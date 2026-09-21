#!/bin/sh
# Renders Casks/claude-account-switcher.rb at a given version and checksum.
# The release workflow runs this to update armandrt/homebrew-tap; by hand it is
# the same one line.  Only `version` and `sha256` change — everything else in
# the cask is edited in this repository and travels with it.
set -e

usage() {
    cat <<'USAGE'
usage: scripts/update-cask.sh <version> [--sha256 <hex> | --zip <file>] [--output <file>]

  scripts/update-cask.sh 1.2.3
      downloads the 1.2.3 release zip, hashes it, prints the cask on stdout

  scripts/update-cask.sh 1.2.3 --zip dist/ClaudeAccountSwitcher-1.2.3.zip \
      --output ~/src/homebrew-tap/Casks/claude-account-switcher.rb
      hashes a local zip and writes the tap's copy in place

  --sha256 <hex>   use this checksum instead of hashing anything
  --output <file>  write there instead of stdout (the directory must exist)
USAGE
}

case "$1" in
    -h|--help) usage; exit 0 ;;
    "") echo "update-cask: no version given (e.g. scripts/update-cask.sh 1.2.3)" >&2; usage >&2; exit 2 ;;
esac

VERSION="$1"; shift
case "$VERSION" in
    v*) echo "update-cask: give the version without the leading v (${VERSION#v})" >&2; exit 2 ;;
esac
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' || {
    echo "update-cask: '$VERSION' is not a version like 1.2.3" >&2; exit 2; }

SHA=""
ZIP=""
OUTPUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sha256) SHA="$2"; shift 2 ;;
        --zip) ZIP="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "update-cask: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/Casks/claude-account-switcher.rb"
[ -f "$TEMPLATE" ] || { echo "update-cask: $TEMPLATE is missing" >&2; exit 1; }

if [ -z "$SHA" ]; then
    if [ -n "$ZIP" ]; then
        [ -f "$ZIP" ] || { echo "update-cask: no such zip: $ZIP" >&2; exit 1; }
        SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
    else
        URL="https://github.com/armandrt/claude-account-switcher/releases/download/v$VERSION/ClaudeAccountSwitcher-$VERSION.zip"
        echo "update-cask: hashing $URL" >&2
        SHA="$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}')"
    fi
fi
printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "update-cask: '$SHA' is not a SHA-256 (64 hex characters); the download may have failed" >&2
    exit 1; }

RENDERED="$(sed \
    -e "s|^  version \".*\"\$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"\$|  sha256 \"$SHA\"|" "$TEMPLATE")"

# Fail loudly rather than write a cask that still points at the old release.
printf '%s\n' "$RENDERED" | grep -q "^  version \"$VERSION\"\$" || {
    echo "update-cask: the version line in $TEMPLATE did not match; fix the template" >&2; exit 1; }
printf '%s\n' "$RENDERED" | grep -q "^  sha256 \"$SHA\"\$" || {
    echo "update-cask: the sha256 line in $TEMPLATE did not match; fix the template" >&2; exit 1; }

if [ -n "$OUTPUT" ]; then
    DIRECTORY="$(dirname "$OUTPUT")"
    [ -d "$DIRECTORY" ] || { echo "update-cask: $DIRECTORY does not exist" >&2; exit 1; }
    printf '%s\n' "$RENDERED" > "$OUTPUT"
    echo "update-cask: wrote $OUTPUT ($VERSION, $SHA)" >&2
else
    printf '%s\n' "$RENDERED"
fi
