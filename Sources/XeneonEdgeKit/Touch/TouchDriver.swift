// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Touchscreen driver for the XENEON EDGE.
//
// The Edge's digitizer enumerates as a separate USB HID device (27c0:0859)
// reporting absolute X/Y (Generic Desktop) plus a contact state (Button 1 on
// this controller; standard digitizer Tip Switch is handled too). macOS has
// no built-in touchscreen support, so this driver maps contacts onto the
// Edge's portion of the desktop and synthesizes mouse events:
//
//   tap            -> left click
//   tap-tap        -> double click
//   touch + move   -> drag (mouse down, drag, up)
//   long press     -> right click (configurable)
//
// After every finished gesture the cursor jumps back to where it stood
// before the touch (restoreCursorAfterTouch, on by default) so the user
// does not have to pull the mouse off the Edge again.
//
// Requires the Accessibility permission (event injection) and Input
// Monitoring (HID capture).

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

public struct TouchDriverConfiguration {
    /// Emit drags (down/drag/up). When false, only taps are emitted.
    public var dragEnabled = true
    /// Long press emits a right click.
    public var longPressRightClick = true
    /// Seconds a stationary contact becomes a long press.
    public var longPressSeconds: TimeInterval = 0.6
    /// Max movement (in screen points) for a contact to count as stationary.
    public var tapSlop: CGFloat = 12
    /// Max seconds between two taps to form a double click.
    public var doubleTapSeconds: TimeInterval = 0.35
    /// Panel mounted rotated (0, 90, 180, 270 degrees clockwise).
    public var rotation = 0
    /// Mirror axes (for unusual mounting).
    public var invertX = false
    public var invertY = false
    /// After a finished gesture, the cursor jumps back to where it stood
    /// before the touch — the user does not have to pull the mouse off the
    /// Edge. Independent of `dragEnabled`; applies to tap, double tap,
    /// long-press right click and drag end.
    public var restoreCursorAfterTouch = true

    public init() {}
}

/// Raw data of a contact event, for calibration. Deliberately carries every
/// intermediate stage, because `touchRotation` / `invertX` / `invertY` can
/// only be derived from the raw value, the normalization and the mapping
/// together.
public struct TouchDiagnostics: Equatable {
    public enum Phase: String { case down, moved, up }
    public let phase: Phase
    /// Contact slot the last value came from (nil = unknown).
    public let slot: Int?
    public let rawX: Int
    public let rawY: Int
    public let maxX: Int
    public let maxY: Int
    /// After rotation/mirroring, 0...1.
    public let normalized: CGPoint
    /// Global CoreGraphics coordinates (or panel coordinates without a display).
    public let mapped: CGPoint

    public init(phase: Phase, slot: Int?, rawX: Int, rawY: Int, maxX: Int, maxY: Int,
                normalized: CGPoint, mapped: CGPoint) {
        self.phase = phase
        self.slot = slot
        self.rawX = rawX
        self.rawY = rawY
        self.maxX = maxX
        self.maxY = maxY
        self.normalized = normalized
        self.mapped = mapped
    }
}

public protocol TouchDriverDelegate: AnyObject {
    func touchDriver(_ driver: TouchDriver, deviceConnected connected: Bool)
    func touchDriver(_ driver: TouchDriver, didTouchAt point: CGPoint, down: Bool)
    func touchDriver(_ driver: TouchDriver, didObserve diagnostics: TouchDiagnostics)
}

/// Diagnostics are optional — existing delegates (AppDelegate) stay unchanged.
public extension TouchDriverDelegate {
    func touchDriver(_ driver: TouchDriver, didObserve diagnostics: TouchDiagnostics) {}
}

public final class TouchDriver {
    public var configuration = TouchDriverConfiguration()
    public weak var delegate: TouchDriverDelegate?
    /// When set, touches map to this display; refreshed automatically on
    /// screen-parameter changes by the app layer.
    public var display: EdgeDisplay?
    /// Master switch; when false, incoming reports are ignored.
    public var enabled = true
    /// When false, touches are tracked and reported to the delegate but no
    /// mouse events are synthesized (diagnostics mode).
    public var injectionEnabled = true
    /// Target of the event output. Swappable for tests.
    public var eventSink: TouchEventSink = CGEventTouchSink()
    /// Overrides `display` for tests and diagnostics: touches map onto this
    /// rectangle. nil = use `display`.
    public var targetBoundsOverride: CGRect?

