// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Loest Serientermine (RRULE) zu konkreten Einzelterminen in einem Zeitfenster
// auf. Pure Funktion, rechnet ueber Kalenderkomponenten in der Zone der Serie,
// damit die Ortszeit ueber die Zeitumstellung stabil bleibt.

import Foundation

public enum RecurrenceExpander {
    /// Obergrenze an Perioden je Serie ohne COUNT (nach dem Vorsprung).
    private static let maxPeriods = 1000
    /// Obergrenze an Perioden je Serie mit COUNT (kein Vorsprung).
    private static let maxPeriodsWithCount = 10000

    /// Liefert alle Termine, deren Start in `range` liegt, sortiert nach
    /// Start. Serien werden aufgeloest, EXDATE entfernt, RECURRENCE-ID
    /// ersetzt die generierte Instanz.
    public static func expand(
        _ events: [CalendarEvent],
        in range: Range<Date>,
        calendar: Calendar = .current
    ) -> [CalendarEvent] {
        // Ausnahmen: (uid, recurrenceID) unterdrueckt die generierte Instanz.
        var overridden = Set<Override>()
        for event in events {
            if let id = event.recurrenceID { overridden.insert(Override(uid: event.uid, start: id)) }
        }

        var result: [CalendarEvent] = []
        for event in events {
            if let rule = event.recurrence, event.recurrenceID == nil {
                var zoned = calendar
                zoned.timeZone = event.timeZone ?? calendar.timeZone
                let exceptions = Set(event.exceptionDates)
                for start in instanceStarts(of: event, rule: rule, in: range, calendar: zoned) {
                    if exceptions.contains(start) { continue }
                    if overridden.contains(Override(uid: event.uid, start: start)) { continue }
                    result.append(instance(of: event, at: start, calendar: zoned))
                }
            } else if range.contains(event.start) {
                result.append(event)
            }
        }
        return result.sorted { ($0.start, $0.uid) < ($1.start, $1.uid) }
    }

    private struct Override: Hashable {
        let uid: String
        let start: Date
    }

    // MARK: - Instanz

    private static func instance(of master: CalendarEvent, at start: Date, calendar: Calendar) -> CalendarEvent {
        let end: Date
        if master.isAllDay {
            let days = calendar.dateComponents([.day], from: master.start, to: master.end).day ?? 1
            end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(master.end.timeIntervalSince(master.start))
        } else {
            end = start.addingTimeInterval(master.end.timeIntervalSince(master.start))
        }
        return CalendarEvent(
            uid: master.uid,
            title: master.title,
            location: master.location,
            start: start,
            end: end,
            isAllDay: master.isAllDay,
            status: master.status,
            recurrenceID: nil,
            recurrence: nil,
            exceptionDates: [],
            timeZone: master.timeZone
        )
    }

    // MARK: - Kandidaten

