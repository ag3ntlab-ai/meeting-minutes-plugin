#!/bin/bash
# Starts the MCP helper that ships inside the installed Meeting Minutes app.
# Nothing is described here: the app answers the MCP handshake and lists its own tools.
# If the app is not installed, answer the first JSON-RPC request with an error and exit 1.
IFS=: read -r -a dirs <<< "${MM_APP_DIRS:-/Applications:$HOME/Applications}"
for dir in "${MM_APP_PATH:+$MM_APP_PATH}" "${dirs[@]}"; do
  [ -n "$dir" ] || continue
  case "$dir" in *.app) app="$dir" ;; *) app="$dir/Meeting Minutes.app" ;; esac
  helper="$app/Contents/MacOS/mm-mcp"
  [ -x "$helper" ] && exec "$helper"
done

IFS= read -r -t 5 line || true
id="$(printf '%s' "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*(-?[0-9]+|"[^"\\]*").*/\1/p')"
printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"Meeting Minutes is not installed on this Mac. Install the app, open it once, then restart the assistant."}}\n' "${id:-null}"
exit 1
