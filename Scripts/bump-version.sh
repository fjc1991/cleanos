#!/bin/zsh
# Sets the next release version in project.yml and regenerates the Xcode project.
#   Scripts/bump-version.sh 1.0.1          → MARKETING_VERSION 1.0.1, CURRENT_PROJECT_VERSION +1
#   Scripts/bump-version.sh 1.1.0 12       → explicit build number
# Sparkle compares the build number (CFBundleVersion), so it must grow with every release.
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="${1:?usage: Scripts/bump-version.sh <major.minor.patch> [build]}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3" >&2; exit 1; }
CURRENT="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
CURRENT_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
BUILD="${2:-$((CURRENT_BUILD + 1))}"
(( BUILD > CURRENT_BUILD )) || { echo "build $BUILD must be greater than the current build $CURRENT_BUILD" >&2; exit 1; }
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$NEW\"/" \
          -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate >/dev/null
echo "CleanOS $CURRENT ($CURRENT_BUILD) → $NEW ($BUILD)"
echo "Next: git commit -am \"Release $NEW\" && git tag v$NEW && git push && git push origin v$NEW"
