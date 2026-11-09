#!/bin/zsh
# Builds a Release CleanOS.app, signs it, packages a DMG, notarizes + staples it (Developer ID only) and writes the
# signed Sparkle appcast the app's updater reads.
#
# Signing identities, best first:
#   "Developer ID Application: Name (TEAMID)"   notarized, opens without warnings
#   "CleanOS Code Signing"                      the project's self-signed certificate (Scripts/signing-cert.sh): a
#                                               stable identity, so permissions survive updates; "Open Anyway" once
#   "-"                                         ad hoc: a new identity every build; for local testing only
#
# Environment:
#   CODESIGN_IDENTITY         one of the identities above                 default: "-"
#   TEAM_ID                   10-character team identifier                default: empty
#   NOTARY_PROFILE            profile from `xcrun notarytool store-credentials`; notarization is skipped when empty
#   GITHUB_REPO               owner/CleanOS                               default: parsed from `git remote get-url origin`
#   KOFI_NAME                 Ko-fi page name (ko-fi.com/<name>)          default: CLEANOS_KOFI_NAME in project.yml
#   SPARKLE_PRIVATE_KEY_FILE  EdDSA private key exported with `generate_keys -x`; default: the key in the login keychain
#   SKIP_TESTS=1              skip the package tests
#   SKIP_APPCAST=1            dry run: build and package the DMG only, without the update key or the appcast
#   DEVELOPER_DIR             Xcode to use                                default: the selected Xcode, or
#                             /Applications/Xcode.app when only the Command Line Tools are selected
#
# Output: build/CleanOS-<version>.dmg and build/appcast.xml. Attach BOTH to the GitHub release tagged v<version>;
# installed copies read https://github.com/<repo>/releases/latest/download/appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."
# Respect the Xcode chosen with xcode-select (CI picks one that way); fall back to /Applications/Xcode.app only
# when the Command Line Tools are selected, because they cannot build the app.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$SELECTED" != *.app/Contents/Developer && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
IDENTITY="${CODESIGN_IDENTITY:--}"
TEAM="${TEAM_ID:-}"
VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
OUT="build/Release"
APP="$OUT/Build/Products/Release/CleanOS.app"
DMG="build/CleanOS-$VERSION.dmg"
APPCAST="build/appcast.xml"

# The GitHub repository decides the update feed and the links inside the app.
if [[ -z "${GITHUB_REPO:-}" ]]; then
  REMOTE="$(git remote get-url origin 2>/dev/null || true)"
  GITHUB_REPO="$(printf '%s' "$REMOTE" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
