// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Frameless floating window that docks onto the Xeneon Edge display (or the
// main display when no Edge is connected). Menu bar item for control; no
// special permissions required — the widget only reads local files.

import AppKit
import SwiftUI
import XeneonEdgeKit

final class WidgetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let model = UsageViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Two instances would load and save claude-widget.json independently,
        // clobbering each other's edits — refuse to run alongside an older one.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSLog("ClaudeUsageWidget: another instance is already running (pid \(others[0].processIdentifier)) — exiting")
                NSApp.terminate(nil)
                return
            }
        }

        model.start()
        makeWindow()
        position()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged() { position() }

    // MARK: Window

    private func makeWindow() {
        let config = model.config
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true // drag anywhere to reposition
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Above the XeneonEdge dashboard window (mainMenu+1), so both can run.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.contentView = NSHostingView(rootView: WidgetView(model: model))
        window.orderFrontRegardless()
    }

    private func position() {
        let config = model.config
        let screen = EdgeDisplay.find()?.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let margin = CGFloat(config.margin)
        let size = NSSize(width: config.width, height: config.height)

        let origin: NSPoint
        switch config.corner {
        case "topLeft":
            origin = NSPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin)
        case "topRight":
            origin = NSPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case "bottomLeft":
            origin = NSPoint(x: frame.minX + margin, y: frame.minY + margin)
        case "center":
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        default: // bottomRight
            origin = NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.needle",
                                   accessibilityDescription: "Claude Usage")
        }
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Jetzt aktualisieren",
                                     action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let repositionItem = NSMenuItem(title: "Auf Xeneon Edge positionieren",
                                        action: #selector(reposition), keyEquivalent: "p")
        repositionItem.target = self
        menu.addItem(repositionItem)

        let configItem = NSMenuItem(title: "Konfigurationsdatei öffnen …",
                                    action: #selector(openConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        let reloadItem = NSMenuItem(title: "Konfiguration neu laden",
                                    action: #selector(reloadConfig), keyEquivalent: "l")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Widget beenden",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func refreshNow() { model.refresh() }
    @objc private func reposition() { position() }

    @objc private func openConfig() {
        // Only create the file when it is missing — writing the in-memory
        // copy unconditionally would overwrite edits made by hand.
        if !FileManager.default.fileExists(atPath: WidgetConfig.fileURL.path) {
            try? model.config.save()
        }
        NSWorkspace.shared.activateFileViewerSelecting([WidgetConfig.fileURL])
    }

    @objc private func reloadConfig() {
        model.reloadConfig()
        window.setContentSize(NSSize(width: model.config.width, height: model.config.height))
        position()
    }
}
