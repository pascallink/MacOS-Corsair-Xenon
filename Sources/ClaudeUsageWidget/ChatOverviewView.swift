// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Overview of the open Claude Code chats (issue #14): how many are working,
// how many wait for an answer, how many are open but idle — plus, optionally,
// the newest open question and a few chats in detail.

import SwiftUI
import XeneonEdgeKit

struct ChatOverview: View {
    @ObservedObject var model: UsageViewModel

    private var snapshot: ClaudeSessionsSnapshot { model.sessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            counters
            if let question = model.latestQuestion {
                questionLine(question)
            }
            ForEach(model.sessionRows) { session in
                sessionRow(session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func color(for state: ClaudeSessionState) -> Color {
        switch state {
        case .working: return WidgetTheme.good
        case .awaitingAnswer: return WidgetTheme.accent
        case .idle: return WidgetTheme.textSecondary
        }
    }

    // MARK: Counters

    private var counters: some View {
        HStack(spacing: 14) {
            Text("Chats")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WidgetTheme.textSecondary)
            counter(snapshot.activeCount, label: "aktiv", state: .working)
            counter(snapshot.questionCount, label: "Frage", state: .awaitingAnswer)
            counter(snapshot.idleCount, label: "offen", state: .idle)
            if snapshot.runningAgents > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text("\(snapshot.runningAgents) Agents")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .foregroundColor(WidgetTheme.textSecondary)
            }
            Spacer(minLength: 0)
            if snapshot.sessions.isEmpty {
                Text("keine offenen Chats")
                    .font(.system(size: 11))
                    .foregroundColor(WidgetTheme.textSecondary)
            }
        }
    }

    private func counter(_ value: Int, label: String, state: ClaudeSessionState) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.color(for: state))
                .frame(width: 7, height: 7)
            Text("\(value)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(WidgetTheme.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(WidgetTheme.textSecondary)
        }
    }

    // MARK: Newest open question

    private func questionLine(_ session: ClaudeSessionSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 12))
                .foregroundColor(WidgetTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WidgetTheme.textPrimary)
                        .lineLimit(1)
                    Text("vor \(SessionFormat.age(session.age(at: snapshot.lastUpdated)))")
                        .font(.system(size: 10))
                        .foregroundColor(WidgetTheme.textSecondary)
                }
                Text(SessionFormat.oneLine(session.question ?? ""))
                    .font(.system(size: 12))
                    .foregroundColor(WidgetTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WidgetTheme.accent.opacity(0.12))
        )
    }

    // MARK: One chat

    private func sessionRow(_ session: ClaudeSessionSummary) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Self.color(for: session.state))
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(WidgetTheme.textPrimary)
                .lineLimit(1)
            if !session.profileName.isEmpty {
                Text(session.profileName)
                    .font(.system(size: 9))
                    .foregroundColor(WidgetTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Text(detail(session))
                .font(.system(size: 10))
                .foregroundColor(WidgetTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(SessionFormat.age(session.age(at: snapshot.lastUpdated)))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundColor(WidgetTheme.textSecondary)
        }
    }

    /// The most useful thing to say about a chat in one short phrase.
    private func detail(_ session: ClaudeSessionSummary) -> String {
        var parts: [String] = []
        switch session.state {
        case .awaitingAnswer:
            parts.append(session.question.map { SessionFormat.oneLine($0, limit: 60) }
                ?? "wartet auf Antwort")
        case .working:
            if session.runningAgents > 0 {
                parts.append("\(session.runningAgents) Agent\(session.runningAgents == 1 ? "" : "s")")
            }
            if let tool = session.runningTool { parts.append(tool) }
            if parts.isEmpty { parts.append("arbeitet") }
        case .idle:
            if let branch = session.gitBranch, !branch.isEmpty {
                parts.append(branch)
            } else if let prompt = session.lastPrompt {
                parts.append(SessionFormat.oneLine(prompt, limit: 50))
            }
        }
        return parts.joined(separator: " · ")
    }
}
