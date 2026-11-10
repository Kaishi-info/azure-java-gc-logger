#!/bin/sh
# Run every check that CI runs, on a development machine.
#   sh tests/run_all.sh            fast checks (no Docker)
#   sh tests/run_all.sh --docker   also real-JVM scenarios in Docker (several minutes)
#   sh tests/run_all.sh --docker --lms   plus the LMS 100-session scenarios (~15 minutes)
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 2
status=0
step() { printf '\n== %s\n' "$1"; shift; if "$@"; then echo "-- ok"; else echo "-- FAILED: $*"; status=1; fi; }

if command -v shellcheck >/dev/null 2>&1; then
  step 'shellcheck' shellcheck -s sh collector/collect_gc.sh tests/*.sh examples/leaky-jdbc/run-docker.sh examples/lms-load/run.sh examples/lms-load/app/entrypoint.sh
else
  echo '== shellcheck not installed: skipped (CI runs it)'
fi
step 'public content check' sh tests/check_public_content.sh
for sh_impl in sh dash bash; do
  command -v "$sh_impl" >/dev/null 2>&1 && step "collector tests ($sh_impl)" "$sh_impl" tests/test_collector.sh
done
if command -v node >/dev/null 2>&1; then step 'dashboard tests' node tests/test_dashboard.cjs; else echo '== node not installed: dashboard tests skipped'; status=1; fi
if [ "${1:-}" = "--docker" ]; then
  step 'real JVM scenarios (Docker)' sh tests/test_real_jvm.sh
fi
if [ "${1:-}" = "--lms" ] || [ "${2:-}" = "--lms" ]; then
  step 'LMS 100-session scenarios (Docker, ~15 min)' sh tests/test_lms_scenario.sh
fi
echo
[ "$status" -eq 0 ] && echo 'ALL CHECKS PASSED' || echo 'SOME CHECKS FAILED'
exit "$status"
