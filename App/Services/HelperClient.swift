import Foundation
import ServiceManagement
import CleanCore
import HelperProtocol

/// The optional privileged helper (an `SMAppService` daemon). When it is installed and answers, administrator work
/// runs without a password prompt; otherwise `AdminAuthorizedRunner` asks for the password. The helper only accepts
/// a CleanOS signed with its own certificate, so ad-hoc builds never offer it.
@MainActor
@Observable
final class HelperClient {
    enum Status: Equatable { case notRegistered, requiresApproval, enabled, notFound, unknown }

    var status: Status = .unknown
    var version: String?
    var lastError: String?
    /// The helper answered the version handshake with the protocol this app speaks.
    private(set) var isVerified = false

    /// Whether this build can use an installed helper at all: it must be signed with a certificate the helper can pin.
    let isSupported: Bool = {
        #if DEBUG
        return true
        #else
        return CodeIdentity.leafCertificateHash() != nil
        #endif
    }()

    private let service = SMAppService.daemon(plistName: "com.cleanos.helper.plist")

    init() { refresh() }

    var isAvailable: Bool { isSupported && status == .enabled && isVerified }

    func refresh() {
        switch service.status {
        case .notRegistered: status = .notRegistered
        case .requiresApproval: status = .requiresApproval
        case .enabled: status = .enabled
        case .notFound: status = .notFound
        @unknown default: status = .unknown
        }
        if status != .enabled { isVerified = false }
    }

    /// Refreshes the registration and, when enabled, checks that the helper really answers.
    func refreshAndVerify() async {
        refresh()
        guard isSupported, status == .enabled else { return }
        await checkVersion()
    }

    func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func unregister() async {
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// After an update the old daemon can keep running old code; re-registering replaces it.
    func reinstall() async {
        await unregister()
        register()
        await refreshAndVerify()
    }

    func checkVersion() async {
        let answer: (String, Int)? = await call(timeout: .seconds(5), failure: { _ in nil }) { proxy, reply in
            proxy.version { version, protocolVersion in reply((version, protocolVersion)) }
        }
        version = answer?.0
        isVerified = answer?.1 == HelperConstants.protocolVersion
        if let answer, answer.1 != HelperConstants.protocolVersion {
            lastError = "The installed helper (\(answer.0)) is from another version of CleanOS. Reinstall it."
        } else if answer == nil {
            lastError = "The helper is enabled but does not answer."
        } else {
            lastError = nil
        }
    }

    // MARK: Requests

    private func perform(_ request: HelperRequest, timeout: Duration) async -> HelperResponse {
        guard isAvailable, let data = try? JSONEncoder().encode(request) else { return .failed("The helper is not available.") }
        return await call(timeout: timeout, failure: { .failed($0) }) { proxy, reply in
            proxy.perform(data) { answer in
                reply((try? JSONDecoder().decode(HelperResponse.self, from: answer)) ?? .failed("The helper sent an unreadable answer."))
            }
        }
    }

    func remove(_ requests: [RootRemovalRequest]) async -> [RootRemovalResult] {
        switch await perform(.remove(items: requests, uid: getuid(), gid: getgid()), timeout: .seconds(600)) {
        case .removed(let results): return results
        case .failed(let message): return requests.map { RootRemovalResult(path: $0.path, error: message) }
        case .ran: return requests.map { RootRemovalResult(path: $0.path, error: "Unexpected answer from the helper.") }
        }
    }

    func run(tool: String, arguments: [String]) async -> (Int32, String, String) {
        switch await perform(.run(tool: tool, arguments: arguments), timeout: .seconds(120)) {
        case .ran(let result): return (result.status, result.stdout, result.stderr)
        case .failed(let message): return (-1, "", message)
        case .removed: return (-1, "", "Unexpected answer from the helper.")
        }
    }

    /// One XPC call on a fresh connection. Exactly one answer is delivered: the reply, the connection's error (a
    /// refused or dropped connection), or the timeout, whichever comes first, so a caller can never hang.
    private func call<T: Sendable>(timeout: Duration, failure: @escaping @Sendable (String) -> T,
                                   _ body: (CleanOSHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CleanOSHelperProtocol.self)
        #if !DEBUG
        connection.setCodeSigningRequirement(CodeIdentity.requirement(identifier: HelperConstants.helperBundleIdentifier,
                                                                      pinnedTo: CodeIdentity.leafCertificateHash()))
        #endif
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.interruptionHandler = { once.resume(failure("The helper stopped while working.")) }
            connection.invalidationHandler = { once.resume(failure("The helper refused the connection.")) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in once.resume(failure(error.localizedDescription)) }
            guard let helper = proxy as? CleanOSHelperProtocol else {
                once.resume(failure("The helper interface is unavailable."))
                return
            }
            body(helper) { once.resume($0) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(failure("The helper did not answer in time."))
            }
        }
    }
}

/// Resumes a continuation at most once, from whichever path answers first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

struct HelperRootRemover: RootRemover {
    let client: HelperClient
    func remove(_ requests: [RootRemovalRequest]) async -> [RootRemovalResult] {
        await client.remove(requests)
    }
}
