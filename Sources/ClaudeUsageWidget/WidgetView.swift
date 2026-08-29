// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compact dark dashboard card: current 5h token window with reset countdown,
// estimated cost, and the active model — sized for the Xeneon Edge strip.

import SwiftUI
import XeneonEdgeKit

enum WidgetTheme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.135)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.93, green: 0.79, blue: 0.12)
    static let good = Color(red: 0.35, green: 0.80, blue: 0.45)
    static let warn = Color(red: 0.95, green: 0.55, blue: 0.20)
    static let critical = Color(red: 0.92, green: 0.30, blue: 0.30)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
}

struct WidgetView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        Group {
            if model.isMultiProfile {
                profileList
            } else {
                singleProfile
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(WidgetTheme.background)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(WidgetTheme.border))
        )
        .preferredColorScheme(.dark)
    }

    private var singleProfile: some View {
        HStack(spacing: 18) {
            tokenGauge
            Divider().overlay(WidgetTheme.border)
            metrics
            Spacer(minLength: 0)
            badges
        }
    }

    // MARK: Several profiles: one compact row each
    //
    // Every profile keeps its own 5h window, so each row carries its own
    // token count, its own bar and its own reset countdown. Nothing here is
    // ever summed across rows — that number would belong to no real limit.

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.profileUsages) { usage in
                profileRow(usage)
                if usage.id != model.profileUsages.last?.id {
                    Divider().overlay(WidgetTheme.border).padding(.vertical, 8)
                }
            }
            Spacer(minLength: 0)
            Text("Kosten geschätzt · je Profil eigenes 5-h-Fenster")
                .font(.system(size: 10))
                .foregroundColor(WidgetTheme.textSecondary.opacity(0.7))
        }
    }

    private func rowColor(_ fraction: Double?) -> Color {
        guard let fraction else { return WidgetTheme.accent }
        if fraction >= 0.9 { return WidgetTheme.critical }
        if fraction >= 0.7 { return WidgetTheme.warn }
        return WidgetTheme.good
    }

    private func profileRow(_ usage: ClaudeUsageReader.ProfileUsage) -> some View {
        let snapshot = usage.snapshot
        let budget = model.budgetFraction(snapshot)
        let fill = budget ?? model.blockElapsedFraction(snapshot)
        let color = rowColor(budget)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(usage.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WidgetTheme.textPrimary)
                    .lineLimit(1)
                if let plan = model.planName(snapshot) {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(WidgetTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                if model.cloudProfileIDs.contains(usage.id) {
                    Image(systemName: "icloud")
                        .font(.system(size: 10))
                        .foregroundColor(WidgetTheme.textSecondary)
                }
                Spacer(minLength: 4)
                Text(UsageViewModel.tokenString(model.blockTokens(snapshot)))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(WidgetTheme.textPrimary)
                Text("Tokens")
                    .font(.system(size: 10))
                    .foregroundColor(WidgetTheme.textSecondary)
            }

            bar(fraction: fill, color: color)

            HStack(spacing: 8) {
                if snapshot.activeBlock == nil {
                    Text("keine aktive Session")
                        .font(.system(size: 11))
                        .foregroundColor(WidgetTheme.textSecondary)
                } else {
                    Text("Reset in \(model.resetCountdown(snapshot))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(WidgetTheme.textSecondary)
                }
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(WidgetTheme.textSecondary.opacity(0.6))
                Text(UsageViewModel.costString(snapshot.activeBlock?.totals.costUSD ?? 0))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(WidgetTheme.textSecondary)
                Spacer(minLength: 0)
                if snapshot.latestModel != nil {
                    Text(model.modelName(snapshot))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(WidgetTheme.accent))
                }
            }
        }
    }

    private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(fraction, 1)) * geometry.size.width)
            }
        }
        .frame(height: 6)
    }

    // MARK: Left: token ring / 5h window

    private var gaugeColor: Color {
        guard let fraction = model.budgetFraction else { return WidgetTheme.accent }
        if fraction >= 0.9 { return WidgetTheme.critical }
        if fraction >= 0.7 { return WidgetTheme.warn }
        return WidgetTheme.good
    }

    private var tokenGauge: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: model.budgetFraction ?? model.blockElapsedFraction)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: model.blockTokens)
                VStack(spacing: 2) {
                    Text(UsageViewModel.tokenString(model.blockTokens))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(WidgetTheme.textPrimary)
                        .minimumScaleFactor(0.5)
                    Text("Tokens")
                        .font(.system(size: 11))
                        .foregroundColor(WidgetTheme.textSecondary)
                }
            }
            .frame(width: 130, height: 130)
            if let fraction = model.budgetFraction {
                Text(String(format: "%.0f %% vom Budget", fraction * 100))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WidgetTheme.textSecondary)
            } else {
                Text("5-h-Fenster")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WidgetTheme.textSecondary)
            }
        }
    }

    // MARK: Middle: metrics

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow(symbol: "clock.arrow.circlepath",
                      title: "Reset in",
                      value: model.resetCountdown,
                      detail: model.resetClockTime.isEmpty ? nil : "um \(model.resetClockTime)")
            metricRow(symbol: "dollarsign.circle",
                      title: "Kosten (Fenster)",
                      value: UsageViewModel.costString(model.snapshot.activeBlock?.totals.costUSD ?? 0),
                      detail: "heute \(UsageViewModel.costString(model.snapshot.today.costUSD))")
            metricRow(symbol: "arrow.up.arrow.down",
                      title: "In / Out",
                      value: "\(UsageViewModel.tokenString(model.snapshot.activeBlock?.totals.inputTokens ?? 0)) / "
                          + UsageViewModel.tokenString(model.snapshot.activeBlock?.totals.outputTokens ?? 0),
                      detail: "Cache "
                          + UsageViewModel.tokenString(model.snapshot.activeBlock?.totals.cacheReadTokens ?? 0))
        }
    }

    private func metricRow(symbol: String, title: String, value: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundColor(WidgetTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(WidgetTheme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(WidgetTheme.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(WidgetTheme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: Right: model / plan badges

    private var badges: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(model.modelName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(WidgetTheme.accent))
            if let plan = model.planName {
                Text("Claude \(plan)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WidgetTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            if model.usesCloudData {
                Label("Cloud", systemImage: "icloud")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WidgetTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Spacer()
            if model.snapshot.activeBlock == nil {
                Text("keine aktive Session")
                    .font(.system(size: 11))
                    .foregroundColor(WidgetTheme.textSecondary)
            }
            Text("Kosten geschätzt · lokal" + (model.usesCloudData ? " + Cloud" : ""))
                .font(.system(size: 10))
                .foregroundColor(WidgetTheme.textSecondary.opacity(0.7))
        }
    }
}
