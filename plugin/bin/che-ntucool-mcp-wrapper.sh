#!/bin/bash
# Version-aware auto-download wrapper for CheNtucoolMCP.
#
# Design (mirrors che-apple-mail-mcp's wrapper):
# - Reads desired version from plugin.json (plugin's intended binary version)
# - Compares against ~/bin/.CheNtucoolMCP.version sidecar
# - Re-downloads when plugin has been updated but binary is stale
# - Atomic file swap (.tmp + mv) so partial downloads never break things
# - Falls back to releases/latest if plugin.json unreadable or pinned tag missing
#
# No credential handling here: the binary reads the keychain token itself
# (CanvasAuth.swift) or falls back to the Safari session; nothing secret
# passes through this wrapper or an env var.

set -u

BINARY_NAME="CheNtucoolMCP"
# shellcheck source=../lib/ensure-binary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ensure-binary.sh"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

# Write runtime state so session-start hook can detect mid-session staleness.
{
    printf '{"pid":%d,"started_at":%d,"version_at_spawn":"%s"}\n' \
        "$$" "$(date +%s)" "${DESIRED_VERSION:-unknown}" \
        > "${RUNTIME_FILE}.tmp" \
        && mv "${RUNTIME_FILE}.tmp" "$RUNTIME_FILE"
} 2>/dev/null || true

# No keychain token is fine: the server falls back to a logged-in Safari tab on
# cool.ntu.edu.tw (manually issued COOL tokens die after about an hour, #1).
if ! security find-generic-password -s ntu-cool-canvas -a "${NTUCOOL_ACCOUNT:-default}" >/dev/null 2>&1; then
    echo "$BINARY_NAME: no keychain token — requests will use the Safari session (keep a cool.ntu.edu.tw tab logged in)" >&2
fi

exec "$BINARY" "$@"
