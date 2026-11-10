#!/bin/sh
# azure-java-gc-logger collector: JDK jstat sampling, POSIX sh, no Python.
# Read-only JVM observation. It never forces GC, restarts the JVM or touches
# application state. Output is append-only and created with umask 077.
#
#   sh collect_gc.sh                 # first run on a terminal: interactive setup, then collect
#   sh collect_gc.sh --setup         # (re)create the config interactively
#   sh collect_gc.sh --check         # take one sample and print it; writes nothing
#   sh collect_gc.sh --collect-logs  # bundle diagnostics for the support contact
#   sh collect_gc.sh --help
set -u
umask 077

VERSION=0.2.0
CONFIG=${CONFIG:-./gc_logger.conf}
CONFIG_KEYS='PID HOST_LABEL OUTPUT_DIR INTERVAL_SEC SAMPLES HIGH_PCT RECOVERY_PCT HIGH_SAMPLES JAVA_MATCH'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script_path="$script_dir/$(basename -- "$0")"

say() { printf '%s\n' "$*" >&2; }
die() { code=$1; shift; say "ERROR: $*"; exit "$code"; }

usage() {
  cat <<'HELP'
Usage:
  sh collect_gc.sh                 Collect using gc_logger.conf / environment.
                                   On a terminal without a config, runs --setup first.
  sh collect_gc.sh --setup         Interactive setup: host label, Java process, thresholds.
  sh collect_gc.sh --check         One jstat sample to stdout. No files are written.
  sh collect_gc.sh --collect-logs  Create a diagnostics archive for your support contact.
  sh collect_gc.sh --version

Settings (environment overrides the config file):
  CONFIG=./gc_logger.conf  PID  HOST_LABEL  OUTPUT_DIR=./out  INTERVAL_SEC=60
  SAMPLES=0 (0 = until stopped)  HIGH_PCT=85  RECOVERY_PCT=75  HIGH_SAMPLES=3
  JAVA_MATCH  main class/jar recorded at setup; collection refuses to start if the
              PID now belongs to a different program.

Output (UTC-dated): gc_samples_YYYY-MM-DD.csv, gc_azure_YYYY-MM-DD.json (NDJSON),
                    collector_YYYY-MM-DD.log (operational log, jstat errors)
HELP
}

# ---------------------------------------------------------------- settings
load_config() {
  [ -f "$CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    # shellcheck disable=SC2034  # read through eval below
    val=${line#*=}
    case " $CONFIG_KEYS " in
      *" $key "*) eval "CFG_$key=\$val" ;;   # key is whitelisted; value is never evaluated
      *) say "WARN: ignoring unknown line in $CONFIG: $key" ;;
    esac
  done < "$CONFIG"
}

resolve_settings() {
  PID=${PID:-${CFG_PID:-}}
  HOST_LABEL=${HOST_LABEL:-${CFG_HOST_LABEL:-}}
  OUTPUT_DIR=${OUTPUT_DIR:-${CFG_OUTPUT_DIR:-./out}}
  INTERVAL_SEC=${INTERVAL_SEC:-${CFG_INTERVAL_SEC:-60}}
  SAMPLES=${SAMPLES:-${CFG_SAMPLES:-0}}
  HIGH_PCT=${HIGH_PCT:-${CFG_HIGH_PCT:-85}}
  RECOVERY_PCT=${RECOVERY_PCT:-${CFG_RECOVERY_PCT:-75}}
  HIGH_SAMPLES=${HIGH_SAMPLES:-${CFG_HIGH_SAMPLES:-3}}
  JAVA_MATCH=${JAVA_MATCH:-${CFG_JAVA_MATCH:-}}
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
is_pct() {
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  awk -v v="$1" 'BEGIN { exit !(v >= 0 && v <= 100) }'
}
is_label() {
  case "$1" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
  [ "${#1}" -le 63 ]
}
is_match() { case "$1" in *[!a-zA-Z0-9._/\$-]*) return 1 ;; esac; }

