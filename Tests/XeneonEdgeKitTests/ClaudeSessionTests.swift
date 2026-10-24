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

@Suite struct CloudSessionRelayTests {
    private let now = ClaudeSessionReader.parseTimestamp("2026-10-24T12:00:00Z")!

    private func stamp(_ minutesAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// Shape of a real `GET /gists/{id}` response, trimmed to what we read.
    private func gistResponse(files: [String: String]) -> Data {
        let filesJSON = files.map { name, content in
            "\"\(name)\": {\"content\": \(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}"
        }.joined(separator: ",")
        return Data("{\"files\": {\(filesJSON)}}".utf8)
    }

    private func stateFile(id: String = "abc-123", state: String = "awaitingAnswer",
                           minutesAgo: Double = 2, label: String? = "MacOS-Corsair-Xenon",
                           question: String? = nil) -> String {
        var fields = """
        "schema":1,"sessionId":"\(id)","state":"\(state)","timestamp":"\(stamp(minutesAgo))"
        """
        if let label { fields += ",\"label\":\"\(label)\",\"gitBranch\":\"feature/x\"" }
        fields += ",\"model\":\"claude-opus-5\""
        if let question { fields += ",\"question\":\"\(question)\"" }
        return "{\(fields)}"
    }

    // MARK: Parsing

    @Test func readsAChatStateFromTheRelay() throws {
        let data = gistResponse(files: [
            "state-abc-123.json": stateFile(question: "Soll ich das Panel bauen?"),
        ])
        let sessions = CloudUsageFetcher.parseSessionStates(data)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.state == .awaitingAnswer)
        #expect(session.question == "Soll ich das Panel bauen?")
        #expect(session.title == "MacOS-Corsair-Xenon")
        #expect(session.gitBranch == "feature/x")
        #expect(session.model == "claude-opus-5")
        #expect(session.isRemote)
        // Prefixed, so a resumed session cannot collide with the local one.
        #expect(session.id == "cloud:abc-123")
    }

    @Test func aRelayWithoutQuestionTextStillCountsAsWaiting() throws {
        let data = gistResponse(files: ["state-abc-123.json": stateFile()])
        let session = try #require(CloudUsageFetcher.parseSessionStates(data).first)
        #expect(session.state == .awaitingAnswer)
        #expect(session.question == nil)
    }

    @Test func unusableStateFilesAreSkippedNotGuessedAt() {
        let data = gistResponse(files: [
            "state-1.json": "not json",
            "state-2.json": #"{"schema":1,"sessionId":"x","state":"schlafend","timestamp":"2026-10-24T11:00:00Z"}"#,
            "state-3.json": #"{"schema":1,"state":"idle","timestamp":"2026-10-24T11:00:00Z"}"#,
            "state-4.json": #"{"schema":1,"sessionId":"y","state":"idle"}"#,
        ])
        #expect(CloudUsageFetcher.parseSessionStates(data).isEmpty)
    }

    @Test func theTwoHalvesOfTheRelayIgnoreEachOther() {
        let usageLine = """
        {"type":"assistant","timestamp":"\(stamp(3))","requestId":"req_1",\
        "message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":10,\
        "output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let data = gistResponse(files: [
            "session-abc-123.jsonl": usageLine,
            "state-abc-123.json": stateFile(),
        ])
        #expect(CloudUsageFetcher.parseGistResponse(data).count == 1)
        #expect(CloudUsageFetcher.parseSessionStates(data).count == 1)
    }

    // MARK: Merging into the local overview

    private func local(_ id: String, _ state: ClaudeSessionState,
                       minutesAgo: Double) -> ClaudeSessionSummary {
        ClaudeSessionSummary(id: id, directory: "/tmp/\(id)", gitBranch: nil,
                             lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                             state: state)
    }

    private func remote(_ id: String, _ state: ClaudeSessionState,
                        minutesAgo: Double) -> ClaudeSessionSummary {
        ClaudeSessionSummary(id: "cloud:\(id)", directory: id, gitBranch: nil,
                             lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                             state: state, isRemote: true)
    }

    @Test func relayedChatsJoinTheLocalOnesInOneOrder() {
        let snapshot = ClaudeSessionsSnapshot(sessions: [local("a", .working, minutesAgo: 1)])
            .merging(remote: [remote("b", .awaitingAnswer, minutesAgo: 3)], now: now)
        #expect(snapshot.sessions.map(\.id) == ["cloud:b", "a"])
        #expect(snapshot.activeCount == 1)
        #expect(snapshot.questionCount == 1)
        #expect(snapshot.remoteCount == 1)
    }

    @Test func aRelayedWorkingChatGoneQuietIsNoLongerActive() {
        // The remote container died mid-turn: nothing is published any more,
        // so the state must decay here instead of staying "active" forever.
        let snapshot = ClaudeSessionsSnapshot()
            .merging(remote: [remote("b", .working, minutesAgo: 30)], now: now)
        #expect(snapshot.activeCount == 0)
        #expect(snapshot.idleCount == 1)
    }

    @Test func aRelayedChatPastTheOpenWindowDropsOut() {
        let snapshot = ClaudeSessionsSnapshot()
            .merging(remote: [remote("b", .idle, minutesAgo: 13 * 60)], now: now)
        #expect(snapshot.sessions.isEmpty)
    }

    @Test func mergingNothingKeepsTheSnapshotUntouched() {
        let original = ClaudeSessionsSnapshot(sessions: [local("a", .idle, minutesAgo: 5)],
                                              lastUpdated: now)
        #expect(original.merging(remote: [], now: now) == original)
    }
}
