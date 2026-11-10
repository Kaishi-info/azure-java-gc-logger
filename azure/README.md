# Optional Azure Monitor integration

This directory contains **configuration examples**. It makes no Azure API calls by itself.

## Architecture

`collect_gc.sh` → `gc_azure_YYYY-MM-DD.json` (one JSON object per line) → **Azure Monitor Agent** (AMA) → Data Collection Rule (DCR) **Custom JSON Logs** → Log Analytics custom table **`JavaGc_CL`** → optional Azure Monitor log search alert.

1. Confirm the target VMs already have AMA and the operator has permission to manage DCRs, tables, and alert rules.
2. Choose an approved disk location and retention/rotation policy. The collector defaults to `umask 077`. Give AMA narrowly scoped read access via an approved ACL/group, *not* world-readable permissions.
3. Create a custom table named `JavaGc_CL` **before** creating its collecting DCR, matching the incoming JSON field schema. Microsoft Learn documents this order. At minimum define `TimeGenerated:datetime`, `record_type:string`, `timestamp_utc:string`, `host:string`, `pid:long`, `event_name:string`, `old_pct:real`, `old_used_mib:real`, `old_capacity_mib:real`, `heap_used_mib:real`, `heap_capacity_mib:real`, `gct_delta_ms:real`, `fgc_delta:long`, `consecutive_samples:long`, `detail:string`. Missing per-record fields should remain null.
4. Create or extend a DCR with a **Custom JSON Logs** source (not text logs), with a file pattern like `/var/log/java-gc/gc_azure_*.json`, and a destination of `JavaGc_CL`. The files are **NDJSON**: one JSON object per line, not an array. Use a transform so `TimeGenerated` is derived from `timestamp_utc`, where appropriate: `source | extend TimeGenerated = todatetime(timestamp_utc)`. Verify the transformation schema and UTC behavior in the portal.
5. Confirm collector metric rows arrive via `query_metrics.kql`; then confirm real or *synthetic test* events arrive via `query_events.kql`. Do not manufacture synthetic alerts in a production workspace.
6. Configure a **separate log search alert rule** using `alert_pressure.kql`, scoped to the destination workspace. Alert on `AlertEvents > 0` and split by `host`. Use a lookback long enough for ingestion latency, but tune notification suppression to avoid repeated alerts for the same single event.
7. Optionally use `alert_current_pressure.kql` to assess recent *observed* high utilization even if the collector restarted before posting a transition event. This is not leak proof.
8. For 24×7 operation, add `alert_missing_metrics.kql` as a heartbeat: it fires when a host that reported in the last day has been silent for 15 minutes (collector stopped, AMA cannot read the file, DCR broken).
9. Add `alert_stalled_jvm.kql` to catch a **hung JVM**: metrics keep arriving but heap, Old usage and GC time are frozen while Old occupancy is high. This happens after back-to-back Full GCs, when the JVM no longer serves requests but `jstat` still answers. The collector deliberately does not judge this on the VM; the alert lives in Azure where it can be tuned and suppressed.

### Events in `JavaGc_CL`

`JAVA_GC_COLLECTOR_STARTED`, `JAVA_GC_COLLECTOR_STOPPED`, `JAVA_GC_OLD_HIGH`, `JAVA_GC_OLD_RECOVERED`, `JAVA_GC_SAMPLE_MISSED`, `JAVA_GC_COUNTER_RESET`, `JAVA_GC_COLLECTOR_FAILED`. `alert_pressure.kql` alerts on `OLD_HIGH` and `COLLECTOR_FAILED` only; the others are context for investigation.

### Example event (SYNTHETIC)

```json
{"record_type":"event","timestamp_utc":"2026-01-15T00:02:00Z","host":"APP01","pid":12345,"event_name":"JAVA_GC_OLD_HIGH","old_pct":87.8,"consecutive_samples":3}
```

### Important caveats

- New custom tables, DCRs, alerts, and data ingestion may incur Azure costs. Review billing/retention.
- Azure collects the file **only when the source VM, AMA, DCR, access permissions, and workspace configuration are correct**. Tests in this repository do not validate ingestion.
- Do not inject JVM events into an existing catch-all application `Exception` string alert. Use typed fields and dedicated alert logic.
- Restrict Log Analytics access appropriately; host labels and timestamps may reveal operating patterns.
- `JAVA_GC_COLLECTOR_FAILED` may not arrive if AMA cannot read the same filesystem after the collector fails; use the heartbeat query `alert_missing_metrics.kql` if missing telemetry is critical.
- A log search alert measuring event rows can trigger repeatedly while the event remains in its lookback window. Configure suppression/resolve conditions according to your operational policy.

References:

- https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-log-json
- https://learn.microsoft.com/en-us/azure/azure-monitor/logs/create-custom-table
- https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule
