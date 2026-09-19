// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

/// Zeichnet jede Anfrage auf und beantwortet sie der Reihe nach aus einer
/// vorbereiteten Liste, ohne je ein echtes Netz zu beruehren. Der Zustand
/// liegt zwangslaeufig auf der Klasse, weil `URLProtocol` von `URLSession`
/// selbst instanziiert wird - deshalb laeuft die Suite serialisiert.
private final class BitbucketStubProtocol: URLProtocol {
    static var responses: [(status: Int, body: Data)] = []
    static var responseIndex = 0
    static var recordedRequests: [URLRequest] = []
    static var failTransport = false

    static func reset() {
        responses = []
        responseIndex = 0
        recordedRequests = []
        failTransport = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)

        if Self.failTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
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

@Suite(.serialized) struct BitbucketClientTests {
    private static let token = "test-token"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BitbucketStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Baut ein minimal gueltiges Pull-Request-Objekt, wie es
    /// `BitbucketResponseParser` erwartet.
    private static func prJSON(id: Int) -> [String: Any] {
        [
            "id": id,
            "title": "PR \(id)",
            "toRef": [
                "displayId": "refs/heads/develop",
                "repository": [
                    "slug": "app",
                    "project": ["key": "REFI"],
                ],
            ],
            "author": ["user": ["name": "alice"]],
        ]
    }

    private static func pageBody(values: [[String: Any]], isLastPage: Bool,
                                  nextPageStart: Int? = nil) -> Data {
        var json: [String: Any] = ["values": values, "isLastPage": isLastPage]
        if let nextPageStart {
            json["nextPageStart"] = nextPageStart
        }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("combines paginated pull requests and threads the start parameter")
    func combinesPages() async throws {
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [
            (200, Self.pageBody(values: [Self.prJSON(id: 1)], isLastPage: false, nextPageStart: 50)),
            (200, Self.pageBody(values: [Self.prJSON(id: 2)], isLastPage: true)),
        ]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: Self.token, session: makeSession())
        let prs = try await client.openPullRequests(role: .author)

        #expect(prs.map(\.id) == [1, 2])
        #expect(BitbucketStubProtocol.recordedRequests.count == 2)

        let firstQuery = BitbucketStubProtocol.recordedRequests[0].url?.query ?? ""
        let secondQuery = BitbucketStubProtocol.recordedRequests[1].url?.query ?? ""
        #expect(!firstQuery.contains("start="))
        #expect(secondQuery.contains("start=50"))
    }

    @Test("sends the bearer token header without exposing it in the url")
    func sendsAuthorizationHeader() async throws {
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [
            (200, Self.pageBody(values: [Self.prJSON(id: 1)], isLastPage: true)),
        ]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: Self.token, session: makeSession())
        _ = try await client.openPullRequests(role: .reviewer)

        let request = try #require(BitbucketStubProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(!(request.url?.absoluteString.contains(Self.token) ?? true))
    }

    @Test("maps status 401 to unauthorized")
    func mapsUnauthorized() async throws {
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [(401, Data())]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: Self.token, session: makeSession())

