#!/bin/sh
# Starts the synthetic LMS JVM and, next to it, the repository's collector
# (mounted read-only at /collector). Output goes to /out.
set -eu
label=${HOST_LABEL:-LMS}
mkdir -p /out

# shellcheck disable=SC2086  # JAVA_OPTS is a list of flags
java ${JAVA_OPTS:--Xmx256m} \
  "-Xlog:gc:file=/out/${label}.log:utctime,uptime,level,tags" \
  -cp /app/classes:/app/postgresql.jar LmsApp > "/out/${label}.stdout" 2>&1 &
jvm=$!

# wait until the JVM has published its perf data
i=0
until jstat -gc "$jvm" >/dev/null 2>&1 || [ "$i" -ge 30 ]; do i=$((i + 1)); sleep 1; done

PID=$jvm HOST_LABEL=$label OUTPUT_DIR=/out INTERVAL_SEC=${INTERVAL_SEC:-5} SAMPLES=0 \
  sh /collector/collect_gc.sh &
collector=$!

trap 'kill -TERM "$collector" 2>/dev/null; kill -TERM "$jvm" 2>/dev/null; wait "$jvm" 2>/dev/null; wait "$collector" 2>/dev/null; chown -R "${OWNER:-0:0}" /out; exit 0' TERM INT
wait "$jvm" || true
# JVM ended by itself (e.g. OutOfMemoryError): let the collector notice and stop.
wait "$collector" || true
chown -R "${OWNER:-0:0}" /out
