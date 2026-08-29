// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads Claude Code's local logs and produces a usage snapshot.
//
// Sources (all local, nothing leaves this Mac):
//   ~/.claude/projects/**/*.jsonl      per-session transcripts; every
//                                      assistant reply carries token usage
//   ~/.claude/.credentials.json        ONLY the plan name (subscriptionType)
//                                      is read; access tokens are ignored
//
// CLAUDE_CONFIG_DIR is honored; ~/.config/claude is checked as a fallback.

import Foundation

public final class ClaudeUsageReader {
    /// How far back log files are considered. Covers the current 5h block
    /// plus a full local day for the "today" totals.
    private let lookback: TimeInterval = 30 * 60 * 60

    private let fileManager = FileManager.default
    private let configDirectories: [URL]

    // Per-file parse cache so refreshes only re-read files that changed.
    private struct CachedFile {
        let modificationDate: Date
        let size: Int
        let entries: [ParsedEntry]
    }
    private var cache: [String: CachedFile] = [:]

    public init(configDirectories: [URL]? = nil) {
        if let configDirectories {
            self.configDirectories = configDirectories
        } else {
            var dirs: [URL] = []
            let env = ProcessInfo.processInfo.environment
            if let custom = env["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
                dirs.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
            }
            let home = fileManager.homeDirectoryForCurrentUser
            dirs.append(home.appendingPathComponent(".claude"))
            dirs.append(home.appendingPathComponent(".config/claude"))
            self.configDirectories = dirs
        }
    }

    // MARK: - Snapshot

    /// - Parameter additionalEntries: Usage entries from other sources (e.g.
    ///   a cloud/remote relay) to fold into the same 5h-block and "today"
    ///   computation as the local logs. Already deduplicated by the caller.
    public func snapshot(now: Date = Date(), additionalEntries: [ClaudeUsageEntry] = []) -> ClaudeUsageSnapshot {
        makeSnapshot(directories: configDirectories, now: now,
                     additionalEntries: additionalEntries)
    }

    // MARK: - Per-profile snapshots

    /// Usage of one profile, computed from that profile's directory alone.
    public struct ProfileUsage: Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let snapshot: ClaudeUsageSnapshot

