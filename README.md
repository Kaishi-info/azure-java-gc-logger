# azure-java-gc-logger

**Dependency-free JVM GC sampling for Linux hosts, a single-file offline dashboard for 7×24 review, and optional Azure Monitor integration.**

[日本語の README](README.ja.md)

> **Release status:** v0.2.0, reference implementation. Collector unit tests, dashboard tests, real-JVM tests in Docker and a PostgreSQL-backed LMS-style load scenario pass. Azure Monitor ingestion and unattended production operation **have not** been validated. Review [`AGENTS.md`](AGENTS.md) before deploying.

## Why this exists

Java applications can exhaust heap while apparently running normally, and periodic restarts can hide a growing baseline. This project collects inexpensive time-series evidence with the **JDK's own `jstat`**, shows a week of it in **one offline HTML file**, and can forward **typed events** to Azure Monitor. It never forces GC, restarts the JVM or writes to the application.

It does **not** identify GC roots, detect every kind of leak, replace a heap profiler, or prove that an application is free of leaks. Connection leaks, for example, may never show up in the heap (see the LMS scenario below).

## Using Claude Code

Paste this repository's URL into [Claude Code](https://claude.com/claude-code) and say what you want to monitor. [`CLAUDE.md`](CLAUDE.md) walks the agent through local verification, a single round of questions, VM install commands, interactive setup, 24×7 operation, reading diagnostics when collection fails, building a report from the dashboard's analysis JSON, and (optionally) Azure Monitor configuration. Commands against production VMs and Azure are **shown for the administrator to run**, never executed autonomously.

## Components

| Path | Purpose | Runs on JVM host? |
| --- | --- | --- |
| [`collector/collect_gc.sh`](collector/collect_gc.sh) | Interactive setup, `jstat -gc` sampling, daily CSV + NDJSON, operator diagnostics | Yes: POSIX `sh`, `jstat`/`jcmd`, `awk`, `date` |
| [`collector/systemd/`](collector/systemd/) | Example unit for continuous collection | Yes, optional |
| [`dashboard/index.html`](dashboard/index.html) | Offline multi-host 7×24 dashboard; CSV, NDJSON and Unified GC logs; raw/analysis JSON export | No: local browser only |
| [`azure/`](azure/) | AMA custom JSON log setup, KQL queries and alert examples | Azure control plane, manually configured |
| [`examples/leaky-jdbc/`](examples/leaky-jdbc/) | Synthetic JVM that leaks JDBC-style connections vs a fixed twin | No: disposable container |
| [`examples/lms-load/`](examples/lms-load/) | PostgreSQL + synthetic LMS (to-do, calendar, enrolment, gradebook) + Artillery, 100 concurrent sessions | No: disposable containers |
| [`tests/`](tests/) | Unit, real-JVM, LMS scenario and public-content checks | CI or development machine |

No Python, Node.js, Java agent, Maven plugin or extra JAR is required **on the monitored VM**.

## Quick start (staging first)

```sh
# as the same user that runs the JVM
sh collector/collect_gc.sh --setup    # detects host name, lists JVMs, test-samples, saves gc_logger.conf
sh collector/collect_gc.sh --check    # one sample to stdout, writes nothing
sh collector/collect_gc.sh            # collect (Ctrl+C to stop); see collector/systemd for 24x7
```

JVM arguments are never displayed or stored (they can contain secrets); only the PID and main class are.

When `jstat` fails three times in a row (JVM stopped or restarted, permissions changed) or the PID now belongs to another program, the collector **stops** and prints an operator notice (Japanese and English) with the exact command to run:

```sh
sh collector/collect_gc.sh --collect-logs   # text-only diagnostics archive for the support contact
```

Output (UTC-dated, `umask 077`):

```text
out/gc_samples_2026-01-15.csv     # samples for the dashboard
out/gc_azure_2026-01-15.json      # NDJSON metrics and events (AMA-compatible)
out/collector_2026-01-15.log      # collector's own log, including jstat errors
```

| Event | Meaning |
| --- | --- |
| `JAVA_GC_COLLECTOR_STARTED` / `_STOPPED` | Collection started / stopped (distinguishes planned stops from missing data) |
| `JAVA_GC_OLD_HIGH` / `_OLD_RECOVERED` | Old occupancy crossed the high / recovery threshold for consecutive samples |
| `JAVA_GC_SAMPLE_MISSED` | One sample failed (reason attached); never filled with zeros |
| `JAVA_GC_COUNTER_RESET` | GC counters moved backward (restart under the same PID) |
| `JAVA_GC_COLLECTOR_FAILED` | Collection stopped; operator action required |

## Dashboard

Open `dashboard/index.html` in a modern browser and load any mix of CSV, NDJSON and Unified GC logs from many hosts and days (`index.html#demo` shows a 7-day synthetic demo). A Content-Security-Policy blocks every network connection.

