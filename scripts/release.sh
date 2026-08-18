#!/bin/bash
#
# Release a new version of che-ntucool-mcp end-to-end:
#   1. Sanity checks (clean tree, tag not already present, CHANGELOG entry exists,
#      manifest version matches)
#   2. Build universal (arm64 + x86_64) release binary
#   3. Sign + notarize (gated — see below)
#   4. Package .mcpb around the signed binary
#   5. Create git tag on HEAD, push, create GitHub release, upload assets
#
# Usage:
#   ./scripts/release.sh <version> [<release-title>]
#
# Example:
#   ./scripts/release.sh v0.2.0 "v0.2.0: write operations"

set -euo pipefail

# ---- Config ------------------------------------------------------------------

REPO="PsychQuant/che-ntucool-mcp"
BINARY_NAME="CheNtucoolMCP"
DIST_DIR=".build/dist"
BINARY_PATH="$DIST_DIR/$BINARY_NAME"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---- Argument parsing --------------------------------------------------------

if [[ $# -lt 1 ]]; then
    die "usage: $0 <version> [<release-title>]

Example:
    $0 v0.2.0
    $0 v0.2.0 \"v0.2.0: write operations\""
fi

VERSION="$1"
TITLE="${2:-$VERSION}"

if ! LC_ALL=C python3 - "$VERSION" <<'PY'
import re, sys
m = re.fullmatch(r'v([0-9]{1,19})\.([0-9]{1,19})\.([0-9]{1,19})', sys.argv[1])
if not m:
    sys.exit(1)
if any(int(g) > 2**63 - 1 for g in m.groups()):
    sys.exit(1)
PY
then
    die "version must match vMAJOR.MINOR.PATCH (got: $VERSION)"
fi

VERSION_NO_V="${VERSION#v}"

# ---- Sanity checks -----------------------------------------------------------

info "Running sanity checks..."

if [[ ! -f "Package.swift" ]] || [[ ! -f "CHANGELOG.md" ]]; then
    die "run this script from the repo root (where Package.swift lives)"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree not clean. commit or stash changes before releasing."
fi

if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
    die "tag $VERSION already exists locally. delete it first or use a new version."
fi

if git ls-remote --tags origin "refs/tags/$VERSION" | grep -q "$VERSION"; then
    die "tag $VERSION already exists on origin. delete it first or use a new version."
fi

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/main 2>/dev/null || echo "")"
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    die "local HEAD ($LOCAL_HEAD) differs from origin/main ($REMOTE_HEAD).
        push your commits first: git push origin main"
fi

if ! grep -qE "^## \[$VERSION_NO_V\]" CHANGELOG.md; then
    die "CHANGELOG.md has no released entry for [$VERSION_NO_V]. add one before releasing."
fi

if ! python3 - "$VERSION_NO_V" <<'PY'
import json, sys
want = sys.argv[1]
try:
    got = json.load(open('mcpb/manifest.json'))['version']
except Exception as exc:
    print(f"    could not read version from mcpb/manifest.json: {exc}", file=sys.stderr)
    sys.exit(2)
if got != want:
    print(f"    manifest version is {got!r}, releasing {want!r}", file=sys.stderr)
    sys.exit(1)
PY
then
    die "mcpb/manifest.json version does not match '$VERSION_NO_V'. Bump it alongside the CHANGELOG entry."
fi

info "Sanity checks passed."

# ---- Extract release notes ---------------------------------------------------

RELEASE_NOTES="$(awk "/^## \[$VERSION_NO_V\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md)"
if [[ -z "$RELEASE_NOTES" ]]; then
    die "extracted release notes are empty. check CHANGELOG.md format for [$VERSION_NO_V]."
fi

info "Release notes (first 5 lines):"
echo "$RELEASE_NOTES" | head -5 | sed 's/^/    /'

# ---- Build universal binary ---------------------------------------------------

info "Building release binary (universal: arm64 + x86_64)..."
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM64_BINARY=".build/arm64-apple-macosx/release/$BINARY_NAME"
X64_BINARY=".build/x86_64-apple-macosx/release/$BINARY_NAME"
if [[ ! -f "$ARM64_BINARY" || ! -f "$X64_BINARY" ]]; then
    die "expected per-arch binaries missing (arm64: $ARM64_BINARY, x86_64: $X64_BINARY). build failed?"
fi

mkdir -p "$DIST_DIR"
rm -f "$BINARY_PATH"
lipo -create "$ARM64_BINARY" "$X64_BINARY" -output "$BINARY_PATH"
chmod +x "$BINARY_PATH"

ARCHS="$(lipo -archs "$BINARY_PATH")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] \
    || die "universal binary missing expected archs (got: $ARCHS)"

BINARY_SIZE="$(ls -lh "$BINARY_PATH" | awk '{print $5}')"
info "Universal binary built: $BINARY_PATH ($BINARY_SIZE), archs: $ARCHS"

# ---- Confirm with user -------------------------------------------------------

cat <<EOF

==========================================================================
About to release $VERSION with the following plan:

    Tag: $VERSION (on $LOCAL_HEAD)
    Title: $TITLE
    Binary: $BINARY_PATH ($BINARY_SIZE)
    Repo: $REPO
    Notes: extracted from CHANGELOG.md [$VERSION_NO_V]

This will:
    1. Sign + notarize the universal binary (unless SKIP_CODESIGN / no DEVELOPER_ID)
    2. Create git tag $VERSION on HEAD
    3. Push tag to origin
    4. Create GitHub release $VERSION
    5. Upload $BINARY_NAME (+ .sha256) as release assets

EOF
read -p "Proceed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
fi

# ---- Sign + notarize ---------------------------------------------------------
# Gate (fork-friendly):
#   SKIP_CODESIGN=1                    → skip (dev/emergency; ships ad-hoc binary)
#   no DEVELOPER_ID / cert not present → skip with warning (default for forks)
#   REQUIRE_CODESIGN=1                 → fail-fast instead of skipping (set by `make release-signed`)
#   otherwise                          → sign + notarize
SHOULD_SIGN=true
SKIP_REASON=""
if [[ "${SKIP_CODESIGN:-}" == "1" || "${SKIP_CODESIGN:-}" == "true" ]]; then
    SHOULD_SIGN=false; SKIP_REASON="SKIP_CODESIGN=$SKIP_CODESIGN"
elif [[ -z "${DEVELOPER_ID:-}" ]]; then
    SHOULD_SIGN=false; SKIP_REASON="DEVELOPER_ID env not set"
elif ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    SHOULD_SIGN=false; SKIP_REASON="codesigning identity '$DEVELOPER_ID' not in keychain"
fi

if [[ "$SHOULD_SIGN" == "false" ]]; then
    if [[ "${REQUIRE_CODESIGN:-}" == "1" || "${REQUIRE_CODESIGN:-}" == "true" ]]; then
        die "Refusing to ship an unsigned binary: REQUIRE_CODESIGN set but $SKIP_REASON.
        Set DEVELOPER_ID + NOTARY_PROFILE and install the Developer ID Application cert.
        See README 'Signing & Notarization'."
    fi
    info "Skipping Developer ID signing + notarize ($SKIP_REASON)."
    codesign --force --sign - "$BINARY_PATH"
else
    info "Signing + notarizing the universal binary..."
    "$(dirname "$0")/sign-and-notarize.sh" "$BINARY_PATH"
fi

shasum -a 256 "$BINARY_PATH" | awk '{print $1}' > "$BINARY_PATH.sha256"
info "SHA-256: $(cat "$BINARY_PATH.sha256")"

# ---- Package the .mcpb around the SIGNED binary -------------------------------

MCPB_PATH=""
if [[ -n "${DEVELOPER_ID:-}" && "${SKIP_CODESIGN:-}" != "1" ]]; then
    info "Packaging .mcpb around the signed universal binary..."
    ./scripts/package-mcpb.sh "$BINARY_PATH" "mcpb/che-ntucool-mcp-$VERSION_NO_V.mcpb"
    MCPB_PATH="mcpb/che-ntucool-mcp-$VERSION_NO_V.mcpb"
else
    info "Skipping .mcpb packaging (no DEVELOPER_ID / SKIP_CODESIGN=1)."
fi

# ---- Tag + release + upload --------------------------------------------------

info "Creating git tag $VERSION..."
git tag -a "$VERSION" -m "$TITLE" "$LOCAL_HEAD"

info "Pushing tag to origin..."
git push origin "$VERSION"

info "Creating GitHub release..."
gh release create "$VERSION" \
    --repo "$REPO" \
    --title "$TITLE" \
    --notes "$RELEASE_NOTES"

info "Uploading $BINARY_NAME (+ .sha256)..."
gh release upload "$VERSION" "$BINARY_PATH" "$BINARY_PATH.sha256" --repo "$REPO"

if [[ -n "$MCPB_PATH" ]]; then
    info "Uploading $(basename "$MCPB_PATH") (+ .sha256)..."
    gh release upload "$VERSION" "$MCPB_PATH" "$MCPB_PATH.sha256" --repo "$REPO"
fi

# ---- Done --------------------------------------------------------------------

info "Release $VERSION published successfully."
echo
echo "View at: https://github.com/$REPO/releases/tag/$VERSION"
