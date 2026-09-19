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

// MARK: - Staggered scan (detail path vs. bucket path)

@Suite struct ClaudeUsageReaderWindowTests {
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

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Legt `<tmp>/projects/<projectDir>/<file>.jsonl` an, schreibt die
    /// gegebenen Zeilen hinein und setzt die Datei-mtime explizit - die
    /// Testfaelle haengen davon ab, ob eine Datei im Detail- oder
    /// Eimerfenster liegt, nicht davon, wann sie tatsaechlich geschrieben
    /// wurde.
    private func makeTranscript(lines: [String], mtime: Date) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("xeneon-window-\(UUID().uuidString)")
        try addTranscript(to: base, fileName: "session.jsonl", lines: lines, mtime: mtime)
        return base
    }

    /// Schreibt ein weiteres Transkript in ein bestehendes Basisverzeichnis -
    /// fuer Testfaelle, die mehrere Dateien mit je eigenem Dateinamen und
    /// eigener mtime im selben Scan brauchen (dateiuebergreifende Duplikate,
    /// Eimer-Cache). Ruft man denselben `fileName` erneut auf, wird die
    /// bestehende Datei ueberschrieben - so laesst sich derselbe Pfad mit
    /// neuem Inhalt, aber gleicher mtime praeparieren.
    private func addTranscript(to base: URL, fileName: String, lines: [String], mtime: Date) throws {
        let projects = base.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent(fileName)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
    }

    /// Eine Datei, deren mtime und Eintraege beide 3 Tage alt sind, liegt
    /// ausserhalb des 30h-Detailfensters, aber innerhalb des Wochenfensters:
    /// ihre Tokens tauchen in `week` auf, aber weder in `activeBlock` noch
    /// in `today`, weil beide nur aus dem Detailpfad gespeist werden.
    @Test func fileOlderThanDetailWindowFeedsWeekOnlyNotBlockOrToday() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let dir = try makeTranscript(
            lines: [line(timestamp: iso(threeDaysAgo), input: 50)],
            mtime: threeDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.week.totals.inputTokens == 50)
        #expect(snap.activeBlock == nil)
        #expect(snap.today.inputTokens == 0)
    }

    /// Eine frische Datei mit heutigen Eintraegen landet im Detailpfad und
    /// zaehlt ueberall: `today`, `day` und `week`.
    @Test func freshFileFeedsTodayDayAndWeek() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-60)
        let dir = try makeTranscript(
            lines: [line(timestamp: iso(recent), input: 30)],
            mtime: recent)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.today.inputTokens == 30)
        #expect(snap.day.totals.inputTokens == 30)
        #expect(snap.week.totals.inputTokens == 30)
    }

    /// Eine Datei mit einer mtime von vor 10 Tagen liegt ausserhalb des
    /// 7-Tage-Eimerfensters (plus Puffer) und taucht nirgends auf - weder im
    /// Detail- noch im Verdichtungspfad wird sie ueberhaupt angefasst.
    @Test func fileOlderThanBucketWindowIsIgnoredEntirely() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let dir = try makeTranscript(
            lines: [line(timestamp: iso(tenDaysAgo), input: 999)],
            mtime: tenDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.week.totals.inputTokens == 0)
        #expect(snap.today.inputTokens == 0)
        #expect(snap.activeBlock == nil)
    }

    /// Derselbe messageID/requestID zweimal in einer alten, verdichteten
    /// Datei (typisch fuer gestreamte Antworten) darf im Verdichtungspfad
    /// nur einmal zaehlen - dieselbe Dedupe-Garantie wie im Detailpfad, nur
    /// innerhalb dieser einen Datei statt ueber alle Dateien hinweg.
    @Test func duplicateEntryInOldFileCountsOnceInWeekBucket() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let dir = try makeTranscript(
            lines: [
                line(timestamp: iso(threeDaysAgo), input: 40, messageID: "dup", requestID: "req_dup"),
                line(timestamp: iso(threeDaysAgo), input: 40, messageID: "dup", requestID: "req_dup"),
            ],
            mtime: threeDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.week.totals.inputTokens == 40)
        #expect(snap.week.totals.entryCount == 1)
    }

    /// Zwei getrennte Dateien mit demselben messageID+requestID duerfen im
    /// Wochenfenster nur einmal zaehlen - die Zusage, dass `seen` auch
    /// dateiuebergreifend dedupliziert, nicht nur innerhalb einer Datei.
    @Test func duplicateAcrossTwoOldFilesCountsOnceInWeek() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let sameLine = line(timestamp: iso(threeDaysAgo), input: 40,
                            messageID: "cross", requestID: "req_cross")
        let dir = try makeTranscript(lines: [sameLine], mtime: threeDaysAgo)
        try addTranscript(to: dir, fileName: "session-2.jsonl", lines: [sameLine], mtime: threeDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.week.totals.inputTokens == 40)
        #expect(snap.week.totals.entryCount == 1)
    }

    /// Derselbe Eintrag taucht sowohl in einer frischen Datei (Detailpfad)
    /// als auch in einer alten Datei (Eimerpfad) auf - er zaehlt in `week`
    /// nur einmal und gehoert wegen seines 3 Tage alten Zeitstempels in
    /// keine Tagessumme, obwohl die ihn enthaltende zweite Datei frisch ist.
    @Test func duplicateAcrossDetailAndBucketPathCountsOnceAndStaysOutOfToday() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-60)
        let sameLine = line(timestamp: iso(threeDaysAgo), input: 40,
                            messageID: "stale", requestID: "req_stale")
        let dir = try makeTranscript(lines: [sameLine], mtime: threeDaysAgo)
        try addTranscript(to: dir, fileName: "session-fresh.jsonl", lines: [sameLine], mtime: recent)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.week.totals.entryCount == 1)
        #expect(snap.today.inputTokens == 0)
    }

    /// Eine unveraendert wirkende alte Datei (gleiche mtime, gleiche Groesse)
    /// darf beim zweiten `snapshot(now:)` auf derselben Reader-Instanz nicht
    /// erneut geparst werden - der Eimer-Cache muss den alten Wert liefern,
    /// nicht den neuen Dateiinhalt.
    @Test func unchangedOldFileIsNotReparsedOnSecondSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let dir = try makeTranscript(
            lines: [line(timestamp: iso(threeDaysAgo), input: 40)],
            mtime: threeDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let first = reader.snapshot(now: now)
        #expect(first.week.totals.inputTokens == 40)

        // Gleiche Stellenzahl (40 -> 70), damit die Dateigroesse unveraendert
        // bleibt - nur mtime und Groesse entscheiden ueber einen Cache-Treffer.
        try addTranscript(to: dir, fileName: "session.jsonl",
                          lines: [line(timestamp: iso(threeDaysAgo), input: 70)],
                          mtime: threeDaysAgo)

        let second = reader.snapshot(now: now)
        #expect(second.week.totals.inputTokens == 40)
    }

    /// `day` zaehlt nur den heutigen Kalendertag - ein 3 Tage alter Eintrag
    /// darf dort nicht auftauchen, auch wenn er im Wochenfenster mitzaehlt.
    @Test func fileOlderThanDetailWindowIsExcludedFromDayWindow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let dir = try makeTranscript(
            lines: [line(timestamp: iso(threeDaysAgo), input: 40)],
            mtime: threeDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let snap = reader.snapshot(now: now)

        #expect(snap.day.totals.entryCount == 0)
        #expect(snap.day.totals.inputTokens == 0)
        #expect(snap.week.totals.inputTokens == 40)
    }

    /// Der dedupKeys-Cache aus dem Eimer-Cache muss bei jedem Lauf erneut in
    /// `seen` einfliessen - sonst kippt das Wochenergebnis zwischen zwei
    /// Widget-Refreshes, weil beim zweiten Lauf eine der beiden Dateien
    /// wieder als unberuecksichtigtes Duplikat auftauchen wuerde.
    @Test func crossFileDedupIsStableAcrossTwoSnapshotRuns() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let sameLine = line(timestamp: iso(threeDaysAgo), input: 40,
                            messageID: "dup2", requestID: "req_dup2")
        let dir = try makeTranscript(lines: [sameLine], mtime: threeDaysAgo)
        try addTranscript(to: dir, fileName: "session-2.jsonl", lines: [sameLine], mtime: threeDaysAgo)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = ClaudeUsageReader(configDirectories: [dir])
        let first = reader.snapshot(now: now)
        let second = reader.snapshot(now: now)

        #expect(first.week.totals.inputTokens == 40)
        #expect(first.week.totals.entryCount == 1)
        #expect(second.week.totals.inputTokens == first.week.totals.inputTokens)
        #expect(second.week.totals.entryCount == first.week.totals.entryCount)
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

