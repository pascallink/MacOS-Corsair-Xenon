// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Persistent configuration, stored as JSON in
// ~/Library/Application Support/XeneonEdge/config.json

import Foundation

public struct LauncherItem: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Either an absolute .app path or a bundle identifier.
    public var target: String
    /// SF Symbol name shown on the button.
    public var symbol: String

    public init(name: String, target: String, symbol: String) {
        self.name = name
        self.target = target
        self.symbol = symbol
    }
}

public struct AppConfig: Codable, Equatable {
    // Touch
    public var touchEnabled = true
    public var dragEnabled = true
    public var longPressRightClick = true
    public var touchRotation = 0
    public var touchInvertX = false
    public var touchInvertY = false

    // Dashboard
    public var dashboardEnabled = true
    /// Show a preview window on the main display when no Edge is connected.
    public var previewWithoutDevice = true
    public var showClock = true
    public var showStats = true
    public var showMedia = true
    public var showVolume = true
    public var showLauncher = true
    public var showWeather = false
    public var use24HourClock = true

    // Weather (Open-Meteo, no API key required)
    public var weatherLatitude: Double = 52.52
    public var weatherLongitude: Double = 13.405
    public var weatherPlaceName = "Berlin"

    // DDC
    public var ddcDisplayIndex = 0

    // Launcher buttons
    public var launcherItems: [LauncherItem] = [
        LauncherItem(name: "Safari", target: "com.apple.Safari", symbol: "safari"),
        LauncherItem(name: "Mail", target: "com.apple.mail", symbol: "envelope"),
        LauncherItem(name: "Musik", target: "com.apple.Music", symbol: "music.note"),
        LauncherItem(name: "Terminal", target: "com.apple.Terminal", symbol: "terminal"),
        LauncherItem(name: "Fotos", target: "com.apple.Photos", symbol: "photo"),
        LauncherItem(name: "Einstellungen", target: "com.apple.systempreferences", symbol: "gearshape"),
    ]

    public init() {}

    // MARK: Persistence

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XeneonEdge", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig()
        }
        return config
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
