// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A decoded HID input value from the touch controller — the seam between
// IOKit and the (testable) state machine.

import Foundation

/// The HID interface of the touch controller a sample originated from. The
/// controller exposes both under one VID/PID and the driver opens both, so a
/// sample alone is ambiguous: X/Y carry the same (page, usage) on either.
public enum TouchInterface: String, Equatable {
    /// `0x0D`/`0x04`, report id 0x0D. Silent while the controller is in
    /// mouse mode.
    case digitizer
    /// `0x01`/`0x02`, report id 0x07. Absolute X/Y plus Button 1.
    case mouseEmulation
    /// Not classifiable — a device the driver did not index, or a sample fed
    /// directly by tests.
    case unknown
}

public struct TouchSample: Equatable {
    public var usagePage: UInt32
    public var usage: UInt32
    public var value: Int
    /// Logical maximum of the element; 0 = unknown.
    public var logicalMax: Int
    /// Contact slot this element belongs to. nil for elements outside a
    /// finger collection (Scan Time, Contact Count), for every element of
    /// the mouse-emulation interface (it has no slots) and as long as slot
    /// indexing has not delivered anything.
    public var slot: Int?
    /// Interface the value arrived on.
    public var interface: TouchInterface

    public init(usagePage: UInt32, usage: UInt32, value: Int,
                logicalMax: Int = 0, slot: Int? = nil,
                interface: TouchInterface = .unknown) {
        self.usagePage = usagePage
        self.usage = usage
        self.value = value
        self.logicalMax = logicalMax
        self.slot = slot
        self.interface = interface
    }
}
