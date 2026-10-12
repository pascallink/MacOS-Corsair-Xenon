// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct DiskUsageTests {
    @Test func usageIsUsedOverTotal() {
        let disk = DiskUsage(total: 1_000, available: 250)
        #expect(disk.used == 750)
        #expect(disk.usage == 0.75)
    }

    @Test func emptyVolumeReportsZeroUsage() {
        #expect(DiskUsage().usage == 0)
    }

    @Test func availableIsClampedToTotal() {
        // Purgeable space can make the reported free space exceed what a
        // stale total says; that must not underflow `used`.
        let disk = DiskUsage(total: 100, available: 120)
        #expect(disk.used == 0)
        #expect(disk.usage == 0)
    }

    @Test func readsTheBootVolume() throws {
        let disk = try #require(DiskUsage.read(volumeAt: "/"))
        #expect(disk.total > 0)
        #expect(disk.available <= disk.total)
        #expect((0...1).contains(disk.usage))
    }

    @Test func missingPathYieldsNil() {
        #expect(DiskUsage.read(volumeAt: "/does/not/exist/\(UUID().uuidString)") == nil)
    }

    @Test func snapshotCarriesDiskUsage() {
        let snap = SystemStats().sample()
        #expect(snap.disk.total > 0)
    }
}
