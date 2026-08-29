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

final class WriteGateTests: XCTestCase {
    func testReadCommandsPassTheGate() {
        XCTAssertTrue(BragiDevice.isReadOnly(BragiFrame.get(property: 0x13)))
        XCTAssertTrue(BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.read)))
    }

    func testStateChangingCommandsAreBlocked() {
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.set(property: 0x03, value: [0x00, 0x02])))
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.softwareMode)))
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.hardwareMode)))
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.openEndpoint)))
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.closeEndpoint)))
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.raw([0xFF])))
        XCTAssertFalse(BragiDevice.isReadOnly(BragiFrame.raw([])))
    }
}

final class ConfigTests: XCTestCase {
    /// JSON numbers may not have a leading zero (RFC 8259 §6) — a common
    /// hand-edit slip (e.g. "08.37" instead of "8.37") makes the *entire*
    /// file fail to decode, not just that one field. AppConfig.load() must
    /// treat that as "use defaults for this run", not "reset the file" —
    /// covered separately by the app's ConfigStore (AppKit, untestable
    /// here), but the parsing behavior this bug hinges on is asserted here.
    func testLeadingZeroNumberFailsToDecode() {
        let json = #"{"weatherLongitude": 08.37}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)))
    }

    func testConfigRoundTrip() throws {
        var config = AppConfig()
        config.touchRotation = 180
        config.weatherPlaceName = "Hamburg"
        config.showClaudeUsage = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    /// Configs written by older versions miss newer keys — customized values
    /// must survive an update, missing fields fall back to defaults.
    func testPartialConfigKeepsCustomValuesAndDefaultsTheRest() throws {
        let json = #"{"touchRotation": 90, "showMedia": false}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.touchRotation, 90)
        XCTAssertFalse(decoded.showMedia)
        let defaults = AppConfig()
        XCTAssertEqual(decoded.showClaudeUsage, defaults.showClaudeUsage)
        XCTAssertEqual(decoded.weatherPlaceName, defaults.weatherPlaceName)
        // Launcher items carry a generated id, so compare their contents.
        XCTAssertEqual(decoded.launcherItems.map(\.target),
                       defaults.launcherItems.map(\.target))
    }

    /// Hand-written launcher entries may omit the internal id.
    func testLauncherItemWithoutIDDecodes() throws {
        let json = #"{"name": "Steam", "target": "/Applications/Steam.app", "symbol": "gamecontroller"}"#
        let item = try JSONDecoder().decode(LauncherItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.name, "Steam")
        XCTAssertEqual(item.target, "/Applications/Steam.app")
        XCTAssertEqual(item.symbol, "gamecontroller")
    }

    func testLauncherItemsSurviveConfigRoundTripWithoutIDs() throws {
        let json = """
        {"launcherItems": [{"name": "VS Code", "target": "com.microsoft.VSCode"}]}
        """
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.launcherItems.count, 1)
        XCTAssertEqual(decoded.launcherItems[0].name, "VS Code")
        XCTAssertEqual(decoded.launcherItems[0].symbol, "app") // default symbol
    }
}