    public private(set) var deviceConnected = false

    private var manager: IOHIDManager?

    private var targetBounds: CGRect? { targetBoundsOverride ?? display?.bounds }

    /// Element cookie -> contact slot, built once per matched device from the
    /// report descriptor. The finger collections appear there in slot order.
    private var slotForCookie: [IOHIDElementCookie: Int] = [:]

    // Raw axis state
    private var rawX = 0
    private var rawY = 0
    private var maxX = EdgeConstants.touchDefaultMaxX
    private var maxY = EdgeConstants.touchDefaultMaxY

    // Contact state machine
    private var touching = false
    private var dragging = false
    private var downPoint = CGPoint.zero
    private var downTime = Date.distantPast
    private var lastPoint = CGPoint.zero
    private var lastTapTime = Date.distantPast
    private var lastTapPoint = CGPoint.zero
    private var longPressFired = false
    private var savedCursorPosition: CGPoint?

    public init() {}

    // MARK: Permissions

    /// True when the process may inject events. Pass prompt=true to make
    /// macOS show the "allow in Accessibility settings" dialog.
    public static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// True when the process may read HID input (Input Monitoring). Without
    /// this permission the driver stays silent rather than reporting an error.
    public static func hasInputMonitoringPermission() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Requests Input Monitoring (shows the system dialog).
    @discardableResult
    public static func requestInputMonitoringPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: Lifecycle

