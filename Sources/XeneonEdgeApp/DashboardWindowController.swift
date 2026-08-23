// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Borderless window that claims the XENEON EDGE display, like the iCUE
// dashboard does on Windows. Falls back to a floating preview window on the
// main display when no Edge is connected (so widgets can be configured
// before the hardware arrives).

import AppKit
import SwiftUI
import XeneonEdgeKit

final class DashboardWindowController {
    private var window: NSWindow?
    private let content: AnyView
    private(set) var isPreview = false

    init<Content: View>(content: Content) {
        self.content = AnyView(content)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// (Re)positions the dashboard: fullscreen on the Edge when present,
    /// otherwise an optional preview window.
    func update(display: EdgeDisplay?, previewAllowed: Bool) {
        if let display {
            isPreview = false
            show(frame: display.screen.frame, fullscreen: true)
        } else if previewAllowed {
            isPreview = true
            let size = NSSize(width: EdgeConstants.nativeWidth / 2,
                              height: EdgeConstants.nativeHeight / 2)
            let main = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = NSRect(
                x: main.midX - size.width / 2,
                y: main.midY - size.height / 2,
                width: size.width, height: size.height
            )
            show(frame: frame, fullscreen: false)
        } else {
            hide()
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func show(frame: NSRect, fullscreen: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(frame, display: true)
        if fullscreen {
            // Cover menu bar and dock on the Edge's screen.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        } else {
            window.level = .floating
        }
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: content)
        return window
    }
}
