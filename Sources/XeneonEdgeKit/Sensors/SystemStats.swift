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

    public init() {}

    public var memoryUsage: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
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
}

public final class SystemStats {
    private var previousCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var previousNetSample: (rx: UInt64, tx: UInt64, at: Date)?
    private var lastDisk: (usage: DiskUsage, at: Date)?

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
            return
        }
        guard let usage = DiskUsage.read() else {
            snap.disk = lastDisk?.usage ?? DiskUsage()
            return
        }
        lastDisk = (usage, now)
        snap.disk = usage
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
