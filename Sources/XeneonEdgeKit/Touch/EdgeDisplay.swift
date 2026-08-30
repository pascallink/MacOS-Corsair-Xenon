// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Locates the XENEON EDGE among the connected displays and provides its
// global bounds in CoreGraphics coordinates (origin top-left of the main
// display, y grows downwards — the space CGEvent works in).

import AppKit
import CoreGraphics

public struct EdgeDisplay {
    public let displayID: CGDirectDisplayID
    public let screen: NSScreen
    /// Bounds in the global CoreGraphics (top-left origin) coordinate space.
    public var bounds: CGRect { CGDisplayBounds(displayID) }
    public var localizedName: String { screen.localizedName }

    /// Finds the Edge: first by EDID name, then by its unmistakable 32:9
    /// ultrawide-strip geometry (2560x720 native, also matched when scaled).
    public static func find() -> EdgeDisplay? {
        let screens = NSScreen.screens

        if let byName = screens.first(where: {
            $0.localizedName.uppercased().contains(EdgeConstants.displayNameHint)
        }) {
            return EdgeDisplay(screen: byName)
        }

        let nativeAspect = EdgeConstants.nativeWidth / EdgeConstants.nativeHeight
        if let byAspect = screens.first(where: { screen in
            let f = screen.frame
            guard f.height > 0 else { return false }
            return abs(f.width / f.height - nativeAspect) < 0.02
        }) {
            return EdgeDisplay(screen: byAspect)
        }
        return nil
    }

    public init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        self.displayID = CGDirectDisplayID(number.uint32Value)
        self.screen = screen
    }

    /// Maps a normalized touch position (0...1 in both axes, origin top-left
    /// of the panel) to a point in global CoreGraphics coordinates.
    public func globalPoint(normalizedX: CGFloat, normalizedY: CGFloat) -> CGPoint {
        Self.globalPoint(normalizedX: normalizedX, normalizedY: normalizedY, in: bounds)
    }
}

public extension EdgeDisplay {
    /// Pure form of `globalPoint(normalizedX:normalizedY:)`; kept separate so
    /// the mapping is checkable without a real NSScreen.
    static func globalPoint(normalizedX: CGFloat, normalizedY: CGFloat,
                            in bounds: CGRect) -> CGPoint {
        let b = bounds
        let x = b.origin.x + normalizedX * b.width
        let y = b.origin.y + normalizedY * b.height
        return CGPoint(x: min(max(x, b.minX), b.maxX - 1),
                       y: min(max(y, b.minY), b.maxY - 1))
    }
}
