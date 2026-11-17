// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Panel "Bamboo-Laufzeiten": durchschnittliche Build-Dauer und Erfolgsquote
// je Plan. Abruf und Auswertung kommen aus XeneonEdgeKit, die View
// formatiert und faerbt nur.

import SwiftUI
import XeneonEdgeKit

/// Haelt den letzten Bamboo-Snapshot und ruft ihn periodisch im Hintergrund ab.
final class BambooModel: ObservableObject {
    @Published var snapshot = BambooSnapshot.empty
    @Published var windowDays = 14

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var signature = ""

    func start(config: AppConfig) {
        let plans = config.bambooPlans
        let windowDays = max(1, config.bambooWindowDays)
        let includeBranches = config.bambooIncludeBranches
        let interval = max(5, config.bambooRefreshMinutes) * 60
        let urlText = config.bambooBaseURL
        self.windowDays = windowDays

        // Gleiche Config bei laufendem Timer: nichts neu starten.
        let sig = "\(urlText)|\(plans.map(\.key))|\(windowDays)|\(includeBranches)|\(interval)"
        if timer != nil, sig == signature { return }
        signature = sig
        timer?.invalidate()
        task?.cancel()
        task = nil
        generation += 1

        guard let baseURL = URL(string: urlText), baseURL.host != nil else {
            timer = nil
            snapshot = BambooSnapshot(plans: [], updatedAt: nil, error: "Bamboo-Adresse ungueltig")
            return
        }

        let refresh: () -> Void = { [weak self] in
            self?.refresh(plans: plans, baseURL: baseURL,
                          includeBranches: includeBranches, windowDays: windowDays)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        generation += 1
        signature = ""
        snapshot = BambooSnapshot.empty
    }

    private func refresh(plans: [BambooPlan], baseURL: URL,
                         includeBranches: Bool, windowDays: Int) {
        guard task == nil else { return } // laufenden Abruf nicht doppelt starten
        let gen = generation
        task = Task.detached(priority: .utility) { [weak self] in
            let owner = self
            let result = await BambooClient.snapshot(
                plans: plans, baseURL: baseURL, tokenSource: KeychainBambooTokenSource(),
                includeBranches: includeBranches, windowDays: windowDays)
            await MainActor.run {
                guard let self = owner, self.generation == gen else { return }
                self.snapshot = result
                self.task = nil
            }
        }
    }
}

struct BambooPanel: View {
    @EnvironmentObject var bamboo: BambooModel

    // MARK: Formatierung (rein, testbar)

    /// "42 min" bzw. "1 h 05 min"; nil -> "-".
    static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "-" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "93 %"; nil -> "-".
    static func percentText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "-" }
        return "\(Int((min(max(rate, 0), 1) * 100).rounded())) %"
    }

    static func rateColor(_ rate: Double?) -> Color {
        guard let rate else { return EdgeTheme.textSecondary }
        if rate >= 0.9 { return EdgeTheme.good }
        if rate >= 0.7 { return EdgeTheme.warn }
        return EdgeTheme.critical
    }

    /// "max 1 h" / "max 3 h" (allgemein: ganze Stunden, sonst Minuten).
    static func scaleText(_ seconds: TimeInterval) -> String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            return "max \(Int(seconds / 3600)) h"
        }
        return "max \(Int((seconds / 60).rounded())) min"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func footerText(windowDays: Int, updatedAt: Date?) -> String {
        var text = "letzte \(windowDays) Tage"
        if let updatedAt { text += " · Stand \(clock.string(from: updatedAt))" }
        return text
    }

    // MARK: View

    var body: some View {
        Panel(title: "Bamboo-Laufzeiten", systemImage: "hammer") {
            VStack(alignment: .leading, spacing: 10) {
                if let error = bamboo.snapshot.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(EdgeTheme.warn)
                        .lineLimit(2)
                }
                if bamboo.snapshot.plans.isEmpty {
                    if bamboo.snapshot.error == nil {
                        Text("noch keine Daten")
                            .font(.system(size: 13))
                            .foregroundColor(EdgeTheme.textSecondary)
                    }
                } else {
                    ForEach(bamboo.snapshot.plans) { stats in
                        BambooPlanRow(stats: stats)
                    }
                }
                Spacer(minLength: 0)
                Text(Self.footerText(windowDays: bamboo.windowDays,
                                     updatedAt: bamboo.snapshot.updatedAt))
                    .font(.system(size: 11))
                    .foregroundColor(EdgeTheme.textSecondary)
            }
        }
    }
}

private struct BambooPlanRow: View {
    let stats: BambooPlanStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.plan.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(EdgeTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let error = stats.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(EdgeTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(BambooPanel.durationText(stats.averageDuration))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(EdgeTheme.textPrimary)
                    Text(BambooPanel.percentText(stats.successRate))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(BambooPanel.rateColor(stats.successRate))
                }
            }
            if stats.error == nil {
                let fill = stats.isCapped
                    ? EdgeTheme.critical
                    : (stats.plan.extended ? EdgeTheme.highlight : EdgeTheme.accent)
                HStack(spacing: 6) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule()
                                .fill(fill)
                                .frame(width: max(0, min(stats.fraction, 1)) * geometry.size.width)
                        }
                    }
                    .frame(height: 5)
                    if stats.isCapped {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(EdgeTheme.critical)
                    }
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text("\(stats.buildCount) Builds")
                        .monospacedDigit()
                    Text(BambooPanel.scaleText(stats.scaleMax))
                }
                .font(.system(size: 11))
                .foregroundColor(EdgeTheme.textSecondary)
            }
        }
    }
}