validate_settings() {
  { is_uint "$PID" && [ "$PID" -gt 0 ]; } || die 2 'PID must be a positive number. Run: sh collect_gc.sh --setup'
  is_label "$HOST_LABEL" || die 2 'HOST_LABEL: 1-63 characters of letters, digits, dash, underscore.'
  is_uint "$INTERVAL_SEC" || die 2 'INTERVAL_SEC must be a non-negative integer.'
  is_uint "$SAMPLES" || die 2 'SAMPLES must be a non-negative integer.'
  { is_uint "$HIGH_SAMPLES" && [ "$HIGH_SAMPLES" -ge 1 ]; } || die 2 'HIGH_SAMPLES must be an integer >= 1.'
  is_pct "$HIGH_PCT" || die 2 'HIGH_PCT must be a number from 0 to 100.'
  is_pct "$RECOVERY_PCT" || die 2 'RECOVERY_PCT must be a number from 0 to 100.'
  awk -v r="$RECOVERY_PCT" -v h="$HIGH_PCT" 'BEGIN { exit !(r < h) }' \
    || die 2 'RECOVERY_PCT must be lower than HIGH_PCT.'
  is_match "$JAVA_MATCH" || die 2 'JAVA_MATCH contains unsupported characters.'
  case "$OUTPUT_DIR" in ''|*'
'*) die 2 'OUTPUT_DIR is empty or contains a newline.' ;; esac
}

default_label() {
  h=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || printf unknown)
  h=${h%%.*}   # some hostname implementations ignore -s
  h=$(printf '%s' "$h" | tr -c 'a-zA-Z0-9_-' '-' | cut -c1-63)
  [ -n "$h" ] || h=unknown
  printf '%s' "$h"
}

# ------------------------------------------------------------- jvm helpers
# Lists "PID MAIN" only. JVM arguments are deliberately dropped: they can hold secrets.
list_jvms() {
  if command -v jcmd >/dev/null 2>&1; then
    jcmd -l 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 != "sun.tools.jcmd.JCmd" && $2 != "jdk.jcmd/sun.tools.jcmd.JCmd" { print $1, ($2 == "" ? "(unknown)" : $2) }'
  elif command -v jps >/dev/null 2>&1; then
    jps -l 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 != "sun.tools.jps.Jps" && $2 != "jdk.jcmd/sun.tools.jps.Jps" { print $1, ($2 == "" ? "(unknown)" : $2) }'
  fi
}
main_of() { list_jvms | awk -v p="$1" '$1 == p { print $2; exit }'; }

# On success sets $values to "old_used old_cap heap_used heap_cap old_pct fgc ygc gct".
# On failure $sample_error holds a short JSON-safe reason and the jstat stderr
# is in $jstat_err_file. Call directly (not in $(...)) so both survive.
sample_jvm() {
  sample_error='' values=''
  raw=$(LC_ALL=C jstat -gc "$PID" 2>"$jstat_err_file")
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    sample_error="jstat exit $rc"
    return 1
  fi
  out=$(printf '%s\n' "$raw" | awk '
    NR==1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    NR==2 {
      n = split("OC OU EC EU S0C S0U S1C S1U FGC YGC GCT", f, " ")
      for (i = 1; i <= n; i++) if (!(f[i] in col)) { bad = 3; exit }
      for (i = 1; i <= n; i++) if ($(col[f[i]]) !~ /^[0-9.]+$/) { bad = 4; exit }
      oCap = $(col["OC"]) + 0; oUse = $(col["OU"]) + 0
      if (oCap <= 0) { bad = 5; exit }
      hCap = oCap + $(col["EC"]) + $(col["S0C"]) + $(col["S1C"])
      hUse = oUse + $(col["EU"]) + $(col["S0U"]) + $(col["S1U"])
      printf "%.3f %.3f %.3f %.3f %.2f %.0f %.0f %.3f\n", oUse/1024, oCap/1024, hUse/1024, hCap/1024, 100*oUse/oCap, $(col["FGC"]), $(col["YGC"]), $(col["GCT"])
      seen = 1
    }
    END { if (bad) exit bad; if (!seen) exit 6 }  # exit in END overrides, so carry the reason')
  rc=$?
  case "$rc" in
    0) values=$out; return 0 ;;
    3) sample_error='jstat output lacks required columns' ;;
    4) sample_error='jstat output has non-numeric values' ;;
    5) sample_error='old generation capacity is zero' ;;
    *) sample_error='jstat output could not be parsed' ;;
  esac
  printf '%s\n' "$raw" >> "$jstat_err_file"
  return 1
}

