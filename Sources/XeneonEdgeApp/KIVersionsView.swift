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

    private static let legendHeight: CGFloat = 20
    private static let legendGap: CGFloat = 8
    private static let rowGap: CGFloat = 10
    private static let cellGap: CGFloat = 32
    private static let minDiameter: CGFloat = 40
    private static let maxDiameter: CGFloat = 400
    /// Abstand zwischen Ring und Beschriftung rechts daneben.
    static let captionGap: CGFloat = 14
    /// Beschriftung rechts: 170 pt beim Schriftfaktor 1, waechst mit der
    /// Schrift, damit "12 Tage ueberfaellig" samt Datum auch gross passt.
    static func captionWidth(diameter: CGFloat) -> CGFloat {
        170 * captionScale(diameter: diameter)
    }

    /// Schriftfaktor der Beschriftung: ab 140 pt Ring waechst sie mit, damit
    /// sie neben grossen Ringen lesbar bleibt, hoechstens auf das 1,8-Fache.
    static func captionScale(diameter: CGFloat) -> CGFloat {
        min(max(diameter / 140, 1), 1.8)
    }

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

    /// Ringdurchmesser: der kleinere Wert aus Reihenhoehe (die Beschriftung
    /// steht neben dem Ring) und Zellbreite der vollsten Reihe abzueglich
    /// Beschriftung, begrenzt.
    static func diameter(size: CGSize, rows: [Int]) -> CGFloat {
        guard !rows.isEmpty else { return minDiameter }
        let count = CGFloat(rows.count)
        let byHeight = (size.height - rowGap * (count - 1)) / count
        let widest = CGFloat(rows.max() ?? 1)
        let cell = (size.width - cellGap * (widest - 1)) / widest
        // Groesster Ring, bei dem Ring + Abstand + Beschriftung in die Zelle
        // passen. Die Beschriftung waechst mit dem Ring, daher Bisektion; die
        // Bedingung ist monoton steigend im Durchmesser.
        func fits(_ d: CGFloat) -> Bool { d + captionGap + captionWidth(diameter: d) <= cell }
        var low: CGFloat = 0
        var high = max(0, min(byHeight, maxDiameter))
        if fits(high) {
            low = high
        } else {
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if fits(mid) { low = mid } else { high = mid }
            }
        }
        // Unter dem Minimum schrumpft die Beschriftung mit der Zelle, statt
        // den Ring weiter zu verkleinern.
        return min(max(low, minDiameter), maxDiameter)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(KIVersionArea.allCases, id: \.self) { area in
                HStack(spacing: 4) {
                    Circle().fill(kiAreaColor(area)).frame(width: 10, height: 10)
                    Text(Self.title(area))
                        .font(.system(size: 13))
                        .foregroundColor(EdgeTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(EdgeTheme.warn)
                    .lineLimit(1)
            }
            if let stamp = model.lastSuccess {
                Text("Stand \(Self.stampFormat.string(from: stamp))")
                    .font(.system(size: 13))
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

/// Eine Version: konzentrische 270-Grad-Spuren, je Bereich eine, rechts
/// daneben Label, Issues und Zeitstrahl. Alle Masse leiten sich aus `diameter` ab.
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
    /// Schriftfaktor der Beschriftung, gleich dem in `captionWidth`.
    private var scale: CGFloat { KIVersionRingsView.captionScale(diameter: diameter) }

    var body: some View {
        HStack(alignment: .center, spacing: KIVersionRingsView.captionGap) {
            ring
            VStack(alignment: .leading, spacing: 6 * scale) {
                Text(version.label)
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .foregroundColor(EdgeTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(version.total) Issues")
                    .font(.system(size: 11 * scale))
                    .foregroundColor(EdgeTheme.textSecondary)
                    .lineLimit(1)
                timeline
            }
            // Hoechstens die berechnete Breite; ist die Zelle schmaler (Ring am
            // Minimum), schrumpft die Spalte und ueberdeckt keine Nachbarzelle.
            .frame(maxWidth: KIVersionRingsView.captionWidth(diameter: diameter), alignment: .leading)
        }
    }

    private var ring: some View {
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
        return VStack(spacing: 4 * scale) {
            timelineBar(t)
                .frame(height: 6 * scale)
            // Ohne Verkleinern der Schrift: passt die Zeile samt Datum nicht in
            // die Spalte, entfaellt das Datum.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    daysText(t)
                    Spacer(minLength: 8)
                    if let date = version.releaseDate, let short = Self.shortDate(date) {
                        Text(short)
                            .font(.system(size: 11 * scale))
                            .monospacedDigit()
                            .foregroundColor(EdgeTheme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                daysText(t)
            }
        }
    }

    private func daysText(_ t: KIVersionTimeline) -> some View {
        Text(t.text)
            .font(.system(size: 12 * scale))
            .foregroundColor(textColor(t.state))
            .lineLimit(1)
            .fixedSize()
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
