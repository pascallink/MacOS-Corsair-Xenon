// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// System monitoring for the dashboard widgets — the macOS equivalent of the
// iCUE sensor panels. Only public APIs (Mach host statistics, sysctl,
// getifaddrs, volume resource values), so no elevated privileges are needed.

import Darwin
import Foundation

public struct SystemSnapshot {
    public var cpuUsage: Double = 0          // 0...1
    public var perCoreUsage: [Double] = []
    public var memoryUsed: UInt64 = 0        // bytes
    public var memoryTotal: UInt64 = 0
    public var networkRxBytesPerSecond: Double = 0
    public var networkTxBytesPerSecond: Double = 0
    public var uptime: TimeInterval = 0
    public var disk = DiskUsage()
    /// Hervorgehobenes APFS-Volume im Boot-Container: `usage.total` ist die
    /// Container-Groesse, `usage.used` der Eigenverbrauch des Volumes. nil,
    /// wenn nicht konfiguriert, nicht gemountet oder in einem anderen Container.
    public var diskHighlight: NamedDiskUsage?
    /// Konfigurierte Zusatz-Volumes, nur solange sie gemountet sind.
    public var extraDisks: [NamedDiskUsage] = []

    public init() {}

    public var memoryUsage: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
    }
}

/// Fuellstand eines Volumes samt Anzeigename (Mountpunkt-Name).
public struct NamedDiskUsage: Equatable {
    public var name: String
    public var usage: DiskUsage

    public init(name: String, usage: DiskUsage) {
        self.name = name
        self.usage = usage
    }
}

/// Fill level of one volume, counted the way Finder does: purgeable space
/// (local Time Machine snapshots, evictable iCloud files) counts as free.
public struct DiskUsage: Equatable {
    public var total: UInt64 = 0             // bytes
    public var available: UInt64 = 0

    public init(total: UInt64 = 0, available: UInt64 = 0) {
        self.total = total
        self.available = min(available, total)
    }

    public var used: UInt64 { total - available }

    public var usage: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    /// Reads the volume containing `path`; nil if it cannot be queried.
    public static func read(volumeAt path: String = "/") -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage,
              available >= 0 else { return nil }
        return DiskUsage(total: UInt64(total), available: UInt64(available))
    }

    // MARK: Mountpunkte und APFS-Container (statfs, kein IOKit)

    /// Mountpunkt und Device des Dateisystems, das `path` enthaelt. Fuer einen
    /// nicht gemounteten Pfad kommt die Eltern-Mount zurueck.
    public static func mountInfo(ofPath path: String) -> (mountPoint: String, device: String)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mountOn = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let mountFrom = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return (mountOn, mountFrom)
    }

    /// Pfad ohne Symlinks und ohne abschliessenden Schraegstrich.
    static func normalized(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// Mountpunkt und Device von `path`, aber nur wenn `path` selbst ein
    /// Mountpunkt ist (statfs liefert sonst die Eltern-Mount).
    static func mountedInfo(at path: String) -> (mountPoint: String, device: String)? {
        guard let info = mountInfo(ofPath: path),
              normalized(info.mountPoint) == normalized(path) else { return nil }
        return info
    }

    /// Eigenverbrauch eines Volumes in Bytes (ATTR_VOL_SPACEUSED). statfs
    /// taugt dafuer nicht: auf APFS meldet es (f_blocks - f_bfree) containerweit,
    /// also fuer jedes Volume denselben Wert. getattrlist liefert den Verbrauch
    /// des einzelnen Volumes. nil, wenn `path` kein Mountpunkt ist (getattrlist
    /// meldet sonst das Volume des Ordners).
    public static func ownUsedBytes(ofVolumeAt path: String) -> UInt64? {
        guard mountedInfo(at: path) != nil else { return nil }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buf = [UInt8](repeating: 0, count: 64)
        let result = buf.withUnsafeMutableBytes {
            getattrlist(path, &attrs, $0.baseAddress, $0.count, 0)
        }
        guard result == 0 else { return nil }
        // Layout: u_int32 Laenge, dann off_t SPACEUSED.
        let used = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return used
    }

    /// "/dev/disk3s7" und "/dev/disk3s1s1" -> "disk3"; alles, was kein
    /// APFS-artiger Devicename ist ("map auto_home", "//u@NAS/x", ""), -> nil.
    public static func apfsContainer(ofDevice device: String) -> String? {
        var name = Substring(device)
        if name.hasPrefix("/dev/") { name = name.dropFirst(5) }
        guard name.hasPrefix("disk") else { return nil }
        let rest = name.dropFirst(4)
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let tail = rest.dropFirst(digits.count)
        // Rest muss leer sein oder nur aus "s<Ziffern>"-Gruppen bestehen.
        var remaining = tail
        while !remaining.isEmpty {
            guard remaining.first == "s" else { return nil }
            remaining = remaining.dropFirst()
            let group = remaining.prefix(while: { $0.isASCII && $0.isNumber })
            guard !group.isEmpty else { return nil }
            remaining = remaining.dropFirst(group.count)
        }
        return "disk" + digits
    }

    /// Wie `read(volumeAt:)`, aber nil, wenn `path` kein Mountpunkt ist.
    public static func readMounted(at path: String) -> DiskUsage? {
        guard mountedInfo(at: path) != nil else { return nil }
        return read(volumeAt: path)
    }

    /// Eigenverbrauch des Volumes unter `path` gegen die Container-Groesse
    /// des Boot-Volumes. nil, wenn nicht gemountet oder in einem anderen
    /// APFS-Container als "/".
    public static func readHighlight(at path: String) -> NamedDiskUsage? {
        guard let info = mountedInfo(at: path),
              let boot = mountInfo(ofPath: "/"),
              let container = apfsContainer(ofDevice: info.device),
              container == apfsContainer(ofDevice: boot.device),
              let own = ownUsedBytes(ofVolumeAt: path),
              let total = read(volumeAt: "/")?.total else { return nil }
        let used = min(own, total)
        return NamedDiskUsage(name: displayName(ofMountPoint: info.mountPoint),
                              usage: DiskUsage(total: total, available: total - used))
    }

    static func displayName(ofMountPoint mount: String) -> String {
        let last = URL(fileURLWithPath: mount).lastPathComponent
        return last.isEmpty || last == "/" ? mount : last
    }
}