operator_notice() {
  # $1: reason (short, English) $2: reason (Japanese)
  say ''
  say '=================================================================='
  say ' オペレーターの方へ / To the operator'
  say " GC 収集を停止しました: $2"
  say " Collection stopped: $1"
  say ''
  say ' 次のコマンドでログを回収し、作成されたファイルを担当者に渡してください。'
  say ' Collect logs with the command below and send the file it prints to your support contact.'
  say ''
  if [ "$CONFIG" = ./gc_logger.conf ]; then
    say "   cd '$(pwd)' && sh '$script_path' --collect-logs"
  else
    say "   cd '$(pwd)' && CONFIG='$CONFIG' sh '$script_path' --collect-logs"
  fi
  say '=================================================================='
}

# ------------------------------------------------------------------- setup
_eof=0
ask() {
  # ask VAR "prompt" "default"; on end of input the default is taken
  printf '%s [%s]: ' "$2" "$3" >&2
  if ! IFS= read -r _ans; then _ans=''; _eof=1; printf '\n' >&2; fi
  [ -n "$_ans" ] || _ans=$3
  eval "$1=\$_ans"
}
# Called when an answer is invalid: after end of input, retrying would loop forever.
retry() {
  [ "$_eof" -eq 0 ] || die 2 'setup aborted: input ended with an invalid answer / 入力が終わりました'
  [ -z "${1:-}" ] || say "  $1"
}

