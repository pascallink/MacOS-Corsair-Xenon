// XeneonEdge for macOS — command line tool
// SPDX-License-Identifier: GPL-3.0-or-later
//
// xeneonctl — probe, picture control and touch diagnostics for the
// CORSAIR XENEON EDGE without the GUI app.

import AppKit
import Foundation
import XeneonEdgeKit

let usage = """
xeneonctl — CORSAIR XENEON EDGE control for macOS

USAGE:
  xeneonctl probe                     Detect the Edge (display, touch, HID) and print details
  xeneonctl firmware                  Query the vendor HID interface (Bragi GET 0x13)
  xeneonctl brightness <0-100>        Set panel brightness via DDC/CI
  xeneonctl brightness                Read panel brightness via DDC/CI
  xeneonctl contrast <0-100>          Set panel contrast via DDC/CI
  xeneonctl power <on|standby>        Panel power via DDC/CI
  xeneonctl ddc get <vcp-hex>         Read a raw VCP feature (e.g. 0x10)
  xeneonctl ddc set <vcp-hex> <value> Write a raw VCP feature
  xeneonctl touch-monitor [--seize]   Print live touch events (Ctrl+C to stop)

OPTIONS:
  --display <n>   Select the I2C service explicitly by index (default: the
                  Edge, chosen by its display identity)
  --seize         touch-monitor only: take the touch interfaces away from
                  macOS for the duration of the run, so the system stops
                  moving the cursor from the same reports. Off by default —
                  plain diagnostics must not change how the device behaves.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var seizeTouch = false
if let optIndex = arguments.firstIndex(of: "--seize") {
    seizeTouch = true
    arguments.remove(at: optIndex)
}
var displayIndex: Int?
if let optIndex = arguments.firstIndex(of: "--display"), optIndex + 1 < arguments.count {
    displayIndex = Int(arguments[optIndex + 1])
    arguments.removeSubrange(optIndex...(optIndex + 1))
}

guard let command = arguments.first else {
    print(usage)
    exit(0)
}

func openDDC() -> DDCControl {
    do {
        if let displayIndex {
            return try DDCControl.openExternalDisplay(index: displayIndex)
        }
        return try DDCControl.openEdge()
    } catch {
        fail("DDC: \(error)")
    }
}

/// Human-readable name for a touch HID interface, by usage page/usage.
func touchInterfaceName(_ info: TouchInterfaceInfo) -> String {
    switch (info.usagePage, info.usage) {
    case (EdgeConstants.digitizerUsagePage, EdgeConstants.digitizerUsage): return "digitizer"
    case (EdgeConstants.touchMouseUsagePage, EdgeConstants.touchMouseUsage): return "mouse emulation"
    case (EdgeConstants.touchVendorChannelUsagePage, EdgeConstants.touchVendorChannelUsage):
        return "vendor channel"
    default: return "unknown"
    }
}

/// Short label of the interface a touch sample arrived on.
func touchInterfaceLabel(_ interface: TouchInterface) -> String {
    switch interface {
    case .digitizer: return "digitizer"
    case .mouseEmulation: return "mouse    "
    case .unknown: return "?        "
    }
}

switch command {
case "probe":
    print("== CORSAIR XENEON EDGE — probe ==")

    if let display = EdgeDisplay.find() {
        let b = display.bounds
        print("Display   : \(display.localizedName) (id \(display.displayID))")
        print("Bounds    : \(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)), \(Int(b.minY)))")
    } else {
        print("Display   : not found (connect via USB-C DP-Alt-Mode or HDMI)")
    }

    if let device = BragiDevice.find() {
        print("Vendor HID: \(device.product) / \(device.manufacturer) / SN \(device.serialNumber)")
    } else {
        print("Vendor HID: 1b1c:1d0d not found")
    }

    let touchInterfaces = TouchDriver.touchInterfaces()
    if touchInterfaces.isEmpty {
        print("Touch HID : \(String(format: "%04x", EdgeConstants.touchVendorID)):" +
              "\(String(format: "%04x", EdgeConstants.touchProductID)) not found")
    } else {
        for (i, iface) in touchInterfaces.enumerated() {
            let label = String(format: "0x%02X/0x%02X", iface.usagePage, iface.usage)
            let marker = iface.matchedByDriver ? " <- driver" : ""
            let prefix = i == 0 ? "Touch HID : " : "            "
            print("\(prefix)\(label) \(touchInterfaceName(iface)) (\(iface.elementCount) elements)\(marker)")
        }
        // Which of the two input interfaces actually reports is decided by
        // this feature value, so it belongs next to the interface list.
        switch TouchDriver.digitizerDeviceMode() {
        case nil:
            print("            Device Mode (0x0D/0x52): not readable")
        case EdgeConstants.digitizerDeviceModeMouse:
            print("            Device Mode (0x0D/0x52): 0 = mouse mode " +
                  "(digitizer stays silent, contacts arrive on the mouse emulation)")
        case .some(let mode):
            print("            Device Mode (0x0D/0x52): \(mode) (digitizer mode)")
        }
    }

    let services = DDCServiceLocator.externalServices()
    print("DDC       : \(services.count) external display I2C service(s)")
    for service in services {
        let name = service.isUsable ? service.productName : "—"
        let isEdge = service.productName.uppercased().contains(EdgeConstants.displayNameHint)
        let marker = (service.isUsable && isEdge) ? " <- Edge" : ""
        let unusable = service.isUsable ? "" : " (no framebuffer, unusable)"
        print("            [\(service.index)] \(service.portTag)  \(name)\(unusable)\(marker)")
    }

    let accessibility = TouchDriver.hasAccessibilityPermission() ? "granted" : "not granted"
    let inputMonitoring = TouchDriver.hasInputMonitoringPermission() ? "granted" : "not granted"
    print("Access    : Accessibility \(accessibility), Input Monitoring \(inputMonitoring)")

case "firmware":
    guard let device = BragiDevice.find() else {
        fail("vendor HID interface 1b1c:1d0d not found")
    }
    do {
        try device.open()
        let frame = BragiFrame.get(property: BragiProperty.firmware)
        let raw = try device.transfer(frame)
        print("GET 0x13 raw : \(BragiFrame.hexDump(Array(raw.prefix(32))))")
        if let data = BragiFrame.responseData(request: frame, response: raw) {
            print("GET 0x13 data: \(BragiFrame.hexDump(Array(data.prefix(30))))")
        }
        device.close()
    } catch {
        fail("\(error)")
    }

case "brightness":
    let ddc = openDDC()
    if arguments.count >= 2 {
        guard let value = Int(arguments[1]), (0...100).contains(value) else {
            fail("brightness must be 0-100")
        }
        do { try ddc.setBrightness(percent: value); print("brightness set to \(value)%") }
        catch { fail("\(error)") }
    } else {
        do { print("brightness: \(try ddc.brightness())%") }
        catch { fail("\(error)") }
    }

case "contrast":
    guard arguments.count >= 2, let value = Int(arguments[1]), (0...100).contains(value) else {
        fail("usage: xeneonctl contrast <0-100>")
    }
    do { try openDDC().setContrast(percent: value); print("contrast set to \(value)%") }
    catch { fail("\(error)") }

case "power":
    guard arguments.count >= 2 else { fail("usage: xeneonctl power <on|standby>") }
    do { try openDDC().setPower(on: arguments[1] == "on"); print("power: \(arguments[1])") }
    catch { fail("\(error)") }

case "ddc":
    guard arguments.count >= 3 else { fail("usage: xeneonctl ddc get|set <vcp-hex> [value]") }
    let hex = arguments[2].replacingOccurrences(of: "0x", with: "")
    guard let code = UInt8(hex, radix: 16) else { fail("bad VCP code: \(arguments[2])") }
    let ddc = openDDC()
    switch arguments[1] {
    case "get":
        do {
            let v = try ddc.read(code)
            print(String(format: "VCP 0x%02X: current=%d max=%d", code, v.current, v.maximum))
        } catch { fail("\(error)") }
    case "set":
        guard arguments.count >= 4, let value = UInt16(arguments[3]) else {
            fail("usage: xeneonctl ddc set <vcp-hex> <value>")
        }
        do { try ddc.write(code, value: value); print(String(format: "VCP 0x%02X = %d", code, value)) }
        catch { fail("\(error)") }
    default:
        fail("usage: xeneonctl ddc get|set <vcp-hex> [value]")
    }

case "touch-monitor":
    // Line buffering: redirected into a file or a pipe, stdout would
    // otherwise be block buffered and the live monitor would look hung for
    // minutes ("xeneonctl touch-monitor > log.txt").
    setvbuf(stdout, nil, _IOLBF, 0)
    guard TouchDriver.hasInputMonitoringPermission() else {
        fail("""
        Input Monitoring is missing — without this permission no touch events \
        arrive at all. Enable it under System Settings > Privacy & Security > \
        Input Monitoring for this terminal (or whichever app runs xeneonctl), \
        then restart it.
        """)
    }
    final class Monitor: TouchDriverDelegate {
        func touchDriver(_ driver: TouchDriver, deviceConnected connected: Bool) {
            print(connected ? "touch controller connected (27c0:0859)"
                            : "touch controller disconnected")
        }
        func touchDriver(_ driver: TouchDriver, didTouchAt point: CGPoint, down: Bool) {
            // Superseded by didObserve below (raw values, slot, movements);
            // kept only to satisfy the protocol.
        }
        func touchDriver(_ driver: TouchDriver, didObserve diagnostics: TouchDiagnostics) {
            let label: String
            switch diagnostics.phase {
            case .down: label = "DOWN"
            case .moved: label = "MOVE"
            case .up: label = "UP  "
            }
            let iface = touchInterfaceLabel(diagnostics.interface)
            let slot = diagnostics.slot.map(String.init) ?? "?"
            let raw = String(format: "(%6d,%6d)", diagnostics.rawX, diagnostics.rawY)
            let maxima = "(\(diagnostics.maxX),\(diagnostics.maxY))"
            let norm = String(format: "(%.3f,%.3f)", diagnostics.normalized.x, diagnostics.normalized.y)
            let mapped = "(\(Int(diagnostics.mapped.x)), \(Int(diagnostics.mapped.y)))"
            print("\(label) if=\(iface) slot=\(slot) raw=\(raw)/\(maxima) norm=\(norm) -> \(mapped)")
        }
    }
    let driver = TouchDriver()
    let monitor = Monitor()
    driver.delegate = monitor
    driver.display = EdgeDisplay.find()
    // Diagnostics only: never inject events from the CLI, and leave the
    // device to macOS unless --seize was asked for explicitly.
    driver.injectionEnabled = false
    driver.configuration.suppressSystemCursor = seizeTouch
    if let display = driver.display {
        let b = display.bounds
        print("bounds: \(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)), \(Int(b.minY))) " +
              "(global CG coordinates, y grows downward)")
    } else {
        print("note: Edge display not found; printing panel-native coordinates")
    }
    print("monitoring touches — Ctrl+C to stop")
    driver.start(runLoop: CFRunLoopGetCurrent())
    if seizeTouch {
        print(driver.systemCursorSuppressed
              ? "seized: macOS gets no pointer events from the touch controller while this runs"
              : "seize refused — macOS keeps moving the cursor from the same reports")
    }
    CFRunLoopRun()

case "help", "--help", "-h":
    print(usage)

default:
    print(usage)
    fail("unknown command: \(command)")
}
