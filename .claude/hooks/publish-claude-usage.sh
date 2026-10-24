#!/usr/bin/env bash
# XeneonEdge for macOS — Claude Code relay hook (Stop + UserPromptSubmit).
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs INSIDE a remote/cloud Claude Code session and publishes two things
# about this session to one GitHub Gist, so the XeneonEdge widget/panel on
# your Mac can include sessions that never touch its local ~/.claude folder:
#
#   session-<id>.jsonl  {timestamp, model, token counts} per assistant reply
#   state-<id>.json     the chat state for the chat overview: working /
#                       awaitingAnswer / idle, plus a label, branch and model
#
# Never prompt or response text — with one exception the remote environment
# has to switch on itself (XENEON_RELAY_QUESTION_TEXT=1), which relays the
# trailing question of the last reply so the Mac can show what is being
# asked. A secret gist is unlisted, not access-controlled: leave it off
# unless the question text may be read by anyone who learns the gist id.
#
# Setup: see docs/CLAUDE-USAGE-WIDGET.md ("Cloud-Relay: Sessions aus der
# Cloud/Remote-Umgebung"). Requires two environment variables in whichever
# remote environment(s) you want tracked:
#   XENEON_USAGE_GIST_ID     - created once by Scripts/setup-cloud-usage-relay.sh
#   XENEON_USAGE_GIST_TOKEN  - a classic GitHub PAT with the "gist" scope
#                              (fine-grained PATs and GitHub App tokens
#                              cannot call the Gists API)
# Optional:
#   XENEON_RELAY_LABEL          - name shown for this chat (default: the
#                                 working directory's last path component;
#                                 the full path never leaves this machine)
#   XENEON_RELAY_QUESTION_TEXT  - 1 relays the trailing question, see above
#   XENEON_RELAY_STATE          - 0 publishes usage only, no chat state
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
event="$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)"
hook_cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[[ -z "$session_id" ]] && exit 0

safe_id="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-' | cut -c1-40)"
[[ -z "$safe_id" ]] && exit 0

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
files_json=""

