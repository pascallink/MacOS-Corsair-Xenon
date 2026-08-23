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
        didSet { config.save() }
    }

    init() {
        config = AppConfig.load()
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

    func start(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        fetch()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
