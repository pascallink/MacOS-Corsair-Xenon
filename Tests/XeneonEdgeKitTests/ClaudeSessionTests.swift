// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct ClaudeSessionAnalysisTests {

    // MARK: Transcript fixtures

    private static let now = ClaudeSessionReader.parseTimestamp("2026-09-01T12:00:00Z")!

    private func stamp(_ minutesAgo: Double) -> String {
        let date = Self.now.addingTimeInterval(-minutesAgo * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func humanLine(_ text: String, minutesAgo: Double) -> String {
        """
        {"type":"user","isSidechain":false,"timestamp":"\(stamp(minutesAgo))",\
        "cwd":"/Volumes/Sources/tools/MacOS-Corsair-Xenon","gitBranch":"feature/x",\
        "message":{"role":"user","content":"\(text)"}}
        """
    }

    private func assistantTextLine(_ text: String, minutesAgo: Double,
                                   requestID: String = "req_1") -> String {
        """
        {"type":"assistant","isSidechain":false,"timestamp":"\(stamp(minutesAgo))",\
        "requestId":"\(requestID)","message":{"model":"claude-opus-5","stop_reason":"end_turn",\
        "content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func toolUseLine(name: String, id: String, minutesAgo: Double,
                             input: String = "{}", requestID: String = "req_2") -> String {
        """
        {"type":"assistant","isSidechain":false,"timestamp":"\(stamp(minutesAgo))",\
        "requestId":"\(requestID)","message":{"model":"claude-opus-5","stop_reason":"tool_use",\
        "content":[{"type":"tool_use","id":"\(id)","name":"\(name)","input":\(input)}]}}
        """
    }

    private func toolResultLine(id: String, minutesAgo: Double) -> String {
        """
        {"type":"user","isSidechain":false,"timestamp":"\(stamp(minutesAgo))",\
        "toolUseResult":{"ok":true},"message":{"role":"user",\
        "content":[{"type":"tool_result","tool_use_id":"\(id)","content":"done"}]}}
        """
    }

    private func analyze(_ lines: [String], activeWindow: TimeInterval = 300)
        -> ClaudeSessionSummary? {
        ClaudeSessionReader.analyze(
            lines: lines, id: "session-1", now: Self.now,
            options: ClaudeSessionReader.Options(activeWindow: activeWindow)
        )
    }

    // MARK: States

    @Test func midTurnChatIsWorking() throws {
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 3),
            toolUseLine(name: "Bash", id: "tool_1", minutesAgo: 1),
        ]))
        #expect(summary.state == .working)
        #expect(summary.runningTool == "Bash")
        #expect(summary.title == "MacOS-Corsair-Xenon")
        #expect(summary.gitBranch == "feature/x")
        #expect(summary.model == "claude-opus-5")
    }

    @Test func staleMidTurnChatCountsAsOpenNotActive() throws {
        // Nothing written for 40 minutes: the window is gone, the machine
        // slept, or the session died — nobody is driving this chat.
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 45),
            toolUseLine(name: "Bash", id: "tool_1", minutesAgo: 40),
        ]))
        #expect(summary.state == .idle)
        #expect(summary.runningTool == nil)
    }

    @Test func finishedTurnWithoutQuestionIsIdle() throws {
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 5),
            assistantTextLine("Fertig, gebaut und getestet.", minutesAgo: 1),
        ]))
        #expect(summary.state == .idle)
        #expect(summary.question == nil)
    }

    @Test func replyEndingOnAQuestionWaitsForAnAnswer() throws {
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 5),
            assistantTextLine("Das Layout steht. Soll ich auch das Dashboard-Panel bauen?",
                              minutesAgo: 1),
        ]))
        #expect(summary.state == .awaitingAnswer)
        #expect(summary.question == "Soll ich auch das Dashboard-Panel bauen?")
    }

    @Test func openAskUserQuestionWaitsForAnAnswer() throws {
        let input = #"{"questions":[{"question":"Welches Farbschema?","header":"Farben"}]}"#
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 10),
            toolUseLine(name: "AskUserQuestion", id: "tool_q", minutesAgo: 8, input: input),
        ]))
        #expect(summary.state == .awaitingAnswer)
        #expect(summary.question == "Welches Farbschema?")
    }

    @Test func answeredQuestionStopsWaiting() throws {
        let input = #"{"questions":[{"question":"Welches Farbschema?"}]}"#
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 10),
            toolUseLine(name: "AskUserQuestion", id: "tool_q", minutesAgo: 8, input: input),
            toolResultLine(id: "tool_q", minutesAgo: 2),
        ]))
        #expect(summary.state == .working)
        #expect(summary.question == nil)
    }

    @Test func aNewHumanTurnClearsAnUnansweredQuestion() throws {
        // Typing past a question answers it as far as the overview goes.
        let input = #"{"questions":[{"question":"Welches Farbschema?"}]}"#
        let summary = try #require(analyze([
            toolUseLine(name: "AskUserQuestion", id: "tool_q", minutesAgo: 8, input: input),
            humanLine("Egal, nimm gelb", minutesAgo: 1),
        ]))
        #expect(summary.state == .working)
        #expect(summary.lastPrompt == "Egal, nimm gelb")
    }

    @Test func planApprovalCountsAsAQuestion() throws {
        let summary = try #require(analyze([
            humanLine("Plane das", minutesAgo: 6),
            toolUseLine(name: "ExitPlanMode", id: "tool_p", minutesAgo: 4,
                        input: #"{"plan":"1. ..."}"#),
        ]))
        #expect(summary.state == .awaitingAnswer)
        #expect(summary.question == "Plan freigeben?")
    }

    // MARK: Subagents

    @Test func runningSubagentsAreCounted() throws {
        let summary = try #require(analyze([
            humanLine("Analysiere das", minutesAgo: 4),
            toolUseLine(name: "Agent", id: "a1", minutesAgo: 3),
            toolUseLine(name: "Agent", id: "a2", minutesAgo: 3, requestID: "req_3"),
            toolResultLine(id: "a1", minutesAgo: 1),
        ]))
        #expect(summary.runningAgents == 1)
        #expect(summary.state == .working)
    }

    @Test func sidechainTrafficKeepsAChatAliveWithoutChangingWhoseTurnItIs() throws {
        let sidechain = """
        {"type":"assistant","isSidechain":true,"timestamp":"\(stamp(1))",\
        "message":{"model":"claude-sonnet-5","stop_reason":"end_turn",\
        "content":[{"type":"text","text":"Subagent-Antwort"}]}}
        """
        let summary = try #require(analyze([
            humanLine("Analysiere das", minutesAgo: 20),
            toolUseLine(name: "Agent", id: "a1", minutesAgo: 19),
            sidechain,
        ]))
        // The main chain is still mid-turn, and the subagent's write counts
        // as activity — so the chat is working, not idle.
        #expect(summary.state == .working)
        #expect(summary.runningAgents == 1)
        #expect(summary.model == "claude-opus-5") // sidechain models don't win
    }

    // MARK: Noise

    @Test func slashCommandEchoesAreNotHumanTurns() throws {
        let summary = try #require(analyze([
            humanLine("Bau das Widget", minutesAgo: 30),
            assistantTextLine("Fertig. Noch etwas?", minutesAgo: 20),
            humanLine("<command-name>/clear</command-name>", minutesAgo: 1),
        ]))
        #expect(summary.state == .awaitingAnswer)
        #expect(summary.lastPrompt == "Bau das Widget")
    }

    @Test func aTranscriptWithoutUsableEntriesIsSkipped() {
        #expect(analyze(["", "kein json", #"{"type":"queue-operation"}"#]) == nil)
    }

    // MARK: Helpers

    @Test func trailingQuestionOnlyMatchesAtTheEnd() {
        #expect(ClaudeSessionReader.trailingQuestion(in: "Warum? Deshalb.") == nil)
        #expect(ClaudeSessionReader.trailingQuestion(in: "Alles klar. Weiter so?")
            == "Weiter so?")
        #expect(ClaudeSessionReader.trailingQuestion(in: "Ohne Frage") == nil)
    }

    @Test func humanTextReadsStringsAndBlocks() {
        #expect(ClaudeSessionReader.humanText("  hallo  ") == "hallo")
        #expect(ClaudeSessionReader.humanText([["type": "text", "text": "hallo"]]) == "hallo")
        #expect(ClaudeSessionReader.humanText([["type": "image"]]) == nil)
    }

    @Test func ageAndOneLineFormatting() {
        #expect(SessionFormat.age(30) == "jetzt")
        #expect(SessionFormat.age(7 * 60) == "7 min")
        #expect(SessionFormat.age(3 * 3_600) == "3 h")
        #expect(SessionFormat.age(2 * 86_400) == "2 d")
        #expect(SessionFormat.oneLine("a\n\nb  \n c") == "a b c")
        #expect(SessionFormat.oneLine("abcdef", limit: 3) == "abc…")
    }
}

@Suite struct ClaudeSessionsSnapshotTests {
    private func session(_ id: String, _ state: ClaudeSessionState, minutesAgo: Double,
                         question: String? = nil, agents: Int = 0) -> ClaudeSessionSummary {
        ClaudeSessionSummary(
            id: id, directory: "/tmp/\(id)", gitBranch: nil,
            lastActivity: Date().addingTimeInterval(-minutesAgo * 60),
            state: state, question: question, runningAgents: agents
        )
    }

    @Test func countersMatchTheIssuesThreeNumbers() {
        let snapshot = ClaudeSessionsSnapshot(sessions: [
            session("a", .working, minutesAgo: 1),
            session("b", .working, minutesAgo: 2, agents: 2),
            session("c", .awaitingAnswer, minutesAgo: 3, question: "Weiter?"),
            session("d", .idle, minutesAgo: 60),
            session("e", .idle, minutesAgo: 90),
        ])
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.questionCount == 1)
        #expect(snapshot.idleCount == 2)
        #expect(snapshot.runningAgents == 2)
    }

    @Test func questionsSortToTheTopAndTheNewestOneIsSurfaced() {
        let sorted = ClaudeSessionReader.sort([
            session("idle", .idle, minutesAgo: 5),
            session("old-question", .awaitingAnswer, minutesAgo: 30, question: "Alt?"),
            session("working", .working, minutesAgo: 1),
            session("new-question", .awaitingAnswer, minutesAgo: 2, question: "Neu?"),
        ])
        #expect(sorted.map(\.id) == ["new-question", "old-question", "working", "idle"])

        let snapshot = ClaudeSessionsSnapshot(sessions: sorted)
        #expect(snapshot.latestQuestion?.question == "Neu?")
    }

    @Test func withoutOpenQuestionsThereIsNothingToSurface() {
        let snapshot = ClaudeSessionsSnapshot(sessions: [session("a", .working, minutesAgo: 1)])
        #expect(snapshot.latestQuestion == nil)
    }
}
