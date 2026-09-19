// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Networking for Bitbucket Data Center's dashboard pull-request endpoint —
// pagination and error mapping live here, JSON shape decoding stays in
// BitbucketResponseParser so both halves are testable independently.

import Foundation

/// Rolle, unter der die eigenen offenen Pull Requests abgefragt werden.
public enum BitbucketRole: String {
    case author = "AUTHOR"
    case reviewer = "REVIEWER"
}

/// Fehlerfaelle beim Abrufen der Pull-Request-Liste. Die Texte sind bewusst
/// knapp und enthalten weder Token noch vollstaendige URL - sie duerfen ohne
/// Nachbearbeitung in der UI landen.
public enum BitbucketError: Error, Equatable {
    case unauthorized
    case http(Int)
    case transport
}

extension BitbucketError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unauthorized:
            return "Anmeldung abgelehnt - Token pruefen"
        case .http(let status):
            return "Serverfehler (Status \(status))"
        case .transport:
            return "Server nicht erreichbar"
        }
    }
}

/// Holt die offenen Pull Requests einer Rolle vom Bitbucket-Data-Center-
/// Dashboard-Endpunkt und fuehrt alle Seiten zu einer Liste zusammen.
public struct BitbucketClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    /// Harter Deckel je Aufruf. Ein Server, der endlos `isLastPage: false`
    /// meldet, darf die Schleife nie unbegrenzt laufen lassen.
    private static let maxPages = 5

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Blaettert die Dashboard-Pull-Request-Liste fuer die angegebene Rolle
    /// durch und liefert alle Eintraege in Seitenreihenfolge. Bricht nach
    /// hoechstens `maxPages` Seiten ohne Fehler ab, auch wenn der Server
    /// weitere Seiten ankuendigt.
    public func openPullRequests(role: BitbucketRole) async throws -> [BitbucketPullRequest] {
        var results: [BitbucketPullRequest] = []
        var start: Int?

        for _ in 0..<Self.maxPages {
            guard let url = pageURL(role: role, start: start) else {
                throw BitbucketError.transport
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // Der zugrundeliegende Fehler koennte URL und Header tragen -
                // deshalb wird er weder mitgereicht noch protokolliert.
                throw BitbucketError.transport
            }

            guard let http = response as? HTTPURLResponse else {
                throw BitbucketError.transport
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                throw BitbucketError.unauthorized
            }
            guard http.statusCode == 200 else {
                throw BitbucketError.http(http.statusCode)
            }

            let page = BitbucketResponseParser.parsePage(data)
            results.append(contentsOf: page.values)

            guard page.isLastPage == false, let nextPageStart = page.nextPageStart else {
                break
            }
            start = nextPageStart
        }

        return results
    }

    /// Baut die URL fuer eine einzelne Seite. `start` bleibt fuer die erste
    /// Seite weg, ab der zweiten Seite traegt die Query `start=<n>`.
    private func pageURL(role: BitbucketRole, start: Int?) -> URL? {
        let endpoint = baseURL.appendingPathComponent("rest/api/1.0/dashboard/pull-requests")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var items = [
            URLQueryItem(name: "state", value: "OPEN"),
            URLQueryItem(name: "role", value: role.rawValue),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if let start {
            items.append(URLQueryItem(name: "start", value: String(start)))
        }
        components.queryItems = items

        return components.url
    }
}
