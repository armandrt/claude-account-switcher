#!/bin/sh
# Runs a SwiftPM command through the toolchain shim (scripts/toolchain-shim.py),
# regenerating it when it is missing or the compiler has changed since.
set -e
usage() {
    cat <<'USAGE'
usage: scripts/swiftpm.sh <command> [arguments]

  scripts/swiftpm.sh swift build
  scripts/swiftpm.sh swift package describe

Sets SWIFT_EXEC to the shim and points SwiftPM at swift-testing, then runs the
command from the repo root.  scripts/build.sh and scripts/test.sh call this.
USAGE
}

case "$1" in
    -h|--help) usage; exit 0 ;;
    "") echo "swiftpm: no command given" >&2; usage >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM="$ROOT/.build-toolchain/swiftc"
STAMP="$ROOT/.build-toolchain/compiler-version"
CURRENT="$(xcrun swift-frontend --version 2>/dev/null | head -n 1)"
[ -n "$CURRENT" ] || CURRENT="$(swift --version 2>/dev/null | head -n 1)"
[ -n "$CURRENT" ] || {
    echo "swiftpm: no Swift compiler found; install the Command Line Tools (xcode-select --install)" >&2
    exit 1; }
if [ ! -x "$SHIM" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$CURRENT" ]; then
    python3 "$ROOT/scripts/toolchain-shim.py" >&2
fi
export SWIFT_EXEC="$SHIM" SWIFT_EXEC_MANIFEST="$SHIM"

# Where swift-testing lives: Command Line Tools first, then an Xcode install.
DEVELOPER="$(xcode-select -p)" || {
    echo "swiftpm: xcode-select -p failed; no developer directory is selected" >&2; exit 1; }
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
[ -d "$FRAMEWORKS" ] || FRAMEWORKS="$DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"
PLUGINS="$DEVELOPER/usr/lib/swift/host/plugins/testing"
[ -d "$PLUGINS" ] || PLUGINS="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
export CAS_DEVELOPER_FRAMEWORKS="$FRAMEWORKS" CAS_TESTING_PLUGINS="$PLUGINS"
cd "$ROOT"
exec "$@"
