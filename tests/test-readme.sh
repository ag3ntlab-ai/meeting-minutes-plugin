#!/bin/bash
# README contract for G17 P8 (8a). No app, network or assistant is started.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
README_TEXT="$(cat "$README")" || { echo 'FAIL README input -- cannot read README.md'; exit 1; }
HELPER='/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp'
fail=0
check() { if "$2"; then echo "PASS $1"; else echo "FAIL $1 -- $3"; fail=1; fi; }

# Join wrapped prose, keeping blank-line paragraph boundaries. Sections include
# code blocks, so a manual setup command may follow its explanatory paragraph.
paragraphs() { awk 'BEGIN { RS="" } { gsub(/[[:space:]]+/, " "); print }'; }
section() {
  awk -v title="$1" '
    $0 == "## " title { inside=1; next }
    inside && /^## / { exit }
    inside { print }
  ' <<< "$README_TEXT"
}
flatten() { awk '{ printf "%s ", $0 } END { print "" }'; }
document() { paragraphs <<< "$README_TEXT"; }
has() { grep -Fq -- "$1"; }
matches() { grep -Eiq -- "$1"; }

r1() {
  local text
  text="$(section 'What it starts' | flatten)"
  has "$HELPER" <<< "$text" && has 'mm-mcp' <<< "$text" &&
    matches 'helper[^.]*((ships|shipped|bundled|included)[^.]*app|inside[^.]*app)' <<< "$text"
}
r2() {
  local text
  # The existing equivalent heading is explicitly accepted by this contract.
  text="$( { section 'What is sent to your assistant'; section 'What data it sends'; } | flatten)"
  matches 'The plug-in (sends nothing anywhere|sends nothing (over|on) the network|does not send anything (over|on) the network)[.]' <<< "$text" &&
    matches '(the app returns the answer to the assistant you chose|responses from the app go to your chosen assistant)' <<< "$text"
}
r3() {
  document | grep -Eq 'https://ag3ntlab[.]ai/meeting-minutes/privacy([[:space:]`)>]|$)'
}
r4() {
  local text
  text="$(section 'Untrusted content' | flatten)"
  matches '(meeting text|text[^.]*from a meeting)[^.]*as data' <<< "$text" &&
    has '`content`' <<< "$text" && has 'never as instructions' <<< "$text" &&
    matches '(the|your) assistant must treat (it|meeting text|this text) as untrusted' <<< "$text"
}
r5() {
  local text
  text="$(document | flatten)"
  matches 'while an import runs, other commands wait' <<< "$text" &&
    matches '(^|[^[:alnum:].])1[.]8 s per GiB([^[:alnum:]]|$)' <<< "$text" &&
    matches '(^|[^[:digit:]])120 s([^[:alnum:]]|$)' <<< "$text"
}
r6() {
  # All three facts must belong to ONE paragraph, not unrelated sections.
  document | awk '
    (tolower($0) ~ /(^|[^[:alnum:]])(2-hour|2 h)([^[:alnum:]]|$)/) &&
    /(^|[^[:digit:]])90 s([^[:alnum:]]|$)/ &&
    /(^|[^[:digit:]])240 s([^[:alnum:]]|$)/ { found=1 }
    END { exit !found }
  '
}
r7() {
  local text
  text="$(document | flatten)"
  matches 'resumed the next time the app starts' <<< "$text" &&
    has 'Journal' <<< "$text" && has 'Resumed importing' <<< "$text"
}
r8() {
  document | has 'codex mcp add meeting-minutes -- "/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp"'
}
r9() {
  # Require one section to connect ChatGPT, STDIO and the installed helper.
  awk '
    function finish() { if (chat && stdio && helper) found=1 }
    /^## / { finish(); chat=stdio=helper=0 }
    /ChatGPT/ { chat=1 }
    /STDIO/ { stdio=1 }
    index($0, "/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp") { helper=1 }
    END { finish(); exit !found }
  ' <<< "$README_TEXT"
}
r10() {
  local text
  text="$(document | flatten)"
  grep -Eqw ssh <<< "$text" && grep -Eqw tmux <<< "$text" &&
    has 'Allow agents that connect to this Mac remotely' <<< "$text"
}
r11() { document | has 'Allow external agent plugin'; }
r12() {
  # An absent/empty README must never make a negative assertion pass.
  [ -n "$README_TEXT" ] && grep -q '[^[:space:]]' <<< "$README_TEXT" || return 1
  local rc
  grep -Eq 'Sanofi|ARIA|@[[:alnum:]][[:alnum:].-]*[.][[:alpha:]]{2,}' <<< "$README_TEXT"
  rc=$?
  [ "$rc" = 1 ]
}

