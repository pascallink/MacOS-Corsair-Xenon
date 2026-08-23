// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Corsair "Bragi" / Protocol V2 framing for the XENEON EDGE vendor HID
// interface. Transfers are 64-byte reports: [0x01 report id][63 payload].
// The payload starts with a command pair {group, id}; the device answers by
// echoing the command pair followed by response data.
//
// Command status (see PROTOCOL-MACOS.md):
//   VERIFIED  — proven against real hardware by the community
//   CANDIDATE — taken from open-source implementations of sibling devices

import Foundation

public enum BragiCommand {
    /// Set property (write). CANDIDATE.
    public static let set: UInt8 = 0x01
    /// Get property (read). VERIFIED framing (firmware echo test).
    public static let get: UInt8 = 0x02
    /// Close endpoint. CANDIDATE.
    public static let closeEndpoint: [UInt8] = [0x05, 0x01, 0x01]
    /// Block read. CANDIDATE.
    public static let read: [UInt8] = [0x08, 0x01]
    /// Open endpoint / start transaction. CANDIDATE.
    public static let openEndpoint: [UInt8] = [0x0D, 0x01]

    /// Enter software mode (host-driven). CANDIDATE.
    public static let softwareMode: [UInt8] = [0x01, 0x03, 0x00, 0x02]
    /// Enter hardware mode (device-driven). CANDIDATE.
    public static let hardwareMode: [UInt8] = [0x01, 0x03, 0x00, 0x01]
}

public enum BragiProperty {
    /// Firmware/property slot probed by the community; returns a length-prefixed
    /// blob on the Edge. VERIFIED to produce a well-formed echo response.
    public static let firmware: UInt8 = 0x13
}

/// A single 64-byte Bragi report.
public struct BragiFrame {
    /// Full frame including the leading report id byte.
    public private(set) var bytes: [UInt8]

    public init() {
        bytes = [UInt8](repeating: 0, count: EdgeConstants.reportSize)
        bytes[0] = EdgeConstants.reportID
    }

    public init(payload: [UInt8]) {
        self.init()
        setPayload(payload)
    }

    /// Payload = everything after the report id (63 bytes).
    public var payload: [UInt8] { Array(bytes.dropFirst()) }

    public mutating func setPayload(_ payload: [UInt8]) {
        precondition(payload.count <= EdgeConstants.reportSize - 1, "payload too large")
        for i in 1..<bytes.count { bytes[i] = 0 }
        for (i, b) in payload.enumerated() { bytes[i + 1] = b }
    }

    // MARK: Builders

    /// GET a property: payload {0x02, prop}.
    public static func get(property: UInt8) -> BragiFrame {
        BragiFrame(payload: [BragiCommand.get, property])
    }

    /// SET a property: payload {0x01, prop, value...}.
    public static func set(property: UInt8, value: [UInt8]) -> BragiFrame {
        BragiFrame(payload: [BragiCommand.set, property] + value)
    }

    /// Raw payload frame.
    public static func raw(_ payload: [UInt8]) -> BragiFrame {
        BragiFrame(payload: payload)
    }

    // MARK: Response parsing

    /// The device echoes the command pair of the request; the response data
    /// follows. Returns nil when the response does not echo `request`.
    public static func responseData(request: BragiFrame, response: [UInt8]) -> [UInt8]? {
        // Response may or may not include the report id, depending on the
        // transport; normalize by stripping a leading 0x01 when present.
        var resp = response
        if resp.first == EdgeConstants.reportID { resp = Array(resp.dropFirst()) }
        let req = request.payload
        guard resp.count >= 2, req.count >= 2 else { return nil }
        guard resp[0] == req[0], resp[1] == req[1] else { return nil }
        return Array(resp.dropFirst(2))
    }

    public static func hexDump(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
