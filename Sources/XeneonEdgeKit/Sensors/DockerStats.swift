// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Docker-Auslastung fuer das System-Panel: RAM der Container und Platz im
// Disk-Image von Docker Desktop. Gelesen wird ueber den Engine-Socket
// (HTTP/1.0 ueber AF_UNIX), ohne `docker`-CLI und ohne Prozesse.

import Darwin
import Foundation

public struct DockerUsage: Equatable {
    public var memoryUsed: UInt64 = 0        // bytes, Summe der Container
    public var memoryTotal: UInt64 = 0       // bytes, RAM der Docker-VM
    public var diskUsed: UInt64 = 0          // bytes, belegt im Disk-Image
    public var diskTotal: UInt64 = 0         // bytes, logische Groesse (Limit)
    public var containerCount = 0

    public init(memoryUsed: UInt64 = 0, memoryTotal: UInt64 = 0,
                diskUsed: UInt64 = 0, diskTotal: UInt64 = 0, containerCount: Int = 0) {
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.containerCount = containerCount
    }

    public var memoryUsage: Double {
        memoryTotal > 0 ? min(1, Double(memoryUsed) / Double(memoryTotal)) : 0
    }

    public var diskUsage: Double {
        diskTotal > 0 ? min(1, Double(diskUsed) / Double(diskTotal)) : 0
    }
}

/// Reine Parser ohne I/O. Ungueltiges JSON ergibt nil, nie einen Absturz.
public enum DockerParser {
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, !(value is Bool), n.doubleValue >= 0 else { return nil }
        return n.uint64Value
    }

    /// `MemTotal` aus GET /info.
    public static func memTotal(fromInfo data: Data) -> UInt64? {
        number(object(data)?["MemTotal"])
    }

    /// Container-IDs aus GET /containers/json.
    public static func containerIDs(fromList data: Data) -> [String]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return list.compactMap { $0["Id"] as? String }
    }

    /// Speicher wie `docker stats`: usage minus inactive_file (cgroup v2) bzw.
    /// total_inactive_file (v1), nicht unter 0.
    public static func memoryUsed(fromStats data: Data) -> UInt64? {
        guard let mem = object(data)?["memory_stats"] as? [String: Any],
              let usage = number(mem["usage"]) else { return nil }
        let stats = mem["stats"] as? [String: Any]
        let inactive = number(stats?["inactive_file"]) ?? number(stats?["total_inactive_file"]) ?? 0
        return usage > inactive ? usage - inactive : 0
    }
}

/// Liest Docker-Werte. `read()` blockiert (Socket-Timeout je ~2 s) und gehoert
/// deshalb auf eine Hintergrund-Queue, nie auf Main.
public final class DockerStatsReader {
    public var socketPaths: [String]
    public var diskImagePath: String

    public static let defaultSocketPaths = [
        NSString(string: "~/.docker/run/docker.sock").expandingTildeInPath,
        "/var/run/docker.sock",
    ]
    public static let defaultDiskImagePath = NSString(
        string: "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
    ).expandingTildeInPath

    public init(socketPaths: [String] = DockerStatsReader.defaultSocketPaths,
                diskImagePath: String = DockerStatsReader.defaultDiskImagePath) {
        self.socketPaths = socketPaths.map { NSString(string: $0).expandingTildeInPath }
        self.diskImagePath = NSString(string: diskImagePath).expandingTildeInPath
    }

    /// nil, wenn kein Socket antwortet (Docker laeuft nicht).
    public func read() -> DockerUsage? {
        for socket in socketPaths {
            guard let info = Self.get("/info", socketPath: socket),
                  let memTotal = DockerParser.memTotal(fromInfo: info) else { continue }
            var usage = DockerUsage(memoryTotal: memTotal)
            if let list = Self.get("/containers/json", socketPath: socket),
               let ids = DockerParser.containerIDs(fromList: list) {
                usage.containerCount = ids.count
                for id in ids {
                    guard let body = Self.get("/containers/\(id)/stats?stream=false&one-shot=true",
                                              socketPath: socket),
                          let used = DockerParser.memoryUsed(fromStats: body) else { continue }
                    usage.memoryUsed += used
                }
            }
            if let image = Self.imageSizes(at: diskImagePath) {
                usage.diskTotal = image.logical
                usage.diskUsed = min(image.allocated, image.logical)
            }
            return usage
        }
        return nil
    }

    static func imageSizes(at path: String) -> (logical: UInt64, allocated: UInt64)? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let logical = values.fileSize, logical > 0,
              let allocated = values.totalFileAllocatedSize else { return nil }
        return (UInt64(logical), UInt64(allocated))
    }

    // MARK: HTTP ueber AF_UNIX

    /// Body einer HTTP-Antwort (nach der Leerzeile); nil bei Status != 200.
    public static func httpBody(fromResponse raw: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator),
              let head = String(data: raw[raw.startIndex..<range.lowerBound], encoding: .utf8),
              let statusLine = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[1] == "200" else { return nil }
        return raw[range.upperBound...]
    }

    /// Minimaler GET; nil bei jedem Fehler, Timeout oder Status != 200.
    public static func get(_ path: String, socketPath: String, timeout: TimeInterval = 2) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(socketPath.utf8)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let request = Array("GET \(path) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            let n = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, request.count - sent) }
            guard n > 0 else { return nil }
            sent += n
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let limit = 8 * 1024 * 1024
        while response.count < limit {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { response.append(contentsOf: chunk[0..<n]) } else { break }
        }
        return httpBody(fromResponse: response)
    }
}
