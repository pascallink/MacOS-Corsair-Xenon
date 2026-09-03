// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns Claude Code's local transcripts into a "which of my chats needs me?"
// overview: one summary per session file, with the state derived from the
// tail of the conversation.
//
// Source (local only, nothing leaves this Mac):
//   ~/.claude/projects/**/*.jsonl   one file per session; every line is one
//                                   transcript event (user, assistant, …)
//
// Only the tail of each file is read — a session's current state is decided
// by its last few turns, and transcripts grow into the megabytes.

import Foundation

public final class ClaudeSessionReader {

    /// Thresholds for the three states. Both are user-configurable because
    /// "still working" and "still open" are workflow decisions, not facts.
    public struct Options: Equatable {
        /// A mid-turn chat counts as *working* while its transcript was
        /// written to within this window; older than that, nobody is driving
        /// it any more (window closed, machine asleep, session crashed) and
        /// it counts as open-but-idle.
        public var activeWindow: TimeInterval
        /// Chats untouched for longer than this are not listed at all.
        public var openWindow: TimeInterval

        public init(activeWindow: TimeInterval = 5 * 60,
                    openWindow: TimeInterval = 12 * 60 * 60) {
            self.activeWindow = activeWindow
            self.openWindow = openWindow
        }
    }

    /// How much of the end of a transcript is parsed. Enough for many turns,
    /// small enough that a dozen sessions refresh in milliseconds.
    static let tailBytes = 512 * 1024

    private let fileManager = FileManager.default
    private let configDirectories: [URL]

    private struct CachedFile {
        let modificationDate: Date
        let size: Int
        /// The parse result; the time-dependent half of the state is
        /// recomputed on every read (see `restate`).
        let summary: ClaudeSessionSummary?
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

    // MARK: - Snapshots

    public func snapshot(now: Date = Date(), options: Options = Options()) -> ClaudeSessionsSnapshot {
        makeSnapshot(directories: configDirectories, profileName: "", now: now, options: options)
    }

    /// One snapshot per profile, merged into a single list. Unlike token
    /// usage, chats *may* be counted together: "three chats want an answer"
    /// is true regardless of which login they belong to.
    public func snapshot(for profiles: [ClaudeProfile], now: Date = Date(),
                         options: Options = Options()) -> ClaudeSessionsSnapshot {
        guard !profiles.isEmpty else { return snapshot(now: now, options: options) }
        let all = profiles.flatMap { profile in
            makeSnapshot(directories: [profile.directoryURL], profileName: profile.name,
                         now: now, options: options).sessions
        }
        return ClaudeSessionsSnapshot(sessions: Self.sort(all), lastUpdated: now)
    }

    private func makeSnapshot(directories: [URL], profileName: String, now: Date,
                              options: Options) -> ClaudeSessionsSnapshot {
        var summaries: [ClaudeSessionSummary] = []
        let cutoff = now.addingTimeInterval(-options.openWindow)

        for dir in directories {
            let projects = dir.appendingPathComponent("projects")
            guard fileManager.fileExists(atPath: projects.path) else { continue }
            guard let files = try? jsonlFiles(under: projects) else { continue }
            for file in files {
                guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime >= cutoff
                else { continue }
                let size = (attrs[.size] as? Int) ?? 0
                guard var summary = summary(of: file, modificationDate: mtime, size: size,
                                            now: now, options: options)
                else { continue }
                guard summary.lastActivity >= cutoff else { continue }
                summary.profileName = profileName
                summaries.append(summary)
            }
        }

        return ClaudeSessionsSnapshot(sessions: Self.sort(summaries), lastUpdated: now)
    }

    /// Questions first, then working chats, then idle ones; newest first
    /// within each group — the order the widget lists them in.
    public static func sort(_ sessions: [ClaudeSessionSummary]) -> [ClaudeSessionSummary] {
        func rank(_ state: ClaudeSessionState) -> Int {
            switch state {
            case .awaitingAnswer: return 0
            case .working: return 1
            case .idle: return 2
            }
        }
        return sessions.sorted {
            rank($0.state) != rank($1.state)
                ? rank($0.state) < rank($1.state)
                : $0.lastActivity > $1.lastActivity
        }
    }

