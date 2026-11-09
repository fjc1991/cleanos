# CleanOS

A native macOS cleaner and uninstaller. It removes apps together with everything they leave behind, cleans
caches, logs and the Trash of every disk, manages startup items and extensions, finds duplicates and the
biggest files, and checks your other apps for updates. Everything it removes goes to the Trash first and can
be put back from History. Swift 6 + SwiftUI, free and open source (MIT).

## Install

Download `CleanOS-<version>.dmg` from the [latest release](https://github.com/fjc1991/cleanos/releases/latest),
open it and drag CleanOS into Applications. It needs macOS 14 or later and runs on Apple silicon and Intel.

Releases are signed with the project's own certificate but **not notarized by Apple** (there is no paid Apple
Developer ID behind them yet), so macOS blocks the first launch: open CleanOS once, then go to System Settings →
Privacy & Security and click **Open Anyway**. From then on it opens normally and updates itself (Settings →
Updates).

### Permissions

- **Full Disk Access** (asked on first launch) lets CleanOS see caches, service files and the Trash of every
  disk, and remove other apps. Without it, scans find less and macOS may refuse to delete apps.
- **App Management**: if you skip Full Disk Access, macOS asks you to allow CleanOS under Privacy &
  Security → App Management the first time it removes an app.
- **Administrator password**: apps installed for all users (App Store and installer packages), system daemons
  and other files owned by the system need administrator rights. macOS asks for your password once per
  removal. Optionally, Settings → Helper installs a small helper that does this without asking each time.

## Privacy

CleanOS has no analytics and sends nothing about you or your files anywhere. It goes online only for:

- **Its own updates**: once a day it reads `appcast.xml` from this repository's GitHub releases (Sparkle).
- **The Updates section**, when you open it: it reads the update feed each of your apps declares
  (`SUFeedURL`, the same request the app itself makes), asks Apple's public App Store lookup service about
  apps installed from the App Store (their bundle identifier and your store region), and runs your local
  Homebrew, if installed, which may contact Homebrew's servers.
- **Links you click** (GitHub, Ko-fi).

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
swift test --package-path Packages/HelperProtocol
swift test --package-path Packages/CleanCore
swift test --package-path Packages/UpdateSources
```

Development builds are ad-hoc signed (`CODE_SIGN_IDENTITY=-`). `CleanOS.xcodeproj` is generated and not
committed; run `xcodegen generate` after cloning or after editing `project.yml`. The default scheme runs with
`CLEANOS_DRY_RUN=1`, which simulates every removal without touching the disk or asking for administrator rights.

## Layout

- `App/` – SwiftUI app (sections, settings, theme, the password-prompt runner)
- `Helper/` – the administrator helper: an `SMAppService` daemon, or one-shot behind the password prompt
- `TrashWatcher/` – login item that reacts to apps moved to the Trash
- `Packages/CleanCore` – UI-free engine (scanning, removal, journal, permissions, volumes, rule files)
- `Packages/UpdateSources` – Sparkle / Homebrew / App Store update checks
- `Packages/HelperProtocol` – requests shared by app and helper, path safety rules, allowed tools
- `Scripts/` – `release.sh` (build, sign, DMG, notarization, appcast), `bump-version.sh`, `sparkle-keys.sh`,
  `signing-cert.sh`, `verify-update-signature.swift`, `make-icon.swift`
- `.github/workflows/` – CI build/test and a signed release rehearsal on every push; tagged releases publish

## Versioning and releases

The version lives in one place, `project.yml` (`MARKETING_VERSION` = the version people see,
`CURRENT_PROJECT_VERSION` = the build number Sparkle compares, so it must grow with every release).

```bash
Scripts/bump-version.sh 1.0.1        # sets the version, bumps the build number, regenerates the project
git commit -am "Release 1.0.1" && git tag v1.0.1 && git push && git push origin v1.0.1
```

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds a Release app, signs it, writes the
signed Sparkle `appcast.xml` and publishes a GitHub release with `CleanOS-<version>.dmg` and `appcast.xml`
attached. Installed copies look for updates at
`https://github.com/<owner>/cleanos/releases/latest/download/appcast.xml`.

