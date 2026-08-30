// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Maps DCPAVServiceProxy I2C services to the display they actually belong
// to. `Location == "External"` alone is not enough to identify a usable
// service: on Apple Silicon a dead service without a framebuffer can carry
// that location too and still occupy index 0.
//
// AppleCLCD2 is NOT an ancestor of DCPAVServiceProxy in the IORegistry — the
// two sit in separate subtrees (dispext2@... vs. dcpext2@...) that only meet
// at a shared grandparent. The port tag from each side's direct parent name
// is what ties them together; see PROTOCOL-MACOS.md for the measurements
// this is based on.

import CoreGraphics
import Foundation
import IOKit

/// An I2C service of an external display, together with the identity of the
/// framebuffer it belongs to.
public struct DDCServiceInfo: Equatable {
    /// Port tag, e.g. "dispext2" — the link between the DCPAVServiceProxy
    /// (parent name "dispext2:dcpav-service-epic:0") and the AppleCLCD2
    /// framebuffer (parent name "dispext2"). AppleCLCD2 is NOT an ancestor
    /// of the service.
    public let portTag: String
    /// EDID product name of the framebuffer ("XENEON EDGE"); empty when no
    /// framebuffer exists for this port.
    public let productName: String
    /// EDID identity; matches CGDisplayVendorNumber / CGDisplayModelNumber /
    /// CGDisplaySerialNumber of the corresponding CGDirectDisplayID.
    public let vendorNumber: UInt32?
    public let modelNumber: UInt32?
    public let serialNumber: UInt32?
    /// False when the service has no DCPAVServiceProxyUserClient child;
    /// such services answer every I2C transfer with 0xE0114000.
    public let hasUserClient: Bool
    /// Position in enumeration order — the number `--display <n>` addresses.
    public let index: Int

    public var isUsable: Bool { hasUserClient && !productName.isEmpty }

    public init(portTag: String, productName: String,
                vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?,
                hasUserClient: Bool, index: Int) {
        self.portTag = portTag
        self.productName = productName
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.hasUserClient = hasUserClient
        self.index = index
    }
}

public enum DDCServiceLocator {
    /// All DCPAVServiceProxy services with `Location == "External"`, in
    /// IOKit enumeration order — the same order `--display <n>` indexes into.
    public static func externalServices() -> [DDCServiceInfo] {
        withExternalServices { entries in entries.map(\.info) }
    }

    /// Pure selection rule, deliberately free of IOKit. Returns the first
    /// usable service whose framebuffer identity matches the display; dead
    /// services are never returned. When several equivalent services match
    /// (identical displays sharing an EDID serial — the test rig has two
    /// BenQ RD280UA at 2513/32915/0), the first one wins.
    public static func select(_ services: [DDCServiceInfo],
                              vendorNumber: UInt32,
                              modelNumber: UInt32,
                              serialNumber: UInt32) -> DDCServiceInfo? {
        services.first {
            $0.isUsable
                && $0.vendorNumber == vendorNumber
                && $0.modelNumber == modelNumber
                && $0.serialNumber == serialNumber
        }
    }

    /// Fallback rule without an EDID identity: first usable service whose
    /// product name contains `nameHint` (case-insensitive).
    public static func select(_ services: [DDCServiceInfo],
                              productNameContains nameHint: String) -> DDCServiceInfo? {
        let hint = nameHint.lowercased()
        return services.first { $0.isUsable && $0.productName.lowercased().contains(hint) }
    }

    // MARK: IOKit enumeration

    /// Framebuffer identity discovered under a port tag.
    private struct Framebuffer {
        let productName: String
        let vendorNumber: UInt32?
        let modelNumber: UInt32?
        let serialNumber: UInt32?
    }

    /// Runs once over the services; the io_service_t handles are only valid
    /// inside `body`.
    static func withExternalServices<T>(
        _ body: ([(entry: io_service_t, info: DDCServiceInfo)]) throws -> T
    ) rethrows -> T {
        let framebuffers = framebuffersByPortTag()

        var entries: [(entry: io_service_t, info: DDCServiceInfo)] = []
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
            == kIOReturnSuccess {
            var entry = IOIteratorNext(iterator)
            var index = 0
            while entry != 0 {
                let location = (IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String) ?? ""
                guard location == "External" else {
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(iterator)
                    continue
                }
                let tag = directParentName(of: entry).map(portTag(fromParentName:)) ?? ""
                let framebuffer = framebuffers[tag]
                let info = DDCServiceInfo(
                    portTag: tag,
                    productName: framebuffer?.productName ?? "",
                    vendorNumber: framebuffer?.vendorNumber,
                    modelNumber: framebuffer?.modelNumber,
                    serialNumber: framebuffer?.serialNumber,
                    hasUserClient: hasUserClient(entry),
                    index: index
                )
                entries.append((entry: entry, info: info))
                index += 1
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        defer { for e in entries { IOObjectRelease(e.entry) } }
        return try body(entries)
    }

    /// AppleCLCD2 framebuffers, keyed by their direct parent's port tag.
    private static func framebuffersByPortTag() -> [String: Framebuffer] {
        var result: [String: Framebuffer] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &iterator)
            == kIOReturnSuccess else { return result }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let tag = directParentName(of: entry).map(portTag(fromParentName:)) else { continue }
            result[tag] = productAttributes(of: entry)
        }
        return result
    }

    private static func productAttributes(of clcd: io_service_t) -> Framebuffer {
        guard let displayAttributes = IORegistryEntryCreateCFProperty(
            clcd, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any],
        let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any]
        else {
            return Framebuffer(productName: "", vendorNumber: nil, modelNumber: nil, serialNumber: nil)
        }
        return Framebuffer(
            productName: productAttributes["ProductName"] as? String ?? "",
            vendorNumber: (productAttributes["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
            modelNumber: (productAttributes["ProductID"] as? NSNumber)?.uint32Value,
            serialNumber: (productAttributes["SerialNumber"] as? NSNumber)?.uint32Value
        )
    }

    /// True unless the service has no DCPAVServiceProxyUserClient child —
    /// the second, independent signal (besides a missing framebuffer) that a
    /// service is dead.
    private static func hasUserClient(_ entry: io_service_t) -> Bool {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == kIOReturnSuccess
        else { return false }
        defer { IOObjectRelease(iterator) }

        var found = false
        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer { IOObjectRelease(child); child = IOIteratorNext(iterator) }
            var classBuf = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(child, &classBuf) == kIOReturnSuccess,
               String(cString: classBuf) == "DCPAVServiceProxyUserClient" {
                found = true
            }
        }
        return found
    }

    /// The name IORegistry gives the direct parent in the service plane,
    /// e.g. "dispext2:dcpav-service-epic:0" or "dispext2@8A000000".
    private static func directParentName(of entry: io_service_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(parent) }
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &nameBuffer) == kIOReturnSuccess else { return nil }
        return String(cString: nameBuffer)
    }

    /// Port tag = the name up to the first ":" or "@", whichever appears.
    private static func portTag(fromParentName name: String) -> String {
        if let colon = name.firstIndex(of: ":") { return String(name[name.startIndex..<colon]) }
        if let at = name.firstIndex(of: "@") { return String(name[name.startIndex..<at]) }
        return name
    }
}