# Positive witnesses exercise the SAME predicates before checking the README.
# They contain only invented prose; every contract also rejects an empty file.
# The source README is never changed: all fixtures live in shell variables.
REAL_README_TEXT="$README_TEXT"
WITNESS="$(cat <<'FIXTURE'
## What it starts
The helper program that ships inside the app is `mm-mcp`, at `/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp`.

## What is sent to your assistant
The plug-in sends nothing over the network. Responses from the app go to your chosen assistant.

## Privacy
https://ag3ntlab.ai/meeting-minutes/privacy

## Untrusted content
Meeting text is returned as data in `content`, never as instructions. Your assistant must treat it as untrusted.

## Delays
While an import runs, other commands wait. Import measures 1.8 s per GiB; the catalogue import timeout is 120 s.

Finishing a 2-hour recording measures 90 s; the catalogue timeout is 240 s.

## Recovery
An interrupted import is resumed the next time the app starts. The Journal shows `Resumed importing`.

## Codex
codex mcp add meeting-minutes -- "/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp"

## ChatGPT Desktop
In ChatGPT Desktop, use STDIO with `/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp`.

## Remote sessions
For ssh and tmux, enable `Allow agents that connect to this Mac remotely`.

## Access
Enable `Allow external agent plugin`.
FIXTURE
)"
for requirement in {1..12}; do
  README_TEXT="$WITNESS"
  if "r$requirement"; then
    echo "PASS R$requirement witness -- valid synthetic contract accepted"
  else
    echo "FAIL R$requirement witness -- valid synthetic contract rejected"
    fail=1
  fi
  README_TEXT=''
  if "r$requirement"; then
    echo "FAIL R$requirement empty witness -- absent content accepted"
    fail=1
  else
    echo "PASS R$requirement empty witness -- absent content rejected"
  fi
done
for marker in Sanofi ARIA A@example.invalid; do
  README_TEXT="$WITNESS"$'\n'"$marker"
  if r12; then
    echo "FAIL R12 forbidden-text witness -- planted marker accepted: $marker"
    fail=1
  else
    echo "PASS R12 forbidden-text witness -- planted marker rejected: $marker"
  fi
done
README_TEXT="$REAL_README_TEXT"

check 'R1 what it starts' r1 'name the bundled mm-mcp helper and its installed path under ## What it starts'
check 'R2 what is sent to your assistant' r2 'state no network sending and app replies going to the chosen assistant under the accepted heading'
check 'R3 privacy N3' r3 'link the exact published privacy URL'
check 'R4 untrusted content D-P7' r4 'under ## Untrusted content, describe meeting data in `content`, never instructions, and require the assistant to distrust it'
check 'R5 import delay D-P16' r5 'state that other commands wait during import, 1.8 s per GiB measured, and the 120 s import timeout'
check 'R6 long recording D-P16' r6 'put 2-hour (or 2 h), 90 s measured and 240 s timeout in one paragraph'
check 'R7 resumed import D-P23' r7 'state next-start resumption, Journal and the exact Resumed importing line'
check 'R8 manual Codex setup' r8 'include the exact codex mcp add command with the quoted installed helper path'
check 'R9 manual ChatGPT Desktop setup' r9 'connect ChatGPT, STDIO and the installed helper path in one section'
check 'R10 ssh/tmux setup' r10 'mention ssh, tmux and the exact remote-agent setting label'
check 'R11 access switch' r11 'include the exact Allow external agent plugin setting label'
check 'R12 no real text' r12 'require a nonempty README without the forbidden names or an email address'
exit "$fail"
