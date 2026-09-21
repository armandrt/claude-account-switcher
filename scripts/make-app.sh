#!/bin/sh
# Builds ClaudeAccountSwitcher.app from the SwiftPM executable; no Xcode needed.
# The icon is drawn at build time by the app itself, so no artwork is committed.
# Signs with the identity scripts/make-signing-identity.sh creates when it exists,
# so keychain "Always Allow" survives rebuilds; otherwise ad hoc.
set -e

usage() {
    cat <<'USAGE'
usage: scripts/make-app.sh [--release] [--install] [--help]

  (no flags)  debug build; the bundle stays in the repo
  --release   release build: the one worth keeping
  --install   --release, then copy into /Applications; refuses while that copy runs
  --help      this text

environment:
  CAS_VERSION         marketing version, default 0.1.0
  CAS_SIGN_IDENTITY   signing identity, default "Claude Account Switcher Dev"
USAGE
}

CONFIG=debug
INSTALL=no
for argument in "$@"; do
    case "$argument" in
        --release) CONFIG=release ;;
        --install) CONFIG=release; INSTALL=yes ;;
        -h|--help) usage; exit 0 ;;
        *) echo "make-app: unknown argument: $argument" >&2; usage >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/Package.swift" ] || { echo "make-app: $ROOT is not the repo root" >&2; exit 1; }

"$ROOT/scripts/swiftpm.sh" swift build --product ClaudeAccountSwitcher --configuration "$CONFIG"

APP="$ROOT/ClaudeAccountSwitcher.app"
BIN="$ROOT/.build/$CONFIG/ClaudeAccountSwitcher"
[ -x "$BIN" ] || { echo "make-app: $BIN was not built" >&2; exit 1; }

# A version anyone can trace back: the marketing number, the commit count as the
# build number (it only ever grows), and the commit itself in the plist.
VERSION="${CAS_VERSION:-0.1.0}"
if BUILD="$(git --no-optional-locks -C "$ROOT" rev-list --count HEAD 2>/dev/null)" && [ -n "$BUILD" ]; then
    COMMIT="$(git --no-optional-locks -C "$ROOT" rev-parse --short HEAD)"
    git --no-optional-locks -C "$ROOT" diff --quiet HEAD || COMMIT="$COMMIT+uncommitted"
else
    BUILD="$(date +%Y%m%d%H%M)"
    COMMIT="outside a git checkout"
fi

if [ -e "$APP" ]; then
    [ -d "$APP/Contents/MacOS" ] || {
        echo "make-app: $APP exists and is not an app bundle; move it aside" >&2; exit 1; }
    rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeAccountSwitcher"

# The icon comes out of the same vector mark the menu bar wears: the app draws
# the ten sizes, iconutil packs them.  Nothing binary is kept in the repo.
ICONSET="$ROOT/.build/icon/AppIcon.iconset"
command -v iconutil >/dev/null 2>&1 || {
    echo "make-app: iconutil is missing (it ships with macOS)" >&2; exit 1; }
case "$ICONSET" in
    */.build/icon/AppIcon.iconset) rm -rf "$ICONSET" ;;
    *) echo "make-app: refusing to clear $ICONSET" >&2; exit 1 ;;
esac
mkdir -p "$ICONSET"
"$BIN" --render-iconset "$ICONSET" >/dev/null || {
    echo "make-app: the app could not draw its icon ($BIN --render-iconset \"$ICONSET\")" >&2
    exit 1; }
iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/AppIcon.icns" || {
    echo "make-app: iconutil could not assemble $ICONSET" >&2; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Claude Account Switcher</string>
    <key>CFBundleDisplayName</key>           <string>Claude Account Switcher</string>
    <key>CFBundleIdentifier</key>            <string>rt.armand.ClaudeAccountSwitcher</string>
    <key>CFBundleExecutable</key>            <string>ClaudeAccountSwitcher</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD</string>
    <key>CASBuiltFrom</key>                  <string>$COMMIT</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHumanReadableCopyright</key>      <string>armandrt</string>
</dict>
</plist>
PLIST

IDENTITY="${CAS_SIGN_IDENTITY:-Claude Account Switcher Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    SIGN="$IDENTITY"
    HOW="signed as \"$IDENTITY\""
else
    SIGN="-"
    HOW="ad-hoc signed; run scripts/make-signing-identity.sh once so keychain approvals survive rebuilds"
fi
codesign --force --sign "$SIGN" --timestamp=none "$APP" >/dev/null \
    || { echo "make-app: codesign failed ($HOW)" >&2; exit 1; }
codesign --verify --deep --strict "$APP" \
    || { echo "make-app: the bundle did not verify after signing" >&2; exit 1; }

if [ "$INSTALL" = yes ]; then
    DEST="/Applications/ClaudeAccountSwitcher.app"
    if pgrep -f "$DEST/Contents/MacOS/ClaudeAccountSwitcher" >/dev/null 2>&1; then
        echo "make-app: $DEST is running — quit it from the panel (power icon), then run this again" >&2
        exit 1
    fi
    if [ -e "$DEST" ]; then
        WAS="$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" || WAS="unreadable"
        [ "$WAS" = "rt.armand.ClaudeAccountSwitcher" ] || {
            echo "make-app: $DEST is some other app ($WAS); move it aside yourself" >&2; exit 1; }
        rm -rf "$DEST"
    fi
    ditto "$APP" "$DEST" || {
        echo "make-app: could not copy into /Applications (check permissions)" >&2; exit 1; }
    echo "make-app: installed $DEST ($VERSION build $BUILD, $HOW)"
    echo "make-app: open it from Spotlight; \"Launch at login\" is in the panel's footer"
    exit 0
fi

echo "make-app: built $APP ($CONFIG $VERSION build $BUILD, $HOW)"
if [ "$CONFIG" = release ]; then
    echo "make-app: to keep it, run scripts/make-app.sh --install, or drag it into /Applications"
fi
