// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Terminmodell fuer das Kalender-Widget. Reine Werttypen ohne Netz- oder
// Geraetebezug.

import Foundation

/// Ein Wochentag einer Wiederholungsregel, optional mit Ordinalzahl.
public struct WeekdayRule: Equatable, Sendable {
    /// 1 = Sonntag bis 7 = Samstag, wie `Calendar.component(.weekday, ...)`.
    public let weekday: Int
    /// `2TU` -> 2, `-1FR` -> -1, `MO` -> nil.
    public let ordinal: Int?

    public init(weekday: Int, ordinal: Int? = nil) {
        self.weekday = weekday
        self.ordinal = ordinal
    }
}

/// Eine ausgewertete RRULE. Nur Teile, die der Expander versteht; alles
/// andere fuehrt im Parser zu `recurrence = nil`.
public struct RecurrenceRule: Equatable, Sendable {
    public enum Frequency: Equatable, Sendable {
        case daily, weekly, monthly, yearly
    }

    public let frequency: Frequency
    public let interval: Int
    public let count: Int?
    public let until: Date?
    public let byDay: [WeekdayRule]
    public let byMonthDay: [Int]
    public let byMonth: [Int]

    public init(
        frequency: Frequency,
        interval: Int = 1,
        count: Int? = nil,
        until: Date? = nil,
        byDay: [WeekdayRule] = [],
        byMonthDay: [Int] = [],
        byMonth: [Int] = []
    ) {
        self.frequency = frequency
        self.interval = interval
        self.count = count
        self.until = until
        self.byDay = byDay
        self.byMonthDay = byMonthDay
        self.byMonth = byMonth
    }
}

/// Ein einzelner Termin aus einem iCalendar-Feed mit aufgeloester Start-
/// und Endzeit.
public struct CalendarEvent: Equatable, Identifiable, Sendable {
    public let uid: String
    public let title: String
    public let location: String?
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Roher Statuswert aus dem Feed (z. B. "CONFIRMED", "CANCELLED"),
    /// per `uppercased()` normalisiert.
    public let status: String?
    public let recurrenceID: Date?
    /// Wiederholungsregel des Mastertermins, nil bei Einzelterminen.
    public let recurrence: RecurrenceRule?
    /// Ausgenommene Instanzen (EXDATE) als Startzeitpunkte.
    public let exceptionDates: [Date]
    /// Zone des DTSTART (UTC bei `Z`, TZID-Zone, sonst Standardzone).
    public let timeZone: TimeZone?

    /// `uid` plus Startzeitpunkt: die `uid` allein wiederholt sich bei
    /// Serieninstanzen.
    public var id: String {
        "\(uid)|\(start.timeIntervalSince1970)"
    }

    public init(
        uid: String,
        title: String,
        location: String? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        status: String? = nil,
        recurrenceID: Date? = nil,
        recurrence: RecurrenceRule? = nil,
        exceptionDates: [Date] = [],
        timeZone: TimeZone? = nil
    ) {
        self.uid = uid
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.status = status?.uppercased()
        self.recurrenceID = recurrenceID
        self.recurrence = recurrence
        self.exceptionDates = exceptionDates
        self.timeZone = timeZone
    }
}
