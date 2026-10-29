import Foundation
import ServiceManagement
import CleanCore
import HelperProtocol

/// Registers the privileged helper with `SMAppService` and talks to it over XPC.
@MainActor
@Observable
final class HelperClient {
    enum Status: Equatable { case notRegistered, requiresApproval, enabled, notFound, unknown }

    var status: Status = .unknown
    var version: String?
    var lastError: String?

    private let service = SMAppService.daemon(plistName: "com.cleanos.helper.plist")
    private var connection: NSXPCConnection?

    init() { refresh() }

    func refresh() {
        switch service.status {
        case .notRegistered: status = .notRegistered
        case .requiresApproval: status = .requiresApproval
        case .enabled: status = .enabled
        case .notFound: status = .notFound
        @unknown default: status = .unknown
        }
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
        connection?.invalidate()
        connection = nil
        refresh()
    }

    var isAvailable: Bool { status == .enabled }

    private func proxy() -> CleanOSHelperProtocol? {
        guard isAvailable else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: CleanOSHelperProtocol.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        } as? CleanOSHelperProtocol
    }

    func checkVersion() async {
        guard let proxy = proxy() else { return }
        version = await withCheckedContinuation { continuation in
            proxy.version { version, _ in continuation.resume(returning: version) }
        }
    }

    func remove(paths: [String], permanently: Bool) async -> [String: String] {
        guard let proxy = proxy() else { return Dictionary(uniqueKeysWithValues: paths.map { ($0, "The helper is not enabled.") }) }
        return await withCheckedContinuation { continuation in
            proxy.remove(paths: paths, permanently: permanently) { continuation.resume(returning: $0) }
        }
    }

    func run(tool: String, arguments: [String]) async -> (Int32, String, String) {
        guard let proxy = proxy() else { return (-1, "", "The helper is not enabled.") }
        return await withCheckedContinuation { continuation in
            proxy.run(tool: tool, arguments: arguments) { continuation.resume(returning: ($0, $1, $2)) }
        }
    }

    func readFile(atPath path: String) async -> Data? {
        guard let proxy = proxy() else { return nil }
        return await withCheckedContinuation { continuation in
            proxy.readFile(atPath: path) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// `RootRemover` for `RemovalExecutor`.
    nonisolated func rootRemover() -> any RootRemover { HelperRootRemover(client: self) }

    /// Closure the registration remover and startup controller use to run whitelisted tools as root.
    nonisolated func rootRunner() -> @Sendable (String, [String]) async -> (Int32, String, String) {
        { tool, arguments in await self.run(tool: tool, arguments: arguments) }
    }
}

struct HelperRootRemover: RootRemover {
    let client: HelperClient
    func remove(paths: [String], permanently: Bool) async -> [String: String] {
        await client.remove(paths: paths, permanently: permanently)
    }
}
