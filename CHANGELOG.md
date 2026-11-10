# Changelog

## v0.2.0 - 2026-11-10

### Collector
- Interactive first-run setup (`--setup`, also automatic on a terminal without a config): detects the host label from `hostname -s`, lists JVMs visible to the user (PID and main class only, never JVM arguments), test-samples, and saves `gc_logger.conf` (mode 600). The config is parsed as data, never sourced.
- `--check` (one sample, no files) and `--collect-logs` (text-only diagnostics archive).
- On three consecutive `jstat` failures, or when the PID no longer runs the configured main class (`JAVA_MATCH`), the collector stops and prints a Japanese/English operator notice with the exact `--collect-logs` command. Exit codes 2/3/4.
- `jstat` stderr is kept in `collector_YYYY-MM-DD.log` instead of being discarded.
- New events `JAVA_GC_COLLECTOR_STARTED`, `JAVA_GC_COLLECTOR_STOPPED`, `JAVA_GC_SAMPLE_MISSED` (single failures are recorded, never zero-filled). NDJSON metrics add `old_capacity_mib` and `heap_capacity_mib`.
- Validation of `HIGH_PCT` / `RECOVERY_PCT` (numeric, 0-100, recovery below high) and `HIGH_SAMPLES`; unsupported `jstat` layouts and `-` values are failures, not numbers.
- Fixed: awk `END` overrode parse error codes; variables followed by multibyte text broke under bash; FQDN host names became dashed labels.
- Example systemd unit for 24×7 operation (`Restart=no` on purpose, no `PrivateTmp`).

### Dashboard
- Rewritten: 24 h / 7 d / all ranges, host toggles, leak tracking (hourly-minimum baseline trend, R², restarts, gaps, extrapolated time to limit, assessment), hours with the largest increase, gap bands and event markers, Full GCs per hour, weekday × hour heatmap, daily summary, events and gaps tables.
- Raw JSON and analysis JSON export; CSV export keeps all columns.
- Japanese / English, UTC / Asia/Tokyo / browser time zone, light / dark / auto; `#demo` opens a 7-day synthetic demo.
- Content-Security-Policy with `connect-src 'none'`; removed organisation-specific wording; GC log host names derived from any `<host>_gc.log` style name.

### Scenarios, tests, CI/CD
- `examples/leaky-jdbc`: synthetic JVM leaking JDBC-style connections vs a fixed twin, run in Docker.
- `examples/lms-load`: PostgreSQL + synthetic Java LMS + Artillery with 100 concurrent sessions and switchable `connection` / `session` defects.
- Tests: 57 collector checks (normal and failure paths), 19 dashboard checks, real-JVM checks in Docker, LMS scenario assertions, public-content check.
- GitHub Actions: `ci.yml`, `lms-scenario.yml` (weekly/manual), `release.yml` (tagged releases with SHA-256 sums).
- Japanese documentation: operations, dashboard, testing; `CLAUDE.md` runbook for Claude Code; Azure heartbeat query `alert_missing_metrics.kql`.

### Limitations
- Real production operation and Azure ingestion are still not validated.

## v0.1.0 - 2026-11-10

- Prepared a generic shell-based JDK `jstat` collector for UTC-dated CSV and newline-delimited JSON.
- Added offline single-file HTML charts for multiple hosts and supported Java Unified GC event lines.
- Added example Azure Monitor Agent custom JSON log ingestion and separate event alert KQL.
- Added synthetic-data tests, a safety-focused `AGENTS.md`, and bilingual README.
- **Limitations:** real JVM production operation and Azure ingestion not yet validated.
