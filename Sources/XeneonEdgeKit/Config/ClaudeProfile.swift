// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One Claude Code profile: a single login with its own config directory, its
// own transcripts and — the reason this type exists — its own 5-hour limit
// window. Anyone running a personal and a work account has two of them side
// by side, and their usage must never be added up: the sum belongs to
// neither limit, and a shared reset countdown would be wrong for at least
// one of them.
//
// A profile is created by starting Claude Code with CLAUDE_CONFIG_DIR
// pointing at a directory of its own, e.g.
//
//     CLAUDE_CONFIG_DIR=~/.claude-work claude
//
// which logs in separately and keeps its transcripts under that directory.

import Foundation

public struct ClaudeProfile: Codable, Equatable, Identifiable {
    public var id = UUID()
    /// Label shown next to this profile's numbers.
    public var name: String
    /// The profile's config directory, e.g. "~/.claude" or "~/.claude-work".
    /// A leading tilde is expanded.
    public var configDir: String
    /// Optional cloud relay gist for *this* profile — a remote/cloud session
    /// started under this login publishes there. Empty means local logs only.
    public var cloudGistID: String

    public init(name: String, configDir: String, cloudGistID: String = "") {
        self.name = name
        self.configDir = configDir
        self.cloudGistID = cloudGistID
    }

    public var directoryURL: URL {
        URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
    }

    /// `id` is an internal detail of the SwiftUI list and the label is
    /// optional, so a hand-written entry can be as short as
    /// `{"configDir": "~/.claude-work"}`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        configDir = try c.decode(String.self, forKey: .configDir)
        if let decodedName = try c.decodeIfPresent(String.self, forKey: .name),
           !decodedName.isEmpty {
            name = decodedName
        } else {
            // Fall back to the directory name: "~/.claude-work" -> "claude-work".
            let base = (configDir as NSString).lastPathComponent
            name = base.hasPrefix(".") ? String(base.dropFirst()) : base
        }
        cloudGistID = try c.decodeIfPresent(String.self, forKey: .cloudGistID) ?? ""
    }
}
