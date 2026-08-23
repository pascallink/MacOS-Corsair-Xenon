// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// IOKit HID transport to the XENEON EDGE vendor control interface
// (usage page 0xFF1B, 64-byte in/out reports, report id 0x01).

import Foundation
import IOKit.hid

public enum BragiError: Error, CustomStringConvertible {
    case deviceNotFound
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout
    case badResponse

    public var description: String {
        switch self {
        case .deviceNotFound: return "XENEON EDGE control interface (1b1c:1d0d) not found"
        case .openFailed(let r): return String(format: "failed to open HID device (IOReturn 0x%08X)", r)
        case .writeFailed(let r): return String(format: "failed to write HID report (IOReturn 0x%08X)", r)
        case .timeout: return "device did not answer in time"
        case .badResponse: return "device answered, but the response did not echo the command"
        }
    }
}

/// Synchronous request/response channel to the Edge's vendor HID interface.
/// All calls are blocking; use from a background queue.
public final class BragiDevice {
    private let device: IOHIDDevice
    // Stable buffer handed to IOKit for incoming reports; must outlive the
    // registration, hence manually managed.
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let responseLock = NSCondition()
    private var pendingResponse: [UInt8]?

    public private(set) var manufacturer: String = ""
    public private(set) var product: String = ""
    public private(set) var serialNumber: String = ""

    // MARK: Discovery

    /// Finds the first XENEON EDGE vendor interface on the system.
    public static func find() -> BragiDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: EdgeConstants.corsairVendorID,
            kIOHIDProductIDKey as String: EdgeConstants.edgeProductID,
            kIOHIDDeviceUsagePageKey as String: EdgeConstants.vendorUsagePage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let dev = set.first
        else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        return BragiDevice(device: dev)
    }

    private init(device: IOHIDDevice) {
        self.device = device
        self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: EdgeConstants.reportSize)
        self.reportBuffer.initialize(repeating: 0, count: EdgeConstants.reportSize)
        manufacturer = Self.stringProperty(device, kIOHIDManufacturerKey) ?? ""
        product = Self.stringProperty(device, kIOHIDProductKey) ?? ""
        serialNumber = Self.stringProperty(device, kIOHIDSerialNumberKey) ?? ""
    }

    deinit {
        reportBuffer.deallocate()
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    // MARK: Session

    /// Opens the device and starts listening for input reports on a private run loop.
    public func open() throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw BragiError.openFailed(result) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, reportBuffer, EdgeConstants.reportSize,
            { context, _, _, _, _, report, reportLength in
                guard let context else { return }
                let me = Unmanaged<BragiDevice>.fromOpaque(context).takeUnretainedValue()
                let bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
                me.responseLock.lock()
                me.pendingResponse = bytes
                me.responseLock.signal()
                me.responseLock.unlock()
            },
            context
        )
        // Dedicated thread so the caller does not have to run a run loop.
        let dev = device
        Thread.detachNewThread {
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopRun()
        }
    }

    public func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: I/O

    /// Sends one 64-byte frame. The report id byte is passed to IOKit as the
    /// report number; the remaining 63 bytes are the report data.
    public func send(_ frame: BragiFrame) throws {
        let data = Array(frame.bytes.dropFirst()) // strip report id byte
        let result = data.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeOutput,
                CFIndex(EdgeConstants.reportID),
                buf.baseAddress!, buf.count
            )
        }
        guard result == kIOReturnSuccess else { throw BragiError.writeFailed(result) }
    }

    /// Sends a frame and waits for the next input report.
    public func transfer(_ frame: BragiFrame, timeout: TimeInterval = 1.0) throws -> [UInt8] {
        responseLock.lock()
        pendingResponse = nil
        responseLock.unlock()

        try send(frame)

        responseLock.lock()
        defer { responseLock.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while pendingResponse == nil {
            if !responseLock.wait(until: deadline) { throw BragiError.timeout }
        }
        return pendingResponse!
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
