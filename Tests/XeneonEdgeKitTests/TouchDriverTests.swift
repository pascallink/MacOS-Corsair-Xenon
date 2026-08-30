// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Testing
@testable import XeneonEdgeKit

/// Aufzeichnende `TouchEventSink`-Doppelgängerin: macht die Gestenlogik ohne
/// Hardware und ohne echte Klicks prüfbar.
final class RecordingTouchSink: TouchEventSink {
    private(set) var events: [SynthesizedMouseEvent] = []
    private(set) var warps: [CGPoint] = []
    private(set) var cursorQueries = 0
    var cursor: CGPoint? = CGPoint(x: 100, y: 100)
    var clock = Date(timeIntervalSince1970: 1_000_000)
    private var pending: [(deadline: Date, work: () -> Void)] = []

    func post(_ event: SynthesizedMouseEvent) { events.append(event) }
    func warpCursor(to point: CGPoint) { warps.append(point) }
    func cursorLocation() -> CGPoint? {
        cursorQueries += 1
        return cursor
    }
    func now() -> Date { clock }
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((clock.addingTimeInterval(seconds), work))
    }

    /// Moves the clock forward and runs whatever becomes due by the new time.
    func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        let due = pending.filter { $0.deadline <= clock }
        guard !due.isEmpty else { return }
        pending.removeAll { item in due.contains { $0.deadline == item.deadline } }
        for item in due { item.work() }
    }

    /// Runs everything currently queued, without moving the clock — the
    /// zero-delay "next main-queue turn" schedules use this.
    func runPending() {
        let items = pending
        pending.removeAll()
        for item in items { item.work() }
    }
}

@Suite struct TouchDriverTests {
    /// Fresh driver wired to a recording sink and a fixed Edge-sized target
    /// rectangle, so gestures do not need a real NSScreen.
    private func makeDriver() -> (TouchDriver, RecordingTouchSink) {
        let driver = TouchDriver()
        let sink = RecordingTouchSink()
        driver.eventSink = sink
        driver.targetBoundsOverride = CGRect(x: 1280, y: 2560, width: 2560, height: 720)
        return (driver, sink)
    }

    private func tip(_ down: Bool, slot: Int? = nil) -> TouchSample {
        TouchSample(usagePage: 0x0D, usage: 0x42, value: down ? 1 : 0, slot: slot)
    }
    private func x(_ value: Int, logicalMax: Int = 16383, slot: Int? = nil) -> TouchSample {
        TouchSample(usagePage: 0x01, usage: 0x30, value: value, logicalMax: logicalMax, slot: slot)
    }
    private func y(_ value: Int, logicalMax: Int = 9599, slot: Int? = nil) -> TouchSample {
        TouchSample(usagePage: 0x01, usage: 0x31, value: value, logicalMax: logicalMax, slot: slot)
    }

    // MARK: Step 2 — today's behaviour, characterized before it changes

    @Test func tapEmitsDownAndUp() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        #expect(sink.events.map(\.kind) == [.leftDown, .leftUp])
        #expect(sink.events.allSatisfy { $0.clickState == 1 })
    }

    @Test func movementBeyondSlopBecomesDrag() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(0))
        driver.handle(sample: y(0))
        driver.handle(sample: tip(true))
        driver.handle(sample: x(8000)) // far beyond tapSlop in panel points
        #expect(sink.events.contains { $0.kind == .leftDragged })
    }

    @Test func movementWithinSlopStaysATap() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(0))
        driver.handle(sample: y(0))
        driver.handle(sample: tip(true))
        driver.handle(sample: x(5)) // a couple of screen points, well under tapSlop
        #expect(!sink.events.contains { $0.kind == .leftDragged })
    }

    @Test func secondTapWithinWindowIsDoubleClick() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        #expect(sink.events.last?.clickState == 2)
    }

    @Test func tapAfterDoubleTapWindowIsSingle() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        sink.advance(1.0) // well beyond doubleTapSeconds
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        #expect(sink.events.last?.clickState == 1)
    }

    @Test func longPressEmitsRightClick() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        sink.advance(0.6)
        #expect(sink.events.map(\.kind) == [.leftDown, .leftUp, .rightDown, .rightUp])
        #expect(sink.events.map(\.clickState) == [1, 0, 1, 1])
    }

    @Test func injectionDisabledEmitsNothing() {
        let (driver, sink) = makeDriver()
        driver.injectionEnabled = false
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        #expect(sink.events.isEmpty)
    }

    @Test func withoutTargetBoundsNothingIsPosted() {
        let driver = TouchDriver()
        let sink = RecordingTouchSink()
        driver.eventSink = sink
        // targetBoundsOverride stays nil and no display is set.
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        #expect(sink.events.isEmpty)
    }
}
