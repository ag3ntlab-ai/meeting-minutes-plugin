#!/bin/bash
# The plug-in must carry no tool vocabulary: the tool list comes from the app. Delivered code only (not tests, not LICENSE).
# Single exception (plan D-P2): the relay asks the app for its catalog with the operation `discover`.
set -u
ROOT="${VOCAB_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
NAMES='cancel|journal|speakers|pending|persons|export|status|submit|propose_speaker_name|create_person|rename_person|set_person_reference|interventions'
files=()
for f in scripts .mcp.json .claude-plugin/plugin.json README.md relay-src/Package.swift relay-src/Sources; do [ -e "$f" ] && files+=("$f"); done
fail=0
hits="$(grep -rnEw "$NAMES" "${files[@]}" 2>/dev/null)"
if [ -n "$hits" ]; then echo "FAIL tool name in delivered code:"; echo "$hits"; fail=1; else echo "PASS no tool name in delivered code (${files[*]})"; fi
# discover: tolerated only in the relay's catalog call
bad="$(grep -rnw discover "${files[@]}" 2>/dev/null | grep -v '^relay-src/Sources/RelayCore/Relay.swift:')"
if [ -n "$bad" ]; then echo "FAIL discover outside Relay.swift:"; echo "$bad"; fail=1; else echo "PASS discover only where the relay calls it"; fi
# compiled relay: same rule on its strings
if [ -f relay/mm-mcp-relay ]; then
  strs="$(strings - relay/mm-mcp-relay | grep -Ew "$NAMES")"
  if [ -n "$strs" ]; then echo "FAIL tool name in relay binary strings:"; echo "$strs" | head; fail=1; else echo "PASS no tool name in relay binary strings"; fi
fi
exit $fail
