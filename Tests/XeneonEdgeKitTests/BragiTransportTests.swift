// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

/// Recording double: makes `BragiDevice`'s framing, write gate and report
/// layout testable without hardware.
final class RecordingBragiTransport: BragiTransport {
    var manufacturer = "CORSAIR"
    var product = "XENEON EDGE"
    var serialNumber = "320225465656"

    private(set) var sentReports: [(reportID: UInt8, bytes: [UInt8])] = []
    private(set) var clearCount = 0
    private(set) var callOrder: [String] = []
    var cannedResponse: [UInt8]?
    var responseDelayThrows = false

    func open() throws {}
    func close() {}

    func clearPendingInput() {
        clearCount += 1
        callOrder.append("clear")
    }

    func setOutputReport(reportID: UInt8, report: [UInt8]) throws {
        sentReports.append((reportID, report))
        callOrder.append("set")
    }

    func nextInputReport(timeout: TimeInterval) throws -> [UInt8] {
        callOrder.append("wait")
        if responseDelayThrows { throw BragiError.timeout }
        return cannedResponse ?? []
    }
}

@Suite struct BragiTransportTests {
    @Test func outputReportIs64BytesAndStartsWithTheReportID() throws {
        let transport = RecordingBragiTransport()
        let device = BragiDevice(transport: transport)
        try device.send(BragiFrame.get(property: 0x13))
        let sent = try #require(transport.sentReports.first)
        #expect(sent.bytes.count == 64)
        #expect(sent.bytes[0] == 0x01)
        #expect(sent.bytes[1] == 0x02)
        #expect(sent.bytes[2] == 0x13)
    }

    @Test func reportIDArgumentIsOne() throws {
        let transport = RecordingBragiTransport()
        let device = BragiDevice(transport: transport)
        try device.send(BragiFrame.get(property: 0x13))
        let sent = try #require(transport.sentReports.first)
        #expect(sent.reportID == EdgeConstants.reportID)
    }

    @Test func writeGateStillBlocksSetFrames() {
        let transport = RecordingBragiTransport()
        let device = BragiDevice(transport: transport)
        #expect(throws: BragiError.self) {
            try device.send(BragiFrame.set(property: 0x03, value: [0x00, 0x02]))
        }
        #expect(transport.sentReports.isEmpty)
    }

    @Test func writeGateLetsBlockReadThrough() throws {
        let transport = RecordingBragiTransport()
        let device = BragiDevice(transport: transport)
        try device.send(BragiFrame.raw(BragiCommand.read))
        #expect(transport.sentReports.count == 1)
    }

    @Test func dangerouslyAllowWritesIsOffByDefault() {
        #expect(!BragiDevice(transport: RecordingBragiTransport()).dangerouslyAllowWrites)
    }

    @Test func pendingInputIsClearedBeforeSending() throws {
        let transport = RecordingBragiTransport()
        transport.cannedResponse = [0x01, 0x02, 0x13, 0x00]
        let device = BragiDevice(transport: transport)
        _ = try device.transfer(BragiFrame.get(property: 0x13))
        #expect(transport.callOrder == ["clear", "set", "wait"])
    }

    @Test func transferReturnsTheDeviceResponse() throws {
        let transport = RecordingBragiTransport()
        var response: [UInt8] = [0x01, 0x02, 0x13, 0x00, 0x00, 0x14]
        response += [UInt8](repeating: 0xFF, count: 20)
        transport.cannedResponse = response
        let device = BragiDevice(transport: transport)
        let received = try device.transfer(BragiFrame.get(property: 0x13))
        #expect(received == response)
    }

    @Test func getPropertyStripsTheEchoedCommandPair() throws {
        let transport = RecordingBragiTransport()
        var response: [UInt8] = [0x01, 0x02, 0x13, 0x00, 0x00, 0x14]
        response += [UInt8](repeating: 0xFF, count: 20)
        transport.cannedResponse = response
        let device = BragiDevice(transport: transport)
        let data = try device.getProperty(0x13)
        #expect(Array(data.prefix(3)) == [0x00, 0x00, 0x14])
    }

    @Test func mismatchedEchoBecomesBadResponse() {
        let transport = RecordingBragiTransport()
        transport.cannedResponse = [0x01, 0x02, 0x14, 0xAA] // wrong property echoed
        let device = BragiDevice(transport: transport)
        #expect(throws: BragiError.self) {
            _ = try device.getProperty(0x13)
        }
    }

    @Test func timeoutSurfacesAsBragiErrorTimeout() {
        let transport = RecordingBragiTransport()
        transport.responseDelayThrows = true
        let device = BragiDevice(transport: transport)
        #expect {
            try device.transfer(BragiFrame.get(property: 0x13))
        } throws: { error in
            guard case BragiError.timeout = error else { return false }
            return true
        }
    }
}
