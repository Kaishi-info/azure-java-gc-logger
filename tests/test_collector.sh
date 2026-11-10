#!/bin/sh
# shellcheck disable=SC2016  # single-quoted sh -c scripts expand "$1" in the child on purpose
# Collector tests with a mocked JDK (jstat / jcmd). Synthetic data only.
# Each scenario documents a normal or abnormal path; see docs/ja/testing.md.
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
collector="$root/collector/collect_gc.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
pass=0 fail=0

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # check "name" command...
  name=$1; shift
  if "$@"; then ok "$name"; else ng "$name"; fi
}

# Mock jstat: each call consumes one line of $MOCK/seq.
#   OK <OC_KiB> <OU_KiB> <FGC> <GCT>   normal sample
#   FAIL                                exit 1 with a HotSpot-like error
#   NOCOL                               output without the OC/OU columns (unsupported GC)
#   DASH                                output with "-" in a required column
# The last line repeats once the sequence is exhausted.
new_mock() {
  MOCK="$tmp/$1"
  rm -rf "$MOCK"; mkdir -p "$MOCK/bin" "$MOCK/work"
  cat > "$MOCK/bin/jstat" <<'EOF'
#!/bin/sh
seq="$MOCK/seq"; idx="$MOCK/idx"
n=$(cat "$idx" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$idx"
total=$(wc -l < "$seq")
[ "$n" -le "$total" ] || n=$total
line=$(sed -n "${n}p" "$seq")
set -- $line
case "$1" in
  OK)
    echo 'S0C S1C S0U S1U EC EU OC OU MC MU CCSC CCSU YGC YGCT FGC FGCT CGC CGCT GCT'
    echo "1024 1024 100 200 2048 1500 $2 $3 16384 9000 1024 700 4 0.3 $4 0.2 0 0 $5" ;;
  NOCOL)
    echo 'S0C S1C S0U S1U EC EU MC MU YGC FGC GCT'
    echo '0 0 0 0 0 0 1 1 1 0 0.1' ;;
  DASH)
    echo 'S0C S1C S0U S1U EC EU OC OU MC MU CCSC CCSU YGC YGCT FGC FGCT CGC CGCT GCT'
    echo '1024 1024 100 200 2048 1500 - - 16384 9000 1024 700 4 0.3 1 0.2 0 0 0.5' ;;
  *)
    echo "$2: sun.jvmstat.monitor.MonitorException: $2 not found" >&2
    echo "Caused by: java.lang.IllegalArgumentException: Could not map vmid to user Name" >&2
    exit 1 ;;
esac
EOF
  cat > "$MOCK/bin/jcmd" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-l" ] || exit 1
cat "$MOCK/jcmd.txt" 2>/dev/null
EOF
  cat > "$MOCK/bin/hostname" <<'EOF'
#!/bin/sh
echo "app-test01.example.internal"
EOF
  chmod +x "$MOCK/bin/"*
  printf '%s\n' '321 com.example.SyntheticApp -Ddb.password=SECRET_SHOULD_NOT_LEAK' '999 jdk.jcmd/sun.tools.jcmd.JCmd -l' > "$MOCK/jcmd.txt"  # public-content: allow (fake secret, must never be copied)
  : > "$MOCK/seq"
  export MOCK
}
seq_add() { printf '%s\n' "$@" >> "$MOCK/seq"; }
run() { # run [--mode] [VAR=val...] ; runs in $MOCK/work, captures rc/stdout/stderr
  mode=''
  case "${1:-}" in --*) mode=$1; shift ;; esac
  # shellcheck disable=SC2086  # $mode is empty or one word
  (cd "$MOCK/work" && env PATH="$MOCK/bin:$PATH" OUTPUT_DIR="$MOCK/work/out" INTERVAL_SEC=0 "$@" \
     sh "$collector" $mode > "$MOCK/stdout" 2> "$MOCK/stderr" < "${STDIN_FILE:-/dev/null}")
  echo $? > "$MOCK/rc"
}
rc() { cat "$MOCK/rc"; }
json() { cat "$MOCK"/work/out/gc_azure_*.json 2>/dev/null; }
csv() { cat "$MOCK"/work/out/gc_samples_*.csv 2>/dev/null; }
count() { json | grep -c "\"event_name\":\"$1\""; }