- 24 h / 7 d / all ranges, host toggles, UTC / Asia/Tokyo / browser time zone, Japanese / English, light / dark
- **Leak tracking:** hourly-minimum Old usage ("baseline") per host, linear trend (MiB/day, R²), restarts and gaps taken into account, assessed as *rising / flat / unclear / not enough data*; hours with the largest baseline increase, to correlate with deployments, batches and traffic
- Old occupancy with threshold, event markers and gap bands; heap with post-GC points from GC logs; GC time; Full GCs per hour
- Weekday × hour (7×24) heatmap, daily summary, events, gaps
- **Raw JSON** and **analysis JSON** export ([format](docs/ja/dashboard.md))

### Read the numbers correctly

- **Old occupancy** = `OU / OC`: a snapshot, not live data after Full GC. Old capacity can change at runtime (G1), so the percentage can move without a change in used memory.
- **GC time delta** = difference in cumulative `GCT`: not guaranteed to be stop-the-world only.
- **Rising baseline** is consistent with a leak *or* a growing working set (caches, sessions). It is not proof.
- **Old occupancy above 85%** is a demonstration threshold. In the LMS scenario a healthy 256 MB JVM reached 90%.

## Test scenarios

```sh
sh tests/run_all.sh                    # shellcheck, public-content check, collector (sh/dash/bash), dashboard
sh tests/run_all.sh --docker           # + real JVM in Docker: leaking vs fixed, uid without passwd entry, diagnostics
sh tests/run_all.sh --docker --lms     # + LMS 100-session scenarios (~15 min)
```

The LMS scenario (`examples/lms-load`) runs PostgreSQL 16, a synthetic Java 11 LMS and Artillery with 100 concurrent sessions, with three switchable defects: `none`, `connection` (a pooled connection is not returned on a validation error: the service stalls with 503s while **heap and GC look healthy**), and `session` (responses accumulate per session: Old generation grows until the JVM stalls). Details and measured results: [`docs/ja/testing.md`](docs/ja/testing.md).

Load or attack-style scenarios beyond a self-hosted synthetic stack (DoS-like traffic, credential stuffing, exploit payloads) do not belong in this public repository; keep them in a separate private repository with documented targets and approvals.

## CI/CD

GitHub Actions (free for public repositories): [`ci.yml`](.github/workflows/ci.yml) on every push and pull request (lint, public-content check, Linux/macOS unit tests, real-JVM job), [`lms-scenario.yml`](.github/workflows/lms-scenario.yml) weekly or on demand, and [`release.yml`](.github/workflows/release.yml) on `v*` tags (all checks, then a source archive and a VM collector bundle with SHA-256 sums as a GitHub Release). Deployment to VMs and any Azure change remain manual, approved operations.

## Optional Azure Monitor integration

**Azure Monitor Agent → Data Collection Rule (custom JSON logs) → `JavaGc_CL` → log search alert.** This repository creates or changes no cloud resources. See [`azure/README.md`](azure/README.md). Ingestion, retention and alert evaluation may incur cost.

## Safety, privacy and limitations

- The collector only reads JVM performance counters. No `System.gc()`, forced Full GC, restarts, DB connection resets or session invalidation.
- Production use needs an approved plan for PID changes, permissions, overhead, retention, rotation and supervision. The collector stops on repeated failures instead of attaching to a new PID.
- In containers a restarted JVM can get the **same PID**; a JVM running under a uid without an `/etc/passwd` entry cannot be read by `jstat` at all.
- CSV and JSON reveal host names, PIDs and timestamps. **Do not commit real logs**, heap dumps, tokens, internal paths or personal data. `tests/check_public_content.sh` runs in CI.
- **This project is a monitoring aid, not a production-ready SRE platform.**

## Documentation

- [`README.ja.md`](README.ja.md), [`docs/ja/operations.md`](docs/ja/operations.md), [`docs/ja/dashboard.md`](docs/ja/dashboard.md), [`docs/ja/testing.md`](docs/ja/testing.md) (Japanese)
- [`CLAUDE.md`](CLAUDE.md), [`AGENTS.md`](AGENTS.md), [`azure/README.md`](azure/README.md), [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md)

## References

- [Oracle JDK 11 `jstat`](https://docs.oracle.com/en/java/javase/11/tools/jstat.html), [`jcmd`](https://docs.oracle.com/en/java/javase/11/tools/jcmd.html)
- [Microsoft Learn: Collect JSON logs using Azure Monitor Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-log-json)
- [Microsoft Learn: Create a custom table in Azure Monitor Logs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/create-custom-table)
- [Microsoft Learn: Create a log search alert](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)

## License

MIT © 2026 AICU Inc. See [`LICENSE`](LICENSE).
