#!/bin/sh
# Packages a release: a release build of the app, a zip and a DMG beside each
# other in dist/, and their SHA-256 sums.  .github/workflows/release.yml runs
# this on a tag; it runs the same way on a laptop.
#
# Nothing here signs with a Developer ID or notarises: that needs a paid Apple
# Developer Program membership.  The bundle carries whatever signature
# scripts/make-app.sh gave it (self-signed locally, ad hoc on a runner), which
# means a downloader has to clear the quarantine attribute by hand or let
# Homebrew do it — see README.md.
set -e

usage() {
    cat <<'USAGE'
usage: scripts/release.sh <version> [--help]

  scripts/release.sh 1.2.3    builds ClaudeAccountSwitcher.app at 1.2.3 and writes
                              dist/ClaudeAccountSwitcher-1.2.3.zip
                              dist/ClaudeAccountSwitcher-1.2.3.dmg
                              dist/SHA256SUMS.txt

The version is the tag without its leading v.  Nothing is uploaded: the release
workflow does that, or `gh release create` by hand.
USAGE
}

case "$1" in
    -h|--help) usage; exit 0 ;;
    "") echo "release: no version given (e.g. scripts/release.sh 1.2.3)" >&2; usage >&2; exit 2 ;;
esac

VERSION="$1"
case "$VERSION" in
    v*) echo "release: give the version without the leading v (${VERSION#v}, not $VERSION)" >&2; exit 2 ;;
esac
# Loose on purpose: 1.2.3 and 1.2.3-beta.1 both pass, 'latest' does not.
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' || {
    echo "release: '$VERSION' is not a version like 1.2.3" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/Package.swift" ] || { echo "release: $ROOT is not the repo root" >&2; exit 1; }

APP="$ROOT/ClaudeAccountSwitcher.app"
DIST="$ROOT/dist"
ZIP="$DIST/ClaudeAccountSwitcher-$VERSION.zip"
DMG="$DIST/ClaudeAccountSwitcher-$VERSION.dmg"

# Ad hoc on purpose, not the local self-signed identity: that identity exists
# only in one keychain, so it makes a downloader's Gatekeeper no happier while
# stamping a personal name into every copy — and a CI runner has no identity at
# all, so this also makes a laptop release and a workflow release the same thing.
CAS_VERSION="$VERSION" CAS_SIGN_IDENTITY="-" "$ROOT/scripts/make-app.sh" --release
[ -d "$APP" ] || { echo "release: $APP was not built" >&2; exit 1; }
BUILT="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || {
    echo "release: the bundle says $BUILT, not $VERSION" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || {
    echo "release: the bundle does not verify; refusing to package it" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"

# ditto, not zip: it keeps the bundle's symlinks, resource forks and code
# signature intact, so the unzipped copy is still a signed app.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# A plain DMG: the app, and a symlink to /Applications to drag it into.  No
# background picture, no window geometry, no third-party tooling.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
ditto "$APP" "$STAGE/ClaudeAccountSwitcher.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Claude Account Switcher" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov -quiet "$DMG" || {
    echo "release: hdiutil could not build $DMG" >&2; exit 1; }
rm -rf "$STAGE"
trap - EXIT INT TERM

# Basenames only, so `shasum -a 256 -c SHA256SUMS.txt` works from inside dist/.
( cd "$DIST" && shasum -a 256 \
    "ClaudeAccountSwitcher-$VERSION.zip" \
    "ClaudeAccountSwitcher-$VERSION.dmg" > SHA256SUMS.txt )

echo "release: dist/ holds $VERSION"
cat "$DIST/SHA256SUMS.txt"
echo "release: not signed with a Developer ID and not notarised (no Apple Developer Program membership)"