# 1. Normal: threshold crossing emits OLD_HIGH once; files are private.
new_mock normal
seq_add 'OK 10240 9318.4 1 0.5'
run PID=321 HOST_LABEL=APP01 SAMPLES=5 HIGH_PCT=85
check 'normal: exit 0' [ "$(rc)" = 0 ]
check 'normal: header + 5 CSV rows' [ "$(csv | wc -l | tr -d ' ')" = 6 ]
check 'normal: 5 metric records' [ "$(json | grep -c '"record_type":"metric"')" = 5 ]
check 'normal: exactly one OLD_HIGH' [ "$(count JAVA_GC_OLD_HIGH)" = 1 ]
check 'normal: STARTED and STOPPED events' [ "$(count JAVA_GC_COLLECTOR_STARTED)$(count JAVA_GC_COLLECTOR_STOPPED)" = 11 ]
check 'normal: old_pct within 85..100' awk -F, 'NR==2 { exit !($2=="APP01" && $8>=85 && $8<=100) }' "$(ls "$MOCK"/work/out/gc_samples_*.csv)"
check 'normal: every NDJSON line is a JSON object' sh -c 'cat "$1"/work/out/gc_azure_*.json | grep -vc "^{.*}$" | grep -qx 0' _ "$MOCK"
check 'normal: output files are mode 600' sh -c '[ -z "$(find "$1/work/out" -type f ! -perm 600)" ]' _ "$MOCK"
check 'normal: timestamps are UTC (Z suffix)' sh -c 'csv=$(ls "$1"/work/out/gc_samples_*.csv); awk -F, "NR>1 && \$1 !~ /Z\$/ {exit 1}" "$csv"' _ "$MOCK"

# 2. Recovery: high for 3 samples, then below RECOVERY_PCT for 3 samples.
new_mock recovery
seq_add 'OK 10240 9500 1 0.5' 'OK 10240 9500 1 0.5' 'OK 10240 9500 1 0.5' \
        'OK 10240 5000 2 0.9' 'OK 10240 5000 2 0.9' 'OK 10240 5000 2 0.9'
run PID=321 HOST_LABEL=APP01 SAMPLES=6
check 'recovery: OLD_HIGH then OLD_RECOVERED' [ "$(count JAVA_GC_OLD_HIGH)$(count JAVA_GC_OLD_RECOVERED)" = 11 ]
check 'recovery: fgc_delta=1 recorded' sh -c 'grep -q "\"fgc_delta\":1}" "$1"/work/out/gc_azure_*.json' _ "$MOCK"
check 'recovery: gct_delta_ms=400 recorded' sh -c 'grep -q "\"gct_delta_ms\":400," "$1"/work/out/gc_azure_*.json' _ "$MOCK"

# 3. Hysteresis: oscillating between thresholds must not flap.
new_mock hysteresis
seq_add 'OK 10240 9500 1 0.5' 'OK 10240 9500 1 0.5' 'OK 10240 9500 1 0.5' \
        'OK 10240 8000 1 0.5' 'OK 10240 9500 1 0.5' 'OK 10240 8000 1 0.5'
run PID=321 HOST_LABEL=APP01 SAMPLES=6
check 'hysteresis: one OLD_HIGH, no RECOVERED between 75% and 85%' [ "$(count JAVA_GC_OLD_HIGH)$(count JAVA_GC_OLD_RECOVERED)" = 10 ]

