// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Touchscreen driver for the XENEON EDGE.
//
// The Edge's touch controller enumerates as a separate USB HID device
// (27c0:0859) that exposes three interfaces under one VID/PID: a digitizer
// (0x0D/0x04, ten contact slots, Tip Switch), a mouse emulation (0x01/0x02,
// absolute X/Y plus Button 1) and a vendor channel (0xFF0A/0xFF).
//
// Which of the two input interfaces actually reports is decided by the
// digitizer's `Device Mode` feature (0x0D/0x52). The Edge powers up with
// Device Mode = 0 — mouse mode — and then sends nothing at all on the
// digitizer; verified at the connected device by reading the feature report.
// Switching it would be a HID *write* to the controller and is out of scope
// here, so the driver opens both input interfaces: the mouse emulation
// carries today's contacts, the digitizer path stays in place (including the
// contact-slot binding) for the day the mode is switched. The vendor channel
// is never opened.
//
// macOS has no built-in touchscreen support, so this driver maps contacts
// onto the Edge's portion of the desktop and synthesizes mouse events:
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
    /// Take the touch controller's input interfaces away from macOS while
    /// the driver runs (`kIOHIDOptionsTypeSeizeDevice`).
    ///
    /// macOS attaches its own `AppleUserHIDEventDriver` to the
    /// mouse-emulation interface and turns the very same reports into system
    /// pointer events — measured in the IORegistry on the connected Edge.
    /// Every touch then moves the cursor twice: natively, wherever macOS
    /// maps the absolute coordinates, and again through this driver onto the
    /// Edge. Seizing the interface stops the native path at the source
    /// without writing anything to the device.
    ///
    /// While seized, touch reaches the system *only* through this driver, so
    /// the seize must be released whenever touch is switched off — `stop()`
    /// does that, and the kernel releases it when the process exits. If the
    /// seize is refused, `start()` falls back to a shared open and
    /// `systemCursorSuppressed` stays false.
    public var suppressSystemCursor = true

    public init() {}
}

/// Raw data of a contact event, for calibration. Deliberately carries every
/// intermediate stage, because `touchRotation` / `invertX` / `invertY` can
/// only be derived from the raw value, the normalization and the mapping
/// together.
public struct TouchDiagnostics: Equatable {
    public enum Phase: String { case down, moved, up }
    public let phase: Phase
    /// HID interface the last value came from.
    public let interface: TouchInterface
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

