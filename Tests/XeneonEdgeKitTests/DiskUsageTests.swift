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

    @Test func apfsContainerRules() {
        #expect(DiskUsage.apfsContainer(ofDevice: "/dev/disk3s7") == "disk3")
        #expect(DiskUsage.apfsContainer(ofDevice: "/dev/disk3s1s1") == "disk3")
        #expect(DiskUsage.apfsContainer(ofDevice: "disk12s2") == "disk12")
        #expect(DiskUsage.apfsContainer(ofDevice: "map auto_home") == nil)
        #expect(DiskUsage.apfsContainer(ofDevice: "//u@NAS/x") == nil)
        #expect(DiskUsage.apfsContainer(ofDevice: "/dev/disk") == nil)
        #expect(DiskUsage.apfsContainer(ofDevice: "") == nil)
    }

    @Test func unmountedPathIsNotMounted() {
        let missing = "/does/not/exist/\(UUID().uuidString)"
        #expect(DiskUsage.readMounted(at: missing) == nil)
        #expect(DiskUsage.ownUsedBytes(ofVolumeAt: missing) == nil)
        // Existierender Ordner, aber kein Mountpunkt: statfs liefert die Eltern-Mount.
        #expect(DiskUsage.readMounted(at: NSTemporaryDirectory()) == nil)
    }

    @Test func bootVolumeIsMountedWithOwnUsage() throws {
        #expect(DiskUsage.readMounted(at: "/") != nil)
        let own = try #require(DiskUsage.ownUsedBytes(ofVolumeAt: "/"))
        #expect(own > 0)
    }

    @Test func emptyPathsYieldNoHighlightAndNoExtras() {
        let stats = SystemStats()
        stats.highlightVolumePath = ""
        stats.extraVolumePaths = []
        let snap = stats.sample()
        #expect(snap.diskHighlight == nil)
        #expect(snap.extraDisks.isEmpty)
    }

    @Test func unmountedConfiguredPathsAreSkippedAndChangeInvalidatesCache() {
        let stats = SystemStats()
        _ = stats.sample()
        stats.highlightVolumePath = "/does/not/exist/\(UUID().uuidString)"
        stats.extraVolumePaths = ["/does/not/exist/\(UUID().uuidString)", "/"]
        let snap = stats.sample()
        #expect(snap.diskHighlight == nil)
        #expect(snap.extraDisks.count == 1)
        #expect(snap.extraDisks.first?.usage.total ?? 0 > 0)
    }

    @Test func namedDiskUsageEquality() {
        let a = NamedDiskUsage(name: "X", usage: DiskUsage(total: 10, available: 4))
        #expect(a == NamedDiskUsage(name: "X", usage: DiskUsage(total: 10, available: 4)))
        #expect(a != NamedDiskUsage(name: "Y", usage: a.usage))
        #expect(a.usage.used == 6)
    }

    @Test func oldConfigWithoutNewKeysDecodesToDefaults() throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(cfg.diskHighlightVolume == "")
        #expect(cfg.extraDiskVolumes.isEmpty)
    }

    @Test func ownUsageIsBoundedByVolumeTotal() throws {
        // Bewusst nur Grenzen, keine Gleichheit: auf Runnern ohne APFS-
        // Mehrfachvolumes ist Eigenverbrauch nicht kleiner als die Fuellung.
        let own = try #require(DiskUsage.ownUsedBytes(ofVolumeAt: "/"))
        let boot = try #require(DiskUsage.read(volumeAt: "/"))
        #expect(own > 0)
        #expect(own <= boot.total)
    }
}
