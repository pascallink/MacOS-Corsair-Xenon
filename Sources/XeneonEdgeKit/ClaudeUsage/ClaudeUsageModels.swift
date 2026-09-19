// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Data model for local Claude Code usage: token counts per assistant reply,
// aggregated into the 5-hour billing blocks Claude Code plans use, plus a
// price table for cost estimates.
//
// Everything is computed from files on this Mac (~/.claude/projects/*.jsonl);
// nothing is sent anywhere.

import Foundation

// MARK: - Single log entry

public struct ClaudeUsageEntry: Equatable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// Cost as recorded by older Claude Code versions; when absent the cost
    /// is estimated from the price table.
    public let costUSD: Double?

    public init(timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
                cacheCreationTokens: Int, cacheReadTokens: Int, costUSD: Double? = nil) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var estimatedCost: Double {
        if let costUSD { return costUSD }
        return ModelPricing.forModel(model).cost(of: self)
    }
}

// MARK: - Aggregated totals

public struct UsageTotals: Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheCreationTokens = 0
    public var cacheReadTokens = 0
    public var costUSD = 0.0
    public var entryCount = 0

    public init() {}

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Tokens that typically count against plan limits (excludes cache reads,
    /// which are heavily discounted).
    public var billableTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens
    }

    public mutating func add(_ entry: ClaudeUsageEntry) {
        inputTokens += entry.inputTokens
        outputTokens += entry.outputTokens
        cacheCreationTokens += entry.cacheCreationTokens
        cacheReadTokens += entry.cacheReadTokens
        costUSD += entry.estimatedCost
        entryCount += 1
    }
}

// MARK: - 5-hour block

/// Claude Code plan limits reset in 5-hour windows. Blocks are anchored to
/// the full hour (UTC) of the first message after a gap, matching the
/// behaviour established by the ccusage community tooling.
public struct UsageBlock: Equatable {
    public static let duration: TimeInterval = 5 * 60 * 60

    public let start: Date
    public var totals = UsageTotals()
    public var models: Set<String> = []
    public var lastActivity: Date

    public init(start: Date, lastActivity: Date) {
        self.start = start
        self.lastActivity = lastActivity
    }

    public var end: Date { start.addingTimeInterval(Self.duration) }

    public func isActive(at now: Date) -> Bool {
        now < end && now.timeIntervalSince(lastActivity) < Self.duration
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }

    /// Groups entries into 5h blocks. `entries` may be unsorted.
    public static func build(from entries: [ClaudeUsageEntry]) -> [UsageBlock] {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var blocks: [UsageBlock] = []
        var current: UsageBlock?

        for entry in sorted {
            if let block = current,
               entry.timestamp < block.end,
               entry.timestamp.timeIntervalSince(block.lastActivity) < duration {
                var updated = block
                updated.totals.add(entry)
                updated.models.insert(entry.model)
                updated.lastActivity = entry.timestamp
                current = updated
            } else {
                if let block = current { blocks.append(block) }
                var block = UsageBlock(start: floorToHour(entry.timestamp),
                                       lastActivity: entry.timestamp)
                block.totals.add(entry)
                block.models.insert(entry.model)
                current = block
            }
        }
        if let block = current { blocks.append(block) }
        return blocks
    }

    public static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

// MARK: - Limit windows (day / rolling week)

/// A time window with aggregated totals, used to show usage against a plan
/// limit. This sits next to `UsageBlock` rather than replacing it: the 5h
/// block is anchor-based (its start snaps to the full hour after a pause in
/// activity), while a `UsageWindow` is either a calendar day or a plain
/// gleitendes (rolling) interval. Merging both ideas into one type would be
/// wrong, since "block start" and "window start" answer different questions.
public struct UsageWindow: Equatable {
    public enum Kind: String, Equatable {
        case block
        case day
        case week

        public var title: String {
            switch self {
            case .block: return "5 h"
            case .day: return "Tag"
            case .week: return "Woche"
            }
        }
    }

    public let kind: Kind
    public let start: Date
    public let end: Date
    public var totals = UsageTotals()
    /// Zeitpunkt, an dem das Limit fuer dieses Fenster wieder frei wird.
    /// Nil, wenn dafuer keine Eintraege vorliegen (z. B. leere Woche).
    public var resetsAt: Date?

    public init(kind: Kind, start: Date, end: Date, totals: UsageTotals = UsageTotals(),
                resetsAt: Date? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.totals = totals
        self.resetsAt = resetsAt
    }

    /// Anteil des verbrauchten Budgets, 0.0 = leer. Nil, wenn kein Budget
    /// bekannt ist. Nicht nach oben geklemmt - das macht der Aufrufer beim
    /// Zeichnen des Balkens.
    public func fraction(of budget: Int, includeCacheReads: Bool) -> Double? {
        guard budget > 0 else { return nil }
        let tokens = includeCacheReads ? totals.totalTokens : totals.billableTokens
        return Double(tokens) / Double(budget)
    }

    /// Verbleibende Zeit bis zum Reset. Nil, wenn `resetsAt` unbekannt ist.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }

    /// Kalendertag von `now` in `calendar`, von lokaler Mitternacht bis zur
    /// naechsten lokalen Mitternacht. Zaehlt Eintraege mit
    /// `start <= timestamp < end`.
    public static func day(from entries: [ClaudeUsageEntry], now: Date,
                           calendar: Calendar = .current) -> UsageWindow {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)

