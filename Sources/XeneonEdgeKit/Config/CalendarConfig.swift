// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konfiguration des Kalender-Widgets, abgelegt als JSON in
// ~/Library/Application Support/XeneonEdge/calendar.json
//
// Die Feed-URL ist ein Geheimnis (private ICS-Adresse). Deshalb: Datei nur
// mit 0600, nie ein Fehlerobjekt oder Dateiinhalt im Log.

import Foundation

public struct CalendarConfig: Codable, Equatable, Sendable {
    public var enabled = false
    /// Geheime ICS-Feed-URL. Nur https wird je abgerufen.
    public var feedURL = ""
    public var leadMinutes: Double = 60
    public var graceMinutes: Double = 2
    public var maxReminders = 2
    public var pollSeconds: Double = 300
    public var showEventTitles = true
    public var feedOwnerEmail = ""

    public init() {}

    // MARK: Tolerantes Decoding
    // Jedes Feld faellt auf den Default zurueck, damit eine handgeschriebene
    // Datei mit nur einem Schluessel gueltig bleibt. Zahlen werden geklemmt.

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CalendarConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        feedURL = (try c.decodeIfPresent(String.self, forKey: .feedURL) ?? d.feedURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        leadMinutes = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .leadMinutes),
                                 5...240, d.leadMinutes)
        graceMinutes = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .graceMinutes),
                                  0...30, d.graceMinutes)
        maxReminders = min(4, max(1, try c.decodeIfPresent(Int.self, forKey: .maxReminders) ?? d.maxReminders))
        pollSeconds = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .pollSeconds),
                                 60...3600, d.pollSeconds)
        showEventTitles = try c.decodeIfPresent(Bool.self, forKey: .showEventTitles) ?? d.showEventTitles
        feedOwnerEmail = try c.decodeIfPresent(String.self, forKey: .feedOwnerEmail) ?? d.feedOwnerEmail
    }

    private static func clamp(_ value: Double?, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: Abgeleitete Werte

    /// Nur true bei `enabled` und einer https-URL mit Host. Ohne das wird
    /// nirgends ein Request gebaut.
    public var isConfigured: Bool {
        enabled && CalendarFeedFetcher.httpsURL(from: feedURL) != nil
    }

    public var reminderOptions: ReminderOptions {
        ReminderOptions(leadMinutes: leadMinutes, graceMinutes: graceMinutes,
                        maxReminders: maxReminders, feedOwnerEmail: feedOwnerEmail)
    }

    // MARK: Persistenz

    public static var fileURL: URL {
        AppConfig.directory.appendingPathComponent("calendar.json")
    }

    /// Fehlende oder kaputte Datei ergibt Defaults und schreibt nichts. Das
    /// Log nennt nie das Fehlerobjekt: ein DecodingError kann Inhalt zitieren.
    public static func load(from url: URL = fileURL) -> CalendarConfig {
        guard let data = try? Data(contentsOf: url) else { return CalendarConfig() }
        tightenPermissions(at: url)
        do {
            return try JSONDecoder().decode(CalendarConfig.self, from: data)
        } catch {
            NSLog("XeneonEdge: calendar.json nicht lesbar - Defaults aktiv")
            return CalendarConfig()
        }
    }

    /// Von Hand angelegte Dateien (typisch 0644) werden auf 0600 gesetzt.
    private static func tightenPermissions(at url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              perms & 0o077 != 0
        else { return }
        if (try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil {
            NSLog("XeneonEdge: Rechte von calendar.json auf 0600 gesetzt")
        } else {
            NSLog("XeneonEdge: Rechte von calendar.json konnten nicht gesetzt werden")
        }
    }

    /// Schreibt die Konfiguration. Die Temp-Datei entsteht bereits mit 0600
    /// im Zielverzeichnis und wird per rename ersetzt, so liegt der Inhalt
    /// nie mit weiteren Rechten auf der Platte. Wirft bei Fehlern.
    public func save(to url: URL = fileURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".calendar-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }

        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
