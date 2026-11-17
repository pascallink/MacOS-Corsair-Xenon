// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Netzwerk fuer die Bamboo-REST-API - Fehlerabbildung und Abruf liegen hier,
// das Lesen der JSON-Form in BambooResponseParser.
//
// Hinweis: Bamboo ist intern nur per http erreichbar. Der Token geht wie beim
// KI-Dashboard als Bearer-Header unverschluesselt ueber das interne Netz.

import Foundation

/// Fehlerfaelle beim Abruf. Die Texte sind knapp und tragen weder Token noch
/// URL - sie duerfen unveraendert in der UI landen.
public enum BambooError: Error, Equatable, CustomStringConvertible {
    case missingToken
    case unauthorized
    case http(Int)
    case transport

    public var description: String {
        switch self {
        case .missingToken:
            return "kein Bamboo-Token in der Keychain"
        case .unauthorized:
            return "Anmeldung abgelehnt - Token pruefen"
        case .http(let status):
            return "Serverfehler (Status \(status))"
        case .transport:
            return "Server nicht erreichbar"
        }
    }
}

extension BambooError: LocalizedError {
    public var errorDescription: String? { description }
}

public struct BambooClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    /// Hoechstzahl Branches je Plan, die abgefragt werden.
    private static let maxBranches = 200

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Keys der aktiven Branch-Plaene eines Plans (hoechstens 200).
    public func branchKeys(planKey: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent("rest/api/latest/plan")
            .appendingPathComponent(planKey)
            .appendingPathComponent("branch.json")
        let data = try await fetch(url, query: [
            URLQueryItem(name: "max-result", value: String(Self.maxBranches)),
        ])
        return BambooResponseParser.parseBranchKeys(data)
    }

    /// Fertige Builds (nur Finished, Successful/Failed) eines Plan-Keys.
    public func finishedBuilds(planKey: String, maxResults: Int) async throws -> [BambooBuild] {
        let url = baseURL.appendingPathComponent("rest/api/latest/result")
            .appendingPathComponent(planKey + ".json")
        let data = try await fetch(url, query: [
            URLQueryItem(name: "expand", value: "results.result"),
            URLQueryItem(name: "max-results", value: String(maxResults)),
            URLQueryItem(name: "includeAllStates", value: "false"),
        ])
        return BambooResponseParser.parseResults(data)
    }

    /// Builds des Hauptplans, bei `includeBranches` zusaetzlich die jedes
    /// Branch-Plans. Branches werden nacheinander abgefragt; ein Branch mit
    /// 404 (inzwischen geloescht) wird uebersprungen, jeder andere Fehler
    /// bricht ab.
    public func builds(for plan: BambooPlan, includeBranches: Bool,
                       maxResultsPerKey: Int) async throws -> [BambooBuild] {
        var all = try await finishedBuilds(planKey: plan.key, maxResults: maxResultsPerKey)
        guard includeBranches else { return all }

        let keys = try await branchKeys(planKey: plan.key).prefix(Self.maxBranches)
        for key in keys {
            do {
                all += try await finishedBuilds(planKey: key, maxResults: maxResultsPerKey)
            } catch BambooError.http(404) {
                continue
            }
        }
        return all
    }

    /// Holt alle Plaene und wertet sie aus. Ein fehlgeschlagener Plan bekommt
    /// seinen eigenen `error`, die anderen bleiben. Ohne Token: Snapshot mit
    /// globalem Fehler, ohne dass eine Anfrage gesendet wird.
    public static func snapshot(plans: [BambooPlan], baseURL: URL,
                                tokenSource: BambooTokenSource, includeBranches: Bool,
                                windowDays: Int, now: () -> Date = Date.init,
                                session: URLSession = .shared) async -> BambooSnapshot {
        let start = now()
        guard let host = baseURL.host,
              let token = tokenSource.token(forHost: host), !token.isEmpty else {
            let empty = plans.map {
                BambooStatistics.evaluate(plan: $0, builds: [], now: start, windowDays: windowDays)
            }
            return BambooSnapshot(plans: empty, updatedAt: nil,
                                  error: BambooError.missingToken.description)
        }

        let client = BambooClient(baseURL: baseURL, token: token, session: session)
        var stats: [BambooPlanStats] = []
        var unauthorizedCount = 0

        for plan in plans {
            do {
                let builds = try await client.builds(for: plan, includeBranches: includeBranches,
                                                     maxResultsPerKey: 100)
                stats.append(BambooStatistics.evaluate(plan: plan, builds: builds,
                                                       now: now(), windowDays: windowDays))
            } catch {
                let bambooError = (error as? BambooError) ?? .transport
                if bambooError == .unauthorized { unauthorizedCount += 1 }
                var failed = BambooStatistics.evaluate(plan: plan, builds: [], now: now(),
                                                       windowDays: windowDays)
                failed.error = bambooError.description
                stats.append(failed)
            }
        }

        let globalError = (!plans.isEmpty && unauthorizedCount == plans.count)
            ? BambooError.unauthorized.description : nil
        return BambooSnapshot(plans: stats, updatedAt: now(), error: globalError)
    }

    private func fetch(_ endpoint: URL, query: [URLQueryItem]) async throws -> Data {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw BambooError.transport
        }
        components.queryItems = query
        guard let url = components.url else { throw BambooError.transport }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Der Fehler koennte URL und Header tragen - nie mitreichen oder loggen.
            throw BambooError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw BambooError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw BambooError.unauthorized }
        guard http.statusCode == 200 else { throw BambooError.http(http.statusCode) }
        return data
    }
}
