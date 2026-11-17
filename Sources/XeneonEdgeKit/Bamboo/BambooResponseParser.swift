// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reines Parsen der Bamboo-REST-Antworten, ohne Netz.
//
// FELDNAMEN: Am 2026-11-17 am Server bestaetigt. Gelesen wird tolerant:
// - result/{planKey}.json?expand=results.result:
//   {"results":{"result":[{lifeCycleState, buildState, buildDuration (ms),
//   buildDurationInSeconds, buildCompletedTime}]}}
//   buildCompletedTime im Format "2026-11-17T20:56:13.651+01:00".
// - plan/{planKey}/branch.json: {"branches":{"branch":[{key, enabled}]}}
//   Deaktivierte Branches (enabled == false) bleiben drin: Bamboo
//   deaktiviert Branch-Plaene nach dem Merge, ihre Builds gehoeren trotzdem
//   in die Statistik (DMCUBE: 101 von 135 Builds im Fenster).
// - Zeiten mit oder ohne Bruchteile, Offset mit oder ohne Doppelpunkt.
// - Eintraege mit fehlenden oder unlesbaren Pflichtfeldern fliegen raus,
//   kaputtes JSON ergibt eine leere Liste.

import Foundation

public enum BambooResponseParser {
    public static func parseResults(_ data: Data) -> [BambooBuild] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let entries = results["result"] as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            guard entry["lifeCycleState"] as? String == "Finished",
                  let state = entry["buildState"] as? String,
                  state == "Successful" || state == "Failed" else { return nil }

            let seconds: Double
            if let millis = number(entry["buildDuration"]) {
                seconds = millis / 1000
            } else if let direct = number(entry["buildDurationInSeconds"]) {
                seconds = direct
            } else {
                return nil
            }
            guard seconds >= 0 else { return nil }

            guard let text = entry["buildCompletedTime"] as? String,
                  let date = parseDate(text) else { return nil }

            return BambooBuild(completedAt: date, duration: seconds,
                               successful: state == "Successful")
        }
    }

    public static func parseBranchKeys(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branches = root["branches"] as? [String: Any],
              let entries = branches["branch"] as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            guard let key = entry["key"] as? String, !key.isEmpty else { return nil }
            return key
        }
    }

    /// Zahl aus JSON (Int oder Double); Strings und Bools zaehlen nicht.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    // Einmal angelegt, danach nur noch zum Parsen benutzt (dafuer thread-sicher).
    private nonisolated(unsafe) static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // Offset ohne Doppelpunkt (+0100), wie ihn manche Bamboo-Versionen liefern.
    private static let offsetFormatters: [DateFormatter] =
        ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"].map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }

    private static func parseDate(_ text: String) -> Date? {
        if let date = isoWithFraction.date(from: text) { return date }
        if let date = isoPlain.date(from: text) { return date }
        for formatter in offsetFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
