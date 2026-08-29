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
// This fetcher reads that Gist back. Gist reads by id need no
// authentication regardless of "secret" vs "public" visibility — a secret
// gist is unlisted, not access-controlled, which is why only token counts
// (never conversation content) are ever put there. See
// docs/CLAUDE-USAGE-WIDGET.md for the full setup and privacy tradeoff.

import Foundation

public enum CloudUsageFetcher {
    /// Fetches every file in the given Gist and parses each line with the
    /// exact same parser used for local transcript files, so the cloud
    /// relay's line format is required to match the local one byte-for-byte.
    /// Returns an empty array on any network or parsing failure — a stale
    /// or unreachable relay must never crash or block the local display.
    public static func fetch(gistID: String, session: URLSession = .shared) async -> [ClaudeUsageEntry] {
        let trimmed = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "https://api.github.com/gists/\(trimmed)") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return [] }

        return parseGistResponse(data)
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
        for name in files.keys.sorted() {
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
}
