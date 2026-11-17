// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reines Parsen der Bamboo-REST-Antworten, ohne Netz.
//
// ANNAHMEN: Die Feldnamen stammen aus der Bamboo-REST-Doku und sind nicht am
// Server verifiziert (es stand kein Token zur Verfuegung). Deshalb wird
// tolerant gelesen:
// - result/{planKey}.json?expand=results.result:
//   {"results":{"result":[{lifeCycleState, buildState, buildDuration (ms),
//   buildDurationInSeconds, buildCompletedTime (ISO 8601)}]}}
// - plan/{planKey}/branch.json: {"branches":{"branch":[{key, enabled}]}}
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
            if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
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

    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        // Offset ohne Doppelpunkt (+0100), wie ihn manche Bamboo-Versionen liefern.
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
