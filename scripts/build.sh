#!/bin/sh
# swift build through the toolchain shim.  Extra arguments reach SwiftPM.
set -e
case "$1" in
    -h|--help)
        cat <<'USAGE'
usage: scripts/build.sh [swift build arguments]

  scripts/build.sh                 debug build of every target
  scripts/build.sh -c release      release build
  scripts/build.sh --help          this text

Always build through this, not plain `swift build`: it routes through
scripts/swiftpm.sh, which masks a broken Command Line Tools install.
For the .app bundle with its icon, use scripts/make-app.sh.
USAGE
        exit 0 ;;
esac
exec "$(cd "$(dirname "$0")" && pwd)/swiftpm.sh" swift build "$@"
