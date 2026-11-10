#!/bin/sh
# Run the SYNTHETIC LMS scenario: PostgreSQL + Java LMS + Artillery, with the
# collector sampling the LMS JVM. Everything runs on an internal Docker network
# that is removed afterwards.
#
#   sh examples/lms-load/run.sh [--leak none|connection|session|connection,session]
#                               [--sessions 100] [--minutes 5] [--out DIR]
#
# Results in DIR (default ./lms-out-<leak>):
#   gc_samples_*.csv gc_azure_*.json collector_*.log  collector output
#   LMS.log                                           Unified GC log
#   artillery_report.json                             load test results
#   app_stats.json  pg_connections.txt                app pool/session and DB state at the end
#   summary.txt                                       one-screen summary
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
leak=none sessions=100 minutes=5 out=''
while [ $# -gt 0 ]; do
  case "$1" in
    --leak) leak=$2; shift 2 ;;
    --sessions) sessions=$2; shift 2 ;;
    --minutes) minutes=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$leak" in none|connection|session|connection,session|session,connection) ;; *) echo '--leak: none|connection|session|connection,session' >&2; exit 2 ;; esac
case "$sessions$minutes" in *[!0-9]*|'') echo '--sessions and --minutes must be integers' >&2; exit 2 ;; esac
command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 2; }

out=${out:-./lms-out-$(printf '%s' "$leak" | tr ',' '+')}
mkdir -p "$out"
out=$(CDPATH='' cd -- "$out" && pwd)
ramp=$(( sessions / 5 )); [ "$ramp" -ge 1 ] || ramp=1
sed -e "s/__SESSIONS__/$sessions/g" -e "s/__RAMP_SEC__/$ramp/g" "$here/load/lms-sessions.yml" > "$out/lms-sessions.yml"
sed -e "s/__DURATION_MS__/$(( minutes * 60000 ))/" "$here/load/processor.js" > "$out/processor.js"

owner="$(id -u):$(id -g)"
export LEAK_MODE="$leak" OUT_DIR="$out" OWNER="$owner"
compose() { docker compose -f "$here/compose.yaml" "$@"; }
cleanup() { compose --profile load down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "== SYNTHETIC LMS: leak=$leak sessions=$sessions minutes=$minutes out=$out"
compose up --build -d --wait db app
echo "== load: $sessions sessions for ~$minutes min (Artillery)"
compose --profile load run --rm --no-deps load > "$out/artillery_stdout.txt" 2>&1 || echo "artillery exited non-zero (see artillery_stdout.txt)"

# State at the end of the run, read through the containers (the network is internal).
# A JVM stalled by GC never answers, hence the timeouts.
compose exec -T app timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080 && printf "GET /stats HTTP/1.0\r\n\r\n" >&3 && sed "1,/^\r$/d" <&3' \
  > "$out/app_stats.json" 2>/dev/null || echo '{"error":"app not reachable (crashed?)"}' > "$out/app_stats.json"
compose exec -T db timeout 10 psql -U lms -d lms -At -c \
  "SELECT state, count(*) FROM pg_stat_activity WHERE datname = 'lms' GROUP BY state ORDER BY state" \
  > "$out/pg_connections.txt" 2>&1 || true
compose stop -t 20 app >/dev/null 2>&1 || true

{
  echo "SYNTHETIC LMS scenario  leak=$leak sessions=$sessions minutes=$minutes"
  echo "app: $(cat "$out/app_stats.json")"
  echo "postgres connections by state:"; sed 's/^/  /' "$out/pg_connections.txt"
  echo "artillery:"; grep -E 'http.codes|http.requests:|vusers.(completed|failed)|errors\.' "$out/artillery_stdout.txt" | tail -n 12 | sed 's/^/  /'
  echo "collector events:"; cat "$out"/gc_azure_*.json 2>/dev/null | grep -o '"event_name":"[A-Z_]*"' | sort | uniq -c | sed 's/^/  /'
  echo "max old_pct: $(awk -F, 'NR>1 && $8>m {m=$8} END {print m+0}' "$out"/gc_samples_*.csv 2>/dev/null)"
} > "$out/summary.txt"
cat "$out/summary.txt"
echo "== open dashboard/index.html and load every file in $out"
