#!/bin/bash
# Install P215 Scan without Homebrew:
#
#   curl -fsSL https://raw.githubusercontent.com/philipyaz/p215-scan/main/install.sh | bash
#
# Downloads the latest release (which bundles everything, including SANE) and
# puts it in /Applications. Files fetched with curl carry no quarantine flag,
# so the app opens without any Gatekeeper ceremony.
set -euo pipefail

REPO="philipyaz/p215-scan"
APP="P215 Scan.app"
DEST="/Applications"

fail() { echo "error: $1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this is a macOS app"
[ "$(uname -m)" = "arm64" ] || fail "P215 Scan needs an Apple Silicon Mac"

echo "==> finding the latest release"
url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)"
[ -n "$url" ] || fail "could not find a release download; see https://github.com/$REPO/releases"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> downloading ${url##*/}"
curl -#fL "$url" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp"
[ -d "$tmp/$APP" ] || fail "unexpected archive layout"

echo "==> installing to $DEST/$APP"
rm -rf "${DEST:?}/$APP"
ditto "$tmp/$APP" "$DEST/$APP"

echo
echo "Done. Set the scanner's rear Auto Start switch to OFF, plug it in, and:"
echo "  open '$DEST/$APP'"
