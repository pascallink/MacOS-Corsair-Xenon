// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import XeneonEdgeKit

final class UsageViewModel: ObservableObject {
    /// One entry per tracked profile. With no `claudeProfiles` configured
    /// this holds exactly one auto-detected profile, which is what keeps the
    /// single-profile layout and behaviour unchanged.
    @Published var profileUsages: [ClaudeUsageReader.ProfileUsage] = []
    @Published var config = WidgetConfig.load()
    /// Profiles that have received at least one entry from a cloud relay.
    @Published var cloudProfileIDs: Set<UUID> = []

    /// Stands in for the auto-detected profile when none are configured.
    static let autoProfileID = UUID()

    private let reader = ClaudeUsageReader()
    private let queue = DispatchQueue(label: "xeneon.claude-usage", qos: .utility)
    private var timer: Timer?
    private var cloudTimer: Timer?
    private var cloudEntries: [UUID: [ClaudeUsageEntry]] = [:]
    private var cloudSources: [(id: UUID, gistID: String)] = []

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
    private static func cloudSources(for config: WidgetConfig) -> [(id: UUID, gistID: String)] {
        let topLevel = config.cloudGistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.claudeProfiles.isEmpty else {
            return topLevel.isEmpty ? [] : [(autoProfileID, topLevel)]
        }
        if !topLevel.isEmpty {
            NSLog("XeneonEdge: cloudGistID is ignored while claudeProfiles is set — "
                + "give the profile its own cloudGistID instead")
        }
        return config.claudeProfiles.compactMap { profile in
            let gist = profile.cloudGistID.trimmingCharacters(in: .whitespacesAndNewlines)
            return gist.isEmpty ? nil : (profile.id, gist)
        }
    }

    private func scheduleCloudTimer() {
        cloudTimer?.invalidate()
        cloudTimer = nil
        cloudEntries = [:]
        cloudProfileIDs = []
        cloudSources = Self.cloudSources(for: config)
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
        let profiles = config.claudeProfiles
        queue.async { [weak self] in
            guard let self else { return }
            let usages: [ClaudeUsageReader.ProfileUsage]
            if profiles.isEmpty {
                let snap = self.reader.snapshot(
                    additionalEntries: cloud[Self.autoProfileID] ?? [])
                usages = [ClaudeUsageReader.ProfileUsage(id: Self.autoProfileID,
                                                         name: "", snapshot: snap)]
            } else {
                usages = self.reader.snapshots(for: profiles, additionalEntries: cloud)
            }
            DispatchQueue.main.async {
                self.profileUsages = usages
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

    // Single-profile conveniences, kept so the existing layout reads the same.
    var blockTokens: Int { blockTokens(snapshot) }
    var budgetFraction: Double? { budgetFraction(snapshot) }
    var blockElapsedFraction: Double { blockElapsedFraction(snapshot) }
    var resetCountdown: String { resetCountdown(snapshot) }
    var resetClockTime: String { resetClockTime(snapshot) }
    var modelName: String { modelName(snapshot) }
    var planName: String? { planName(snapshot) }

    static func tokenString(_ tokens: Int) -> String { UsageFormat.tokens(tokens) }
    static func costString(_ usd: Double) -> String { UsageFormat.cost(usd) }
}