The same can be done locally with `Scripts/release.sh` (environment: `CODESIGN_IDENTITY`, `TEAM_ID`,
`NOTARY_PROFILE`, optional `GITHUB_REPO`, `KOFI_NAME`, `SPARKLE_PRIVATE_KEY_FILE`).
`SKIP_APPCAST=1 Scripts/release.sh` is a dry run that stops after packaging the DMG.

### One-time setup: two keys to create once and never lose

1. **Sparkle update key** – `Scripts/sparkle-keys.sh github` creates an EdDSA key in your login keychain,
   writes the public half into `project.yml` (`SUPublicEDKey`; commit `project.yml`) and stores the private
   half as the `SPARKLE_PRIVATE_KEY` secret. Installed copies accept only updates signed with this key. Back it
   up: `Scripts/sparkle-keys.sh export <file>`.
2. **Signing certificate** – `Scripts/signing-cert.sh create` makes the project's self-signed code-signing
   certificate (`~/CleanOS-signing/CleanOS-signing.p12`, imported into your login keychain), and
   `Scripts/signing-cert.sh github` stores it as the `CLEANOS_CERTIFICATE_P12` / `CLEANOS_CERTIFICATE_PASSWORD`
   secrets. Every release signed with it has the same identity, so macOS keeps Full Disk Access and other
   permissions across updates, and the helper can trust the app. Back up the `.p12` and its password.

Optional: `KOFI_NAME` repository variable overrides the ko-fi.com page from `project.yml`. Later, with the
Apple Developer Program, the `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`
and `APPLE_APP_PASSWORD` secrets switch releases to Developer ID signing and notarization.

## In-app updates

The app embeds [Sparkle 2](https://sparkle-project.org). It checks once a day and by default downloads a new
version in the background and installs it when you quit CleanOS. Both behaviours are switchable in
Settings → Updates; "Check for Updates…" is in the CleanOS menu and Settings → About. Sparkle verifies every
download against `SUPublicEDKey` before replacing the app.

## Support (Ko-fi)

CleanOS counts launches. From the sixth session on, Overview shows a one-line banner inviting a tip on Ko-fi;
"Not now" hides it for a month, "Don't ask again" (or visiting the page) hides it for good. The link is always
available under Help → Support CleanOS on Ko-fi… and Settings → About.

## Administrator rights and the login item

- Without the helper, anything that needs administrator rights (apps installed for all users, system daemons,
  root-owned leftovers, snapshot deletion, Spotlight reindexing, system permission resets) asks for your
  password once per removal.
- Settings → Helper installs `com.cleanos.helper` through `SMAppService` so it no longer asks; macOS asks for
  approval under System Settings → General → Login Items & Extensions. It accepts only a CleanOS signed with
  the same certificate, so ad-hoc builds do not offer it.
- Settings → General enables the Trash watcher (`CleanOS Trash Watcher`), a login item that notifies you
  when an app lands in the Trash and offers to remove its leftovers. It needs Full Disk Access to watch
  `~/.Trash`; otherwise it notices apps that disappear from the application folders.

## Safety

Every removal moves items to the Trash of their volume unless "Delete permanently" is chosen (things already
in a Trash, and system settings, are always permanent), and is journaled under
`~/Library/Application Support/com.cleanos/Journal` so it can be restored from History. Items marked Caution
(user data, shared vendor folders, keychain items, iCloud containers, screenshots, installers) are never
selected by default. A last check before anything is removed refuses system locations, home and Library
folders, disks and the Skip List, and the administrator helper repeats that check itself.

## Everyday use

- **⌘R** rescans the current section; **⌘Y** (or the History link under the sidebar) opens every removal session with per-item Restore.
- The sidebar shows live totals: junk found, installed apps and high-confidence Remains, startup items enabled, updates available.
- Applications: the Uninstall button acts on the highlighted app when nothing is ticked; a group row ticks every app of that developer; the filter menu finds apps not opened recently (threshold in Settings → Advanced), over 1 GB, not notarized or outside the App Store. Expert Mode is remembered.
- Remains hides low-confidence groups (mostly iCloud containers of iPhone apps) behind a checkbox.
- The review sheet lets you untick single items and warns which running apps will be quit; the result screen explains anything that could not be removed and offers the fix.
- Extensions → Default Applications changes which app opens common file types and links.

## License

MIT, see [LICENSE](LICENSE). Includes [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT). Security
reports: see [SECURITY.md](SECURITY.md).