    // MARK: - Files

    private func jsonlFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "jsonl" { result.append(item) }
        }
        return result
    }

    private func summary(of url: URL, modificationDate: Date, size: Int, now: Date,
                         options: Options) -> ClaudeSessionSummary? {
        // The parse is cached per (mtime, size); the *state* is not, because
        // "working" turns into "idle" purely by the clock moving on.
        if let cached = cache[url.path], cached.modificationDate == modificationDate,
           cached.size == size {
            return cached.summary.map { Self.restate($0, now: now, options: options) }
        }
        guard let lines = Self.tailLines(of: url) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        let summary = Self.analyze(lines: lines, id: id, now: now, options: options)
        cache[url.path] = CachedFile(modificationDate: modificationDate, size: size,
                                     summary: summary)
        return summary
    }

    /// Reads the last `tailBytes` of a file and splits it into lines. A
    /// truncated first line (the read rarely starts on a line boundary) is
    /// dropped; it would only fail to parse anyway.
    static func tailLines(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var lines = text.components(separatedBy: "\n")
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    // MARK: - Transcript analysis

    private enum LastEvent {
        case assistantTurnEnded
        case assistantMidTurn
        case toolResult
        case humanPrompt
    }

    /// Builds the summary of one session from its transcript lines. Pure and
    /// public so the state rules can be tested without touching the disk.
    public static func analyze(lines: [String], id: String, now: Date = Date(),
                               options: Options = Options()) -> ClaudeSessionSummary? {
        var lastActivity: Date?
        var directory: String?
        var gitBranch: String?
        var model: String?
        var lastPrompt: String?
        var lastEvent: LastEvent?
        var assistantText = ""
        var currentRequestID: String?
        // Tool calls still waiting for their result, in call order.
        var pending: [(id: String, name: String, input: [String: Any])] = []

        for line in lines {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            if let cwd = json["cwd"] as? String, !cwd.isEmpty { directory = cwd }
            if let branch = json["gitBranch"] as? String, !branch.isEmpty { gitBranch = branch }
            let timestamp = (json["timestamp"] as? String).flatMap(parseTimestamp)

            // Subagent traffic keeps a chat alive but never changes whose
            // turn it is — the agent reports back to Claude, not to the user.
            let isSidechain = (json["isSidechain"] as? Bool) ?? false
            if isSidechain {
                if let timestamp { lastActivity = max(lastActivity ?? timestamp, timestamp) }
                continue
            }

            switch type {
            case "assistant":
                guard let message = json["message"] as? [String: Any] else { continue }
                if let timestamp { lastActivity = max(lastActivity ?? timestamp, timestamp) }
                if let m = message["model"] as? String, !m.isEmpty { model = m }

                // One turn is written as several lines (thinking, text, tool
                // calls) sharing a requestId — text accumulates per turn.
                let requestID = json["requestId"] as? String
                if requestID != currentRequestID {
                    currentRequestID = requestID
                    assistantText = ""
                }

                var hasToolUse = false
                for block in (message["content"] as? [[String: Any]]) ?? [] {
                    switch (block["type"] as? String) ?? "" {
                    case "text":
                        if let text = block["text"] as? String { assistantText += text }
                    case "tool_use":
                        hasToolUse = true
                        let toolID = (block["id"] as? String) ?? UUID().uuidString
                        pending.append((id: toolID,
                                        name: (block["name"] as? String) ?? "",
                                        input: (block["input"] as? [String: Any]) ?? [:]))
                    default:
                        break
                    }
                }
                let stopReason = message["stop_reason"] as? String
                lastEvent = (hasToolUse || stopReason == "tool_use")
                    ? .assistantMidTurn : .assistantTurnEnded

            case "user":
                guard let message = json["message"] as? [String: Any] else { continue }
                if let timestamp { lastActivity = max(lastActivity ?? timestamp, timestamp) }

                if let blocks = message["content"] as? [[String: Any]],
                   blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    for block in blocks where (block["type"] as? String) == "tool_result" {
                        if let toolID = block["tool_use_id"] as? String {
                            pending.removeAll { $0.id == toolID }
                        }
                    }
                    lastEvent = .toolResult
                    continue
                }

                // A human turn answers everything that was open, including a
                // question the user simply typed past.
                guard let text = humanText(message["content"]), !isCommandEcho(text) else { continue }
                pending.removeAll()
                lastPrompt = text
                assistantText = ""
                currentRequestID = nil
                lastEvent = .humanPrompt

            default:
                continue
            }
        }

        guard let lastActivity, let lastEvent else { return nil }

        let agents = pending.filter { $0.name == "Agent" || $0.name == "Task" }.count
        let runningTool = pending.last(where: { $0.name != "Agent" && $0.name != "Task" })?.name

        var state: ClaudeSessionState
        var question: String?

        if let ask = pending.last(where: { $0.name == "AskUserQuestion" }) {
            state = .awaitingAnswer
            question = askedQuestion(from: ask.input)
        } else if pending.contains(where: { $0.name == "ExitPlanMode" }) {
            state = .awaitingAnswer
            question = "Plan freigeben?"
        } else {
            switch lastEvent {
            case .assistantTurnEnded:
                if let asked = trailingQuestion(in: assistantText) {
                    state = .awaitingAnswer
                    question = asked
                } else {
                    state = .idle
                }
            case .assistantMidTurn, .toolResult, .humanPrompt:
                state = now.timeIntervalSince(lastActivity) <= options.activeWindow
                    ? .working : .idle
            }
        }

        return ClaudeSessionSummary(
            id: id, directory: directory, gitBranch: gitBranch, lastActivity: lastActivity,
            state: state, question: question, lastPrompt: lastPrompt, model: model,
            runningAgents: agents,
            runningTool: state == .working ? runningTool : nil
        )
    }

    /// Re-evaluates the time-dependent half of the state for a cached parse:
    /// a chat that was working when we last parsed its file becomes idle once
    /// the active window passes, without the file changing at all.
    private static func restate(_ summary: ClaudeSessionSummary, now: Date,
                                options: Options) -> ClaudeSessionSummary {
        guard summary.state == .working,
              now.timeIntervalSince(summary.lastActivity) > options.activeWindow
        else { return summary }
        return ClaudeSessionSummary(
            id: summary.id, directory: summary.directory, gitBranch: summary.gitBranch,
            lastActivity: summary.lastActivity, state: .idle, question: summary.question,
            lastPrompt: summary.lastPrompt, model: summary.model,
            runningAgents: summary.runningAgents, runningTool: nil,
            profileName: summary.profileName
        )
    }

    // MARK: - Text helpers

    /// The human's own words. `content` is a plain string for typed prompts
    /// and a block array when attachments/images are involved.
    static func humanText(_ content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let blocks = content as? [[String: Any]] {
            let text = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Slash commands, hook output and IDE notifications ride in as user
    /// messages; they are not something the human typed at Claude.
    static func isCommandEcho(_ text: String) -> Bool {
        text.hasPrefix("<command-name>") || text.hasPrefix("<local-command")
            || text.hasPrefix("<system-reminder>") || text.hasPrefix("[Request interrupted")
            || text.hasPrefix("Caveat:")
    }

    /// The question text out of an `AskUserQuestion` call.
    static func askedQuestion(from input: [String: Any]) -> String? {
        guard let questions = input["questions"] as? [[String: Any]] else { return nil }
        let texts = questions.compactMap { $0["question"] as? String }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: " · ")
    }

    /// The question a reply ends on, if it ends on one. Only a trailing
    /// question counts: a question mark in the middle of a long answer is
    /// usually rhetorical, or already answered further down.
    static func trailingQuestion(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return nil }
        let body = trimmed.dropLast()
        // Walk back to the start of the sentence carrying the question mark.
        var start = body.endIndex
        while start > body.startIndex {
            let previous = body.index(before: start)
            if ".!?\n".contains(body[previous]) { break }
            start = previous
        }
        let sentence = body[start...].trimmingCharacters(in: .whitespacesAndNewlines) + "?"
        return sentence.count > 1 ? sentence : trimmed
    }

    // MARK: - Timestamps

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

    static func parseTimestamp(_ string: String) -> Date? {
        isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }
}
