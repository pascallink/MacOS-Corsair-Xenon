// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

/// Antwortet ohne Netz mit einer festen Antwort (nur in ephemeren Sessions).
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let r = HTTPURLResponse(url: request.url!, statusCode: StubProtocol.status,
                                httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubProtocol.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct KIVersionsTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func entry(id: String = "1", project: String = "DBREFI", label: String = "REFI 52.0",
                       total: String = "40", areas: String? = nil, score: String? = nil) -> String {
        let a = areas ?? #"{"preparation":{"count":5},"development":{"count":12},"acceptance":{"count":8},"done":{"count":15}}"#
        var s = #"{"id":"\#(id)","project":"\#(project)","name":"52.0","label":"\#(label)","releaseDate":"2026-12-15","released":false,"total":\#(total),"areas":\#(a)"#
        if let score { s += #","score":\#(score)"# }
        return s + "}"
    }

    private func wrap(_ entries: [String]) -> Data { data(#"{"versions":["# + entries.joined(separator: ",") + "]}") }

    @Test func parsesFullEntry() throws {
        let rings = try #require(KIVersionsParser.versions(
            from: wrap([entry(score: #"{"points":50,"max":80,"percent":63}"#)]), projects: []))
        #expect(rings.count == 1)
        let r = rings[0]
        #expect(r.id == "1" && r.project == "DBREFI" && r.name == "52.0" && r.label == "REFI 52.0")
        #expect(r.releaseDate == "2026-12-15" && r.released == false && r.total == 40)
        #expect(r.areas.map(\.area) == [.preparation, .development, .acceptance, .done])
        #expect(r.areas.map(\.count) == [5, 12, 8, 15])
        #expect(r.scorePercent == 63)
        #expect(r.fractions == [0.125, 0.3, 0.2, 0.375])
        #expect(r.allDone == false)
    }

    @Test func missingPreparationKeepsThreeAreas() throws {
        let areas = #"{"development":{"count":12},"acceptance":{"count":8},"done":{"count":15}}"#
        let r = try #require(KIVersionsParser.versions(from: wrap([entry(areas: areas)]), projects: [])?.first)
        #expect(r.areas.map(\.area) == [.development, .acceptance, .done])
        #expect(r.fractions.count == 3)
    }

    @Test func missingScoreIsNil() throws {
        let r = try #require(KIVersionsParser.versions(from: wrap([entry()]), projects: [])?.first)
        #expect(r.scorePercent == nil)
    }

    @Test func totalZeroGivesZeroFractions() throws {
        let areas = #"{"development":{"count":0},"done":{"count":0}}"#
        let r = try #require(KIVersionsParser.versions(from: wrap([entry(total: "0", areas: areas)]), projects: [])?.first)
        #expect(r.fractions == [0, 0])
        #expect(r.allDone == false)
    }

    @Test func allDoneWhenDoneEqualsTotal() throws {
        let areas = #"{"development":{"count":0},"done":{"count":40}}"#
        let r = try #require(KIVersionsParser.versions(from: wrap([entry(areas: areas)]), projects: [])?.first)
        #expect(r.allDone)
        #expect(r.fractions == [0, 1])
    }

    @Test func fractionsAreClamped() {
        let r = KIVersionRing(id: "1", project: "P", name: "n", label: "l", total: 10,
                              areas: [KIAreaCount(area: .done, count: 15)])
        #expect(r.fractions == [1])
    }

    @Test func projectFilterAndOrder() throws {
        let rings = try #require(KIVersionsParser.versions(from: wrap([
            entry(id: "1", project: "DBREFI", label: "REFI 52.0"),
            entry(id: "2", project: "RWMD", label: "RWMD 1"),
            entry(id: "3", project: "DBCUBE", label: "CUBE 1"),
            entry(id: "4", project: "DBREFI", label: "REFI 53.0"),
        ]), projects: ["DBCUBE", "DBREFI"]))
        #expect(rings.map(\.id) == ["3", "1", "4"])
        let all = KIVersionsParser.versions(from: wrap([entry(id: "1"), entry(id: "2", project: "RWMD")]), projects: [])
        #expect(all?.count == 2)
    }

    @Test func brokenEntriesAreSkipped() throws {
        let rings = try #require(KIVersionsParser.versions(from: wrap([
            #"{"project":"DBREFI","label":"x","total":1}"#,
            #"{"id":"a","label":"x","total":1}"#,
            #"{"id":"b","project":"DBREFI","total":1}"#,
            #"{"id":"c","project":"DBREFI","label":"x"}"#,
            entry(id: "d", total: "-3"),
            entry(id: "e", areas: #"{"done":{"count":-1}}"#),
            "42",
            entry(id: "ok"),
        ]), projects: []))
        #expect(rings.map(\.id) == ["ok"])
    }

    @Test func invalidJSONOrMissingVersionsIsNil() {
        #expect(KIVersionsParser.versions(from: data("kaputt"), projects: []) == nil)
        #expect(KIVersionsParser.versions(from: data(#"{"x":1}"#), projects: []) == nil)
        #expect(KIVersionsParser.versions(from: data(#"{"versions":{}}"#), projects: []) == nil)
        #expect(KIVersionsParser.versions(from: data(#"{"versions":[]}"#), projects: []) == [])
    }

    @Test func numbersAreTolerantButNeverBool() throws {
        let ok = try #require(KIVersionsParser.versions(from: wrap([entry(total: "40.0")]), projects: [])?.first)
        #expect(ok.total == 40)
        #expect(KIVersionsParser.versions(from: wrap([entry(total: "true")]), projects: [])?.isEmpty == true)
        #expect(KIVersionsParser.versions(from: wrap([entry(total: "40.5")]), projects: [])?.isEmpty == true)
        #expect(KIVersionsParser.versions(from: wrap([entry(areas: #"{"done":{"count":true}}"#)]), projects: [])?.isEmpty == true)
        // 0 und 1 sind keine Bools
        let small = try #require(KIVersionsParser.versions(from: wrap([entry(total: "1", areas: #"{"done":{"count":1},"development":{"count":0}}"#)]), projects: [])?.first)
        #expect(small.total == 1 && small.allDone)
    }

    @Test func errorMessageReadsErrorField() {
        #expect(KIVersionsParser.errorMessage(from: data(#"{"error":"Jira down"}"#)) == "Jira down")
        #expect(KIVersionsParser.errorMessage(from: data("{}")) == nil)
        #expect(KIVersionsParser.errorMessage(from: data("kaputt")) == nil)
    }

    @Test func endpointBuildsURL() {
        #expect(KIVersionsReader.endpoint(base: "http://127.0.0.1:3001")?.absoluteString == "http://127.0.0.1:3001/api/developers")
        #expect(KIVersionsReader.endpoint(base: "http://127.0.0.1:3001/")?.absoluteString == "http://127.0.0.1:3001/api/developers")
        #expect(KIVersionsReader.endpoint(base: "https://ki.example/")?.absoluteString == "https://ki.example/api/developers")
        #expect(KIVersionsReader.endpoint(base: "") == nil)
        #expect(KIVersionsReader.endpoint(base: "  ") == nil)
        #expect(KIVersionsReader.endpoint(base: "ftp://host") == nil)
        #expect(KIVersionsReader.endpoint(base: "nonsense") == nil)
    }

    // MARK: Fetch ueber URLProtocol

    private func fetch(status: Int, body: String, base: String = "http://127.0.0.1:3001") async -> Result<[KIVersionRing], KIVersionsError> {
        StubProtocol.status = status
        StubProtocol.body = data(body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let reader = KIVersionsReader(baseURL: base, projects: ["DBREFI"], session: URLSession(configuration: config))
        return await withCheckedContinuation { cont in reader.fetch { cont.resume(returning: $0) } }
    }

    @Test func fetchSuccess() async {
        let result = await fetch(status: 200, body: #"{"versions":["# + entry() + "]}")
        #expect((try? result.get())?.count == 1)
    }

    @Test func fetchMapsErrors() async {
        #expect(await fetch(status: 503, body: #"{"error":"Jira down"}"#) == .failure(.http(503, "Jira down")))
        #expect(await fetch(status: 500, body: "x") == .failure(.http(500, nil)))
        #expect(await fetch(status: 200, body: "kaputt") == .failure(.invalidResponse))
        #expect(await fetch(status: 200, body: "{}", base: "") == .failure(.invalidURL))
    }

    // MARK: Zeitplan

    private var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func next(after d: Date) -> Date { KIVersionsSchedule(calendar: berlin).naechsterLauf(nach: d) }

    // 2026-11-16 ist ein Montag.
    @Test func scheduleWithinWeekday() {
        #expect(next(after: date(2026, 11, 16, 7, 0)) == date(2026, 11, 16, 7, 45))
        #expect(next(after: date(2026, 11, 16, 7, 45)) == date(2026, 11, 16, 9, 45))
        #expect(next(after: date(2026, 11, 16, 17, 50)) == date(2026, 11, 16, 18, 45))
        #expect(next(after: date(2026, 11, 16, 18, 45)) == date(2026, 11, 17, 7, 45))
    }

    @Test func scheduleSkipsWeekend() {
        #expect(next(after: date(2026, 11, 20, 19, 0)) == date(2026, 11, 23, 7, 45))   // Fr
        #expect(next(after: date(2026, 11, 21, 12, 0)) == date(2026, 11, 23, 7, 45))   // Sa
        #expect(next(after: date(2026, 11, 22, 23, 59)) == date(2026, 11, 23, 7, 45))  // So
    }

    @Test func scheduleAcrossDST() {
        #expect(next(after: date(2026, 3, 29, 12, 0)) == date(2026, 3, 30, 7, 45))
        #expect(next(after: date(2026, 10, 25, 12, 0)) == date(2026, 10, 26, 7, 45))
        #expect(berlin.component(.hour, from: next(after: date(2026, 3, 29, 12, 0))) == 7)
    }

    @Test func scheduleDefaultsAndEmptySlotsTerminate() {
        #expect(KIVersionsSchedule.defaultSlots.count == 7)
        let empty = KIVersionsSchedule(slots: [], calendar: berlin)
        let now = date(2026, 11, 16, 7, 0)
        #expect(empty.naechsterLauf(nach: now) > now)
    }

    // MARK: Config

    @Test func oldConfigGetsDefaults() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: data(#"{"showClock":false}"#))
        #expect(c.showKIVersions == true)
        #expect(c.kiDashboardURL == "http://127.0.0.1:3001")
        #expect(c.kiDashboardProjects == ["DBREFI", "DBCUBE"])
        let set = try JSONDecoder().decode(AppConfig.self, from: data(#"{"showKIVersions":false,"kiDashboardURL":"http://x:3000","kiDashboardProjects":["DBCUBE"]}"#))
        #expect(set.showKIVersions == false && set.kiDashboardURL == "http://x:3000" && set.kiDashboardProjects == ["DBCUBE"])
    }

    // MARK: Zeitstrahl

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func timeline(_ start: String?, _ release: String?, released: Bool = false, today: Date) -> KIVersionTimeline {
        KIVersionTimeline.make(startDate: start, releaseDate: release, released: released,
                               today: today, calendar: berlin)
    }

    @Test func parserReadsStartDate() throws {
        let json = #"{"versions":[{"id":"1","project":"P","label":"L","startDate":"2026-11-01","releaseDate":"2026-12-15","total":1}]}"#
        let rings = try #require(KIVersionsParser.versions(from: data(json), projects: []))
        #expect(rings[0].startDate == "2026-11-01" && rings[0].releaseDate == "2026-12-15")
        let none = try #require(KIVersionsParser.versions(from: wrap([entry()]), projects: []))
        #expect(none[0].startDate == nil)
    }

    @Test func timelineRunningPluralAndSingular() {
        let p = timeline(nil, "2026-11-20", today: at(2026, 11, 17))
        #expect(p.state == .running && p.daysLeft == 3 && p.text == "noch 3 Tage" && p.elapsed == nil)
        let s = timeline(nil, "2026-11-18", today: at(2026, 11, 17))
        #expect(s.state == .running && s.daysLeft == 1 && s.text == "noch 1 Tag")
    }

    @Test func timelineDueToday() {
        let t = timeline(nil, "2026-11-17", today: at(2026, 11, 17))
        #expect(t.state == .dueToday && t.daysLeft == 0 && t.text == "Lieferung heute")
    }

    @Test func timelineOverdue() {
        let one = timeline(nil, "2026-11-16", today: at(2026, 11, 17))
        #expect(one.state == .overdue && one.daysLeft == -1 && one.text == "1 Tag ueberfaellig")
        let many = timeline(nil, "2026-11-10", today: at(2026, 11, 17))
        #expect(many.state == .overdue && many.daysLeft == -7 && many.text == "7 Tage ueberfaellig")
    }

    @Test func timelineReleased() {
        let both = timeline("2026-11-01", "2026-11-21", released: true, today: at(2026, 11, 11))
        #expect(both.state == .released && both.text == "geliefert" && both.elapsed == 1 && both.daysLeft == 10)
        let none = timeline(nil, nil, released: true, today: at(2026, 11, 11))
        #expect(none.state == .released && none.daysLeft == nil && none.elapsed == nil)
    }

    @Test func timelineNoDate() {
        let t = timeline("2026-11-01", nil, today: at(2026, 11, 11))
        #expect(t.state == .noDate && t.daysLeft == nil && t.elapsed == nil && t.text == "ohne Lieferdatum")
    }

    @Test func timelineInvalidDateIsNoDate() {
        let t = timeline(nil, "2026-13-40", today: at(2026, 11, 11))
        #expect(t.state == .noDate && t.daysLeft == nil)
    }

    @Test func timelineElapsedMiddleAndClamped() {
        #expect(timeline("2026-11-01", "2026-11-21", today: at(2026, 11, 11)).elapsed == 0.5)
        #expect(timeline("2026-11-01", "2026-11-21", today: at(2026, 10, 20)).elapsed == 0)
        #expect(timeline("2026-11-01", "2026-11-21", today: at(2026, 12, 5)).elapsed == 1)
    }

    @Test func timelineElapsedNilWhenReleaseNotAfterStart() {
        #expect(timeline("2026-11-21", "2026-11-21", today: at(2026, 11, 21)).elapsed == nil)
        #expect(timeline("2026-11-25", "2026-11-21", today: at(2026, 11, 21)).elapsed == nil)
    }

    @Test func timelineLateEveningCountsAsSameDay() {
        let t = timeline(nil, "2026-11-18", today: at(2026, 11, 17, 23, 59, 59))
        #expect(t.daysLeft == 1)
        let d = timeline(nil, "2026-11-17", today: at(2026, 11, 17, 23, 59, 59))
        #expect(d.state == .dueToday)
    }
}
