#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate in your login
# keychain, so every build of Custom Notch has the same signature and macOS
# keeps its permissions between builds. Nothing is uploaded anywhere.
# To remove it later: Keychain Access → login → My Certificates → delete
# "Custom Notch Local Signing".
set -euo pipefail

NAME="Custom Notch Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
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
CNF

echo "==> Creating certificate"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout pass:customnotch

echo "==> Importing into your login keychain (codesign may use the key)"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P customnotch -T /usr/bin/codesign >/dev/null

echo "==> Testing a signature"
cp /usr/bin/true "$TMP/probe"
if ! codesign --force --sign "$NAME" "$TMP/probe" 2>/dev/null; then
    echo "    macOS wants the certificate trusted for code signing; it will ask for your password."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
    codesign --force --sign "$NAME" "$TMP/probe"
fi

echo "Done. Run ./build.sh again: it will sign with \"$NAME\" from now on."
echo "If a dialog says \"codesign wants to use a key\", choose Always Allow."