# 4. Counter reset: FGC goes backwards (JVM restarted under the same PID).
new_mock reset
seq_add 'OK 10240 5000 5 2.0' 'OK 10240 5000 1 0.1'
run PID=321 HOST_LABEL=APP01 SAMPLES=2
check 'reset: COUNTER_RESET emitted' [ "$(count JAVA_GC_COUNTER_RESET)" = 1 ]
check 'reset: no negative deltas written' sh -c '! grep -q "delta[a-z_]*\":-" "$1"/work/out/gc_azure_*.json' _ "$MOCK"

# 5. One missed sample: recorded as SAMPLE_MISSED, not filled with zeros.
new_mock missed
seq_add 'OK 10240 5000 1 0.5' 'FAIL' 'OK 10240 5000 1 0.5'
run PID=321 HOST_LABEL=APP01 SAMPLES=3
check 'missed: exit 0' [ "$(rc)" = 0 ]
check 'missed: SAMPLE_MISSED once' [ "$(count JAVA_GC_SAMPLE_MISSED)" = 1 ]
check 'missed: only 2 metric rows (no zero fill)' [ "$(json | grep -c '"record_type":"metric"')" = 2 ]
check 'missed: jstat stderr kept in collector log' sh -c 'grep -q "Could not map vmid" "$1"/work/out/collector_*.log' _ "$MOCK"

# 6. JVM gone: 3 consecutive failures stop the collector and instruct the operator.
new_mock failed
seq_add 'FAIL'
run PID=321 HOST_LABEL=APP01 SAMPLES=10
check 'failed: exit 3' [ "$(rc)" = 3 ]
check 'failed: COLLECTOR_FAILED once' [ "$(count JAVA_GC_COLLECTOR_FAILED)" = 1 ]
check 'failed: operator told to run --collect-logs' grep -q -- '--collect-logs' "$MOCK/stderr"
check 'failed: Japanese operator notice' grep -q 'オペレーターの方へ' "$MOCK/stderr"

# 7. Unsupported jstat layout (missing OC/OU) and "-" values are failures, not zeros.
new_mock nocol
seq_add 'NOCOL'
run PID=321 HOST_LABEL=APP01 SAMPLES=5
check 'nocol: exit 3 with reason' sh -c '[ "$(cat "$1/rc")" = 3 ] && grep -q "lacks required columns" "$1"/work/out/gc_azure_*.json' _ "$MOCK"
new_mock dash
seq_add 'DASH'
run PID=321 HOST_LABEL=APP01 SAMPLES=5
check 'dash: non-numeric values rejected' grep -q 'non-numeric' "$MOCK/stderr"

# 8. Invalid settings are rejected before anything is written.
new_mock invalid
seq_add 'OK 10240 5000 1 0.5'
for bad in 'HIGH_PCT=abc' 'HIGH_PCT=150' 'RECOVERY_PCT=90' 'HOST_LABEL=bad.label' 'HOST_LABEL=a;rm' 'PID=12a' 'PID=0' 'HIGH_SAMPLES=0' 'INTERVAL_SEC=-1'; do
  run PID=321 HOST_LABEL=APP01 SAMPLES=1 "$bad"
  check "invalid: $bad -> exit 2, no output" sh -c '[ "$(cat "$1/rc")" = 2 ] && [ ! -d "$1/work/out" ]' _ "$MOCK"
done

# 9. Non-interactive start without PID refuses and points to --setup.
new_mock nopid
run SAMPLES=1
check 'nopid: exit 2 with --setup hint' sh -c '[ "$(cat "$1/rc")" = 2 ] && grep -q -- "--setup" "$1/stderr"' _ "$MOCK"

