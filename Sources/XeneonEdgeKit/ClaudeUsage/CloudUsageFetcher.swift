// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Optional relay for Claude Code sessions that run in a remote/cloud
// environment, where ClaudeUsageReader's local ~/.claude/projects scan can
// never see them (different filesystem entirely).
//
// A Stop hook running INSIDE the remote session (see
// .claude/hooks/publish-claude-usage.sh in this repo) extracts only
// {timestamp, model, token counts} from its own transcript — never prompt
// or response text — and publishes them to one GitHub Gist, one file per
// session id, overwriting that file's full content on every turn.
//
// The same hook also publishes one small state file per session — the
// chat's state (working / waiting for an answer / idle) and a label, so the
// chat overview can show sessions that run elsewhere. Conversation text is
// published only if that environment explicitly opts in.
//
// This fetcher reads that Gist back. Gist reads by id need no
// authentication regardless of "secret" vs "public" visibility — a secret
// gist is unlisted, not access-controlled, which is why only token counts
// (never conversation content) are ever put there. See
// docs/CLAUDE-USAGE-WIDGET.md for the full setup and privacy tradeoff.

import Foundation

/// Everything one relay Gist carries: token counts for the usage numbers,
/// and chat states for the chat overview. Both come out of a single HTTP
/// request — the Gist API returns all files of a gist at once, and polling
/// the same gist twice per interval would burn through GitHub's limit of 60
/// unauthenticated requests per hour and IP twice as fast.
public struct CloudRelayPayload: Equatable {
    public var entries: [ClaudeUsageEntry]
    public var sessions: [ClaudeSessionSummary]

    public init(entries: [ClaudeUsageEntry] = [], sessions: [ClaudeSessionSummary] = []) {
        self.entries = entries
        self.sessions = sessions
    }

    public var isEmpty: Bool { entries.isEmpty && sessions.isEmpty }
}

public enum CloudUsageFetcher {
    /// Chat states live in their own `state-*` files, next to the
    /// `session-*` files holding usage lines. Keeping them apart lets either
    /// parser skip what is not its own, and lets an older XeneonEdge build
    /// ignore the state files it does not know about.
    static let statePrefix = "state-"

    /// Fetches every file in the given Gist and parses each line with the
    /// exact same parser used for local transcript files, so the cloud
    /// relay's line format is required to match the local one byte-for-byte.
    /// Returns an empty array on any network or parsing failure — a stale
    /// or unreachable relay must never crash or block the local display.
    public static func fetch(gistID: String, session: URLSession = .shared) async -> [ClaudeUsageEntry] {
        await fetchRelay(gistID: gistID, session: session).entries
    }

    /// Fetches the relay Gist once and returns both halves of it. Returns an
    /// empty payload on any network or parsing failure — a stale or
    /// unreachable relay must never crash or block the local display.
    public static func fetchRelay(gistID: String,
                                  session: URLSession = .shared) async -> CloudRelayPayload {
        let trimmed = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "https://api.github.com/gists/\(trimmed)") else {
            return CloudRelayPayload()
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return CloudRelayPayload() }

        return CloudRelayPayload(entries: parseGistResponse(data),
                                 sessions: parseSessionStates(data))
    }

    /// Parses a raw `GET /gists/{id}` response body. Pure and synchronous,
    /// so it is unit-tested directly against a canned response body.
    public static func parseGistResponse(_ data: Data) -> [ClaudeUsageEntry] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = json["files"] as? [String: Any]
        else { return [] }

        var seen = Set<String>()
        var entries: [ClaudeUsageEntry] = []
        // Dictionary order is unspecified; sort by filename (session id) so
        // repeated fetches produce deterministic ordering for display.
        for name in files.keys.sorted() where !name.hasPrefix(statePrefix) {
            guard let file = files[name] as? [String: Any],
                  let content = file["content"] as? String
            else { continue }
            content.enumerateLines { line, _ in
                guard let parsed = ClaudeUsageReader.parseLine(line) else { return }
                if let key = parsed.dedupKey {
                    if seen.contains(key) { return }
                    seen.insert(key)
                }
                entries.append(parsed.entry)
            }
        }
        return entries
    }

    // MARK: - Chat states

    /// Parses the relay's state files out of a raw `GET /gists/{id}` body.
    /// Pure and synchronous, so it is unit-tested against canned bodies.
    ///
    /// Unlike the usage half, these are not transcript lines: a remote
    /// session cannot be watched from here, so its hook publishes the state
    /// it sees at the end of each turn. Anything unparsable is skipped
    /// rather than guessed at — a half-read relay must not invent chats.
    public static func parseSessionStates(_ data: Data) -> [ClaudeSessionSummary] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = json["files"] as? [String: Any]
        else { return [] }

        var summaries: [ClaudeSessionSummary] = []
        for name in files.keys.sorted() where name.hasPrefix(statePrefix) {
            guard let file = files[name] as? [String: Any],
                  let content = file["content"] as? String,
                  let summary = parseSessionState(content)
            else { continue }
            summaries.append(summary)
        }
        return summaries
    }

    /// One state file: `{"schema":1,"sessionId":…,"state":…,"timestamp":…}`,
    /// plus the optional label, branch, model and question.
    static func parseSessionState(_ content: String) -> ClaudeSessionSummary? {
        guard let data = content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionID = (json["sessionId"] as? String)?.trimmingCharacters(in: .whitespaces),
              !sessionID.isEmpty,
              let state = (json["state"] as? String).flatMap(ClaudeSessionState.init(rawValue:)),
              let timestamp = (json["timestamp"] as? String)
                  .flatMap(ClaudeSessionReader.parseTimestamp)
        else { return nil }

        func text(_ key: String) -> String? {
            guard let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            return value
        }

        return ClaudeSessionSummary(
            // Prefixed so a relayed chat can never collide with a local one
            // of the same id — the same session resumed on both sides would
            // otherwise replace itself in the list.
            id: "cloud:" + sessionID,
            directory: text("label"),
            gitBranch: text("gitBranch"),
            lastActivity: timestamp,
            state: state,
            question: text("question"),
            model: text("model"),
            isRemote: true
        )
    }
}
