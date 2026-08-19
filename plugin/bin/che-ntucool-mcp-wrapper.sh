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
# No credential handling here: the Canvas Personal Access Token is read
# directly from the macOS keychain by the binary itself (CanvasAuth.swift),
# never passed through this wrapper or an env var.

set -u

REPO="PsychQuant/che-ntucool-mcp"
BINARY_NAME="CheNtucoolMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
RUNTIME_FILE="$INSTALL_DIR/.${BINARY_NAME}.runtime.json"

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"binary_version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
    if [[ -z "$DESIRED_VERSION" ]]; then
        DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
            | head -1 | cut -d'"' -f4 || true)
    fi
fi

INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

NEED_DOWNLOAD=false
REASON=""
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    URL=""
    for API_URL in \
        "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" \
        "https://api.github.com/repos/$REPO/releases/latest"
    do
        [[ -z "$API_URL" ]] && continue
        URL=$(curl -sL --max-time 30 "$API_URL" 2>/dev/null \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
        [[ -n "$URL" ]] && break
    done

    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    else
        if curl -sL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
            chmod +x "${BINARY}.tmp"
            mv "${BINARY}.tmp" "$BINARY"
            ACTUAL_VERSION=$(echo "$URL" | sed -nE 's|.*/releases/download/v?([^/]+)/.*|\1|p')
            echo "${ACTUAL_VERSION:-${DESIRED_VERSION:-unknown}}" > "$VERSION_FILE"
            echo "$BINARY_NAME: installed v${ACTUAL_VERSION:-${DESIRED_VERSION:-latest}}" >&2
        else
            rm -f "${BINARY}.tmp" 2>/dev/null
            if [[ -x "$BINARY" ]]; then
                echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
            else
                echo "$BINARY_NAME: ERROR — download failed" >&2
                exit 1
            fi
        fi
    fi
fi

# Write runtime state so session-start hook can detect mid-session staleness.
{
    printf '{"pid":%d,"started_at":%d,"version_at_spawn":"%s"}\n' \
        "$$" "$(date +%s)" "${DESIRED_VERSION:-unknown}" \
        > "${RUNTIME_FILE}.tmp" \
        && mv "${RUNTIME_FILE}.tmp" "$RUNTIME_FILE"
} 2>/dev/null || true

# Fail-fast, actionable message if the Canvas token isn't provisioned yet —
# better than the server binary's own generic keychain error surfacing deep
# inside a tool call.
if ! security find-generic-password -s ntu-cool-canvas -a "${NTUCOOL_ACCOUNT:-default}" -w >/dev/null 2>&1; then
    echo "$BINARY_NAME: no Canvas token in keychain for account '${NTUCOOL_ACCOUNT:-default}'." >&2
    echo "  Generate one: NTU COOL → 帳戶 → 設定 → 已核准的整合 → 新訪問令牌" >&2
    echo "                (NTU's theme hides that section by default)" >&2
    echo "  Store it:     security add-generic-password -s ntu-cool-canvas -a ${NTUCOOL_ACCOUNT:-default} -w '<token>'" >&2
    echo "  (server will still start — this just means tool calls will fail until provisioned)" >&2
fi

exec "$BINARY" "$@"
