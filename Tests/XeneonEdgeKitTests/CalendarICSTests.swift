// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct ICSParserTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let utc = TimeZone(identifier: "UTC")!

    /// 2026-09-19T12:30:00Z
    private static let nineteenth1230Z = Date(timeIntervalSince1970: 1_789_821_000)

    private static func wrap(_ body: String, eol: String = "\n") -> String {
        let text = "BEGIN:VCALENDAR\n\(body)\nEND:VCALENDAR\n"
        return text.replacingOccurrences(of: "\n", with: eol)
    }

    private static func parse(_ body: String, zone: TimeZone = berlin, eol: String = "\n") -> [CalendarEvent] {
        ICSParser.parse(wrap(body, eol: eol), defaultTimeZone: zone)
    }

    @Test func foldedSummaryStaysContiguous() {
        let events = Self.parse("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        SUMMARY:Sprint Plan
         ning Meeting
        END:VEVENT
        """)
        #expect(events.first?.title == "Sprint Planning Meeting")
    }

    @Test func escapedCommaAndNewlineAreUnescaped() {
        let events = Self.parse(#"""
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        SUMMARY:A\, B\; C\\ D
        LOCATION:Zeile1\nZeile2
        END:VEVENT
        """#)
        #expect(events.first?.title == "A, B; C\\ D")
        #expect(events.first?.location == "Zeile1\nZeile2")
    }

    @Test func utcStart() {
        let events = Self.parse("BEGIN:VEVENT\nUID:a\nDTSTART:20260919T123000Z\nEND:VEVENT")
        #expect(events.count == 1)
        #expect(events[0].start == Self.nineteenth1230Z)
        #expect(!events[0].isAllDay)
    }

    @Test func tzidStart() {
        let events = Self.parse(
            "BEGIN:VEVENT\nUID:a\nDTSTART;TZID=\"Europe/Berlin\":20260919T143000\nEND:VEVENT",
            zone: Self.utc
        )
        #expect(events.first?.start == Self.nineteenth1230Z)
    }

    @Test func floatingStartUsesDefaultZone() {
        let events = Self.parse("BEGIN:VEVENT\nUID:a\nDTSTART:20260919T143000\nEND:VEVENT")
        #expect(events.first?.start == Self.nineteenth1230Z)
    }

    @Test func valueDateSetsAllDay() {
        let events = Self.parse(
            "BEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260919\nDTEND;VALUE=DATE:20260920\nEND:VEVENT"
        )
        #expect(events.first?.isAllDay == true)
        #expect(events.first?.start == Date(timeIntervalSince1970: 1_789_768_800)) // 2026-09-19T00:00 CEST
        #expect(events.first?.end == Date(timeIntervalSince1970: 1_789_855_200))
    }

    @Test func allDayWithoutEndGetsOneDay() {
        let events = Self.parse("BEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260919\nEND:VEVENT")
        #expect(events.first?.end == Date(timeIntervalSince1970: 1_789_855_200))
    }

    @Test func durationWithoutEnd() {
        let events = Self.parse("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        DURATION:PT1H30M
        END:VEVENT
        """)
        #expect(events.first?.end == Self.nineteenth1230Z.addingTimeInterval(5400))
    }

    @Test func dayDurationKeepsCalendarDayAcrossDST() {
        // Zeitumstellung 2026-10-25: P1D ab 24.10. 12:00 Berlin ist 25.10. 12:00 (25 h).
        let events = Self.parse(
            "BEGIN:VEVENT\nUID:a\nDTSTART;TZID=Europe/Berlin:20261024T120000\nDURATION:P1D\nEND:VEVENT"
        )
        #expect(events.first.map { $0.end.timeIntervalSince($0.start) } == TimeInterval(25 * 3600))
    }

    @Test func unknownTZIDFallsBackToDefaultZone() {
        let events = Self.parse(
            "BEGIN:VEVENT\nUID:a\nDTSTART;TZID=Mars/Olympus:20260919T143000\nEND:VEVENT"
        )
        #expect(events.count == 1)
        #expect(events.first?.start == Self.nineteenth1230Z)
    }

    @Test func textWithoutEventIsEmpty() {
        #expect(Self.parse("X-WR-CALNAME:Nichts").isEmpty)
        #expect(ICSParser.parse("", defaultTimeZone: Self.utc).isEmpty)
        #expect(ICSParser.parse("Muell\u{0}\u{1}:::", defaultTimeZone: Self.utc).isEmpty)
    }

    @Test func truncatedEventIsEmpty() {
        let events = Self.parse("BEGIN:VEVENT\nUID:a\nDTSTART:20260919T123000Z\nSUMMARY:Abgeschnitten")
        #expect(events.isEmpty)
    }

    @Test func invalidDigitsSkipEvent() {
        #expect(Self.parse("BEGIN:VEVENT\nUID:a\nDTSTART:20261319T123000Z\nEND:VEVENT").isEmpty)
        #expect(Self.parse("BEGIN:VEVENT\nUID:a\nDTSTART:2026091\nEND:VEVENT").isEmpty)
        #expect(Self.parse("BEGIN:VEVENT\nUID:a\nSUMMARY:ohne Start\nEND:VEVENT").isEmpty)
    }

    @Test func alarmDoesNotChangeEvent() {
        let events = Self.parse("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        DTEND:20260919T133000Z
        SUMMARY:Echt
        BEGIN:VALARM
        TRIGGER:-PT15M
        DURATION:PT5M
        SUMMARY:Alarm
        END:VALARM
        END:VEVENT
        """)
        #expect(events.count == 1)
        #expect(events[0].title == "Echt")
        #expect(events[0].end == Self.nineteenth1230Z.addingTimeInterval(3600))
    }

    @Test func timezoneBlockIsSkipped() {
        let events = Self.parse("""
        BEGIN:VTIMEZONE
        TZID:Europe/Berlin
        BEGIN:VEVENT
        DTSTART:19700101T000000
        SUMMARY:Falle
        END:VEVENT
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        SUMMARY:Echt
        END:VEVENT
        """)
        #expect(events.map(\.title) == ["Echt"])
    }

    @Test func crlfMatchesLF() {
        let body = "BEGIN:VEVENT\nUID:a\nDTSTART:20260919T123000Z\nSUMMARY:Lang\n er Titel\nSTATUS:confirmed\nEND:VEVENT"
        let lf = Self.parse(body)
        let crlf = Self.parse(body, eol: "\r\n")
        #expect(lf == crlf)
        #expect(lf.first?.title == "Langer Titel")
        #expect(lf.first?.status == "CONFIRMED")
    }

    @Test func recurrenceIDIsResolved() {
        let events = Self.parse("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        RECURRENCE-ID:20260912T123000Z
        END:VEVENT
        """)
        #expect(events.first?.recurrenceID == Self.nineteenth1230Z.addingTimeInterval(-7 * 86400))
    }

    @Test func idIsUniquePerStart() {
        let a = CalendarEvent(uid: "x", title: "", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2))
        let b = CalendarEvent(uid: "x", title: "", start: Date(timeIntervalSince1970: 5), end: Date(timeIntervalSince1970: 6))
        #expect(a.id != b.id)
        #expect(a.id.hasPrefix("x|"))
    }

    @Test func quotedColonInParameterDoesNotSplit() {
        let events = Self.parse("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20260919T123000Z
        ATTENDEE;CN="Doe: John":mailto:j@example.com
        SUMMARY:Ok
        END:VEVENT
        """)
        #expect(events.first?.title == "Ok")
    }
}
