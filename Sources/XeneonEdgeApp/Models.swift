// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Observable state feeding the dashboard widgets.

import AppKit
import Combine
import Foundation
import SwiftUI
import XeneonEdgeKit

// MARK: - Configuration store

final class ConfigStore: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            // Swift calls didSet for an assignment made from within init()
            // itself, not just for changes after it — so without this guard,
            // loading a config that fails to decode (e.g. a hand-edit typo)
            // would immediately save the resulting defaults right back over
            // the user's file, destroying it before they get a chance to
            // fix the typo. Only a real, user-driven change may save.
            guard !isLoading else { return }
            do {
                try config.save()
            } catch {
                NSLog("XeneonEdge: could not save config.json: \(error)")
                lastSaveError = "\(error)"
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Konfiguration konnte nicht gespeichert werden"
                    alert.informativeText = "\(error)\n\nDie Änderung gilt nur für diese Sitzung "
                        + "und geht beim nächsten Start verloren."
                    alert.runModal()
                }
            }
        }
    }

    /// Set whenever a save fails, so the UI can surface it instead of the
    /// change silently failing to persist.
    @Published var lastSaveError: String?

    private var isLoading = false

    init() {
        isLoading = true
        config = AppConfig.load()
        isLoading = false
    }

    /// Re-reads the file from disk after the user edited it by hand, without
    /// writing the in-memory copy back over their changes.
    func reload() {
        isLoading = true
        config = AppConfig.load()
        isLoading = false
    }
}

// MARK: - System statistics

final class StatsModel: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var cpuHistory: [Double] = []

    private let stats = SystemStats()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        _ = stats.sample() // prime the delta-based counters
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snap = self.stats.sample()
            self.snapshot = snap
            self.cpuHistory.append(snap.cpuUsage)
            if self.cpuHistory.count > 60 { self.cpuHistory.removeFirst() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Media

final class MediaModel: ObservableObject {
    @Published var nowPlaying = NowPlaying()

    private let controller = MediaController()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "xeneon.media")

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            let info = self.controller.nowPlaying()
            DispatchQueue.main.async {
                if info != self.nowPlaying { self.nowPlaying = info }
            }
        }
    }

    func playPause() { controller.playPause() }
    func next() { controller.next() }
    func previous() { controller.previous() }
}

// MARK: - Volume

final class VolumeModel: ObservableObject {
    @Published var volume: Float = 0
    @Published var muted = false

    private var timer: Timer?
    private var suppressUpdates = false

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !suppressUpdates else { return }
        if let v = SystemVolume.get() { volume = v }
        muted = SystemVolume.isMuted()
    }

    func userChanged(to value: Float) {
        suppressUpdates = true
        volume = value
        SystemVolume.set(value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.suppressUpdates = false
        }
    }

    func toggleMute() {
        muted.toggle()
        SystemVolume.setMuted(muted)
    }
}

// MARK: - Claude Code chat overview

/// Watches the open Claude Code chats (issue #14): how many are working, how
/// many wait for an answer, how many are open but idle — plus the newest
/// unanswered question. Reads the same local transcripts as the usage model
/// but keeps its own timer, so either panel can run without the other.
final class ClaudeSessionsModel: ObservableObject {
    @Published var snapshot = ClaudeSessionsSnapshot()

    private let reader = ClaudeSessionReader()
    private let queue = DispatchQueue(label: "xeneon.claude-sessions", qos: .utility)
    private var timer: Timer?
    private var profiles: [ClaudeProfile] = []
    private var options = ClaudeSessionReader.Options()

    /// Refreshed more often than the token numbers: "is this chat asking me
    /// something?" is only useful while it is still true.
    private let interval: TimeInterval = 20

    func start(profiles: [ClaudeProfile] = [], options: ClaudeSessionReader.Options) {
        self.profiles = profiles
        self.options = options
        guard timer == nil else {
            refresh()
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        profiles = []
        snapshot = ClaudeSessionsSnapshot()
    }

    func refresh() {
        let profiles = self.profiles
        let options = self.options
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.reader.snapshot(for: profiles, options: options)
            DispatchQueue.main.async { self.snapshot = snapshot }
        }
    }
}

// MARK: - Claude Code usage (local logs)

final class ClaudeUsageModel: ObservableObject {
    /// One entry per tracked profile. With no `claudeProfiles` configured
    /// this holds exactly one auto-detected profile, which is what keeps the
    /// single-profile panel and behaviour unchanged.
    @Published var profileUsages: [ClaudeUsageReader.ProfileUsage] = []
    /// Profiles that have received at least one entry from a cloud relay, so
    /// the panel can show that it isn't showing local-only numbers.
    @Published var cloudProfileIDs: Set<UUID> = []

    /// Stands in for the auto-detected profile when none are configured.
    static let autoProfileID = UUID()

    private let reader = ClaudeUsageReader()
    private let queue = DispatchQueue(label: "xeneon.claude-usage", qos: .utility)
    private var timer: Timer?
    private var cloudTimer: Timer?
    private var cloudEntries: [UUID: [ClaudeUsageEntry]] = [:]
    private var cloudSources: [(id: UUID, gistID: String)] = []
    private var profiles: [ClaudeProfile] = []

