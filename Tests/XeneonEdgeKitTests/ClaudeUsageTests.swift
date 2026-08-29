// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct ClaudeUsageParserTests {
    private func line(timestamp: String, model: String = "claude-opus-5",
                      input: Int = 10, output: Int = 20,
                      cacheWrite: Int = 0, cacheRead: Int = 0,
                      messageID: String = "msg_1", requestID: String = "req_1") -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestID)",\
        "message":{"id":"\(messageID)","model":"\(model)","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),\
        "cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    @Test func parsesAssistantLine() throws {
        let parsed = try #require(ClaudeUsageReader.parseLine(
            line(timestamp: "2026-08-23T10:00:00.123Z", input: 100, output: 50,
                 cacheWrite: 5, cacheRead: 7)
        ))
        #expect(parsed.entry.inputTokens == 100)
        #expect(parsed.entry.outputTokens == 50)
        #expect(parsed.entry.cacheCreationTokens == 5)
        #expect(parsed.entry.cacheReadTokens == 7)
        #expect(parsed.entry.model == "claude-opus-5")
        #expect(parsed.entry.totalTokens == 162)
        #expect(parsed.dedupKey == "msg_1:req_1")
    }

    @Test func parsesTimestampWithoutFraction() {
        #expect(ClaudeUsageReader.parseLine(line(timestamp: "2026-08-23T10:00:00Z")) != nil)
    }

    @Test func ignoresNonAssistantLines() {
        #expect(ClaudeUsageReader.parseLine(
            #"{"type":"user","timestamp":"2026-08-23T10:00:00Z","message":{}}"#
        ) == nil)
        #expect(ClaudeUsageReader.parseLine("not json") == nil)
        #expect(ClaudeUsageReader.parseLine("") == nil)
    }

    @Test func costEstimation() {
        // Opus 5: $5 in / $25 out per MTok.
        let entry = ClaudeUsageEntry(timestamp: Date(), model: "claude-opus-5",
                                     inputTokens: 1_000_000, outputTokens: 1_000_000,
                                     cacheCreationTokens: 0, cacheReadTokens: 0)
        #expect(abs(entry.estimatedCost - 30.0) <= 0.001)

        // Recorded costUSD wins over the estimate.
        let recorded = ClaudeUsageEntry(timestamp: Date(), model: "claude-opus-5",
                                        inputTokens: 1_000_000, outputTokens: 0,
                                        cacheCreationTokens: 0, cacheReadTokens: 0,
                                        costUSD: 1.23)
        #expect(abs(recorded.estimatedCost - 1.23) <= 0.001)
    }

    @Test func pricingSelection() {
        #expect(ModelPricing.forModel("claude-fable-5") == ModelPricing.fable)
        #expect(ModelPricing.forModel("claude-opus-5") == ModelPricing.opus)
        #expect(ModelPricing.forModel("claude-opus-4-1-20250805") == ModelPricing.opusLegacy)
        #expect(ModelPricing.forModel("claude-sonnet-5") == ModelPricing.sonnet)
        #expect(ModelPricing.forModel("claude-haiku-4-5") == ModelPricing.haiku)
    }

    @Test func displayName() {
        #expect(ModelPricing.displayName(for: "claude-opus-5") == "Opus 5")
        #expect(ModelPricing.displayName(for: "claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(ModelPricing.displayName(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelPricing.displayName(for: "claude-fable-5") == "Fable 5")
    }
}

