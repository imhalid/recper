#!/bin/zsh
# One-time: creates a self-signed code-signing identity named "recper-dev" (login keychain).
# Why: with ad-hoc signing every build counts as a new app and Screen Recording / Microphone grants (TCC) are lost.
# Signed with a stable certificate, grants survive rebuilds. scripts/bundle.sh uses this identity when present.
# The last step (trust setting) asks for your system password. To undo: delete "recper-dev" in Keychain Access.
set -euo pipefail
NAME=recper-dev
KC=~/Library/Keychains/login.keychain-db
if security find-certificate -c $NAME $KC >/dev/null 2>&1; then echo "$NAME already exists"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf $T' EXIT
cat > $T/cfg <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
# The system LibreSSL produces PKCS#12 that macOS can import (OpenSSL 3's default can't be imported).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout $T/key.pem -out $T/cert.pem -days 3650 -config $T/cfg 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey $T/key.pem -in $T/cert.pem -out $T/id.p12 -passout pass:recper -name $NAME
security import $T/id.p12 -k $KC -P recper -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k $KC $T/cert.pem
security find-identity -v -p codesigning | grep $NAME && echo "done: scripts/bundle.sh now signs with $NAME"
