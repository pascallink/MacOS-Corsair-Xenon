// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure coordinate mapping for the digitizer — deliberately free of IOKit and
// NSScreen so rotation and mirroring are testable without a device.

import CoreGraphics

public enum TouchMapping {
    /// Normalizes raw values to 0...1 (origin top-left of the panel) and then
    /// applies rotation and mirroring — the exact order
    /// `TouchDriver.currentPoint()` used to compute internally.
    /// - Parameter rotation: degrees clockwise; arbitrary multiples and
    ///   negative values are normalized to 0/90/180/270.
    public static func normalized(rawX: Int, rawY: Int,
                                  maxX: Int, maxY: Int,
                                  rotation: Int,
                                  invertX: Bool, invertY: Bool) -> CGPoint {
        var nx = CGFloat(rawX) / CGFloat(max(maxX, 1))
        var ny = CGFloat(rawY) / CGFloat(max(maxY, 1))
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)

        switch ((rotation % 360) + 360) % 360 {
        case 90: (nx, ny) = (1 - ny, nx)
        case 180: (nx, ny) = (1 - nx, 1 - ny)
        case 270: (nx, ny) = (ny, 1 - nx)
        default: break
        }
        if invertX { nx = 1 - nx }
        if invertY { ny = 1 - ny }

        return CGPoint(x: nx, y: ny)
    }
}