fi
if [[ -z "$GITHUB_REPO" || "$GITHUB_REPO" == *YOUR-GITHUB-USER* || "$GITHUB_REPO" != */* ]]; then
  echo "✗ GITHUB_REPO is not set and no GitHub 'origin' remote was found. Export GITHUB_REPO=owner/CleanOS." >&2
  exit 1
fi
KOFI="${KOFI_NAME:-$(sed -n 's/.*CLEANOS_KOFI_NAME: "\(.*\)"/\1/p' project.yml | head -1)}"
if [[ "$KOFI" == *YOUR-KOFI-NAME* ]]; then
  echo "⚠ CLEANOS_KOFI_NAME is still the placeholder; the tip link and nudge stay hidden in this build (set it in project.yml or KOFI_NAME=...)."
fi

echo "▸ CleanOS $VERSION ($BUILD) for github.com/$GITHUB_REPO"
echo "▸ Generating project"
xcodegen generate >/dev/null

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "▸ Running package tests"
  swift test --package-path Packages/CleanCore >/dev/null
  swift test --package-path Packages/UpdateSources >/dev/null
fi

echo "▸ Building Release"
# Built ad hoc, then every component is re-signed with the real identity below (Xcode may not accept a self-signed one).
# Judge the build by xcodebuild's own exit status: an app left over from an earlier build must never be packaged.
BUILD_LOG="build/release-build.log"
mkdir -p build
if ! xcodebuild -project CleanOS.xcodeproj -scheme CleanOS -configuration Release -derivedDataPath "$OUT" \
  CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
  CLEANOS_GITHUB_REPO="$GITHUB_REPO" CLEANOS_KOFI_NAME="$KOFI" build > "$BUILD_LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$BUILD_LOG" || tail -40 "$BUILD_LOG"
  echo "✗ build failed (full log: $BUILD_LOG)" >&2
  exit 1
fi
[ -d "$APP" ] || { echo "✗ the build reported success but $APP is missing" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")"
PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
if [[ "$PUBKEY" == *PLACEHOLDER* || -z "$PUBKEY" ]]; then
  if [[ "${SKIP_APPCAST:-0}" == "1" ]]; then
    echo "⚠ SUPublicEDKey is still the placeholder: this dry-run build cannot update itself. Do not publish it."
  else
    echo "✗ SUPublicEDKey is not set in project.yml. Run Scripts/sparkle-keys.sh once and commit the public key." >&2
    exit 1
  fi
fi
echo "▸ Update feed: $FEED"

# Sign inside-out with the hardened runtime. Everything is re-signed, including the helper and the Trash Watcher,
# so the get-task-allow entitlement Xcode adds to development signatures never ships in a root daemon.
ENTITLEMENTS="App/CleanOS.entitlements"
if [[ "$IDENTITY" == Developer\ ID* ]]; then
  echo "▸ Signing with $IDENTITY"
  TIMESTAMP=(--timestamp)
else
  if [[ "$IDENTITY" == "-" ]]; then
    echo "⚠ Ad-hoc signed: every build gets a new identity, so macOS forgets granted permissions after updates. Use the"
    echo "  project certificate (Scripts/signing-cert.sh) or a Developer ID for anything you publish."
  else
    echo "▸ Signing with the self-signed certificate \"$IDENTITY\" (not notarized: users click Open Anyway once)"
  fi
  TIMESTAMP=(--timestamp=none)
  # Without an Apple team ID the hardened runtime's library validation refuses the embedded Sparkle framework and the
  # app dies at launch. Keep the hardened runtime and waive only that check.
  ENTITLEMENTS="$(mktemp -d)/CleanOS.entitlements"
  cp App/CleanOS.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
sign() { codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
fi
sign "$APP/Contents/MacOS/com.cleanos.helper"
sign "$APP/Contents/Library/LoginItems/CleanOS Trash Watcher.app"
sign --entitlements "$ENTITLEMENTS" "$APP"
[[ "$ENTITLEMENTS" == App/* ]] || rm -rf "$(dirname "$ENTITLEMENTS")"
codesign --verify --deep --strict "$APP"
for BINARY in "$APP/Contents/MacOS/com.cleanos.helper" "$APP/Contents/Library/LoginItems/CleanOS Trash Watcher.app"; do
  if codesign -d --entitlements - --xml "$BINARY" 2>/dev/null | grep -q get-task-allow; then
    echo "✗ $BINARY still carries get-task-allow" >&2; exit 1
  fi
done

# dyld loads the embedded frameworks under the final signature before main() runs, so this catches a build
# that cannot start (wrong signature, missing framework) before it is packaged.
echo "▸ Checking that the signed app starts"
"$APP/Contents/MacOS/CleanOS" --smoke-test || { echo "✗ the signed app cannot start; see the message above" >&2; exit 1; }

echo "▸ Packaging $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# hdiutil sometimes reports "Resource busy" on CI machines while Spotlight or XProtect still holds the folder.
for ATTEMPT in 1 2 3; do
  hdiutil create -volname "CleanOS" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null && break
  [[ "$ATTEMPT" == 3 ]] && { echo "✗ hdiutil could not create the DMG"; exit 1; }
  echo "  hdiutil failed (attempt $ATTEMPT), retrying"; sleep 5
done
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  echo "▸ Notarizing"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

if [[ "${SKIP_APPCAST:-0}" == "1" ]]; then
  echo "✓ $DMG (dry run: no appcast written)"
  exit 0
fi

echo "▸ Writing Sparkle appcast"
GENERATE_APPCAST="$(find "$OUT/SourcePackages/artifacts" -type f -name generate_appcast 2>/dev/null | head -1)"
[[ -x "$GENERATE_APPCAST" ]] || { echo "✗ generate_appcast not found under $OUT/SourcePackages (did the Sparkle package resolve?)"; exit 1; }
APPCAST_DIR="build/appcast"
rm -rf "$APPCAST_DIR"; mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
KEY_ARGS=()
[[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
"$GENERATE_APPCAST" "${KEY_ARGS[@]}" \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$GITHUB_REPO/releases/tag/v$VERSION" \
  -o "$APPCAST" "$APPCAST_DIR"
grep -q "sparkle:edSignature" "$APPCAST" || { echo "✗ appcast has no EdDSA signature"; exit 1; }
# Installed copies accept an update only if this signature verifies against the SUPublicEDKey they carry.
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -1)"
if ! swift Scripts/verify-update-signature.swift "$DMG" "$SIGNATURE" "$PUBKEY"; then
  echo "✗ The update is signed with a key that does not match SUPublicEDKey in the app; installed copies would" >&2
  echo "  refuse it. Check that the signing key is the one Scripts/sparkle-keys.sh wrote into project.yml." >&2
  exit 1
fi
echo "▸ Update signature matches the key in the app"
rm -rf "$APPCAST_DIR"

echo "✓ $DMG"
echo "✓ $APPCAST"
echo "  Next: git tag v$VERSION && git push --tags, then attach both files to the GitHub release v$VERSION"
echo "  (the release workflow does this automatically when the tag is pushed)."
