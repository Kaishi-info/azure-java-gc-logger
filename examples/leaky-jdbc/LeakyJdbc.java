// SYNTHETIC test workload: a JVM that deliberately leaks "JDBC connections".
//
// Purpose: give collect_gc.sh and the offline dashboard a real JVM whose Old
// generation grows for a known reason, without any database, driver or
// network. java.sql.Connection / PreparedStatement are implemented with
// java.lang.reflect.Proxy, so the request code looks like ordinary JDBC.
//
// Never run this next to a production workload. It is meant to exhaust its
// own heap. Java 11+, no dependencies:
//
//   java -Xmx128m LeakyJdbc.java leak  [seconds] [req_per_sec] [fail_pct] [buffer_kib]
//   java -Xmx128m LeakyJdbc.java fixed [seconds] [req_per_sec] [fail_pct] [buffer_kib]
//
// "leak":  the error path returns before close(), the classic bug shown below.
// "fixed": the same work with try-with-resources; heap should stay flat.

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

public class LeakyJdbc {

    /** Stands in for a pool / driver registry that tracks every borrowed connection. */
    static final class FakeDataSource {
        final Map<Long, byte[]> borrowed = new ConcurrentHashMap<>();
        final AtomicLong ids = new AtomicLong();
        final int bufferBytes;

        FakeDataSource(int bufferBytes) { this.bufferBytes = bufferBytes; }

        Connection getConnection() {
            long id = ids.incrementAndGet();
            // Per-connection socket/statement buffers live until close().
            borrowed.put(id, new byte[bufferBytes]);
            InvocationHandler h = (proxy, m, args) -> {
                switch (m.getName()) {
                    case "close": borrowed.remove(id); return null;
                    case "isClosed": return !borrowed.containsKey(id);
                    case "prepareStatement": return statement();
                    case "toString": return "FakeConnection#" + id;
                    case "hashCode": return Long.hashCode(id);
                    case "equals": return proxy == args[0];
                    default: throw new SQLException("unsupported in synthetic driver: " + m.getName());
                }
            };
            return (Connection) Proxy.newProxyInstance(
                LeakyJdbc.class.getClassLoader(), new Class<?>[] {Connection.class}, h);
        }

        PreparedStatement statement() {
            InvocationHandler h = (proxy, m, args) -> {
                switch (m.getName()) {
                    case "executeUpdate":
                        // Short-lived garbage per query, so young GCs also happen.
                        byte[] rows = new byte[32 * 1024];
                        return rows.length > 0 ? 1 : 0;
                    case "close": return null;
                    case "toString": return "FakeStatement";
                    case "hashCode": return System.identityHashCode(proxy);
                    case "equals": return proxy == args[0];
                    default: throw new SQLException("unsupported in synthetic driver: " + m.getName());
                }
            };
            return (PreparedStatement) Proxy.newProxyInstance(
                LeakyJdbc.class.getClassLoader(), new Class<?>[] {PreparedStatement.class}, h);
        }
    }

    static final Random RNG = new Random(42); // deterministic, synthetic

    /** BUG ON PURPOSE: the validation-failure path returns before close(). */
    static void handleRequestLeaky(FakeDataSource ds, int failPct) throws SQLException {
        Connection c = ds.getConnection();
        PreparedStatement ps = c.prepareStatement("UPDATE demo SET n = n + 1");
        ps.executeUpdate();
        if (RNG.nextInt(100) < failPct) {
            return; // leaked: neither ps nor c is closed
        }
        ps.close();
        c.close();
    }

    /** Same work, resources always released. */
    static void handleRequestFixed(FakeDataSource ds, int failPct) throws SQLException {
        try (Connection c = ds.getConnection();
             PreparedStatement ps = c.prepareStatement("UPDATE demo SET n = n + 1")) {
            ps.executeUpdate();
            if (RNG.nextInt(100) < failPct) {
                return;
            }
        }
    }

    public static void main(String[] a) throws Exception {
        String mode = a.length > 0 ? a[0] : "leak";
        int seconds = a.length > 1 ? Integer.parseInt(a[1]) : 120;
        int rps = a.length > 2 ? Integer.parseInt(a[2]) : 50;
        int failPct = a.length > 3 ? Integer.parseInt(a[3]) : 30;
        int bufKiB = a.length > 4 ? Integer.parseInt(a[4]) : 128;
        if (!mode.equals("leak") && !mode.equals("fixed")) {
            System.err.println("mode must be leak or fixed");
            System.exit(2);
        }
        FakeDataSource ds = new FakeDataSource(bufKiB * 1024);
        long pid = ProcessHandle.current().pid();
        System.out.printf("SYNTHETIC LeakyJdbc mode=%s pid=%d seconds=%d rps=%d fail=%d%% buffer=%dKiB%n",
            mode, pid, seconds, rps, failPct, bufKiB);

        long end = System.nanoTime() + seconds * 1_000_000_000L;
        long sleepNanos = 1_000_000_000L / Math.max(1, rps);
        long n = 0;
        while (System.nanoTime() < end) {
            if (mode.equals("leak")) handleRequestLeaky(ds, failPct);
            else handleRequestFixed(ds, failPct);
            n++;
            if (n % (rps * 10L) == 0) {
                System.out.printf("requests=%d open_connections=%d%n", n, ds.borrowed.size());
            }
            Thread.sleep(sleepNanos / 1_000_000, (int) (sleepNanos % 1_000_000));
        }
        System.out.printf("done requests=%d open_connections=%d%n", n, ds.borrowed.size());
    }
}
