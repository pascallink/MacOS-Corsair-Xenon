// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Terminmodell fuer das Kalender-Widget. Reine Werttypen ohne Netz- oder
// Geraetebezug.

import Foundation

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
        recurrenceID: Date? = nil
    ) {
        self.uid = uid
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.status = status?.uppercased()
        self.recurrenceID = recurrenceID
    }
}
