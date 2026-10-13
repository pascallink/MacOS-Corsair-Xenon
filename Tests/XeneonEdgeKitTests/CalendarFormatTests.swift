// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct ReminderFormatTests {
    private static let zone = TimeZone(identifier: "Europe/Berlin")!
    /// 2026-10-12 10:00:00 UTC = 12:00 in Berlin (Sommerzeit).
    private static let start = Date(timeIntervalSince1970: 1_791_799_200)

    private static func reminder(remaining: TimeInterval) -> CalendarReminder {
        let event = CalendarEvent(uid: "u", title: "T", start: start,
                                  end: start.addingTimeInterval(1800), isAllDay: false)
        return CalendarReminder(event: event, remaining: remaining,
                                stage: ReminderStage(remaining: remaining), progress: 0.5)
    }

    @Test func countdownFormats() {
        #expect(ReminderFormat.countdown(0) == "00:00")
        #expect(ReminderFormat.countdown(59.2) == "01:00")
        #expect(ReminderFormat.countdown(61) == "01:01")
        #expect(ReminderFormat.countdown(3599) == "59:59")
        #expect(ReminderFormat.countdown(3600) == "1:00:00")
        #expect(ReminderFormat.countdown(3725) == "1:02:05")
        #expect(ReminderFormat.countdown(-5) == "laeuft")
    }

    @Test func clockUsesGivenZone() {
        #expect(ReminderFormat.clock(Self.start, timeZone: Self.zone) == "12:00")
        #expect(ReminderFormat.clock(Self.start, timeZone: TimeZone(identifier: "UTC")!) == "10:00")
    }

    @Test func statusTitleNilBelowQuarter() {
        #expect(ReminderFormat.statusTitle(Self.reminder(remaining: 1200), timeZone: Self.zone) == nil)
        #expect(ReminderFormat.statusTitle(Self.reminder(remaining: 3000), timeZone: Self.zone) == nil)
    }

    @Test func statusTitleRoundsMinutesUp() {
        let title = ReminderFormat.statusTitle(Self.reminder(remaining: 11 * 60 + 30), timeZone: Self.zone)
        #expect(title == "12:00 - 12 min")
    }

    @Test func statusTitleNowAndRunning() {
        #expect(ReminderFormat.statusTitle(Self.reminder(remaining: 30), timeZone: Self.zone) == "12:00 - jetzt")
        #expect(ReminderFormat.statusTitle(Self.reminder(remaining: -10), timeZone: Self.zone) == "12:00 - laeuft")
    }

    // MARK: nextLabel / relative

    /// Mo 2026-10-12 12:00 Berlin als Bezugspunkt (`start`).
    private static func label(daysAhead: Int, hour: Int = 9) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.date(byAdding: .day, value: daysAhead, to: cal.startOfDay(for: start))!
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return ReminderFormat.nextLabel(date, now: start, timeZone: zone)
    }

    @Test func nextLabelTodayTomorrowWeekdayDate() {
        #expect(Self.label(daysAhead: 0, hour: 15) == "15:00")
        #expect(Self.label(daysAhead: 1) == "morgen 09:00")
        #expect(Self.label(daysAhead: 3) == "Do 09:00")
        #expect(Self.label(daysAhead: 6) == "So 09:00")
        #expect(Self.label(daysAhead: 7) == "19.10. 09:00")
        #expect(Self.label(daysAhead: 10) == "22.10. 09:00")
    }

    @Test func relativeFormats() {
        #expect(ReminderFormat.relative(59) == "in 1 min")
        #expect(ReminderFormat.relative(30 * 60) == "in 30 min")
        #expect(ReminderFormat.relative(2 * 3600) == "in 2 h")
        #expect(ReminderFormat.relative(2 * 3600 + 15 * 60) == "in 2 h 15 min")
        #expect(ReminderFormat.relative(86400) == "in 1 Tag")
        #expect(ReminderFormat.relative(3 * 86400 + 5000) == "in 3 Tagen")
    }
}
