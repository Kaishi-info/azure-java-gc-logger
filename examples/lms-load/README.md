# Synthetic LMS load scenario (PostgreSQL + Java + Artillery)

A disposable, internal-only Docker stack that puts **100 concurrent sessions** on a synthetic learning-management-style web application and records its JVM with `collector/collect_gc.sh`. It models the pages such systems are busiest with (to-do list, calendar, course enrolment, gradebook read and write). It does not reproduce any specific product or organisation, and all data is generated.

```sh
sh examples/lms-load/run.sh --leak none        --minutes 5
sh examples/lms-load/run.sh --leak connection  --minutes 5
sh examples/lms-load/run.sh --leak session     --minutes 5
# options: --sessions 100  --out DIR
```

| Service | What it is |
| --- | --- |
| `db` | PostgreSQL 16 with generated data ([`db/init.sql`](db/init.sql)): 2,000 students, 50 teachers, 40 courses, 800 assignments, ~7,300 calendar entries, 16,000 to-dos, grades. Trust authentication on an internal network: no password exists anywhere. |
| `app` | [`app/LmsApp.java`](app/LmsApp.java): Java 11, JDK HTTP server, PostgreSQL JDBC driver (pinned by SHA-256), fixed pool of 20 connections, `-Xmx256m`. The container also runs the collector and writes a Unified GC log. |
| `load` | Artillery 2.0.34 ([`load/lms-sessions.yml`](load/lms-sessions.yml)): each virtual user logs in once and repeats to-do → calendar → courses → gradebook → grade submission with think time, until the deadline. About 8% of submissions use an out-of-range score. |

Deliberate defects (`--leak`, in `LmsApp.java`):

| Mode | Defect | What you see |
| --- | --- | --- |
| `none` | none | baseline |
| `connection` | validation happens after borrowing a pooled connection, and the error path returns without releasing it | pool exhausted, 503s; **heap and GC look healthy**, PostgreSQL shows the connections as `idle` |
| `session` | every response is appended to a per-session cache, and sessions never expire | Old generation grows, Full GCs, the service stalls |

Results land in `./lms-out-<mode>`: collector output, `LMS.log` (GC log), `artillery_report.json`, `app_stats.json`, `pg_connections.txt`, `summary.txt`. Load them into `dashboard/index.html`.

Assertions for CI: [`tests/test_lms_scenario.sh`](../../tests/test_lms_scenario.sh). Measured results and interpretation (Japanese): [`docs/ja/testing.md`](../../docs/ja/testing.md).

Only run this against the stack it starts. Attack-style traffic against other systems does not belong here.
