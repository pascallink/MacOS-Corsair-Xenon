// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import XeneonEdgeKit

final class UsageViewModel: ObservableObject {
    @Published var snapshot = ClaudeUsageSnapshot()
    @Published var config = WidgetConfig.load()

    private let reader = ClaudeUsageReader()
    private let queue = DispatchQueue(label: "xeneon.claude-usage", qos: .utility)
    private var timer: Timer?

    func start() {
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reloadConfig() {
        config = WidgetConfig.load()
        scheduleTimer()
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = min(max(config.refreshSeconds, 15), 600)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let snap = self.reader.snapshot()
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
        let remaining = Int(block.remaining(at: Date()))
        return String(format: "%d:%02d h", remaining / 3600, (remaining % 3600) / 60)
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

    static func tokenString(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens)"
        case ..<1_000_000: return String(format: "%.1fk", Double(tokens) / 1_000)
        default: return String(format: "%.2fM", Double(tokens) / 1_000_000)
        }
    }

    static func costString(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }
}