    /// - Parameters:
    ///   - profiles: Claude logins tracked separately; empty auto-detects one.
    ///   - cloudGistID: Empty disables the cloud relay (default, local-only).
    ///     Ignored when `profiles` is set — each profile brings its own gist.
    ///   - cloudPollSeconds: Clamped to >=60s per polled gist (GitHub's
    ///     unauthenticated rate limit is 60 requests/hour/IP).
    func start(profiles: [ClaudeProfile] = [], cloudGistID: String = "",
               cloudPollSeconds: Double = 90) {
        configureCloud(profiles: profiles, gistID: cloudGistID,
                       pollSeconds: cloudPollSeconds)
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cloudTimer?.invalidate()
        cloudTimer = nil
        cloudEntries = [:]
        cloudSources = []
        profiles = []
        cloudProfileIDs = []
    }

    /// Which gists to poll, and for which profile. Without configured
    /// profiles the top-level gist feeds the auto-detected profile; with
    /// profiles each one brings its own and the top-level field would be
    /// ambiguous, so it is ignored (loudly, not silently).
    private static func cloudSources(profiles: [ClaudeProfile],
                                     gistID: String) -> [(id: UUID, gistID: String)] {
        let topLevel = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profiles.isEmpty else {
            return topLevel.isEmpty ? [] : [(autoProfileID, topLevel)]
        }
        if !topLevel.isEmpty {
            NSLog("XeneonEdge: cloudGistID is ignored while claudeProfiles is set — "
                + "give the profile its own cloudGistID instead")
        }
        return profiles.compactMap { profile in
            let gist = profile.cloudGistID.trimmingCharacters(in: .whitespacesAndNewlines)
            return gist.isEmpty ? nil : (profile.id, gist)
        }
    }

    private func configureCloud(profiles: [ClaudeProfile], gistID: String,
                                pollSeconds: Double) {
        let sources = Self.cloudSources(profiles: profiles, gistID: gistID)
        let unchanged = profiles == self.profiles
            && sources.count == cloudSources.count
            && zip(sources, cloudSources).allSatisfy { $0.id == $1.id && $0.gistID == $1.gistID }
        guard !unchanged else { return }

        self.profiles = profiles
        cloudSources = sources
        cloudEntries = [:]
        cloudProfileIDs = []
        cloudTimer?.invalidate()
        cloudTimer = nil
        refresh()
        guard !sources.isEmpty else { return }

        // Every poll hits one gist per source, so the floor scales with the
        // number of sources: GitHub allows 60 unauthenticated requests per
        // hour and IP, and two profiles polled every 90s would be 80.
        let floor = 60 * Double(sources.count)
        let interval = min(max(pollSeconds, floor), 900)
        pollCloud()
        cloudTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollCloud()
        }
    }

    private func pollCloud() {
        let sources = cloudSources
        guard !sources.isEmpty else { return }
        Task { [weak self] in
            for source in sources {
                let entries = await CloudUsageFetcher.fetch(gistID: source.gistID)
                await MainActor.run {
                    guard let self,
                          self.cloudSources.contains(where: {
                              $0.id == source.id && $0.gistID == source.gistID
                          })
                    else { return }
                    self.cloudEntries[source.id] = entries
                    if entries.isEmpty {
                        self.cloudProfileIDs.remove(source.id)
                    } else {
                        self.cloudProfileIDs.insert(source.id)
                    }
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        let cloud = cloudEntries
        let profiles = self.profiles
        queue.async { [weak self] in
            guard let self else { return }
            let usages: [ClaudeUsageReader.ProfileUsage]
            if profiles.isEmpty {
                let snap = self.reader.snapshot(
                    additionalEntries: cloud[Self.autoProfileID] ?? [])
                usages = [ClaudeUsageReader.ProfileUsage(id: Self.autoProfileID,
                                                         name: "", snapshot: snap)]
            } else {
                usages = self.reader.snapshots(for: profiles, additionalEntries: cloud)
            }
            DispatchQueue.main.async { self.profileUsages = usages }
        }
    }

    // MARK: Display helpers

    /// True once more than one profile is tracked; the panel then switches to
    /// the stacked per-profile layout.
    var isMultiProfile: Bool { profileUsages.count > 1 }

    var usesCloudData: Bool { !cloudProfileIDs.isEmpty }

    /// The single-profile panel reads this; with several profiles it is the
    /// first one, which the stacked layout does not use.
    var snapshot: ClaudeUsageSnapshot {
        profileUsages.first?.snapshot ?? ClaudeUsageSnapshot()
    }
}


// MARK: - Weather (Open-Meteo, key-less public API)

struct WeatherInfo: Equatable {
    var temperature: Double = 0
    var weatherCode: Int = 0
    var windSpeed: Double = 0
    var isAvailable = false

    var symbolName: String {
        switch weatherCode {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...67: return "cloud.drizzle"
        case 71...77: return "cloud.snow"
        case 80...82: return "cloud.rain"
        case 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}

final class WeatherModel: ObservableObject {
    @Published var info = WeatherInfo()

    private var timer: Timer?
    private var latitude = 0.0
    private var longitude = 0.0
    private var isRunning = false

    func start(latitude: Double, longitude: Double) {
        if isRunning, latitude == self.latitude, longitude == self.longitude { return }
        self.latitude = latitude
        self.longitude = longitude
        isRunning = true
        fetch()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func fetch() {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
        ]
        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any]
            else { return }
            var info = WeatherInfo()
            info.temperature = (current["temperature_2m"] as? Double) ?? 0
            info.weatherCode = (current["weather_code"] as? Int) ?? 0
            info.windSpeed = (current["wind_speed_10m"] as? Double) ?? 0
            info.isAvailable = true
            DispatchQueue.main.async { self.info = info }
        }.resume()
    }
}