    /// Starts HID capture; callbacks arrive on the given run loop.
    public func start(runLoop: CFRunLoop = CFRunLoopGetMain()) {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: EdgeConstants.touchVendorID,
            kIOHIDProductIDKey as String: EdgeConstants.touchProductID,
            kIOHIDDeviceUsagePageKey as String: EdgeConstants.digitizerUsagePage,
            kIOHIDDeviceUsageKey as String: EdgeConstants.digitizerUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.indexContactSlots(of: device)
            me.deviceConnected = true
            me.delegate?.touchDriver(me, deviceConnected: true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.slotForCookie.removeAll()
            me.deviceConnected = false
            me.delegate?.touchDriver(me, deviceConnected: false)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.handle(value: value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    // MARK: HID input

    /// Thin decoder: turns a raw IOHIDValue into a `TouchSample` and hands it
    /// to the (testable) state machine.
    private func handle(value: IOHIDValue) {
        guard enabled else { return }
        let element = IOHIDValueGetElement(value)
        let sample = TouchSample(usagePage: IOHIDElementGetUsagePage(element),
                                 usage: IOHIDElementGetUsage(element),
                                 value: IOHIDValueGetIntegerValue(value),
                                 logicalMax: IOHIDElementGetLogicalMax(element),
                                 slot: slotForCookie[IOHIDElementGetCookie(element)])
        handle(sample: sample)
    }

    /// The actual state machine input, decoupled from IOKit so it can be fed
    /// directly by tests.
    func handle(sample: TouchSample) {
        // The digitizer declares ten identical finger collections; only the
        // first drives the cursor. Values from slots 1-9 must not touch
        // rawX/rawY/touching, or an unused slot reporting 0 would drag the
        // cursor into the panel corner. Fallback: if slot indexing found
        // nothing (unexpected descriptor), sample.slot stays nil here and
        // every value is processed as before.
        if let slot = sample.slot, slot != 0 { return }

        switch (sample.usagePage, sample.usage) {
        case (0x01, 0x30): // Generic Desktop / X
            rawX = sample.value
            if sample.logicalMax > 0 { maxX = sample.logicalMax }
            if touching { contactMoved(slot: sample.slot) }
        case (0x01, 0x31): // Generic Desktop / Y
            rawY = sample.value
            if sample.logicalMax > 0 { maxY = sample.logicalMax }
            if touching { contactMoved(slot: sample.slot) }
        case (0x0D, 0x42): // Digitizer / Tip Switch — the only contact source
                           // on this interface. Button 1 (0x09/0x01) lives on
                           // the mouse-emulation interface, which this driver
                           // does not open.
            if sample.value != 0 { contactDown(slot: sample.slot) } else { contactUp(slot: sample.slot) }
        default:
            break
        }
    }

    // MARK: Slot indexing

    /// Builds `slotForCookie`. Only `(0x0D, 0x22)` collections whose parent
    /// collection is `(0x0D, 0x04)` are counted — the descriptor contains a
    /// second finger collection under `(0x0D, 0x0E)` (Device Configuration)
    /// that is not a contact slot.
    private func indexContactSlots(of device: IOHIDDevice) {
        slotForCookie.removeAll()
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return }

        var slotForFingerCookie: [IOHIDElementCookie: Int] = [:]
        for element in elements {
            guard let finger = IOHIDElementGetParent(element) else { continue }
            guard IOHIDElementGetUsagePage(finger) == UInt32(EdgeConstants.digitizerUsagePage),
                  IOHIDElementGetUsage(finger) == UInt32(EdgeConstants.digitizerFingerUsage)
            else { continue }
            guard let digitizer = IOHIDElementGetParent(finger),
                  IOHIDElementGetUsagePage(digitizer) == UInt32(EdgeConstants.digitizerUsagePage),
                  IOHIDElementGetUsage(digitizer) == UInt32(EdgeConstants.digitizerUsage)
            else { continue }

            let fingerCookie = IOHIDElementGetCookie(finger)
            let slot = slotForFingerCookie[fingerCookie] ?? slotForFingerCookie.count
            slotForFingerCookie[fingerCookie] = slot
            slotForCookie[IOHIDElementGetCookie(element)] = slot
        }
    }

    // MARK: Mapping

    private func currentPoint() -> CGPoint? {
        let n = TouchMapping.normalized(rawX: rawX, rawY: rawY, maxX: maxX, maxY: maxY,
                                        rotation: configuration.rotation,
                                        invertX: configuration.invertX,
                                        invertY: configuration.invertY)

        guard let bounds = targetBounds else {
            // No Edge display located: report panel-native coordinates so
            // diagnostics still work; injection stays off in that case.
            return CGPoint(x: n.x * EdgeConstants.nativeWidth,
                           y: n.y * EdgeConstants.nativeHeight)
        }
        return EdgeDisplay.globalPoint(normalizedX: n.x, normalizedY: n.y, in: bounds)
    }

    // MARK: Contact state machine

    private func contactDown(slot: Int? = nil) {
        guard !touching, let point = currentPoint() else { return }
        touching = true
        dragging = false
        longPressFired = false
        downPoint = point
        downTime = eventSink.now()
        lastPoint = point
        savedCursorPosition = configuration.restoreCursorAfterTouch
            ? eventSink.cursorLocation() : nil

        delegate?.touchDriver(self, didTouchAt: point, down: true)
        reportDiagnostics(phase: .down, slot: slot, point: point)

        if configuration.dragEnabled {
            postMouse(.leftDown, at: point, clickState: clickState(for: point))
        }
        if configuration.longPressRightClick {
            eventSink.schedule(after: configuration.longPressSeconds) { [weak self] in
                self?.longPressCheck()
            }
        }
    }

    private func contactMoved(slot: Int? = nil) {
        guard touching, let point = currentPoint() else { return }
        lastPoint = point
        reportDiagnostics(phase: .moved, slot: slot, point: point)
        if configuration.dragEnabled {
            if dragging || distance(point, downPoint) > configuration.tapSlop {
                dragging = true
                postMouse(.leftDragged, at: point, clickState: 1)
            }
        }
    }

    private func contactUp(slot: Int? = nil) {
        guard touching else { return }
        touching = false
        let point = lastPoint
        delegate?.touchDriver(self, didTouchAt: point, down: false)
        reportDiagnostics(phase: .up, slot: slot, point: point)

        if longPressFired {
            restoreCursorIfNeeded() // right click already delivered
            return
        }

        if configuration.dragEnabled {
            postMouse(.leftUp, at: point, clickState: clickState(for: downPoint))
        } else {
            let state = clickState(for: downPoint)
            postMouse(.leftDown, at: point, clickState: state)
            postMouse(.leftUp, at: point, clickState: state)
        }
        restoreCursorIfNeeded()

        if !dragging {
            lastTapTime = eventSink.now()
            lastTapPoint = downPoint
        }
    }

    /// Restores the cursor position saved before the touch. Deferred by one
    /// main-queue turn: an app that queries the *current* cursor position
    /// while handling the just-posted click should still see the touch
    /// position.
    private func restoreCursorIfNeeded() {
        guard configuration.restoreCursorAfterTouch,
              injectionEnabled, targetBounds != nil,
              let saved = savedCursorPosition else { return }
        savedCursorPosition = nil
        eventSink.schedule(after: 0) { [weak self] in
            guard let self else { return }
            self.eventSink.warpCursor(to: saved)
            // A warp does not generate mouseMoved; hover/tracking state
            // would otherwise stay stuck on the Edge.
            self.eventSink.post(SynthesizedMouseEvent(kind: .moved, point: saved, clickState: 0))
        }
    }

    private func longPressCheck() {
        guard touching, !dragging, !longPressFired else { return }
        guard eventSink.now().timeIntervalSince(downTime) >= configuration.longPressSeconds - 0.01 else { return }
        guard distance(lastPoint, downPoint) <= configuration.tapSlop else { return }
        longPressFired = true
        if configuration.dragEnabled {
            // Cancel the pending left click before the right click.
            postMouse(.leftUp, at: downPoint, clickState: 0)
        }
        postMouse(.rightDown, at: downPoint, clickState: 1)
        postMouse(.rightUp, at: downPoint, clickState: 1)
    }

    private func clickState(for point: CGPoint) -> Int64 {
        let isDouble = eventSink.now().timeIntervalSince(lastTapTime) < configuration.doubleTapSeconds
            && distance(point, lastTapPoint) <= configuration.tapSlop * 2
        return isDouble ? 2 : 1
    }

    /// Reports the current raw/normalized/mapped state for calibration.
    /// `contactMoved` used to report nothing at all, which is exactly what
    /// made `touch-monitor` useless for calibration.
    private func reportDiagnostics(phase: TouchDiagnostics.Phase, slot: Int?, point: CGPoint) {
        let n = TouchMapping.normalized(rawX: rawX, rawY: rawY, maxX: maxX, maxY: maxY,
                                        rotation: configuration.rotation,
                                        invertX: configuration.invertX,
                                        invertY: configuration.invertY)
        delegate?.touchDriver(self, didObserve: TouchDiagnostics(
            phase: phase, slot: slot, rawX: rawX, rawY: rawY, maxX: maxX, maxY: maxY,
            normalized: n, mapped: point))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: Event injection

    private func postMouse(_ kind: SynthesizedMouseEvent.Kind,
                           at point: CGPoint, clickState: Int64) {
        guard injectionEnabled, targetBounds != nil else { return }
        eventSink.post(SynthesizedMouseEvent(kind: kind, point: point, clickState: clickState))
    }
}

/// One HID interface of the touch controller, for diagnostics.
public struct TouchInterfaceInfo: Equatable {
    public let usagePage: Int
    public let usage: Int
    public let elementCount: Int
    /// True for the interface that `start()` opens.
    public let matchedByDriver: Bool
}

public extension TouchDriver {
    /// All HID interfaces of the touch controller (VID/PID), with which one
    /// the driver actually opens. Read-only, only used for `xeneonctl probe`.
    static func touchInterfaces() -> [TouchInterfaceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: EdgeConstants.touchVendorID,
            kIOHIDProductIDKey as String: EdgeConstants.touchProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let infos: [TouchInterfaceInfo] = devices.map { device in
            let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            let elementCount = (IOHIDDeviceCopyMatchingElements(
                device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
            ) as? [IOHIDElement])?.count ?? 0
            let matched = usagePage == EdgeConstants.digitizerUsagePage
                && usage == EdgeConstants.digitizerUsage
            return TouchInterfaceInfo(usagePage: usagePage, usage: usage,
                                      elementCount: elementCount, matchedByDriver: matched)
        }
        return infos.sorted {
            if $0.matchedByDriver != $1.matchedByDriver { return $0.matchedByDriver }
            return ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage)
        }
    }
}
