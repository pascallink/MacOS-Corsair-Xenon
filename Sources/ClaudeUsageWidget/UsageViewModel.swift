// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import XeneonEdgeKit

final class UsageViewModel: ObservableObject {
    @Published var snapshot = ClaudeUsageSnapshot()
    @Published var config = WidgetConfig.load()
    /// True once at least one entry has come back from the cloud relay.
    @Published var usesCloudData = false

    private let reader = ClaudeUsageReader()
    private let queue = DispatchQueue(label: "xeneon.claude-usage", qos: .utility)
    private var timer: Timer?
    private var cloudTimer: Timer?
    private var cloudEntries: [ClaudeUsageEntry] = []

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

    private func scheduleCloudTimer() {
        cloudTimer?.invalidate()
        cloudTimer = nil
        cloudEntries = []
        usesCloudData = false
        guard !config.cloudGistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let interval = min(max(config.cloudPollSeconds, 60), 900)
        pollCloud()
        cloudTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollCloud()
        }
    }

    private func pollCloud() {
        let gistID = config.cloudGistID
        guard !gistID.isEmpty else { return }
        Task { [weak self] in
            let entries = await CloudUsageFetcher.fetch(gistID: gistID)
            await MainActor.run {
                guard let self, self.config.cloudGistID == gistID else { return }
                self.cloudEntries = entries
                self.usesCloudData = !entries.isEmpty
                self.refresh()
            }
        }
    }

    func refresh() {
        let cloud = cloudEntries
        queue.async { [weak self] in
            guard let self else { return }
            let snap = self.reader.snapshot(additionalEntries: cloud)
            DispatchQueue.main.async {
                self.snapshot = snap
            }
        }
    }

    // MARK: - Display helpers

    var blockTokens: Int {
        guard let block = snapshot.activeBlock else { return 0 }
        return config.includeCacheReads ? block.totals.totalTokens
                                        : block.totals.billableTokens
    }

    var budgetFraction: Double? {
        guard config.tokenBudgetPerBlock > 0 else { return nil }
        return min(Double(blockTokens) / Double(config.tokenBudgetPerBlock), 1.0)
    }

    /// Fraction of the 5h window that has elapsed (for the time bar).
    var blockElapsedFraction: Double {
        guard let block = snapshot.activeBlock else { return 0 }
        let elapsed = Date().timeIntervalSince(block.start)
        return min(max(elapsed / UsageBlock.duration, 0), 1)
    }

    var resetCountdown: String {
        guard let block = snapshot.activeBlock else { return "—" }
        return UsageFormat.countdown(block.remaining(at: Date()))
    }

    var resetClockTime: String {
        guard let block = snapshot.activeBlock else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: block.end)
    }

    var modelName: String {
        guard let model = snapshot.latestModel else { return "—" }
        return ModelPricing.displayName(for: model)
    }

    var planName: String? {
        guard let plan = snapshot.subscriptionType, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    static func tokenString(_ tokens: Int) -> String { UsageFormat.tokens(tokens) }
    static func costString(_ usd: Double) -> String { UsageFormat.cost(usd) }
}
