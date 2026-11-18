#!/bin/bash
# Starts the MCP helper that ships inside the installed Meeting Minutes app.
# Nothing is described here: the app answers the MCP handshake and lists its own tools.
# If the app is not installed this script still speaks MCP: it answers the handshake, answers every
# other request with a JSON-RPC error, and exits 1 at end of input.
APP_ID="ai.ag3ntlab.meetingminutes"
IFS=: read -r -a dirs <<< "${MM_APP_DIRS:-/Applications:$HOME/Applications}"
for dir in "${MM_APP_PATH:+$MM_APP_PATH}" "${dirs[@]}"; do
  [ -n "$dir" ] || continue
  case "$dir" in *.app) app="$dir" ;; *) app="$dir/Meeting Minutes.app" ;; esac
  helper="$app/Contents/MacOS/mm-mcp"
  # Only our own app: same identifier check as the app's helper.
  [ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null)" = "$APP_ID" ] || continue
  [ -x "$helper" ] && exec "$helper"
done

# JSON id of a request line: number or string kept as such, anything else (or no id) means "not a request".
request_id() {
  local type value
  type="$(printf '%s' "$1" | plutil -type id - 2>/dev/null)" || return 1
  value="$(printf '%s' "$1" | plutil -extract id raw -o - - 2>/dev/null)" || return 1
  case "$type" in
    integer|float) printf '%s' "$value" ;;
    string)
      case "$value" in *[[:cntrl:]]*) printf 'null' ;; *) value="${value//\\/\\\\}"; printf '"%s"' "${value//\"/\\\"}" ;; esac ;;
    *) return 1 ;;
  esac
}
while IFS= read -r line || [ -n "$line" ]; do
  id="$(request_id "$line")" || continue
  if [ "$(printf '%s' "$line" | plutil -extract method raw -o - - 2>/dev/null)" = initialize ]; then
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"Meeting Minutes","version":"1.0"}}}\n' "$id"
  else
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"Meeting Minutes is not installed on this Mac. Install the app, open it once, then restart the assistant."}}\n' "$id"
  fi
done
exit 1
