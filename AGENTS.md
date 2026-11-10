# AGENTS.md: Azure Java GC Logger

## Scope

This repository contains a reference collector (POSIX shell + JDK `jstat`), a standalone offline HTML dashboard, and Azure Monitor configuration examples. Its goal is safe JVM/GC observability without changing the monitored application.

## Non-negotiable constraints for coding agents

1. **Never modify a production JVM or Azure subscription without explicit human authorization.** Do not autonomously deploy, run remote commands, change alerts, rotate services, or publish secrets.
2. No `System.gc()`, `jcmd GC.run`, forced Full GC, `kill -9`, JVM reboot, JDBC pool reset, cache flush, or session invalidation. This repo must only observe JVM statistics.
3. Never add external script dependencies, CDN resources, telemetry beacons, or automatic network uploads to the offline dashboard.
4. Do not require Python, Node.js, Maven, or unapproved agents **on monitored VMs**. Build/test tooling on CI/development machines is okay.
5. Never commit real customer logs, heap dumps, credentials, tokens, internal hostnames, tenant/subscription identifiers, student/user data, or application configurations. Test data must be clearly synthetic.
6. Keep examples **vendor-neutral except where specifically documenting Azure APIs**. No private organizations, educational institutions, or internal incidents in public examples.
7. Use UTC timestamps in generated records. Do not invent metrics or fill unobserved minutes with zeros; annotate missing data.
8. Do not interpret high Old utilization or JVM GC pause counts as definitive proof of a memory leak.
9. All changes should have regression tests. Preserve POSIX shell compatibility and optional Azure integration, without breaking offline use.
10. Follow least privilege for output files. `umask 077` is intentional; AMA access must use explicitly approved ACL/group grants, never `chmod 777`.

## Interface contract

- `collector/collect_gc.sh` writes UTC-dated `gc_samples_YYYY-MM-DD.csv`, `gc_azure_YYYY-MM-DD.json` (newline-delimited JSON objects) and `collector_YYYY-MM-DD.log`. The CSV column order is stable; NDJSON metrics may gain fields (v0.2 added `old_capacity_mib`, `heap_capacity_mib`).
- Modes: default (collect), `--setup` (interactive, writes `gc_logger.conf` mode 600), `--check` (one sample, no files), `--collect-logs` (text-only diagnostics archive), `--help`, `--version`.
- Settings (environment overrides `CONFIG`, default `./gc_logger.conf`): `PID`, `HOST_LABEL`, `OUTPUT_DIR`, `INTERVAL_SEC`, `SAMPLES`, `HIGH_PCT`, `RECOVERY_PCT`, `HIGH_SAMPLES`, `JAVA_MATCH`. The config file is parsed as data, never sourced.
- Exit codes: 0 ok, 2 invalid settings or missing PID (nothing written), 3 jstat failed three times, 4 PID no longer matches `JAVA_MATCH`. Exits 3 and 4 print an operator notice that names `--collect-logs`.
- Events: `JAVA_GC_COLLECTOR_STARTED`, `JAVA_GC_COLLECTOR_STOPPED`, `JAVA_GC_OLD_HIGH`, `JAVA_GC_OLD_RECOVERED`, `JAVA_GC_SAMPLE_MISSED`, `JAVA_GC_COUNTER_RESET`, `JAVA_GC_COLLECTOR_FAILED`.
- JVM command-line arguments must never be displayed, stored or bundled (they can contain secrets); only PID and main class.
- `dashboard/index.html` loads local CSV / NDJSON / selected Unified GC logs and exports `java-gc-timeline/raw@1` and `java-gc-timeline/analysis@1` JSON. It must not connect to anything; its CSP enforces `connect-src 'none'`.
- `azure/*.kql` targets the example `JavaGc_CL` table. Azure environment changes are manually approved operations, not part of tests.
- `examples/` are synthetic single-JVM workloads for disposable containers only. Database-backed load tests and attack-style scenarios (DoS-like load, credential stuffing, exploit payloads) live in a separate private repository, not here.
- Hung-JVM detection (frozen counters) is done in Azure (`azure/alert_stalled_jvm.kql`), not on the VM.

## CI checks

```sh
sh tests/run_all.sh                  # shellcheck, public-content check, collector tests (sh/dash/bash), dashboard tests
sh tests/run_all.sh --docker         # + real JVM scenarios in Docker
```

GitHub Actions runs the same scripts (`.github/workflows/`). On every pull request, inspect new files for leaked secrets, real host IDs, private incident detail, and unwanted remote connections; `tests/check_public_content.sh` automates part of this. Demonstration logs must be synthetic. Never assert that Azure ingestion has been validated unless a test environment has explicitly demonstrated it.

## Limitations to preserve in documentation

- `jstat` usage sampled at time T is not necessarily post-GC usage.
- `GCT` is cumulative GC time, not an exact STW stop time metric.
- The GC log viewer supports a subset of Unified GC formats; unsupported lines are skipped.
- Correlation with real user requests and proof of root cause require additional data and approval.
- Changes of PID, JVM version, or GC implementation can invalidate the simple sample assumptions; disclose these conditions.
- In containers a restarted JVM can keep the same PID, and a JVM under a uid without an `/etc/passwd` entry cannot be read by `jstat`.
- Connection-pool leaks can stall a service while heap and GC metrics stay healthy; GC monitoring does not replace pool monitoring.
