// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Versionsringe des lokalen KI-Dashboards fuer das Claude-Panel.

import SwiftUI
import XeneonEdgeKit

/// Farbe je Bereich, angelehnt an das KI-Dashboard.
func kiAreaColor(_ area: KIVersionArea) -> Color {
    switch area {
    case .preparation: return Color(white: 0.6)
    case .development: return EdgeTheme.highlight
    case .acceptance: return EdgeTheme.warn
    case .done: return EdgeTheme.good
    }
}

/// Versionsringe, eine Reihe je Projekt, fuellen den verfuegbaren Platz.
/// Legende und Stand stehen unten.
struct KIVersionRingsView: View {
    @EnvironmentObject var model: KIVersionsModel
    @EnvironmentObject var configStore: ConfigStore

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let legendHeight: CGFloat = 16
    private static let legendGap: CGFloat = 8
    private static let rowGap: CGFloat = 10
    private static let cellGap: CGFloat = 8
    /// Platz unter dem Ring: Label, Issues, Zeitstrahl samt Text und Abstaende.
    static let captionHeight: CGFloat = 68
    private static let minDiameter: CGFloat = 80
    private static let maxDiameter: CGFloat = 220

    /// Reihen in Reihenfolge der konfigurierten Projekte, Projekte ohne
    /// Version entfallen; unbekannte Projekte folgen am Ende.
    private var rows: [[KIVersionRing]] {
        var order = configStore.config.kiDashboardProjects
        for v in model.versions where !order.contains(v.project) { order.append(v.project) }
        return order.compactMap { project in
            let list = model.versions.filter { $0.project == project }
            return list.isEmpty ? nil : list
        }
    }

