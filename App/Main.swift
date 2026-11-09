import SwiftUI

/// Entry point. `--smoke-test` exits straight away without touching any state: by the time `main` runs, dyld
/// has already loaded every embedded framework under the app's code signature. `Scripts/release.sh` uses it to
/// prove that the build it is about to package can start at all (an ad-hoc signed build with the hardened
/// runtime cannot load Sparkle unless library validation is waived, and dies before `main`).
@main
enum CleanOSMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            print("CleanOS \(version) loads")
            exit(0)
        }
        CleanOSApp.main()
    }
}
