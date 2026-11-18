// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Zeitstrahl einer Version: restliche Tage bis zur Lieferung und verstrichener
// Anteil seit dem Start. Reines Regelwerk, ohne I/O.

import Foundation

public struct KIVersionTimeline: Equatable {
    public enum State: Equatable { case running, dueToday, overdue, released, noDate }

    public var state: State
    /// Kalendertage bis zur Lieferung (heute -> Lieferdatum), negativ bei Verzug; nil ohne Lieferdatum.
    public var daysLeft: Int?
    /// Verstrichener Anteil von Start bis Lieferung, 0...1; nil ohne Start- oder Lieferdatum.
    public var elapsed: Double?
    /// Kurzer Text fuer die UI, Deutsch ohne Umlaute.
    public var text: String

    public static func make(startDate: String?, releaseDate: String?, released: Bool,
                            today: Date, calendar: Calendar = .current) -> KIVersionTimeline {
        let todayStart = calendar.startOfDay(for: today)
        let start = startDate.flatMap { day($0, calendar) }
        let release = releaseDate.flatMap { day($0, calendar) }

        func days(_ from: Date, _ to: Date) -> Int? {
            calendar.dateComponents([.day], from: from, to: to).day
        }

        let daysLeft = release.flatMap { days(todayStart, $0) }

        var elapsed: Double?
        if let start, let release, let total = days(start, release), total > 0,
           let passed = days(start, todayStart) {
            elapsed = min(1, max(0, Double(passed) / Double(total)))
        }

        if released {
            let both = start != nil && release != nil
            return KIVersionTimeline(state: .released, daysLeft: daysLeft,
                                     elapsed: both ? 1 : nil, text: "geliefert")
        }
        guard let left = daysLeft else {
            return KIVersionTimeline(state: .noDate, daysLeft: nil, elapsed: nil,
                                     text: "ohne Lieferdatum")
        }
        if left > 0 {
            return KIVersionTimeline(state: .running, daysLeft: left, elapsed: elapsed,
                                     text: left == 1 ? "noch 1 Tag" : "noch \(left) Tage")
        }
        if left == 0 {
            return KIVersionTimeline(state: .dueToday, daysLeft: 0, elapsed: elapsed,
                                     text: "Lieferung heute")
        }
        let late = -left
        return KIVersionTimeline(state: .overdue, daysLeft: left, elapsed: elapsed,
                                 text: late == 1 ? "1 Tag ueberfaellig" : "\(late) Tage ueberfaellig")
    }

    /// JJJJ-MM-TT als Ortsdatum (Tagesbeginn) im Kalender; nil bei ungueltigem Datum.
    private static func day(_ string: String, _ calendar: Calendar) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return calendar.startOfDay(for: date)
    }
}