public final class SystemStats {
    private var previousCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var previousNetSample: (rx: UInt64, tx: UInt64, at: Date)?
    private var lastDisk: (usage: DiskUsage, highlight: NamedDiskUsage?,
                           extras: [NamedDiskUsage], at: Date)?

    /// Hervorgehobenes Volume im Boot-Container (leer = keines). Eine
    /// Aenderung verwirft den Disk-Cache.
    public var highlightVolumePath = "" {
        didSet { if highlightVolumePath != oldValue { lastDisk = nil } }
    }

    /// Zusatz-Volumes; je gemountetem Eintrag ein Ring. Eine Aenderung
    /// verwirft den Disk-Cache.
    public var extraVolumePaths: [String] = [] {
        didSet { if extraVolumePaths != oldValue { lastDisk = nil } }
    }

    /// Fill levels change slowly and the purgeable-space query is not free,
    /// so the disk is re-read at most this often instead of every tick.
    public var diskRefreshInterval: TimeInterval = 15

    public init() {}

    public func sample() -> SystemSnapshot {
        var snap = SystemSnapshot()
        sampleCPU(into: &snap)
        sampleMemory(into: &snap)
        sampleNetwork(into: &snap)
        sampleDisk(into: &snap)
        snap.uptime = ProcessInfo.processInfo.systemUptime
        return snap
    }

    // MARK: CPU

    private func sampleCPU(into snap: inout SystemSnapshot) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var ticks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            ticks.append((
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }

        var perCore: [Double] = []
        if previousCPUTicks.count == ticks.count {
            for (prev, cur) in zip(previousCPUTicks, ticks) {
                let user = Double(cur.user &- prev.user)
                let system = Double(cur.system &- prev.system)
                let nice = Double(cur.nice &- prev.nice)
                let idle = Double(cur.idle &- prev.idle)
                let total = user + system + nice + idle
                perCore.append(total > 0 ? (user + system + nice) / total : 0)
            }
        } else {
            perCore = Array(repeating: 0, count: ticks.count)
        }
        previousCPUTicks = ticks
        snap.perCoreUsage = perCore
        snap.cpuUsage = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
    }

    // MARK: Memory

    private func sampleMemory(into snap: inout SystemSnapshot) {
        snap.memoryTotal = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        // "Used" the way Activity Monitor counts it: active + wired + compressed.
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize
        snap.memoryUsed = min(used, snap.memoryTotal)
    }

    // MARK: Disk

    private func sampleDisk(into snap: inout SystemSnapshot) {
        let now = Date()
        if let last = lastDisk, now.timeIntervalSince(last.at) < diskRefreshInterval {
            snap.disk = last.usage
            snap.diskHighlight = last.highlight
            snap.extraDisks = last.extras
            return
        }
        guard let usage = DiskUsage.read() else {
            snap.disk = lastDisk?.usage ?? DiskUsage()
            snap.diskHighlight = lastDisk?.highlight
            snap.extraDisks = lastDisk?.extras ?? []
            return
        }
        let highlight = highlightVolumePath.isEmpty
            ? nil : DiskUsage.readHighlight(at: highlightVolumePath)
        let extras: [NamedDiskUsage] = extraVolumePaths.compactMap { path in
            guard let info = DiskUsage.mountedInfo(at: path),
                  let disk = DiskUsage.read(volumeAt: path) else { return nil }
            return NamedDiskUsage(name: DiskUsage.displayName(ofMountPoint: info.mountPoint),
                                  usage: disk)
        }
        lastDisk = (usage, highlight, extras, now)
        snap.disk = usage
        snap.diskHighlight = highlight
        snap.extraDisks = extras
    }

    // MARK: Network

    private func sampleNetwork(into snap: inout SystemSnapshot) {
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            totalRx &+= UInt64(data.ifi_ibytes)
            totalTx &+= UInt64(data.ifi_obytes)
        }

        let now = Date()
        if let prev = previousNetSample {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0 {
                snap.networkRxBytesPerSecond = Double(totalRx &- prev.rx) / dt
                snap.networkTxBytesPerSecond = Double(totalTx &- prev.tx) / dt
            }
        }
        previousNetSample = (totalRx, totalTx, now)
    }
}

public enum ByteFormatter {
    public static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    public static func size(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}
