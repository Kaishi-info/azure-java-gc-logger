#!/bin/sh
# LMS scenario assertions (examples/lms-load). Synthetic data only.
#   MINUTES=3 sh tests/test_lms_scenario.sh [none connection session]
#   OUT_BASE=DIR keeps the results (default: a temporary directory)
# shellcheck disable=SC2016  # single-quoted sh -c scripts expand "$1" in the child on purpose
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
minutes=${MINUTES:-3}
modes=${*:-none connection session}
if ! docker info >/dev/null 2>&1; then
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then echo 'FAIL  docker not available'; exit 1; fi
  echo 'SKIP  docker not available'; exit 0
fi
if [ -n "${OUT_BASE:-}" ]; then base=$OUT_BASE; mkdir -p "$base"; else base=$(mktemp -d); trap 'rm -rf "$base"' EXIT HUP INT TERM; fi
pass=0 fail=0
check() { name=$1; shift; if "$@"; then pass=$((pass + 1)); echo "PASS  $name"; else fail=$((fail + 1)); echo "FAIL  $name"; fi; }
stat() { sed -n "s/.*\"$2\":\([0-9]*\).*/\1/p" "$1/app_stats.json"; }
maxold() { awk -F, 'NR>1 && $8>m {m=$8} END {print m+0}' "$1"/gc_samples_*.csv 2>/dev/null; }

for m in $modes; do
  out="$base/$m"
  sh "$root/examples/lms-load/run.sh" --leak "$m" --minutes "$minutes" --out "$out" > "$base/$m.run.txt" 2>&1
  echo "== $m: max old_pct $(maxold "$out"), stats $(cat "$out/app_stats.json" 2>/dev/null)"
  check "$m: collector produced samples" sh -c '[ "$(cat "$1"/gc_samples_*.csv | wc -l)" -gt 10 ]' _ "$out"
  check "$m: one collector start (no container re-creation)" sh -c '[ "$(grep -c COLLECTOR_STARTED "$1"/gc_azure_*.json)" = 1 ]' _ "$out"
  check "$m: GC log written" test -s "$out/LMS.log"
  check "$m: load test report written" test -s "$out/artillery_report.json"
  case "$m" in
    none)
      check 'none: no pool timeouts' [ "$(stat "$out" pool_timeouts)" = 0 ]
      check 'none: no server errors' [ "$(stat "$out" errors)" = 0 ]
      ;;
    connection)
      check 'connection: pool exhausted (all connections borrowed)' [ "$(stat "$out" pool_borrowed)" = "$(stat "$out" pool_size)" ]
      check 'connection: pool timeouts observed' [ "$(stat "$out" pool_timeouts)" -gt 0 ]
      check 'connection: 503 responses in load report' grep -q '"http.codes.503"' "$out/artillery_report.json"
      check "connection: heap looks healthy (max old_pct $(maxold "$out") < 85)" awk -v v="$(maxold "$out")" 'BEGIN { exit !(v < 85) }'
      ;;
    session)
      check "session: old_pct above 90 (got $(maxold "$out"))" awk -v v="$(maxold "$out")" 'BEGIN { exit !(v > 90) }'
      check 'session: OLD_HIGH emitted' sh -c 'grep -q JAVA_GC_OLD_HIGH "$1"/gc_azure_*.json' _ "$out"
      check 'session: Full GC in GC log' sh -c 'grep -q "Pause Full" "$1"/LMS.log*' _ "$out"
      ;;
  esac
done
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
