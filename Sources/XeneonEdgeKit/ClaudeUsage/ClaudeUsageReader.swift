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
// Das Scan-Fenster ist gestaffelt, kein einzelner Lookback: Dateien werden
// ueberhaupt erst betrachtet, wenn sie neuer als bucketLookback sind
// (rollierende Woche plus Puffer), aber nur Dateien neuer als
// detailLookback (30h) werden in einzelne Eintraege fuer "today" und den
// aktiven 5h-Block zerlegt. Alles Aeltere, bis bucketLookback, wird
// stattdessen zu stuendlichen HourBuckets fuer das rollierende 7-Tage-
// Fenster verdichtet - eine volle Woche roher Eintraege waere das
// Sechsfache des heutigen Scan-Materials, bei jedem Widget-Refresh (45s).
//
// CLAUDE_CONFIG_DIR is honored; ~/.config/claude is checked as a fallback.

import Foundation

public final class ClaudeUsageReader {
    /// Dateien neuer als dieser Wert werden in einzelne Eintraege zerlegt.
    /// Deckt den aktuellen 5h-Block plus einen vollen lokalen Tag fuer die
    /// "today"-Summen ab - unveraendert seit vor dem Wochenfenster.
    private let detailLookback: TimeInterval = 30 * 60 * 60
    /// Dateien neuer als dieser Wert (aber aelter als detailLookback) werden
    /// nur zu Stundeneimern fuer das rollierende Wochenfenster verdichtet.
    /// Zwei getrennte Lookbacks statt einem groesseren, weil eine Woche
    /// roher Eintraege bei jedem 45s-Widget-Refresh geparst und im Speicher
    /// gehalten wuerde - der Eimerpfad wirft die rohen Eintraege sofort nach
    /// dem Verdichten wieder weg.
    private let bucketLookback: TimeInterval = 7 * 24 * 60 * 60 + 6 * 60 * 60

    private let fileManager = FileManager.default
    private let configDirectories: [URL]

    // Per-file parse cache so refreshes only re-read files that changed.
    private struct CachedFile {
        let modificationDate: Date
        let size: Int
        let entries: [ParsedEntry]
    }
    private var cache: [String: CachedFile] = [:]

    // Dateiweiser Cache der verdichteten Stundeneimer fuer Dateien ausserhalb
    // des Detailfensters - vermeidet erneutes Parsen und Verdichten
    // wochenalter Dateien, die sich seit dem letzten Refresh nicht
    // geaendert haben.
    private struct CachedBuckets {
        let modificationDate: Date
        let size: Int
        let buckets: [HourBucket]
        /// dedupKeys der Eintraege, die in `buckets` eingeflossen sind. Wird
        /// beim Cache-Treffer erneut in `seen` eingefuegt, damit der
        /// dateiuebergreifende Dedup zwischen zwei Refreshes stabil bleibt.
        let dedupKeys: [String]
    }
    private var bucketCache: [String: CachedBuckets] = [:]

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
        var buckets: [HourBucket] = []
        let detailCutoff = now.addingTimeInterval(-detailLookback)
        let bucketCutoff = now.addingTimeInterval(-bucketLookback)

        // Kandidaten ueber alle Verzeichnisse hinweg sammeln, bevor
        // irgendeine Datei geparst wird: sonst laeuft der Eimerpfad des
        // ersten Verzeichnisses vor dem Detailpfad des zweiten, und die
        // Prioritaet "Detailpfad vor Eimerpfad" gilt nur je Verzeichnis
        // statt ueber alle Verzeichnisse hinweg.
        var candidates: [(url: URL, mtime: Date, size: Int)] = []
        for dir in directories {
            let projects = dir.appendingPathComponent("projects")
            guard fileManager.fileExists(atPath: projects.path) else { continue }
            guard let files = try? allJSONLFiles(under: projects) else { continue }

            for file in files {
                guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime >= bucketCutoff
                else { continue }
                let size = (attrs[.size] as? Int) ?? 0
                candidates.append((file, mtime, size))
            }
        }