        do {
            _ = try await client.openPullRequests(role: .author)
            Issue.record("expected BitbucketError.unauthorized to be thrown")
        } catch let error as BitbucketError {
            #expect(error == .unauthorized)
        }
    }

    @Test("maps status 500 to http error")
    func mapsHTTPError() async throws {
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [(500, Data())]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: Self.token, session: makeSession())

        do {
            _ = try await client.openPullRequests(role: .author)
            Issue.record("expected BitbucketError.http(500) to be thrown")
        } catch let error as BitbucketError {
            #expect(error == .http(500))
        }
    }

    @Test("stops after five pages without throwing")
    func stopsAtPageCap() async throws {
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = (0..<10).map { index in
            (200, Self.pageBody(values: [Self.prJSON(id: index)], isLastPage: false,
                                 nextPageStart: (index + 1) * 50))
        }

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: Self.token, session: makeSession())
        let prs = try await client.openPullRequests(role: .author)

        #expect(BitbucketStubProtocol.recordedRequests.count == 5)
        #expect(prs.count == 5)
    }

    @Test("unauthorized error never leaks the token")
    func unauthorizedDoesNotLeakToken() async throws {
        let secretToken = "geheim-token-12345"
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [(401, Data())]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: secretToken, session: makeSession())

        do {
            _ = try await client.openPullRequests(role: .author)
            Issue.record("expected BitbucketError.unauthorized to be thrown")
        } catch {
            #expect(!String(describing: error).contains(secretToken))
            #expect(!error.localizedDescription.contains(secretToken))
            if let bitbucketError = error as? BitbucketError {
                #expect(!bitbucketError.description.contains(secretToken))
            } else {
                Issue.record("expected a BitbucketError, got \(type(of: error))")
            }
        }
    }

    @Test("http error never leaks the token")
    func httpErrorDoesNotLeakToken() async throws {
        let secretToken = "geheim-token-12345"
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [(500, Data())]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: secretToken, session: makeSession())

        do {
            _ = try await client.openPullRequests(role: .author)
            Issue.record("expected BitbucketError.http to be thrown")
        } catch {
            #expect(!String(describing: error).contains(secretToken))
            #expect(!error.localizedDescription.contains(secretToken))
            if let bitbucketError = error as? BitbucketError {
                #expect(!bitbucketError.description.contains(secretToken))
            } else {
                Issue.record("expected a BitbucketError, got \(type(of: error))")
            }
        }
    }

    @Test("transport error never leaks the token")
    func transportErrorDoesNotLeakToken() async throws {
        let secretToken = "geheim-token-12345"
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.failTransport = true

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: secretToken, session: makeSession())

        do {
            _ = try await client.openPullRequests(role: .author)
            Issue.record("expected BitbucketError.transport to be thrown")
        } catch {
            #expect(!String(describing: error).contains(secretToken))
            #expect(!error.localizedDescription.contains(secretToken))
            if let bitbucketError = error as? BitbucketError {
                #expect(!bitbucketError.description.contains(secretToken))
                #expect(bitbucketError == .transport)
            } else {
                Issue.record("expected a BitbucketError, got \(type(of: error))")
            }
        }
    }

    @Test("localized descriptions match the mapped error text")
    func localizedDescriptionsMatchMappedText() {
        #expect((BitbucketError.unauthorized as Error).localizedDescription
            == "Anmeldung abgelehnt - Token pruefen")
        #expect((BitbucketError.http(500) as Error).localizedDescription
            == "Serverfehler (Status 500)")
        #expect((BitbucketError.transport as Error).localizedDescription
            == "Server nicht erreichbar")
    }

    @Test("stops paginating when the server repeats a non-advancing nextPageStart")
    func stopsOnStaleNextPageStart() async throws {
        BitbucketStubProtocol.reset()
        BitbucketStubProtocol.responses = [
            (200, Self.pageBody(values: [Self.prJSON(id: 1)], isLastPage: false, nextPageStart: 0)),
            (200, Self.pageBody(values: [Self.prJSON(id: 2)], isLastPage: true)),
        ]

        let client = BitbucketClient(baseURL: URL(string: "https://bitbucket.example.com")!,
                                      token: Self.token, session: makeSession())
        let prs = try await client.openPullRequests(role: .author)

        #expect(BitbucketStubProtocol.recordedRequests.count == 1)
        #expect(prs.count == 1)
    }

    /// Testdouble fuer `BitbucketTokenSource`, ohne die echte Keychain
    /// anzufassen.
    private struct FixedTokenSource: BitbucketTokenSource {
        let value: String?

        func token(forHost host: String) -> String? { value }
    }

    @Test("BitbucketTokenSource protocol is usable via a test double")
    func tokenSourceProtocolIsUsable() {
        let source: BitbucketTokenSource = FixedTokenSource(value: "double-token")
        #expect(source.token(forHost: "bitbucket.example.com") == "double-token")

        let empty: BitbucketTokenSource = FixedTokenSource(value: nil)
        #expect(empty.token(forHost: "bitbucket.example.com") == nil)
    }
}
