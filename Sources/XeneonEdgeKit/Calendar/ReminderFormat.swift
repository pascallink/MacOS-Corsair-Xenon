// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Textformate der Termin-Warnungen, geteilt von Dashboard-Panel, Widget-Karte
// und Menueleisten-Titel.

import Foundation

public enum ReminderFormat {
    /// mm:ss unter einer Stunde, h:mm:ss ab einer Stunde, "laeuft" bei
    /// negativer Restzeit. Sekunden werden aufgerundet.
    public static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining >= 0 else { return "laeuft" }
        let total = Int(remaining.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Uhrzeit als HH:mm (24 h, POSIX-Locale).
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Titel fuer die Menueleiste: erst ab Stufe .quarter, sonst nil.
    public static func statusTitle(_ reminder: CalendarReminder,
                                   timeZone: TimeZone = .current) -> String? {
        guard let index = ReminderStage.allCases.firstIndex(of: reminder.stage),
              let quarter = ReminderStage.allCases.firstIndex(of: .quarter),
              index >= quarter
        else { return nil }
        let time = clock(reminder.event.start, timeZone: timeZone)
        if reminder.remaining < 0 { return "\(time) - laeuft" }
        if reminder.remaining < 60 { return "\(time) - jetzt" }
        let minutes = Int((reminder.remaining / 60).rounded(.up))
        return "\(time) - \(minutes) min"
    }
}