# 10. Interactive setup: detected host name, JVM list, config saved privately.
new_mock setup
seq_add 'OK 10240 5000 1 0.5'
printf '\n1\n\n60\n\n\n\n' > "$MOCK/answers"
STDIN_FILE="$MOCK/answers" run --setup
conf="$MOCK/work/gc_logger.conf"
check 'setup: exit 0' [ "$(rc)" = 0 ]
check 'setup: host label from hostname -s' grep -qx 'HOST_LABEL=app-test01' "$conf"
check 'setup: PID chosen from list' grep -qx 'PID=321' "$conf"
check 'setup: JAVA_MATCH is main class only' grep -qx 'JAVA_MATCH=com.example.SyntheticApp' "$conf"
check 'setup: JVM arguments never shown or saved' sh -c '! grep -q SECRET_SHOULD_NOT_LEAK "$1/stderr" "$2"' _ "$MOCK" "$conf"
check 'setup: jcmd itself not listed' sh -c '! grep -q JCmd "$1/stderr"' _ "$MOCK"
check 'setup: config is mode 600' sh -c '[ -z "$(find "$1" ! -perm 600)" ]' _ "$conf"
run SAMPLES=2
check 'setup: interval 60 saved' grep -qx 'INTERVAL_SEC=60' "$conf"
printf '\n1\n\n0\n' > "$MOCK/answers0"
STDIN_FILE="$MOCK/answers0" run --setup CONFIG="$MOCK/work/other.conf"
check 'setup: invalid answer at end of input aborts (no hang)' [ "$(rc)" = 2 ]
check 'setup: collection runs from saved config' [ "$(json | grep -c '"host":"app-test01"')" -ge 2 ]

# 11. Config file is data, not code.
new_mock config
seq_add 'OK 10240 5000 1 0.5'
printf '%s\n' 'PID=321' 'HOST_LABEL=APP01' 'EVIL=$(touch pwned)' 'SAMPLES=$(touch pwned2)' > "$MOCK/work/gc_logger.conf"
run
check 'config: injected commands not executed' sh -c '[ ! -e "$1/work/pwned" ] && [ ! -e "$1/work/pwned2" ]' _ "$MOCK"
check 'config: bad SAMPLES value rejected (exit 2)' [ "$(rc)" = 2 ]

# 12. PID now belongs to another program: refuse and instruct.
new_mock mismatch
seq_add 'OK 10240 5000 1 0.5'
printf '%s\n' 'PID=321' 'HOST_LABEL=APP01' 'JAVA_MATCH=com.example.OtherApp' > "$MOCK/work/gc_logger.conf"
run SAMPLES=1
check 'mismatch: exit 4' [ "$(rc)" = 4 ]
check 'mismatch: operator told to collect logs' grep -q -- '--collect-logs' "$MOCK/stderr"
check 'mismatch: no metrics sampled' [ "$(json | grep -c '"record_type":"metric"')" = 0 ]

# 13. --collect-logs bundles diagnostics without JVM arguments.
new_mock diag
seq_add 'FAIL'
printf '%s\n' 'PID=321' 'HOST_LABEL=APP01' > "$MOCK/work/gc_logger.conf"
run SAMPLES=5
run --collect-logs
archive=$(tail -n 1 "$MOCK/stdout")
check 'diag: archive created' [ -f "$archive" ]
mkdir -p "$MOCK/x" && (cd "$MOCK/x" && gzip -dc "$archive" | tar xf -)
check 'diag: contains system, java and collector logs' sh -c 'ls "$1"/x/*/system.txt "$1"/x/*/java.txt "$1"/x/*/collector_*.log >/dev/null' _ "$MOCK"
check 'diag: jstat error captured' sh -c 'grep -rq "Could not map vmid" "$1/x"' _ "$MOCK"
check 'diag: no JVM arguments in archive' sh -c '! grep -rq SECRET_SHOULD_NOT_LEAK "$1/x"' _ "$MOCK"
check 'diag: archive is mode 600' sh -c '[ -z "$(find "$1" ! -perm 600)" ]' _ "$archive"

# 14. --check prints one sample and writes nothing.
new_mock check
seq_add 'OK 10240 5120 1 0.5'
run --check PID=321 HOST_LABEL=APP01
check 'check: prints old_pct=50.00' grep -q 'old_pct=50.00' "$MOCK/stdout"
check 'check: no output directory' [ ! -d "$MOCK/work/out" ]

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
