// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import XeneonEdgeKit

final class ClaudeUsageParserTests: XCTestCase {
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

    func testParsesAssistantLine() throws {
        let parsed = try XCTUnwrap(ClaudeUsageReader.parseLine(
            line(timestamp: "2026-08-23T10:00:00.123Z", input: 100, output: 50,
                 cacheWrite: 5, cacheRead: 7)
        ))
        XCTAssertEqual(parsed.entry.inputTokens, 100)
        XCTAssertEqual(parsed.entry.outputTokens, 50)
        XCTAssertEqual(parsed.entry.cacheCreationTokens, 5)
        XCTAssertEqual(parsed.entry.cacheReadTokens, 7)
        XCTAssertEqual(parsed.entry.model, "claude-opus-5")
        XCTAssertEqual(parsed.entry.totalTokens, 162)
        XCTAssertEqual(parsed.dedupKey, "msg_1:req_1")
    }

    func testParsesTimestampWithoutFraction() {
        XCTAssertNotNil(ClaudeUsageReader.parseLine(line(timestamp: "2026-08-23T10:00:00Z")))
    }

    func testIgnoresNonAssistantLines() {
        XCTAssertNil(ClaudeUsageReader.parseLine(
            #"{"type":"user","timestamp":"2026-08-23T10:00:00Z","message":{}}"#
        ))
        XCTAssertNil(ClaudeUsageReader.parseLine("not json"))
        XCTAssertNil(ClaudeUsageReader.parseLine(""))
    }

    func testCostEstimation() {
        // Opus 5: $5 in / $25 out per MTok.
        let entry = ClaudeUsageEntry(timestamp: Date(), model: "claude-opus-5",
                                     inputTokens: 1_000_000, outputTokens: 1_000_000,
                                     cacheCreationTokens: 0, cacheReadTokens: 0)
        XCTAssertEqual(entry.estimatedCost, 30.0, accuracy: 0.001)

        // Recorded costUSD wins over the estimate.
        let recorded = ClaudeUsageEntry(timestamp: Date(), model: "claude-opus-5",
                                        inputTokens: 1_000_000, outputTokens: 0,
                                        cacheCreationTokens: 0, cacheReadTokens: 0,
                                        costUSD: 1.23)
        XCTAssertEqual(recorded.estimatedCost, 1.23, accuracy: 0.001)
    }

    func testPricingSelection() {
        XCTAssertEqual(ModelPricing.forModel("claude-fable-5"), ModelPricing.fable)
        XCTAssertEqual(ModelPricing.forModel("claude-opus-5"), ModelPricing.opus)
        XCTAssertEqual(ModelPricing.forModel("claude-opus-4-1-20250805"), ModelPricing.opusLegacy)
        XCTAssertEqual(ModelPricing.forModel("claude-sonnet-5"), ModelPricing.sonnet)
        XCTAssertEqual(ModelPricing.forModel("claude-haiku-4-5"), ModelPricing.haiku)
    }

    func testDisplayName() {
        XCTAssertEqual(ModelPricing.displayName(for: "claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-fable-5"), "Fable 5")
    }
}

final class UsageBlockTests: XCTestCase {
    private func entry(atMinutes minutes: Double, tokens: Int = 10) -> ClaudeUsageEntry {
        ClaudeUsageEntry(timestamp: Date(timeIntervalSince1970: 1_000_000_000 + minutes * 60),
                         model: "claude-opus-5", inputTokens: tokens, outputTokens: 0,
                         cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    func testEntriesWithinFiveHoursShareABlock() {
        let blocks = UsageBlock.build(from: [
            entry(atMinutes: 0), entry(atMinutes: 60), entry(atMinutes: 240),
        ])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].totals.inputTokens, 30)
    }

    func testGapStartsNewBlock() {
        let blocks = UsageBlock.build(from: [
            entry(atMinutes: 0),
            entry(atMinutes: 400), // > 5h after block start AND after last activity
        ])
        XCTAssertEqual(blocks.count, 2)
    }

    func testBlockStartIsFlooredToHour() {
        let ts = Date(timeIntervalSince1970: 1_000_000_000 + 42 * 60) // hh:42
        let blocks = UsageBlock.build(from: [
            ClaudeUsageEntry(timestamp: ts, model: "m", inputTokens: 1, outputTokens: 0,
                             cacheCreationTokens: 0, cacheReadTokens: 0)
        ])
        XCTAssertEqual(blocks[0].start, UsageBlock.floorToHour(ts))
        XCTAssertEqual(blocks[0].start.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: 3600), 0)
    }

    func testActiveBlockAndRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_000_000_000 + 60 * 60)
        let blocks = UsageBlock.build(from: [entry(atMinutes: 0)])
        let block = blocks[0]
        XCTAssertTrue(block.isActive(at: now))
        // Block start is floored to the hour containing t0; 4h remain of 5h.
        XCTAssertEqual(block.remaining(at: now), 4 * 3600,
                       accuracy: 3600) // within the flooring tolerance
        XCTAssertFalse(block.isActive(at: now.addingTimeInterval(6 * 3600)))
    }

    func testUnsortedInput() {
        let blocks = UsageBlock.build(from: [
            entry(atMinutes: 240), entry(atMinutes: 0), entry(atMinutes: 60),
        ])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].totals.entryCount, 3)
    }
}

final class CloudUsageFetcherTests: XCTestCase {
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

    func testParsesFilesFromGistResponse() {
        let lines = [
            gistLine(timestamp: "2026-08-29T10:00:00Z", input: 100, output: 50),
            gistLine(timestamp: "2026-08-29T10:05:00Z", input: 20, output: 10,
                     messageID: "msg_2", requestID: "req_2"),
        ].joined(separator: "\n")
        let data = gistResponse(files: ["session-abc.jsonl": lines])

        let entries = CloudUsageFetcher.parseGistResponse(data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.inputTokens }, 120)
    }

    func testDeduplicatesAcrossFiles() {
        let line = gistLine(timestamp: "2026-08-29T10:00:00Z")
        // Same session republished under two file snapshots must not double-count.
        let data = gistResponse(files: [
            "session-abc.jsonl": line,
            "session-abc-old.jsonl": line,
        ])
        let entries = CloudUsageFetcher.parseGistResponse(data)
        XCTAssertEqual(entries.count, 1)
    }

    func testMalformedResponseReturnsEmpty() {
        XCTAssertEqual(CloudUsageFetcher.parseGistResponse(Data("not json".utf8)).count, 0)
        XCTAssertEqual(CloudUsageFetcher.parseGistResponse(Data("{}".utf8)).count, 0)
    }

    func testSnapshotMergesAdditionalEntriesIntoActiveBlockAndToday() {
        let reader = ClaudeUsageReader(configDirectories: [])
        let now = Date()
        let cloudEntry = ClaudeUsageEntry(timestamp: now.addingTimeInterval(-60),
                                          model: "claude-opus-5", inputTokens: 500,
                                          outputTokens: 250, cacheCreationTokens: 0,
                                          cacheReadTokens: 0)
        let snap = reader.snapshot(now: now, additionalEntries: [cloudEntry])
        XCTAssertEqual(snap.activeBlock?.totals.inputTokens, 500)
        XCTAssertEqual(snap.today.inputTokens, 500)
        XCTAssertEqual(snap.latestModel, "claude-opus-5")
    }
}