setup() {
  say "== azure-java-gc-logger $VERSION セットアップ / setup =="
  say "設定ファイル / config: $CONFIG"
  say ''
  command -v jstat >/dev/null 2>&1 || {
    operator_notice 'jstat not found (a JDK, not a JRE, is required)' 'jstat が見つかりません（JRE ではなく JDK が必要です）'
    exit 3
  }

  detected=$(default_label)
  while :; do
    ask HOST_LABEL 'ホスト名ラベル / host label' "${HOST_LABEL:-$detected}"
    is_label "$HOST_LABEL" && break
    retry '英数字・ハイフン・アンダースコアのみ、63 文字まで / letters, digits, - and _ only'
  done

  jvms=$(list_jvms)
  me=$(id -un 2>/dev/null || id -u)
  if [ -z "$jvms" ]; then
    say ''
    say "ユーザー $me から見える Java プロセスがありません / no JVM visible to user $me."
    say '  よくある原因 / common causes:'
    say '  - JVM と別のユーザーで実行している / running as a different user than the JVM'
    say '  - コンテナで /etc/passwd に無い uid で JVM が動いている / container uid without a passwd entry'
    say '  - JVM が -XX:-UsePerfData で起動されている / JVM started with -XX:-UsePerfData'
    default_pid=${PID:-}
  else
    say ''
    say "ユーザー $me から見える Java プロセス / JVMs visible to $me:"
    printf '%s\n' "$jvms" | awk '{ printf "  %d) PID %-8s %s\n", NR, $1, $2 }' >&2
    default_pid=1
  fi
  choice=''
  while :; do
    ask choice '番号または PID / number or PID' "$default_pid"
    if is_uint "$choice" && [ -n "$jvms" ] && [ "$choice" -ge 1 ] && [ "$choice" -le "$(printf '%s\n' "$jvms" | wc -l)" ]; then
      PID=$(printf '%s\n' "$jvms" | awk -v n="$choice" 'NR == n { print $1 }')
    else
      PID=$choice
    fi
    is_uint "$PID" && [ "$PID" -gt 0 ] && break
    retry '数字で入力してください / enter a number'
  done
  JAVA_MATCH=$(main_of "$PID")
  is_match "$JAVA_MATCH" || JAVA_MATCH=''

  ask OUTPUT_DIR '出力先 / output directory' "$OUTPUT_DIR"
  while :; do ask INTERVAL_SEC '間隔(秒) / interval seconds' "$INTERVAL_SEC"; is_uint "$INTERVAL_SEC" && [ "$INTERVAL_SEC" -ge 1 ] && break; retry '1 以上の整数 / integer >= 1'; done
  while :; do ask HIGH_PCT 'Old 使用率の注意しきい値(%) / high threshold %' "$HIGH_PCT"; is_pct "$HIGH_PCT" && break; retry '0〜100 / 0 to 100'; done
  while :; do
    ask RECOVERY_PCT '回復しきい値(%) / recovery threshold %' "$RECOVERY_PCT"
    is_pct "$RECOVERY_PCT" && awk -v r="$RECOVERY_PCT" -v h="$HIGH_PCT" 'BEGIN { exit !(r < h) }' && break
    retry "$HIGH_PCT より小さい値にしてください / must be lower than $HIGH_PCT"
  done
  while :; do ask HIGH_SAMPLES '連続回数 / consecutive samples' "$HIGH_SAMPLES"; is_uint "$HIGH_SAMPLES" && [ "$HIGH_SAMPLES" -ge 1 ] && break; retry '1 以上の整数 / integer >= 1'; done

  say ''
  say "テスト採取 / test sample: jstat -gc $PID"
  mkdir -p "$OUTPUT_DIR" || die 2 "cannot create $OUTPUT_DIR"
  jstat_err_file="$OUTPUT_DIR/.jstat_last_error"
  if sample_jvm; then
    # shellcheck disable=SC2086
      set -- $values
    say "  OK: old ${5}% (${1} / ${2} MiB), heap ${3} / ${4} MiB, FGC $6, YGC $7"
  else
    say "  NG: $sample_error"
    sed -n '1,5p' "$jstat_err_file" | sed 's/^/    /' >&2
    operator_notice "test sample failed ($sample_error)" "テスト採取に失敗しました（${sample_error}）"
    exit 3
  fi

  tmp="$CONFIG.tmp.$$"
  {
    printf '# azure-java-gc-logger config, written by --setup %s UTC\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for k in $CONFIG_KEYS; do eval "printf '%s=%s\n' \"\$k\" \"\$$k\""; done
  } > "$tmp" || die 2 "cannot write $tmp"
  mv "$tmp" "$CONFIG" || die 2 "cannot write $CONFIG"
  say ''
  say "保存しました / saved: $CONFIG"
  say "常時稼働の例 / to run continuously: see collector/systemd/java-gc-logger.service"
}

