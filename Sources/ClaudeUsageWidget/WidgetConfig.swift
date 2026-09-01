// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Widget configuration, stored as JSON in
// ~/Library/Application Support/XeneonEdge/claude-widget.json

import Foundation
import XeneonEdgeKit

struct WidgetConfig: Codable, Equatable {
    /// Refresh interval in seconds (30-60s is sensible).
    var refreshSeconds: Double = 45
    /// Personal token budget per 5h block for the progress ring. Plans have
    /// no published token number, so this is user-calibrated: watch the
    /// widget until you hit a limit once, then set what you reached.
    /// 0 = no ring, show plain numbers.
    var tokenBudgetPerBlock: Int = 0
    /// Where on the Edge display the widget docks:
    /// topLeft | topRight | bottomLeft | bottomRight | center
    var corner: String = "bottomRight"
    /// Margin from the display edges in points.
    var margin: Double = 24
    /// Widget size in points. The default leaves room for the chat
    /// overview; without it (`showSessions: false`) about 250 is enough.
    var width: Double = 560
    var height: Double = 320
    /// Count cache reads towards the displayed token number. Plan limits
    /// weigh cache reads barely at all, so the default leaves them out.
    var includeCacheReads: Bool = false
    /// GitHub Gist id relaying usage from Claude Code sessions running in a
    /// remote/cloud environment (see .claude/hooks/publish-claude-usage.sh
    /// and docs/CLAUDE-USAGE-WIDGET.md). Empty disables the cloud relay
    /// entirely — only local ~/.claude logs are read, the default.
    var cloudGistID: String = ""
    /// Poll interval for the cloud relay; clamped to >=60s to stay under
    /// GitHub's unauthenticated REST rate limit (60 requests/hour/IP).
    var cloudPollSeconds: Double = 90
    /// Claude logins to track separately (e.g. a personal and a work
    /// account). Each one keeps its own 5h window, so they are never summed.
    /// Empty = auto-detect a single profile, the previous behaviour.
    var claudeProfiles: [ClaudeProfile] = []
    /// Show the chat overview (how many chats work / ask / idle) below the
    /// usage numbers. This is what makes several parallel Claude Code
    /// sessions visible at a glance.
    var showSessions: Bool = true
    /// Show the newest unanswered question as a line of text. Off keeps the
    /// widget to bare counters — the question text is chat content, and the
    /// Edge display may not be private.
    var showLastQuestion: Bool = true
    /// How many individual chats are listed under the counters; 0 shows the
    /// counters only.
    var sessionRows: Int = 3
    /// A chat mid-turn counts as "active" while its transcript was written
    /// to within this many seconds.
    var sessionActiveSeconds: Double = 300
    /// Chats untouched for longer than this many hours drop off the list.
    var sessionOpenHours: Double = 12

    // MARK: Tolerant decoding
    // The synthesized Codable init requires every key to be present, so a
    // hand-edit that only changes one value (or a version that predates a
    // newly added field) would otherwise fail to decode entirely. Every
    // field falls back to its default individually instead.

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WidgetConfig()
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? d.refreshSeconds
        tokenBudgetPerBlock = try c.decodeIfPresent(Int.self, forKey: .tokenBudgetPerBlock) ?? d.tokenBudgetPerBlock
        corner = try c.decodeIfPresent(String.self, forKey: .corner) ?? d.corner
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        includeCacheReads = try c.decodeIfPresent(Bool.self, forKey: .includeCacheReads) ?? d.includeCacheReads
        cloudGistID = try c.decodeIfPresent(String.self, forKey: .cloudGistID) ?? d.cloudGistID
        cloudPollSeconds = try c.decodeIfPresent(Double.self, forKey: .cloudPollSeconds) ?? d.cloudPollSeconds
        claudeProfiles = try c.decodeIfPresent([ClaudeProfile].self, forKey: .claudeProfiles) ?? d.claudeProfiles
        showSessions = try c.decodeIfPresent(Bool.self, forKey: .showSessions) ?? d.showSessions
        showLastQuestion = try c.decodeIfPresent(Bool.self, forKey: .showLastQuestion) ?? d.showLastQuestion
        sessionRows = try c.decodeIfPresent(Int.self, forKey: .sessionRows) ?? d.sessionRows
        sessionActiveSeconds = try c.decodeIfPresent(Double.self, forKey: .sessionActiveSeconds) ?? d.sessionActiveSeconds
        sessionOpenHours = try c.decodeIfPresent(Double.self, forKey: .sessionOpenHours) ?? d.sessionOpenHours
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XeneonEdge/claude-widget.json")
    }

    /// Loads the config. A file that fails to parse (a JSON syntax error
    /// from hand-editing, for example) never triggers a write — only a
    /// missing file gets defaults written out, so a broken but recoverable
    /// edit is never silently destroyed. Defaults are still returned in
    /// memory so the widget keeps running either way.
    static func load() -> WidgetConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            let config = WidgetConfig()
            try? config.save() // first run: write defaults so the file is easy to find/edit
            return config
        }
        do {
            return try JSONDecoder().decode(WidgetConfig.self, from: data)
        } catch {
            NSLog("XeneonEdge: claude-widget.json could not be read (\(error)) — "
                + "using defaults for this run without touching the file")
            return WidgetConfig()
        }
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: .atomic)
    }
}
