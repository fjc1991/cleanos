#!/bin/zsh
# One-time setup of the self-signed certificate every CleanOS release is signed with, until there is a paid Apple
# Developer ID. Signing with one stable certificate (instead of ad hoc) keeps the app's identity the same across
# updates: macOS then keeps Full Disk Access and other permissions after each update, and the privileged helper can
# pin the app it trusts. Gatekeeper still shows "Open Anyway" on first launch, exactly as for ad-hoc builds.
#
#   Scripts/signing-cert.sh create [folder]   → creates the certificate (10 years) as folder/CleanOS-signing.p12
#                                               (default ~/CleanOS-signing) and imports it into the login keychain
#   Scripts/signing-cert.sh github [folder]   → stores the .p12 and its password as the repository secrets
#                                               CLEANOS_CERTIFICATE_P12 / CLEANOS_CERTIFICATE_PASSWORD (needs `gh`)
#
# Keep the .p12 and its password backed up. Losing them means the next release has a different identity: users
# would have to grant permissions again and re-approve the helper. Anyone who has them can sign code the helper
# trusts, so never commit them.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="CleanOS Code Signing"
FOLDER="${2:-$HOME/CleanOS-signing}"
P12="$FOLDER/CleanOS-signing.p12"
OPENSSL=/usr/bin/openssl   # LibreSSL writes .p12 files the macOS keychain can import

ask_password() {
  local first second
  read -rs "first?$1: "; echo
  [[ ${#first} -ge 8 ]] || { echo "✗ The password needs at least 8 characters. Nothing was created; run the command again." >&2; exit 1; }
  if [[ "${2:-}" == confirm ]]; then
    read -rs "second?Repeat it: "; echo
    [[ "$first" == "$second" ]] || { echo "✗ The passwords differ. Nothing was created; run the command again." >&2; exit 1; }
  fi
  PASSWORD="$first"
}

case "${1:-}" in
  create)
    [[ -e "$P12" ]] && { echo "✗ $P12 already exists. Never create a second certificate once a release is signed with one." >&2; exit 1; }
    mkdir -p "$FOLDER"; chmod 700 "$FOLDER"
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = CleanOS
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
    "$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
    ask_password "Choose a password for the certificate file (at least 8 characters)" confirm
    "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$P12" -passout "pass:$PASSWORD"
    chmod 600 "$P12"
    security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    echo "✓ Created $P12 and imported \"$NAME\" into the login keychain."
    echo "  Back up $FOLDER (and the password) somewhere safe, then run: Scripts/signing-cert.sh github"
    echo "  Local release builds use it with: CODESIGN_IDENTITY=\"$NAME\" Scripts/release.sh";;
  github)
    command -v gh >/dev/null || { echo "✗ gh is not installed (brew install gh, then gh auth login)" >&2; exit 1; }
    [[ -f "$P12" ]] || { echo "✗ $P12 not found; run Scripts/signing-cert.sh create first." >&2; exit 1; }
    ask_password "Password of $P12"
    "$OPENSSL" pkcs12 -in "$P12" -passin "pass:$PASSWORD" -noout 2>/dev/null || { echo "✗ Wrong password." >&2; exit 1; }
    base64 -i "$P12" | tr -d '\n' | gh secret set CLEANOS_CERTIFICATE_P12
    printf '%s' "$PASSWORD" | gh secret set CLEANOS_CERTIFICATE_PASSWORD
    echo "✓ CLEANOS_CERTIFICATE_P12 and CLEANOS_CERTIFICATE_PASSWORD stored for $(gh repo view --json nameWithOwner -q .nameWithOwner)";;
  *) echo "usage: Scripts/signing-cert.sh create|github [folder]" >&2; exit 1;;
esac
