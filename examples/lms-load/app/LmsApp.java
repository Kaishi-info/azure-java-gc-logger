// SYNTHETIC LMS-style web application for load and leak experiments.
//
// A small Java 11 HTTP service backed by PostgreSQL that serves the pages a
// learning-management system is busiest with: to-do list, calendar, course
// enrolment, and gradebook (read and write). All data is generated; no real
// product, organisation or person is modelled.
//
// LEAK_MODE selects deliberate defects (comma separated):
//   none        correct code: connections always returned, sessions expire
//   connection  POST /grades returns early on invalid input without returning
//               the pooled connection -> pool exhaustion, heap stays flat
//   session     every response is appended to a per-session cache that never
//               expires -> Old generation grows until the heap is exhausted
//
// Never expose this service outside a disposable test network.

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.SQLTransientConnectionException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class LmsApp {

    static final String DB_URL = env("DB_URL", "jdbc:postgresql://db:5432/lms");
    static final String DB_USER = env("DB_USER", "lms");
    // The disposable compose network uses trust authentication: no credential exists in this repository.
    static final String DB_PASSWORD = env("DB_PASSWORD", "");
    static final int POOL_SIZE = Integer.parseInt(env("POOL_SIZE", "20"));
    static final int BORROW_TIMEOUT_MS = Integer.parseInt(env("BORROW_TIMEOUT_MS", "3000"));
    static final int SESSION_TTL_SEC = Integer.parseInt(env("SESSION_TTL_SEC", "300"));
    static final Set<String> LEAKS = Set.of(env("LEAK_MODE", "none").split(","));
    static final boolean LEAK_CONNECTION = LEAKS.contains("connection");
    static final boolean LEAK_SESSION = LEAKS.contains("session");

    static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }

    // ------------------------------------------------------------------ pool
    /** Minimal fixed-size pool, enough to show what a leaked borrow does. */
    static final class Pool {
        final ArrayBlockingQueue<Connection> idle;
        final AtomicInteger borrowed = new AtomicInteger();
        final AtomicLong timeouts = new AtomicLong();

        Pool(int size) throws SQLException {
            idle = new ArrayBlockingQueue<>(size);
            for (int i = 0; i < size; i++) idle.add(DriverManager.getConnection(DB_URL, DB_USER, DB_PASSWORD));
        }

        Connection borrow() throws SQLException {
            try {
                Connection c = idle.poll(BORROW_TIMEOUT_MS, TimeUnit.MILLISECONDS);
                if (c == null) {
                    timeouts.incrementAndGet();
                    throw new SQLTransientConnectionException("connection pool exhausted after " + BORROW_TIMEOUT_MS + " ms");
                }
                borrowed.incrementAndGet();
                return c;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new SQLException("interrupted", e);
            }
        }

        void release(Connection c) {
            borrowed.decrementAndGet();
            idle.offer(c);
        }
    }

    // --------------------------------------------------------------- sessions
    static final class Session {
        final String id;
        final int userId;
        volatile long lastSeen = System.currentTimeMillis();
        final Map<String, String> latest = new ConcurrentHashMap<>();   // correct: one entry per page
        final List<String> history = new ArrayList<>();                // defect: grows forever
        Session(String id, int userId) { this.id = id; this.userId = userId; }

        void remember(String page, String body) {
            if (LEAK_SESSION) { synchronized (history) { history.add(body); } }
            else latest.put(page, body);
        }
    }

    static final Map<String, Session> SESSIONS = new ConcurrentHashMap<>();
    static Pool pool;
    static final AtomicLong REQUESTS = new AtomicLong(), ERRORS = new AtomicLong();
    static final AtomicInteger INVALID_LOGGED = new AtomicInteger();

    public static void main(String[] args) throws Exception {
        pool = connectWithRetry();
        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 256);
        server.setExecutor(Executors.newFixedThreadPool(64));
        server.createContext("/", LmsApp::handle);
        Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(LmsApp::expireSessions, 30, 30, TimeUnit.SECONDS);
        server.start();
        System.out.printf("SYNTHETIC LMS listening on :8080 pid=%d leak_mode=%s pool=%d%n",
            ProcessHandle.current().pid(), String.join(",", LEAKS), POOL_SIZE);
    }

    static Pool connectWithRetry() throws Exception {
        SQLException last = null;
        for (int i = 0; i < 60; i++) {
            try { return new Pool(POOL_SIZE); } catch (SQLException e) { last = e; Thread.sleep(1000); }
        }
        throw last;
    }

    static void expireSessions() {
        if (LEAK_SESSION) return; // defect: sessions are never expired
        long cutoff = System.currentTimeMillis() - SESSION_TTL_SEC * 1000L;
        SESSIONS.values().removeIf(s -> s.lastSeen < cutoff);
    }

    // ---------------------------------------------------------------- routing
    static void handle(HttpExchange ex) throws IOException {
        REQUESTS.incrementAndGet();
        String path = ex.getRequestURI().getPath(), method = ex.getRequestMethod();
        try {
            if (path.equals("/health")) { send(ex, 200, "{\"status\":\"ok\"}"); return; }
            if (path.equals("/stats")) { send(ex, 200, stats()); return; }
            if (path.equals("/login") && method.equals("POST")) { login(ex); return; }
            Session s = session(ex);
            if (s == null) { send(ex, 401, "{\"error\":\"login required\"}"); return; }
            s.lastSeen = System.currentTimeMillis();
            String body;
            switch (path) {
                case "/todo": body = todo(s); break;
                case "/calendar": body = calendar(s, intParam(ex, "days", 14)); break;
                case "/courses": body = courses(s); break;
                case "/gradebook": body = gradebook(s); break;
                case "/grades":
                    if (!method.equals("POST")) { send(ex, 405, "{\"error\":\"POST only\"}"); return; }
                    postGrade(ex, s); return;
                default: send(ex, 404, "{\"error\":\"not found\"}"); return;
            }
            s.remember(path, body);
            send(ex, 200, body);
        } catch (SQLTransientConnectionException e) {
            ERRORS.incrementAndGet();
            send(ex, 503, "{\"error\":\"" + e.getMessage() + "\"}");
        } catch (Exception e) {
            ERRORS.incrementAndGet();
            send(ex, 500, "{\"error\":\"" + e.getClass().getSimpleName() + "\"}");
        }
    }

    static void login(HttpExchange ex) throws IOException {
        Matcher m = Pattern.compile("\"user\"\\s*:\\s*\"?(\\d+)").matcher(readBody(ex));
        int user = m.find() ? Integer.parseInt(m.group(1)) : 1;
        Session s = new Session(UUID.randomUUID().toString(), Math.max(1, Math.min(user, 2000)));
        SESSIONS.put(s.id, s);
        ex.getResponseHeaders().add("Set-Cookie", "sid=" + s.id + "; Path=/; HttpOnly");
        send(ex, 200, "{\"user\":" + s.userId + "}");
    }

    static Session session(HttpExchange ex) {
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies == null) return null;
        for (String header : cookies) for (String c : header.split(";")) {
            String kv = c.trim();
            if (kv.startsWith("sid=")) return SESSIONS.get(kv.substring(4));
        }
        return null;
    }

    // ------------------------------------------------------------------ pages
    static String todo(Session s) throws SQLException {
        return query("SELECT 'assignment' AS kind, a.title, to_char(a.due_at,'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS due, c.code "
            + "FROM enrollments e JOIN assignments a ON a.course_id = e.course_id JOIN courses c ON c.id = a.course_id "
            + "WHERE e.user_id = ? AND a.due_at BETWEEN now() AND now() + interval '14 days' "
            + "UNION ALL SELECT 'todo', t.title, to_char(t.due_at,'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '' FROM todos t WHERE t.user_id = ? AND NOT t.done "
            + "ORDER BY due LIMIT 100", s.userId, s.userId);
    }

    static String calendar(Session s, int days) throws SQLException {
        return query("SELECT ev.title, ev.description, to_char(ev.starts_at,'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS starts, c.code "
            + "FROM enrollments e JOIN calendar_events ev ON ev.course_id = e.course_id JOIN courses c ON c.id = ev.course_id "
            + "WHERE e.user_id = ? AND ev.starts_at BETWEEN now() AND now() + make_interval(days => ?) ORDER BY ev.starts_at LIMIT 500",
            s.userId, Math.max(1, Math.min(days, 60)));
    }

    static String courses(Session s) throws SQLException {
        return query("SELECT c.code, c.title, e.role FROM enrollments e JOIN courses c ON c.id = e.course_id WHERE e.user_id = ? ORDER BY c.code", s.userId);
    }

    static String gradebook(Session s) throws SQLException {
        return query("SELECT c.code, a.title, g.score, to_char(g.updated_at,'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS updated "
            + "FROM grades g JOIN assignments a ON a.id = g.assignment_id JOIN courses c ON c.id = a.course_id "
            + "WHERE g.user_id = ? ORDER BY c.code, a.title", s.userId);
    }

    static void postGrade(HttpExchange ex, Session s) throws IOException, SQLException {
        String body = readBody(ex);
        int assignment = jsonInt(body, "assignment", -1), score = jsonInt(body, "score", -1);
        if ((score < 0 || score > 100 || assignment < 1) && INVALID_LOGGED.getAndIncrement() < 3) {
            System.out.println("invalid grade request body: " + body.replaceAll("[^ -~]", "?"));
        }
        Connection c = pool.borrow();
        if (LEAK_CONNECTION) {
            // DEFECT ON PURPOSE: validation after borrowing, early return skips release().
            if (score < 0 || score > 100 || assignment < 1) { send(ex, 400, "{\"error\":\"score must be 0-100\"}"); return; }
            upsertGrade(c, assignment, s.userId, score);
            pool.release(c);
        } else {
            try {
                if (score < 0 || score > 100 || assignment < 1) { send(ex, 400, "{\"error\":\"score must be 0-100\"}"); return; }
                upsertGrade(c, assignment, s.userId, score);
            } finally {
                pool.release(c);
            }
        }
        send(ex, 200, "{\"saved\":true}");
    }

    static void upsertGrade(Connection c, int assignment, int user, int score) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO grades(assignment_id, user_id, score, updated_at) SELECT ?, ?, ?, now() WHERE EXISTS (SELECT 1 FROM assignments WHERE id = ?) "
                + "ON CONFLICT (assignment_id, user_id) DO UPDATE SET score = EXCLUDED.score, updated_at = now()")) {
            ps.setInt(1, assignment); ps.setInt(2, user); ps.setInt(3, score); ps.setInt(4, assignment);
            ps.executeUpdate();
        }
    }

    // ---------------------------------------------------------------- helpers
    static String query(String sql, Object... params) throws SQLException {
        Connection c = pool.borrow();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            for (int i = 0; i < params.length; i++) ps.setObject(i + 1, params[i]);
            try (ResultSet rs = ps.executeQuery()) {
                StringBuilder sb = new StringBuilder("[");
                int cols = rs.getMetaData().getColumnCount();
                boolean first = true;
                while (rs.next()) {
                    sb.append(first ? "{" : ",{");
                    first = false;
                    for (int i = 1; i <= cols; i++) {
                        if (i > 1) sb.append(',');
                        sb.append('"').append(rs.getMetaData().getColumnLabel(i)).append("\":");
                        Object v = rs.getObject(i);
                        if (v == null) sb.append("null");
                        else if (v instanceof Number) sb.append(v);
                        else sb.append('"').append(v.toString().replace("\\", "\\\\").replace("\"", "\\\"")).append('"');
                    }
                    sb.append('}');
                }
                return sb.append(']').toString();
            }
        } finally {
            pool.release(c);
        }
    }

    static String stats() {
        long cached = 0;
        for (Session s : SESSIONS.values()) synchronized (s.history) { cached += s.history.size() + s.latest.size(); }
        Runtime rt = Runtime.getRuntime();
        return String.format("{\"leak_mode\":\"%s\",\"requests\":%d,\"errors\":%d,\"sessions\":%d,\"cached_pages\":%d,"
                + "\"pool_size\":%d,\"pool_idle\":%d,\"pool_borrowed\":%d,\"pool_timeouts\":%d,\"heap_used_mib\":%d}",
            String.join(",", LEAKS), REQUESTS.get(), ERRORS.get(), SESSIONS.size(), cached,
            POOL_SIZE, pool.idle.size(), pool.borrowed.get(), pool.timeouts.get(), (rt.totalMemory() - rt.freeMemory()) >> 20);
    }

    static int intParam(HttpExchange ex, String name, int def) {
        String q = ex.getRequestURI().getQuery();
        if (q == null) return def;
        for (String kv : q.split("&")) if (kv.startsWith(name + "=")) {
            try { return Integer.parseInt(kv.substring(name.length() + 1)); } catch (NumberFormatException e) { return def; }
        }
        return def;
    }

    static int jsonInt(String body, String key, int def) {
        Matcher m = Pattern.compile("\"" + key + "\"\\s*:\\s*\"?(-?\\d+)").matcher(body);
        return m.find() ? Integer.parseInt(m.group(1)) : def;
    }

    static String readBody(HttpExchange ex) throws IOException {
        try (InputStream in = ex.getRequestBody()) { return new String(in.readNBytes(64 * 1024), StandardCharsets.UTF_8); }
    }

    static void send(HttpExchange ex, int code, String body) throws IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.sendResponseHeaders(code, b.length);
        try (OutputStream os = ex.getResponseBody()) { os.write(b); }
    }
}
