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
// Requires the Accessibility permission (event injection) and Input
// Monitoring (HID capture).

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

public struct TouchDriverConfiguration {
    /// Emit drags (down/drag/up). When false, only taps are emitted and the
    /// cursor jumps back to where it was before the tap.
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

    public init() {}
}

public protocol TouchDriverDelegate: AnyObject {
    func touchDriver(_ driver: TouchDriver, deviceConnected connected: Bool)
    func touchDriver(_ driver: TouchDriver, didTouchAt point: CGPoint, down: Bool)
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

    public private(set) var deviceConnected = false

    private var manager: IOHIDManager?

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

    // MARK: Lifecycle

    /// Starts HID capture; callbacks arrive on the given run loop.
    public func start(runLoop: CFRunLoop = CFRunLoopGetMain()) {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: EdgeConstants.touchVendorID,
            kIOHIDProductIDKey as String: EdgeConstants.touchProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
            me.deviceConnected = true
            me.delegate?.touchDriver(me, deviceConnected: true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(context).takeUnretainedValue()
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

    private func handle(value: IOHIDValue) {
        guard enabled else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        switch (usagePage, usage) {
        case (0x01, 0x30): // Generic Desktop / X
            rawX = intValue
            let logicalMax = IOHIDElementGetLogicalMax(element)
            if logicalMax > 0 { maxX = logicalMax }
            if touching { contactMoved() }
        case (0x01, 0x31): // Generic Desktop / Y
            rawY = intValue
            let logicalMax = IOHIDElementGetLogicalMax(element)
            if logicalMax > 0 { maxY = logicalMax }
            if touching { contactMoved() }
        case (0x09, 0x01), // Button 1 (Xeneon Edge touch controller)
             (0x0D, 0x42): // Digitizer / Tip Switch (standard)
            if intValue != 0 { contactDown() } else { contactUp() }
        default:
            break
        }
    }

    // MARK: Mapping

    private func currentPoint() -> CGPoint? {
        var nx = CGFloat(rawX) / CGFloat(max(maxX, 1))
        var ny = CGFloat(rawY) / CGFloat(max(maxY, 1))
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)

        switch ((configuration.rotation % 360) + 360) % 360 {
        case 90: (nx, ny) = (1 - ny, nx)
        case 180: (nx, ny) = (1 - nx, 1 - ny)
        case 270: (nx, ny) = (ny, 1 - nx)
        default: break
        }
        if configuration.invertX { nx = 1 - nx }
        if configuration.invertY { ny = 1 - ny }

        guard let display else {
            // No Edge display located: report panel-native coordinates so
            // diagnostics still work; injection stays off in that case.
            return CGPoint(x: nx * EdgeConstants.nativeWidth,
                           y: ny * EdgeConstants.nativeHeight)
        }
        return display.globalPoint(normalizedX: nx, normalizedY: ny)
    }

    // MARK: Contact state machine

    private func contactDown() {
        guard !touching, let point = currentPoint() else { return }
        touching = true
        dragging = false
        longPressFired = false
        downPoint = point
        downTime = Date()
        lastPoint = point
        savedCursorPosition = configuration.dragEnabled ? nil : CGEvent(source: nil)?.location

        delegate?.touchDriver(self, didTouchAt: point, down: true)

        if configuration.dragEnabled {
            postMouse(.leftMouseDown, at: point, clickState: clickState(for: point))
        }
        if configuration.longPressRightClick {
            let deadline = DispatchTime.now() + configuration.longPressSeconds
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                self?.longPressCheck()
            }
        }
    }

    private func contactMoved() {
        guard touching, let point = currentPoint() else { return }
        lastPoint = point
        if configuration.dragEnabled {
            if dragging || distance(point, downPoint) > configuration.tapSlop {
                dragging = true
                postMouse(.leftMouseDragged, at: point, clickState: 1)
            }
        }
    }

    private func contactUp() {
        guard touching else { return }
        touching = false
        let point = lastPoint
        delegate?.touchDriver(self, didTouchAt: point, down: false)

        if longPressFired {
            return // right click already delivered
        }

        if configuration.dragEnabled {
            postMouse(.leftMouseUp, at: point, clickState: clickState(for: downPoint))
        } else {
            // Tap-only mode: click, then restore the cursor.
            let state = clickState(for: downPoint)
            postMouse(.leftMouseDown, at: point, clickState: state)
            postMouse(.leftMouseUp, at: point, clickState: state)
            if let saved = savedCursorPosition {
                CGWarpMouseCursorPosition(saved)
            }
        }

        if !dragging {
            lastTapTime = Date()
            lastTapPoint = downPoint
        }
    }

    private func longPressCheck() {
        guard touching, !dragging, !longPressFired else { return }
        guard Date().timeIntervalSince(downTime) >= configuration.longPressSeconds - 0.01 else { return }
        guard distance(lastPoint, downPoint) <= configuration.tapSlop else { return }
        longPressFired = true
        if configuration.dragEnabled {
            // Cancel the pending left click before the right click.
            postMouse(.leftMouseUp, at: downPoint, clickState: 0)
        }
        postMouse(.rightMouseDown, at: downPoint, clickState: 1, button: .right)
        postMouse(.rightMouseUp, at: downPoint, clickState: 1, button: .right)
    }

    private func clickState(for point: CGPoint) -> Int64 {
        let isDouble = Date().timeIntervalSince(lastTapTime) < configuration.doubleTapSeconds
            && distance(point, lastTapPoint) <= configuration.tapSlop * 2
        return isDouble ? 2 : 1
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: Event injection

    private func postMouse(_ type: CGEventType, at point: CGPoint,
                           clickState: Int64, button: CGMouseButton = .left) {
        guard injectionEnabled, display != nil else { return }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }
}
