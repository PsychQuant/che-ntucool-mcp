#!/bin/bash
# Shared by bin/che-ntucool-mcp-wrapper.sh (MCP server) and bin/che-ntucool (CLI):
# make sure ~/bin/$BINARY_NAME exists and matches the plugin's binary_version,
# downloading it from the GitHub release when it does not.
#
# Lives outside bin/ on purpose: every file in a plugin's bin/ is put on the
# Bash tool's PATH, and this is not a command.
#
# Caller sets BINARY_NAME, then sources this file. Sets BINARY and
# DESIRED_VERSION. Progress goes to stderr only — the CLI's stdout is data.

# REPO stays on the current name: GitHub redirects old → new after a repo
# rename, never new → old, so this works before and after `gh repo rename`.
REPO="PsychQuant/che-ntucool-mcp"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). This file lives at PLUGIN_ROOT/lib/.
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

