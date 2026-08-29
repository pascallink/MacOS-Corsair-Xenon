// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu bar application: wires the touch driver, the dashboard window and the
// device controls together.

import AppKit
import SwiftUI
import XeneonEdgeKit

final class AppDelegate: NSObject, NSApplicationDelegate, TouchDriverDelegate {
    private var statusItem: NSStatusItem!
    private let configStore = ConfigStore()
    private let statsModel = StatsModel()
    private let mediaModel = MediaModel()
    private let volumeModel = VolumeModel()
    private let weatherModel = WeatherModel()
    private let claudeModel = ClaudeUsageModel()

    private let touchDriver = TouchDriver()
    private var dashboard: DashboardWindowController!
    private var edgeDisplay: EdgeDisplay?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no dock icon

        // Ask for the Accessibility permission needed to inject touch clicks.
        if !TouchDriver.hasAccessibilityPermission(prompt: true) {
            NSLog("XeneonEdge: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }

        let dashboardView = DashboardView()
            .environmentObject(configStore)
            .environmentObject(statsModel)
            .environmentObject(mediaModel)
            .environmentObject(volumeModel)
            .environmentObject(weatherModel)
            .environmentObject(claudeModel)
        dashboard = DashboardWindowController(content: dashboardView)

        statsModel.start()
        mediaModel.start()
        volumeModel.start()
        if configStore.config.showClaudeUsage {
            claudeModel.start()
        }
        if configStore.config.showWeather {
            weatherModel.start(latitude: configStore.config.weatherLatitude,
                               longitude: configStore.config.weatherLongitude)
        }

        applyTouchConfiguration()
        touchDriver.delegate = self
        touchDriver.start()

        refreshDisplays()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged() {
        refreshDisplays()
        rebuildMenu()
    }

    private func refreshDisplays() {
        edgeDisplay = EdgeDisplay.find()
        touchDriver.display = edgeDisplay
        if configStore.config.dashboardEnabled {
            dashboard.update(display: edgeDisplay,
                             previewAllowed: configStore.config.previewWithoutDevice)
        } else {
            dashboard.hide()
        }
    }

    private func applyTouchConfiguration() {
        let c = configStore.config
        touchDriver.enabled = c.touchEnabled
        var tc = TouchDriverConfiguration()
        tc.dragEnabled = c.dragEnabled
        tc.longPressRightClick = c.longPressRightClick
        tc.rotation = c.touchRotation
        tc.invertX = c.touchInvertX
        tc.invertY = c.touchInvertY
        touchDriver.configuration = tc
    }

    // MARK: TouchDriverDelegate

    func touchDriver(_ driver: TouchDriver, deviceConnected connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDisplays()
            self?.rebuildMenu()
        }
    }

    func touchDriver(_ driver: TouchDriver, didTouchAt point: CGPoint, down: Bool) {
        // Hook for a future visual touch indicator.
    }

    // MARK: Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                   accessibilityDescription: "XeneonEdge")
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusTitle: String
        if let edgeDisplay {
            statusTitle = "Display: \(edgeDisplay.localizedName)"
        } else {
            statusTitle = "Display: nicht verbunden"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let touchLine = NSMenuItem(
            title: touchDriver.deviceConnected ? "Touchscreen: verbunden" : "Touchscreen: nicht gefunden",
            action: nil, keyEquivalent: ""
        )
        touchLine.isEnabled = false
        menu.addItem(touchLine)
        menu.addItem(.separator())

        let touchToggle = NSMenuItem(title: "Touch-Eingabe aktiv",
                                     action: #selector(toggleTouch), keyEquivalent: "t")
        touchToggle.target = self
        touchToggle.state = configStore.config.touchEnabled ? .on : .off
        menu.addItem(touchToggle)

        let dashToggle = NSMenuItem(title: "Dashboard anzeigen",
                                    action: #selector(toggleDashboard), keyEquivalent: "d")
        dashToggle.target = self
        dashToggle.state = configStore.config.dashboardEnabled ? .on : .off
        menu.addItem(dashToggle)

        // Brightness submenu (DDC/CI)
        let brightnessItem = NSMenuItem(title: "Helligkeit", action: nil, keyEquivalent: "")
        let brightnessMenu = NSMenu()
        for percent in [10, 25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(percent) %",
                                  action: #selector(setBrightness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            brightnessMenu.addItem(item)
        }
        brightnessItem.submenu = brightnessMenu
        menu.addItem(brightnessItem)
        menu.addItem(.separator())

        let probeItem = NSMenuItem(title: "Gerät abfragen (HID)",
                                   action: #selector(probeDevice), keyEquivalent: "")
        probeItem.target = self
        menu.addItem(probeItem)

        let configItem = NSMenuItem(title: "Konfigurationsdatei öffnen …",
                                    action: #selector(openConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "XeneonEdge beenden",
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Actions

    @objc private func toggleTouch() {
        configStore.config.touchEnabled.toggle()
        applyTouchConfiguration()
        rebuildMenu()
    }

    @objc private func toggleDashboard() {
        configStore.config.dashboardEnabled.toggle()
        refreshDisplays()
        rebuildMenu()
    }

    @objc private func setBrightness(_ sender: NSMenuItem) {
        let percent = sender.tag
        let index = configStore.config.ddcDisplayIndex
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ddc = try DDCControl.openExternalDisplay(index: index)
                try ddc.setBrightness(percent: percent)
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "Helligkeit fehlgeschlagen", text: "\(error)")
                }
            }
        }
    }

    @objc private func probeDevice() {
        DispatchQueue.global(qos: .userInitiated).async {
            var text: String
            if let device = BragiDevice.find() {
                do {
                    try device.open()
                    let response = try device.probeFirmware()
                    text = """
                    Produkt: \(device.product)
                    Hersteller: \(device.manufacturer)
                    Seriennummer: \(device.serialNumber)
                    Antwort (Property 0x13): \(BragiFrame.hexDump(Array(response.prefix(24))))
                    """
                    device.close()
                } catch {
                    text = "Gerät gefunden, Abfrage fehlgeschlagen: \(error)"
                }
            } else {
                text = "Kein XENEON EDGE Control-Interface (1b1c:1d0d) gefunden.\nIst das USB-Kabel verbunden?"
            }
            DispatchQueue.main.async {
                self.showAlert(title: "XENEON EDGE", text: text)
            }
        }
    }

    @objc private func openConfig() {
        configStore.config.save() // make sure the file exists
        NSWorkspace.shared.activateFileViewerSelecting([AppConfig.fileURL])
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
