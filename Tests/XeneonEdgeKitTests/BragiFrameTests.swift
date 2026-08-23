// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import XeneonEdgeKit

final class BragiFrameTests: XCTestCase {
    func testFrameIs64BytesWithReportID() {
        let frame = BragiFrame.get(property: BragiProperty.firmware)
        XCTAssertEqual(frame.bytes.count, 64)
        XCTAssertEqual(frame.bytes[0], 0x01)
        XCTAssertEqual(frame.bytes[1], 0x02) // GET
        XCTAssertEqual(frame.bytes[2], 0x13) // firmware property
        XCTAssertTrue(frame.bytes.dropFirst(3).allSatisfy { $0 == 0 })
    }

    func testSetFrame() {
        let frame = BragiFrame.set(property: 0x03, value: [0x00, 0x02])
        XCTAssertEqual(Array(frame.bytes[1...4]), [0x01, 0x03, 0x00, 0x02])
    }

    func testResponseEchoParsing() {
        // Real capture: TX 01 02 13 ... -> RX 01 02 13 00 00 14 FF ...
        let request = BragiFrame.get(property: 0x13)
        var response: [UInt8] = [0x01, 0x02, 0x13, 0x00, 0x00, 0x14]
        response += [UInt8](repeating: 0xFF, count: 20)

        let data = BragiFrame.responseData(request: request, response: response)
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(3)), [0x00, 0x00, 0x14])
    }

    func testResponseWithoutReportID() {
        let request = BragiFrame.get(property: 0x13)
        let response: [UInt8] = [0x02, 0x13, 0xAA, 0xBB]
        let data = BragiFrame.responseData(request: request, response: response)
        XCTAssertEqual(data, [0xAA, 0xBB])
    }

    func testMismatchedEchoRejected() {
        let request = BragiFrame.get(property: 0x13)
        let response: [UInt8] = [0x01, 0x02, 0x14, 0x00]
        XCTAssertNil(BragiFrame.responseData(request: request, response: response))
    }

    func testPayloadRoundTrip() {
        var frame = BragiFrame()
        frame.setPayload([0xDE, 0xAD])
        XCTAssertEqual(frame.payload.count, 63)
        XCTAssertEqual(Array(frame.payload.prefix(2)), [0xDE, 0xAD])
    }
}

final class ConfigTests: XCTestCase {
    func testConfigRoundTrip() throws {
        var config = AppConfig()
        config.touchRotation = 180
        config.weatherPlaceName = "Hamburg"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}
