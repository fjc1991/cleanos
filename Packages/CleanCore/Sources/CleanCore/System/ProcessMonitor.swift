import Foundation
import Darwin

/// A running process with its memory footprint.
public struct RunningProcess: Identifiable, Sendable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let path: String?
    public let memoryFootprint: Int64
    public let cpuSeconds: Double
    public let uid: uid_t

    /// The `.app` bundle the executable lives in, if any.
    public var appBundlePath: String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.upperBound].dropLast())
    }
}

/// Memory used by all processes of one app ("Heavy applications").
public struct AppMemoryUsage: Identifiable, Sendable, Hashable {
    public var id: String { bundlePath ?? name }
    public let name: String
    public let bundlePath: String?
    public let processes: [RunningProcess]
    public var memory: Int64 { processes.reduce(0) { $0 + $1.memoryFootprint } }
    public var pids: [Int32] { processes.map(\.pid) }
}

public enum ProcessMonitor {
    /// Snapshot of every process the current user can inspect (own processes without root).
    public static func snapshot() -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [RunningProcess] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var usage = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
            }
            guard ok == 0 else { continue }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : nil
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0 ? String(cString: nameBuffer) : (path.map { URL(filePath: $0).lastPathComponent } ?? "pid \(pid)")
            var info = proc_bsdinfo()
            let infoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            let uid = infoSize > 0 ? info.pbi_uid : 0
            result.append(RunningProcess(pid: pid, name: name, path: path, memoryFootprint: Int64(usage.ri_phys_footprint),
                                         cpuSeconds: Double(usage.ri_user_time + usage.ri_system_time) / 1_000_000_000, uid: uid))
        }
        return result
    }

    /// Processes whose executable lives inside the bundle (the app itself, helpers, XPC services, login items).
    public static func processes(inBundle bundlePath: String) -> [RunningProcess] {
        // proc_pidpath reports fully resolved paths (/private/var/…), so compare against the resolved bundle path too.
        var candidates = [bundlePath]
        if let resolved = realpath(bundlePath, nil) { candidates.append(String(cString: resolved)); free(resolved) }
        let prefixes = Set(candidates.map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        return snapshot().filter { process in
            guard let path = process.path else { return false }
            return prefixes.contains { path.hasPrefix($0) } || candidates.contains(path)
        }
    }

    /// Terminates every process inside the bundle: SIGTERM first, SIGKILL for whatever is still alive after the grace period.
    /// Returns the pids that could not be stopped (processes of other users need the helper).
    public static func forceStop(bundlePath: String, gracePeriod: TimeInterval = 2) async -> [Int32] {
        let mine = getuid()
        var targets = processes(inBundle: bundlePath).filter { $0.uid == mine }
        for process in targets { kill(process.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            targets = processes(inBundle: bundlePath).filter { $0.uid == mine }
            if targets.isEmpty { return [] }
        }
        for process in targets { kill(process.pid, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(300))
        return processes(inBundle: bundlePath).map(\.pid)
    }

    /// Groups processes by the app bundle they belong to (helpers and XPC services count towards their app).
    public static func groupByApp(_ processes: [RunningProcess], includeOthers: Bool = false) -> [AppMemoryUsage] {
        var groups: [String: [RunningProcess]] = [:]
        var others: [RunningProcess] = []
        for process in processes {
            if let bundle = process.appBundlePath {
                // Nested helper apps: attribute to the outermost .app.
                let outer = bundle.range(of: ".app/").map { String(bundle[..<$0.upperBound].dropLast()) } ?? bundle
                groups[outer, default: []].append(process)
            } else {
                others.append(process)
            }
        }
        var result = groups.map { path, procs in
            AppMemoryUsage(name: URL(filePath: path).deletingPathExtension().lastPathComponent, bundlePath: path, processes: procs)
        }
        if includeOthers, !others.isEmpty {
            result.append(AppMemoryUsage(name: "System processes", bundlePath: nil, processes: others))
        }
        return result.sorted { $0.memory > $1.memory }
    }
}

/// One-off maintenance actions from the Speed Up section.
public enum MaintenanceTask: Sendable, Hashable {
    case reindexSpotlight(mount: String)
    case reindexMail
}

public struct MaintenanceRunner: Sendable {
    public var runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))?
    public init(runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))? = nil) { self.runAsRoot = runAsRoot }

    /// Returns an error description, or nil on success. Mail must already have quit for `.reindexMail`.
    public func run(_ task: MaintenanceTask, home: String = NSHomeDirectory()) async -> String? {
        if FileRemover.isDryRun { return nil }
        switch task {
        case .reindexSpotlight(let mount):
            guard let runAsRoot else { return "Needs administrator rights to rebuild the Spotlight index." }
            let (status, _, err) = await runAsRoot("mdutil", ["-E", mount])
            return status == 0 ? nil : (err.isEmpty ? "mdutil failed (\(status))" : err)
        case .reindexMail:
            // The index files go to the Trash, so they can be put back; Mail rebuilds them on its next launch.
            let mail = URL(filePath: home).appending(path: "Library/Mail")
            guard let versions = try? FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil) else { return "Mail data is not accessible. Grant Full Disk Access." }
            var moved = 0, failed: [String] = []
            for version in versions where version.lastPathComponent.hasPrefix("V") {
                let data = version.appending(path: "MailData")
                for file in (try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("Envelope Index") {
                    let outcome = FileRemover.trash(file)
                    if outcome.succeeded { moved += 1 } else { failed.append(outcome.error ?? file.lastPathComponent) }
                }
            }
            if let first = failed.first { return "Could not move the Mail index to the Trash: \(first)" }
            return moved > 0 ? nil : "No Mail index found to rebuild."
        }
    }
}