    /// Starts aller Instanzen in `range` (vor Ausnahmen), aufsteigend.
    private static func instanceStarts(
        of event: CalendarEvent,
        rule: RecurrenceRule,
        in range: Range<Date>,
        calendar cal: Calendar
    ) -> [Date] {
        let dtstart = event.start
        let anchor = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: dtstart)
        guard let sy = anchor.year, let sm = anchor.month, let sd = anchor.day,
              let hour = anchor.hour, let minute = anchor.minute, let second = anchor.second,
              let sweekday = anchor.weekday else { return [] }
        let interval = max(rule.interval, 1)
        let startOfDay = cal.startOfDay(for: dtstart)

        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var c = DateComponents()
            c.year = y; c.month = m; c.day = d
            c.hour = hour; c.minute = minute; c.second = second
            guard let date = cal.date(from: c) else { return nil }
            let back = cal.dateComponents([.year, .month, .day], from: date)
            guard back.year == y, back.month == m, back.day == d else { return nil }
            return date
        }

        // Montag der Startwoche (Wochenbeginn Montag).
        let mondayOffset = (sweekday + 5) % 7
        let startWeekMonday = cal.date(byAdding: .day, value: -mondayOffset, to: startOfDay) ?? startOfDay

        // Erste Periode: Vorsprung nur ohne COUNT.
        var first = 0
        let hasCount = rule.count != nil
        if !hasCount, range.lowerBound > dtstart {
            let lower = range.lowerBound
            var total = 0
            switch rule.frequency {
            case .daily:
                total = cal.dateComponents([.day], from: startOfDay, to: lower).day ?? 0
            case .weekly:
                total = (cal.dateComponents([.day], from: startWeekMonday, to: lower).day ?? 0) / 7
            case .monthly:
                let l = cal.dateComponents([.year, .month], from: lower)
                total = ((l.year ?? sy) * 12 + (l.month ?? sm)) - (sy * 12 + sm)
            case .yearly:
                total = (cal.component(.year, from: lower)) - sy
            }
            first = max(0, total / interval - 1)
        }
        let limit = first + (hasCount ? maxPeriodsWithCount : maxPeriods)

        var starts: [Date] = []
        var counted = 0
        var n = first
        while n < limit {
            let step = n * interval
            var candidates: [Date] = []
            var periodStart: Date?

            switch rule.frequency {
            case .daily:
                guard let day = cal.date(byAdding: .day, value: step, to: startOfDay) else { return starts }
                periodStart = day
                let c = cal.dateComponents([.year, .month, .day, .weekday], from: day)
                if let y = c.year, let m = c.month, let d = c.day, let wd = c.weekday {
                    let dim = daysInMonth(y, m, cal)
                    let ok = (rule.byMonth.isEmpty || rule.byMonth.contains(m))
                        && (rule.byMonthDay.isEmpty || matchesMonthDay(d, dim, rule.byMonthDay))
                        && (rule.byDay.isEmpty || rule.byDay.contains { $0.weekday == wd })
                    if ok, let date = make(y, m, d) { candidates = [date] }
                }
            case .weekly:
                guard let monday = cal.date(byAdding: .day, value: step * 7, to: startWeekMonday) else { return starts }
                periodStart = monday
                let weekdays = rule.byDay.isEmpty ? [sweekday] : Array(Set(rule.byDay.map(\.weekday)))
                for offset in weekdays.map({ ($0 + 5) % 7 }).sorted() {
                    guard let day = cal.date(byAdding: .day, value: offset, to: monday) else { continue }
                    let c = cal.dateComponents([.year, .month, .day], from: day)
                    guard let y = c.year, let m = c.month, let d = c.day else { continue }
                    if !rule.byMonth.isEmpty, !rule.byMonth.contains(m) { continue }
                    if !rule.byMonthDay.isEmpty, !matchesMonthDay(d, daysInMonth(y, m, cal), rule.byMonthDay) { continue }
                    if let date = make(y, m, d) { candidates.append(date) }
                }
            case .monthly:
                let index = sy * 12 + (sm - 1) + step
                let y = index / 12
                let m = index % 12 + 1
                periodStart = make(y, m, 1)
                if rule.byMonth.isEmpty || rule.byMonth.contains(m) {
                    candidates = monthCandidates(y, m, rule: rule, startDay: sd, cal: cal, make: make)
                }
            case .yearly:
                let y = sy + step
                let months = rule.byMonth.isEmpty ? [sm] : rule.byMonth.sorted()
                periodStart = make(y, 1, 1)
                for m in Set(months).sorted() {
                    candidates += monthCandidates(y, m, rule: rule, startDay: sd, cal: cal, make: make)
                }
            }

            if let periodStart, periodStart >= range.upperBound { break }
            for date in candidates {
                if date < dtstart { continue }
                if date >= range.upperBound { return starts }
                if let until = rule.until, date > until { return starts }
                counted += 1
                if let count = rule.count, counted > count { return starts }
                if range.contains(date) { starts.append(date) }
            }
            n += 1
        }
        return starts
    }

    private static func daysInMonth(_ y: Int, _ m: Int, _ cal: Calendar) -> Int {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = 1
        guard let date = cal.date(from: c), let r = cal.range(of: .day, in: .month, for: date) else { return 31 }
        return r.count
    }

    private static func matchesMonthDay(_ d: Int, _ dim: Int, _ list: [Int]) -> Bool {
        list.contains { $0 > 0 ? $0 == d : dim + 1 + $0 == d }
    }

    /// Kandidaten eines Monats (MONTHLY und je Monat bei YEARLY), aufsteigend.
    private static func monthCandidates(
        _ y: Int, _ m: Int,
        rule: RecurrenceRule,
        startDay: Int,
        cal: Calendar,
        make: (Int, Int, Int) -> Date?
    ) -> [Date] {
        let dim = daysInMonth(y, m, cal)
        var first = DateComponents()
        first.year = y; first.month = m; first.day = 1
        guard let firstDate = cal.date(from: first) else { return [] }
        let firstWeekday = cal.component(.weekday, from: firstDate)

        var days: Set<Int>?
        if !rule.byMonthDay.isEmpty {
            days = Set((1...dim).filter { matchesMonthDay($0, dim, rule.byMonthDay) })
        }
        if !rule.byDay.isEmpty {
            var set = Set<Int>()
            for entry in rule.byDay {
                let firstHit = 1 + (entry.weekday - firstWeekday + 7) % 7
                let hits = Array(stride(from: firstHit, through: dim, by: 7))
                if let ordinal = entry.ordinal {
                    let idx = ordinal > 0 ? ordinal - 1 : hits.count + ordinal
                    if hits.indices.contains(idx) { set.insert(hits[idx]) }
                } else {
                    set.formUnion(hits)
                }
            }
            days = days.map { $0.intersection(set) } ?? set
        }
        let resolved = days ?? (startDay <= dim ? [startDay] : [])
        return resolved.sorted().compactMap { make(y, m, $0) }
    }
}
