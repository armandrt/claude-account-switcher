#!/bin/sh
# Unit tests.  Nothing touches the network or real keychain items; with
# CAS_KEYCHAIN_TESTS=1 the suite also writes under `CAS Test Login: *` and cleans up.
# Hosted by Tests/Runner: Command Line Tools ship no xctest host, so `swift test`
# there builds the bundle and exits 0 without running anything.
set -e
case "$1" in
    -h|--help)
        cat <<'USAGE'
usage: scripts/test.sh [test runner arguments]

  scripts/test.sh                        every test that touches nothing real
  CAS_KEYCHAIN_TESTS=1 scripts/test.sh   adds the keychain round-trip tests,
                                         which write only under `CAS Test Login: `
  scripts/test.sh --help                 this text
USAGE
        exit 0 ;;
esac
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
"$DIR/swiftpm.sh" swift build
RUNNER="$ROOT/.build/debug/SwitcherCoreTestRunner"
[ -x "$RUNNER" ] || { echo "test: $RUNNER was not built" >&2; exit 1; }
exec "$RUNNER" "$@"
