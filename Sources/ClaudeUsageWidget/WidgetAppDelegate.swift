// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Frameless floating window that docks onto the Xeneon Edge display (or the
// main display when no Edge is connected). Menu bar item for control; no
// special permissions required — the widget only reads local files.

import AppKit
import Combine
import SwiftUI
import XeneonEdgeKit

final class WidgetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let model = UsageViewModel()
    private let agenda = AgendaModel()
    private var agendaCancellables = Set<AnyCancellable>()
    /// Abstand zwischen Karte und Nutzungsanzeige (Spacing der WidgetView).
    private static let cardGap: CGFloat = 12
    /// Zusatzhoehe des Fensters durch die Karte; 0 ohne sichtbare Karte.
    private var cardExtraHeight: CGFloat = 0
    private var statusTitle = ""

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
        if model.config.showCalendar { agenda.start() }
        makeWindow()
        position()
        setupStatusItem()
        observeAgenda()

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
        window.contentView = NSHostingView(rootView: WidgetView(model: model, agenda: agenda))
        window.orderFrontRegardless()
    }

    private func position() {
        let config = model.config
        let screen = EdgeDisplay.find()?.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let margin = CGFloat(config.margin)
        let size = NSSize(width: config.width, height: CGFloat(config.height) + cardExtraHeight)

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

    // MARK: Agenda

    /// Zusatzhoehe fuer die Karte samt Abstand; 0 solange sie nicht sichtbar ist.
    private static func cardHeight(config: WidgetConfig, agenda: AgendaModel) -> CGFloat {
        guard config.showCalendar, !agenda.reminders.isEmpty else { return 0 }
        let extra = AgendaCard.extraLines(overflow: agenda.overflow, isStale: agenda.isStale)
        return AgendaCard.height(rows: agenda.reminders.count, extraLines: extra) + cardGap
    }

    private func observeAgenda() {
        // @Published meldet vor der Aenderung; ein Runloop-Hop spaeter sind
        // alle drei Felder konsistent. Das Fenster wird nur bei geaenderter
        // Hoehe neu gesetzt, nicht jede Sekunde.
        Publishers.CombineLatest3(agenda.$reminders, agenda.$overflow, agenda.$isStale)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                let height = Self.cardHeight(config: self.model.config, agenda: self.agenda)
                if height != self.cardExtraHeight {
                    self.cardExtraHeight = height
                    self.position() // verankert die konfigurierte Ecke
                }
                self.updateStatusTitle()
            }
            .store(in: &agendaCancellables)
    }

    /// Titel ab Stufe .quarter der dringendsten Warnung, sonst nur das Symbol.
    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        var title = ""
        if model.config.showCalendar,
           let urgent = AgendaCard.urgent(agenda.reminders),
           let text = ReminderFormat.statusTitle(urgent) {
            title = text
        }
        guard title != statusTitle else { return }
        statusTitle = title
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
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
        if model.config.showCalendar { agenda.start() } else { agenda.stop() }
        cardExtraHeight = Self.cardHeight(config: model.config, agenda: agenda)
        window.setContentSize(NSSize(width: model.config.width,
                                     height: CGFloat(model.config.height) + cardExtraHeight))
        position()
        updateStatusTitle()
    }
}
