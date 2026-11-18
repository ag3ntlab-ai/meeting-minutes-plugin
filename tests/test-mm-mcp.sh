#!/bin/bash
# Self-check of scripts/mm-mcp.sh. Hermetic: a stub app stands in for the real one.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/mm-mcp.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/mmmcp-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1 -- $3"; fail=1; fi; }

mkapp() { # dir bundle-id with-helper
  mkdir -p "$1/Meeting Minutes.app/Contents/MacOS"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>' "$2" > "$1/Meeting Minutes.app/Contents/Info.plist"
  if [ "$3" = yes ]; then
    cat > "$1/Meeting Minutes.app/Contents/MacOS/mm-mcp" <<'STUB'
#!/bin/bash
echo "$$" > "$STUB_PID_FILE"
echo "$#" > "$STUB_ARGC_FILE"
IFS= read -r line
echo '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"stub-mm-mcp"}}}'
STUB
    chmod +x "$1/Meeting Minutes.app/Contents/MacOS/mm-mcp"
  fi
}
mkdir -p "$T/home"
mkapp "$T/good" ai.ag3ntlab.meetingminutes yes
mkapp "$T/wrongid" com.example.other yes
mkapp "$T/nohelper" ai.ag3ntlab.meetingminutes no
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# j FILE LINE-NUMBER EXPR : value of a Python expression on the JSON object found on that line of FILE ("ERR" if unusable)
j() { python3 -c 'import json,sys
try:
    o=json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])-1]); print(eval(sys.argv[3]))
except Exception: print("ERR")' "$1" "$2" "$3"; }
run_absent() { HOME="$T/home" MM_APP_DIRS="${APPDIRS:-$T/nowhere}" bash "$SCRIPT" < "$1" > "$2" 2>/dev/null; echo $?; }

# 1. app present: handshake relayed, exec (same PID), no argument
echo "$INIT" > "$T/in1"
STUB_PID_FILE="$T/pid" STUB_ARGC_FILE="$T/argc" HOME="$T/home" MM_APP_DIRS="$T/good" bash "$SCRIPT" < "$T/in1" > "$T/out1" 2>/dev/null & bgpid=$!
wait "$bgpid"; rc=$?
[ "$rc" = 0 ] && grep -q '"stub-mm-mcp"' "$T/out1" && check "app present: handshake relayed, rc 0" ok || check "app present: handshake relayed, rc 0" bad "rc=$rc"
[ "$(cat "$T/pid" 2>/dev/null)" = "$bgpid" ] && check "app present: exec (stub PID == script PID)" ok || check "app present: exec (stub PID == script PID)" bad "stub=$(cat "$T/pid" 2>/dev/null) script=$bgpid"
[ "$(cat "$T/argc" 2>/dev/null)" = 0 ] && check "app present: no argument passed" ok || check "app present: no argument passed" bad "argc=$(cat "$T/argc" 2>/dev/null)"

# 2. app absent: initialize answered normally, every other call answered with an error, loop until EOF, rc 1
{ echo "$INIT"
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":"call-9","method":"tools/call","params":{"name":"x","arguments":{}}}'; } > "$T/in2"
rc=$(run_absent "$T/in2" "$T/out2")
[ "$rc" = 1 ] && check "app absent: rc 1 at EOF" ok || check "app absent: rc 1 at EOF" bad "rc=$rc"
[ "$(wc -l < "$T/out2" | tr -d ' ')" = 3 ] && check "app absent: 3 replies (initialize, tools/list, tools/call), none for the notification" ok || check "app absent: 3 replies" bad "lines=$(wc -l < "$T/out2")"
[ "$(j "$T/out2" 1 'o["id"]==1 and o["result"]["serverInfo"]["name"]=="Meeting Minutes" and "error" not in o')" = True ] && check "app absent: initialize answered normally" ok || check "app absent: initialize answered normally" bad "$(sed -n 1p "$T/out2")"
[ "$(j "$T/out2" 2 'o["id"]==2 and o["error"]["code"]==-32000 and "not installed" in o["error"]["message"] and "result" not in o')" = True ] && check "app absent: tools/list gets the 'not installed' error" ok || check "app absent: tools/list gets the 'not installed' error" bad "$(sed -n 2p "$T/out2")"
[ "$(j "$T/out2" 3 'o["id"]=="call-9" and o["error"]["code"]==-32000')" = True ] && check "app absent: any other call gets the error, string id echoed" ok || check "app absent: any other call gets the error" bad "$(sed -n 3p "$T/out2")"

# 3. id parsing: number, float, string with a quote; an id nested in params is not the request id
{ echo '{"jsonrpc":"2.0","method":"tools/list","params":{"id":99},"id":7}'
  echo '{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":"a\"b","method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":-3,"method":"nope","params":{"id":"x"}}'; } > "$T/in3"
run_absent "$T/in3" "$T/out3" > /dev/null
[ "$(j "$T/out3" 1 'o["id"]==7')" = True ] && check "ids: numeric id wins over a nested id" ok || check "ids: numeric id wins over a nested id" bad "$(sed -n 1p "$T/out3")"
[ "$(j "$T/out3" 2 'o["id"]==1.5')" = True ] && check "ids: float" ok || check "ids: float" bad "$(sed -n 2p "$T/out3")"
[ "$(j "$T/out3" 3 'o["id"]=="a\"b"')" = True ] && check "ids: string with a quote, still valid JSON" ok || check "ids: string with a quote" bad "$(sed -n 3p "$T/out3")"
[ "$(j "$T/out3" 4 'o["id"]==-3')" = True ] && check "ids: negative integer" ok || check "ids: negative integer" bad "$(sed -n 4p "$T/out3")"

# 4. absent + empty stdin: nothing to answer, rc 1, no hang
rc=$(run_absent /dev/null "$T/out4")
[ "$rc" = 1 ] && [ ! -s "$T/out4" ] && check "app absent, empty stdin: no output, rc 1" ok || check "app absent, empty stdin: no output, rc 1" bad "rc=$rc"

# 5. a folder that is not our app (wrong bundle id) or has no helper counts as absent
for d in wrongid nohelper; do
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/list"}' > "$T/in5"
  rc=$(APPDIRS="$T/$d" run_absent "$T/in5" "$T/out5")
  [ "$rc" = 1 ] && [ "$(j "$T/out5" 1 'o["error"]["code"]==-32000')" = True ] && check "$d: treated as absent" ok || check "$d: treated as absent" bad "rc=$rc"
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
