#!/bin/bash
# XeneonEdge for macOS — writes a sample ICS file with events relative to now.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Local test of the calendar panel without Google: the debug build reads this
# file when XENEON_CALENDAR_ICS_FILE is set (the release build ignores it).
# Usage: ./Scripts/sample-calendar.sh [output-path]
# Uses BSD date (macOS): `date -u -v+4M`.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-${TMPDIR:-/tmp}/xeneon-sample.ics}"
FMT="+%Y%m%dT%H%M%SZ"

stamp() { date -u "-v$1" "$FMT"; }

# event <uid> <summary> <start-offset> <duration-offset> [status]
event() {
    local uid="$1" summary="$2" start end status="${5:-CONFIRMED}"
    start="$(stamp "$3")"
    end="$(date -u "-v$3" "-v$4" "$FMT")"
    printf 'BEGIN:VEVENT\nUID:%s@xeneon-sample\nDTSTAMP:%s\nDTSTART:%s\nDTEND:%s\nSUMMARY:%s\nSTATUS:%s\nEND:VEVENT\n' \
        "$uid" "$(date -u "$FMT")" "$start" "$end" "$summary" "$status"
}

{
    printf 'BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//XeneonEdge//sample//DE\n'
    event in50s   "In 50 Sekunden"  +50S  +1H
    event in4m    "In 4 Minuten"    +4M   +1H
    event in12m   "In 12 Minuten"   +12M  +1H
    event in25m   "In 25 Minuten"   +25M  +1H
    event in50m   "In 50 Minuten"   +50M  +2H
    event started "Vor 1 Minute begonnen" -1M +1H
    event cancel  "Abgesagt"        +8M   +1H CANCELLED
    printf 'BEGIN:VEVENT\nUID:allday@xeneon-sample\nDTSTAMP:%s\nDTSTART;VALUE=DATE:%s\nDTEND;VALUE=DATE:%s\nSUMMARY:Ganztagstermin\nEND:VEVENT\n' \
        "$(date -u "$FMT")" "$(date +%Y%m%d)" "$(date -v+1d +%Y%m%d)"
    printf 'END:VCALENDAR\n'
} > "$OUT"

echo "Beispieldatei: $OUT"
echo "Startbefehl (Debug-Build, showCalendar im Menue unter Widgets > Termine einschalten):"
echo "  XENEON_CALENDAR_ICS_FILE=\"$OUT\" .build/debug/XeneonEdgeApp"