        public init(id: UUID, name: String, snapshot: ClaudeUsageSnapshot) {
            self.id = id
            self.name = name
            self.snapshot = snapshot
        }
    }

    /// Builds one snapshot per profile. Each profile is read from its own
    /// directory and aggregated on its own, because every login has an
    /// independent 5-hour window: mixing two profiles' entries into one
    /// `UsageBlock` would report a number that belongs to neither limit and
    /// a reset countdown that is wrong for at least one of them.
    ///
    /// - Parameter additionalEntries: Cloud-relay entries per profile id.
    public func snapshots(for profiles: [ClaudeProfile], now: Date = Date(),
                          additionalEntries: [UUID: [ClaudeUsageEntry]] = [:]) -> [ProfileUsage] {
        profiles.map { profile in
            ProfileUsage(
                id: profile.id,
                name: profile.name,
                snapshot: makeSnapshot(directories: [profile.directoryURL], now: now,
                                       additionalEntries: additionalEntries[profile.id] ?? [])
            )
        }
    }

    // MARK: - Aggregation

    private func makeSnapshot(directories: [URL], now: Date,
                              additionalEntries: [ClaudeUsageEntry]) -> ClaudeUsageSnapshot {
        var snap = ClaudeUsageSnapshot()
        snap.lastUpdated = now
        snap.subscriptionType = readSubscriptionType(in: directories)

        var entries: [ClaudeUsageEntry] = []
        var seen = Set<String>()
        let cutoff = now.addingTimeInterval(-lookback)

        for dir in directories {
            let projects = dir.appendingPathComponent("projects")
            guard fileManager.fileExists(atPath: projects.path) else { continue }
            guard let files = try? allJSONLFiles(under: projects) else { continue }
            for file in files {
                guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime >= cutoff
                else { continue }
                let size = (attrs[.size] as? Int) ?? 0
                let fileEntries = parseFile(file, modificationDate: mtime, size: size)
                if fileEntries.isEmpty { continue }
                snap.scannedFiles += 1
                for parsed in fileEntries {
                    if let key = parsed.dedupKey {
                        if seen.contains(key) { continue }
                        seen.insert(key)
                    }
                    entries.append(parsed.entry)
                }
            }
        }

        entries.append(contentsOf: additionalEntries)

        // Latest model = most recent assistant reply.
        snap.latestModel = entries.max(by: { $0.timestamp < $1.timestamp })?.model

        // Today's totals (local midnight).
        let startOfDay = Calendar.current.startOfDay(for: now)
        for entry in entries where entry.timestamp >= startOfDay && entry.timestamp <= now {
            snap.today.add(entry)
        }

        // Current 5h block.
        let blocks = UsageBlock.build(from: entries.filter { $0.timestamp <= now })
        snap.activeBlock = blocks.last(where: { $0.isActive(at: now) })

        return snap
    }

    // MARK: - File discovery

    private func allJSONLFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "jsonl" { result.append(item) }
        }
        return result
    }

    private func parseFile(_ url: URL, modificationDate: Date, size: Int) -> [ParsedEntry] {
        let key = url.path
        if let cached = cache[key], cached.modificationDate == modificationDate,
           cached.size == size {
            return cached.entries
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var parsed: [ParsedEntry] = []
        text.enumerateLines { line, _ in
            if let p = Self.parseLine(line) { parsed.append(p) }
        }
        cache[key] = CachedFile(modificationDate: modificationDate, size: size, entries: parsed)
        return parsed
    }

    // MARK: - Line parsing

    public struct ParsedEntry {
        public let entry: ClaudeUsageEntry
        /// message.id + requestId; streamed replies appear multiple times in
        /// the logs and must be counted once.
        public let dedupKey: String?
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses one transcript line. Only assistant messages with a usage
    /// object count; everything else returns nil.
    public static func parseLine(_ line: String) -> ParsedEntry? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["type"] as? String) == "assistant",
              let timestampString = json["timestamp"] as? String,
              let timestamp = isoWithFraction.date(from: timestampString)
                  ?? isoPlain.date(from: timestampString),
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        func intValue(_ key: String) -> Int {
            (usage[key] as? Int) ?? Int((usage[key] as? Double) ?? 0)
        }

        let entry = ClaudeUsageEntry(
            timestamp: timestamp,
            model: (message["model"] as? String) ?? "unknown",
            inputTokens: intValue("input_tokens"),
            outputTokens: intValue("output_tokens"),
            cacheCreationTokens: intValue("cache_creation_input_tokens"),
            cacheReadTokens: intValue("cache_read_input_tokens"),
            costUSD: json["costUSD"] as? Double
        )

        var dedupKey: String?
        if let messageID = message["id"] as? String,
           let requestID = json["requestId"] as? String {
            dedupKey = "\(messageID):\(requestID)"
        }
        return ParsedEntry(entry: entry, dedupKey: dedupKey)
    }

    // MARK: - Plan name

    /// Reads ONLY the subscription type from .credentials.json. The file
    /// also holds OAuth tokens — they are deliberately never extracted,
    /// logged or returned.
    ///
    /// On macOS this file is frequently absent because Claude Code keeps the
    /// credentials in the Keychain instead. We do not read them from there:
    /// the Keychain item is one blob holding the access tokens, so getting
    /// the plan name out of it would mean pulling the tokens into this
    /// process — exactly what this reader promises never to do. A missing
    /// file therefore means "plan unknown" and the UI omits the badge.
    private func readSubscriptionType(in directories: [URL]) -> String? {
        for dir in directories {
            let url = dir.appendingPathComponent(".credentials.json")
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let oauth = json["claudeAiOauth"] as? [String: Any],
               let plan = oauth["subscriptionType"] as? String {
                return plan
            }
        }
        return nil
    }
}
