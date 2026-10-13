// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Auswahl der anzuzeigenden Termin-Warnungen samt Eskalationsstufe. Reine
// Funktionen; die Uhrzeit wird immer injiziert, keine Farben, kein SwiftUI.

import Foundation

/// Eskalationsstufe nach Restzeit bis zum Terminstart.
public enum ReminderStage: Equatable, Sendable, CaseIterable {
    case hour, halfHour, quarter, fiveMinutes, imminent

    /// Grenzen: ueber 1800 s -> hour, ueber 900 s -> halfHour, ueber 300 s ->
    /// quarter, ueber 60 s -> fiveMinutes, sonst imminent (auch negativ).
    /// Die Kante gehoert zur ruhigeren Stufe.
    public init(remaining: TimeInterval) {
        if remaining > 1800 {
            self = .hour
        } else if remaining > 900 {
            self = .halfHour
        } else if remaining > 300 {
            self = .quarter
        } else if remaining > 60 {
            self = .fiveMinutes
        } else {
            self = .imminent
        }
    }
}

/// Eine anzuzeigende Warnung.
public struct CalendarReminder: Equatable, Identifiable, Sendable {
    public let event: CalendarEvent
    public let remaining: TimeInterval
    public let stage: ReminderStage
    /// 0 bei Restzeit gleich Vorlauf, 1 bei Restzeit 0; auf 0...1 geklemmt.
    public let progress: Double

    public var id: String { event.id }

    public init(event: CalendarEvent, remaining: TimeInterval, stage: ReminderStage, progress: Double) {
        self.event = event
        self.remaining = remaining
        self.stage = stage
        self.progress = progress
    }
}

/// Einstellungen der Auswahl.
public struct ReminderOptions: Equatable, Sendable {
    public var leadMinutes: Double
    public var graceMinutes: Double
    public var maxReminders: Int
    public var feedOwnerEmail: String

    public init(
        leadMinutes: Double = 60,
        graceMinutes: Double = 2,
        maxReminders: Int = 2,
        feedOwnerEmail: String = ""
    ) {
        self.leadMinutes = leadMinutes
        self.graceMinutes = graceMinutes
        self.maxReminders = maxReminders
        self.feedOwnerEmail = feedOwnerEmail
    }
}

public enum UpcomingReminders {
    /// Waehlt aus bereits expandierten Terminen die Warnungen aus. `now` wird
    /// immer injiziert.
    public static func select(
        events: [CalendarEvent],
        now: Date,
        options: ReminderOptions = .init()
    ) -> (reminders: [CalendarReminder], overflow: Int) {
        let lead = options.leadMinutes * 60
        let earliest = now.addingTimeInterval(-options.graceMinutes * 60)
        let latest = now.addingTimeInterval(lead)

        var seen = Set<String>()
        var matching: [CalendarEvent] = []
        for event in candidates(events, options: options) {
            guard event.start >= earliest, event.start <= latest else { continue }
            guard seen.insert(event.id).inserted else { continue }
            matching.append(event)
        }
        matching.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.uid < $1.uid
        }

        let limit = max(0, options.maxReminders)
        let reminders = matching.prefix(limit).map { event -> CalendarReminder in
            let remaining = event.start.timeIntervalSince(now)
            let progress: Double = lead <= 0 ? 1 : min(1, max(0, 1 - remaining / lead))
            return CalendarReminder(
                event: event,
                remaining: remaining,
                stage: ReminderStage(remaining: remaining),
                progress: progress
            )
        }
        return (Array(reminders), matching.count - reminders.count)
    }

    /// Fruehester Termin hinter dem Vorlauf (`start > now + leadMinutes*60`),
    /// bei Gleichstand nach Titel, dann uid. Gleiche Filter wie `select`.
    /// `now` wird immer injiziert.
    public static func next(
        events: [CalendarEvent],
        now: Date,
        options: ReminderOptions = .init()
    ) -> CalendarEvent? {
        let threshold = now.addingTimeInterval(options.leadMinutes * 60)
        return candidates(events, options: options)
            .filter { $0.start > threshold }
            .min {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.title != $1.title { return $0.title < $1.title }
                return $0.uid < $1.uid
            }
    }

    /// Gemeinsame Filter: Ganztag, CANCELLED und vom Feed-Besitzer
    /// abgelehnte Termine fallen raus.
    private static func candidates(_ events: [CalendarEvent], options: ReminderOptions) -> [CalendarEvent] {
        let owner = options.feedOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return events.filter { event in
            if event.isAllDay { return false }
            if event.status == "CANCELLED" { return false }
            if !owner.isEmpty, event.declinedBy.contains(owner) { return false }
            return true
        }
    }
}
