import Foundation
import Testing
@testable import CleanCore

@Suite struct ModelTests {
    @Test func scanItemRollsUpSizes() {
        let leaf1 = ScanItem(url: URL(filePath: "/tmp/a"), title: "a", kind: .file, group: "Caches", size: 10)
        let leaf2 = ScanItem(url: URL(filePath: "/tmp/b"), title: "b", kind: .file, group: "Caches", size: 5, tier: .caution)
        let group = ScanItem(id: "group", title: "Caches", kind: .group, group: "Caches", children: [leaf1, leaf2]).rollingUpSizes()
        #expect(group.size == 15)
        #expect(group.leaves.count == 2)
        #expect(group.flattened.count == 3)
    }

    @Test func riskTierOrderingAndDefaults() {
        #expect(RiskTier.safe < RiskTier.protected)
        #expect(RiskTier.caution.isSelectable && !RiskTier.caution.isSelectableByDefault)
        #expect(!RiskTier.protected.isSelectable)
    }

    @Test func volumeCatalogListsRootVolume() {
        let volumes = VolumeCatalog.mountedVolumes()
        let root = volumes.first { $0.isRoot }
        #expect(root != nil)
        #expect((root?.totalCapacity ?? 0) > 0)
        #expect(volumes.allSatisfy { $0.isRoot || $0.url.path.hasPrefix("/Volumes/") })
    }

    @Test func fullDiskAccessProbeReturnsAStatus() {
        let status = FullDiskAccess.status()
        #expect(status == .granted || status == .denied || status == .unknown)
    }
}
