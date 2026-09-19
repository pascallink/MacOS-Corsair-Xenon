// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import XeneonEdgeKit

/// Eine Zeile der Limitanzeige (5 h / Tag / Woche).
///
/// Die `id` wird aus `kind.rawValue` gebildet, da dieser die stabile,
/// an die JSON-Schreibweise gebundene Identitaet des Fenstertyps bietet.
struct LimitRow: Identifiable {
    var id: String { kind.rawValue }
    let kind: UsageWindow.Kind
    let title: String
    let tokens: Int
    let budget: Int
    /// Anteil des Budgets, 0.0 = leer. Nil, wenn kein Budget gesetzt ist
    /// (budget <= 0). Bewusst NICHT auf 1.0 geklemmt - ein Fenster ueber dem
    /// Budget ist eine Information, die die View sehen muss; sie klemmt die
    /// Balkenbreite selbst beim Zeichnen.
    let fraction: Double?
    let resetText: String
}

final class UsageViewModel: ObservableObject {
    /// One entry per tracked profile. With no `claudeProfiles` configured
    /// this holds exactly one auto-detected profile, which is what keeps the
    /// single-profile layout and behaviour unchanged.
    @Published var profileUsages: [ClaudeUsageReader.ProfileUsage] = []
    @Published var config = WidgetConfig.load()
    /// Profiles that have received at least one entry from a cloud relay.
    @Published var cloudProfileIDs: Set<UUID> = []
    /// Overview of the open Claude Code chats (issue #14): how many are
    /// working, how many wait for an answer, how many just sit there.
    @Published var sessions = ClaudeSessionsSnapshot()

    /// Stands in for the auto-detected profile when none are configured.
    static let autoProfileID = UUID()

    private let reader = ClaudeUsageReader()
    private let sessionReader = ClaudeSessionReader()
    private let queue = DispatchQueue(label: "xeneon.claude-usage", qos: .utility)
    private var timer: Timer?
    private var cloudTimer: Timer?
    private var cloudEntries: [UUID: [ClaudeUsageEntry]] = [:]
    private var cloudSources: [(id: UUID, gistID: String)] = []

    /// Nur aktive Profile - ein deaktiviertes Konto wird weder gelesen noch
    /// gepollt noch angezeigt. Genau diese Stelle filtert, damit refresh()
    /// und die Cloud-Quellenbestimmung nicht auseinanderlaufen.
    /// ACHTUNG Sonderfall: eine LEERE claudeProfiles-Liste bedeutet
    /// Auto-Erkennung eines Profils, nicht "keine Profile" - dieser
    /// Unterschied wird NICHT hier behandelt, sondern an den Aufrufstellen
    /// anhand von `config.claudeProfiles.isEmpty` unterschieden, weil
    /// `activeProfiles` in beiden Faellen (kein Profil konfiguriert vs. alle
    /// deaktiviert) gleichermassen leer waere.
    private var activeProfiles: [ClaudeProfile] { ClaudeProfile.active(config.claudeProfiles) }

    func start() {
        refresh()
        scheduleTimer()
        scheduleCloudTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cloudTimer?.invalidate()
        cloudTimer = nil
    }

    func reloadConfig() {
        config = WidgetConfig.load()
        scheduleTimer()
        scheduleCloudTimer()
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = min(max(config.refreshSeconds, 15), 600)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Which gists to poll, and for which profile. Without configured
    /// profiles the top-level `cloudGistID` feeds the auto-detected profile;
    /// with profiles each one brings its own gist and the top-level field
    /// would be ambiguous, so it is ignored (loudly, not silently).
    private static func cloudSources(for config: WidgetConfig,
                                      activeProfiles: [ClaudeProfile]) -> [(id: UUID, gistID: String)] {
        let topLevel = config.cloudGistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.claudeProfiles.isEmpty else {
            return topLevel.isEmpty ? [] : [(autoProfileID, topLevel)]
        }
        if !topLevel.isEmpty {
            NSLog("XeneonEdge: cloudGistID is ignored while claudeProfiles is set — "
                + "give the profile its own cloudGistID instead")
        }
        // Nur aktive Profile pollen - ein deaktiviertes Konto darf keinen
        // Gist-Poll ausloesen, jede Anfrage zaehlt gegen GitHubs Limit von
        // 60 unauthentifizierten Anfragen pro Stunde und IP, und niemand
        // sieht das Ergebnis. Sind alle Profile deaktiviert, ist die Liste
        // leer und es wird NICHT auf die Auto-Erkennung zurueckgefallen -
        // die Leerpruefung oben greift nur, wenn claudeProfiles selbst leer
        // ist.
        return activeProfiles.compactMap { profile in
            let gist = profile.cloudGistID.trimmingCharacters(in: .whitespacesAndNewlines)
            return gist.isEmpty ? nil : (profile.id, gist)
        }
    }

    private func scheduleCloudTimer() {
        cloudTimer?.invalidate()
        cloudTimer = nil
        cloudEntries = [:]
        cloudProfileIDs = []
        cloudSources = Self.cloudSources(for: config, activeProfiles: activeProfiles)
        guard !cloudSources.isEmpty else { return }

        // Every poll hits one gist per source, so the floor scales with the
        // number of sources: GitHub allows 60 unauthenticated requests per
        // hour and IP, and two profiles polled every 90s would be 80.
        let floor = 60 * Double(cloudSources.count)
        let interval = min(max(config.cloudPollSeconds, floor), 900)
        pollCloud()
        cloudTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollCloud()
        }
    }

