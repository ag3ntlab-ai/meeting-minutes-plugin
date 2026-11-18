#!/bin/bash
# Self-check of scripts/mm-mcp.sh. Hermetic: a stub app stands in for the real one.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/mm-mcp.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/mmmcp-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "ok" ]; then echo "PASS $1"; else echo "FAIL $1 -- $3"; fail=1; fi; }

mkdir -p "$T/home" "$T/stubapp/Meeting Minutes.app/Contents/MacOS"
cat > "$T/stubapp/Meeting Minutes.app/Contents/MacOS/mm-mcp" <<'STUB'
#!/bin/bash
echo "$$" > "$STUB_PID_FILE"
echo "$#" > "$STUB_ARGC_FILE"
IFS= read -r line
echo '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"stub-mm-mcp"}}}'
STUB
chmod +x "$T/stubapp/Meeting Minutes.app/Contents/MacOS/mm-mcp"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
isjson() { python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; }

# 1. app present: handshake goes through, exec (same PID), no extra args
echo "$INIT" > "$T/in1"
STUB_PID_FILE="$T/pid" STUB_ARGC_FILE="$T/argc" HOME="$T/home" MM_APP_DIRS="$T/stubapp" \
  bash "$SCRIPT" < "$T/in1" > "$T/out1" 2> "$T/err1" & bgpid=$!
wait "$bgpid"; rc=$?
if [ "$rc" = 0 ] && grep -q '"stub-mm-mcp"' "$T/out1" && isjson < "$T/out1"; then check "app present: handshake relayed, rc 0" ok; else check "app present: handshake relayed, rc 0" bad "rc=$rc out=$(cat "$T/out1")"; fi
if [ "$(cat "$T/pid" 2>/dev/null)" = "$bgpid" ]; then check "app present: exec (stub PID == script PID)" ok; else check "app present: exec (stub PID == script PID)" bad "stub=$(cat "$T/pid" 2>/dev/null) script=$bgpid"; fi
[ "$(cat "$T/argc" 2>/dev/null)" = 0 ] && check "app present: no argument passed" ok || check "app present: no argument passed" bad "argc=$(cat "$T/argc" 2>/dev/null)"

# 2. app absent: JSON-RPC error carrying the request id, rc 1
echo "$INIT" > "$T/in2"
HOME="$T/home" MM_APP_DIRS="$T/nowhere" bash "$SCRIPT" < "$T/in2" > "$T/out2" 2> "$T/err2"; rc=$?
if [ "$rc" = 1 ]; then check "app absent: rc 1" ok; else check "app absent: rc 1" bad "rc=$rc"; fi
if python3 - "$T/out2" <<'PY'
import json, sys
o = json.loads(open(sys.argv[1]).read())
assert o["jsonrpc"] == "2.0" and o["id"] == 1 and o["error"]["code"] == -32000 and o["error"]["message"] and "result" not in o
PY
then check "app absent: JSON-RPC error, id 1, code -32000" ok; else check "app absent: JSON-RPC error, id 1, code -32000" bad "out=$(cat "$T/out2")"; fi

# 3. string id echoed back
echo '{"jsonrpc":"2.0","id":"abc-7","method":"initialize"}' > "$T/in3"
HOME="$T/home" MM_APP_DIRS="$T/nowhere" bash "$SCRIPT" < "$T/in3" > "$T/out3" 2>/dev/null
python3 - "$T/out3" <<'PY' && check "app absent: string id echoed" ok || check "app absent: string id echoed" bad "out=$(cat "$T/out3")"
import json, sys
assert json.loads(open(sys.argv[1]).read())["id"] == "abc-7"
PY

# 4. app absent and stdin closed: still a valid error (id null), rc 1, no hang
HOME="$T/home" MM_APP_DIRS="$T/nowhere" bash "$SCRIPT" < /dev/null > "$T/out4" 2>/dev/null; rc=$?
python3 - "$T/out4" <<'PY' && [ "$rc" = 1 ] && check "app absent, empty stdin: error id null, rc 1" ok || check "app absent, empty stdin: error id null, rc 1" bad "rc=$rc out=$(cat "$T/out4")"
import json, sys
o = json.loads(open(sys.argv[1]).read())
assert o["id"] is None and o["error"]["code"] == -32000
PY

# 5. app folder without the helper = absent
mkdir -p "$T/broken/Meeting Minutes.app/Contents/MacOS"
echo "$INIT" > "$T/in5"
HOME="$T/home" MM_APP_DIRS="$T/broken" bash "$SCRIPT" < "$T/in5" > "$T/out5" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && grep -q '"error"' "$T/out5" && check "app without helper: treated as absent" ok || check "app without helper: treated as absent" bad "rc=$rc"

# 6. the script is not a hard-coded tool list
if [ ! -f "$SCRIPT" ] || grep -Eq 'tools/list|discover|"name"' "$SCRIPT"; then check "script carries no tool vocabulary" bad "script missing or tool-ish token found"; else check "script carries no tool vocabulary" ok; fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
