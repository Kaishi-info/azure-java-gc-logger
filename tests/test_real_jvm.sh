#!/bin/sh
# shellcheck disable=SC2016  # single-quoted sh -c scripts expand "$1" in the child on purpose
# Real-JVM scenarios in Docker (synthetic workloads only). Slower than the unit
# tests; CI runs them in a separate job. Skips when Docker is unavailable
# unless REQUIRE_DOCKER=1.
#   sh tests/test_real_jvm.sh
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if ! docker info >/dev/null 2>&1; then
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then echo 'FAIL  docker not available'; exit 1; fi
  echo 'SKIP  docker not available'; exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
pass=0 fail=0
check() { name=$1; shift; if "$@"; then pass=$((pass + 1)); echo "PASS  $name"; else fail=$((fail + 1)); echo "FAIL  $name"; fi; }
img=eclipse-temurin:11-jdk

# A. Leaking vs fixed JVM (examples/leaky-jdbc), 120 s.
sh "$root/examples/leaky-jdbc/run-docker.sh" "$tmp/leaky" 120 > "$tmp/leaky.txt" 2>&1
csv=$(ls "$tmp"/leaky/gc_samples_*.csv)
leak_max=$(awk -F, '$2=="LEAK" && $8>m {m=$8} END {print m+0}' "$csv")
fixed_max=$(awk -F, '$2=="FIXED" && $8>m {m=$8} END {print m+0}' "$csv")
check "leaky: LEAK old_pct rises above 85 (got $leak_max)" awk -v v="$leak_max" 'BEGIN { exit !(v > 85) }'
check "leaky: FIXED old_pct stays below 30 (got $fixed_max)" awk -v v="$fixed_max" 'BEGIN { exit !(v < 30) }'
check 'leaky: OLD_HIGH emitted for LEAK only' sh -c 'grep "JAVA_GC_OLD_HIGH" "$1"/gc_azure_*.json | grep -q "\"host\":\"LEAK\"" && ! grep "JAVA_GC_OLD_HIGH" "$1"/gc_azure_*.json | grep -q "\"host\":\"FIXED\""' _ "$tmp/leaky"
check 'leaky: JVM exit detected as COLLECTOR_FAILED' grep -q 'JAVA_GC_COLLECTOR_FAILED' "$(ls "$tmp"/leaky/gc_azure_*.json)"
check 'leaky: GC log contains Full GC lines' grep -q 'Pause Full' "$tmp/leaky/LEAK.log"
check 'leaky: output files are private (600)' sh -c '[ -z "$(find "$1" -name "gc_*" ! -perm 600)" ]' _ "$tmp/leaky"

# B. JVM under a uid without an /etc/passwd entry: no hsperfdata, jstat cannot attach.
#    The collector must stop, explain, and point to --collect-logs.
mkdir -p "$tmp/nouid"
owner="$(id -u):$(id -g)"
docker run --rm -e OWNER="$owner" -v "$root:/src:ro" -v "$tmp/nouid:/out" "$img" sh -c '
  setpriv --reuid=4242 --regid=4242 --clear-groups java -Xmx64m /src/examples/leaky-jdbc/LeakyJdbc.java fixed 40 >/dev/null 2>&1 &
  jvm=$!
  sleep 5
  PID=$jvm HOST_LABEL=NOUID OUTPUT_DIR=/out INTERVAL_SEC=1 SAMPLES=10 sh /src/collector/collect_gc.sh
  echo "rc=$?"
  cd /out && PID=$jvm HOST_LABEL=NOUID OUTPUT_DIR=/out sh /src/collector/collect_gc.sh --collect-logs
  chown -R "$OWNER" /out' > "$tmp/nouid.txt" 2>&1 || true
check 'no-passwd uid: collector exits 3' grep -q 'rc=3' "$tmp/nouid.txt"
check 'no-passwd uid: operator told to run --collect-logs' grep -q -- '--collect-logs' "$tmp/nouid.txt"
check 'no-passwd uid: HotSpot reason kept in collector log' sh -c 'grep -q "Could not map vmid" "$1"/collector_*.log' _ "$tmp/nouid"

# C. Diagnostics archive created inside the container (same run as B).
check 'diag: archive created in container' sh -c 'ls "$1"/diag_NOUID_*.tar.gz >/dev/null 2>&1' _ "$tmp/nouid"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
