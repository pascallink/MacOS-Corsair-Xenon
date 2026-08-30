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

/// Recording delegate: captures calibration diagnostics without a real
/// observer.
final class RecordingTouchDelegate: TouchDriverDelegate {
    private(set) var diagnostics: [TouchDiagnostics] = []
    func touchDriver(_ driver: TouchDriver, deviceConnected connected: Bool) {}
    func touchDriver(_ driver: TouchDriver, didTouchAt point: CGPoint, down: Bool) {}
    func touchDriver(_ driver: TouchDriver, didObserve diagnostics: TouchDiagnostics) {
        self.diagnostics.append(diagnostics)
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

    // MARK: Step 3 — only the digitizer interface, only contact slot 0

    @Test func samplesFromSlotOneAreIgnored() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000, slot: 0))
        driver.handle(sample: y(1000, slot: 0))
        driver.handle(sample: tip(true, slot: 0))
        driver.handle(sample: x(9999, slot: 1))
        driver.handle(sample: y(9999, slot: 1))
        driver.handle(sample: tip(true, slot: 1))
        #expect(sink.events.map(\.kind) == [.leftDown])
        driver.handle(sample: tip(false, slot: 1)) // must not end slot 0's contact
        #expect(sink.events.map(\.kind) == [.leftDown])
        driver.handle(sample: tip(false, slot: 0))
        #expect(sink.events.map(\.kind) == [.leftDown, .leftUp])
    }

    @Test func slotZeroDrivesTheCursor() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000, slot: 0))
        driver.handle(sample: y(1000, slot: 0))
        driver.handle(sample: tip(true, slot: 0))
        driver.handle(sample: tip(false, slot: 0))
        #expect(sink.events.map(\.kind) == [.leftDown, .leftUp])
    }

    @Test func samplesWithoutSlotAreStillProcessed() {
        // Fallback for an unexpected descriptor: slot indexing found nothing,
        // sample.slot stays nil, so everything is processed as before.
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
        #expect(sink.events.map(\.kind) == [.leftDown, .leftUp])
    }

    @Test func buttonOneNoLongerStartsAContact() {
        let (driver, sink) = makeDriver()
        let button1 = TouchSample(usagePage: 0x09, usage: 0x01, value: 1)
        driver.handle(sample: button1)
        #expect(sink.events.isEmpty)
    }

    @Test func unusedSlotZeroesDoNotDragTheCursor() {
        // This was the actual bug: an idle slot reporting (0,0) while slot 0
        // is down used to yank the cursor into the panel corner.
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(8000, slot: 0))
        driver.handle(sample: y(4000, slot: 0))
        driver.handle(sample: tip(true, slot: 0))
        driver.handle(sample: x(0, slot: 3))
        driver.handle(sample: y(0, slot: 3))
        #expect(!sink.events.contains { $0.kind == .leftDragged })
    }

    // MARK: Step 4 — restoreCursorAfterTouch, independent of dragEnabled

    private func tapGesture(_ driver: TouchDriver) {
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        driver.handle(sample: tip(false))
    }

    @Test func tapRestoresCursor() {
        let (driver, sink) = makeDriver()
        tapGesture(driver)
        sink.runPending()
        #expect(sink.warps == [CGPoint(x: 100, y: 100)])
        #expect(sink.events.last?.kind == .moved)
        #expect(sink.events.last?.point == CGPoint(x: 100, y: 100))
    }

    @Test func dragEndRestoresCursor() {
        let (driver, sink) = makeDriver()
        driver.configuration.dragEnabled = true // the default
        driver.handle(sample: x(0))
        driver.handle(sample: y(0))
        driver.handle(sample: tip(true))
        driver.handle(sample: x(8000)) // drag
        driver.handle(sample: tip(false))
        sink.runPending()
        #expect(sink.warps == [CGPoint(x: 100, y: 100)])
    }

    @Test func longPressRestoresCursor() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        driver.handle(sample: tip(true))
        sink.advance(0.6) // fires the right click
        driver.handle(sample: tip(false))
        sink.runPending()
        #expect(sink.warps == [CGPoint(x: 100, y: 100)])
    }

    @Test func doubleTapRestoresCursorAndKeepsClickState() {
        let (driver, sink) = makeDriver()
        tapGesture(driver)
        sink.runPending()
        tapGesture(driver)
        sink.runPending()
        #expect(sink.warps.count == 2)
        #expect(sink.events.last { $0.kind == .leftUp }?.clickState == 2)
    }

    @Test func optionOffDoesNotWarp() {
        let (driver, sink) = makeDriver()
        driver.configuration.restoreCursorAfterTouch = false
        tapGesture(driver)
        sink.runPending()
        #expect(sink.warps.isEmpty)
        #expect(sink.cursorQueries == 0)
    }

    @Test func injectionDisabledDoesNotWarp() {
        let (driver, sink) = makeDriver()
        driver.injectionEnabled = false
        tapGesture(driver)
        sink.runPending()
        #expect(sink.warps.isEmpty)
    }

    @Test func cursorIsSavedBeforeTheDownEventIsPosted() {
        let (driver, sink) = makeDriver()
        driver.handle(sample: x(1000))
        driver.handle(sample: y(1000))
        // cursorLocation() is queried inside contactDown, before postMouse
        // ever calls eventSink.post — the recorder has no events yet then.
        let eventsBeforeDown = sink.events.count
        driver.handle(sample: tip(true))
        #expect(eventsBeforeDown == 0)
        #expect(sink.cursorQueries == 1)
    }

    @Test func restoreIsDeferredByOneTurn() {
        let (driver, sink) = makeDriver()
        tapGesture(driver)
        #expect(sink.warps.isEmpty) // not yet, before runPending()/advance()
        sink.runPending()
        #expect(sink.warps == [CGPoint(x: 100, y: 100)])
    }

    @Test func dragEnabledAndRestoreAreIndependent() {
        for dragEnabled in [true, false] {
            for restore in [true, false] {
                let (driver, sink) = makeDriver()
                driver.configuration.dragEnabled = dragEnabled
                driver.configuration.restoreCursorAfterTouch = restore
                tapGesture(driver)
                sink.runPending()
                #expect(sink.warps.isEmpty == !restore)
            }
        }
    }

    // MARK: Step 7 — calibration diagnostics

    @Test func movementIsReportedToTheDelegate() {
        let (driver, _) = makeDriver()
        let observer = RecordingTouchDelegate()
        driver.delegate = observer
        driver.handle(sample: x(0))
        driver.handle(sample: y(0))
        driver.handle(sample: tip(true))
        driver.handle(sample: x(8000)) // move while touching
        #expect(observer.diagnostics.contains { $0.phase == .moved })
    }

    @Test func diagnosticsCarryRawNormalizedAndMapped() throws {
        let (driver, _) = makeDriver()
        let observer = RecordingTouchDelegate()
        driver.delegate = observer
        driver.handle(sample: x(8192, slot: 0))
        driver.handle(sample: y(4800, slot: 0))
        driver.handle(sample: tip(true, slot: 0))
        let diag = try #require(observer.diagnostics.first)
        #expect(diag.rawX == 8192)
        #expect(diag.rawY == 4800)
        #expect(diag.slot == 0)
        let expected = TouchMapping.normalized(rawX: 8192, rawY: 4800, maxX: diag.maxX, maxY: diag.maxY,
                                               rotation: 0, invertX: false, invertY: false)
        #expect(abs(diag.normalized.x - expected.x) < 0.001)
        #expect(abs(diag.normalized.y - expected.y) < 0.001)
        let expectedMapped = EdgeDisplay.globalPoint(normalizedX: diag.normalized.x, normalizedY: diag.normalized.y,
                                                     in: CGRect(x: 1280, y: 2560, width: 2560, height: 720))
        #expect(diag.mapped == expectedMapped)
    }

    @Test func diagnosticsAreEmittedForDownMovedUp() {
        let (driver, _) = makeDriver()
        let observer = RecordingTouchDelegate()
        driver.delegate = observer
        driver.handle(sample: x(0))
        driver.handle(sample: y(0))
        driver.handle(sample: tip(true))
        driver.handle(sample: x(8000))
        driver.handle(sample: tip(false))
        #expect(observer.diagnostics.map(\.phase) == [.down, .moved, .up])
    }
}
