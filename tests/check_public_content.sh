#!/bin/sh
# Public-repository content check (AGENTS.md: "inspect new files for leaked
# secrets, real host IDs, private incident detail, and unwanted remote
# connections"). Fails on anything that should not be published. A line that must contain a
# flagged string on purpose (test fixtures) ends with: public-content: allow
#   sh tests/check_public_content.sh
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 2
failed=$(mktemp)
trap 'rm -f "$failed"' EXIT
# report runs at the end of a pipe (a subshell), so failures are recorded in a file.
report() { printf 'FAIL  %s\n' "$1"; sed 's/^/      /'; echo x >> "$failed"; }

files=$(git ls-files --cached --others --exclude-standard 2>/dev/null || find . -type f ! -path './.git/*')
self=tests/check_public_content.sh

scan() { # scan "description" "ERE" [path filter ERE]
  hits=$(printf '%s\n' "$files" | grep -Ev "^($self)$" | grep -E "${3:-.}" | while IFS= read -r f; do
    [ -f "$f" ] && grep -EnI -- "$2" "$f" /dev/null 2>/dev/null
  done | grep -v 'public-content: allow')
  [ -z "$hits" ] || printf '%s\n' "$hits" | report "$1"
}

# Secrets and identifiers
scan 'private keys' '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan 'cloud or VCS tokens' '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk_live_[A-Za-z0-9]{10,}|AccountKey=[A-Za-z0-9+/=]{20,}|SharedAccessSignature=|sig=[A-Za-z0-9%]{30,})'
scan 'Azure subscription/tenant GUIDs' '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
scan 'Azure resource IDs' '/subscriptions/[0-9a-fA-F-]{36}'
scan 'password assignments with a value' '(password|passwd|pwd)[A-Za-z_]*["'"'"' ]*[:=] *["'"'"']?[A-Za-z0-9!@#$%^&*]{6,}' '\.(sh|java|ya?ml|json|kql|html|cjs|sql|conf|service)$'
scan 'private IPv4 addresses' '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
# Organisation-specific wording must stay out of code and examples (AGENTS.md rule 6)
scan 'institution or student wording in code/examples' '(学生|答案|大学|[Ss]tudent ?ID|[Uu]niversity|[Kk]aishi|開志|moodle|Moodle)' '^(collector|dashboard|azure|examples|tests)/'
# Offline dashboard: no remote resources
scan 'remote resources in the dashboard' '(https?://|fetch\(|XMLHttpRequest|WebSocket|sendBeacon|<script[^>]+src=)' '^dashboard/'
# Data files must be synthetic fixtures only
data=$(printf '%s\n' "$files" | grep -E '\.(csv|ndjson|jsonl|log|hprof|tar\.gz)$|(^|/)gc_(samples|azure)_' | grep -v '^tests/fixtures/')
[ -z "$data" ] || printf '%s\n' "$data" | report 'log/data files outside tests/fixtures (real logs must never be committed)'

if [ -s "$failed" ]; then exit 1; fi
echo 'PASS  public content check'
