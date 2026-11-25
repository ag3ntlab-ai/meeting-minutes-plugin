#!/bin/bash
# Interactive app-absent probe, including two red witnesses. No installed app is used.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/mm-discover-probe.XXXXXX")" || exit 1
trap 'find "$T" -depth -delete' EXIT
mkdir -p "$T/home" "$T/apps" || exit 1

# Python supplies bounded pipe I/O and JSON type checks (also used by test-mm-mcp.sh).
python3 - "$ROOT/scripts/mm-mcp.sh" "$T" <<'PY'
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

script, temporary = sys.argv[1], Path(sys.argv[2])
timeout = 3.0
requests = [
    '{"jsonrpc":"2.0","id":7,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}',
    '{"jsonrpc":"2.0","id":8,"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}',
    '{"jsonrpc":"2.0","id":9,"method":"tools/list"}',
]
# An explicit environment also prevents an inherited MM_APP_PATH from finding a real app.
environment = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": str(temporary / "home"),
    "MM_APP_DIRS": str(temporary / "apps"),
    "MM_APP_PATH": "",
}


def run_session(server):
    """The real stub and both witnesses execute this exact assertion sequence."""
    checks, replies = {}, []
    captured, pending = bytearray(), bytearray()
    stdout_eof = False
    process = subprocess.Popen(
        ["/bin/bash", str(server)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=environment, bufsize=0,
    )
    os.set_blocking(process.stdin.fileno(), False)

    def check(name, condition, detail):
        checks[name] = (bool(condition), detail)

    def read_chunk(deadline):
        nonlocal stdout_eof
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
            return False
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            stdout_eof = True
        captured.extend(chunk)
        pending.extend(chunk)
        # Keep even a noisy broken server bounded in both time and memory.
        return len(captured) <= 65536

    def exchange(request):
        deadline = time.monotonic() + timeout
        try:
            data = (request + "\n").encode()
            # All requests fit in PIPE_BUF; nonblocking writes cannot hang on a dead peer.
            if os.write(process.stdin.fileno(), data) != len(data):
                return {}, "incomplete request write"
        except OSError as error:
            return {}, str(error)
        while b"\n" not in pending:
            if stdout_eof or not read_chunk(deadline):
                return {}, "no complete response before EOF/deadline (or stdout limit)"
        line, _, rest = pending.partition(b"\n")
        pending[:] = rest
        replies.append(bytes(line) + b"\n")
        try:
            response = json.loads(line)
        except (ValueError, UnicodeError):
            return {}, "invalid JSON: " + repr(bytes(line))
        if not isinstance(response, dict):
            return {}, "response is not a JSON object"
        return response, repr(bytes(line))

    def is_error(response):
        error = response.get("error")
        return (response.get("jsonrpc") == "2.0" and isinstance(error, dict)
                and type(error.get("code")) is int and "result" not in response)

    def same_id(response, index):
        expected = json.loads(requests[index])["id"]
        return type(response.get("id")) is type(expected) and response["id"] == expected

    try:
        response, detail = exchange(requests[0])
        check("discover.error", is_error(response), detail)
        check("discover.id", same_id(response, 0), detail)
        error = response.get("error")
        message = error.get("message") if isinstance(error, dict) else None
        check("discover.message", isinstance(message, str) and "not installed" in message, detail)
        # Give an exit immediately after the reply time to become observable; stdin stays open.
        deadline = time.monotonic() + 0.2
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        check("discover.alive", process.poll() is None, "rc=" + str(process.poll()))

        response, detail = exchange(requests[1])
        result = response.get("result")
        check("initialize.result", response.get("jsonrpc") == "2.0"
              and isinstance(result, dict) and "error" not in response, detail)
        check("initialize.id", same_id(response, 1), detail)
        version = result.get("protocolVersion") if isinstance(result, dict) else None
        check("initialize.protocolVersion", isinstance(version, str) and bool(version.strip()), detail)

        response, detail = exchange(requests[2])
        tools = response.get("result", {}).get("tools") if isinstance(response.get("result"), dict) else None
        check("tools.result", response.get("jsonrpc") == "2.0" and "error" not in response
              and isinstance(tools, list) and len(tools) == 1, detail)
        check("tools.id", same_id(response, 2), detail)

        process.stdin.close()
        deadline = time.monotonic() + timeout
        while not stdout_eof:
            if not read_chunk(deadline):
                break
        try:
            rc = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            rc = None
        check("eof.exit", rc == 1, "expected rc 1 after EOF, got " + str(rc))
        check("stdout.exactly-three-lines", stdout_eof and len(replies) == 3
              and bytes(captured) == b"".join(replies),
              "complete replies=%d, stdout=%r" % (len(replies), bytes(captured)))
    finally:
        # Only this session's own child is stopped, including on a timeout or interruption.
        if process.poll() is None:
            process.kill()
        process.wait(timeout=timeout)
        process.stdin.close()
        process.stdout.close()
    return checks


failed = False


def report(name, passed, detail=""):
    global failed
    print(("PASS " if passed else "FAIL ") + name + (" -- " + detail if detail else ""))
    if not passed:
        failed = True


# Precondition witness BEFORE launching the real script: both search directories exist and are empty.
isolated = all(path.is_dir() and not any(path.iterdir())
               for path in (temporary / "home", temporary / "apps"))
report("fixture.empty-app-search", isolated)
if not isolated:
    sys.exit(1)

# One process for the real script, with a read between each of the three writes.
real_checks = run_session(script)
for name, (passed, detail) in real_checks.items():
    report(name, passed, "" if passed else detail)

# Minimal fake servers: only the requested defect varies. They never invoke the app stub.
error_reply = {"jsonrpc": "2.0", "id": 7, "error": {
    "code": -32000, "message": "Meeting Minutes is not installed on this Mac."}}
initialize_reply = {"jsonrpc": "2.0", "id": 8, "result": {"protocolVersion": "2024-11-05"}}
tools_reply = {"jsonrpc": "2.0", "id": 9, "result": {"tools": [{
    "name": "meeting_minutes_setup", "description": "Meeting Minutes is not installed on this Mac.",
    "inputSchema": {"type": "object"}}]}}

for label, wrong_id, exit_after_probe, target in (
    ("wrong-id", True, False, "discover.id"),
    ("exits-after-probe", False, True, "discover.alive"),
):
    probe_reply = dict(error_reply, id=700 if wrong_id else 7)
    # Validate the planted response BEFORE invoking the shared assertions.
    valid_fixture = (type(probe_reply["id"]) is int
                     and (probe_reply["id"] != 7) == wrong_id
                     and probe_reply["error"]["code"] == -32000
                     and "not installed" in probe_reply["error"]["message"])
    report("witness." + label + ".fixture", valid_fixture)
    if not valid_fixture:
        continue
    source = "\n".join([
        "#!/bin/bash",
        "while IFS= read -r line; do",
        "  case \"$line\" in",
        "    *'\"method\":\"server/discover\"'*)",
        "      printf '%s\\n' '" + json.dumps(probe_reply) + "'",
        "      exit 1" if exit_after_probe else "      :",
        "      ;;",
        "    *'\"method\":\"initialize\"'*)",
        "      printf '%s\\n' '" + json.dumps(initialize_reply) + "' ;;",
        "    *'\"method\":\"tools/list\"'*)",
        "      printf '%s\\n' '" + json.dumps(tools_reply) + "' ;;",
        "  esac",
        "done",
        "exit 1",
        "",
    ])
    server = temporary / (label + ".sh")
    server.write_text(source)
    report("witness." + label + ".source", server.is_file() and server.read_text() == source)
    checks = run_session(server)
    # A malformed/no-response fake must not masquerade as proof of the intended assertion.
    prerequisites = ("discover.error", "discover.message")
    if exit_after_probe:
        prerequisites += ("discover.id",)
    detected = (checks.keys() == real_checks.keys() and not checks[target][0]
                and all(checks[name][0] for name in prerequisites))
    if wrong_id:
        detected = detected and all(passed for name, (passed, _) in checks.items() if name != target)
    report("witness." + label, detected, "detected expected FAIL " + target if detected
           else "failed assertions: " + repr([name for name, (passed, _) in checks.items() if not passed]))

print("FAILURES" if failed else "ALL PASS")
sys.exit(1 if failed else 0)
PY
