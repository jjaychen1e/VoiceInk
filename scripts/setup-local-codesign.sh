#!/usr/bin/env bash
# Creates a long-lived self-signed code signing certificate for local VoiceInk builds.
# This keeps macOS Accessibility / TCC grants stable across `make local` rebuilds.
set -euo pipefail

CERT_NAME="VoiceInk Local Codesign"
STORE_DIR="${HOME}/Library/Application Support/VoiceInk-LocalCodesign"
CRT="${STORE_DIR}/VoiceInkLocalCodesign.crt"
KEY="${STORE_DIR}/VoiceInkLocalCodesign.key"
WORKDIR="$(mktemp -d)"
CONF="${WORKDIR}/codesign.conf"
P12="${WORKDIR}/voiceink.p12"

cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

mkdir -p "${STORE_DIR}"

if security find-identity -p codesigning 2>/dev/null | grep -F "\"${CERT_NAME}\"" >/dev/null; then
  echo "Found existing identity: ${CERT_NAME}"
  security find-identity -p codesigning 2>/dev/null | grep -F "${CERT_NAME}" || true
  echo "Reusing existing certificate. Delete it from Keychain Access if you want to recreate."
  exit 0
fi

cat > "${CONF}" <<'EOF'
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = codesign_ext

[ dn ]
CN = VoiceInk Local Codesign
O  = VoiceInk Local Dev
C  = US

[ codesign_ext ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

echo "Creating 10-year self-signed certificate: ${CERT_NAME}"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "${KEY}" -out "${CRT}" -config "${CONF}" -extensions codesign_ext

chmod 600 "${KEY}"

if openssl pkcs12 -help 2>&1 | grep -q -- '--legacy'; then
  openssl pkcs12 -export -legacy -out "${P12}" -inkey "${KEY}" -in "${CRT}" \
    -name "${CERT_NAME}" -passout pass:voiceink-local
else
  openssl pkcs12 -export -out "${P12}" -inkey "${KEY}" -in "${CRT}" \
    -name "${CERT_NAME}" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
    -passout pass:voiceink-local
fi

security import "${P12}" -k ~/Library/Keychains/login.keychain-db -P voiceink-local \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign

# Best-effort user trust for code signing (may still show CSSMERR_TP_NOT_TRUSTED).
security add-trusted-cert -d -r unspecified -p codeSign "${CRT}" >/dev/null 2>&1 || true

echo
echo "Imported: ${CERT_NAME}"
echo "Backup saved under: ${STORE_DIR}"
echo
security find-identity -p codesigning 2>/dev/null | grep -F "${CERT_NAME}" || true
echo
echo "Test signing..."
TEST_FILE="$(mktemp)"
echo test > "${TEST_FILE}"
codesign -s "${CERT_NAME}" -f "${TEST_FILE}"
codesign -dv "${TEST_FILE}" 2>&1 | head -12
rm -f "${TEST_FILE}"
echo
echo "Done. Use: make local"
