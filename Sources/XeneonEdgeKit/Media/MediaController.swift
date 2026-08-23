// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Media widget backend: transport control via system media keys (works with
// every app that honors the keyboard media keys) and now-playing metadata
// via Apple Events for Music and Spotify (public scripting interfaces —
// no private frameworks).

import AppKit
import Foundation

public struct NowPlaying: Equatable {
    public var title = ""
    public var artist = ""
    public var appName = ""
    public var isPlaying = false
    public var isAvailable = false
}

public final class MediaController {
    public init() {}

    // MARK: Transport (system media keys)

    private enum MediaKey: Int32 {
        case play = 16      // NX_KEYTYPE_PLAY
        case next = 17      // NX_KEYTYPE_NEXT
        case previous = 18  // NX_KEYTYPE_PREVIOUS
        case fast = 19      // NX_KEYTYPE_FAST
        case rewind = 20    // NX_KEYTYPE_REWIND
    }

    public func playPause() { post(.play) }
    public func next() { post(.fast) }
    public func previous() { post(.rewind) }

    private func post(_ key: MediaKey) {
        func emit(down: Bool) {
            let flags: UInt = down ? 0xA00 : 0xB00
            let data1 = Int((Int32(key.rawValue) << 16) | Int32(flags))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        emit(down: true)
        emit(down: false)
    }

    // MARK: Now playing (Apple Events)

    private struct Player {
        let bundleID: String
        let appName: String
        let script: String
    }

    private static let players: [Player] = [
        Player(
            bundleID: "com.spotify.client",
            appName: "Spotify",
            script: """
            tell application "Spotify"
                set t to name of current track
                set a to artist of current track
                set s to player state as string
            end tell
            return t & "\\n" & a & "\\n" & s
            """
        ),
        Player(
            bundleID: "com.apple.Music",
            appName: "Music",
            script: """
            tell application "Music"
                set t to name of current track
                set a to artist of current track
                set s to player state as string
            end tell
            return t & "\\n" & a & "\\n" & s
            """
        ),
    ]

    /// Polls the first running player for track metadata. Runs Apple Events —
    /// call from a background queue; the first call triggers the macOS
    /// automation permission prompt.
    public func nowPlaying() -> NowPlaying {
        for player in Self.players {
            let running = !NSRunningApplication
                .runningApplications(withBundleIdentifier: player.bundleID).isEmpty
            guard running else { continue }

            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: player.script) else { continue }
            let output = script.executeAndReturnError(&errorInfo)
            guard errorInfo == nil, let text = output.stringValue else { continue }

            let parts = text.components(separatedBy: "\n")
            guard parts.count >= 3 else { continue }
            var info = NowPlaying()
            info.title = parts[0]
            info.artist = parts[1]
            info.isPlaying = parts[2].lowercased().contains("playing")
            info.appName = player.appName
            info.isAvailable = true
            return info
        }
        return NowPlaying()
    }
}
