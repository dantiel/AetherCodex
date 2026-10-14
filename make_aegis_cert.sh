#!/bin/bash
# Create a *stable* self-signed code-signing identity for AetherAegis.
#
# Why: macOS keys Screen Recording / Accessibility / Automation consent to the
# requesting process's *designated requirement* — which for an ad-hoc signature
# is the binary's CDHash and therefore changes on every rebuild, forcing the
# prompt again and again. A stable identity (same certificate, same bundle id)
# yields a stable designated requirement, so the shield's grants survive its
# (rare) rebuilds while AetherCodex is endlessly recompiled.
#
# Run once per machine:
#     ./make_aegis_cert.sh
#
# For distribution, replace this with a real Developer ID certificate — the
# architecture (a stable identity on the shield) is identical.
set -euo pipefail

NAME="AetherAegis Identity"
KEYCHAIN=~/Library/Keychains/login.keychain-db

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "✔ Identity '$NAME' already present — nothing to do."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A 20-year self-signed RSA certificate — long-lived so it outlasts the project.
openssl req -new -newkey rsa:2048 -nodes -x509 -days 7300 \
    -subj "/CN=$NAME/O=AetherCodex/OU=Aegis" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

# Bundle cert + key into a PKCS#12 identity and import it into the login keychain,
# granting codesign (and security) the right to use the private key.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: >/dev/null 2>&1

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1

# Trust it for code signing (best-effort; may prompt for keychain access).
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null 2>&1 || true

echo "✔ Created self-signed identity '$NAME' (login keychain)."
echo "   The shield will now keep its TCC grants across rebuilds."
