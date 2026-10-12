// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Panel "Termine": naechste Termine mit Countdown und Farbeskalation.
// Auswahl und Stufen kommen unveraendert aus XeneonEdgeKit, die View
// formatiert und faerbt nur.

import SwiftUI
import XeneonEdgeKit

struct AgendaPanel: View {
    @EnvironmentObject var agenda: AgendaModel

    /// Massgeblich ist die dringendste Warnung: der hoechste Rang in
    /// `ReminderStage.allCases` (hour ... imminent), unabhaengig von der
    /// Reihenfolge der Liste.
    private var urgent: ReminderStage? {
        agenda.reminders.map(\.stage).max { Self.rank($0) < Self.rank($1) }
    }

    private static func rank(_ stage: ReminderStage) -> Int {
        ReminderStage.allCases.firstIndex(of: stage) ?? 0
    }

    static func color(for stage: ReminderStage) -> Color {
        switch stage {
        case .hour: return EdgeTheme.good
        case .halfHour: return EdgeTheme.accent
        case .quarter: return EdgeTheme.warn
        case .fiveMinutes, .imminent: return EdgeTheme.critical
        }
    }

    private var emptyText: String {
        let lead = Int(agenda.leadMinutes.rounded())
        return lead == 60
            ? "keine Termine in der naechsten Stunde"
            : "keine Termine in den naechsten \(lead) Minuten"
    }

    var body: some View {
        Panel(title: "Termine", systemImage: "calendar") {
            VStack(alignment: .leading, spacing: 10) {
                if !agenda.isConfigured {
                    Text("kein Kalender-Feed eingerichtet")
                        .font(.system(size: 13))
                        .foregroundColor(EdgeTheme.textSecondary)
                } else if agenda.reminders.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 13))
                        .foregroundColor(EdgeTheme.textSecondary)
                } else {
                    ForEach(agenda.reminders) { reminder in
                        ReminderRow(reminder: reminder, showTitle: agenda.showEventTitles)
                    }
                    if agenda.overflow > 0 {
                        Text("+\(agenda.overflow) weitere")
                            .font(.system(size: 12))
                            .foregroundColor(EdgeTheme.textSecondary)
                    }
                }
                if agenda.isStale {
                    Text("Stand veraltet")
                        .font(.system(size: 11))
                        .foregroundColor(EdgeTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        // Rand und Toenung als Overlay: die Huelle zeichnet einen deckenden
        // Hintergrund und bleibt unveraendert.
        .overlay(alignment: .center) {
            if let stage = urgent, rank(stage) >= Self.rank(.quarter) {
                let color = Self.color(for: stage)
                ZStack {
                    if Self.rank(stage) >= Self.rank(.fiveMinutes) {
                        RoundedRectangle(cornerRadius: 18).fill(color.opacity(0.12))
                    }
                    RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.35), lineWidth: 2)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func rank(_ stage: ReminderStage) -> Int { Self.rank(stage) }
}

private struct ReminderRow: View {
    let reminder: CalendarReminder
    let showTitle: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// mm:ss unter einer Stunde, h:mm:ss ab einer Stunde, "laeuft" bei
    /// negativer Restzeit.
    static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining >= 0 else { return "laeuft" }
        let total = Int(remaining.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        let color = AgendaPanel.color(for: reminder.stage)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.timeFormatter.string(from: reminder.event.start))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(EdgeTheme.textSecondary)
                if showTitle {
                    Text(reminder.event.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(EdgeTheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Self.countdown(reminder.remaining))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, min(reminder.progress, 1)) * geometry.size.width)
                }
            }
            .frame(height: 5)
        }
        .modifier(PulseModifier(active: reminder.stage == .imminent))
    }
}

/// Pulsierende Deckkraft (1.0 zu 0.45, 1 s easeInOut, endlos) solange `active`.
private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? 0.45 : 1.0)
            .animation(active
                       ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                       : .default,
                       value: dimmed)
            .onAppear { dimmed = active }
            .onChange(of: active) { dimmed = $0 }
    }
}
