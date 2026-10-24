// XeneonEdge for macOS — command line tool
// SPDX-License-Identifier: GPL-3.0-or-later
//
// xeneonctl bitbucket-check — live connection test against a Bitbucket Data
// Center instance: keychain token, bearer auth, paging, field mapping and
// (with target patterns) grouping. Diagnostics only, not part of the widget.

import Foundation
import XeneonEdgeKit

enum BitbucketCheck {
    /// Hoechstens so viele Pull Requests je Rolle werden einzeln aufgelistet.
    private static let listLimit = 10

    /// Fuehrt die Pruefung aus und beendet den Prozess mit Exitcode 1, wenn
    /// Eingaben, Token oder Abruf scheitern. Alle Eingaben kommen aus der
    /// Umgebung bzw. der Keychain, nichts ist im Quelltext hinterlegt.
    static func run() {
        let environment = ProcessInfo.processInfo.environment

        // Basis-URL (Pflicht)
        let rawURL = (environment["XENEON_BITBUCKET_URL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty,
              let baseURL = URL(string: rawURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = baseURL.host, !host.isEmpty else {
            fail("""
            XENEON_BITBUCKET_URL fehlt oder ist keine gueltige URL mit Host. \
            Beispiel: export XENEON_BITBUCKET_URL=https://bitbucket.example.com
            """)
        }

        let user = (environment["XENEON_BITBUCKET_USER"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTargets = (environment["XENEON_BITBUCKET_TARGETS"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Token: nur ueber die Keychain-Quelle des Kits, nie ausgegeben.
        guard let token = KeychainTokenSource().token(forHost: host) else {
            fail("""
            Kein Token fuer \(host) gefunden. Abhilfe: \
            security add-generic-password -s xeneon-bitbucket -a \(host) -w \
            (fragt das Token interaktiv ab). Alternativ die Umgebungsvariable \
            XENEON_BITBUCKET_TOKEN setzen.
            """)
        }

        print("== Bitbucket-Check: \(host) ==")
        if scheme == "http" {
            print("WARNUNG: Schema http - das Token wird unverschluesselt uebertragen.")
        }

        let client = BitbucketClient(baseURL: baseURL, token: token)
        let authored = fetch(client, role: .author, title: "Autor (AUTHOR)")
        let reviewing = fetch(client, role: .reviewer, title: "Reviewer (REVIEWER)")

        printMetrics(author: authored, reviewer: reviewing, user: user, rawTargets: rawTargets)
    }

    /// Ruft eine Rolle ab, druckt Kopfzeile und Liste und liefert die Eintraege.
    private static func fetch(_ client: BitbucketClient, role: BitbucketRole,
                              title: String) -> [BitbucketPullRequest] {
        let result = runBlocking { try await client.openPullRequests(role: role) }
        switch result {
        case .success(let pullRequests):
            print("")
            print("\(title): \(pullRequests.count) offene Pull Requests")
            for pr in pullRequests.prefix(listLimit) {
                print("  \(pr.projectKey)/\(pr.repoSlug) -> \(pr.targetBranch)" +
                      " | Reviewer: \(pr.reviewers.count)" +
                      " | offene Aufgaben: \(taskText(pr.openTaskCount))")
            }
            if pullRequests.count > listLimit {
                print("  ... \(pullRequests.count - listLimit) weitere nicht gezeigt")
            }
            return pullRequests
        case .failure(let error):
            // Nur die kuratierte Beschreibung, nie das Fehlerobjekt selbst.
            if let bitbucketError = error as? BitbucketError {
                fail("Abruf \(title) fehlgeschlagen: \(bitbucketError.localizedDescription)")
            }
            fail("Abruf \(title) fehlgeschlagen: unbekannter Fehler")
        }
    }

    /// Kennzahlen je Zielmuster, nur wenn Benutzer und Muster gesetzt sind.
    private static func printMetrics(author: [BitbucketPullRequest],
                                     reviewer: [BitbucketPullRequest],
                                     user: String, rawTargets: String) {
        print("")
        var missing: [String] = []
        if user.isEmpty { missing.append("XENEON_BITBUCKET_USER") }
        if rawTargets.isEmpty { missing.append("XENEON_BITBUCKET_TARGETS") }
        guard missing.isEmpty else {
            print("Kennzahlen uebersprungen: \(missing.joined(separator: " und ")) nicht gesetzt.")
            return
        }

        var patterns: [BitbucketTargetPattern] = []
        var labels: [String] = []
        let entries = rawTargets.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for entry in entries {
            if let pattern = BitbucketTargetPattern.parse(entry) {
                patterns.append(pattern)
                labels.append(entry)
            } else {
                print("Zielmuster ungueltig, ausgelassen: \(entry)")
            }
        }
        guard !patterns.isEmpty else {
            print("Kennzahlen uebersprungen: kein gueltiges Zielmuster in XENEON_BITBUCKET_TARGETS.")
            return
        }

        let overview = BitbucketOverview.build(author: author, reviewer: reviewer,
                                               patterns: patterns, patternLabels: labels,
                                               currentUser: user, requiredApprovals: 1)
        print("Kennzahlen fuer \(user):")
        for group in overview.groups {
            print("  \(group.pattern)")
            print("    Meine PR      : \(countText(group.mine))")
            print("    Review        : \(countText(group.toReview))")
            print("    Merge-bereit  : \(group.readyToMerge)")
        }
    }

    /// Fehlende Aufgabenzahl ist `-`, nie `0`.
    private static func taskText(_ tasks: Int?) -> String {
        tasks.map(String.init) ?? "-"
    }

    private static func countText(_ count: BitbucketCount) -> String {
        "\(count.count) (Aufgaben: \(taskText(count.openTasks)))"
    }
}

/// Ergebnis-Ablage fuer die Bruecke; der Semaphor ordnet Schreiben vor Lesen.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Fuehrt einen async-Aufruf synchron aus: ein `Task` laeuft los, der
/// aufrufende Thread wartet ueber einen Semaphor. Noetig, weil main.swift
/// reiner synchroner Top-Level-Code ist.
private func runBlocking<T>(_ operation: @escaping () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.result ?? .failure(BitbucketError.transport)
}
