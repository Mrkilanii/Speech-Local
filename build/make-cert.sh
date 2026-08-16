#!/bin/bash
# Creates a stable self-signed code-signing identity in the login keychain.
#
# Why this exists: ad-hoc signing (`codesign -s -`) mints a new identity on every
# build, so macOS treats each build as a different app and silently drops the
# Accessibility grant — with no prompt to re-approve. A stable identity keeps the
# grant across rebuilds.
#
# Self-signed is sufficient because distribution is source-only: every user
# builds and signs locally. A Developer ID would only matter for shipping
# binaries to other machines.
set -euo pipefail

IDENTITY="${1:-SpeechLocal Dev}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already exists. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing certificate: $IDENTITY"

# extendedKeyUsage=codeSigning is what makes it show up under
# `find-identity -p codesigning`. Without it the cert exists but is unusable.
cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = $IDENTITY

[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" 2>/dev/null

# A throwaway transfer password. macOS `security import` mishandles an empty
# password ("MAC verification failed"), so the bundle is never actually
# password-free — this value only has to survive the next three lines.
P12PASS="speechlocal-transfer"

openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12PASS"

# -T /usr/bin/codesign pre-authorizes codesign to use the key, which avoids a
# keychain prompt on every single build.
security import "$WORK/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security

echo ""
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "SUCCESS — '$IDENTITY' is ready."
    security find-identity -p codesigning | grep "$IDENTITY"
    echo ""
    echo "If the first 'make sign' shows a keychain access dialog, choose"
    echo "'Always Allow' so later builds run without prompting."
else
    echo "Certificate imported but not listed as a codesigning identity."
    echo "Check: security find-identity -p codesigning"
    exit 1
fi
