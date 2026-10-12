// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct CalendarReminderTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func event(
        _ uid: String,
        in seconds: TimeInterval,
        title: String = "T",
        allDay: Bool = false,
        status: String? = nil,
        declinedBy: Set<String> = []
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(seconds)
        return CalendarEvent(
            uid: uid, title: title, start: start, end: start.addingTimeInterval(1800),
            isAllDay: allDay, status: status, declinedBy: declinedBy
        )
    }

    private static func select(_ events: [CalendarEvent], _ options: ReminderOptions = .init()) -> (reminders: [CalendarReminder], overflow: Int) {
        UpcomingReminders.select(events: events, now: now, options: options)
    }

    @Test func allDayEventIsDropped() {
        #expect(Self.select([Self.event("a", in: 600, allDay: true)]).reminders.isEmpty)
    }

    @Test func leadWindowBoundary() {
        #expect(Self.select([Self.event("a", in: 61 * 60)]).reminders.isEmpty)
        #expect(Self.select([Self.event("a", in: 59 * 60)]).reminders.count == 1)
        #expect(Self.select([Self.event("a", in: 3600)]).reminders.count == 1)
    }

    @Test func threeEventsYieldTwoAndOverflowOne() {
        let r = Self.select([Self.event("a", in: 600), Self.event("b", in: 900), Self.event("c", in: 1200)])
        #expect(r.reminders.map(\.event.uid) == ["a", "b"])
        #expect(r.overflow == 1)
    }

    @Test func negativeMaxRemindersCountsAsZero() {
        let r = Self.select([Self.event("a", in: 600)], ReminderOptions(maxReminders: -3))
        #expect(r.reminders.isEmpty)
        #expect(r.overflow == 1)
    }

    @Test func graceWindow() {
        #expect(Self.select([Self.event("a", in: -60)]).reminders.count == 1)
        #expect(Self.select([Self.event("a", in: -120)]).reminders.count == 1)
        #expect(Self.select([Self.event("a", in: -180)]).reminders.isEmpty)
    }

    @Test func cancelledIsDropped() {
        #expect(Self.select([Self.event("a", in: 600, status: "cancelled")]).reminders.isEmpty)
    }

    @Test func duplicateIdCountsOnce() {
        let e = Self.event("a", in: 600)
        #expect(Self.select([e, e]).reminders.count == 1)
    }

    @Test func sameStartSortsByTitleThenUid() {
        let r = Self.select([
            Self.event("2", in: 600, title: "B"),
            Self.event("1", in: 600, title: "B"),
            Self.event("3", in: 600, title: "A"),
        ], ReminderOptions(maxReminders: 5))
        #expect(r.reminders.map(\.event.uid) == ["3", "1", "2"])
    }

    @Test func stageBoundaries() {
        #expect(ReminderStage(remaining: 1801) == .hour)
        #expect(ReminderStage(remaining: 1800) == .halfHour)
        #expect(ReminderStage(remaining: 901) == .halfHour)
        #expect(ReminderStage(remaining: 900) == .quarter)
        #expect(ReminderStage(remaining: 301) == .quarter)
        #expect(ReminderStage(remaining: 300) == .fiveMinutes)
        #expect(ReminderStage(remaining: 61) == .fiveMinutes)
        #expect(ReminderStage(remaining: 60) == .imminent)
        #expect(ReminderStage(remaining: 59) == .imminent)
    }

    @Test func negativeRemainingIsImminent() {
        #expect(ReminderStage(remaining: -30) == .imminent)
        #expect(Self.select([Self.event("a", in: -30)]).reminders.first?.stage == .imminent)
    }

    @Test func progressBounds() {
        let r = Self.select([Self.event("a", in: 3600), Self.event("b", in: 0)], ReminderOptions(maxReminders: 5))
        #expect(r.reminders[1].progress == 0)
        #expect(r.reminders[0].progress == 1)
        let past = Self.select([Self.event("c", in: -60)]).reminders[0]
        #expect(past.progress == 1)
        let noLead = Self.select([Self.event("d", in: 0)], ReminderOptions(leadMinutes: 0)).reminders[0]
        #expect(noLead.progress == 1)
    }

    @Test func declinedByOwnerIsDroppedOnlyWithOwnerSet() {
        let e = Self.event("a", in: 600, declinedBy: ["me@x.de"])
        #expect(Self.select([e], ReminderOptions(feedOwnerEmail: " Me@X.de ")).reminders.isEmpty)
        #expect(Self.select([e]).reminders.count == 1)
        #expect(Self.select([e], ReminderOptions(feedOwnerEmail: "other@x.de")).reminders.count == 1)
    }

    @Test func parserFillsDeclinedBy() {
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART:20260919T123000Z\nATTENDEE;PARTSTAT=DECLINED;CN=Me:MAILTO:Me@X.DE\nATTENDEE;PARTSTAT=ACCEPTED:mailto:other@x.de\nEND:VEVENT\nEND:VCALENDAR\n"
        let events = ICSParser.parse(ics, defaultTimeZone: TimeZone(identifier: "UTC")!)
        #expect(events.first?.declinedBy == ["me@x.de"])
    }

    @Test func expanderCarriesDeclinedByToInstances() {
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:s\nDTSTART:20260907T100000Z\nDTEND:20260907T110000Z\nRRULE:FREQ=DAILY;COUNT=3\nATTENDEE;PARTSTAT=DECLINED:mailto:me@x.de\nEND:VEVENT\nEND:VCALENDAR\n"
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let master = ICSParser.parse(ics, defaultTimeZone: utc)
        let from = master[0].start.addingTimeInterval(-3600)
        let out = RecurrenceExpander.expand(master, in: from..<from.addingTimeInterval(5 * 86400), calendar: cal)
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.declinedBy == ["me@x.de"] })
    }
}
