// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Holt die Versionsringe per HTTP vom lokalen KI-Dashboard (ohne
// Authentifizierung, keine Tokens). Ein Cache-Miss im Backend kann einige
// zehn Sekunden dauern, daher 60 s Request-Timeout.

import Foundation

public enum KIVersionsError: Error, Equatable {
    case invalidURL
    case unreachable
    case http(Int, String?)
    case invalidResponse
}

public final class KIVersionsReader {
    public var baseURL: String
    public var projects: [String]
    private let session: URLSession

    public init(baseURL: String, projects: [String], session: URLSession? = nil) {
        self.baseURL = baseURL
        self.projects = projects
        self.session = session ?? KIVersionsReader.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }

    /// <base>/api/developers; toleriert abschliessenden Slash, nur http/https.
    public static func endpoint(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed + "/api/developers"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Ruft die Versionen ab. Die Completion kommt auf einer beliebigen Queue.
    public func fetch(completion: @escaping (Result<[KIVersionRing], KIVersionsError>) -> Void) {
        guard let url = KIVersionsReader.endpoint(base: baseURL) else {
            completion(.failure(.invalidURL))
            return
        }
        let projects = self.projects
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion(.failure(.unreachable))
                return
            }
            let body = data ?? Data()
            guard (200...299).contains(http.statusCode) else {
                completion(.failure(.http(http.statusCode, KIVersionsParser.errorMessage(from: body))))
                return
            }
            if let rings = KIVersionsParser.versions(from: body, projects: projects) {
                completion(.success(rings))
            } else {
                completion(.failure(.invalidResponse))
            }
        }.resume()
    }
}
