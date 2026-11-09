import AppKit
import CleanCore
import HelperProtocol

/// Runs one helper request with administrator rights through the standard macOS password prompt
/// ("CleanOS wants to make changes"). Needs no installed helper and no Developer ID, so it always works.
///
/// The helper binary is copied into a private root-owned folder, its signature is checked there (pinned to the
/// certificate CleanOS itself is signed with, when there is one) and only then run, so nothing can swap it between
/// the check and the launch. The request travels inside the authorised command, never through a file. The command
/// runs in the background and writes its JSON answer into a private folder the app polls, so long removals do not
/// freeze the app; only the password dialog itself is modal.
@MainActor
final class AdminAuthorizedRunner {
    static let shared = AdminAuthorizedRunner()

    enum Failure: Error, LocalizedError {
        case cancelled, couldNotStart(String), noAnswer
        var errorDescription: String? {
            switch self {
            case .cancelled: "The administrator password prompt was cancelled."
            case .couldNotStart(let message): "Could not ask for administrator rights: \(message)"
            case .noAnswer: "The administrator helper stopped without an answer."
            }
        }
    }

    private var helperURL: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS/com.cleanos.helper") }

    func perform(_ request: HelperRequest, prompt: String) async -> Result<HelperResponse, Failure> {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return .failure(.couldNotStart("the helper is missing from the app")) }
        guard let encoded = try? JSONEncoder().encode(request) else { return .failure(.couldNotStart("unencodable request")) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "CleanOS-admin-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.couldNotStart(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "result.json")

        let requirement = CodeIdentity.requirement(identifier: HelperConstants.helperBundleIdentifier, pinnedTo: CodeIdentity.leafCertificateHash())
        let body = [
            "d=$(/usr/bin/mktemp -d /private/tmp/cleanos-helper.XXXXXX)",
            "/bin/cp -X \(Self.shellQuote(helperURL.path)) \"$d/helper\"",
            "/usr/bin/codesign --verify -R \(Self.shellQuote("=" + requirement)) \"$d/helper\"",
            "\"$d/helper\" --request \(Self.shellQuote(encoded.base64EncodedString())) --output \(Self.shellQuote(output.path))",
        ].joined(separator: " && ") + "; [ -n \"$d\" ] && /bin/rm -rf \"$d\""
        let command = "( \(body) ) </dev/null >/dev/null 2>&1 & echo $!"
        let source = "do shell script \(Self.appleScriptQuote(command)) with prompt \(Self.appleScriptQuote(prompt)) with administrator privileges"

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.couldNotStart("script error")) }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return .failure(.cancelled) }
            return .failure(.couldNotStart(errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"))
        }
        let pid = pid_t(descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0

        // Poll for the answer; give up once the background command has exited without writing one.
        var goneSince: Date?
        while true {
            if let data = try? Data(contentsOf: output), let response = try? JSONDecoder().decode(HelperResponse.self, from: data) {
                return .success(response)
            }
            let alive = pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
            if !alive {
                if let since = goneSince, Date().timeIntervalSince(since) > 1 { return .failure(.noAnswer) }
                goneSince = goneSince ?? .now
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Adapters used by removals and tools

    func remove(_ requests: [RootRemovalRequest]) async -> [RootRemovalResult] {
        let names = requests.prefix(2).map { URL(filePath: $0.path).lastPathComponent }.joined(separator: ", ")
        let more = requests.count > 2 ? " and \(requests.count - 2) more" : ""
        let prompt = "CleanOS needs administrator rights to remove \(names)\(more), which belong to the system or another user."
        let request = HelperRequest.remove(items: requests, uid: getuid(), gid: getgid())
        switch await perform(request, prompt: prompt) {
        case .success(.removed(let results)): return results
        case .success(.failed(let message)): return requests.map { RootRemovalResult(path: $0.path, error: message) }
        case .success: return requests.map { RootRemovalResult(path: $0.path, error: "Unexpected answer from the helper.") }
        case .failure(let failure):
            let code: Int32? = if case .cancelled = failure { ECANCELED } else { nil }
            return requests.map { RootRemovalResult(path: $0.path, error: failure.localizedDescription, errorCode: code) }
        }
    }

    func run(tool: String, arguments: [String]) async -> (Int32, String, String) {
        let prompt = "CleanOS needs administrator rights to run \(tool)."
        switch await perform(.run(tool: tool, arguments: arguments), prompt: prompt) {
        case .success(.ran(let result)): return (result.status, result.stdout, result.stderr)
        case .success(.failed(let message)): return (-1, "", message)
        case .success: return (-1, "", "Unexpected answer from the helper.")
        case .failure(let failure): return (-1, "", failure.localizedDescription)
        }
    }
}

struct AdminRootRemover: RootRemover {
    func remove(_ requests: [RootRemovalRequest]) async -> [RootRemovalResult] {
        await AdminAuthorizedRunner.shared.remove(requests)
    }
}
