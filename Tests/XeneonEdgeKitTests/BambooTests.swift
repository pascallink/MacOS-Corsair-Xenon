// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

/// Zeichnet Anfragen auf und beantwortet sie der Reihe nach, ohne Netz.
private final class BambooStubProtocol: URLProtocol {
    static var responses: [(status: Int, body: Data)] = []
    static var responseIndex = 0
    static var recordedRequests: [URLRequest] = []
    static var failTransport = false
    static var transportError = URLError(.notConnectedToInternet)

    static func reset() {
        responses = []
        responseIndex = 0
        recordedRequests = []
        failTransport = false
        transportError = URLError(.notConnectedToInternet)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        if Self.failTransport {
            client?.urlProtocol(self, didFailWithError: Self.transportError)
            return
        }
        guard Self.responseIndex < Self.responses.count, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let entry = Self.responses[Self.responseIndex]
        Self.responseIndex += 1
        let response = HTTPURLResponse(url: url, statusCode: entry.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: entry.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct FixedBambooToken: BambooTokenSource {
    let value: String?
    func token(forHost host: String) -> String? { value }
}

@Suite(.serialized) struct BambooTests {
    private static let token = "dummy-token"
    private static let base = URL(string: "http://bamboo.example.com")!

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BambooStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> BambooClient {
        BambooClient(baseURL: Self.base, token: Self.token, session: makeSession())
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func result(state: String = "Successful", life: String = "Finished",
                               extra: [String: Any] = [:]) -> [String: Any] {
        var entry: [String: Any] = [
            "lifeCycleState": life, "buildState": state,
            "buildDuration": 600_000,
            "buildCompletedTime": "2026-11-13T02:41:12.345+01:00",
        ]
        for (k, v) in extra { entry[k] = v }
        return entry
    }

    private static func results(_ entries: [[String: Any]]) -> Data {
        json(["results": ["size": entries.count, "result": entries]])
    }

    private static func branches(_ entries: [[String: Any]]) -> Data {
        json(["branches": ["size": entries.count, "branch": entries]])
    }

    private static let plan = BambooPlan(key: "DMCUBE-DMCUB", name: "DMCube")
    private static let extPlan = BambooPlan(key: "DMCUBE-DMCF", name: "Ext", extended: true)

    // MARK: Parser

    @Test("parses finished successful build")
    func parsesSuccessful() {
        let builds = BambooResponseParser.parseResults(Self.results([Self.result()]))
        #expect(builds.count == 1)
        #expect(builds[0].successful)
        #expect(builds[0].duration == 600)
    }

    @Test("parses failed build")
    func parsesFailed() {
        let builds = BambooResponseParser.parseResults(Self.results([Self.result(state: "Failed")]))
        #expect(builds.map(\.successful) == [false])
    }

    @Test("drops in-progress and unknown builds")
    func dropsOtherStates() {
        let data = Self.results([
            Self.result(life: "InProgress"),
            Self.result(state: "Unknown"),
            Self.result(state: "NotBuilt"),
        ])
        #expect(BambooResponseParser.parseResults(data).isEmpty)
    }

    @Test("duration: milliseconds, seconds fallback, double, missing and negative")
    func durationVariants() {
        var seconds = Self.result()
        seconds["buildDuration"] = nil
        seconds["buildDurationInSeconds"] = 90
        var double = Self.result(extra: ["buildDuration": 1500.5])
        double["buildDurationInSeconds"] = nil
        var missing = Self.result()
        missing["buildDuration"] = nil
        let negative = Self.result(extra: ["buildDuration": -5])

        let builds = BambooResponseParser.parseResults(Self.results([seconds, double, missing, negative]))
        #expect(builds.map(\.duration) == [90, 1.5005])
    }

    @Test("completion time with and without fraction, bad time dropped")
    func timeVariants() {
        let withFraction = Self.result()
        let without = Self.result(extra: ["buildCompletedTime": "2026-11-13T02:41:12+01:00"])
        let noColon = Self.result(extra: ["buildCompletedTime": "2026-11-13T02:41:12.345+0100"])
        let bad = Self.result(extra: ["buildCompletedTime": "gestern"])
        let builds = BambooResponseParser.parseResults(Self.results([withFraction, without, noColon, bad]))
        #expect(builds.count == 3)
        let expected = ISO8601DateFormatter().date(from: "2026-11-13T02:41:12+01:00")!
        #expect(builds[1].completedAt == expected)
        #expect(abs(builds[0].completedAt.timeIntervalSince(expected) - 0.345) < 0.001)
        #expect(abs(builds[2].completedAt.timeIntervalSince(expected) - 0.345) < 0.001)
    }

    @Test("broken json yields empty lists")
    func brokenJSON() {
        let junk = Data("{nope".utf8)
        #expect(BambooResponseParser.parseResults(junk).isEmpty)
        #expect(BambooResponseParser.parseBranchKeys(junk).isEmpty)
    }

    @Test("branch keys skip disabled and empty keys")
    func branchKeys() {
        let data = Self.branches([
            ["key": "A-B1", "enabled": true],
            ["key": "A-B2", "enabled": false],
            ["key": "A-B3"],
            ["key": ""],
        ])
        #expect(BambooResponseParser.parseBranchKeys(data) == ["A-B1", "A-B3"])
    }

    // MARK: Statistik

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func build(ago: TimeInterval, duration: TimeInterval = 600, ok: Bool = true) -> BambooBuild {
        BambooBuild(completedAt: Self.now.addingTimeInterval(-ago), duration: duration, successful: ok)
    }

    @Test("window boundary and future tolerance")
    func windowBoundary() {
        let day: TimeInterval = 86400
        let builds = [
            build(ago: 14 * day),            // genau auf der Grenze: drin
            build(ago: 14 * day + 1),        // knapp davor: raus
            build(ago: -30),                 // 30 s in der Zukunft: drin
            build(ago: -120),                // 2 min in der Zukunft: raus
        ]
        let stats = BambooStatistics.evaluate(plan: Self.plan, builds: builds, now: Self.now, windowDays: 14)
        #expect(stats.buildCount == 2)
        let tiny = BambooStatistics.evaluate(plan: Self.plan, builds: [build(ago: day - 1), build(ago: day + 1)],
                                             now: Self.now, windowDays: 0)
        #expect(tiny.buildCount == 1)
    }

    @Test("average and success rate")
    func averageAndRate() {
        let builds = [build(ago: 10, duration: 600), build(ago: 20, duration: 1200),
                      build(ago: 30, duration: 900, ok: false), build(ago: 40, duration: 900)]
        let stats = BambooStatistics.evaluate(plan: Self.plan, builds: builds, now: Self.now, windowDays: 14)
        #expect(stats.averageDuration == 900)
        #expect(stats.successCount == 3)
        #expect(stats.failedCount == 1)
        #expect(stats.successRate == 0.75)
        #expect(stats.fraction == 0.25)
        #expect(!stats.isCapped)
    }

    @Test("capping: normal 1 h versus extended 3 h")
    func capping() {
        let builds = [build(ago: 10, duration: 7200)]
        let normal = BambooStatistics.evaluate(plan: Self.plan, builds: builds, now: Self.now, windowDays: 14)
        #expect(normal.scaleMax == BambooStatistics.normalScale)
        #expect(normal.isCapped)
        #expect(normal.fraction == 1)

        let ext = BambooStatistics.evaluate(plan: Self.extPlan, builds: builds, now: Self.now, windowDays: 14)
        #expect(ext.scaleMax == BambooStatistics.extendedScale)
        #expect(!ext.isCapped)
        #expect(abs(ext.fraction - 7200.0 / 10800.0) < 1e-9)
    }

    @Test("no builds gives nil average and rate")
    func noBuilds() {
        let stats = BambooStatistics.evaluate(plan: Self.plan, builds: [], now: Self.now, windowDays: 14)
        #expect(stats.buildCount == 0)
        #expect(stats.averageDuration == nil)
        #expect(stats.successRate == nil)
        #expect(stats.fraction == 0)
        #expect(!stats.isCapped)
    }

    // MARK: Client

    @Test("sends bearer header, path and query")
    func requestShape() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [(200, Self.results([Self.result()]))]
        let builds = try await client().finishedBuilds(planKey: "DMCUBE-DMCUB", maxResults: 100, since: .distantPast)
        #expect(builds.count == 1)

        let request = try #require(BambooStubProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(request.url?.path == "/rest/api/latest/result/DMCUBE-DMCUB.json")
        let query = request.url?.query ?? ""
        #expect(query.contains("expand=results.result"))
        #expect(query.contains("max-results=100"))
        #expect(query.contains("includeAllStates=false"))
        #expect(!(request.url?.absoluteString.contains(Self.token) ?? true))
    }

    @Test("branch request path and max-result")
    func branchRequestShape() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [(200, Self.branches([["key": "X-Y1"]]))]
        let keys = try await client().branchKeys(planKey: "DMCUBE-DMCUB")
        #expect(keys == ["X-Y1"])
        let url = try #require(BambooStubProtocol.recordedRequests.first?.url)
        #expect(url.path == "/rest/api/latest/plan/DMCUBE-DMCUB/branch.json")
        #expect(url.query?.contains("max-result=200") == true)
    }

    @Test("maps 401 to unauthorized, 500 to http, failure to transport")
    func errorMapping() async {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [(401, Data()), (500, Data())]
        do { _ = try await client().finishedBuilds(planKey: "A-B", maxResults: 1, since: .distantPast) }
        catch { #expect(error as? BambooError == .unauthorized) }
        do { _ = try await client().finishedBuilds(planKey: "A-B", maxResults: 1, since: .distantPast) }
        catch { #expect(error as? BambooError == .http(500)) }

        BambooStubProtocol.reset()
        BambooStubProtocol.failTransport = true
        do { _ = try await client().finishedBuilds(planKey: "A-B", maxResults: 1, since: .distantPast) }
        catch {
            #expect(error as? BambooError == .transport)
            #expect(!String(describing: error).contains(Self.token))
        }
    }

    @Test("branch with 404 is skipped, main plan and other branches stay")
    func branch404Skipped() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [
            (200, Self.results([Self.result()])),
            (200, Self.branches([["key": "A-B1"], ["key": "A-B2"]])),
            (404, Data()),
            (200, Self.results([Self.result(state: "Failed")])),
        ]
        let builds = try await client().builds(for: Self.plan, includeBranches: true, maxResultsPerKey: 100, since: .distantPast)
        #expect(builds.map(\.successful) == [true, false])
        #expect(BambooStubProtocol.recordedRequests.count == 4)
    }

    @Test("other branch errors abort")
    func branch500Aborts() async {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [
            (200, Self.results([])),
            (200, Self.branches([["key": "A-B1"]])),
            (500, Data()),
        ]
        do {
            _ = try await client().builds(for: Self.plan, includeBranches: true, maxResultsPerKey: 100, since: .distantPast)
            Issue.record("expected error")
        } catch {
            #expect(error as? BambooError == .http(500))
        }
    }

    @Test("without branches only the main plan is asked")
    func noBranches() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [(200, Self.results([Self.result()]))]
        _ = try await client().builds(for: Self.plan, includeBranches: false, maxResultsPerKey: 100, since: .distantPast)
        #expect(BambooStubProtocol.recordedRequests.count == 1)
    }

    private static func fullPage(_ count: Int, completed: String = "2026-11-13T02:41:12+01:00") -> Data {
        results(Array(repeating: result(extra: ["buildCompletedTime": completed]), count: count))
    }

    private func startIndexes() -> [String] {
        BambooStubProtocol.recordedRequests.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "start-index" }?.value ?? ""
        }
    }

