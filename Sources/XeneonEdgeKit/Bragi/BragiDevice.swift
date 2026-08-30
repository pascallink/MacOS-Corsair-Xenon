// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Corsair "Bragi" / Protocol V2 request/response logic for the XENEON EDGE
// vendor control interface. The IOKit transport lives in BragiTransport.swift
// so this type stays testable without hardware.

import Foundation

public enum BragiError: Error, CustomStringConvertible {
    case deviceNotFound
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout
    case badResponse
    case writesDisabled(UInt8)

    public var description: String {
        switch self {
        case .deviceNotFound: return "XENEON EDGE control interface (1b1c:1d0d) not found"
        case .openFailed(let r): return String(format: "failed to open HID device (IOReturn 0x%08X)", r)
        case .writeFailed(let r): return String(format: "failed to write HID report (IOReturn 0x%08X)", r)
        case .timeout: return "device did not answer in time"
        case .badResponse: return "device answered, but the response did not echo the command"
        case .writesDisabled(let cmd):
            return String(format: "blocked state-changing command 0x%02X: " +
                "only read commands are allowed (write gate; see PROTOCOL-MACOS.md)", cmd)
        }
    }
}

/// Synchronous request/response channel to the Edge's vendor HID interface.
/// All calls are blocking; use from a background queue.
///
/// FIRMWARE SAFETY — write gate:
/// This transport refuses to transmit anything but the read-only commands
/// GET (0x02) and block-read (0x08) unless `dangerouslyAllowWrites` is set
/// explicitly. Neither the app nor the CLI ever set it. Firmware-update /
/// flash commands are not implemented anywhere in this codebase, so a bad
/// GET at worst returns garbage — it cannot alter device state.
public final class BragiDevice {
    /// Payload command bytes that never change device state.
    private static let readOnlyCommands: Set<UInt8> = [BragiCommand.get, 0x08]

    /// Off by default. Must be set knowingly by a developer to send SET /
    /// mode-switch / endpoint commands; nothing in this project sets it.
    public var dangerouslyAllowWrites = false

    /// True when the frame only reads state (passes the write gate).
    public static func isReadOnly(_ frame: BragiFrame) -> Bool {
        readOnlyCommands.contains(frame.payload.first ?? 0)
    }

    private let transport: BragiTransport

    public var manufacturer: String { transport.manufacturer }
    public var product: String { transport.product }
    public var serialNumber: String { transport.serialNumber }

    // MARK: Discovery

    /// Test seam: wraps an arbitrary transport.
    public init(transport: BragiTransport) {
        self.transport = transport
    }

    /// Finds the first XENEON EDGE vendor interface on the system.
    public static func find() -> BragiDevice? {
        guard let transport = IOHIDBragiTransport.find() else { return nil }
        return BragiDevice(transport: transport)
    }

    // MARK: Session

    public func open() throws { try transport.open() }
    public func close() { transport.close() }

    // MARK: I/O

    /// Sends one 64-byte frame. Frames whose command byte is not read-only
    /// are rejected unless `dangerouslyAllowWrites` was set (firmware-safety
    /// write gate).
    public func send(_ frame: BragiFrame) throws {
        guard Self.isReadOnly(frame) || dangerouslyAllowWrites else {
            throw BragiError.writesDisabled(frame.payload.first ?? 0)
        }
        // The buffer MUST contain the report id byte 0x01. A/B-verified on
        // the real device: 64 bytes incl. id -> answer; 63 bytes without id
        // -> silence. IOHIDDeviceSetReport reports kIOReturnSuccess either
        // way, so the failure only surfaces later, as a timeout.
        try transport.setOutputReport(reportID: EdgeConstants.reportID, report: frame.bytes)
    }

    /// Sends a frame and waits for the next input report.
    public func transfer(_ frame: BragiFrame, timeout: TimeInterval = 1.0) throws -> [UInt8] {
        transport.clearPendingInput()
        try send(frame)
        return try transport.nextInputReport(timeout: timeout)
    }

    // MARK: High-level commands

    /// GET a property and return the data after the echoed command pair.
    public func getProperty(_ property: UInt8) throws -> [UInt8] {
        let frame = BragiFrame.get(property: property)
        let response = try transfer(frame)
        guard let data = BragiFrame.responseData(request: frame, response: response) else {
            throw BragiError.badResponse
        }
        return data
    }

    /// Probes the firmware property slot (0x13) and returns the raw response
    /// for diagnostics. Response semantics are still being mapped by the
    /// community; the framing itself is verified.
    public func probeFirmware() throws -> [UInt8] {
        try getProperty(BragiProperty.firmware)
    }
}
