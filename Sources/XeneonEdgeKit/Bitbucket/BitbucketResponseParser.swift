// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure JSON parsing for Bitbucket Data Center's paginated pull-request list
// endpoint — deliberately free of any networking or device framework so the
// mapping is testable against canned response bodies without a network
// round trip or a live device.

import Foundation

/// Eine Seite der Pull-Request-Liste, wie sie
/// `GET /rest/api/1.0/dashboard/pull-requests` liefert.
public struct BitbucketPage: Equatable {
    public let values: [BitbucketPullRequest]
    public let isLastPage: Bool
    public let nextPageStart: Int?

    public init(values: [BitbucketPullRequest], isLastPage: Bool, nextPageStart: Int?) {
        self.values = values
        self.isLastPage = isLastPage
        self.nextPageStart = nextPageStart
    }
}

/// Uebersetzt eine rohe JSON-Antwortseite von Bitbucket Data Center in
/// `BitbucketPage`-Werte.
public enum BitbucketResponseParser {
    /// Parst eine rohe `GET /rest/api/1.0/dashboard/pull-requests`-Antwort.
    /// Pure und synchron, kein Netzwerkzugriff. Wirft nie: kaputtes oder
    /// nicht als Objekt lesbares JSON ergibt eine leere Seite mit
    /// `isLastPage: true`, damit eine Paginierungsschleife auf Muell
    /// abbricht statt endlos weiterzublaettern. Ein einzelner Eintrag ohne
    /// die Pflichtfelder wird ausgelassen, ohne die uebrigen Eintraege der
    /// Seite zu verwerfen.
    public static func parsePage(_ data: Data) -> BitbucketPage {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BitbucketPage(values: [], isLastPage: true, nextPageStart: nil)
        }

        let rawValues = json["values"] as? [Any] ?? []
        let values = rawValues.compactMap { entry -> BitbucketPullRequest? in
            guard let object = entry as? [String: Any] else { return nil }
            return parsePullRequest(object)
        }

        let isLastPage = json["isLastPage"] as? Bool ?? true
        let nextPageStart = json["nextPageStart"] as? Int

        return BitbucketPage(values: values, isLastPage: isLastPage, nextPageStart: nextPageStart)
    }

    /// Uebersetzt einen einzelnen Eintrag aus `values`. Liefert `nil`, wenn
    /// eines der Pflichtfelder fehlt oder den falschen Typ hat.
    private static func parsePullRequest(_ raw: [String: Any]) -> BitbucketPullRequest? {
        guard let id = raw["id"] as? Int,
              let toRef = raw["toRef"] as? [String: Any],
              let displayId = toRef["displayId"] as? String,
              let repository = toRef["repository"] as? [String: Any],
              let repoSlug = repository["slug"] as? String,
              let project = repository["project"] as? [String: Any],
              let projectKey = project["key"] as? String,
              let author = raw["author"] as? [String: Any],
              let authorUser = author["user"] as? [String: Any],
              let authorName = authorUser["name"] as? String
        else { return nil }

        let title = (raw["title"] as? String) ?? ""

        var targetBranch = displayId
        let branchPrefix = "refs/heads/"
        if targetBranch.hasPrefix(branchPrefix) {
            targetBranch.removeFirst(branchPrefix.count)
        }

        let reviewers = parseReviewers(raw["reviewers"] as? [Any] ?? [])
        let openTaskCount = (raw["properties"] as? [String: Any])?["openTaskCount"] as? Int
        let url = parseSelfLink(raw["links"] as? [String: Any])
        let updatedAt = parseUpdatedDate(raw["updatedDate"])

        return BitbucketPullRequest(id: id, title: title, projectKey: projectKey,
                                     repoSlug: repoSlug, targetBranch: targetBranch,
                                     authorName: authorName, reviewers: reviewers,
                                     openTaskCount: openTaskCount, url: url, updatedAt: updatedAt)
    }

    /// Uebersetzt die Reviewer-Liste. Ein Eintrag ohne `user.name` oder ohne
    /// die Objektform wird ausgelassen, ohne den ganzen Pull Request zu
    /// verwerfen.
    private static func parseReviewers(_ raw: [Any]) -> [BitbucketReviewer] {
        raw.compactMap { rawEntry in
            guard let entry = rawEntry as? [String: Any],
                  let user = entry["user"] as? [String: Any],
                  let name = user["name"] as? String
            else { return nil }

            if let rawStatus = entry["status"] as? String,
               let status = BitbucketReviewerStatus(rawValue: rawStatus) {
                return BitbucketReviewer(name: name, status: status)
            }
            let approved = entry["approved"] as? Bool ?? false
            return BitbucketReviewer(name: name, status: approved ? .approved : .unapproved)
        }
    }

    /// Uebersetzt `updatedDate` (Millisekunden seit 1970) in ein `Date`.
    /// JSONSerialization liefert jede Zahl als `NSNumber`, deshalb glueckt
    /// der `Double`-Zweig auch bei ganzen Zahlen. Der `Int`-Zweig bleibt nur
    /// als Auffang fuer Werte, die sich nicht exakt als `Double` darstellen
    /// lassen.
    private static func parseUpdatedDate(_ raw: Any?) -> Date? {
        if let millis = raw as? Double {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        if let millis = raw as? Int {
            return Date(timeIntervalSince1970: Double(millis) / 1000)
        }
        return nil
    }

    /// Liest die URL aus dem ersten passenden Eintrag von `links.self`.
    /// Ein Nicht-Objekt vor einem gueltigen Eintrag wird uebersprungen statt
    /// die Suche abzubrechen. Fehlt ein gueltiger Eintrag ganz, wird der
    /// leere String geliefert - das verwirft den Pull Request nicht.
    private static func parseSelfLink(_ links: [String: Any]?) -> String {
        let selfLinks = links?["self"] as? [Any] ?? []
        for rawEntry in selfLinks {
            if let entry = rawEntry as? [String: Any],
               let href = entry["href"] as? String {
                return href
            }
        }
        return ""
    }
}
