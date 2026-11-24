#!/bin/bash
# Creates a self-signed code-signing identity in a dedicated keychain so every rebuild keeps the
# same designated requirement (Keychain items and notification registration survive rebuilds).
# The keychain password is random and stored mode 600 outside the repo.
set -euo pipefail
NAME="InboxBadge Local Signing"
KC="$HOME/Library/Keychains/inboxbadge-signing.keychain-db"
PWFILE="$HOME/.inboxbadge-signing-pw"

if [ -f "$KC" ] && [ -f "$PWFILE" ] && security find-identity -p codesigning "$KC" | grep -q "$NAME"; then
  echo "identity already present"; exit 0
fi
rm -f "$KC" "$PWFILE"
umask 077
openssl rand -hex 24 > "$PWFILE"
PW=$(cat "$PWFILE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PW"
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security find-identity -p codesigning "$KC" | grep "$NAME"
