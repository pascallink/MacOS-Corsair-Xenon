// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Data model for the "Claude chats" overview: one summary per Claude Code
// session (transcript file), plus the counters the widget shows — how many
// chats are working, how many wait for an answer, how many are open but
// idle.
//
// Everything is derived from files on this Mac (~/.claude/projects/*.jsonl);
// nothing is sent anywhere.

import Foundation

// MARK: - State of a single chat

/// What a chat is currently doing. Derived from the tail of its transcript:
/// a turn that ended hands control back to the human, a turn still running
/// belongs to Claude.
public enum ClaudeSessionState: String, Equatable, CaseIterable {
    /// Claude is working: the last turn is mid-flight (tool calls running,
    /// subagents busy) and the transcript was written to recently.
    case working
    /// Claude is waiting for the human: an `AskUserQuestion`/`ExitPlanMode`
    /// call is unanswered, or the last reply ended on a question.
    case awaitingAnswer
    /// Open, but nothing is happening: the turn ended without a question, or
    /// it stalled long enough that nobody is driving it any more.
    case idle
}

// MARK: - One chat

public struct ClaudeSessionSummary: Equatable, Identifiable {
    /// Claude Code's session id (transcript file name without extension).
    public let id: String
    /// Working directory of the session, e.g. "/Volumes/Sources/tools/X".
    public let directory: String?
    public let gitBranch: String?
    public let lastActivity: Date
    public let state: ClaudeSessionState
    /// The open question, when there is one — the `AskUserQuestion` text, or
    /// the question the last reply ended on.
    public let question: String?
    /// Most recent human prompt, as a hint at what this chat is about.
    public let lastPrompt: String?
    /// Model id of the most recent assistant reply.
    public let model: String?
    /// Subagents still running (unanswered `Agent`/`Task` tool calls).
    public let runningAgents: Int
    /// Tool the session is currently executing, if it is mid-turn.
    public let runningTool: String?
    /// Profile this chat belongs to; empty when only one is tracked.
    public var profileName: String

    public init(id: String, directory: String?, gitBranch: String?, lastActivity: Date,
                state: ClaudeSessionState, question: String? = nil, lastPrompt: String? = nil,
                model: String? = nil, runningAgents: Int = 0, runningTool: String? = nil,
                profileName: String = "") {
        self.id = id
        self.directory = directory
        self.gitBranch = gitBranch
        self.lastActivity = lastActivity
        self.state = state
        self.question = question
        self.lastPrompt = lastPrompt
        self.model = model
        self.runningAgents = runningAgents
        self.runningTool = runningTool
        self.profileName = profileName
    }

    /// Short label for the chat: the project folder, falling back to a
    /// shortened session id.
    public var title: String {
        if let directory, !directory.isEmpty {
            let name = (directory as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return String(id.prefix(8))
    }

    /// Seconds since the last transcript entry.
    public func age(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(lastActivity))
    }
}

// MARK: - Snapshot for the UI

public struct ClaudeSessionsSnapshot: Equatable {
    /// All open chats, most interesting first: chats with an open question,
    /// then working chats, then idle ones; each group newest first.
    public var sessions: [ClaudeSessionSummary] = []
    public var lastUpdated = Date.distantPast

    public init() {}

    public init(sessions: [ClaudeSessionSummary], lastUpdated: Date = Date()) {
        self.sessions = sessions
        self.lastUpdated = lastUpdated
    }

    public func count(_ state: ClaudeSessionState) -> Int {
        sessions.reduce(0) { $0 + ($1.state == state ? 1 : 0) }
    }

    /// "Anzahl aktive Chats" — Claude is working right now.
    public var activeCount: Int { count(.working) }
    /// "Anzahl Chats mit Fragen" — waiting for an answer.
    public var questionCount: Int { count(.awaitingAnswer) }
    /// "Anzahl offene inaktive Chats" — open, nothing happening.
    public var idleCount: Int { count(.idle) }

    /// Subagents running across all chats.
    public var runningAgents: Int { sessions.reduce(0) { $0 + $1.runningAgents } }

    /// The most recent unanswered question, for the one-line "last open
    /// question" readout.
    public var latestQuestion: ClaudeSessionSummary? {
        sessions.filter { $0.state == .awaitingAnswer && $0.question != nil }
            .max(by: { $0.lastActivity < $1.lastActivity })
    }

    /// Merges per-profile snapshots into one list.
    public static func merged(_ snapshots: [ClaudeSessionsSnapshot],
                              now: Date = Date()) -> ClaudeSessionsSnapshot {
        ClaudeSessionsSnapshot(
            sessions: ClaudeSessionReader.sort(snapshots.flatMap(\.sessions)),
            lastUpdated: now
        )
    }
}

// MARK: - Formatting

public enum SessionFormat {
    /// Compact relative age: "jetzt", "7 min", "3 h", "2 d".
    public static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "jetzt"
        case ..<3_600: return "\(s / 60) min"
        case ..<86_400: return "\(s / 3_600) h"
        default: return "\(s / 86_400) d"
        }
    }

    /// Single-line, length-capped text for the question readout.
    public static func oneLine(_ text: String, limit: Int = 180) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
