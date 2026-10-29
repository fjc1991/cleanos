import Foundation
import Darwin

/// Physical memory usage as shown in Activity Monitor.
public struct MemoryStats: Sendable {
    public let total: Int64
    public let used: Int64
    public let wired: Int64
    public let compressed: Int64
    public let appMemory: Int64
    public let cached: Int64
    public let free: Int64
    public let swapUsed: Int64

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current() -> MemoryStats? {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(sysconf(_SC_PAGESIZE))
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let active = Int64(stats.active_count) * page
        let speculative = Int64(stats.speculative_count) * page
        let purgeable = Int64(stats.purgeable_count) * page
        let external = Int64(stats.external_page_count) * page
        let free = Int64(stats.free_count) * page
        let appMemory = max(0, active + speculative - purgeable - external)
        let used = appMemory + wired + compressed
        var swap = xsw_usage()
        var swapLength = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapLength, nil, 0)
        return MemoryStats(total: Int64(size), used: used, wired: wired, compressed: compressed, appMemory: appMemory,
                           cached: external, free: free, swapUsed: Int64(swap.xsu_used))
    }
}