@Suite struct UsageWindowTests {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func entry(at date: Date, tokens: Int = 10) -> ClaudeUsageEntry {
        ClaudeUsageEntry(timestamp: date, model: "claude-opus-5", inputTokens: tokens,
                         outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    @Test func dayWindowExcludesYesterdayAndSetsNextMidnightAsReset() {
        let calendar = berlin
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23,
                                                      hour: 14, minute: 0))!
        let startOfToday = calendar.startOfDay(for: now)
        let entryEarlyToday = entry(at: startOfToday.addingTimeInterval(60), tokens: 5)
        let entryLaterToday = entry(at: now, tokens: 7)
        let entryJustBeforeMidnight = entry(at: startOfToday.addingTimeInterval(-1), tokens: 99)

        let window = UsageWindow.day(from: [entryEarlyToday, entryLaterToday, entryJustBeforeMidnight],
                                     now: now, calendar: calendar)

        #expect(window.kind == .day)
        #expect(window.totals.inputTokens == 12)
        #expect(window.totals.entryCount == 2)
        let expectedReset = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        #expect(window.resetsAt == expectedReset)
        #expect(window.start == startOfToday)
        #expect(window.end == expectedReset)
    }

    /// Sommerzeitumstellung: 29.03.2026 hat wegen der verlorenen Stunde nur
    /// 23 Stunden - der Calendar-Umweg in `UsageWindow.day` ist genau fuer
    /// diesen Fall da, ein simples `+ 24h` waere hier falsch.
    @Test func dayWindowSpansOnlyTwentyThreeHoursOnSpringForwardDST() {
        let calendar = berlin
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29,
                                                      hour: 14, minute: 0))!
        let expectedStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29,
                                                                hour: 0, minute: 0))!
        let expectedEnd = calendar.date(from: DateComponents(year: 2026, month: 3, day: 30,
                                                              hour: 0, minute: 0))!

        let entryJustAfterStart = entry(at: expectedStart.addingTimeInterval(60), tokens: 5)
        let entryJustBeforeEnd = entry(at: expectedEnd.addingTimeInterval(-1), tokens: 7)
        let entryJustBeforeStart = entry(at: expectedStart.addingTimeInterval(-1), tokens: 99)

        let window = UsageWindow.day(from: [entryJustAfterStart, entryJustBeforeEnd, entryJustBeforeStart],
                                     now: now, calendar: calendar)

        #expect(window.start == expectedStart)
        #expect(window.end == expectedEnd)
        #expect(window.end.timeIntervalSince(window.start) == 23 * 60 * 60)
        #expect(window.totals.entryCount == 2)
        #expect(window.totals.inputTokens == 12)
    }

    /// Winterzeitumstellung: 25.10.2026 hat wegen der gewonnenen Stunde 25
    /// Stunden - der Gegenfall zur Sommerzeitumstellung.
    @Test func dayWindowSpansTwentyFiveHoursOnFallBackDST() {
        let calendar = berlin
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25,
                                                      hour: 14, minute: 0))!
        let expectedStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25,
                                                                hour: 0, minute: 0))!
        let expectedEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26,
                                                              hour: 0, minute: 0))!

        let entryJustAfterStart = entry(at: expectedStart.addingTimeInterval(60), tokens: 5)
        let entryJustBeforeEnd = entry(at: expectedEnd.addingTimeInterval(-1), tokens: 7)
        let entryJustBeforeStart = entry(at: expectedStart.addingTimeInterval(-1), tokens: 99)

        let window = UsageWindow.day(from: [entryJustAfterStart, entryJustBeforeEnd, entryJustBeforeStart],
                                     now: now, calendar: calendar)

        #expect(window.start == expectedStart)
        #expect(window.end == expectedEnd)
        #expect(window.end.timeIntervalSince(window.start) == 25 * 60 * 60)
        #expect(window.totals.entryCount == 2)
        #expect(window.totals.inputTokens == 12)
    }

    @Test func remainingWithoutResetsAtIsNil() {
        let window = UsageWindow(kind: .week, start: .distantPast, end: .distantPast)
        #expect(window.remaining(at: Date()) == nil)
    }

    @Test func remainingWithFutureResetsAtReturnsDifferenceInSeconds() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetsAt = now.addingTimeInterval(3600)
        let window = UsageWindow(kind: .day, start: .distantPast, end: .distantPast, resetsAt: resetsAt)

        #expect(window.remaining(at: now) == 3600)
    }

    @Test func remainingWithPastResetsAtIsClampedToZeroNotNegative() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetsAt = now.addingTimeInterval(-3600)
        let window = UsageWindow(kind: .day, start: .distantPast, end: .distantPast, resetsAt: resetsAt)

        #expect(window.remaining(at: now) == 0)
    }

    @Test func kindTitlesMatchGermanLabels() {
        #expect(UsageWindow.Kind.block.title == "5 h")
        #expect(UsageWindow.Kind.day.title == "Tag")
        #expect(UsageWindow.Kind.week.title == "Woche")
    }

    @Test func weekWindowIncludesSixDaysExcludesEightDaysAndTheSevenDayEdge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let exactlySevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let window = UsageWindow.week(from: [
            entry(at: sixDaysAgo, tokens: 3),
            entry(at: eightDaysAgo, tokens: 100),
            entry(at: exactlySevenDaysAgo, tokens: 200),
        ], now: now)

        #expect(window.kind == .week)
        #expect(window.totals.inputTokens == 3)
        #expect(window.totals.entryCount == 1)
    }

    @Test func weekWindowResetsAtOldestConsideredEntryPlusSevenDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)

        let window = UsageWindow.week(from: [entry(at: sixDaysAgo), entry(at: threeDaysAgo)],
                                      now: now)

        #expect(window.resetsAt == sixDaysAgo.addingTimeInterval(7 * 24 * 60 * 60))
    }

    @Test func emptyWindowHasNoTokensNoResetAndNoFraction() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = UsageWindow.week(from: [], now: now)

        #expect(window.totals.totalTokens == 0)
        #expect(window.resetsAt == nil)
        #expect(window.fraction(of: 0, includeCacheReads: false) == nil)
    }

    @Test func fractionUsesBillableTokensByDefaultAndTotalTokensWithCacheReads() {
        var totals = UsageTotals()
        totals.inputTokens = 30
        totals.outputTokens = 20
        totals.cacheReadTokens = 25
        let window = UsageWindow(kind: .day, start: .distantPast, end: .distantPast, totals: totals)

        // 50 billable tokens of a 100 budget.
        #expect(window.fraction(of: 100, includeCacheReads: false) == 0.5)
        // 75 total tokens (including cache reads) of a 100 budget.
        #expect(window.fraction(of: 100, includeCacheReads: true) == 0.75)
    }

    @Test func usageTotalsAddMergesBothTotalsFieldByField() {
        var a = UsageTotals()
        a.inputTokens = 10
        a.outputTokens = 20
        a.cacheCreationTokens = 5
        a.cacheReadTokens = 3
        a.costUSD = 1.5
        a.entryCount = 2

        var b = UsageTotals()
        b.inputTokens = 100
        b.outputTokens = 200
        b.cacheCreationTokens = 50
        b.cacheReadTokens = 30
        b.costUSD = 2.5
        b.entryCount = 4

        a.add(b)

        #expect(a.inputTokens == 110)
        #expect(a.outputTokens == 220)
        #expect(a.cacheCreationTokens == 55)
        #expect(a.cacheReadTokens == 33)
        #expect(abs(a.costUSD - 4.0) <= 0.001)
        #expect(a.entryCount == 6)
    }

    @Test func hourBucketBuildsSortedBucketsPerFullHour() {
        let baseHour = UsageBlock.floorToHour(Date(timeIntervalSince1970: 1_700_000_000))
        let firstHourEntries = [
            entry(at: baseHour.addingTimeInterval(60), tokens: 10),
            entry(at: baseHour.addingTimeInterval(600), tokens: 10),
            entry(at: baseHour.addingTimeInterval(3000), tokens: 10),
        ]
        let secondHourEntry = entry(at: baseHour.addingTimeInterval(3700), tokens: 10)

        // Unsorted input on purpose - buckets() must sort by hour itself.
        let buckets = HourBucket.buckets(from: [secondHourEntry] + firstHourEntries)

        #expect(buckets.count == 2)
        #expect(buckets[0].hour == UsageBlock.floorToHour(baseHour))
        #expect(buckets[0].totals.entryCount == 3)
        #expect(buckets[1].hour == UsageBlock.floorToHour(baseHour.addingTimeInterval(3700)))
        #expect(buckets[1].totals.entryCount == 1)
        #expect(buckets[0].hour < buckets[1].hour)
        #expect(buckets[0].hour.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: 3600) == 0)
    }

    @Test func weekFromBucketsCountsBucketInsideWindowAndTodayEntry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = UsageBlock.floorToHour(now.addingTimeInterval(-3 * 24 * 60 * 60))
        var bucket = HourBucket(hour: threeDaysAgo)
        bucket.totals.inputTokens = 40
        bucket.totals.entryCount = 4

        let todayEntry = entry(at: now, tokens: 8)

        let window = UsageWindow.week(fromBuckets: [bucket], entries: [todayEntry], now: now)

        #expect(window.kind == .week)
        #expect(window.totals.inputTokens == 48)
        #expect(window.totals.entryCount == 5)
    }

    @Test func weekFromBucketsExcludesBucketOlderThanFlooredWindowStart() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let flooredStart = UsageBlock.floorToHour(now.addingTimeInterval(-7 * 24 * 60 * 60))
        var tooOld = HourBucket(hour: flooredStart.addingTimeInterval(-3600))
        tooOld.totals.inputTokens = 999
        tooOld.totals.entryCount = 1

        let window = UsageWindow.week(fromBuckets: [tooOld], entries: [], now: now)

        #expect(window.totals.inputTokens == 0)
        #expect(window.totals.entryCount == 0)
        #expect(window.resetsAt == nil)
    }

    @Test func weekFromBucketsResetsAtFollowsEarliestConsideredMark() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketHour = UsageBlock.floorToHour(now.addingTimeInterval(-6 * 24 * 60 * 60))
        let bucket = HourBucket(hour: bucketHour)
        let laterEntry = entry(at: now.addingTimeInterval(-3 * 24 * 60 * 60), tokens: 1)

        let window = UsageWindow.week(fromBuckets: [bucket], entries: [laterEntry], now: now)

        #expect(window.resetsAt == bucketHour.addingTimeInterval(7 * 24 * 60 * 60))
    }

    @Test func weekFromBucketsWithoutBucketsOrEntriesIsEmpty() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = UsageWindow.week(fromBuckets: [], entries: [], now: now)

        #expect(window.totals.totalTokens == 0)
        #expect(window.totals.entryCount == 0)
        #expect(window.resetsAt == nil)
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

    /// Acceptance criterion: a profile whose directory does not exist (the
    /// "Team" login before its first `CLAUDE_CONFIG_DIR=... claude` run, for
    /// example) must show up as zero tokens, never crash and never poison
    /// the other profiles' results.
    @Test func missingDirectoryYieldsZeroTokensNotACrash() throws {
        let now = Date()
        let existingDir = try makeProfile(lines: [line(at: now.addingTimeInterval(-120), input: 55, messageID: "x")])
        defer { try? FileManager.default.removeItem(at: existingDir) }
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xeneon-profile-does-not-exist-\(UUID().uuidString)")

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [
            ClaudeProfile(name: "Persönlich / Pro", configDir: existingDir.path),
            ClaudeProfile(name: "inxire / Team", configDir: missingDir.path),
        ], now: now)

        #expect(usages.count == 2)
        #expect(usages[0].snapshot.today.inputTokens == 55)
        #expect(usages[1].snapshot.today.inputTokens == 0)
        #expect(usages[1].snapshot.activeBlock == nil)
        #expect(usages[1].snapshot.subscriptionType == nil)
        #expect(usages[1].snapshot.scannedFiles == 0)
    }

    /// A path that exists but is a plain file (not a directory) — a
    /// plausible typo in a hand-edited config — must be equally harmless.
    @Test func configDirPointingAtAFileYieldsZeroTokens() throws {
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("xeneon-not-a-directory-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: filePath)
        defer { try? FileManager.default.removeItem(at: filePath) }

        let reader = ClaudeUsageReader(configDirectories: [])
        let usages = reader.snapshots(for: [
            ClaudeProfile(name: "Broken", configDir: filePath.path)
        ])
        #expect(usages[0].snapshot.today.inputTokens == 0)
        #expect(usages[0].snapshot.activeBlock == nil)
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
        // Die Kurzform bleibt gueltig und ist standardmaessig aktiv.
        #expect(decoded.claudeProfiles[0].enabled == true)
    }

    /// Bestehende Konfigurationen ohne `enabled` verhalten sich unveraendert:
    /// das Profil bleibt aktiv.
    @Test func profileWithoutEnabledDecodesToEnabled() throws {
        let json = #"{"claudeProfiles": [{"name": "Privat", "configDir": "~/.claude"}]}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.claudeProfiles[0].enabled == true)
    }

    /// `"enabled": false` schaltet ein Profil ab, ohne seine Konfiguration
    /// zu verlieren.
    @Test func profileWithEnabledFalseDecodesToDisabled() throws {
        let json = #"{"claudeProfiles": [{"name": "Team", "configDir": "~/.claude-team", "enabled": false}]}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.claudeProfiles[0].enabled == false)
        #expect(decoded.claudeProfiles[0].name == "Team")
        #expect(decoded.claudeProfiles[0].configDir == "~/.claude-team")
    }

    /// `active(_:)` filtert deaktivierte Profile heraus und erhaelt die
    /// Reihenfolge der uebrigen.
    @Test func activeFiltersDisabledProfilesAndKeepsOrder() {
        let max = ClaudeProfile(name: "Max", configDir: "~/.claude", enabled: true)
        let team = ClaudeProfile(name: "Team", configDir: "~/.claude-team", enabled: false)
        let pro = ClaudeProfile(name: "Pro", configDir: "~/.claude-pro", enabled: true)

        let active = ClaudeProfile.active([max, team, pro])
        #expect(active.count == 2)
        #expect(active[0].name == "Max")
        #expect(active[1].name == "Pro")
    }

    /// Round-trip: ein deaktiviertes Profil bleibt nach Encode/Decode
    /// deaktiviert.
    @Test func disabledProfileSurvivesEncodeDecodeRoundTrip() throws {
        let profile = ClaudeProfile(name: "Team", configDir: "~/.claude-team", enabled: false)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ClaudeProfile.self, from: data)
        #expect(decoded.enabled == false)
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
