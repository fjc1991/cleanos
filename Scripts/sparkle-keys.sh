#!/bin/zsh
# One-time setup of the Sparkle EdDSA key pair that signs every update.
#   Scripts/sparkle-keys.sh            → creates the key in the login keychain (if missing) and prints the public key
#   Scripts/sparkle-keys.sh export F   → writes the private key to file F (for the SPARKLE_PRIVATE_KEY GitHub secret)
# Keep the private key safe and backed up: updates signed with any other key are refused by installed copies.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOL="$(find build -type f -path '*artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -1)"
if [[ ! -x "$TOOL" ]]; then
  echo "▸ Resolving the Sparkle package to get generate_keys"
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  xcodegen generate >/dev/null
  xcodebuild -resolvePackageDependencies -project CleanOS.xcodeproj -scheme CleanOS -derivedDataPath build/DerivedData >/dev/null
  TOOL="$(find build -type f -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)"
fi
case "${1:-}" in
  export) "$TOOL" -x "${2:?usage: sparkle-keys.sh export <file>}"; echo "✓ private key written to $2 (do not commit it)";;
  "")
    PUBLIC="$("$TOOL" -p 2>/dev/null || true)"
    if [[ -z "$PUBLIC" ]]; then "$TOOL" >/dev/null; PUBLIC="$("$TOOL" -p)"; fi
    echo "Public key: $PUBLIC"
    if grep -q "SUPublicEDKey: $PUBLIC" project.yml; then
      echo "✓ project.yml already carries this key"
    else
      sed -i '' "s|SUPublicEDKey: .*|SUPublicEDKey: $PUBLIC|" project.yml
      xcodegen generate >/dev/null
      echo "✓ project.yml updated (SUPublicEDKey); commit it"
    fi;;
  *) echo "usage: Scripts/sparkle-keys.sh [export <file>]" >&2; exit 1;;
esac