# ------------------------------------------------------------ collect-logs
collect_logs() {
  [ -n "$HOST_LABEL" ] || HOST_LABEL=$(default_label)
  is_label "$HOST_LABEL" || HOST_LABEL=unknown
  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  mkdir -p "$OUTPUT_DIR" || die 2 "cannot create $OUTPUT_DIR"
  d="$OUTPUT_DIR/diag_${HOST_LABEL}_$stamp"
  mkdir -p "$d" || die 2 "cannot create $d"
  {
    echo "collector_version=$VERSION"
    echo "collected_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "uname=$(uname -srm 2>/dev/null)"
    echo "user=$(id -un 2>/dev/null) uid=$(id -u) gid=$(id -g)"
    echo "umask=$(umask)"
    echo "config_path=$CONFIG"
    echo "pid=$PID host_label=$HOST_LABEL output_dir=$OUTPUT_DIR interval_sec=$INTERVAL_SEC"
    echo "high_pct=$HIGH_PCT recovery_pct=$RECOVERY_PCT high_samples=$HIGH_SAMPLES java_match=$JAVA_MATCH"
  } > "$d/system.txt"
  {
    for c in jstat jcmd jps java awk; do printf '%s: %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo 'not found')"; done
    echo '--- java -version'
    java -version 2>&1 | sed -n '1,5p'
    echo '--- JVMs visible to this user (PID and main class only; arguments omitted)'
    list_jvms
    echo '--- hsperfdata directories'
    ls -ld "${TMPDIR:-/tmp}" "${TMPDIR:-/tmp}"/hsperfdata_* 2>&1
    if is_uint "$PID" && [ -n "$PID" ]; then
      echo "--- process $PID (command name only)"
      ps -o pid= -o user= -o etime= -o comm= -p "$PID" 2>&1
      echo "--- jstat -gc $PID"
      LC_ALL=C jstat -gc "$PID" 2>&1 | sed -n '1,20p'
    fi
  } > "$d/java.txt" 2>&1
  copy_tail() { # pattern keep_files keep_lines
    # shellcheck disable=SC2012,SC2086  # glob pattern in $1 is intended; names are our own
    ls -1 "$OUTPUT_DIR"/$1 2>/dev/null | tail -n "$2" | while IFS= read -r f; do
      tail -n "$3" "$f" > "$d/$(basename "$f")"
    done
  }
  copy_tail 'collector_*.log' 3 500
  copy_tail 'gc_samples_*.csv' 2 200
  copy_tail 'gc_azure_*.json' 2 200
  [ -f "$OUTPUT_DIR/.jstat_last_error" ] && sed -n '1,50p' "$OUTPUT_DIR/.jstat_last_error" > "$d/jstat_last_error.txt"

  archive="$d.tar.gz"
  if (cd "$OUTPUT_DIR" && tar cf - "$(basename "$d")" | gzip -c > "$(basename "$archive")") 2>/dev/null; then
    rm -rf "$d"
    result=$archive
  else
    rm -f "$archive"
    result=$d
  fi
  say ''
  say '=================================================================='
  say ' ログを回収しました / Diagnostics collected:'
  say "   $result"
  say ' このファイルを担当者に渡してください。中身はテキストのみです。'
  say ' Send this file to your support contact. It contains text only.'
  say ' ホスト名・PID・時刻を含みます。JVM の起動引数やヒープの中身は含みません。'
  say ' It includes host label, PID and timestamps; no JVM arguments or heap content.'
  say '=================================================================='
  printf '%s\n' "$result"
}

# --------------------------------------------------------------------- run
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$OUTPUT_DIR/collector_$(date -u '+%Y-%m-%d').log"; }
emit_event() {
  # emit_event NAME [extra JSON fields, already JSON-safe]
  printf '{"record_type":"event","timestamp_utc":"%s","host":"%s","pid":%s,"event_name":"%s"%s}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$HOST_LABEL" "$PID" "$1" "${2:-}" >> "$OUTPUT_DIR/gc_azure_$(date -u '+%Y-%m-%d').json"
}