        // Detailpfad zuerst: unveraendertes Verhalten, fuellt "today"
        // und den 5h-Block mit einzelnen Eintraegen und befuellt dabei
        // `seen` vollstaendig - ueber alle Verzeichnisse hinweg, nicht nur
        // je Verzeichnis.
        for candidate in candidates where candidate.mtime >= detailCutoff {
            let fileEntries = parseFile(candidate.url, modificationDate: candidate.mtime, size: candidate.size)
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

        // Eimerpfad danach: `seen` ist an dieser Stelle bereits durch den
        // Detailpfad oben ueber ALLE Verzeichnisse hinweg vollstaendig
        // befuellt, dedupliziert also auch gegen Dateien, die im Detailpfad
        // eines anderen Verzeichnisses geparst wurden - genau der Fall, in
        // dem derselbe message.id + requestId sowohl in einer frischen als
        // auch in einer aelteren Datei auftaucht.
        for candidate in candidates where candidate.mtime < detailCutoff {
            let fileBuckets = bucketsForFile(candidate.url, modificationDate: candidate.mtime,
                                             size: candidate.size, seen: &seen)
            if !fileBuckets.isEmpty { snap.scannedFiles += 1 }
            buckets.append(contentsOf: fileBuckets)
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

        // Kalendertag als Limitfenster. Braucht keine Eimer: der 30h-
        // Detaillookback deckt auch den laengsten Kalendertag ab (25h bei
        // der Winterzeitumstellung), also liegen alle Tageseintraege ohnehin
        // schon in `entries`.
        snap.day = UsageWindow.day(from: entries, now: now)
        // Rollendes 7-Tage-Fenster: Eimer fuer alles ausserhalb des
        // Detailfensters, rohe Eintraege fuer den aktuellen Rand.
        snap.week = UsageWindow.week(fromBuckets: buckets, entries: entries, now: now)

        // Caches nach Alter evakuieren, nicht nach in diesem Lauf besuchten
        // Pfaden: `snapshots(for:...)` ruft `makeSnapshot` fuer mehrere
        // Profile nacheinander auf derselben Reader-Instanz auf, ein Trimmen
        // nach besuchten Pfaden wuerde sich die Profile gegenseitig leeren.
        // Zwei getrennte Cutoffs, weil beide Caches von unterschiedlichen
        // Pfaden befuellt und gelesen werden: `cache` ausschliesslich vom
        // Detailpfad, dessen Filter `mtime >= detailCutoff` eine Datei
        // aelter als detailLookback nie wieder anfasst - mit dem
        // bucketCutoff bliebe so ein Eintrag samt seiner vollstaendigen
        // ParsedEntry-Liste fast sechs Tage laenger im Speicher, als er je
        // wieder getroffen werden koennte. `bucketCache` bleibt beim
        // bucketCutoff: Dateien aelter als bucketLookback faellt der Scan
        // (Filter `mtime >= bucketCutoff`) ohnehin nie wieder an, die
        // Eviction ist deshalb weiterhin profilunabhaengig.
        let detailEvictionCutoff = now.addingTimeInterval(-detailLookback)
        let bucketEvictionCutoff = now.addingTimeInterval(-bucketLookback)
        cache = cache.filter { $0.value.modificationDate >= detailEvictionCutoff }
        bucketCache = bucketCache.filter { $0.value.modificationDate >= bucketEvictionCutoff }

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

    /// Verdichtet eine Datei ausserhalb des Detailfensters zu Stundeneimern
    /// fuer das rollierende Wochenfenster. Ruft bewusst NICHT `parseFile`
    /// auf: dessen Cache wuerde die komplette `ParsedEntry`-Liste jeder
    /// wochenalten Datei im Speicher halten, genau das soll diese
    /// Verdichtung vermeiden - hier werden die rohen Eintraege direkt nach
    /// dem Verdichten verworfen und nur die paar resultierenden Eimer
    /// behalten. `seen` dedupliziert zusaetzlich gegen den Detailpfad und
    /// gegen andere schon verarbeitete Dateien.
    private func bucketsForFile(_ url: URL, modificationDate: Date, size: Int,
                                seen: inout Set<String>) -> [HourBucket] {
        let key = url.path
        if let cached = bucketCache[key], cached.modificationDate == modificationDate,
           cached.size == size,
           !cached.dedupKeys.contains(where: { seen.contains($0) }) {
            // Cache-Treffer: die dedupKeys dieser Datei erneut in `seen`
            // einfuegen, sonst kippt das Ergebnis zwischen zwei Refreshes -
            // `seen` ist pro Lauf neu, der Cache-Treffer ueberspringt aber
            // das erneute Parsen.
            seen.formUnion(cached.dedupKeys)
            return cached.buckets
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var parsed: [ParsedEntry] = []
        text.enumerateLines { line, _ in
            if let p = Self.parseLine(line) { parsed.append(p) }
        }

        // Dedupe innerhalb dieser einen Datei - gestreamte Antworten koennen
        // mehrfach im selben Transkript auftauchen und muessen einmal
        // gezaehlt werden. Zusaetzlich gegen `seen` dedupliziert, damit
        // derselbe Eintrag nicht doppelt zaehlt, wenn er in zwei
        // verschiedenen Dateien auftaucht.
        var seenInFile = Set<String>()
        var dedupKeys: [String] = []
        var entries: [ClaudeUsageEntry] = []
        var droppedCrossFileDuplicate = false
        for p in parsed {
            if let dedupKey = p.dedupKey {
                if seenInFile.contains(dedupKey) { continue }
                seenInFile.insert(dedupKey)
                if seen.contains(dedupKey) {
                    droppedCrossFileDuplicate = true
                    continue
                }
                seen.insert(dedupKey)
                dedupKeys.append(dedupKey)
            }
            entries.append(p.entry)
        }

        let buckets = HourBucket.buckets(from: entries)
        // Nur cachen, wenn beim Parsen kein Eintrag wegen eines bereits in
        // `seen` vorhandenen Schluessels verworfen wurde - sonst gilt die
        // gefilterte Fassung nur fuer diesen einen Lauf. Eine Datei mit
        // dateiuebergreifenden Duplikaten wird dadurch bei jedem Refresh neu
        // geparst - das ist der bewusst gewaehlte Preis fuer eine Zahl, die
        // nicht zu hoch steht.
        if !droppedCrossFileDuplicate {
            bucketCache[key] = CachedBuckets(modificationDate: modificationDate, size: size,
                                             buckets: buckets, dedupKeys: dedupKeys)
        }
        return buckets
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
