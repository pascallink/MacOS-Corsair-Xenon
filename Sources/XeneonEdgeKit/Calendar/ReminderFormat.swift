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

    private static let weekdays = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]

    /// Beschriftung des naechsten Termins: heute "HH:mm", morgen "morgen
    /// HH:mm", bis 6 Tage voraus "Mi 09:00", sonst "dd.MM. HH:mm".
    public static func nextLabel(_ start: Date, now: Date,
                                 timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let time = clock(start, timeZone: timeZone)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: start)).day ?? 0
        switch days {
        case ..<1:
            return time
        case 1:
            return "morgen \(time)"
        case 2...6:
            let index = cal.component(.weekday, from: start) - 1
            return "\(weekdays[index]) \(time)"
        default:
            let day = cal.component(.day, from: start)
            let month = cal.component(.month, from: start)
            return String(format: "%02d.%02d. ", day, month) + time
        }
    }

    /// Restzeit als "in 5 min", "in 2 h 15 min", "in 3 Tagen".
    public static func relative(_ interval: TimeInterval) -> String {
        if interval < 3600 {
            let minutes = max(1, Int((interval / 60).rounded(.up)))
            return "in \(minutes) min"
        }
        if interval < 86400 {
            let total = Int(interval / 60)
            let hours = total / 60
            let minutes = total % 60
            return minutes == 0 ? "in \(hours) h" : "in \(hours) h \(minutes) min"
        }
        let days = Int(interval / 86400)
        return days == 1 ? "in 1 Tag" : "in \(days) Tagen"
    }
}
