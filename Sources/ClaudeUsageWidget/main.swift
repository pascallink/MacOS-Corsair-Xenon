// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

let app = NSApplication.shared
let delegate = WidgetAppDelegate()
app.delegate = delegate
app.run()
