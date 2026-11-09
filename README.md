# CleanOS

A native macOS cleaner that combines the feature set of MacCleaner Pro and App Cleaner & Uninstaller:
one-pass clean-up, exhaustive app uninstalling, startup/extension management, updates, duplicates,
biggest files and external-disk purging. Swift 6 + SwiftUI, Developer ID (not sandboxed).

## Install

Download `CleanOS-<version>.dmg` from the [latest release](https://github.com/fjc1991/cleanos/releases/latest),
open it and drag CleanOS into Applications. It needs macOS 14 or later and runs on Apple silicon and Intel.

Current releases are **unsigned previews** (there is no Apple Developer ID behind them yet), so macOS blocks
the first launch: open CleanOS once, then go to System Settings → Privacy & Security and click **Open Anyway**.
From then on it opens normally and offers new versions itself (Settings → Updates). The privileged helper for
root-only clean-ups may be refused in unsigned builds.

## Build

Xcode 16+ is required. On a machine where `xcode-select` points at the Command Line Tools, prefix
commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project CleanOS.xcodeproj -scheme CleanOS -configuration Debug build
```

Packages are tested with SwiftPM:

```bash
swift test --package-path Packages/CleanCore
swift test --package-path Packages/UpdateSources
```

Development builds are ad-hoc signed (`CODE_SIGN_IDENTITY=-`). `CleanOS.xcodeproj` is generated and not
committed; run `xcodegen generate` after cloning or after editing `project.yml`.

## Layout

- `App/` – SwiftUI app (sections, settings, theme)
- `Helper/` – privileged helper daemon (`SMAppService.daemon`)
- `TrashWatcher/` – login item that reacts to apps moved to the Trash
- `Packages/CleanCore` – UI-free engine (scanning, removal, journal, permissions, volumes)
- `Packages/UpdateSources` – Sparkle / Homebrew / App Store update checks
- `Packages/HelperProtocol` – XPC protocol shared by app and helper
- `Rules/` – JSON data the scanners load at runtime
- `Scripts/` – `release.sh` (DMG + notarization + appcast), `bump-version.sh`, `sparkle-keys.sh`, `verify-update-signature.swift`, `make-icon.swift`
- `.github/workflows/` – CI build/test on every push; tagged releases build, notarize and publish

Run with `CLEANOS_DRY_RUN=1` to log removal plans without touching the disk (the default scheme sets it).

## Versioning and releases

The version lives in one place, `project.yml` (`MARKETING_VERSION` = the version people see,
`CURRENT_PROJECT_VERSION` = the build number Sparkle compares, so it must grow with every release).

```bash
Scripts/bump-version.sh 1.0.1        # sets the version, bumps the build number, regenerates the project
git commit -am "Release 1.0.1" && git tag v1.0.1 && git push && git push origin v1.0.1
```

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds a Release app, signs and notarizes it
(when the Developer ID secrets below are set), writes the signed Sparkle `appcast.xml` and publishes a GitHub
release with `CleanOS-<version>.dmg` and `appcast.xml` attached. Installed copies look for updates at
`https://github.com/<owner>/CleanOS/releases/latest/download/appcast.xml`.

The same can be done locally with `Scripts/release.sh` (environment: `CODESIGN_IDENTITY`, `TEAM_ID`,
`NOTARY_PROFILE`, optional `GITHUB_REPO`, `KOFI_NAME`, `SPARKLE_PRIVATE_KEY_FILE`). Without an identity the
DMG is ad-hoc signed, which other Macs block until the app is allowed by hand (see below).
`SKIP_APPCAST=1 Scripts/release.sh` is a dry run that stops after packaging the DMG.

### One-time setup

1. **Sparkle key pair** – `Scripts/sparkle-keys.sh github` creates an EdDSA key in your login keychain,
   writes the public half into `project.yml` (`SUPublicEDKey`, commit it) and stores the private half as the
   `SPARKLE_PRIVATE_KEY` secret of the GitHub repository. Every update must be signed with this key and
   GitHub never shows a secret again, so keep a backup outside the repository:
   `Scripts/sparkle-keys.sh export <file>`.
2. **GitHub secrets for signing** (Settings → Secrets and variables → Actions): `MACOS_CERTIFICATE_P12`
   (base64 of the "Developer ID Application" .p12), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`,
   `APPLE_APP_PASSWORD` (app-specific password). Optional repository variable `KOFI_NAME` overrides the
   ko-fi.com page name from `project.yml`.
3. **Links** – `CLEANOS_GITHUB_REPO` and `CLEANOS_KOFI_NAME` in `project.yml` feed the Help menu,
   Settings → About and the support nudge. The release script overrides the repository from the git remote.

A Developer ID certificate needs the Apple Developer Program. Until it is configured, releases are ad-hoc
signed: macOS blocks them on first launch (people have to allow the app under System Settings → Privacy &
Security → Open Anyway) and the privileged helper may be refused.

## In-app updates

The app embeds [Sparkle 2](https://sparkle-project.org). It checks once a day (`SUScheduledCheckInterval`),
and by default downloads the new version in the background and asks before installing it
(`SUAutomaticallyUpdate`). Both behaviours are switchable in Settings → Updates; "Check for Updates…" is in
the CleanOS menu and Settings → About. Sparkle verifies every download against `SUPublicEDKey` and the
app's code signature before replacing `/Applications/CleanOS.app`.

## Support (Ko-fi)

CleanOS counts launches. From the sixth session on, Overview shows a one-line banner inviting a tip on Ko-fi;
"Not now" hides it for a month, "Don't ask again" (or visiting the page) hides it for good. The link is always
available under Help → Support CleanOS on Ko-fi… and Settings → About. Nothing is shown while
`CLEANOS_KOFI_NAME` is still the placeholder.

## Privileged helper and login item

- Settings → Helper enables `com.cleanos.helper` through `SMAppService`. macOS asks for approval under
  System Settings → General → Login Items & Extensions. Root-only removals, snapshot deletion, Spotlight
  reindexing and system permission resets need it.
- Settings → General enables the Trash watcher (`CleanOS Trash Watcher`), a login item that notifies you
  when an app lands in the Trash and offers to remove its leftovers. It needs Full Disk Access to watch
  `~/.Trash`; otherwise it diffs the application folders.

## Safety

Every removal moves items to the Trash of their volume unless "Delete items permanently" is chosen, and is
journaled under `~/Library/Application Support/com.cleanos/Journal` so it can be restored. Items marked
Caution (user data, shared vendor folders, keychain items, iCloud containers) are never selected by default.
Protected locations (`/System`, `/usr`, Apple identifiers, the Skip List) are never selectable.

## Everyday use

- **⌘R** rescans the current section; **⌘Y** (or the History link under the sidebar) opens every removal session with per-item Restore.
- The sidebar shows live totals: junk found, installed apps and high-confidence Remains, startup items enabled, updates available.
- Applications: the Uninstall button acts on the highlighted app when nothing is ticked; a group row ticks every app of that developer; the filter menu finds apps not opened recently (threshold in Settings → Advanced), over 1 GB, not notarized or outside the App Store. Expert Mode is remembered.
- Remains hides low-confidence groups (mostly iCloud containers of iPhone apps) behind a checkbox.
- The review sheet lets you untick single items, warns which running apps will be quit, and can enable the helper in place; a notification arrives if the clean-up finishes while another app is in front.
- Extensions → Default Applications changes which app opens common file types and links.
