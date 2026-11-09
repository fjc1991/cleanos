#!/bin/zsh
# Builds a Release CleanOS.app, signs it with a Developer ID identity when one is configured, packages a DMG,
# notarizes + staples it (optional) and writes the signed Sparkle appcast the app's updater reads.
#
# Environment:
#   CODESIGN_IDENTITY         "Developer ID Application: Name (TEAMID)"   default: "-" (ad hoc: runs only on this Mac)
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
# Judge the build by xcodebuild's own exit status: an app left over from an earlier build must never be packaged.
BUILD_LOG="build/release-build.log"
mkdir -p build
if ! xcodebuild -project CleanOS.xcodeproj -scheme CleanOS -configuration Release -derivedDataPath "$OUT" \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
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

if [[ "$IDENTITY" != "-" ]]; then
  echo "▸ Signing nested components inside-out with hardened runtime"
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
  fi
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/com.cleanos.helper"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Library/LoginItems/CleanOS Trash Watcher.app"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements App/CleanOS.entitlements "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "⚠ Ad-hoc signed: Gatekeeper will block this DMG on other Macs and the privileged helper may be refused. Set CODESIGN_IDENTITY for a real release."
  # An ad-hoc signature carries no team, so the hardened runtime's library validation refuses to load the
  # embedded Sparkle framework and the app dies at launch. Keep the hardened runtime and waive only that check
  # (signing again here also drops the get-task-allow entitlement Xcode injects into ad-hoc builds).
  ADHOC_ENTITLEMENTS="$(mktemp -d)/CleanOS.entitlements"
  cp App/CleanOS.entitlements "$ADHOC_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ADHOC_ENTITLEMENTS"
  codesign --force --options runtime --sign - --entitlements "$ADHOC_ENTITLEMENTS" "$APP"
  rm -rf "$(dirname "$ADHOC_ENTITLEMENTS")"
  codesign --verify --deep --strict "$APP"
fi

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
rm -rf "$APPCAST_DIR"

echo "✓ $DMG"
echo "✓ $APPCAST"
echo "  Next: git tag v$VERSION && git push --tags, then attach both files to the GitHub release v$VERSION"
echo "  (the release workflow does this automatically when the tag is pushed)."