collect() {
  mkdir -p "$OUTPUT_DIR" || die 2 "cannot create $OUTPUT_DIR"
  jstat_err_file="$OUTPUT_DIR/.jstat_last_error"
  command -v jstat >/dev/null 2>&1 || {
    log 'jstat not found in PATH'
    operator_notice 'jstat not found (a JDK, not a JRE, is required)' 'jstat が見つかりません（JRE ではなく JDK が必要です）'
    exit 2
  }
  if [ -n "$JAVA_MATCH" ]; then
    now=$(main_of "$PID")
    if [ "$now" != "$JAVA_MATCH" ]; then
      log "PID $PID is '${now:-not visible}', expected '$JAVA_MATCH'"
      emit_event JAVA_GC_COLLECTOR_FAILED ',"detail":"PID does not match the configured Java program"'
      operator_notice "PID $PID is not $JAVA_MATCH any more (JVM restarted?)" \
        "PID $PID は設定時の Java プログラム（${JAVA_MATCH}）ではありません（JVM 再起動の可能性）。--setup で選び直すか、ログを回収してください"
      exit 4
    fi
  fi

  log "start version=$VERSION pid=$PID label=$HOST_LABEL interval=$INTERVAL_SEC samples=$SAMPLES high=$HIGH_PCT recovery=$RECOVERY_PCT streak=$HIGH_SAMPLES match=${JAVA_MATCH:-none}"
  emit_event JAVA_GC_COLLECTOR_STARTED ",\"detail\":\"collector $VERSION interval ${INTERVAL_SEC}s\""
  trap 'log "stopped by signal"; emit_event JAVA_GC_COLLECTOR_STOPPED ",\"detail\":\"signal\""; exit 0' INT TERM HUP

  n=0 failures=0 high_streak=0 normal_streak=0 pressure_active=0 prev_fgc='' prev_gct=''
  while :; do
    n=$((n + 1))
    utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    day=$(date -u '+%Y-%m-%d')
    csv="$OUTPUT_DIR/gc_samples_$day.csv"
    jsonl="$OUTPUT_DIR/gc_azure_$day.json"
    [ -f "$csv" ] || printf '%s\n' 'timestamp_utc,host,pid,old_used_mib,old_capacity_mib,heap_used_mib,heap_capacity_mib,old_pct,fgc_total,ygc_total,gct_total_s,gct_delta_ms,fgc_delta' >> "$csv"

    if sample_jvm; then
      failures=0
      # Word splitting is intended: $values holds exactly eight numbers.
      # shellcheck disable=SC2086
      set -- $values
      old_used=$1 old_capacity=$2 heap_used=$3 heap_capacity=$4 old_pct=$5 fgc=$6 ygc=$7 gct=$8
      gct_delta_ms=0 fgc_delta=0
      if [ -n "$prev_fgc" ]; then
        fgc_delta=$((fgc - prev_fgc))
        if [ "$fgc_delta" -lt 0 ]; then
          log "FGC counter moved backward ($prev_fgc -> $fgc)"
          emit_event JAVA_GC_COUNTER_RESET
          fgc_delta=0
        fi
        gct_delta_ms=$(awk -v now="$gct" -v prev="$prev_gct" 'BEGIN { v = (now - prev) * 1000; if (v < 0) v = 0; printf "%.0f", v }')
      fi
      prev_fgc=$fgc prev_gct=$gct
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$utc" "$HOST_LABEL" "$PID" "$old_used" "$old_capacity" "$heap_used" "$heap_capacity" "$old_pct" "$fgc" "$ygc" "$gct" "$gct_delta_ms" "$fgc_delta" >> "$csv"
      printf '{"record_type":"metric","timestamp_utc":"%s","host":"%s","pid":%s,"old_pct":%s,"old_used_mib":%s,"old_capacity_mib":%s,"heap_used_mib":%s,"heap_capacity_mib":%s,"gct_delta_ms":%s,"fgc_delta":%s}\n' \
        "$utc" "$HOST_LABEL" "$PID" "$old_pct" "$old_used" "$old_capacity" "$heap_used" "$heap_capacity" "$gct_delta_ms" "$fgc_delta" >> "$jsonl"

      if awk -v n="$old_pct" -v t="$HIGH_PCT" 'BEGIN { exit !(n >= t) }'; then high_streak=$((high_streak + 1)); else high_streak=0; fi
      if awk -v n="$old_pct" -v t="$RECOVERY_PCT" 'BEGIN { exit !(n < t) }'; then normal_streak=$((normal_streak + 1)); else normal_streak=0; fi
      if [ "$pressure_active" -eq 0 ] && [ "$high_streak" -ge "$HIGH_SAMPLES" ]; then
        pressure_active=1
        emit_event JAVA_GC_OLD_HIGH ",\"old_pct\":$old_pct,\"consecutive_samples\":$high_streak"
      fi
      if [ "$pressure_active" -eq 1 ] && [ "$normal_streak" -ge "$HIGH_SAMPLES" ]; then
        pressure_active=0
        emit_event JAVA_GC_OLD_RECOVERED ",\"old_pct\":$old_pct"
      fi
    else
      failures=$((failures + 1))
      log "sample failed ($failures/3): $sample_error"
      sed -n '1,10p' "$jstat_err_file" 2>/dev/null | sed 's/^/    /' >> "$OUTPUT_DIR/collector_$day.log"
      if [ "$failures" -ge 3 ]; then
        emit_event JAVA_GC_COLLECTOR_FAILED ",\"detail\":\"jstat failed 3 consecutive samples: $sample_error\""
        log 'stopping after 3 consecutive failures'
        say "ERROR: jstat failed 3 consecutive times for PID=$PID ($sample_error); stopping."
        operator_notice "jstat failed 3 times in a row for PID $PID ($sample_error)" \
          "PID $PID の jstat が 3 回連続で失敗しました（JVM の停止・再起動、権限の変化など）"
        exit 3
      fi
      # Not filled with zeros: the gap is recorded as an event instead.
      emit_event JAVA_GC_SAMPLE_MISSED ",\"detail\":\"$sample_error\""
    fi

    if [ "$SAMPLES" -gt 0 ] && [ "$n" -ge "$SAMPLES" ]; then
      log "finished after $n samples"
      emit_event JAVA_GC_COLLECTOR_STOPPED ',"detail":"sample count reached"'
      break
    fi
    sleep "$INTERVAL_SEC" || exit 0
  done
}

