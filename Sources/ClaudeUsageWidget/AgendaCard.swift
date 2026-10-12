// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Karte "Termine" oberhalb der Nutzungsanzeige. Auswahl, Stufen und Formate
// kommen aus XeneonEdgeKit; die Karte faerbt und layoutet nur. Alle Hoehen
// sind fest, damit das Fenster exakt um die Karte wachsen kann.

import SwiftUI
import XeneonEdgeKit

struct AgendaCard: View {
    @ObservedObject var agenda: AgendaModel

    // Feste Masse: `height(rows:extraLines:)` liefert genau diese Summe.
    private static let padding: CGFloat = 12
    private static let spacing: CGFloat = 8
    private static let rowHeight: CGFloat = 38
    private static let extraLineHeight: CGFloat = 16
    private static let cornerRadius: CGFloat = 14

    /// Exakte Hoehe der Karte fuer `rows` Warnzeilen und `extraLines`
    /// Zusatzzeilen ("+N weitere", "Stand veraltet").
    static func height(rows: Int, extraLines: Int) -> CGFloat {
        let rows = max(0, rows)
        let extra = max(0, extraLines)
        let children = rows + extra
        guard children > 0 else { return 0 }
        return 2 * padding
            + CGFloat(rows) * rowHeight
            + CGFloat(extra) * extraLineHeight
            + CGFloat(children - 1) * spacing
    }

    /// Anzahl Zusatzzeilen fuer den aktuellen Stand.
    static func extraLines(overflow: Int, isStale: Bool) -> Int {
        (overflow > 0 ? 1 : 0) + (isStale ? 1 : 0)
    }

    private static func rank(_ stage: ReminderStage) -> Int {
        ReminderStage.allCases.firstIndex(of: stage) ?? 0
    }

    /// Dringendste Warnung: hoechster Rang in `ReminderStage.allCases`, bei
    /// gleicher Stufe die mit der kuerzesten Restzeit (nie das Minimum des Rangs).
    static func urgent(_ reminders: [CalendarReminder]) -> CalendarReminder? {
        reminders.max { lhs, rhs in
            let l = rank(lhs.stage), r = rank(rhs.stage)
            return l != r ? l < r : lhs.remaining > rhs.remaining
        }
    }

    static func color(for stage: ReminderStage) -> Color {
        switch stage {
        case .hour: return WidgetTheme.good
        case .halfHour: return WidgetTheme.accent
        case .quarter: return WidgetTheme.warn
        case .fiveMinutes, .imminent: return WidgetTheme.critical
        }
    }

    var body: some View {
        let urgentStage = Self.urgent(agenda.reminders)?.stage
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(agenda.reminders) { reminder in
                AgendaCardRow(reminder: reminder, showTitle: agenda.showEventTitles)
                    .frame(height: Self.rowHeight, alignment: .top)
            }
            if agenda.overflow > 0 {
                Text("+\(agenda.overflow) weitere")
                    .font(.system(size: 12))
                    .foregroundColor(WidgetTheme.textSecondary)
                    .frame(height: Self.extraLineHeight, alignment: .leading)
            }
            if agenda.isStale {
                Text("Stand veraltet")
                    .font(.system(size: 11))
                    .foregroundColor(WidgetTheme.textSecondary)
                    .frame(height: Self.extraLineHeight, alignment: .leading)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height(rows: agenda.reminders.count,
                                   extraLines: Self.extraLines(overflow: agenda.overflow,
                                                               isStale: agenda.isStale)),
               alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius).fill(WidgetTheme.panel)
        )
        .overlay {
            if let stage = urgentStage, Self.rank(stage) >= Self.rank(.quarter) {
                let color = Self.color(for: stage)
                ZStack {
                    if Self.rank(stage) >= Self.rank(.fiveMinutes) {
                        RoundedRectangle(cornerRadius: Self.cornerRadius).fill(color.opacity(0.12))
                    }
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .stroke(color.opacity(0.35), lineWidth: 2)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private struct AgendaCardRow: View {
    let reminder: CalendarReminder
    let showTitle: Bool

    var body: some View {
        let color = AgendaCard.color(for: reminder.stage)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ReminderFormat.clock(reminder.event.start))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(WidgetTheme.textSecondary)
                if showTitle {
                    Text(reminder.event.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(WidgetTheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(ReminderFormat.countdown(reminder.remaining))
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
        .modifier(AgendaPulse(active: reminder.stage == .imminent))
    }
}

/// Pulsierende Deckkraft (1.0 zu 0.45, 1 s easeInOut, endlos) solange `active`.
private struct AgendaPulse: ViewModifier {
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
