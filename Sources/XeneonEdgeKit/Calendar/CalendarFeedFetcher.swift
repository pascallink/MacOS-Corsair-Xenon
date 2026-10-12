// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Abruf des ICS-Feeds. Die Feed-URL ist geheim: Jede Log- und Fehlermeldung
// geht ueber `redact`, Fehlerobjekte (URLError, error) werden nie
// interpoliert, weil sie die volle URL tragen (NSErrorFailingURLStringKey).

import Foundation

public enum CalendarFeedFetcher {
    public enum FeedResult: Equatable, Sendable {
        case notModified
        case success(text: String, etag: String?, lastModified: String?)
        case failure
    }

    /// Obergrenze der Antwortgroesse.
    static let maxBytes = 20 * 1024 * 1024

    /// Eigene Session ohne Cache: die Standard-Session legt Antwort und URL
    /// sonst in Cache.db auf der Platte ab.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Hoechstens "scheme://host", nie Pfad, Query, Fragment, Port oder
    /// Userinfo. Unparsbar oder ohne Host ergibt eine Konstante.
    public static func redact(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(), !scheme.isEmpty,
              let host = parsed.host, !host.isEmpty
        else { return "<ungueltige URL>" }
        return "\(scheme)://\(host)"
    }

    /// Gemeinsame Pruefung fuer `isConfigured` und `fetch`: https und Host.
    static func httpsURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Kein `throw` nach aussen, gleiche Haltung wie CloudUsageFetcher.fetch.
    public static func fetch(
        urlString: String,
        etag: String?,
        lastModified: String?,
        session: URLSession = CalendarFeedFetcher.session
    ) async -> FeedResult {
        guard let url = httpsURL(from: urlString) else {
            NSLog("XeneonEdge: Kalender-Feed abgelehnt (kein https): %@", redact(urlString))
            return .failure
        }
        let shown = redact(urlString)

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure }
            if let final = http.url, final.scheme?.lowercased() != "https" {
                NSLog("XeneonEdge: Kalender-Feed leitet auf Nicht-https um: %@", shown)
                return .failure
            }
            if http.statusCode == 304 { return .notModified }
            guard http.statusCode == 200 else {
                NSLog("XeneonEdge: Kalender-Feed %@ HTTP %d", shown, http.statusCode)
                return .failure
            }
            if http.expectedContentLength > Int64(maxBytes) {
                NSLog("XeneonEdge: Kalender-Feed %@ zu gross", shown)
                return .failure
            }

            var data = Data()
            var buffer = [UInt8]()
            buffer.reserveCapacity(16 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 16 * 1024 {
                    data.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if data.count + buffer.count > maxBytes {
                    NSLog("XeneonEdge: Kalender-Feed %@ zu gross", shown)
                    return .failure
                }
            }
            data.append(contentsOf: buffer)

            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            guard let text else { return .failure }
            return .success(
                text: text,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        } catch let urlError as URLError {
            NSLog("XeneonEdge: Kalender-Feed %@ Fehlercode %d", shown, urlError.code.rawValue)
            return .failure
        } catch {
            NSLog("XeneonEdge: Kalender-Feed %@ fehlgeschlagen", shown)
            return .failure
        }
    }
}
