#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain and tells the build to use
# it (Config/Local.xcconfig, not checked in).
#
# Why: without a certificate the app is ad-hoc signed, and its signature changes on every build.
# macOS ties permissions such as Accessibility (needed for push to talk and shortcuts while another
# app is in front) to the signature, so each rebuild silently loses them although the switch in
# System Settings still looks on. With a certificate the signature stays the same across builds.
#
# macOS may ask for your login keychain password the first time the certificate is used; choose
# "Always Allow". To undo: delete the certificate and its key in Keychain Access and remove
# Config/Local.xcconfig.
set -euo pipefail

NAME="SwiftSpeak Local Signing"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists."
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
    PASS="$(/usr/bin/openssl rand -hex 16)"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
        -out "$WORK/identity.p12" -passout "pass:$PASS"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
    echo "Created certificate \"$NAME\" in the login keychain."
fi

echo "CODE_SIGN_IDENTITY = $NAME" > "$ROOT/Config/Local.xcconfig"
echo "Builds now sign with it (Config/Local.xcconfig)."
