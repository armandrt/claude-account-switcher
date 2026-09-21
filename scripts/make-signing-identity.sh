#!/bin/sh
# One self-signed code-signing identity, kept so a keychain "Always Allow"
# survives a rebuild: an ad-hoc signature changes every time.  See --help.
set -e
usage() {
    cat <<'USAGE'
usage: scripts/make-signing-identity.sh [--help]

Creates one self-signed code-signing identity in your login keychain, so every
build carries the same signature and a keychain "Always Allow" survives a
rebuild.  Already there: says so and stops.  Nothing leaves the machine, and
nothing system-wide is trusted.  To undo, delete the identity by name in
Keychain Access.

  CAS_SIGN_IDENTITY   the name to create, default "Claude Account Switcher Dev"
USAGE
}

case "$1" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) echo "make-signing-identity: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

NAME="${CAS_SIGN_IDENTITY:-Claude Account Switcher Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[ -f "$KEYCHAIN" ] || { echo "make-signing-identity: no login keychain at $KEYCHAIN" >&2; exit 1; }

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "make-signing-identity: \"$NAME\" already exists, nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A certificate whose only purpose is code signing, valid ten years.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>"$TMP/err" \
    || { cat "$TMP/err" >&2; exit 1; }

# OpenSSL 3 needs -legacy for a bundle the macOS importer accepts; LibreSSL has no such flag.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
|| openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PASS" 2>"$TMP/err" \
|| { cat "$TMP/err" >&2; exit 1; }

# -T lets codesign use the private key without a dialog of its own.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null \
    || { echo "make-signing-identity: the keychain would not import the identity" >&2; exit 1; }
# Trusted for code signing in the login keychain only (no -d: nothing system-wide).
echo "make-signing-identity: macOS will ask for your login password to trust \"$NAME\"" >&2
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
    || { echo "make-signing-identity: the certificate was imported but not trusted" >&2; exit 1; }

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "make-signing-identity: created \"$NAME\""
else
    echo "make-signing-identity: imported, but codesign sees no valid identity named \"$NAME\"" >&2
    exit 1
fi
