#!/bin/bash
# The plug-in must carry no tool vocabulary: the tool list comes from the app. Delivered code only (not tests, not LICENSE).
# Single exception (plan D-P2): the relay asks the app for its catalog with the operation `discover`.
set -u
ROOT="${VOCAB_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
NAMES='cancel|journal|speakers|pending|persons|export|status|submit|propose_speaker_name|create_person|rename_person|set_person_reference|interventions'
CURRENT_NAMES='app_info journal_read journal_write meeting_delete meeting_read meeting_write person_delete person_read person_write recording_write settings_delete settings_read settings_write trash_delete trash_read trash_write voice_delete voice_read voice_write'
NAMES="$NAMES|${CURRENT_NAMES// /|}"
files=()
for f in scripts .mcp.json .claude-plugin/plugin.json .claude-plugin/marketplace.json README.md relay-src/Package.swift relay-src/Sources; do [ -e "$f" ] && files+=("$f"); done
fail=0
# Never report absence on an empty scan. Keep all legacy relay targets as well.
if [ "${#files[@]}" = 0 ]; then echo 'FAIL no delivered files to scan'; exit 1; fi
hits="$(grep -rnEw "$NAMES" "${files[@]}" 2>/dev/null)"
scan_rc=$?
if [ "$scan_rc" -gt 1 ]; then echo 'FAIL cannot scan delivered code'; fail=1
elif [ -n "$hits" ]; then echo "FAIL tool name in delivered code:"; echo "$hits"; fail=1
else echo "PASS no tool name in delivered code (${files[*]})"; fi
# discover: tolerated only in the relay's catalog call
discovered="$(grep -rnw discover "${files[@]}" 2>/dev/null)"
scan_rc=$?
if [ "$scan_rc" -gt 1 ]; then echo 'FAIL cannot scan discover vocabulary'; fail=1; fi
bad="$(printf '%s\n' "$discovered" | grep -v '^relay-src/Sources/RelayCore/Relay.swift:')"
if [ -n "$bad" ]; then echo "FAIL discover outside Relay.swift:"; echo "$bad"; fail=1; else echo "PASS discover only where the relay calls it"; fi
# compiled relay: same rule on its strings
if [ -f relay/mm-mcp-relay ]; then
  strs="$(strings - relay/mm-mcp-relay | grep -Ew "$NAMES")"
  if [ -n "$strs" ]; then echo "FAIL tool name in relay binary strings:"; echo "$strs" | head; fail=1; else echo "PASS no tool name in relay binary strings"; fi
fi

# Internal scan mode prevents recursive self-checks in the disposable copy.
if [ "${1:-}" != --scan-only ]; then
  T="$(mktemp -d "${TMPDIR:-/tmp}/mm-vocabulary.XXXXXX")" || { echo 'FAIL vocabulary witness: mktemp'; exit 1; }
  # Only this invocation's mktemp tree is removed; no source paths are touched.
  trap 'find "$T" -depth -delete' EXIT
  if ! mkdir "$T/repo" || ! cp -R "$ROOT/." "$T/repo/"; then
    echo 'FAIL vocabulary witness: cannot copy repository'; exit 1
  fi
  # Establish a clean baseline BEFORE planting anything: a pre-existing failure
  # must never be mistaken for successful detection of the synthetic name.
  if VOCAB_ROOT="$T/repo" bash "$T/repo/tests/test-vocabulary.sh" --scan-only > "$T/baseline.log" 2>&1; then
    echo 'PASS vocabulary witness: clean copied repository'
    witness_file="$T/repo/.claude-plugin/marketplace.json"
    if [ ! -f "$witness_file" ]; then
      echo 'FAIL vocabulary witness: marketplace fixture is missing'; fail=1
    else
      cp "$witness_file" "$T/marketplace-original.json" || exit 1
      for name in $CURRENT_NAMES; do
        # Replace only a disposable copy with a minimal, valid JSON fixture.
        printf '{"name":"%s"}\n' "$name" > "$witness_file" || exit 1
        # Check fixture contents before invoking the scanner under test.
        if ! grep -qw "$name" "$witness_file"; then
          echo "FAIL vocabulary witness $name: planted fixture not found"; fail=1; continue
        fi
        VOCAB_ROOT="$T/repo" bash "$T/repo/tests/test-vocabulary.sh" --scan-only > "$T/planted.log" 2>&1
        witness_rc=$?
        if [ "$witness_rc" = 1 ] &&
           grep -Fxq 'FAIL tool name in delivered code:' "$T/planted.log" &&
           grep -Fxq ".claude-plugin/marketplace.json:1:{\"name\":\"$name\"}" "$T/planted.log"; then
          echo "PASS vocabulary witness $name: planted name rejected (rc 1)"
        else
          echo "FAIL vocabulary witness $name: expected named assertion and rc 1, got rc $witness_rc"
          cat "$T/planted.log"; fail=1
        fi
      done
      cp "$T/marketplace-original.json" "$witness_file" || exit 1
    fi
  else
    echo 'FAIL vocabulary witness: copied baseline is not clean'
    cat "$T/baseline.log"; fail=1
  fi
fi
exit $fail
