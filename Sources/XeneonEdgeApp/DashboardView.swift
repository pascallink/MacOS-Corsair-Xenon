// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The iCUE-style dashboard rendered fullscreen on the XENEON EDGE strip
// (2560x720). All widgets are touch-first: big targets, no hover states.

import AppKit
import SwiftUI
import XeneonEdgeKit

enum EdgeTheme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.075)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.135)
    static let panelBorder = Color.white.opacity(0.07)
    static let accent = Color(red: 0.93, green: 0.79, blue: 0.12) // Corsair yellow
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
}

struct DashboardView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var media: MediaModel
    @EnvironmentObject var volume: VolumeModel
    @EnvironmentObject var weather: WeatherModel
    @EnvironmentObject var claude: ClaudeUsageModel

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 1600
            HStack(spacing: 16) {
                if configStore.config.showClock {
                    ClockPanel(showWeather: configStore.config.showWeather,
                               placeName: configStore.config.weatherPlaceName)
                        .frame(maxWidth: geo.size.width * (compact ? 0.30 : 0.24))
                }
                if configStore.config.showStats {
                    StatsPanel()
                }
                if configStore.config.showMedia || configStore.config.showVolume
                    || configStore.config.showClaudeUsage {
                    VStack(spacing: 16) {
                        if configStore.config.showMedia { MediaPanel() }
                        if configStore.config.showClaudeUsage { ClaudeUsagePanel() }
                        if configStore.config.showVolume { VolumePanel() }
                    }
                    .frame(maxWidth: geo.size.width * 0.26)
                }
                if configStore.config.showLauncher {
                    LauncherPanel()
                        .frame(maxWidth: geo.size.width * 0.24)
                }
            }
            .padding(20)
        }
        .background(EdgeTheme.background)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Shared panel chrome

struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(EdgeTheme.textSecondary)
                .labelStyle(.titleAndIcon)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(EdgeTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(EdgeTheme.panelBorder))
        )
    }
}

// MARK: - Clock + weather

struct ClockPanel: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var weather: WeatherModel
    let showWeather: Bool
    let placeName: String

    var body: some View {
        Panel(title: "Uhrzeit", systemImage: "clock") {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.date, format: timeFormat)
                            .font(.system(size: 88, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(EdgeTheme.textPrimary)
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                        Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(EdgeTheme.accent)
                    }
                }
                if showWeather, weather.info.isAvailable {
                    Spacer(minLength: 4)
                    HStack(spacing: 10) {
                        Image(systemName: weather.info.symbolName)
                            .font(.system(size: 30))
                            .foregroundColor(EdgeTheme.accent)
                        Text(String(format: "%.0f °C", weather.info.temperature))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundColor(EdgeTheme.textPrimary)
                        Text(placeName)
                            .font(.system(size: 18))
                            .foregroundColor(EdgeTheme.textSecondary)
                    }
                }
            }
        }
    }

    private var timeFormat: Date.FormatStyle {
        var style = Date.FormatStyle().hour(.twoDigits(amPM: configStore.config.use24HourClock ? .omitted : .abbreviated)).minute(.twoDigits)
        style.timeZone = .current
        return style
    }
}

// MARK: - System statistics

struct StatsPanel: View {
    @EnvironmentObject var stats: StatsModel

    var body: some View {
        Panel(title: "System", systemImage: "gauge.medium") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 24) {
                    GaugeView(label: "CPU",
                              value: stats.snapshot.cpuUsage,
                              text: String(format: "%.0f%%", stats.snapshot.cpuUsage * 100))
                    GaugeView(label: "RAM",
                              value: stats.snapshot.memoryUsage,
                              text: ByteFormatter.size(stats.snapshot.memoryUsed))
                    VStack(alignment: .leading, spacing: 8) {
                        NetworkRow(symbol: "arrow.down",
                                   text: ByteFormatter.rate(stats.snapshot.networkRxBytesPerSecond))
                        NetworkRow(symbol: "arrow.up",
                                   text: ByteFormatter.rate(stats.snapshot.networkTxBytesPerSecond))
                        Text("Netzwerk")
                            .font(.system(size: 14))
                            .foregroundColor(EdgeTheme.textSecondary)
                    }
                }
                SparklineView(values: stats.cpuHistory)
                    .frame(maxWidth: .infinity)
                    .frame(height: 70)
            }
        }
    }
}

struct NetworkRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(EdgeTheme.accent)
            Text(text)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(EdgeTheme.textPrimary)
        }
    }
}

struct GaugeView: View {
    let label: String
    let value: Double // 0...1
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * min(max(value, 0), 1))
                    .stroke(EdgeTheme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(text)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(EdgeTheme.textPrimary)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: 110, height: 110)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(EdgeTheme.textSecondary)
        }
    }
}

struct SparklineView: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let points = normalizedPoints(in: geo.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for p in points { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(EdgeTheme.accent.opacity(0.15))
                    Path { path in
                        path.move(to: points[0])
                        for p in points.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(EdgeTheme.accent, lineWidth: 2)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
        )
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * stepX,
                    y: size.height * (1 - CGFloat(min(max(value, 0), 1))))
        }
    }
}

