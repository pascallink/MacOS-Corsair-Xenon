// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing
@testable import XeneonEdgeKit

@Suite struct TouchMappingTests {
    @Test func rawZeroMapsToTopLeft() {
        let p = TouchMapping.normalized(rawX: 0, rawY: 0, maxX: 16383, maxY: 9599,
                                        rotation: 0, invertX: false, invertY: false)
        #expect(p == CGPoint(x: 0, y: 0))
    }

    @Test func rawMaximumMapsToBottomRight() {
        let p = TouchMapping.normalized(rawX: 16383, rawY: 9599, maxX: 16383, maxY: 9599,
                                        rotation: 0, invertX: false, invertY: false)
        #expect(p == CGPoint(x: 1, y: 1))
    }

    @Test func valuesAboveMaximumAreClamped() {
        let over = TouchMapping.normalized(rawX: 20000, rawY: 20000, maxX: 16383, maxY: 9599,
                                           rotation: 0, invertX: false, invertY: false)
        #expect(over == CGPoint(x: 1, y: 1))
        let under = TouchMapping.normalized(rawX: -100, rawY: -100, maxX: 16383, maxY: 9599,
                                            rotation: 0, invertX: false, invertY: false)
        #expect(under == CGPoint(x: 0, y: 0))
    }

    @Test func zeroLogicalMaximumDoesNotDivideByZero() {
        let p = TouchMapping.normalized(rawX: 5, rawY: 5, maxX: 0, maxY: 0,
                                        rotation: 0, invertX: false, invertY: false)
        #expect(p.x.isFinite)
        #expect(p.y.isFinite)
    }

    @Test func rotation90() {
        let p = TouchMapping.normalized(rawX: Int(0.25 * 16383), rawY: Int(0.75 * 9599),
                                        maxX: 16383, maxY: 9599,
                                        rotation: 90, invertX: false, invertY: false)
        #expect(abs(p.x - 0.25) < 0.01)
        #expect(abs(p.y - 0.25) < 0.01)
    }

    @Test func rotation180() {
        let p = TouchMapping.normalized(rawX: Int(0.25 * 16383), rawY: Int(0.75 * 9599),
                                        maxX: 16383, maxY: 9599,
                                        rotation: 180, invertX: false, invertY: false)
        #expect(abs(p.x - 0.75) < 0.01)
        #expect(abs(p.y - 0.25) < 0.01)
    }

    @Test func rotation270() {
        let p = TouchMapping.normalized(rawX: Int(0.25 * 16383), rawY: Int(0.75 * 9599),
                                        maxX: 16383, maxY: 9599,
                                        rotation: 270, invertX: false, invertY: false)
        #expect(abs(p.x - 0.75) < 0.01)
        #expect(abs(p.y - 0.75) < 0.01)
    }

    @Test func rotationIsNormalized() {
        let base = TouchMapping.normalized(rawX: 4000, rawY: 4000, maxX: 16383, maxY: 9599,
                                           rotation: 90, invertX: false, invertY: false)
        let full = TouchMapping.normalized(rawX: 4000, rawY: 4000, maxX: 16383, maxY: 9599,
                                           rotation: 450, invertX: false, invertY: false)
        #expect(base == full)
        let negative = TouchMapping.normalized(rawX: 4000, rawY: 4000, maxX: 16383, maxY: 9599,
                                               rotation: -270, invertX: false, invertY: false)
        #expect(base == negative)
        let wrapped = TouchMapping.normalized(rawX: 4000, rawY: 4000, maxX: 16383, maxY: 9599,
                                              rotation: 360, invertX: false, invertY: false)
        let unrotated = TouchMapping.normalized(rawX: 4000, rawY: 4000, maxX: 16383, maxY: 9599,
                                                rotation: 0, invertX: false, invertY: false)
        #expect(wrapped == unrotated)
    }

    @Test func invertXOnly() {
        let p = TouchMapping.normalized(rawX: 0, rawY: 0, maxX: 16383, maxY: 9599,
                                        rotation: 0, invertX: true, invertY: false)
        #expect(p == CGPoint(x: 1, y: 0))
    }

    @Test func invertYOnly() {
        let p = TouchMapping.normalized(rawX: 0, rawY: 0, maxX: 16383, maxY: 9599,
                                        rotation: 0, invertX: false, invertY: true)
        #expect(p == CGPoint(x: 0, y: 1))
    }

    @Test func invertBoth() {
        let p = TouchMapping.normalized(rawX: 0, rawY: 0, maxX: 16383, maxY: 9599,
                                        rotation: 0, invertX: true, invertY: true)
        #expect(p == CGPoint(x: 1, y: 1))
    }

    @Test func rotationIsAppliedBeforeMirroring() {
        // Regression pin: rotating then mirroring (0.25, 0.75) at 90° gives
        // (0.25, 0.25) before mirroring, then invertX flips x to 0.75.
        let p = TouchMapping.normalized(rawX: Int(0.25 * 16383), rawY: Int(0.75 * 9599),
                                        maxX: 16383, maxY: 9599,
                                        rotation: 90, invertX: true, invertY: false)
        #expect(abs(p.x - 0.75) < 0.01)
        #expect(abs(p.y - 0.25) < 0.01)
    }

    @Test func rotationGroupCloses() {
        let once = TouchMapping.normalized(rawX: 4000, rawY: 2000, maxX: 16383, maxY: 9599,
                                           rotation: 90, invertX: false, invertY: false)
        let twice = TouchMapping.normalized(rawX: Int(once.x * 16383), rawY: Int(once.y * 9599),
                                            maxX: 16383, maxY: 9599,
                                            rotation: 90, invertX: false, invertY: false)
        let thrice = TouchMapping.normalized(rawX: Int(twice.x * 16383), rawY: Int(twice.y * 9599),
                                             maxX: 16383, maxY: 9599,
                                             rotation: 90, invertX: false, invertY: false)
        let direct270 = TouchMapping.normalized(rawX: 4000, rawY: 2000, maxX: 16383, maxY: 9599,
                                                rotation: 270, invertX: false, invertY: false)
        #expect(abs(thrice.x - direct270.x) < 0.01)
        #expect(abs(thrice.y - direct270.y) < 0.01)
    }

    @Test func globalPointUsesDisplayOrigin() {
        // Belies "top-left yields small x/y" from #4: the Edge's global
        // bounds start at (1280, 2560) on this test rig.
        let bounds = CGRect(x: 1280, y: 2560, width: 2560, height: 720)
        let p = EdgeDisplay.globalPoint(normalizedX: 0, normalizedY: 0, in: bounds)
        #expect(p == CGPoint(x: 1280, y: 2560))
    }

    @Test func globalPointClampsToBounds() {
        let bounds = CGRect(x: 1280, y: 2560, width: 2560, height: 720)
        let p = EdgeDisplay.globalPoint(normalizedX: 1, normalizedY: 1, in: bounds)
        #expect(p == CGPoint(x: 3839, y: 3279))
    }
}