    var body: some View {
        VStack(spacing: Self.legendGap) {
            let rows = self.rows
            if rows.isEmpty {
                Spacer(minLength: 0)
                if model.errorText == nil {
                    Text("keine laufende Fix-Version")
                        .font(.system(size: 13))
                        .foregroundColor(EdgeTheme.textSecondary)
                }
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in
                    let diameter = Self.diameter(size: geo.size, rows: rows.map(\.count))
                    // Zeitstrahl rechnet mit dem Tag, daher minuetlich neu zeichnen.
                    TimelineView(.everyMinute) { context in
                        VStack(spacing: Self.rowGap) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: Self.cellGap) {
                                    ForEach(row) {
                                        KIVersionRingView(version: $0, diameter: diameter, today: context.date)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            legend
        }
    }

    /// Ringdurchmesser: der kleinere Wert aus Hoehe (Reihenhoehe abzueglich
    /// Beschriftung) und Breite (Zellbreite der vollsten Reihe), begrenzt.
    static func diameter(size: CGSize, rows: [Int]) -> CGFloat {
        guard !rows.isEmpty else { return minDiameter }
        let count = CGFloat(rows.count)
        let rowHeight = (size.height - rowGap * (count - 1)) / count
        let byHeight = rowHeight - captionHeight
        let widest = CGFloat(rows.max() ?? 1)
        let byWidth = (size.width - cellGap * (widest - 1)) / widest - cellGap
        return min(max(min(byHeight, byWidth), minDiameter), maxDiameter)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(KIVersionArea.allCases, id: \.self) { area in
                HStack(spacing: 4) {
                    Circle().fill(kiAreaColor(area)).frame(width: 8, height: 8)
                    Text(Self.title(area))
                        .font(.system(size: 11))
                        .foregroundColor(EdgeTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(EdgeTheme.warn)
                    .lineLimit(1)
            }
            if let stamp = model.lastSuccess {
                Text("Stand \(Self.stampFormat.string(from: stamp))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(EdgeTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(height: Self.legendHeight)
    }

    private static func title(_ area: KIVersionArea) -> String {
        switch area {
        case .preparation: return "Vorbereitung"
        case .development: return "Entwicklung"
        case .acceptance: return "Abnahme"
        case .done: return "Fertig"
        }
    }
}

/// Eine Version: konzentrische 270-Grad-Spuren, je Bereich eine, darunter
/// Label, Issues und Zeitstrahl. Alle Masse leiten sich aus `diameter` ab.
struct KIVersionRingView: View {
    let version: KIVersionRing
    let diameter: CGFloat
    let today: Date

    /// Strich 6 %, Spurabstand 7,5 % des Durchmessers.
    private var stroke: CGFloat { diameter * 0.06 }
    private var step: CGFloat { diameter * 0.075 }
    /// Innenfeld bei vier Spuren: Durchmesser abzueglich zweimal (Strich + 3 Schritte).
    private var innerField: CGFloat { diameter - 2 * (stroke + 3 * step) }
    /// "100%" ist etwa 3,3 Schriftgroessen breit und 1,2 hoch; 0,27 * Feld
    /// laesst dem Text im Kreis Rand.
    private var centerFont: CGFloat { innerField * 0.27 }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                let fractions = version.fractions
                ForEach(Array(version.areas.enumerated()), id: \.offset) { index, entry in
                    let inset = stroke / 2 + CGFloat(index) * step
                    ZStack {
                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(Color.white.opacity(0.10),
                                    style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                            .rotationEffect(.degrees(135))
                        Circle()
                            .trim(from: 0, to: 0.75 * fractions[index])
                            .stroke(kiAreaColor(entry.area),
                                    style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                            .rotationEffect(.degrees(135))
                            .animation(.easeOut(duration: 0.4), value: fractions[index])
                    }
                    .padding(inset)
                }
                center
            }
            .frame(width: diameter, height: diameter)
            Text(version.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(EdgeTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(version.total) Issues")
                .font(.system(size: 10))
                .foregroundColor(EdgeTheme.textSecondary)
                .lineLimit(1)
            timeline
        }
    }

    @ViewBuilder private var center: some View {
        if version.allDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: innerField * 0.6))
                .foregroundColor(EdgeTheme.good)
        } else {
            Text(version.scorePercent.map { "\($0)%" } ?? "\(version.total)")
                .font(.system(size: centerFont, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(EdgeTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7) // nur Sicherheitsnetz
                .frame(width: innerField * 0.92)
        }
    }

    // MARK: Zeitstrahl

    private var timeline: some View {
        let t = KIVersionTimeline.make(startDate: version.startDate, releaseDate: version.releaseDate,
                                       released: version.released, today: today)
        return VStack(spacing: 3) {
            timelineBar(t)
                .frame(width: diameter, height: 6)
            HStack(spacing: 4) {
                Text(t.text)
                    .font(.system(size: 11))
                    .foregroundColor(textColor(t.state))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let date = version.releaseDate, let short = Self.shortDate(date) {
                    Text(short)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(EdgeTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: diameter)
        }
    }

    @ViewBuilder private func timelineBar(_ t: KIVersionTimeline) -> some View {
        switch t.state {
        case .noDate:
            Capsule()
                .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        default:
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(barColor(t.state))
                        .frame(width: geo.size.width * fill(t))
                }
            }
        }
    }

    private func fill(_ t: KIVersionTimeline) -> CGFloat {
        switch t.state {
        case .overdue, .released: return 1
        default: return CGFloat(t.elapsed ?? 0)
        }
    }

    private func barColor(_ state: KIVersionTimeline.State) -> Color {
        switch state {
        case .overdue: return EdgeTheme.critical
        case .released: return EdgeTheme.good
        default: return EdgeTheme.highlight
        }
    }

    private func textColor(_ state: KIVersionTimeline.State) -> Color {
        switch state {
        case .overdue: return EdgeTheme.critical
        case .dueToday: return EdgeTheme.warn
        default: return EdgeTheme.textSecondary
        }
    }

    /// "2026-12-15" -> "15.12."
    private static func shortDate(_ iso: String) -> String? {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return "\(day).\(month)."
    }
}
