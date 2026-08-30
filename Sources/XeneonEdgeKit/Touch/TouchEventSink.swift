// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything the touch state machine does to the outside world, behind an
// injectable seam — that is what makes the gesture logic testable without
// a device and without generating real clicks.

import CoreGraphics
import Foundation

/// A mouse event the touch driver wants to synthesize.
public struct SynthesizedMouseEvent: Equatable {
    public enum Kind: Equatable {
        case leftDown, leftUp, leftDragged, rightDown, rightUp, moved
    }
    public var kind: Kind
    public var point: CGPoint
    /// CGEvent click state (1 = single, 2 = double); 0 = do not set it.
    public var clickState: Int64

    public init(kind: Kind, point: CGPoint, clickState: Int64) {
        self.kind = kind
        self.point = point
        self.clickState = clickState
    }
}

/// Everything the touch state machine does to the outside world. The
/// production implementation is `CGEventTouchSink`; tests plug in a
/// recording double — that makes the gesture logic testable without
/// hardware and without emitting real clicks.
public protocol TouchEventSink: AnyObject {
    func post(_ event: SynthesizedMouseEvent)
    /// Moves the cursor without an event and re-couples it to the mouse.
    func warpCursor(to point: CGPoint)
    /// Current cursor position in global CoreGraphics coordinates.
    func cursorLocation() -> CGPoint?
    /// Clock seam (long press, double tap).
    func now() -> Date
    /// Timer seam (long-press deadline, delayed cursor restore).
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void)
}

/// Production sink: real CGEvents on the HID event tap.
public final class CGEventTouchSink: TouchEventSink {
    // A cursor warp starts the local-events-suppression interval (0.25s by
    // default), during which posted events get swallowed. A private source
    // lets us set that to 0.
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    public init() {}

    public func post(_ event: SynthesizedMouseEvent) {
        let (type, button): (CGEventType, CGMouseButton)
        switch event.kind {
        case .leftDown: (type, button) = (.leftMouseDown, .left)
        case .leftUp: (type, button) = (.leftMouseUp, .left)
        case .leftDragged: (type, button) = (.leftMouseDragged, .left)
        case .rightDown: (type, button) = (.rightMouseDown, .right)
        case .rightUp: (type, button) = (.rightMouseUp, .right)
        case .moved: (type, button) = (.mouseMoved, .left)
        }
        guard let cgEvent = CGEvent(mouseEventSource: source, mouseType: type,
                                    mouseCursorPosition: event.point, mouseButton: button)
        else { return }
        if event.clickState > 0 {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: event.clickState)
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    public func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Without this, the cursor stays decoupled from the HID mouse and
        // the next physical movement snaps it back to the old position.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    public func now() -> Date { Date() }

    public func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