    private func pollCloud() {
        let sources = cloudSources
        guard !sources.isEmpty else { return }
        Task { [weak self] in
            for source in sources {
                let entries = await CloudUsageFetcher.fetch(gistID: source.gistID)
                await MainActor.run {
                    guard let self,
                          self.cloudSources.contains(where: {
                              $0.id == source.id && $0.gistID == source.gistID
                          })
                    else { return }
                    self.cloudEntries[source.id] = entries
                    if entries.isEmpty {
                        self.cloudProfileIDs.remove(source.id)
                    } else {
                        self.cloudProfileIDs.insert(source.id)
                    }
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        let cloud = cloudEntries
        // config.claudeProfiles selbst (nicht activeProfiles) entscheidet,
        // ob ueberhaupt Profile konfiguriert sind: leer heisst
        // Auto-Erkennung eines Profils, wie bisher. Sind Profile
        // konfiguriert, aber alle deaktiviert, waere activeProfiles
        // ebenfalls leer - das darf NICHT auf die Auto-Erkennung
        // zurueckfallen, sonst zeigt das Widget ausgerechnet das
        // automatisch erkannte Standardkonto, das der Nutzer abgeschaltet
        // hat. Deshalb die zwei Faelle unten sauber getrennt.
        let configuredProfiles = config.claudeProfiles
        let profiles = activeProfiles
        let sessionOptions = ClaudeSessionReader.Options(
            activeWindow: max(30, config.sessionActiveSeconds),
            openWindow: max(600, config.sessionOpenHours * 3_600)
        )
        let wantsSessions = config.showSessions
        queue.async { [weak self] in
            guard let self else { return }
            let usages: [ClaudeUsageReader.ProfileUsage]
            let sessions: ClaudeSessionsSnapshot
            if configuredProfiles.isEmpty {
                // Keine Profile konfiguriert: automatisch ein Profil
                // erkennen, unveraendertes Verhalten von vorher.
                sessions = wantsSessions
                    ? self.sessionReader.snapshot(for: [], options: sessionOptions)
                    : ClaudeSessionsSnapshot()
                let snap = self.reader.snapshot(
                    additionalEntries: cloud[Self.autoProfileID] ?? [])
                usages = [ClaudeUsageReader.ProfileUsage(id: Self.autoProfileID,
                                                         name: "", snapshot: snap)]
            } else if profiles.isEmpty {
                // Profile konfiguriert, aber alle deaktiviert: keine
                // Snapshots, keine Sessions. sessionReader.snapshot(for: [])
                // wuerde sonst auf die Auto-Erkennung zurueckfallen - genau
                // das abgeschaltete Konto.
                sessions = ClaudeSessionsSnapshot()
                usages = []
            } else {
                sessions = wantsSessions
                    ? self.sessionReader.snapshot(for: profiles, options: sessionOptions)
                    : ClaudeSessionsSnapshot()
                usages = self.reader.snapshots(for: profiles, additionalEntries: cloud)
            }
            DispatchQueue.main.async {
                self.profileUsages = usages
                self.sessions = sessions
            }
        }
    }

    // MARK: - Display helpers

    /// True once more than one profile is tracked; the view then switches to
    /// the stacked per-profile layout.
    var isMultiProfile: Bool { profileUsages.count > 1 }

    var usesCloudData: Bool { !cloudProfileIDs.isEmpty }

    /// The single-profile layout reads this; with several profiles it is the
    /// first one, which the stacked layout does not use.
    var snapshot: ClaudeUsageSnapshot {
        profileUsages.first?.snapshot ?? ClaudeUsageSnapshot()
    }

    func blockTokens(_ snapshot: ClaudeUsageSnapshot) -> Int {
        guard let block = snapshot.activeBlock else { return 0 }
        return config.includeCacheReads ? block.totals.totalTokens
                                        : block.totals.billableTokens
    }

    func budgetFraction(_ snapshot: ClaudeUsageSnapshot) -> Double? {
        guard config.tokenBudgetPerBlock > 0 else { return nil }
        return min(Double(blockTokens(snapshot)) / Double(config.tokenBudgetPerBlock), 1.0)
    }

    /// Fraction of the 5h window that has elapsed (for the time bar).
    func blockElapsedFraction(_ snapshot: ClaudeUsageSnapshot) -> Double {
        guard let block = snapshot.activeBlock else { return 0 }
        let elapsed = Date().timeIntervalSince(block.start)
        return min(max(elapsed / UsageBlock.duration, 0), 1)
    }

    func resetCountdown(_ snapshot: ClaudeUsageSnapshot) -> String {
        guard let block = snapshot.activeBlock else { return "—" }
        return UsageFormat.countdown(block.remaining(at: Date()))
    }

    func resetClockTime(_ snapshot: ClaudeUsageSnapshot) -> String {
        guard let block = snapshot.activeBlock else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: block.end)
    }

    func modelName(_ snapshot: ClaudeUsageSnapshot) -> String {
        guard let model = snapshot.latestModel else { return "—" }
        return ModelPricing.displayName(for: model)
    }

    func planName(_ snapshot: ClaudeUsageSnapshot) -> String? {
        guard let plan = snapshot.subscriptionType, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// Verbrauch je Limitfenster (5 h, Tag, Woche), in dieser Reihenfolge.
    func limitRows(for snapshot: ClaudeUsageSnapshot) -> [LimitRow] {
        let blockBudget = config.tokenBudgetPerBlock
        let blockTok = blockTokens(snapshot)
        let block = LimitRow(
            kind: .block,
            title: UsageWindow.Kind.block.title,
            tokens: blockTok,
            budget: blockBudget,
            fraction: blockBudget > 0 ? Double(blockTok) / Double(blockBudget) : nil,
            resetText: resetCountdown(snapshot)
        )
        return [block, limitRow(for: snapshot.day, budget: config.tokenBudgetPerDay),
                limitRow(for: snapshot.week, budget: config.tokenBudgetPerWeek)]
    }

    /// Baut eine Limitzeile aus einem `UsageWindow` (Tag/Woche). Der 5-h-
    /// Block hat kein `UsageWindow`, deshalb eigener Zweig in
    /// `limitRows(for:)`.
    private func limitRow(for window: UsageWindow, budget: Int) -> LimitRow {
        let tokens = config.includeCacheReads ? window.totals.totalTokens : window.totals.billableTokens
        // Anteil bewusst NICHT auf 1.0 geklemmt - ein Fenster ueber dem
        // Budget ist eine Information, die die View sehen muss; sie klemmt
        // die Balkenbreite selbst beim Zeichnen. `UsageWindow.fraction`
        // klemmt ebenfalls nicht, im Gegensatz zum bestehenden
        // `budgetFraction` fuer den 5-h-Ring, der unveraendert bleibt.
        let fraction = budget > 0 ? window.fraction(of: budget, includeCacheReads: config.includeCacheReads) : nil
        return LimitRow(
            kind: window.kind,
            title: window.kind.title,
            tokens: tokens,
            budget: budget,
            fraction: fraction,
            resetText: countdownText(window.remaining(at: Date()))
        )
    }

    /// Gleicher Platzhalter wie `resetCountdown(_:)` ohne aktiven Block -
    /// hier fuer Fenster ohne bekannten Reset-Zeitpunkt (z. B. leere Woche).
    private func countdownText(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "—" }
        return UsageFormat.countdown(remaining)
    }

    // Single-profile conveniences, kept so the existing layout reads the same.
    var blockTokens: Int { blockTokens(snapshot) }
    var budgetFraction: Double? { budgetFraction(snapshot) }
    var blockElapsedFraction: Double { blockElapsedFraction(snapshot) }
    var resetCountdown: String { resetCountdown(snapshot) }
    var resetClockTime: String { resetClockTime(snapshot) }
    var modelName: String { modelName(snapshot) }
    var planName: String? { planName(snapshot) }
    var limitRows: [LimitRow] { limitRows(for: snapshot) }

    /// The chats listed under the counters, capped by `sessionRows`.
    var sessionRows: [ClaudeSessionSummary] {
        Array(sessions.sessions.prefix(max(0, config.sessionRows)))
    }

    /// The newest open question, when the config allows showing its text.
    var latestQuestion: ClaudeSessionSummary? {
        config.showLastQuestion ? sessions.latestQuestion : nil
    }

    static func tokenString(_ tokens: Int) -> String { UsageFormat.tokens(tokens) }
    static func costString(_ usd: Double) -> String { UsageFormat.cost(usd) }
}
