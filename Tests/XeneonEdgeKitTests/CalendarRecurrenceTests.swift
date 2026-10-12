// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct RecurrenceExpanderTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let utc = TimeZone(identifier: "UTC")!

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, zone: TimeZone = berlin) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private static func events(_ body: String) -> [CalendarEvent] {
        ICSParser.parse("BEGIN:VCALENDAR\n\(body)\nEND:VCALENDAR\n", defaultTimeZone: utc)
    }

    private static func expand(_ body: String, _ from: Date, _ to: Date) -> [CalendarEvent] {
        RecurrenceExpander.expand(events(body), in: from..<to, calendar: cal)
    }

    /// Einzelnes VEVENT ab Montag 2026-09-07 10:00 Berlin.
    private static func series(_ rrule: String, extra: String = "") -> String {
        "BEGIN:VEVENT\nUID:s\nDTSTART;TZID=Europe/Berlin:20260907T100000\nDTEND;TZID=Europe/Berlin:20260907T110000\nRRULE:\(rrule)\n\(extra)\nEND:VEVENT"
    }

    private static func days(_ events: [CalendarEvent]) -> [Int] {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = berlin
        return events.map { c.component(.day, from: $0.start) }
    }

    // MARK: - Expander

    @Test func weeklyByDayHitsOnlyMondayAndWednesday() {
        let r = Self.expand(Self.series("FREQ=WEEKLY;BYDAY=MO,WE"), Self.date(2026, 9, 7), Self.date(2026, 9, 21))
        #expect(Self.days(r) == [7, 9, 14, 16])
    }

    @Test func intervalTwoSkipsEveryOtherWeek() {
        let r = Self.expand(Self.series("FREQ=WEEKLY;INTERVAL=2"), Self.date(2026, 9, 1), Self.date(2026, 10, 15))
        #expect(Self.days(r) == [7, 21, 5])
    }

    @Test func countThreeEndsAfterThreeInstances() {
        let r = Self.expand(Self.series("FREQ=DAILY;COUNT=3"), Self.date(2026, 9, 1), Self.date(2026, 12, 1))
        #expect(Self.days(r) == [7, 8, 9])
    }

    @Test func countIncludesInstancesBeforeWindow() {
        let r = Self.expand(Self.series("FREQ=DAILY;COUNT=3"), Self.date(2026, 9, 9), Self.date(2026, 12, 1))
        #expect(Self.days(r) == [9])
    }

    @Test func untilInThePastYieldsNothing() {
        let r = Self.expand(Self.series("FREQ=DAILY;UNTIL=20260801T000000Z"), Self.date(2026, 9, 1), Self.date(2026, 9, 30))
        #expect(r.isEmpty)
    }

    @Test func dateOnlyUntilIncludesThatDay() {
        let r = Self.expand(Self.series("FREQ=DAILY;UNTIL=20260909"), Self.date(2026, 9, 1), Self.date(2026, 9, 30))
        #expect(Self.days(r) == [7, 8, 9])
    }

    @Test func exdateWithTwoValuesRemovesExactlyThose() {
        let r = Self.expand(
            Self.series("FREQ=DAILY;COUNT=5", extra: "EXDATE;TZID=Europe/Berlin:20260908T100000,20260910T100000"),
            Self.date(2026, 9, 1), Self.date(2026, 9, 30)
        )
        #expect(Self.days(r) == [7, 9, 11])
    }

    @Test func recurrenceIDReplacesInsteadOfDoubling() {
        let ics = Self.series("FREQ=DAILY;COUNT=3") + "\n" + """
        BEGIN:VEVENT
        UID:s
        DTSTART;TZID=Europe/Berlin:20260908T150000
        DTEND;TZID=Europe/Berlin:20260908T160000
        RECURRENCE-ID;TZID=Europe/Berlin:20260908T100000
        SUMMARY:Verlegt
        END:VEVENT
        """
        let r = Self.expand(ics, Self.date(2026, 9, 1), Self.date(2026, 9, 30))
        #expect(r.count == 3)
        #expect(r.filter { $0.title == "Verlegt" }.count == 1)
        #expect(r[1].start == Self.date(2026, 9, 8, 15))
    }

    @Test func recurrenceIDMovedOutOfWindowSuppressesInstance() {
        let ics = Self.series("FREQ=DAILY;COUNT=3") + "\n" + """
        BEGIN:VEVENT
        UID:s
        DTSTART;TZID=Europe/Berlin:20261001T150000
        DTEND;TZID=Europe/Berlin:20261001T160000
        RECURRENCE-ID;TZID=Europe/Berlin:20260908T100000
        END:VEVENT
        """
        let r = Self.expand(ics, Self.date(2026, 9, 1), Self.date(2026, 9, 30))
        #expect(Self.days(r) == [7, 9])
    }

    @Test func openEndedSeriesYieldsExactlyTheInstancesInTwoHourWindow() {
        let ics = Self.series("FREQ=HOURLY") // nicht unterstuetzt -> Einzeltermin
        #expect(Self.expand(ics, Self.date(2026, 9, 7, 9), Self.date(2026, 9, 7, 11)).count == 1)

        let daily = Self.series("FREQ=DAILY")
        let r = Self.expand(daily, Self.date(2026, 9, 20, 9), Self.date(2026, 9, 20, 11))
        #expect(r.count == 1)
        #expect(r[0].start == Self.date(2026, 9, 20, 10))
        #expect(r[0].end == Self.date(2026, 9, 20, 11))
        #expect(Self.expand(daily, Self.date(2026, 9, 20, 11), Self.date(2026, 9, 20, 13)).isEmpty)
    }

    @Test func dailySeriesFromThreeYearsAgoReachesToday() {
        let ics = "BEGIN:VEVENT\nUID:old\nDTSTART:20230901T080000Z\nDTEND:20230901T090000Z\nRRULE:FREQ=DAILY\nEND:VEVENT"
        let r = Self.expand(ics, Self.date(2026, 10, 12, zone: Self.utc), Self.date(2026, 10, 13, zone: Self.utc))
        #expect(r.count == 1)
        #expect(r[0].start == Self.date(2026, 10, 12, 8, zone: Self.utc))
    }

    @Test func dailySeriesKeepsLocalTimeAcrossDaylightSaving() {
        // Zeitumstellung 2026-10-25 (Berlin).
        let r = Self.expand(Self.series("FREQ=DAILY"), Self.date(2026, 10, 23), Self.date(2026, 10, 28))
        #expect(r.count == 5)
        for e in r {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = Self.berlin
            #expect(c.component(.hour, from: e.start) == 10)
        }
    }

    @Test func monthlySecondTuesday() {
        let ics = "BEGIN:VEVENT\nUID:m\nDTSTART;TZID=Europe/Berlin:20260908T100000\nDTEND;TZID=Europe/Berlin:20260908T110000\nRRULE:FREQ=MONTHLY;BYDAY=2TU\nEND:VEVENT"
        let r = Self.expand(ics, Self.date(2026, 9, 1), Self.date(2026, 12, 31))
        #expect(Self.days(r) == [8, 13, 10, 8])
    }

    @Test func monthlyOnThirtyFirstSkipsShortMonths() {
        let ics = "BEGIN:VEVENT\nUID:m\nDTSTART;TZID=Europe/Berlin:20260731T100000\nDTEND;TZID=Europe/Berlin:20260731T110000\nRRULE:FREQ=MONTHLY\nEND:VEVENT"
        let r = Self.expand(ics, Self.date(2026, 7, 1), Self.date(2027, 1, 1))
        #expect(Self.days(r) == [31, 31, 31, 31])
    }

    @Test func monthlyLastDayViaNegativeMonthDay() {
        let ics = "BEGIN:VEVENT\nUID:m\nDTSTART;TZID=Europe/Berlin:20260930T100000\nDTEND;TZID=Europe/Berlin:20260930T110000\nRRULE:FREQ=MONTHLY;BYMONTHDAY=-1\nEND:VEVENT"
        let r = Self.expand(ics, Self.date(2026, 9, 1), Self.date(2027, 1, 1))
        #expect(Self.days(r) == [30, 31, 30, 31])
    }

    @Test func yearlyWithByMonthAndOrdinalWeekday() {
        let ics = "BEGIN:VEVENT\nUID:y\nDTSTART;TZID=Europe/Berlin:20261126T100000\nDTEND;TZID=Europe/Berlin:20261126T110000\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=-1TH\nEND:VEVENT"
        let r = Self.expand(ics, Self.date(2026, 1, 1), Self.date(2028, 1, 1))
        #expect(Self.days(r) == [26, 25])
    }

    @Test func allDaySeriesKeepsDayDuration() {
        let ics = "BEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260907\nDTEND;VALUE=DATE:20260909\nRRULE:FREQ=WEEKLY;COUNT=2\nEND:VEVENT"
        let r = Self.expand(ics, Self.date(2026, 9, 1, zone: Self.utc), Self.date(2026, 10, 1, zone: Self.utc))
        #expect(r.count == 2)
        #expect(r[1].start == Self.date(2026, 9, 14, zone: Self.utc))
        #expect(r[1].end == Self.date(2026, 9, 16, zone: Self.utc))
        #expect(r[1].isAllDay)
    }

    @Test func singleEventsPassThroughOnlyInsideWindow() {
        let ics = "BEGIN:VEVENT\nUID:e\nDTSTART:20260910T080000Z\nDTEND:20260910T090000Z\nEND:VEVENT"
        #expect(Self.expand(ics, Self.date(2026, 9, 10, zone: Self.utc), Self.date(2026, 9, 11, zone: Self.utc)).count == 1)
        #expect(Self.expand(ics, Self.date(2026, 9, 11, zone: Self.utc), Self.date(2026, 9, 12, zone: Self.utc)).isEmpty)
    }

    @Test func instancesHaveDistinctIDsAndNoRecurrence() {
        let r = Self.expand(Self.series("FREQ=DAILY;COUNT=3"), Self.date(2026, 9, 1), Self.date(2026, 9, 30))
        #expect(Set(r.map(\.id)).count == 3)
        #expect(r.allSatisfy { $0.recurrence == nil && $0.recurrenceID == nil && $0.uid == "s" })
    }

    // MARK: - Parser

    @Test func parserReadsRuleParts() {
        let e = Self.events(Self.series("FREQ=MONTHLY;INTERVAL=2;COUNT=4;BYDAY=2TU,-1FR,MO;BYMONTH=1,2;WKST=SU"))[0]
        #expect(e.recurrence == RecurrenceRule(
            frequency: .monthly, interval: 2, count: 4, until: nil,
            byDay: [WeekdayRule(weekday: 3, ordinal: 2), WeekdayRule(weekday: 6, ordinal: -1), WeekdayRule(weekday: 2)],
            byMonthDay: [], byMonth: [1, 2]
        ))
        #expect(e.timeZone == Self.berlin)
    }

    @Test func parserCollectsAllExdates() {
        let e = Self.events(Self.series(
            "FREQ=DAILY",
            extra: "EXDATE;TZID=Europe/Berlin:20260908T100000,20260909T100000\nEXDATE:20260910T080000Z"
        ))[0]
        #expect(e.exceptionDates == [Self.date(2026, 9, 8, 10), Self.date(2026, 9, 9, 10), Self.date(2026, 9, 10, 10)])
    }

    @Test func parserReadsUntilAsUTCAndDateOnlyAsEndOfDay() {
        let a = Self.events(Self.series("FREQ=DAILY;UNTIL=20260920T080000Z"))[0]
        #expect(a.recurrence?.until == Self.date(2026, 9, 20, 8, zone: Self.utc))
        let b = Self.events(Self.series("FREQ=DAILY;UNTIL=20260920"))[0]
        #expect(b.recurrence?.until == Self.date(2026, 9, 21).addingTimeInterval(-1))
    }

    @Test func unsupportedRulesBecomeSingleEvents() {
        for rule in [
            "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1", "FREQ=YEARLY;BYWEEKNO=20", "FREQ=DAILY;BYHOUR=9",
            "FREQ=SECONDLY", "FREQ=DAILY;INTERVAL=0", "FREQ=WEEKLY;BYDAY=2TU", "FREQ=DAILY;BYDAY=-1FR",
            "FREQ=YEARLY;BYDAY=MO",
        ] {
            let parsed = Self.events(Self.series(rule))
            #expect(parsed.count == 1, "\(rule)")
            #expect(parsed.first?.recurrence == nil, "\(rule)")
        }
        let r = Self.expand(Self.series("FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1"), Self.date(2026, 9, 1), Self.date(2026, 12, 1))
        #expect(r.count == 1)
    }
}