# ---------------------------------------------------------------- usage ----
# Project down to exactly the fields the Mac-side parser reads
# (ClaudeUsageReader.parseLine): type, timestamp, requestId, costUSD (if
# present), message.id, message.model, message.usage. Everything else in
# the transcript — prompt text, tool output, file contents — is dropped
# here and never leaves this machine.
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
  usage_lines="$(jq -c '
    select(.type == "assistant" and (.message.usage // empty) != null) |
    {type, timestamp, requestId, costUSD,
     message: {id: .message.id, model: .message.model, usage: .message.usage}}
  ' "$transcript_path" 2>/dev/null || true)"
  if [[ -n "$usage_lines" ]]; then
    # A PATCH with empty file content DELETES that gist file — the content
    # is guaranteed non-empty here, so that never happens accidentally.
    files_json="$(jq -n --arg fname "session-${safe_id}.jsonl" --arg content "$usage_lines" \
      '{($fname): {content: $content}}')"
  fi
fi

# ---------------------------------------------------------------- state ----
# The hook only ever runs at a turn boundary, so only two of the three
# states can be observed here, and the Mac derives the rest from the age of
# this file: UserPromptSubmit means a turn just started (working), Stop
# means the turn ended and the chat is back in the human's court — waiting
# for an answer if the reply ended on a question or asked one outright,
# otherwise simply idle. A session whose container dies mid-turn stops
# publishing, and "working" decays to idle on the Mac once its active
# window passes.
if [[ "${XENEON_RELAY_STATE:-1}" != "0" ]]; then
  state="idle"
  state_ts="$now"
  model=""
  branch=""
  label="${XENEON_RELAY_LABEL:-}"
  question=""

  if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    # Only the tail matters for the state, and transcripts grow into the
    # megabytes — slurping the whole file here would cost more than the
    # usage projection above.
    tail_json="$(tail -n 400 "$transcript_path" 2>/dev/null | jq -c -s '
      [.[] | select(.type == "assistant" and (.isSidechain != true))] | last // empty |
      {ts: .timestamp, model: .message.model, branch: .gitBranch, cwd: .cwd,
       asks: ([.message.content[]? | select(.type == "tool_use") | .name]
              | map(. == "AskUserQuestion" or . == "ExitPlanMode") | any),
       asked: ([.message.content[]? | select(.type == "tool_use")
                | select(.name == "AskUserQuestion") | .input.questions[]?.question]
               | join(" · ")),
       text: ([.message.content[]? | select(.type == "text") | .text] | join(" "))}
    ' 2>/dev/null || true)"
    if [[ -n "$tail_json" ]]; then
      model="$(jq -r '.model // empty' <<<"$tail_json" 2>/dev/null)"
      branch="$(jq -r '.branch // empty' <<<"$tail_json" 2>/dev/null)"
      [[ -z "$label" ]] && label="$(jq -r '.cwd // empty' <<<"$tail_json" 2>/dev/null)"
      ts="$(jq -r '.ts // empty' <<<"$tail_json" 2>/dev/null)"
      [[ -n "$ts" ]] && state_ts="$ts"
      text="$(jq -r '.text // empty' <<<"$tail_json" 2>/dev/null)"
      if [[ "$(jq -r '.asks // false' <<<"$tail_json" 2>/dev/null)" == "true" ]]; then
        state="awaitingAnswer"
        if [[ "${XENEON_RELAY_QUESTION_TEXT:-0}" == "1" ]]; then
          question="$(jq -r '.asked // empty' <<<"$tail_json" 2>/dev/null \
            | tr '\n' ' ' | cut -c1-200 | sed 's/[[:space:]]*$//')"
        fi
      elif [[ "$text" =~ \?[[:space:]]*$ ]]; then
        state="awaitingAnswer"
        # The trailing sentence only — and only when this environment opted
        # in to relaying any conversation text at all.
        if [[ "${XENEON_RELAY_QUESTION_TEXT:-0}" == "1" ]]; then
          question="$(printf '%s' "$text" | tr '\n' ' ' \
            | grep -o '[^.!?]*?[[:space:]]*$' | cut -c1-200 \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        fi
      fi
    fi
  fi

  # A prompt was just submitted: the turn starts now, whatever the
  # transcript's last reply says.
  if [[ "$event" == "UserPromptSubmit" ]]; then
    state="working"
    state_ts="$now"
    question=""
  fi

  [[ -z "$label" ]] && label="$hook_cwd"
  # Only the folder name, never the full path: it can carry a customer or
  # project name and is of no use on the Mac anyway.
  label="$(basename -- "${label:-}" 2>/dev/null || true)"

  state_content="$(jq -n --arg id "$session_id" --arg state "$state" --arg ts "$state_ts" \
    --arg label "$label" --arg branch "$branch" --arg model "$model" --arg question "$question" \
    '{schema: 1, sessionId: $id, state: $state, timestamp: $ts}
     + (if $label    == "" then {} else {label: $label}       end)
     + (if $branch   == "" then {} else {gitBranch: $branch}  end)
     + (if $model    == "" then {} else {model: $model}       end)
     + (if $question == "" then {} else {question: $question} end)')"

  if [[ -n "$state_content" ]]; then
    # A session with no assistant reply yet (a brand-new chat's first
    # prompt) publishes its state alone, so the empty default matters.
    [[ -z "$files_json" ]] && files_json="{}"
    files_json="$(jq -n --argjson existing "$files_json" \
      --arg fname "state-${safe_id}.json" --arg content "$state_content" \
      '$existing + {($fname): {content: $content}}')"
  fi
fi

[[ -z "$files_json" || "$files_json" == "{}" ]] && exit 0

# Both files go out in one PATCH: the gist API replaces the files named
# here and leaves every other session's files untouched.
curl -sS --max-time 8 -X PATCH "https://api.github.com/gists/${GIST_ID}" \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -d "$(jq -n --argjson files "$files_json" '{files: $files}')" >/dev/null 2>&1 || true

exit 0
