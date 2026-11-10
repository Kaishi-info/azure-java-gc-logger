#!/bin/sh
# Run the SYNTHETIC LeakyJdbc workload in a disposable container and record it
# with collector/collect_gc.sh. Nothing leaves the container except files in OUT.
#
#   sh examples/leaky-jdbc/run-docker.sh [OUT_DIR] [SECONDS]
#
# Starts two JVMs side by side in eclipse-temurin:11-jdk (-Xmx128m each):
#   LEAK  - connections leak on the error path
#   FIXED - same work with try-with-resources
# Output (host labels LEAK / FIXED, load all of it into dashboard/index.html):
#   OUT/gc_samples_*.csv, OUT/gc_azure_*.json, OUT/LEAK.log, OUT/FIXED.log
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out=${1:-./leaky-out}
seconds=${2:-120}
image=${IMAGE:-eclipse-temurin:11-jdk}
case "$seconds" in ''|*[!0-9]*) echo 'SECONDS must be an integer' >&2; exit 2;; esac
mkdir -p "$out"
out=$(CDPATH='' cd -- "$out" && pwd)
samples=$((seconds / 2 + 3))

# Runs as root inside the container: a JVM whose uid has no /etc/passwd entry
# creates no hsperfdata, and jstat then fails with "Could not map vmid to user Name".
# Output keeps umask 077; ownership is handed back to the invoking user at the end.
docker run --rm \
  -v "$root:/src:ro" -v "$out:/out" \
  -e SECONDS_RUN="$seconds" -e SAMPLES_RUN="$samples" -e OWNER="$(id -u):$(id -g)" \
  "$image" sh -eu -c '
    xlog() { echo "-Xlog:gc:file=/out/$1.log:utctime,uptime,level,tags"; }
    java -Xmx128m "$(xlog LEAK)"  /src/examples/leaky-jdbc/LeakyJdbc.java leak  "$SECONDS_RUN" 50 20 128 > /out/LEAK.stdout 2>&1 &
    leak=$!
    java -Xmx128m "$(xlog FIXED)" /src/examples/leaky-jdbc/LeakyJdbc.java fixed "$SECONDS_RUN" 50 20 128 > /out/FIXED.stdout 2>&1 &
    fixed=$!
    sleep 3   # source-launcher compile time
    PID=$leak  HOST_LABEL=LEAK  OUTPUT_DIR=/out INTERVAL_SEC=2 SAMPLES=$SAMPLES_RUN HIGH_SAMPLES=3 \
      sh /src/collector/collect_gc.sh &
    c1=$!
    PID=$fixed HOST_LABEL=FIXED OUTPUT_DIR=/out INTERVAL_SEC=2 SAMPLES=$SAMPLES_RUN HIGH_SAMPLES=3 \
      sh /src/collector/collect_gc.sh &
    c2=$!
    rc=0
    wait $c1 || rc=$?; echo "collector LEAK exit=$rc"
    rc=0
    wait $c2 || rc=$?; echo "collector FIXED exit=$rc"
    wait $leak || echo "LEAK jvm exit=$?"
    wait $fixed || echo "FIXED jvm exit=$?"
    chown -R "$OWNER" /out
  '
echo "Results in $out"
