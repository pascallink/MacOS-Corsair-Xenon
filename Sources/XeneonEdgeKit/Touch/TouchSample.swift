// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A decoded HID input value from the touch controller — the seam between
// IOKit and the (testable) state machine.

import Foundation

public struct TouchSample: Equatable {
    public var usagePage: UInt32
    public var usage: UInt32
    public var value: Int
    /// Logical maximum of the element; 0 = unknown.
    public var logicalMax: Int
    /// Contact slot this element belongs to. nil for elements outside a
    /// finger collection (Scan Time, Contact Count) and as long as slot
    /// indexing has not delivered anything.
    public var slot: Int?

    public init(usagePage: UInt32, usage: UInt32, value: Int,
                logicalMax: Int = 0, slot: Int? = nil) {
        self.usagePage = usagePage
        self.usage = usage
        self.value = value
        self.logicalMax = logicalMax
        self.slot = slot
    }
}
