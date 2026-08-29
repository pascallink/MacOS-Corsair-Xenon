// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu bar application: wires the touch driver, the dashboard window and the
// device controls together.

import AppKit
import SwiftUI
import XeneonEdgeKit

/// The dashboard panels the user can switch on and off from the menu bar.
private enum WidgetToggle: Int, CaseIterable {
    case clock = 1, stats, media, volume, launcher, weather, claude

    var title: String {
        switch self {
        case .clock: return "Uhrzeit"
        case .stats: return "System (CPU/RAM/Netz)"
        case .media: return "Medien"
        case .volume: return "Lautstärke"
        case .launcher: return "Schnellstart"
        case .weather: return "Wetter"
        case .claude: return "Claude-Nutzung"
        }
    }
}

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

        // A second instance (e.g. started from Finder while the LaunchAgent
        // copy is already running) would load and save config.json
        // independently, so edits keep getting clobbered by whichever
        // instance saves last. Refuse to run alongside an older one.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSLog("XeneonEdge: another instance is already running (pid \(others[0].processIdentifier)) — exiting")
                NSApp.terminate(nil)
                return
            }
        }

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
        applyWidgetServices()

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

    /// Starts or stops the background work behind the optional panels, so a
    /// switched-off widget costs nothing.
    private func applyWidgetServices() {
        if configStore.config.showClaudeUsage {
            claudeModel.start(cloudGistID: configStore.config.cloudGistID,
                              cloudPollSeconds: configStore.config.cloudPollSeconds)
        } else {
            claudeModel.stop()
        }
        if configStore.config.showWeather {
            weatherModel.start(latitude: configStore.config.weatherLatitude,
                               longitude: configStore.config.weatherLongitude)
        } else {
            weatherModel.stop()
        }
    }

    private func isEnabled(_ widget: WidgetToggle) -> Bool {
        switch widget {
        case .clock: return configStore.config.showClock
        case .stats: return configStore.config.showStats
        case .media: return configStore.config.showMedia
        case .volume: return configStore.config.showVolume
        case .launcher: return configStore.config.showLauncher
        case .weather: return configStore.config.showWeather
        case .claude: return configStore.config.showClaudeUsage
        }
    }

    private func setEnabled(_ widget: WidgetToggle, _ value: Bool) {
        switch widget {
        case .clock: configStore.config.showClock = value
        case .stats: configStore.config.showStats = value
        case .media: configStore.config.showMedia = value
        case .volume: configStore.config.showVolume = value
        case .launcher: configStore.config.showLauncher = value
        case .weather: configStore.config.showWeather = value
        case .claude: configStore.config.showClaudeUsage = value
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

        // Panels of the dashboard
        let widgetsItem = NSMenuItem(title: "Widgets", action: nil, keyEquivalent: "")
        let widgetsMenu = NSMenu()
        for widget in WidgetToggle.allCases {
            let item = NSMenuItem(title: widget.title,
                                  action: #selector(toggleWidget(_:)), keyEquivalent: "")
            item.target = self
            item.tag = widget.rawValue
            item.state = isEnabled(widget) ? .on : .off
            widgetsMenu.addItem(item)
        }
        widgetsItem.submenu = widgetsMenu
        menu.addItem(widgetsItem)

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

        let reloadItem = NSMenuItem(title: "Konfiguration neu laden",
                                    action: #selector(reloadConfig), keyEquivalent: "l")
        reloadItem.target = self
        menu.addItem(reloadItem)
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

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let widget = WidgetToggle(rawValue: sender.tag) else { return }
        setEnabled(widget, !isEnabled(widget))
        applyWidgetServices()
        rebuildMenu()
    }

    @objc private func reloadConfig() {
        configStore.reload()
        applyTouchConfiguration()
        applyWidgetServices()
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
        // Only create the file when it is missing — writing the in-memory copy
        // unconditionally would overwrite edits the user made by hand.
        if !FileManager.default.fileExists(atPath: AppConfig.fileURL.path) {
            do {
                try configStore.config.save()
            } catch {
                showAlert(title: "Konfiguration konnte nicht angelegt werden", text: "\(error)")
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppConfig.fileURL])
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
