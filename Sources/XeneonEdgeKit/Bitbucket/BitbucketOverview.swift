// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure aggregation rules for Bitbucket pull requests - deliberately free of
// URLSession, IOKit and AppKit so "meine offenen", "Review an mir" and
// "merge-bereit" stay testable without a network round trip.

import Foundation

/// Eine Kennzahl mit optionaler Aufgabensumme. `openTasks` ist `nil`, wenn
/// die Zahl unbekannt ist - entweder weil kein Pull Request beitraegt oder
/// weil mindestens einer der beitragenden Pull Requests keine bekannte
/// Aufgabenzahl hat. Eine Teilsumme waere eine Untertreibung.
public struct BitbucketCount: Equatable {
    public let count: Int
    public let openTasks: Int?

    public init(count: Int, openTasks: Int?) {
        self.count = count
        self.openTasks = openTasks
    }
}

/// Die drei Kennzahlen einer Muster-Gruppe, zusammen mit der Rohform des
/// Musters fuer die Kopfzeile der UI.
public struct BitbucketGroup: Equatable {
    public let pattern: String
    public let mine: BitbucketCount
    public let toReview: BitbucketCount
    public let readyToMerge: Int

    public init(pattern: String, mine: BitbucketCount, toReview: BitbucketCount, readyToMerge: Int) {
        self.pattern = pattern
        self.mine = mine
        self.toReview = toReview
        self.readyToMerge = readyToMerge
    }
}

/// Fasst zwei Rollenlisten von Pull Requests ("als Autor" und "als
/// Reviewer") und eine Liste von Zielmustern zu Gruppen mit je drei
/// Kennzahlen zusammen. Alle Regeln dafuer leben ausschliesslich hier, damit
/// es genau eine Definition von "meine offenen", "zu reviewen" und
/// "merge-bereit" gibt.
public struct BitbucketOverview: Equatable {
    public let groups: [BitbucketGroup]

    public init(groups: [BitbucketGroup]) {
        self.groups = groups
    }

    /// Baut die Uebersicht. `patterns` und `patternLabels` sind gleich lang
    /// und positionsgleich; ist `patternLabels` kuerzer, wird fuer die
    /// fehlenden Gruppen der leere String als `pattern` gesetzt. Die
    /// Reihenfolge der Gruppen im Ergebnis ist die Reihenfolge von
    /// `patterns`.
    public static func build(author: [BitbucketPullRequest],
                              reviewer: [BitbucketPullRequest],
                              patterns: [BitbucketTargetPattern],
                              patternLabels: [String],
                              currentUser: String,
                              requiredApprovals: Int) -> BitbucketOverview {
        let merged = mergeDeduplicated(author: author, reviewer: reviewer)
        let effectiveRequiredApprovals = max(requiredApprovals, 1)

        let trimmedCurrentUser = currentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentUserIsEmpty = trimmedCurrentUser.isEmpty
        let lowerCurrentUser = trimmedCurrentUser.lowercased()

        // Jeder Pull Request landet beim ersten passenden Muster, nie in
        // zwei Gruppen gleichzeitig.
        var buckets: [[BitbucketPullRequest]] = Array(repeating: [], count: patterns.count)
        for pr in merged {
            guard let index = patterns.firstIndex(where: { $0.matches(pr) }) else { continue }
            buckets[index].append(pr)
        }

        var groups: [BitbucketGroup] = []
        groups.reserveCapacity(patterns.count)

        for index in patterns.indices {
            let prs = buckets[index]
            let patternLabel = index < patternLabels.count ? patternLabels[index] : ""

            let mine: BitbucketCount
            let toReview: BitbucketCount
            if currentUserIsEmpty {
                mine = BitbucketCount(count: 0, openTasks: nil)
                toReview = BitbucketCount(count: 0, openTasks: nil)
            } else {
                let minePullRequests = prs.filter { pr in
                    isCurrentUser(pr.authorName, lowerCurrentUser: lowerCurrentUser)
                        && !isApproved(pr, requiredApprovals: effectiveRequiredApprovals)
                }
                mine = aggregate(minePullRequests)

                // Nur `.unapproved` ist "Review an mir" - abarbeitbar durch
                // den Nutzer. `.approved` heisst erledigt, `.needsWork`
                // heisst der Ball liegt beim Autor: in beiden Faellen gibt
                // es fuer den Nutzer nichts zu tun, der Pull Request soll
                // also nicht dauerhaft in der Kennzahl haengen bleiben.
                let toReviewPullRequests = prs.filter { pr in
                    guard !isCurrentUser(pr.authorName, lowerCurrentUser: lowerCurrentUser) else { return false }
                    return pr.reviewers.contains { reviewerEntry in
                        reviewerEntry.status == .unapproved
                            && isCurrentUser(reviewerEntry.name, lowerCurrentUser: lowerCurrentUser)
                    }
                }
                toReview = aggregate(toReviewPullRequests)
            }

            let readyToMerge = prs.filter { pr in
                isApproved(pr, requiredApprovals: effectiveRequiredApprovals) && pr.openTaskCount == 0
            }.count

            groups.append(BitbucketGroup(pattern: patternLabel, mine: mine, toReview: toReview,
                                         readyToMerge: readyToMerge))
        }

        return BitbucketOverview(groups: groups)
    }

    /// Fuehrt beide Rollenlisten zusammen, ein Pull Request mit derselben
    /// `id` zaehlt genau einmal. Bei doppelter `id` gewinnt der Eintrag aus
    /// `author`.
    private static func mergeDeduplicated(author: [BitbucketPullRequest],
                                          reviewer: [BitbucketPullRequest]) -> [BitbucketPullRequest] {
        var seenIds = Set<Int>()
        var merged: [BitbucketPullRequest] = []
        for pr in author where seenIds.insert(pr.id).inserted {
            merged.append(pr)
        }
        for pr in reviewer where seenIds.insert(pr.id).inserted {
            merged.append(pr)
        }
        return merged
    }

    /// "genehmigt": mindestens `requiredApprovals` Reviewer mit Status
    /// `.approved` und kein Reviewer mit Status `.needsWork`.
    private static func isApproved(_ pr: BitbucketPullRequest, requiredApprovals: Int) -> Bool {
        let approvedCount = pr.reviewers.filter { $0.status == .approved }.count
        let hasNeedsWork = pr.reviewers.contains { $0.status == .needsWork }
        return approvedCount >= requiredApprovals && !hasNeedsWork
    }

    /// Case-insensitiver Vergleich gegen `currentUser`, umschliessende
    /// Leerzeichen werden abgeschnitten.
    private static func isCurrentUser(_ name: String, lowerCurrentUser: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowerCurrentUser
    }

    /// Zaehlt die beitragenden Pull Requests und summiert ihre offenen
    /// Aufgaben. Traegt keiner bei, ist die Aufgabensumme `nil`. Hat auch nur
    /// einer der beitragenden Pull Requests eine unbekannte Aufgabenzahl,
    /// ist die Summe `nil` statt einer Teilsumme.
    private static func aggregate(_ prs: [BitbucketPullRequest]) -> BitbucketCount {
        guard !prs.isEmpty else { return BitbucketCount(count: 0, openTasks: nil) }
        var sum = 0
        for pr in prs {
            guard let openTaskCount = pr.openTaskCount else {
                return BitbucketCount(count: prs.count, openTasks: nil)
            }
            sum += openTaskCount
        }
        return BitbucketCount(count: prs.count, openTasks: sum)
    }
}
