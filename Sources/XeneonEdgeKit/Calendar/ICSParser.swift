// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure iCalendar-(ICS-)Auswertung — bewusst frei von Netz- und
// Dateizugriff, damit die Abbildung gegen feste Texte testbar bleibt.

import Foundation

/// Uebersetzt einen rohen ICS-Text in `CalendarEvent`-Werte.
public enum ICSParser {
    /// Eine zerlegte Inhaltszeile: `NAME;PARAM=WERT:Wert`.
    private struct Property {
        let name: String
        let params: [String: String]
        let value: String
    }

    /// Ein aufgeloester Zeitpunkt samt Zone und Ganztags-Kennzeichen.
    private struct Resolved {
        let date: Date
        let zone: TimeZone
        let isAllDay: Bool
    }

    /// Parst einen ICS-Text. Pure und synchron, kein Netz- oder
    /// Dateizugriff. Wirft nie: kaputte oder abgeschnittene Eingabe ergibt
    /// ein leeres Array, ein VEVENT ohne verwertbares DTSTART wird
    /// ausgelassen.
    public static func parse(_ text: String, defaultTimeZone: TimeZone = .current) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var current: [Property]?
        var nestedDepth = 0
        var inTimezone = false
        var unknownZones = Set<String>()

        for line in unfold(text) {
            guard let property = parseLine(line) else { continue }
            let name = property.name
            let value = property.value.uppercased()

            if inTimezone {
                if name == "END", value == "VTIMEZONE" { inTimezone = false }
                continue
            }

            guard current != nil else {
                if name == "BEGIN" {
                    if value == "VTIMEZONE" {
                        inTimezone = true
                    } else if value == "VEVENT" {
                        current = []
                        nestedDepth = 0
                    }
                }
                continue
            }

            // Innerhalb eines VEVENT: verschachtelte Komponenten (VALARM)
            // bis zu ihrem END ueberspringen.
            if nestedDepth > 0 {
                if name == "BEGIN" {
                    nestedDepth += 1
                } else if name == "END" {
                    nestedDepth -= 1
                }
                continue
            }
            if name == "BEGIN", value == "VEVENT" {
                // Vorheriger VEVENT hatte kein END: verwerfen, neu beginnen.
                current = []
            } else if name == "BEGIN" {
                nestedDepth = 1
            } else if name == "END", value == "VEVENT" {
                if let event = makeEvent(current ?? [], defaultTimeZone: defaultTimeZone, unknownZones: &unknownZones) {
                    events.append(event)
                }
                current = nil
            } else {
                current?.append(property)
            }
        }
        for tzid in unknownZones.sorted() {
            NSLog("ICSParser: unbekannte TZID '%@', verwende Standardzone", tzid)
        }
        return events
    }

    // MARK: - Zeilen

    /// Entfaltet Fortsetzungszeilen (Beginn mit Leerzeichen oder Tab).
    private static func unfold(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// Trennt an `separator` ausserhalb doppelter Anfuehrungszeichen;
    /// bei `once` nur am ersten Vorkommen.
    private static func splitOutsideQuotes(_ s: String, separator: Character, once: Bool) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if ch == separator, !quoted, !(once && !parts.isEmpty) {
                parts.append(buffer)
                buffer = ""
            } else {
                buffer.append(ch)
            }
        }
        parts.append(buffer)
        return parts
    }

    private static func parseLine(_ line: String) -> Property? {
        let halves = splitOutsideQuotes(line, separator: ":", once: true)
        guard halves.count == 2 else { return nil }
        let head = splitOutsideQuotes(halves[0], separator: ";", once: false)
        guard let rawName = head.first else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty else { return nil }

        var params: [String: String] = [:]
        for part in head.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            var val = String(part[part.index(after: eq)...])
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return Property(name: name, params: params, value: halves[1])
    }

    /// Entmaskiert TEXT-Werte: `\n`/`\N`, `\,`, `\;`, `\\`.
    private static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "n", "N": out.append("\n")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: - Termin

    private static func makeEvent(
        _ props: [Property],
        defaultTimeZone: TimeZone,
        unknownZones: inout Set<String>
    ) -> CalendarEvent? {
        func first(_ name: String) -> Property? { props.first { $0.name == name } }

        guard let startProp = first("DTSTART"),
              let start = resolve(startProp, defaultTimeZone: defaultTimeZone, unknownZones: &unknownZones) else { return nil }

        var end: Date?
        if let endProp = first("DTEND") {
            end = resolve(endProp, defaultTimeZone: defaultTimeZone, unknownZones: &unknownZones)?.date
        }
        if end == nil, let durationProp = first("DURATION") {
            end = addDuration(durationProp.value, to: start)
        }
        let resolvedEnd: Date
        if let end {
            resolvedEnd = end
        } else if start.isAllDay {
            resolvedEnd = shift(start, day: 1) ?? start.date
        } else {
            resolvedEnd = start.date
        }

        var recurrence: Date?
        if let recProp = first("RECURRENCE-ID") {
            recurrence = resolve(recProp, defaultTimeZone: defaultTimeZone, unknownZones: &unknownZones)?.date
        }
        var exceptionDates: [Date] = []
        for prop in props where prop.name == "EXDATE" {
            for part in prop.value.split(separator: ",", omittingEmptySubsequences: true) {
                let single = Property(name: prop.name, params: prop.params, value: String(part))
                if let date = resolve(single, defaultTimeZone: defaultTimeZone, unknownZones: &unknownZones)?.date {
                    exceptionDates.append(date)
                }
            }
        }
        let rule = first("RRULE").flatMap { parseRule($0.value, start: start) }
        return CalendarEvent(
            uid: first("UID")?.value ?? "",
            title: first("SUMMARY").map { unescape($0.value) } ?? "",
            location: first("LOCATION").map { unescape($0.value) },
            start: start.date,
            end: resolvedEnd,
            isAllDay: start.isAllDay,
            status: first("STATUS")?.value.trimmingCharacters(in: .whitespaces),
            recurrenceID: recurrence,
            recurrence: rule,
            exceptionDates: exceptionDates,
            timeZone: start.zone
        )
    }

    // MARK: - Wiederholung

    private static let weekdayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// Wertet eine RRULE aus. nil bei Regeln, die hier nicht korrekt
    /// ausgewertet werden koennen: der Termin bleibt dann ein Einzeltermin,
    /// statt Phantom-Instanzen zu erzeugen.
    private static func parseRule(_ raw: String, start: Resolved) -> RecurrenceRule? {
        var frequency: RecurrenceRule.Frequency?
        var interval = 1
        var count: Int?
        var until: Date?
        var byDay: [WeekdayRule] = []
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []

        for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces).uppercased()
            let items = value.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
            switch key {
            case "FREQ":
                switch value {
                case "DAILY": frequency = .daily
                case "WEEKLY": frequency = .weekly
                case "MONTHLY": frequency = .monthly
                case "YEARLY": frequency = .yearly
                default: return nil
                }
            case "INTERVAL":
                guard let n = Int(value), n >= 1 else { return nil }
                interval = n
            case "COUNT":
                guard let n = Int(value), n >= 1 else { return nil }
                count = n
            case "UNTIL":
                // Zone des DTSTART gilt fuer Werte ohne Z; reines Datum
                // zaehlt bis zum Ende des Tages.
                let single = Property(name: "UNTIL", params: [:], value: value)
                var ignored = Set<String>()
                guard let resolved = resolve(single, defaultTimeZone: start.zone, unknownZones: &ignored) else { return nil }
                if resolved.isAllDay {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = resolved.zone
                    guard let next = calendar.date(byAdding: .day, value: 1, to: resolved.date) else { return nil }
                    until = next.addingTimeInterval(-1)
                } else {
                    until = resolved.date
                }
            case "BYDAY":
                guard !items.isEmpty else { return nil }
                for item in items {
                    guard let rule = parseWeekday(item) else { return nil }
                    byDay.append(rule)
                }
            case "BYMONTHDAY":
                guard !items.isEmpty else { return nil }
                for item in items {
                    guard let n = Int(item), n != 0, (-31...31).contains(n) else { return nil }
                    byMonthDay.append(n)
                }
            case "BYMONTH":
                guard !items.isEmpty else { return nil }
                for item in items {
                    guard let n = Int(item), (1...12).contains(n) else { return nil }
                    byMonth.append(n)
                }
            case "WKST":
                continue
            default:
                // BYSETPOS, BYWEEKNO, BYYEARDAY, BYHOUR, BYMINUTE, BYSECOND
                // und alles Unbekannte: nicht auswertbar.
                return nil
            }
        }
        guard let frequency else { return nil }
        let hasOrdinal = byDay.contains { $0.ordinal != nil }
        switch frequency {
        case .daily, .weekly:
            if hasOrdinal { return nil }
        case .monthly:
            break
        case .yearly:
            // Ohne BYMONTH waeren BYDAY/BYMONTHDAY ueber das ganze Jahr
            // zu lesen; das wird nicht ausgewertet.
            if byMonth.isEmpty, !byDay.isEmpty || !byMonthDay.isEmpty { return nil }
        }
        return RecurrenceRule(
            frequency: frequency, interval: interval, count: count, until: until,
            byDay: byDay, byMonthDay: byMonthDay, byMonth: byMonth
        )
    }

    /// `MO`, `2TU`, `-1FR`, `+1SU`.
    private static func parseWeekday(_ item: String) -> WeekdayRule? {
        guard item.count >= 2 else { return nil }
        guard let weekday = weekdayCodes[String(item.suffix(2))] else { return nil }
        let prefix = String(item.dropLast(2))
        if prefix.isEmpty { return WeekdayRule(weekday: weekday) }
        guard let n = Int(prefix), n != 0, (-53...53).contains(n) else { return nil }
        return WeekdayRule(weekday: weekday, ordinal: n)
    }

    // MARK: - Zeitpunkte

    private static func resolve(
        _ property: Property,
        defaultTimeZone: TimeZone,
        unknownZones: inout Set<String>
    ) -> Resolved? {
        let value = property.value.trimmingCharacters(in: .whitespaces).uppercased()
        let isUTC = value.hasSuffix("Z")
        let digits = isUTC ? String(value.dropLast()) : value

        let chars = Array(digits)
        let allDay: Bool
        switch chars.count {
        case 8: allDay = true
        case 15 where chars[8] == "T": allDay = false
        default: return nil
        }

        // Reine Datumswerte: Mitternacht in defaultTimeZone, TZID/Z ignoriert.
        var zone = defaultTimeZone
        if !allDay {
            if isUTC {
                guard let utc = TimeZone(identifier: "UTC") else { return nil }
                zone = utc
            } else if let tzid = property.params["TZID"] {
                if let known = TimeZone(identifier: tzid) {
                    zone = known
                } else {
                    unknownZones.insert(tzid)
                }
            }
        }
        let numeric = chars.enumerated().filter { !(!allDay && $0.offset == 8) }.map(\.element)
        guard numeric.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        func number(_ range: Range<Int>) -> Int { Int(String(numeric[range])) ?? 0 }

        var comps = DateComponents()
        comps.year = number(0..<4)
        comps.month = number(4..<6)
        comps.day = number(6..<8)
        if !allDay {
            comps.hour = number(8..<10)
            comps.minute = number(10..<12)
            comps.second = number(12..<14)
        }
        guard (1...12).contains(comps.month ?? 0), (1...31).contains(comps.day ?? 0),
              (0...23).contains(comps.hour ?? 0), (0...59).contains(comps.minute ?? 0),
              (0...59).contains(comps.second ?? 0) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: comps) else { return nil }
        // Rundlauf-Pruefung: faengt z. B. den 30. Februar ab.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == comps.year, back.month == comps.month, back.day == comps.day else { return nil }

        let dateOnly = allDay || property.params["VALUE"]?.uppercased() == "DATE"
        return Resolved(date: date, zone: zone, isAllDay: dateOnly && allDay)
    }

    private static func shift(_ start: Resolved, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = start.zone
        return calendar.date(byAdding: .day, value: day, to: start.date)
    }

    /// Addiert eine ISO-8601-Dauer (`PT1H30M`, `P1D`, `P1W`, `P1DT2H`).
    /// Unlesbare Dauer ergibt nil.
    private static func addDuration(_ raw: String, to start: Resolved) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()

        var parts = DateComponents()
        var number = ""
        var inTime = false
        var seen = false
        for ch in text {
            if ch == "T" {
                guard !inTime, number.isEmpty else { return nil }
                inTime = true
            } else if ch.isASCII && ch.isNumber {
                number.append(ch)
            } else {
                guard let n = Int(number) else { return nil }
                number = ""
                seen = true
                switch (ch, inTime) {
                case ("W", false): parts.day = (parts.day ?? 0) + 7 * n
                case ("D", false): parts.day = (parts.day ?? 0) + n
                case ("H", true): parts.hour = n
                case ("M", true): parts.minute = n
                case ("S", true): parts.second = n
                default: return nil
                }
            }
        }
        guard number.isEmpty, seen else { return nil }

        if sign < 0 {
            parts.day = parts.day.map { -$0 }
            parts.hour = parts.hour.map { -$0 }
            parts.minute = parts.minute.map { -$0 }
            parts.second = parts.second.map { -$0 }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = start.zone
        return calendar.date(byAdding: parts, to: start.date)
    }
}