@Suite struct UsageBlockTests {
    private func entry(atMinutes minutes: Double, tokens: Int = 10) -> ClaudeUsageEntry {
        ClaudeUsageEntry(timestamp: Date(timeIntervalSince1970: 1_000_000_000 + minutes * 60),
                         model: "claude-opus-5", inputTokens: tokens, outputTokens: 0,
                         cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    @Test func entriesWithinFiveHoursShareABlock() {
        let blocks = UsageBlock.build(from: [
            entry(atMinutes: 0), entry(atMinutes: 60), entry(atMinutes: 240),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].totals.inputTokens == 30)
    }

    @Test func gapStartsNewBlock() {
        let blocks = UsageBlock.build(from: [
            entry(atMinutes: 0),
            entry(atMinutes: 400), // > 5h after block start AND after last activity
        ])
        #expect(blocks.count == 2)
    }

    @Test func blockStartIsFlooredToHour() {
        let ts = Date(timeIntervalSince1970: 1_000_000_000 + 42 * 60) // hh:42
        let blocks = UsageBlock.build(from: [
            ClaudeUsageEntry(timestamp: ts, model: "m", inputTokens: 1, outputTokens: 0,
                             cacheCreationTokens: 0, cacheReadTokens: 0)
        ])
        #expect(blocks[0].start == UsageBlock.floorToHour(ts))
        #expect(blocks[0].start.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 3600) == 0)
    }

    @Test func activeBlockAndRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_000_000_000 + 60 * 60)
        let blocks = UsageBlock.build(from: [entry(atMinutes: 0)])
        let block = blocks[0]
        #expect(block.isActive(at: now))
        // Block start is floored to the hour containing t0; 4h remain of 5h.
        // Tolerance covers the flooring.
        #expect(abs(block.remaining(at: now) - 4 * 3600) <= 3600)
        #expect(!block.isActive(at: now.addingTimeInterval(6 * 3600)))
    }

    @Test func unsortedInput() {
        let blocks = UsageBlock.build(from: [
            entry(atMinutes: 240), entry(atMinutes: 0), entry(atMinutes: 60),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].totals.entryCount == 3)
    }
}

@Suite struct CloudUsageFetcherTests {
    private func gistLine(timestamp: String, model: String = "claude-opus-5",
                          input: Int = 10, output: Int = 20,
                          messageID: String = "msg_1", requestID: String = "req_1") -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestID)",\
        "message":{"id":"\(messageID)","model":"\(model)","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    /// Shape of a real `GET /gists/{id}` response, trimmed to what we read.
    private func gistResponse(files: [String: String]) -> Data {
        let filesJSON = files.map { name, content in
            "\"\(name)\": {\"content\": \(String(data: try! JSONEncoder().encode(content), encoding: .utf8)!)}"
        }.joined(separator: ",")
        return Data("{\"files\": {\(filesJSON)}}".utf8)
    }

    @Test func parsesFilesFromGistResponse() {
        let lines = [
            gistLine(timestamp: "2026-08-29T10:00:00Z", input: 100, output: 50),
            gistLine(timestamp: "2026-08-29T10:05:00Z", input: 20, output: 10,
                     messageID: "msg_2", requestID: "req_2"),
        ].joined(separator: "\n")
        let data = gistResponse(files: ["session-abc.jsonl": lines])

        let entries = CloudUsageFetcher.parseGistResponse(data)
        #expect(entries.count == 2)
        #expect(entries.reduce(0) { $0 + $1.inputTokens } == 120)
    }

    @Test func deduplicatesAcrossFiles() {
        let line = gistLine(timestamp: "2026-08-29T10:00:00Z")
        // Same session republished under two file snapshots must not double-count.
        let data = gistResponse(files: [
            "session-abc.jsonl": line,
            "session-abc-old.jsonl": line,
        ])
        let entries = CloudUsageFetcher.parseGistResponse(data)
        #expect(entries.count == 1)
    }

    @Test func malformedResponseReturnsEmpty() {
        #expect(CloudUsageFetcher.parseGistResponse(Data("not json".utf8)).count == 0)
        #expect(CloudUsageFetcher.parseGistResponse(Data("{}".utf8)).count == 0)
    }

    @Test func snapshotMergesAdditionalEntriesIntoActiveBlockAndToday() {
        let reader = ClaudeUsageReader(configDirectories: [])
        let now = Date()
        let cloudEntry = ClaudeUsageEntry(timestamp: now.addingTimeInterval(-60),
                                          model: "claude-opus-5", inputTokens: 500,
                                          outputTokens: 250, cacheCreationTokens: 0,
                                          cacheReadTokens: 0)
        let snap = reader.snapshot(now: now, additionalEntries: [cloudEntry])
        #expect(snap.activeBlock?.totals.inputTokens == 500)
        #expect(snap.today.inputTokens == 500)
        #expect(snap.latestModel == "claude-opus-5")
    }
}

