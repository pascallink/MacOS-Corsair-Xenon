// XeneonEdge for macOS — Claude usage widget
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Widget configuration, stored as JSON in
// ~/Library/Application Support/XeneonEdge/claude-widget.json

import Foundation

struct WidgetConfig: Codable, Equatable {
    /// Refresh interval in seconds (30-60s is sensible).
    var refreshSeconds: Double = 45
    /// Personal token budget per 5h block for the progress ring. Plans have
    /// no published token number, so this is user-calibrated: watch the
    /// widget until you hit a limit once, then set what you reached.
    /// 0 = no ring, show plain numbers.
    var tokenBudgetPerBlock: Int = 0
    /// Where on the Edge display the widget docks:
    /// topLeft | topRight | bottomLeft | bottomRight | center
    var corner: String = "bottomRight"
    /// Margin from the display edges in points.
    var margin: Double = 24
    /// Widget size in points.
    var width: Double = 560
    var height: Double = 250
    /// Count cache reads towards the displayed token number. Plan limits
    /// weigh cache reads barely at all, so the default leaves them out.
    var includeCacheReads: Bool = false

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XeneonEdge/claude-widget.json")
    }

    static func load() -> WidgetConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(WidgetConfig.self, from: data)
        else {
            let config = WidgetConfig()
            config.save() // write defaults so the file is easy to find/edit
            return config
        }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