# -------------------------------------------------------------------- main
mode=run
case "${1:-}" in
  '') ;;
  --help|-h) usage; exit 0 ;;
  --version) echo "$VERSION"; exit 0 ;;
  --setup) mode=setup ;;
  --check) mode=check ;;
  --collect-logs) mode=collect ;;
  *) usage >&2; exit 2 ;;
esac

load_config
resolve_settings

case "$mode" in
  setup)
    setup
    exit 0
    ;;
  collect)
    collect_logs
    exit 0
    ;;
  check)
    [ -n "$HOST_LABEL" ] || HOST_LABEL=$(default_label)
    validate_settings
    command -v jstat >/dev/null 2>&1 || die 2 'jstat not found (JDK required).'
    jstat_err_file=$(mktemp 2>/dev/null || echo "/tmp/gc_logger_check.$$")
    if sample_jvm; then
      rm -f "$jstat_err_file"
      # shellcheck disable=SC2086
      set -- $values
      echo "pid=$PID main=${JAVA_MATCH:-?} old_pct=$5 old_used_mib=$1 old_capacity_mib=$2 heap_used_mib=$3 heap_capacity_mib=$4 fgc=$6 ygc=$7 gct_s=$8"
      exit 0
    fi
    say "ERROR: $sample_error"
    sed -n '1,5p' "$jstat_err_file" >&2
    rm -f "$jstat_err_file"
    exit 3
    ;;
esac

if [ -z "$PID" ]; then
  if [ -t 0 ] && [ -t 2 ]; then
    say '設定がありません。対話セットアップを始めます / No config yet: starting interactive setup.'
    setup
    printf '%s' '今すぐ収集を始めますか / start collecting now? [Y/n]: ' >&2
    IFS= read -r go || go=n
    case "$go" in n|N|no|NO) exit 0 ;; esac
  else
    die 2 "no PID configured. Run interactively once: sh $script_path --setup"
  fi
fi
[ -n "$HOST_LABEL" ] || HOST_LABEL=$(default_label)
validate_settings
collect
