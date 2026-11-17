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

    /// Hoechstzahl Seiten je Plan-Key beim Blaettern.
    private static let maxPages = 10

    /// Laufzeitdeckel: Sind je Plan (Hauptplan, Branch-Liste und alle Seiten)
    /// schon so viele Anfragen gestellt, werden keine weiteren Branches mehr
    /// abgefragt; es zaehlt, was bis dahin gesammelt wurde.
    private static let maxRequestsPerPlan = 400

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

    /// Fertige Builds (nur Finished, Successful/Failed) eines Plan-Keys seit
    /// `since`. Blaettert mit `start-index` in Seiten zu `maxResults`.
    public func finishedBuilds(planKey: String, maxResults: Int,
                               since: Date) async throws -> [BambooBuild] {
        var requests = 0
        return try await finishedBuilds(planKey: planKey, maxResults: maxResults,
                                        since: since, requests: &requests)
    }

    /// Wie oben; `requests` zaehlt die gestellten Anfragen mit (auch bei Fehlern).
    private func finishedBuilds(planKey: String, maxResults: Int, since: Date,
                                requests: inout Int) async throws -> [BambooBuild] {
        let url = baseURL.appendingPathComponent("rest/api/latest/result")
            .appendingPathComponent(planKey + ".json")
        let pageSize = max(maxResults, 1)
        var all: [BambooBuild] = []

        for page in 0..<Self.maxPages {
            requests += 1
            let data = try await fetch(url, query: [
                URLQueryItem(name: "expand", value: "results.result"),
                URLQueryItem(name: "max-results", value: String(pageSize)),
                URLQueryItem(name: "start-index", value: String(page * pageSize)),
                URLQueryItem(name: "includeAllStates", value: "false"),
            ])
            let parsed = BambooResponseParser.parseResults(data)
            all += parsed

            // Der Parser filtert nach Status, "Seite voll" zaehlt daher roh.
            let rawCount = Self.rawResultCount(data)
            if rawCount < pageSize { break }
            if let oldest = parsed.map(\.completedAt).min(), oldest < since { break }
        }
        return all
    }

    /// Anzahl der Eintraege in `results.result`, ungefiltert.
    private static func rawResultCount(_ data: Data) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let entries = results["result"] as? [Any] else { return 0 }
        return entries.count
    }

    /// Builds des Hauptplans seit `since`, bei `includeBranches` zusaetzlich die
    /// jedes Branch-Plans. Branches werden nacheinander abgefragt; ein Branch
    /// mit 404 (inzwischen geloescht) wird uebersprungen, jeder andere Fehler
    /// bricht ab. Ist das Anfragebudget je Plan erreicht, werden keine weiteren
    /// Branches abgefragt.
    public func builds(for plan: BambooPlan, includeBranches: Bool,
                       maxResultsPerKey: Int, since: Date) async throws -> [BambooBuild] {
        var requests = 0
        var all = try await finishedBuilds(planKey: plan.key, maxResults: maxResultsPerKey,
                                           since: since, requests: &requests)
        guard includeBranches else { return all }

        requests += 1
        let keys = try await branchKeys(planKey: plan.key).prefix(Self.maxBranches)
        for key in keys {
            guard requests < Self.maxRequestsPerPlan else { break }
            do {
                all += try await finishedBuilds(planKey: key, maxResults: maxResultsPerKey,
                                                since: since, requests: &requests)
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
        let since = start.addingTimeInterval(-Double(max(windowDays, 1)) * 86400)
        var stats: [BambooPlanStats] = []
        var unauthorizedCount = 0

        for plan in plans {
            // Abbruch: bisher Gesammeltes zurueck, ohne Zeitstempel und Fehler.
            if Task.isCancelled {
                return BambooSnapshot(plans: stats, updatedAt: nil, error: nil)
            }
            do {
                let builds = try await client.builds(for: plan, includeBranches: includeBranches,
                                                     maxResultsPerKey: 50, since: since)
                stats.append(BambooStatistics.evaluate(plan: plan, builds: builds,
                                                       now: now(), windowDays: windowDays))
            } catch is CancellationError {
                return BambooSnapshot(plans: stats, updatedAt: nil, error: nil)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
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
