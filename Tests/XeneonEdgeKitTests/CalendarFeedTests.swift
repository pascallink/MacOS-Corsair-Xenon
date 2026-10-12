// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

/// Beantwortet jede Anfrage aus einer vorbereiteten Antwort, ohne je ein
/// echtes Netz zu beruehren. Der Zustand liegt auf der Klasse, weil
/// `URLSession` das Protokoll selbst instanziiert - deshalb ist die Suite
/// serialisiert (Muster: BitbucketStubProtocol).
private final class CalendarStubProtocol: URLProtocol {
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()
    static var recordedRequests: [URLRequest] = []

    static func reset() {
        status = 200
        headers = [:]
        body = Data()
        recordedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: Self.status,
                                        httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CalendarFeedTests {
    private static let secretURL = "https://calendar.google.com/calendar/ical/x%40group/private-abc/basic.ics"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarFeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func decode(_ json: String) throws -> CalendarConfig {
        try JSONDecoder().decode(CalendarConfig.self, from: Data(json.utf8))
    }

    // MARK: redact

    @Test func redactEntferntPfadQueryUndUserinfo() {
        #expect(CalendarFeedFetcher.redact(Self.secretURL) == "https://calendar.google.com")
        #expect(CalendarFeedFetcher.redact("https://user:pw@example.org:8443/a/b?token=zzz#frag")
                == "https://example.org")
    }

    @Test func redactUnparsbareEingabe() {
        #expect(CalendarFeedFetcher.redact("") == "<ungueltige URL>")
        #expect(CalendarFeedFetcher.redact("geheim-ohne-host") == "<ungueltige URL>")
    }

    // MARK: Config

    @Test func httpURLIstNichtKonfiguriert() throws {
        var config = CalendarConfig()
        config.enabled = true
        config.feedURL = "http://example.org/feed.ics"
        #expect(!config.isConfigured)
        config.feedURL = Self.secretURL
        #expect(config.isConfigured)
    }

    @Test func deaktiviertIstNichtKonfiguriert() {
        var config = CalendarConfig()
        config.feedURL = Self.secretURL
        config.enabled = false
        #expect(!config.isConfigured)
    }

    @Test func leereConfigDekodiertAufDefaults() throws {
        #expect(try decode("{}") == CalendarConfig())
    }

    @Test func einzelnerSchluesselBehaeltDefaults() throws {
        var expected = CalendarConfig()
        expected.enabled = true
        #expect(try decode(#"{"enabled": true}"#) == expected)
    }

    @Test func zahlenWerdenGeklemmt() throws {
        #expect(try decode(#"{"pollSeconds": 5}"#).pollSeconds == 60)
        #expect(try decode(#"{"pollSeconds": 99999}"#).pollSeconds == 3600)
        #expect(try decode(#"{"maxReminders": 9}"#).maxReminders == 4)
        #expect(try decode(#"{"maxReminders": 0}"#).maxReminders == 1)
        #expect(try decode(#"{"leadMinutes": 1}"#).leadMinutes == 5)
        #expect(try decode(#"{"graceMinutes": 99}"#).graceMinutes == 30)
    }

    @Test func feedURLWirdGetrimmt() throws {
        #expect(try decode(#"{"feedURL": "  https://a.example/x  "}"#).feedURL == "https://a.example/x")
    }

    @Test func saveSchreibtMitRechten0600UndLoadLiestZurueck() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/calendar.json")

        var config = CalendarConfig()
        config.enabled = true
        config.feedURL = Self.secretURL
        config.maxReminders = 3
        try config.save(to: file)

        #expect(try permissions(file) == 0o600)
        #expect(CalendarConfig.load(from: file) == config)
        // Keine Temp-Reste im Verzeichnis.
        let rest = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(rest == ["calendar.json"])
    }

    @Test func loadSetztRechteVon0644Auf0600() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("calendar.json")
        try Data(#"{"enabled": true}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try permissions(file) == 0o644)

        let config = CalendarConfig.load(from: file)
        #expect(config.enabled)
        #expect(try permissions(file) == 0o600)
    }

    @Test func loadOhneDateiGibtDefaultsUndSchreibtNichts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("calendar.json")
        #expect(CalendarConfig.load(from: file) == CalendarConfig())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func reminderOptionsUebernehmenFelder() {
        var config = CalendarConfig()
        config.leadMinutes = 30
        config.maxReminders = 3
        config.feedOwnerEmail = "a@b.de"
        let options = config.reminderOptions
        #expect(options.leadMinutes == 30)
        #expect(options.maxReminders == 3)
        #expect(options.feedOwnerEmail == "a@b.de")
    }

    // MARK: fetch

    @Test func fetch200LiefertSuccessMitETag() async {
        CalendarStubProtocol.reset()
        CalendarStubProtocol.headers = ["ETag": "\"v1\"", "Last-Modified": "Mon, 01 Jan 2026 00:00:00 GMT"]
        CalendarStubProtocol.body = Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)
        let result = await CalendarFeedFetcher.fetch(urlString: Self.secretURL, etag: nil,
                                                     lastModified: nil, session: makeSession())
        #expect(result == .success(text: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
                                   etag: "\"v1\"", lastModified: "Mon, 01 Jan 2026 00:00:00 GMT"))
    }

    @Test func fetch304LiefertNotModifiedUndSendetBedingungsHeader() async throws {
        CalendarStubProtocol.reset()
        CalendarStubProtocol.status = 304
        let result = await CalendarFeedFetcher.fetch(urlString: Self.secretURL, etag: "\"v1\"",
                                                     lastModified: "Mon", session: makeSession())
        #expect(result == .notModified)
        let request = try #require(CalendarStubProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Mon")
    }

    @Test func fetch500LiefertFailure() async {
        CalendarStubProtocol.reset()
        CalendarStubProtocol.status = 500
        let result = await CalendarFeedFetcher.fetch(urlString: Self.secretURL, etag: nil,
                                                     lastModified: nil, session: makeSession())
        #expect(result == .failure)
    }

    @Test func httpURLErzeugtKeinenRequest() async {
        CalendarStubProtocol.reset()
        let result = await CalendarFeedFetcher.fetch(urlString: "http://example.org/feed.ics", etag: nil,
                                                     lastModified: nil, session: makeSession())
        #expect(result == .failure)
        #expect(CalendarStubProtocol.recordedRequests.isEmpty)
    }

    @Test func fetchLatin1Rueckfall() async {
        CalendarStubProtocol.reset()
        CalendarStubProtocol.body = Data([0x53, 0x55, 0x4D, 0x3A, 0xE4])  // "SUM:" + ae in Latin-1
        let result = await CalendarFeedFetcher.fetch(urlString: Self.secretURL, etag: nil,
                                                     lastModified: nil, session: makeSession())
        #expect(result == .success(text: "SUM:\u{E4}", etag: nil, lastModified: nil))
    }
}
