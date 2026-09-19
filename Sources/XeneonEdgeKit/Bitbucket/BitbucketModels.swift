// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure data models and glob matching for Bitbucket Data Center pull requests
// — deliberately free of URLSession, IOKit and AppKit so target-pattern
// matching is testable without a network round trip.

import Foundation

/// Ein einzelner Pull Request aus Bitbucket Data Center, reduziert auf die
/// Felder, die das Widget zur Anzeige und Filterung braucht.
public struct BitbucketPullRequest: Equatable {
    public let id: Int
    public let title: String
    public let projectKey: String
    public let repoSlug: String
    public let targetBranch: String
    public let authorName: String
    public let reviewers: [BitbucketReviewer]
    /// Anzahl offener Tasks. `nil`, wenn die Antwort keine Zahl liefert -
    /// das ist ausdruecklich nicht dasselbe wie "0" und wird als "-"
    /// dargestellt, nie als "0".
    public let openTaskCount: Int?
    public let url: String
    public let updatedAt: Date?

    public init(id: Int, title: String, projectKey: String, repoSlug: String,
                targetBranch: String, authorName: String,
                reviewers: [BitbucketReviewer], openTaskCount: Int?,
                url: String, updatedAt: Date?) {
        self.id = id
        self.title = title
        self.projectKey = projectKey
        self.repoSlug = repoSlug
        self.targetBranch = targetBranch
        self.authorName = authorName
        self.reviewers = reviewers
        self.openTaskCount = openTaskCount
        self.url = url
        self.updatedAt = updatedAt
    }
}

/// Ein Reviewer-Eintrag eines Pull Requests mit seinem Freigabestatus.
public struct BitbucketReviewer: Equatable {
    public let name: String
    public let status: BitbucketReviewerStatus

    public init(name: String, status: BitbucketReviewerStatus) {
        self.name = name
        self.status = status
    }
}

/// Freigabestatus eines Reviewers, wie Bitbucket ihn in der REST-Antwort
/// benennt.
public enum BitbucketReviewerStatus: String {
    case approved = "APPROVED"
    case unapproved = "UNAPPROVED"
    case needsWork = "NEEDS_WORK"
}

/// Zielmuster fuer Pull Requests, z. B. `refi/develop*`, `refi/app/develop*`
/// oder `refi/app/release/1.2`. Zwei Segmente lassen das Repo offen, ab drei
/// Segmenten schraenkt das zweite Segment das Repo ein und alle Segmente ab
/// dem dritten bilden - mit `/` wieder zusammengefuegt - den Ziel-Branch, der
/// damit selbst Slashes tragen darf (`release/1.2`). Ein projektweites
/// Slash-Ziel muss das Repo deshalb ausdruecklich als `*` ausschreiben
/// (`refi/*/release/1.*`), sonst liest `parse()` drei Segmente als Projekt,
/// Repo und Branch - das ist die einzige eindeutige Lesart. Jedes Segment
/// darf `*` als Platzhalter fuer beliebig viele Zeichen (auch keines)
/// enthalten, aber niemals fuer einen Slash.
public struct BitbucketTargetPattern: Equatable {
    private let projectPattern: String
    private let repoPattern: String?
    private let targetBranchPattern: String

    private init(projectPattern: String, repoPattern: String?, targetBranchPattern: String) {
        self.projectPattern = projectPattern
        self.repoPattern = repoPattern
        self.targetBranchPattern = targetBranchPattern
    }

