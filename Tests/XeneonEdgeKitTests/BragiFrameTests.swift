// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import XeneonEdgeKit

@Suite struct BragiFrameTests {
    @Test func frameIs64BytesWithReportID() {
        let frame = BragiFrame.get(property: BragiProperty.firmware)
        #expect(frame.bytes.count == 64)
        #expect(frame.bytes[0] == 0x01)
        #expect(frame.bytes[1] == 0x02) // GET
        #expect(frame.bytes[2] == 0x13) // firmware property
        #expect(frame.bytes.dropFirst(3).allSatisfy { $0 == 0 })
    }

    @Test func setFrame() {
        let frame = BragiFrame.set(property: 0x03, value: [0x00, 0x02])
        #expect(Array(frame.bytes[1...4]) == [0x01, 0x03, 0x00, 0x02])
    }

    @Test func responseEchoParsing() throws {
        // Real capture: TX 01 02 13 ... -> RX 01 02 13 00 00 14 FF ...
        let request = BragiFrame.get(property: 0x13)
        var response: [UInt8] = [0x01, 0x02, 0x13, 0x00, 0x00, 0x14]
        response += [UInt8](repeating: 0xFF, count: 20)

        let data = try #require(BragiFrame.responseData(request: request, response: response))
        #expect(Array(data.prefix(3)) == [0x00, 0x00, 0x14])
    }

    @Test func responseWithoutReportID() {
        let request = BragiFrame.get(property: 0x13)
        let response: [UInt8] = [0x02, 0x13, 0xAA, 0xBB]
        let data = BragiFrame.responseData(request: request, response: response)
        #expect(data == [0xAA, 0xBB])
    }

    @Test func mismatchedEchoRejected() {
        let request = BragiFrame.get(property: 0x13)
        let response: [UInt8] = [0x01, 0x02, 0x14, 0x00]
        #expect(BragiFrame.responseData(request: request, response: response) == nil)
    }

    @Test func payloadRoundTrip() {
        var frame = BragiFrame()
        frame.setPayload([0xDE, 0xAD])
        #expect(frame.payload.count == 63)
        #expect(Array(frame.payload.prefix(2)) == [0xDE, 0xAD])
    }
}

@Suite struct WriteGateTests {
    @Test func readCommandsPassTheGate() {
        #expect(BragiDevice.isReadOnly(BragiFrame.get(property: 0x13)))
        #expect(BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.read)))
    }

    @Test func stateChangingCommandsAreBlocked() {
        #expect(!BragiDevice.isReadOnly(BragiFrame.set(property: 0x03, value: [0x00, 0x02])))
        #expect(!BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.softwareMode)))
        #expect(!BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.hardwareMode)))
        #expect(!BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.openEndpoint)))
        #expect(!BragiDevice.isReadOnly(BragiFrame.raw(BragiCommand.closeEndpoint)))
        #expect(!BragiDevice.isReadOnly(BragiFrame.raw([0xFF])))
        #expect(!BragiDevice.isReadOnly(BragiFrame.raw([])))
    }
}

@Suite struct ConfigTests {
    /// JSON numbers may not have a leading zero (RFC 8259 §6) — a common
    /// hand-edit slip (e.g. "08.37" instead of "8.37") makes the *entire*
    /// file fail to decode, not just that one field. AppConfig.load() must
    /// treat that as "use defaults for this run", not "reset the file" —
    /// covered separately by the app's ConfigStore (AppKit, untestable
    /// here), but the parsing behavior this bug hinges on is asserted here.
    @Test func leadingZeroNumberFailsToDecode() {
        let json = #"{"weatherLongitude": 08.37}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        }
    }

    @Test func configRoundTrip() throws {
        var config = AppConfig()
        config.touchRotation = 180
        config.weatherPlaceName = "Hamburg"
        config.showClaudeUsage = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == config)
    }

    /// Configs written by older versions miss newer keys — customized values
    /// must survive an update, missing fields fall back to defaults.
    @Test func partialConfigKeepsCustomValuesAndDefaultsTheRest() throws {
        let json = #"{"touchRotation": 90, "showMedia": false}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.touchRotation == 90)
        #expect(!decoded.showMedia)
        let defaults = AppConfig()
        #expect(decoded.showClaudeUsage == defaults.showClaudeUsage)
        #expect(decoded.weatherPlaceName == defaults.weatherPlaceName)
        // Launcher items carry a generated id, so compare their contents.
        #expect(decoded.launcherItems.map(\.target) == defaults.launcherItems.map(\.target))
    }

    /// Hand-written launcher entries may omit the internal id.
    @Test func launcherItemWithoutIDDecodes() throws {
        let json = #"{"name": "Steam", "target": "/Applications/Steam.app", "symbol": "gamecontroller"}"#
        let item = try JSONDecoder().decode(LauncherItem.self, from: Data(json.utf8))
        #expect(item.name == "Steam")
        #expect(item.target == "/Applications/Steam.app")
        #expect(item.symbol == "gamecontroller")
    }

    @Test func launcherItemsSurviveConfigRoundTripWithoutIDs() throws {
        let json = """
        {"launcherItems": [{"name": "VS Code", "target": "com.microsoft.VSCode"}]}
        """
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.launcherItems.count == 1)
        #expect(decoded.launcherItems[0].name == "VS Code")
        #expect(decoded.launcherItems[0].symbol == "app") // default symbol
    }

    @Test func restoreCursorAfterTouchDefaultsToOn() {
        #expect(AppConfig().restoreCursorAfterTouch)
    }

    /// macOS drives the cursor from the same reports, so the seize is on by
    /// default — otherwise every touch moves the pointer twice.
    @Test func suppressSystemCursorDefaultsToOn() {
        #expect(AppConfig().suppressSystemCursor)
        #expect(TouchDriverConfiguration().suppressSystemCursor)
    }

    /// Issue #10: existing config.json files predate both keys — they must
    /// fall back to the new defaults rather than resetting the whole file.
    @Test func oldConfigWithoutNewKeysGetsTheNewDefaults() throws {
        let json = #"{"ddcDisplayIndex": 0}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.restoreCursorAfterTouch)
        #expect(decoded.suppressSystemCursor)
        #expect(decoded.ddcSelectEdgeByIdentity)
        #expect(decoded.ddcDisplayIndex == 0)
    }

    @Test func newKeysSurviveARoundTrip() throws {
        var config = AppConfig()
        config.restoreCursorAfterTouch = false
        config.suppressSystemCursor = false
        config.ddcSelectEdgeByIdentity = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == config)
    }
}