// MARK: - Media

struct MediaPanel: View {
    @EnvironmentObject var media: MediaModel

    var body: some View {
        Panel(title: "Medien", systemImage: "music.note") {
            VStack(alignment: .leading, spacing: 10) {
                if media.nowPlaying.isAvailable {
                    Text(media.nowPlaying.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(EdgeTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(media.nowPlaying.artist) — \(media.nowPlaying.appName)")
                        .font(.system(size: 17))
                        .foregroundColor(EdgeTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Keine Wiedergabe")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(EdgeTheme.textSecondary)
                }
                Spacer(minLength: 2)
                HStack(spacing: 26) {
                    MediaButton(symbol: "backward.fill") { media.previous() }
                    MediaButton(symbol: media.nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                                prominent: true) { media.playPause() }
                    MediaButton(symbol: "forward.fill") { media.next() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct MediaButton: View {
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 30 : 22, weight: .bold))
                .foregroundColor(prominent ? .black : EdgeTheme.textPrimary)
                .frame(width: prominent ? 72 : 56, height: prominent ? 72 : 56)
                .background(Circle().fill(prominent ? EdgeTheme.accent : Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Claude Code usage

struct ClaudeUsagePanel: View {
    @EnvironmentObject var claude: ClaudeUsageModel
    @EnvironmentObject var configStore: ConfigStore

    private var block: UsageBlock? { claude.snapshot.activeBlock }

    private var blockTokens: Int { block?.totals.billableTokens ?? 0 }

    private var budgetFraction: Double? {
        let budget = configStore.config.claudeTokenBudgetPerBlock
        guard budget > 0 else { return nil }
        return min(Double(blockTokens) / Double(budget), 1.0)
    }

    private var elapsedFraction: Double {
        guard let block else { return 0 }
        return min(max(Date().timeIntervalSince(block.start) / UsageBlock.duration, 0), 1)
    }

    private var ringColor: Color {
        guard let fraction = budgetFraction else { return EdgeTheme.accent }
        if fraction >= 0.9 { return Color(red: 0.92, green: 0.30, blue: 0.30) }
        if fraction >= 0.7 { return Color(red: 0.95, green: 0.55, blue: 0.20) }
        return Color(red: 0.35, green: 0.80, blue: 0.45)
    }

    var body: some View {
        Panel(title: "Claude", systemImage: "gauge.with.needle") {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: budgetFraction ?? elapsedFraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.5), value: blockTokens)
                    VStack(spacing: 0) {
                        Text(UsageFormat.tokens(blockTokens))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(EdgeTheme.textPrimary)
                            .minimumScaleFactor(0.5)
                        Text("Tokens")
                            .font(.system(size: 10))
                            .foregroundColor(EdgeTheme.textSecondary)
                    }
                }
                .frame(width: 84, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    if let block {
                        Text("Reset in \(UsageFormat.countdown(block.remaining(at: Date())))")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(EdgeTheme.textPrimary)
                        Text("Fenster \(UsageFormat.cost(block.totals.costUSD)) · heute \(UsageFormat.cost(claude.snapshot.today.costUSD))")
                            .font(.system(size: 13))
                            .foregroundColor(EdgeTheme.textSecondary)
                    } else {
                        Text("Keine aktive Session")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(EdgeTheme.textSecondary)
                        Text("heute \(UsageFormat.cost(claude.snapshot.today.costUSD))")
                            .font(.system(size: 13))
                            .foregroundColor(EdgeTheme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        if let model = claude.snapshot.latestModel {
                            Text(ModelPricing.displayName(for: model))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(EdgeTheme.accent))
                        }
                        if claude.usesCloudData {
                            Label("Cloud", systemImage: "icloud")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(EdgeTheme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Volume

struct VolumePanel: View {
    @EnvironmentObject var volume: VolumeModel

    var body: some View {
        Panel(title: "Lautstärke", systemImage: "speaker.wave.2") {
            HStack(spacing: 14) {
                Button {
                    volume.toggleMute()
                } label: {
                    Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 22))
                        .foregroundColor(volume.muted ? EdgeTheme.textSecondary : EdgeTheme.accent)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { Double(volume.volume) },
                        set: { volume.userChanged(to: Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(EdgeTheme.accent)

                Text("\(Int(volume.volume * 100))%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(EdgeTheme.textPrimary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }
}

// MARK: - App launcher ("Virtual Stream Deck")

struct LauncherPanel: View {
    @EnvironmentObject var configStore: ConfigStore

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        Panel(title: "Schnellstart", systemImage: "square.grid.2x2") {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(configStore.config.launcherItems) { item in
                    Button {
                        launch(item)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 28))
                                .foregroundColor(EdgeTheme.accent)
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(EdgeTheme.textPrimary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92)
                        .background(
                            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func launch(_ item: LauncherItem) {
        let workspace = NSWorkspace.shared
        let url: URL?
        if item.target.hasPrefix("/") {
            url = URL(fileURLWithPath: item.target)
        } else {
            url = workspace.urlForApplication(withBundleIdentifier: item.target)
        }
        guard let url else { return }
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                  completionHandler: nil)
    }
}
