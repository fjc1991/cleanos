#!/bin/zsh
# One-time setup of the Sparkle EdDSA key pair that signs every update.
#   Scripts/sparkle-keys.sh            → creates the key in the login keychain (if missing) and writes the public
#                                        key into project.yml
#   Scripts/sparkle-keys.sh github     → the above, then stores the private key as the SPARKLE_PRIVATE_KEY secret
#                                        of this GitHub repository (needs `gh`, signed in)
#   Scripts/sparkle-keys.sh export F   → writes the private key to file F, to back it up
# Keep the private key safe and backed up: updates signed with any other key are refused by installed copies,
# and GitHub never shows a secret again once it is stored.
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

# Creates the key when the keychain has none, then makes project.yml carry its public half.
ensure_key() {
  local PUBLIC
  PUBLIC="$("$TOOL" -p 2>/dev/null || true)"
  if [[ -z "$PUBLIC" ]]; then "$TOOL" >/dev/null; PUBLIC="$("$TOOL" -p)"; fi
  echo "Public key: $PUBLIC"
  if grep -q "SUPublicEDKey: $PUBLIC" project.yml; then
    echo "✓ project.yml already carries this key"
  else
    sed -i '' "s|SUPublicEDKey: .*|SUPublicEDKey: $PUBLIC|" project.yml
    xcodegen generate >/dev/null
    echo "✓ project.yml updated (SUPublicEDKey); commit it"
  fi
}

case "${1:-}" in
  "") ensure_key;;
  export)
    "$TOOL" -x "${2:?usage: sparkle-keys.sh export <file>}"
    echo "✓ private key written to $2 (do not commit it)";;
  github)
    command -v gh >/dev/null || { echo "✗ gh is not installed (brew install gh, then gh auth login)" >&2; exit 1; }
    ensure_key
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    "$TOOL" -x "$TMP/sparkle.key" >/dev/null
    tr -d '\n' < "$TMP/sparkle.key" | gh secret set SPARKLE_PRIVATE_KEY
    echo "✓ SPARKLE_PRIVATE_KEY stored for $(gh repo view --json nameWithOwner -q .nameWithOwner)";;
  *) echo "usage: Scripts/sparkle-keys.sh [github | export <file>]" >&2; exit 1;;
esac