    @Test("pages through full pages until a short one")
    func paginates() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [
            (200, Self.fullPage(50)), (200, Self.fullPage(50)), (200, Self.fullPage(10)),
        ]
        let since = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00+01:00")!
        let builds = try await client().finishedBuilds(planKey: "A-B", maxResults: 50, since: since)
        #expect(builds.count == 110)
        #expect(startIndexes() == ["0", "50", "100"])
    }

    @Test("stops when the oldest build of a page is before since")
    func stopsBeforeSince() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [
            (200, Self.fullPage(50)), (200, Self.fullPage(50, completed: "2026-10-01T02:41:12+01:00")),
            (200, Self.fullPage(50)),
        ]
        let since = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00+01:00")!
        _ = try await client().finishedBuilds(planKey: "A-B", maxResults: 50, since: since)
        #expect(startIndexes() == ["0", "50"])
    }

    @Test("page count is counted raw, not after status filter")
    func rawPageCount() async throws {
        BambooStubProtocol.reset()
        let mixed = Self.results(
            Array(repeating: Self.result(), count: 2) + [Self.result(life: "InProgress")])
        BambooStubProtocol.responses = [(200, mixed), (200, Self.results([]))]
        _ = try await client().finishedBuilds(planKey: "A-B", maxResults: 3, since: .distantPast)
        #expect(startIndexes() == ["0", "3"])
    }

    @Test("page limit of 10 ends paging")
    func pageLimit() async throws {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = Array(repeating: (200, Self.fullPage(5)), count: 15)
        _ = try await client().finishedBuilds(planKey: "A-B", maxResults: 5, since: .distantPast)
        #expect(BambooStubProtocol.recordedRequests.count == 10)
    }

    // MARK: Snapshot

    @Test("cancelled request is no transport error and ends the snapshot")
    func snapshotCancelled() async {
        BambooStubProtocol.reset()
        BambooStubProtocol.failTransport = true
        BambooStubProtocol.transportError = URLError(.cancelled)
        let snapshot = await BambooClient.snapshot(
            plans: [Self.plan, Self.extPlan], baseURL: Self.base,
            tokenSource: FixedBambooToken(value: Self.token), includeBranches: false,
            windowDays: 14, session: makeSession())
        #expect(snapshot.updatedAt == nil)
        #expect(snapshot.error == nil)
        #expect(snapshot.plans.allSatisfy { $0.error != BambooError.transport.description })
        #expect(BambooStubProtocol.recordedRequests.count == 1)
    }

    @Test("snapshot without token sends no request")
    func snapshotWithoutToken() async {
        BambooStubProtocol.reset()
        let snapshot = await BambooClient.snapshot(
            plans: BambooPlan.defaultPlans, baseURL: Self.base,
            tokenSource: FixedBambooToken(value: nil), includeBranches: true,
            windowDays: 14, session: makeSession())
        #expect(snapshot.error == BambooError.missingToken.description)
        #expect(snapshot.plans.count == 4)
        #expect(snapshot.plans.allSatisfy { $0.buildCount == 0 })
        #expect(BambooStubProtocol.recordedRequests.isEmpty)
    }

    @Test("snapshot keeps healthy plans when one fails")
    func snapshotPartialFailure() async {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [
            (200, Self.results([Self.result(extra: ["buildCompletedTime": "2026-11-13T02:41:12+01:00"])])),
            (500, Data()),
        ]
        let now = ISO8601DateFormatter().date(from: "2026-11-14T00:00:00+01:00")!
        let snapshot = await BambooClient.snapshot(
            plans: [Self.plan, Self.extPlan], baseURL: Self.base,
            tokenSource: FixedBambooToken(value: Self.token), includeBranches: false,
            windowDays: 14, now: { now }, session: makeSession())
        #expect(snapshot.plans[0].buildCount == 1)
        #expect(snapshot.plans[0].error == nil)
        #expect(snapshot.plans[1].error == BambooError.http(500).description)
        #expect(snapshot.error == nil)
        #expect(snapshot.updatedAt == now)
    }

    @Test("snapshot sets global error when every plan is unauthorized")
    func snapshotAllUnauthorized() async {
        BambooStubProtocol.reset()
        BambooStubProtocol.responses = [(401, Data()), (401, Data())]
        let snapshot = await BambooClient.snapshot(
            plans: [Self.plan, Self.extPlan], baseURL: Self.base,
            tokenSource: FixedBambooToken(value: Self.token), includeBranches: false,
            windowDays: 14, session: makeSession())
        #expect(snapshot.error == BambooError.unauthorized.description)
        #expect(snapshot.plans.allSatisfy { $0.error != nil })
    }

    // MARK: Modelle und AppConfig

    @Test("plan decoding is tolerant")
    func planDecoding() throws {
        let plan = try JSONDecoder().decode(BambooPlan.self, from: Data(#"{"key":"A-B"}"#.utf8))
        #expect(plan == BambooPlan(key: "A-B", name: "A-B", extended: false))
        #expect(plan.id == "A-B")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(BambooPlan.self, from: Data(#"{"name":"x"}"#.utf8))
        }
    }

    @Test("default plans")
    func defaultPlans() {
        #expect(BambooPlan.defaultPlans.map(\.key) ==
                ["DBREFI6-DBREF", "DBREFI6-REFIEXT", "DMCUBE-DMCUB", "DMCUBE-DMCF"])
        #expect(BambooPlan.defaultPlans.map(\.extended) == [false, true, false, true])
    }

    @Test("old config without bamboo fields decodes to defaults")
    func oldConfigDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"showClock":false}"#.utf8))
        #expect(config.showClock == false)
        #expect(config.showBamboo)
        #expect(config.bambooBaseURL == "http://bamboo.inxire.com")
        #expect(config.bambooPlans == BambooPlan.defaultPlans)
        #expect(config.bambooIncludeBranches)
        #expect(config.bambooWindowDays == 14)
        #expect(config.bambooRefreshMinutes == 60)
    }

    @Test("config with short plan entries")
    func configShortPlans() throws {
        let json = #"{"bambooPlans":[{"key":"X-Y"},{"key":"X-Z","name":"Z","extended":true}],"bambooWindowDays":7}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.bambooPlans.map(\.name) == ["X-Y", "Z"])
        #expect(config.bambooPlans.map(\.extended) == [false, true])
        #expect(config.bambooWindowDays == 7)
    }
}