        var window = UsageWindow(kind: .day, start: start, end: end, resetsAt: end)
        for entry in entries where entry.timestamp >= start && entry.timestamp < end {
            window.totals.add(entry)
        }
        return window
    }

    /// Rollendes 7-Tage-Fenster bis `now`. Zaehlt Eintraege mit
    /// `timestamp > start && timestamp <= now` - das Fenster rollt, ein
    /// Eintrag genau auf der Kante (vor genau 7 Tagen) ist bereits
    /// herausgerollt.
    public static func week(from entries: [ClaudeUsageEntry], now: Date) -> UsageWindow {
        let start = now.addingTimeInterval(-7 * 24 * 60 * 60)

        var window = UsageWindow(kind: .week, start: start, end: now)
        var oldest: Date?
        for entry in entries where entry.timestamp > start && entry.timestamp <= now {
            window.totals.add(entry)
            if oldest == nil || entry.timestamp < oldest! {
                oldest = entry.timestamp
            }
        }
        // Reset ist der Zeitpunkt, an dem der aelteste beruecksichtigte
        // Eintrag aus dem 7-Tage-Fenster herausrollt und damit wieder Budget
        // frei wird. Ohne Eintraege gibt es nichts, das rollt.
        window.resetsAt = oldest.map { $0.addingTimeInterval(7 * 24 * 60 * 60) }
        return window
    }
}

// MARK: - Snapshot for the UI

public struct ClaudeUsageSnapshot: Equatable {
    /// The currently running 5h block, if there was recent activity.
    public var activeBlock: UsageBlock?
    /// Everything since local midnight.
    public var today = UsageTotals()
    /// Kalendertag als Limitfenster (dieselbe Zeitspanne wie `today`, aber
    /// samt Reset-Zeitpunkt fuer die Limitanzeige).
    public var day = UsageWindow(kind: .day, start: .distantPast, end: .distantPast)
    /// Rollendes 7-Tage-Fenster als Limitfenster.
    public var week = UsageWindow(kind: .week, start: .distantPast, end: .distantPast)
    /// Model id of the most recent assistant reply (e.g. "claude-opus-5").
    public var latestModel: String?
    /// Plan from ~/.claude/.credentials.json (e.g. "pro", "max") — the only
    /// field read from that file; tokens are never touched.
    public var subscriptionType: String?
    public var lastUpdated = Date.distantPast
    /// Number of log files that contributed data.
    public var scannedFiles = 0

    public init() {}
}

// MARK: - Formatting shared by the widget and the dashboard panel

public enum UsageFormat {
    public static func tokens(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens)"
        case ..<1_000_000: return String(format: "%.1fk", Double(tokens) / 1_000)
        default: return String(format: "%.2fM", Double(tokens) / 1_000_000)
        }
    }

    public static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d h", s / 3600, (s % 3600) / 60)
    }
}

// MARK: - Pricing (estimates)

/// USD per million tokens. Cache write ≈ 1.25x input, cache read ≈ 0.1x
/// input, per Anthropic's standard pricing structure. Prices change —
/// treat every cost as an estimate.
public struct ModelPricing: Equatable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double
    public let cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public func cost(of entry: ClaudeUsageEntry) -> Double {
        (Double(entry.inputTokens) * input
            + Double(entry.outputTokens) * output
            + Double(entry.cacheCreationTokens) * cacheWrite
            + Double(entry.cacheReadTokens) * cacheRead) / 1_000_000
    }

    // Price table (as of 2026; per MTok)
    public static let fable = ModelPricing(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1.0)
    public static let opus = ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)
    public static let opusLegacy = ModelPricing(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
    public static let sonnet = ModelPricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
    public static let haiku = ModelPricing(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)

    public static func forModel(_ model: String) -> ModelPricing {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return fable }
        if m.contains("opus") {
            // Opus 4.1 and older were priced at 15/75.
            if m.contains("opus-4-1") || m.contains("opus-4-2024") || m.contains("3-opus") {
                return opusLegacy
            }
            return opus
        }
        if m.contains("haiku") { return haiku }
        // Sonnet and unknown models: mid-tier pricing.
        return sonnet
    }

    /// Short display name for the mode badge, e.g. "Opus 5".
    public static func displayName(for model: String) -> String {
        let m = model.lowercased()
        let family: String
        if m.contains("fable") { family = "Fable" }
        else if m.contains("mythos") { family = "Mythos" }
        else if m.contains("opus") { family = "Opus" }
        else if m.contains("sonnet") { family = "Sonnet" }
        else if m.contains("haiku") { family = "Haiku" }
        else { return model }

        // Extract a version like "5" or "4-5" following the family name,
        // ignoring trailing date stamps ("...-20251001").
        if let range = m.range(of: family.lowercased() + "-") {
            var parts: [Substring] = []
            for component in m[range.upperBound...].split(separator: "-") {
                guard component.allSatisfy(\.isNumber), component.count <= 2 else { break }
                parts.append(component)
            }
            if !parts.isEmpty {
                return "\(family) \(parts.joined(separator: "."))"
            }
        }
        return family
    }
}
