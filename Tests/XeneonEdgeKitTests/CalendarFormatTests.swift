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
}
