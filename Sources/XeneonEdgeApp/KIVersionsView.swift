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

/// Alle Versionen nebeneinander, bei Platzmangel umbrechend.
struct KIVersionRingsView: View {
    @EnvironmentObject var model: KIVersionsModel

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.versions.isEmpty {
                if model.errorText == nil {
                    Text("keine laufende Fix-Version")
                        .font(.system(size: 13))
                        .foregroundColor(EdgeTheme.textSecondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(model.versions) { KIVersionRingView(version: $0) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(KIVersionArea.allCases, id: \.self) { area in
                HStack(spacing: 3) {
                    Circle().fill(kiAreaColor(area)).frame(width: 7, height: 7)
                    Text(Self.shortTitle(area))
                        .font(.system(size: 10))
                        .foregroundColor(EdgeTheme.textSecondary)
                }
            }
            Spacer(minLength: 4)
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(EdgeTheme.warn)
                    .lineLimit(1)
            }
            if let stamp = model.lastSuccess {
                Text("Stand \(Self.stampFormat.string(from: stamp))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(EdgeTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private static func shortTitle(_ area: KIVersionArea) -> String {
        switch area {
        case .preparation: return "Vorb."
        case .development: return "Entw."
        case .acceptance: return "Abn."
        case .done: return "Fertig"
        }
    }
}

/// Eine Version: konzentrische 270-Grad-Spuren, je Bereich eine.
struct KIVersionRingView: View {
    let version: KIVersionRing

    private let diameter: CGFloat = 90
    private let stroke: CGFloat = 6
    private let step: CGFloat = 8 // Abstand von Spur zu Spur je Seite

    var body: some View {
        VStack(spacing: 4) {
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
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(EdgeTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var center: some View {
        if version.allDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(EdgeTheme.good)
        } else {
            Text(version.scorePercent.map { "\($0)%" } ?? "\(version.total)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(EdgeTheme.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(width: 30)
        }
    }

    private var detail: String {
        var text = "\(version.total) Issues"
        if let date = version.releaseDate, let short = Self.shortDate(date) {
            text += " · bis \(short)"
        }
        return text
    }

    /// "2026-12-15" -> "15.12."
    private static func shortDate(_ iso: String) -> String? {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return "\(day).\(month)."
    }
}
