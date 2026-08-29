#!/usr/bin/env bash
# XeneonEdge for macOS — Claude Code Stop hook.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs INSIDE a remote/cloud Claude Code session after each turn. Extracts
# only {timestamp, model, token counts} — never prompt or response text —
# from this session's own transcript, and publishes them to one GitHub Gist
# as one file per session id, so the XeneonEdge Claude-usage widget/panel on
# your Mac can include sessions that never touch its local ~/.claude folder.
#
# Setup: see docs/CLAUDE-USAGE-WIDGET.md ("Cloud-Relay: Sessions aus der
# Cloud/Remote-Umgebung"). Requires two environment variables in whichever
# remote environment(s) you want tracked:
#   XENEON_USAGE_GIST_ID     - created once by Scripts/setup-cloud-usage-relay.sh
#   XENEON_USAGE_GIST_TOKEN  - a classic GitHub PAT with the "gist" scope
#                              (fine-grained PATs and GitHub App tokens
#                              cannot call the Gists API)
#
# Never blocks or fails the session: every error path exits 0 silently.
set -u
trap 'exit 0' ERR

GIST_ID="${XENEON_USAGE_GIST_ID:-}"
TOKEN="${XENEON_USAGE_GIST_TOKEN:-}"
[[ -z "$GIST_ID" || -z "$TOKEN" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

input="$(cat)"
transcript_path="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
session_id="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
[[ -z "$transcript_path" || -z "$session_id" || ! -f "$transcript_path" ]] && exit 0

# Project down to exactly the fields the Mac-side parser reads
# (ClaudeUsageReader.parseLine): type, timestamp, requestId, costUSD (if
# present), message.id, message.model, message.usage. Everything else in
# the transcript — prompt text, tool output, file contents — is dropped
# here and never leaves this machine.
usage_lines="$(jq -c '
  select(.type == "assistant" and (.message.usage // empty) != null) |
  {type, timestamp, requestId, costUSD,
   message: {id: .message.id, model: .message.model, usage: .message.usage}}
' "$transcript_path" 2>/dev/null || true)"
[[ -z "$usage_lines" ]] && exit 0

safe_id="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-' | cut -c1-40)"
[[ -z "$safe_id" ]] && exit 0
filename="session-${safe_id}.jsonl"

payload="$(jq -n --arg fname "$filename" --arg content "$usage_lines" \
  '{files: {($fname): {content: $content}}}')"

# A PATCH with empty file content DELETES that gist file — usage_lines is
# already guaranteed non-empty above, so this never happens accidentally.
curl -sS --max-time 8 -X PATCH "https://api.github.com/gists/${GIST_ID}" \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -d "$payload" >/dev/null 2>&1 || true

exit 0