// MARK: - Several Claude profiles

@Suite struct ClaudeProfileTests {
    /// Builds a throwaway Claude config directory holding one transcript.
    private func makeProfile(lines: [String], credentialsPlan: String? = nil) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("xeneon-profile-\(UUID().uuidString)")
        let projects = base.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: projects.appendingPathComponent("session.jsonl"),
                   atomically: true, encoding: .utf8)
        if let credentialsPlan {
            let json = #"{"claudeAiOauth":{"subscriptionType":"\#(credentialsPlan)"}}"#
            try json.write(to: base.appendingPathComponent(".credentials.json"),
                           atomically: true, encoding: .utf8)
        }
        return base
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func line(at date: Date, input: Int, messageID: String) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(date))","requestId":"req_\(messageID)",\
        "message":{"id":"\(messageID)","model":"claude-opus-5","usage":{"input_tokens":\(input),\
        "output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    /// The whole point of the feature: two logins have independent 5h limits,
    /// so their entries must never land in a shared block — not even when
    /// they are used minutes apart and would otherwise group together.
    @Test func overlappingProfilesKeepSeparateBlocks() throws {
        let now = Date()
        let privateDir = try makeProfile(lines: [
            line(at: now.addingTimeInterval(-600), input: 100, messageID: "p1"),
            line(at: now.addingTimeInterval(-300), input: 200, messageID: "p2"),
        ])
        let workDir = try makeProfile(lines: [
            line(at: now.addingTimeInterval(-540), input: 7, messageID: "w1"),
        ])
        defer {
            try? FileManager.default.removeItem(at: privateDir)
            try? FileManager.default.removeItem(at: workDir)
        }

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [
            ClaudeProfile(name: "Privat", configDir: privateDir.path),
            ClaudeProfile(name: "Arbeit", configDir: workDir.path),
        ], now: now)

        #expect(usages.count == 2)
        #expect(usages[0].name == "Privat")
        #expect(usages[1].name == "Arbeit")
        // Each block holds only its own profile's tokens — 300 and 7, never 307.
        #expect(usages[0].snapshot.activeBlock?.totals.inputTokens == 300)
        #expect(usages[1].snapshot.activeBlock?.totals.inputTokens == 7)
        #expect(usages[0].snapshot.activeBlock?.totals.entryCount == 2)
        #expect(usages[1].snapshot.activeBlock?.totals.entryCount == 1)
        #expect(usages[0].snapshot.today.inputTokens == 300)
        #expect(usages[1].snapshot.today.inputTokens == 7)
    }

    /// A profile reads its own directory only; another profile's transcripts
    /// must not leak in.
    @Test func profileReadsOnlyItsOwnDirectory() throws {
        let now = Date()
        let dirA = try makeProfile(lines: [line(at: now.addingTimeInterval(-120), input: 42, messageID: "a")])
        let dirB = try makeProfile(lines: [line(at: now.addingTimeInterval(-120), input: 99, messageID: "b")])
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [ClaudeProfile(name: "A", configDir: dirA.path)], now: now)
        #expect(usages.count == 1)
        #expect(usages[0].snapshot.today.inputTokens == 42)
    }

    /// Plans differ per login (e.g. Pro privately, Max at work), so the plan
    /// name is read per profile rather than "first one wins".
    @Test func planNameIsReadPerProfile() throws {
        let now = Date()
        let proDir = try makeProfile(
            lines: [line(at: now.addingTimeInterval(-120), input: 1, messageID: "x")],
            credentialsPlan: "pro")
        let maxDir = try makeProfile(
            lines: [line(at: now.addingTimeInterval(-120), input: 1, messageID: "y")],
            credentialsPlan: "max")
        defer {
            try? FileManager.default.removeItem(at: proDir)
            try? FileManager.default.removeItem(at: maxDir)
        }

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [
            ClaudeProfile(name: "Privat", configDir: proDir.path),
            ClaudeProfile(name: "Arbeit", configDir: maxDir.path),
        ], now: now)
        #expect(usages[0].snapshot.subscriptionType == "pro")
        #expect(usages[1].snapshot.subscriptionType == "max")
    }

    /// A missing .credentials.json (the normal case on macOS, where the
    /// credentials live in the Keychain) means "plan unknown", not a crash
    /// and not a wrong label.
    @Test func missingCredentialsFileLeavesPlanUnknown() throws {
        let now = Date()
        let dir = try makeProfile(lines: [line(at: now.addingTimeInterval(-120), input: 1, messageID: "z")])
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [ClaudeProfile(name: "A", configDir: dir.path)], now: now)
        #expect(usages[0].snapshot.subscriptionType == nil)
    }

    @Test func cloudEntriesAreFoldedIntoTheirOwnProfile() throws {
        let now = Date()
        let dirA = try makeProfile(lines: [line(at: now.addingTimeInterval(-120), input: 10, messageID: "a")])
        let dirB = try makeProfile(lines: [line(at: now.addingTimeInterval(-120), input: 20, messageID: "b")])
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let profileA = ClaudeProfile(name: "A", configDir: dirA.path)
        let profileB = ClaudeProfile(name: "B", configDir: dirB.path)
        let cloudEntry = ClaudeUsageEntry(timestamp: now.addingTimeInterval(-60),
                                          model: "claude-opus-5", inputTokens: 500,
                                          outputTokens: 0, cacheCreationTokens: 0,
                                          cacheReadTokens: 0)

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [profileA, profileB], now: now,
                                      additionalEntries: [profileB.id: [cloudEntry]])
        #expect(usages[0].snapshot.today.inputTokens == 10)
        #expect(usages[1].snapshot.today.inputTokens == 520)
    }

    // MARK: Config decoding

    /// Configs written before this feature have no `claudeProfiles` key and
    /// must keep working, falling back to single-profile auto-detection.
    @Test func configWithoutProfilesDecodesToEmpty() throws {
        let json = #"{"touchRotation": 90}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.claudeProfiles.isEmpty)
        #expect(decoded.touchRotation == 90)
    }

    /// Hand-written entries may be as short as a directory; the label then
    /// comes from the directory name and the id is generated.
    @Test func profileWithoutNameOrIDDecodes() throws {
        let json = #"{"claudeProfiles": [{"configDir": "~/.claude-work"}]}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.claudeProfiles.count == 1)
        #expect(decoded.claudeProfiles[0].name == "claude-work")
        #expect(decoded.claudeProfiles[0].configDir == "~/.claude-work")
        #expect(decoded.claudeProfiles[0].cloudGistID == "")
    }

    @Test func profileTildeIsExpanded() {
        let profile = ClaudeProfile(name: "Arbeit", configDir: "~/.claude-work")
        #expect(!profile.directoryURL.path.contains("~"))
        #expect(profile.directoryURL.path.hasSuffix("/.claude-work"))
    }

    @Test func profilesSurviveAConfigRoundTrip() throws {
        var config = AppConfig()
        config.claudeProfiles = [
            ClaudeProfile(name: "Privat", configDir: "~/.claude"),
            ClaudeProfile(name: "Arbeit", configDir: "~/.claude-work", cloudGistID: "abc123"),
        ]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.claudeProfiles[1].cloudGistID == "abc123")
    }
}
