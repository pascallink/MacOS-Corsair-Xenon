// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import XeneonEdgeKit

@Suite struct DDCServiceTests {
    /// Fixture modeled after the real measurements on the test rig: a dead
    /// service (dispextE, no framebuffer, no user client) at index 0, the
    /// Edge at index 1, and two identical BenQ RD280UA monitors sharing one
    /// EDID serial at indices 2 and 3.
    private let fixture: [DDCServiceInfo] = [
        DDCServiceInfo(portTag: "dispextE", productName: "", vendorNumber: nil,
                       modelNumber: nil, serialNumber: nil, hasUserClient: false, index: 0),
        DDCServiceInfo(portTag: "dispext2", productName: "XENEON EDGE", vendorNumber: 3672,
                       modelNumber: 60672, serialNumber: 16843009, hasUserClient: true, index: 1),
        DDCServiceInfo(portTag: "dispext0", productName: "BenQ RD280UA", vendorNumber: 2513,
                       modelNumber: 32915, serialNumber: 0, hasUserClient: true, index: 2),
        DDCServiceInfo(portTag: "dispext1", productName: "BenQ RD280UA", vendorNumber: 2513,
                       modelNumber: 32915, serialNumber: 0, hasUserClient: true, index: 3),
    ]

    @Test func deadServiceAtIndexZeroIsNeverSelected() {
        // Exactly today's shipping bug: index 0 is dead but still "External".
        let match = DDCServiceLocator.select(fixture, vendorNumber: 0, modelNumber: 0, serialNumber: 0)
        #expect(match == nil)
        #expect(!fixture[0].isUsable)
    }

    @Test func edgeIsFoundByEdidIdentity() {
        let match = DDCServiceLocator.select(fixture, vendorNumber: 3672, modelNumber: 60672,
                                             serialNumber: 16843009)
        #expect(match?.portTag == "dispext2")
    }

    @Test func unknownIdentityReturnsNil() {
        let match = DDCServiceLocator.select(fixture, vendorNumber: 9999, modelNumber: 9999,
                                             serialNumber: 9999)
        #expect(match == nil)
    }

    @Test func identicalDisplaysTakeTheFirstUsableMatch() {
        let match = DDCServiceLocator.select(fixture, vendorNumber: 2513, modelNumber: 32915,
                                             serialNumber: 0)
        #expect(match?.portTag == "dispext0")
    }

    @Test func nameHintFallbackMatchesCaseInsensitively() {
        let match = DDCServiceLocator.select(fixture, productNameContains: "xeneon")
        #expect(match?.portTag == "dispext2")
    }

    @Test func nameHintFallbackSkipsUnusableServices() {
        let deadWithName = DDCServiceInfo(portTag: "dispextE", productName: "XENEON GHOST",
                                          vendorNumber: nil, modelNumber: nil, serialNumber: nil,
                                          hasUserClient: false, index: 0)
        let match = DDCServiceLocator.select([deadWithName] + fixture, productNameContains: "xeneon")
        #expect(match?.portTag == "dispext2")
    }

    @Test func serviceWithoutFramebufferIsNotUsable() {
        #expect(!fixture[0].isUsable)
        #expect(fixture[0].productName.isEmpty)
    }

    @Test func indexOrderIsPreserved() {
        #expect(fixture.map(\.index) == [0, 1, 2, 3])
    }
}