    /// Parst ein Muster der Form `<projekt>/<ziel-branch>` oder
    /// `<projekt>/<repo>/<ziel-branch>`, wobei der Ziel-Branch ab drei
    /// Segmenten selbst Slashes enthalten darf. Ein fuehrender Slash wird
    /// geschluckt, danach wird jedes an `/` aufgeteilte Segment einzeln um
    /// umschliessende Leerzeichen zugeschnitten. Bei genau zwei Segmenten
    /// bildet das erste das Projekt und das zweite den Ziel-Branch, das Repo
    /// bleibt offen. Ab drei Segmenten bildet das erste das Projekt, das
    /// zweite das Repo, und alle Segmente ab dem dritten werden mit `/`
    /// wieder zusammengefuegt und ergeben den Ziel-Branch - eine Obergrenze
    /// fuer die Segmentzahl gibt es nicht. Liefert `nil` bei leerem Muster,
    /// nach dem Zuschneiden leeren Segmenten oder weniger als zwei
    /// Segmenten - stuerzt niemals ab.
    public static func parse(_ raw: String) -> BitbucketTargetPattern? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        let segments = trimmed.components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard segments.count >= 2 else { return nil }
        guard segments.allSatisfy({ !$0.isEmpty }) else { return nil }

        if segments.count == 2 {
            return BitbucketTargetPattern(projectPattern: segments[0],
                                          repoPattern: nil,
                                          targetBranchPattern: segments[1])
        }
        let targetBranchPattern = segments[2...].joined(separator: "/")
        return BitbucketTargetPattern(projectPattern: segments[0],
                                      repoPattern: segments[1],
                                      targetBranchPattern: targetBranchPattern)
    }

    /// Prueft, ob der Pull Request auf dieses Muster passt. Projekt und
    /// Repo werden case-insensitiv verglichen, der Ziel-Branch
    /// case-sensitiv.
    public func matches(_ pr: BitbucketPullRequest) -> Bool {
        guard Self.globMatches(pattern: projectPattern.lowercased(),
                               value: pr.projectKey.lowercased()) else {
            return false
        }
        if let repoPattern {
            guard Self.globMatches(pattern: repoPattern.lowercased(),
                                   value: pr.repoSlug.lowercased()) else {
                return false
            }
        }
        return Self.globMatches(pattern: targetBranchPattern, value: pr.targetBranch)
    }

    /// Eigene Glob-Implementierung ohne `NSRegularExpression`/`NSPredicate`:
    /// zerlegt das Muster am `*` und prueft Praefix, Suffix und die
    /// dazwischenliegenden Teile der Reihe nach. `*` steht fuer beliebig
    /// viele Zeichen, aber nie fuer einen Slash - jede von `*` konsumierte
    /// Spanne wird deshalb zusaetzlich auf ein `/` geprueft.
    private static func globMatches(pattern: String, value: String) -> Bool {
        guard pattern.contains("*") else {
            return pattern == value
        }

        let parts = pattern.components(separatedBy: "*").map { Array($0) }
        let valueChars = Array(value)
        var cursor = 0

        for (index, part) in parts.enumerated() {
            let isFirst = index == 0
            let isLast = index == parts.count - 1

            if isFirst {
                guard valueChars.count >= part.count,
                      Array(valueChars[0..<part.count]) == part else { return false }
                cursor = part.count
                continue
            }

            if isLast {
                guard valueChars.count - cursor >= part.count else { return false }
                let tailStart = valueChars.count - part.count
                guard tailStart >= cursor,
                      Array(valueChars[tailStart...]) == part else { return false }
                let wildcardSpan = valueChars[cursor..<tailStart]
                guard !wildcardSpan.contains("/") else { return false }
                cursor = valueChars.count
                continue
            }

            if part.isEmpty { continue }
            guard let foundStart = findSubsequenceStart(part, in: valueChars, from: cursor) else {
                return false
            }
            let wildcardSpan = valueChars[cursor..<foundStart]
            guard !wildcardSpan.contains("/") else { return false }
            cursor = foundStart + part.count
        }
        return true
    }

    /// Sucht die erste Position von `needle` in `haystack` ab Index `from`
    /// und liefert den Startindex des Treffers, oder `nil` wenn nichts
    /// passt.
    private static func findSubsequenceStart(_ needle: [Character], in haystack: [Character],
                                              from: Int) -> Int? {
        guard haystack.count - from >= needle.count else { return nil }

        var start = from
        while start + needle.count <= haystack.count {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start
            }
            start += 1
        }
        return nil
    }
}
