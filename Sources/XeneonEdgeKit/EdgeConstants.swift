// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Device identity of the CORSAIR XENEON EDGE 14.5" LCD touchscreen.
//
// Protocol facts are re-implemented from open sources and public
// reverse-engineering notes; no proprietary code involved. See
// PROTOCOL-MACOS.md for the sources and verification status.

import Foundation

public enum EdgeConstants {
    // MARK: Vendor HID interface (Corsair "Bragi" / Protocol V2)

    /// CORSAIR USB vendor id.
    public static let corsairVendorID: Int = 0x1B1C
    /// XENEON EDGE product id (vendor HID control interface).
    public static let edgeProductID: Int = 0x1D0D
    /// Vendor-specific HID usage page of the control interface.
    public static let vendorUsagePage: Int = 0xFF1B
    /// Usage inside the vendor page (application collection).
    public static let vendorUsage: Int = 0x91
    /// The control interface uses 64-byte reports: [report id 0x01][63 payload bytes].
    public static let reportID: UInt8 = 0x01
    public static let reportSize: Int = 64

    // MARK: Touchscreen controller (separate USB HID device)

    /// Touch controller USB vendor id (generic touch IC, not Corsair's VID).
    public static let touchVendorID: Int = 0x27C0
    /// Touch controller product id.
    public static let touchProductID: Int = 0x0859
    /// Default logical maximum of the X axis reported by the digitizer.
    public static let touchDefaultMaxX: Int = 16383
    /// Default logical maximum of the Y axis reported by the digitizer.
    public static let touchDefaultMaxY: Int = 9599
    /// Usage page / usage of the touch controller's digitizer interface
    /// (report id 0x0D). Under the same VID/PID the controller additionally
    /// reports a mouse-emulation interface and a vendor channel; matching on
    /// VID/PID alone opens all three.
    public static let digitizerUsagePage: Int = 0x0D
    public static let digitizerUsage: Int = 0x04
    /// Mouse-emulation interface of the same controller (report id 0x07):
    /// absolute X/Y over the same logical range as the digitizer, contact as
    /// Button 1. The Edge powers up in mouse mode, so this is the interface
    /// that actually delivers contacts — see `digitizerDeviceModeUsage`.
    public static let touchMouseUsagePage: Int = 0x01
    public static let touchMouseUsage: Int = 0x02
    /// Vendor channel of the touch controller (wch.cn); never opened.
    public static let touchVendorChannelUsagePage: Int = 0xFF0A
    public static let touchVendorChannelUsage: Int = 0xFF
    /// Finger collection inside the digitizer.
    public static let digitizerFingerUsage: Int = 0x22
    /// Device Configuration collection of the digitizer and its `Device Mode`
    /// feature (report id 0x21). The value selects how the controller
    /// reports: `digitizerDeviceModeMouse` (0) = mouse emulation, the
    /// digitizer interface then stays silent. Switching it is a HID *write*
    /// and deliberately not implemented here.
    public static let digitizerDeviceConfigUsage: Int = 0x0E
    public static let digitizerDeviceModeUsage: Int = 0x52
    public static let digitizerDeviceModeMouse: Int = 0
    /// Number of contact slots declared by the Edge's report descriptor.
    public static let touchContactSlots: Int = 10

    // MARK: Panel

    /// Native panel resolution (ultrawide 32:9 strip).
    public static let nativeWidth: CGFloat = 2560
    public static let nativeHeight: CGFloat = 720
    /// Substring of the display's localized name as exposed over EDID.
    public static let displayNameHint = "XENEON"
}
