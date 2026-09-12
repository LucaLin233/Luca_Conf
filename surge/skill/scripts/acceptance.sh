#!/bin/sh
# Non-destructive acceptance test for Minis Surge CLI.
set -eu
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CLI="${SURGE_CLI_BIN:-surge-cli}"
TMP="$(mktemp -d /tmp/surge-cli-accept.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }
json_check() {
  python3 - "$1" <<'PY' || fail "$2 returned invalid or error JSON"
import json,sys
x=json.load(open(sys.argv[1]))
assert not (isinstance(x,dict) and x.get("error")), x.get("error") if isinstance(x,dict) else ""
PY
  pass "$2 JSON"
}

command -v python3 >/dev/null || fail "python3 is unavailable"
command -v "$CLI" >/dev/null || fail "surge-cli is not installed"
python3 - "$SELF_DIR/surge_cli.py" "$SELF_DIR/surge_ios.py" "$SELF_DIR/adapt_upstream_reference.py" <<'PY'
import sys
for name in sys.argv[1:]:
    source=open(name,encoding="utf-8").read()
    compile(source,name,"exec")
PY
pass "Python syntax"

"$CLI" --raw version > "$TMP/version.json"; json_check "$TMP/version.json" "version"
cat > "$TMP/minimal.conf" <<'EOF'
[General]
loglevel = notify

[Rule]
FINAL,DIRECT
EOF
"$CLI" --check "$TMP/minimal.conf" > "$TMP/check.txt"
grep -qx 'OK' "$TMP/check.txt" || fail "official profile validation service check failed"
pass "official profile validation service"
if [ -n "${SURGE_HTTP_API_KEY:-}" ]; then
  python3 "$SELF_DIR/surge_ios.py" metrics > "$TMP/metrics.txt"
  grep -q '^# TYPE surge_build_info gauge$' "$TMP/metrics.txt" || fail "Prometheus metrics output is invalid"
  pass "Prometheus metrics endpoint"
fi
python3 - "$TMP/version.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assert x.get("controller-protocol",0)>=20, "Controller Protocol 20+ required"
assert x.get("system") in ("iOS","macOS"), "Unexpected Surge platform"
PY
pass "Controller handshake and capability"

"$CLI" --raw status > "$TMP/status.json"; json_check "$TMP/status.json" "status"
"$CLI" --raw summary > "$TMP/summary.json"; json_check "$TMP/summary.json" "summary"
"$CLI" --raw dump performance > "$TMP/performance.json"; json_check "$TMP/performance.json" "dump performance"
"$CLI" --raw rule match example.com > "$TMP/rule.json"; json_check "$TMP/rule.json" "rule match"
"$CLI" --raw rule temp list > "$TMP/temp-rules.json"; json_check "$TMP/temp-rules.json" "temporary rule list"
"$CLI" --raw dns lookup example.com > "$TMP/dns.json"; json_check "$TMP/dns.json" "dns lookup"
"$CLI" --raw feature list > "$TMP/features.json"; json_check "$TMP/features.json" "feature list"
"$CLI" --raw module list > "$TMP/modules.json"; json_check "$TMP/modules.json" "module list"

if command -v timeout >/dev/null; then
  timeout 3 "$CLI" --raw watch speed > "$TMP/watch.jsonl" 2>/dev/null || code=$?
  code=${code:-0}
  [ "$code" -eq 0 ] || [ "$code" -eq 124 ] || [ "$code" -eq 143 ] || fail "watch speed failed"
  sed -n '1p' "$TMP/watch.jsonl" > "$TMP/watch-first.json"
  [ -s "$TMP/watch-first.json" ] || fail "watch speed produced no subscription frame"
  json_check "$TMP/watch-first.json" "watch speed first frame"
fi

printf '\nAcceptance passed: read-only commands only; no Surge settings were changed.\n'
