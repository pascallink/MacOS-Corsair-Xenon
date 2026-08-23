// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// DDC/CI picture control (brightness, contrast, input, color preset, power)
// over the display's I2C channel — the same channel iCUE/monitor OSDs use,
// so no vendor protocol is required for picture settings.
//
// Apple Silicon: uses the private IOAVService I2C functions from IOKit
// (the approach proven by m1ddc/MonitorControl). Symbols are resolved at
// runtime via dlsym, so the binary also loads on machines where they do
// not exist (there DDC reports "unsupported").
//
// Note: DDC works on direct HDMI / USB-C(DP Alt Mode) connections. Some
// docks/adapters do not forward I2C.

import Foundation
import IOKit

public enum VCP {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let colorPreset: UInt8 = 0x14
    public static let inputSource: UInt8 = 0x60
    public static let audioVolume: UInt8 = 0x62
    public static let powerMode: UInt8 = 0xD6
}

public enum DDCError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case noExternalDisplayService
    case i2cError(IOReturn)
    case invalidReply

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "IOAVService I2C is unavailable on this machine (Intel Macs are not supported yet)"
        case .noExternalDisplayService:
            return "no external display I2C service found (adapter may not forward DDC)"
        case .i2cError(let r):
            return String(format: "I2C transfer failed (IOReturn 0x%08X)", r)
        case .invalidReply:
            return "malformed DDC reply"
        }
    }
}

public struct DDCValue {
    public let current: UInt16
    public let maximum: UInt16
}

public final class DDCControl {
    // MARK: Private IOKit symbols (Apple Silicon)

    private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias ReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let createWithService: CreateWithServiceFn
    private let writeI2C: WriteI2CFn
    private let readI2C: ReadI2CFn

    private let service: CFTypeRef
    public let serviceLocation: String

    private static let ddcChipAddress: UInt32 = 0x37
    private static let ddcDataAddress: UInt32 = 0x51
    private static let ddcSourceAddress: UInt8 = 0x6E // 0x37 << 1

    // MARK: Setup

    /// Lists the I2C services of external displays. `index` selects among
    /// them when several external displays are connected.
    public static func openExternalDisplay(index: Int = 0) throws -> DDCControl {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let createSym = dlsym(handle, "IOAVServiceCreateWithService"),
              let writeSym = dlsym(handle, "IOAVServiceWriteI2C"),
              let readSym = dlsym(handle, "IOAVServiceReadI2C")
        else {
            throw DDCError.unsupportedPlatform
        }
        let create = unsafeBitCast(createSym, to: CreateWithServiceFn.self)
        let write = unsafeBitCast(writeSym, to: WriteI2CFn.self)
        let read = unsafeBitCast(readSym, to: ReadI2CFn.self)

        var found: [(CFTypeRef, String)] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            throw DDCError.noExternalDisplayService
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            let location = (IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String) ?? ""
            guard location == "External" else { continue }
            if let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found.append((service, location))
            }
        }

        guard index >= 0, index < found.count else {
            throw DDCError.noExternalDisplayService
        }
        let (service, location) = found[index]
        return DDCControl(service: service, location: location,
                          create: create, write: write, read: read)
    }

    /// Number of external display I2C services currently visible.
    public static func externalDisplayCount() -> Int {
        var count = 0
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = (IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String) ?? ""
            if location == "External" { count += 1 }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return count
    }

    private init(service: CFTypeRef, location: String,
                 create: @escaping CreateWithServiceFn,
                 write: @escaping WriteI2CFn,
                 read: @escaping ReadI2CFn) {
        self.service = service
        self.serviceLocation = location
        self.createWithService = create
        self.writeI2C = write
        self.readI2C = read
    }

    // MARK: VCP read/write

    /// Writes a VCP feature value (DDC/CI "Set VCP Feature").
    public func write(_ code: UInt8, value: UInt16) throws {
        var packet: [UInt8] = [
            0x84, // length | 0x80
            0x03, // Set VCP Feature
            code,
            UInt8(value >> 8),
            UInt8(value & 0xFF),
            0,
        ]
        packet[5] = Self.ddcSourceAddress ^ UInt8(Self.ddcDataAddress)
            ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]

        // DDC writes are more reliable when repeated; monitors debounce them.
        for attempt in 0..<3 {
            let result = packet.withUnsafeMutableBufferPointer { buf in
                writeI2C(service, Self.ddcChipAddress, Self.ddcDataAddress,
                         buf.baseAddress!, UInt32(buf.count))
            }
            if result == kIOReturnSuccess { return }
            if attempt == 2 { throw DDCError.i2cError(result) }
            usleep(20_000)
        }
    }

    /// Reads a VCP feature (current + maximum value).
    public func read(_ code: UInt8) throws -> DDCValue {
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = Self.ddcSourceAddress ^ UInt8(Self.ddcDataAddress)
            ^ request[0] ^ request[1] ^ request[2]

        let writeResult = request.withUnsafeMutableBufferPointer { buf in
            writeI2C(service, Self.ddcChipAddress, Self.ddcDataAddress,
                     buf.baseAddress!, UInt32(buf.count))
        }
        guard writeResult == kIOReturnSuccess else { throw DDCError.i2cError(writeResult) }
        usleep(50_000) // DDC/CI mandates a pause before the reply is fetched

        var reply = [UInt8](repeating: 0, count: 12)
        let readResult = reply.withUnsafeMutableBufferPointer { buf in
            readI2C(service, Self.ddcChipAddress, Self.ddcDataAddress,
                    buf.baseAddress!, UInt32(buf.count))
        }
        guard readResult == kIOReturnSuccess else { throw DDCError.i2cError(readResult) }

        // Reply layout: [addr][len][0x02 reply op][result][code][type]
        //               [max hi][max lo][cur hi][cur lo][chk]
        guard reply.count >= 10, reply[2] == 0x02, reply[4] == code else {
            throw DDCError.invalidReply
        }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return DDCValue(current: current, maximum: maximum)
    }

    // MARK: Convenience

    public func setBrightness(percent: Int) throws {
        try write(VCP.brightness, value: UInt16(min(max(percent, 0), 100)))
    }

    public func brightness() throws -> Int {
        let v = try read(VCP.brightness)
        guard v.maximum > 0 else { return Int(v.current) }
        return Int((UInt32(v.current) * 100) / UInt32(v.maximum))
    }

    public func setContrast(percent: Int) throws {
        try write(VCP.contrast, value: UInt16(min(max(percent, 0), 100)))
    }

    /// 0x01 = on, 0x04 = standby, 0x05 = off (VESA DPM codes).
    public func setPower(on: Bool) throws {
        try write(VCP.powerMode, value: on ? 0x01 : 0x04)
    }
}
