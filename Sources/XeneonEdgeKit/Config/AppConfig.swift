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

    /// `id` is an internal detail of the SwiftUI list, so hand-written
    /// config entries may omit it; one is generated then.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        target = try c.decode(String.self, forKey: .target)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "app"
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
    /// Claude-Code usage panel (tokens in the 5h window, reset, cost, model).
    public var showClaudeUsage = false
    /// Personal token budget per 5h block for the panel's ring; 0 = show the
    /// elapsed-time ring instead (limits are not published by Anthropic).
    public var claudeTokenBudgetPerBlock = 0
    /// GitHub Gist id relaying usage from Claude Code sessions running in a
    /// remote/cloud environment (see .claude/hooks/publish-claude-usage.sh
    /// and docs/CLAUDE-USAGE-WIDGET.md). Empty disables the cloud relay
    /// entirely — only local ~/.claude logs are read, the default.
    public var cloudGistID = ""
    /// Poll interval for the cloud relay; clamped to >=60s to stay under
    /// GitHub's unauthenticated REST rate limit (60 requests/hour/IP).
    public var cloudPollSeconds: Double = 90
    /// Claude logins to track separately (e.g. a personal and a work
    /// account). Each one keeps its own 5h window, so they are never summed.
    /// Empty = auto-detect a single profile, the previous behaviour.
    public var claudeProfiles: [ClaudeProfile] = []

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

    // MARK: Tolerant decoding
    // Every field falls back to its default when missing, so configs written
    // by older versions keep working after an update instead of being reset.

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        touchEnabled = try c.decodeIfPresent(Bool.self, forKey: .touchEnabled) ?? d.touchEnabled
        dragEnabled = try c.decodeIfPresent(Bool.self, forKey: .dragEnabled) ?? d.dragEnabled
        longPressRightClick = try c.decodeIfPresent(Bool.self, forKey: .longPressRightClick) ?? d.longPressRightClick
        touchRotation = try c.decodeIfPresent(Int.self, forKey: .touchRotation) ?? d.touchRotation
        touchInvertX = try c.decodeIfPresent(Bool.self, forKey: .touchInvertX) ?? d.touchInvertX
        touchInvertY = try c.decodeIfPresent(Bool.self, forKey: .touchInvertY) ?? d.touchInvertY
        dashboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .dashboardEnabled) ?? d.dashboardEnabled
        previewWithoutDevice = try c.decodeIfPresent(Bool.self, forKey: .previewWithoutDevice) ?? d.previewWithoutDevice
        showClock = try c.decodeIfPresent(Bool.self, forKey: .showClock) ?? d.showClock
        showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? d.showStats
        showMedia = try c.decodeIfPresent(Bool.self, forKey: .showMedia) ?? d.showMedia
        showVolume = try c.decodeIfPresent(Bool.self, forKey: .showVolume) ?? d.showVolume
        showLauncher = try c.decodeIfPresent(Bool.self, forKey: .showLauncher) ?? d.showLauncher
        showWeather = try c.decodeIfPresent(Bool.self, forKey: .showWeather) ?? d.showWeather
        use24HourClock = try c.decodeIfPresent(Bool.self, forKey: .use24HourClock) ?? d.use24HourClock
        showClaudeUsage = try c.decodeIfPresent(Bool.self, forKey: .showClaudeUsage) ?? d.showClaudeUsage
        claudeTokenBudgetPerBlock = try c.decodeIfPresent(Int.self, forKey: .claudeTokenBudgetPerBlock) ?? d.claudeTokenBudgetPerBlock
        cloudGistID = try c.decodeIfPresent(String.self, forKey: .cloudGistID) ?? d.cloudGistID
        cloudPollSeconds = try c.decodeIfPresent(Double.self, forKey: .cloudPollSeconds) ?? d.cloudPollSeconds
        claudeProfiles = try c.decodeIfPresent([ClaudeProfile].self, forKey: .claudeProfiles) ?? d.claudeProfiles
        weatherLatitude = try c.decodeIfPresent(Double.self, forKey: .weatherLatitude) ?? d.weatherLatitude
        weatherLongitude = try c.decodeIfPresent(Double.self, forKey: .weatherLongitude) ?? d.weatherLongitude
        weatherPlaceName = try c.decodeIfPresent(String.self, forKey: .weatherPlaceName) ?? d.weatherPlaceName
        ddcDisplayIndex = try c.decodeIfPresent(Int.self, forKey: .ddcDisplayIndex) ?? d.ddcDisplayIndex
        launcherItems = try c.decodeIfPresent([LauncherItem].self, forKey: .launcherItems) ?? d.launcherItems
    }

    // MARK: Persistence

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XeneonEdge", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // A malformed file must not silently reset every setting.
            NSLog("XeneonEdge: config.json could not be read (\(error)) — using defaults")
            return AppConfig()
        }
    }

    /// Writes the configuration. Throws instead of failing silently: a lost
    /// write means the user's settings vanish without any hint why.
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: .atomic)
    }
}
