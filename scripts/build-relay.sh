#!/bin/bash
# Rebuilds relay/mm-mcp-relay from relay-src/ (arm64, release) and prints its SHA-256.
# Paths are mapped and symbols stripped so the result does not depend on where the repo or the scratch folder lives.
# `--verify` rebuilds into a temp folder and compares with relay/mm-mcp-relay.sha256 without touching the committed binary.
# Toolchain used for the committed binary: Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0, macOS 26 SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mm-relay-build.XXXXXX")"
FLAGS=(-c release --arch arm64 --package-path "$ROOT/relay-src" --scratch-path "$SCRATCH"
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/src" -Xswiftc -file-prefix-map -Xswiftc "$SCRATCH=/build"
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/src" -Xswiftc -debug-prefix-map -Xswiftc "$SCRATCH=/build" -Xlinker -S)
swift build "${FLAGS[@]}" >&2
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/mm-mcp-relay"
SUM="$(shasum -a 256 "$BIN" | cut -d' ' -f1)"
if [ "${1:-}" = "--verify" ]; then
  EXPECTED="$(cut -d' ' -f1 "$ROOT/relay/mm-mcp-relay.sha256")"
  [ "$SUM" = "$EXPECTED" ] && echo "REPRODUCED $SUM" || { echo "DIFFERENT built=$SUM committed=$EXPECTED"; exit 1; }
else
  cp "$BIN" "$ROOT/relay/mm-mcp-relay"
  echo "$SUM  relay/mm-mcp-relay" > "$ROOT/relay/mm-mcp-relay.sha256"
  echo "$SUM"
fi
