// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// IOKit HID transport to the XENEON EDGE vendor control interface, pulled
// out of BragiDevice so framing, the write gate and the report layout are
// testable without hardware.

import Foundation
import IOKit.hid

/// A request/response channel to a Bragi device.
public protocol BragiTransport: AnyObject {
    var manufacturer: String { get }
    var product: String { get }
    var serialNumber: String { get }

    /// Opens the device and returns only once incoming reports can actually
    /// be delivered.
    func open() throws
    func close()
    /// Discards a response that arrived before the next request.
    func clearPendingInput()
    /// Writes an output report. `report` is the **full** buffer including
    /// the leading report id byte — the Edge reads the report id from the
    /// buffer and ignores the `reportID` argument of `IOHIDDeviceSetReport`.
    func setOutputReport(reportID: UInt8, report: [UInt8]) throws
    /// Blocks until the next input report arrives; throws `BragiError.timeout`.
    func nextInputReport(timeout: TimeInterval) throws -> [UInt8]
}

/// Production transport: the IOHID vendor interface of the XENEON EDGE.
public final class IOHIDBragiTransport: BragiTransport {
    private let device: IOHIDDevice
    // Stable buffer handed to IOKit for incoming reports; must outlive the
    // registration, hence manually managed.
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let responseLock = NSCondition()
    private var pendingResponse: [UInt8]?
    private var runLoop: CFRunLoop?

    public private(set) var manufacturer: String = ""
    public private(set) var product: String = ""
    public private(set) var serialNumber: String = ""

    /// Finds the first XENEON EDGE vendor interface on the system.
    public static func find() -> IOHIDBragiTransport? {
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
        return IOHIDBragiTransport(device: dev)
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

    /// Opens the device and starts listening for input reports on a private
    /// run loop; returns only after that run loop has taken its first turn,
    /// so a `send()` right after `open()` cannot race the callback
    /// registration.
    public func open() throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw BragiError.openFailed(result) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, reportBuffer, EdgeConstants.reportSize,
            { context, _, _, _, _, report, reportLength in
                guard let context else { return }
                let me = Unmanaged<IOHIDBragiTransport>.fromOpaque(context).takeUnretainedValue()
                let bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
                me.responseLock.lock()
                me.pendingResponse = bytes
                me.responseLock.signal()
                me.responseLock.unlock()
            },
            context
        )

        let dev = device
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [device = dev] in
            let rl: CFRunLoop = CFRunLoopGetCurrent()
            self.runLoop = rl
            IOHIDDeviceScheduleWithRunLoop(device, rl, CFRunLoopMode.defaultMode.rawValue)
            // Only signal from inside the first run loop iteration: only
            // then is the input-report source actually being serviced.
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { ready.signal() }
            CFRunLoopWakeUp(rl)
            CFRunLoopRun()
        }
        guard ready.wait(timeout: .now() + 2.0) == .success else {
            throw BragiError.openFailed(kIOReturnTimeout)
        }
    }

    public func close() {
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        runLoop = nil
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func clearPendingInput() {
        responseLock.lock()
        pendingResponse = nil
        responseLock.unlock()
    }

    // MARK: I/O

    /// The report id byte is passed to IOKit as the report number, but this
    /// device only answers when the full buffer (with the report id at
    /// index 0) is also handed to `IOHIDDeviceSetReport` as the data.
    public func setOutputReport(reportID: UInt8, report: [UInt8]) throws {
        let result = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeOutput,
                CFIndex(reportID),
                buf.baseAddress!, buf.count
            )
        }
        guard result == kIOReturnSuccess else { throw BragiError.writeFailed(result) }
    }

    public func nextInputReport(timeout: TimeInterval) throws -> [UInt8] {
        responseLock.lock()
        defer { responseLock.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while pendingResponse == nil {
            if !responseLock.wait(until: deadline) { throw BragiError.timeout }
        }
        return pendingResponse!
    }
}
