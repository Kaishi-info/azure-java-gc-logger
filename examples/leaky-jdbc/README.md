# Synthetic leaking-JDBC workload

`LeakyJdbc.java` is a **synthetic** Java 11+ program that leaks "JDBC connections" on purpose, so that `collector/collect_gc.sh` and `dashboard/index.html` can be checked against a real JVM instead of a mocked `jstat`. There is no database, driver, or network. `java.sql.Connection` and `PreparedStatement` are implemented with `java.lang.reflect.Proxy`, so the request code reads like ordinary JDBC.

The bug it reproduces is an early return that skips `close()`:

```java
Connection c = ds.getConnection();
PreparedStatement ps = c.prepareStatement("UPDATE demo SET n = n + 1");
ps.executeUpdate();
if (validationFailed) {
    return;            // neither ps nor c is closed
}
ps.close();
c.close();
```

Each leaked connection keeps a per-connection buffer (128 KiB by default) alive in the fake data source's "borrowed" map. The `fixed` mode does the same work with try-with-resources.

**Do not run this on a host that serves real traffic.** It is designed to exhaust its own heap.

## Run in a disposable container

Requires Docker on a development machine. Nothing is installed on a monitored VM.

```sh
sh examples/leaky-jdbc/run-docker.sh ./leaky-out 120
```

This starts two JVMs (`-Xmx128m` each) in `eclipse-temurin:11-jdk`, labelled `LEAK` and `FIXED`, samples both every 2 seconds with `collect_gc.sh`, and writes Unified GC logs next to the collector output. Load everything in `./leaky-out` into `dashboard/index.html`.

What to expect (one run, 50 req/s, 20% failure path, 128 KiB buffer):

| Host | Old occupancy | Full GC | End |
| --- | --- | --- | --- |
| `LEAK` | rises steadily from about 9% to 98% | starts only in the last ~10 s; GC log shows `126M->104M` after Full GC | `OutOfMemoryError` after about 100 s, then `JAVA_GC_OLD_HIGH` and `JAVA_GC_COLLECTOR_FAILED` events |
| `FIXED` | flat around 4-5% | none | completes normally; collector stops with `JAVA_GC_COLLECTOR_FAILED` once the JVM exits |

The same run is asserted in CI by [`tests/test_real_jvm.sh`](../../tests/test_real_jvm.sh).

The heap that remains after a Full GC is the signal that separates a leak from a heap that is merely busy. `jstat` sampling alone does not show it, which is why the dashboard also accepts Unified GC logs.

## Notes

- Inside the container the JVM runs as root. If a JVM runs under a uid with no `/etc/passwd` entry (for example `docker run --user 502`), HotSpot creates no `hsperfdata` file and `jstat` fails with `Could not map vmid to user Name`. The same applies to production containers started with an arbitrary uid.
- Arguments: `java -Xmx128m LeakyJdbc.java leak|fixed [seconds] [req_per_sec] [fail_pct] [buffer_kib]`.
- The random sequence is seeded, so runs are comparable, but GC timing still varies by machine.
