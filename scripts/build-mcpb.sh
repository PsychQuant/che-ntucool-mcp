#!/bin/bash
# Build a DEV .mcpb package (host arch only, ad-hoc signed).
#
# This is a dev convenience, not a distribution path — the resulting bundle is
# arm64-only (or whatever the host arch is) and unsigned, so on macOS 26 a
# Gatekeeper-strict install may warn. Ship via `make release-signed` instead.

set -e

cd "$(dirname "$0")/.."

echo "Building release..."
swift build -c release

MCPB_ALLOW_UNSIGNED=1 ./scripts/package-mcpb.sh \
    .build/release/CheNtucoolMCP \
    mcpb/che-ntucool-mcp-dev.mcpb
