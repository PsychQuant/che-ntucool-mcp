#!/bin/bash
# che-ntucool-mcp SessionStart hook — detect stale MCP binary, kill PID for respawn.
#
# Same staleness-detection pattern as che-apple-mail-mcp#76: the wrapper's
# version-check only fires at spawn; the in-memory binary never re-checks
# plugin.json mid-session. This hook compares wrapper-written runtime state
# against the current plugin.json version; if they differ and the recorded PID
# is alive, SIGTERM (then SIGKILL after grace) so Claude Code respawns the MCP
# via the wrapper, picking up the new binary.
#
# No first-run TCC/FDA assist here (unlike che-apple-mail-mcp) — this server
# makes only outbound HTTPS calls, nothing to grant permission for.
#
# Failure mode: every dependency missing or unexpected → silent exit 0. Worst
# case is no-op; never break session start.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v ps >/dev/null 2>&1 || exit 0

BINARY_NAME="CheNtucoolMCP"
INSTALL_DIR="$HOME/bin"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

[ -f "$RUNTIME_FILE" ] || exit 0
[ -f "$PLUGIN_JSON" ] || exit 0

RUNTIME_VERSION=$(jq -r '.version_at_spawn // ""' "$RUNTIME_FILE" 2>/dev/null)
PLUGIN_VERSION=$(jq -r '.binary_version // .version // ""' "$PLUGIN_JSON" 2>/dev/null)

[ -z "$RUNTIME_VERSION" ] && exit 0
[ -z "$PLUGIN_VERSION" ] && exit 0

[ "$RUNTIME_VERSION" = "$PLUGIN_VERSION" ] && exit 0

PID=$(jq -r '.pid // empty' "$RUNTIME_FILE" 2>/dev/null)
[ -z "$PID" ] && exit 0

ps -p "$PID" -o pid= >/dev/null 2>&1 || exit 0
PID_COMM=$(ps -p "$PID" -o command= 2>/dev/null)
case "$PID_COMM" in
    *"$BINARY_NAME"*) ;;
    *) exit 0 ;;
esac

echo "⚠ Killing stale ${BINARY_NAME} PID ${PID} (was v${RUNTIME_VERSION}, plugin now v${PLUGIN_VERSION}) — Claude Code will respawn with new binary." >&2

kill -TERM "$PID" 2>/dev/null || true
for _ in 1 2 3 4 5; do
    ps -p "$PID" -o pid= >/dev/null 2>&1 || break
    sleep 1
done

if ps -p "$PID" -o pid= >/dev/null 2>&1; then
    echo "⚠ ${BINARY_NAME} PID ${PID} did not exit on SIGTERM, sending SIGKILL." >&2
    kill -KILL "$PID" 2>/dev/null || true
fi

exit 0