    public init(phase: Phase, interface: TouchInterface = .unknown, slot: Int?,
                rawX: Int, rawY: Int, maxX: Int, maxY: Int,
                normalized: CGPoint, mapped: CGPoint) {
        self.phase = phase
        self.interface = interface
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
    /// True while the touch interfaces are actually seized, i.e. macOS is
    /// not generating pointer events from them. False when
    /// `suppressSystemCursor` is off or the seize was refused.
    public private(set) var systemCursorSuppressed = false

    /// True while the HID connection is open.
    public var isRunning: Bool { manager != nil }

    private var manager: IOHIDManager?
    /// Options `start()` opened the manager with; `stop()` must close with
    /// the same ones.
    private var openOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    private var targetBounds: CGRect? { targetBoundsOverride ?? display?.bounds }

    /// Per device: element cookie -> contact slot, built once per matched
    /// device from the report descriptor. The finger collections appear there
    /// in slot order. Keyed by device because cookies are only unique within
    /// one device — the mouse emulation's cookies overlap the digitizer's.
    private var slotTables: [ObjectIdentifier: [IOHIDElementCookie: Int]] = [:]
    /// Per device: which interface it is, for sample tagging and diagnostics.
    private var interfaceForDevice: [ObjectIdentifier: TouchInterface] = [:]
    /// Matched devices currently present. Two interfaces are opened, so
    /// connect/disconnect must only be reported on the first and the last.
    private var openDevices: Set<ObjectIdentifier> = []
    /// Interface of the value last handed to `handle(sample:)`, for
    /// diagnostics reporting.
    private var lastInterface: TouchInterface = .unknown

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

        let matching = TouchDriver.openedInterfaces.map { iface -> [String: Any] in
            [
                kIOHIDVendorIDKey as String: EdgeConstants.touchVendorID,
                kIOHIDProductIDKey as String: EdgeConstants.touchProductID,
                kIOHIDDeviceUsagePageKey as String: iface.usagePage,
                kIOHIDDeviceUsageKey as String: iface.usage,
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.deviceAppeared(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.deviceVanished(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.handle(value: value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let shared = IOOptionBits(kIOHIDOptionsTypeNone)
        let seize = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        var options = configuration.suppressSystemCursor ? seize : shared
        if IOHIDManagerOpen(manager, options) != kIOReturnSuccess, options == seize {
            // Better a doubled cursor than no touch at all.
            options = shared
            _ = IOHIDManagerOpen(manager, options)
        }
        openOptions = options
        systemCursorSuppressed = options == seize
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, openOptions)
        self.manager = nil
        openOptions = IOOptionBits(kIOHIDOptionsTypeNone)
        systemCursorSuppressed = false
        // A later start() matches the devices afresh; keep `deviceConnected`
        // as last seen so the menu does not claim the panel went away.
        slotTables.removeAll()
        interfaceForDevice.removeAll()
        openDevices.removeAll()
    }

    // MARK: HID input

    /// Thin decoder: turns a raw IOHIDValue into a `TouchSample` and hands it
    /// to the (testable) state machine.
    private func handle(value: IOHIDValue) {
        guard enabled else { return }
        let element = IOHIDValueGetElement(value)
        let device = ObjectIdentifier(IOHIDElementGetDevice(element))
        let sample = TouchSample(usagePage: IOHIDElementGetUsagePage(element),
                                 usage: IOHIDElementGetUsage(element),
                                 value: IOHIDValueGetIntegerValue(value),
                                 logicalMax: IOHIDElementGetLogicalMax(element),
                                 slot: slotTables[device]?[IOHIDElementGetCookie(element)],
                                 interface: interfaceForDevice[device] ?? .unknown)
        handle(sample: sample)
    }

    /// The actual state machine input, decoupled from IOKit so it can be fed
    /// directly by tests.
    func handle(sample: TouchSample) {
        // The digitizer declares ten identical finger collections; only the
        // first drives the cursor. Values from slots 1-9 must not touch
        // rawX/rawY/touching, or an unused slot reporting 0 would drag the
        // cursor into the panel corner. The mouse emulation has no slots, so
        // its samples carry nil and pass. Same fallback for an unexpected
        // descriptor: slot stays nil, every value is processed as before.
        if let slot = sample.slot, slot != 0 { return }
        lastInterface = sample.interface

        switch (sample.usagePage, sample.usage) {
        case (0x01, 0x30): // Generic Desktop / X (absolute on both interfaces)
            rawX = sample.value
            if sample.logicalMax > 0 { maxX = sample.logicalMax }
            if touching { contactMoved(slot: sample.slot) }
        case (0x01, 0x31): // Generic Desktop / Y (absolute on both interfaces)
            rawY = sample.value
            if sample.logicalMax > 0 { maxY = sample.logicalMax }
            if touching { contactMoved(slot: sample.slot) }
        case (0x09, 0x01), // Button 1 — contact on the mouse emulation, which
                           // is what the Edge reports in its power-on mode
             (0x0D, 0x42): // Digitizer / Tip Switch — contact on the
                           // digitizer, silent until Device Mode is switched
            // Only one of the two interfaces reports at a time; should both
            // ever do so, the guards in contactDown/contactUp collapse the
            // duplicate into a single gesture.
            if sample.value != 0 { contactDown(slot: sample.slot) } else { contactUp(slot: sample.slot) }
        default:
            break
        }
    }

    // MARK: Device bookkeeping

    private func deviceAppeared(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        interfaceForDevice[id] = TouchDriver.interface(of: device)
        indexContactSlots(of: device)
        let wasConnected = !openDevices.isEmpty
        openDevices.insert(id)
        guard !wasConnected else { return }
        deviceConnected = true
        delegate?.touchDriver(self, deviceConnected: true)
    }

    private func deviceVanished(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        slotTables.removeValue(forKey: id)
        interfaceForDevice.removeValue(forKey: id)
        openDevices.remove(id)
        guard openDevices.isEmpty else { return }
        deviceConnected = false
        delegate?.touchDriver(self, deviceConnected: false)
    }

    private static func interface(of device: IOHIDDevice) -> TouchInterface {
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        switch (page, usage) {
        case (EdgeConstants.digitizerUsagePage, EdgeConstants.digitizerUsage): return .digitizer
        case (EdgeConstants.touchMouseUsagePage, EdgeConstants.touchMouseUsage): return .mouseEmulation
        default: return .unknown
        }
    }

    // MARK: Slot indexing

    /// Builds `slotForCookie`. Only `(0x0D, 0x22)` collections whose parent
    /// collection is `(0x0D, 0x04)` are counted — the descriptor contains a
    /// second finger collection under `(0x0D, 0x0E)` (Device Configuration)
    /// that is not a contact slot.
    private func indexContactSlots(of device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        slotTables[id] = [:]
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return }

        var slotForCookie: [IOHIDElementCookie: Int] = [:]
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
        slotTables[id] = slotForCookie
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
            phase: phase, interface: lastInterface, slot: slot,
            rawX: rawX, rawY: rawY, maxX: maxX, maxY: maxY,
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
    /// True for the interfaces that `start()` opens.
    public let matchedByDriver: Bool
}

public extension TouchDriver {
    /// The interfaces `start()` matches on. The digitizer is listed first
    /// because it is the one that carries real contact slots; it only
    /// reports once `Device Mode` is switched away from mouse mode.
    static var openedInterfaces: [(usagePage: Int, usage: Int)] {
        [
            (EdgeConstants.digitizerUsagePage, EdgeConstants.digitizerUsage),
            (EdgeConstants.touchMouseUsagePage, EdgeConstants.touchMouseUsage),
        ]
    }

    /// The digitizer's `Device Mode` feature (`0x0D/0x52`), read back from
    /// the device. `EdgeConstants.digitizerDeviceModeMouse` (0) means the
    /// controller reports through the mouse emulation and the digitizer
    /// interface stays silent. nil when the interface or the element is not
    /// there. Read-only: this issues a Get Feature request, never a write.
    static func digitizerDeviceMode() -> Int? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: EdgeConstants.touchVendorID,
            kIOHIDProductIDKey as String: EdgeConstants.touchProductID,
            kIOHIDDeviceUsagePageKey as String: EdgeConstants.digitizerUsagePage,
            kIOHIDDeviceUsageKey as String: EdgeConstants.digitizerUsage,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first
        else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let modeMatching: [String: Any] = [
            kIOHIDElementUsagePageKey as String: EdgeConstants.digitizerUsagePage,
            kIOHIDElementUsageKey as String: EdgeConstants.digitizerDeviceModeUsage,
        ]
        guard let elements = IOHIDDeviceCopyMatchingElements(
                  device, modeMatching as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)
              ) as? [IOHIDElement],
              let element = elements.first
        else { return nil }

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // IOHIDDeviceGetValue wants a valid IOHIDValue to overwrite.
        var value = Unmanaged.passUnretained(
            IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
        guard IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess else { return nil }
        return Int(IOHIDValueGetIntegerValue(value.takeUnretainedValue()))
    }

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
            let matched = TouchDriver.openedInterfaces
                .contains { $0.usagePage == usagePage && $0.usage == usage }
            return TouchInterfaceInfo(usagePage: usagePage, usage: usage,
                                      elementCount: elementCount, matchedByDriver: matched)
        }
        return infos.sorted {
            if $0.matchedByDriver != $1.matchedByDriver { return $0.matchedByDriver }
            return ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage)
        }
    }
}
