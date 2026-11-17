// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Versionsringe aus dem lokalen KI-Dashboard (GET /api/developers, Feld
// "versions"): Datenmodell und reiner Parser, ohne I/O.

import Foundation

public enum KIVersionArea: String, CaseIterable, Equatable {
    case preparation, development, acceptance, done

    public var title: String {
        switch self {
        case .preparation: return "Vorbereitung"
        case .development: return "Entwicklung"
        case .acceptance: return "Abnahme"
        case .done: return "Fertig"
        }
    }
}

public struct KIAreaCount: Equatable {
    public var area: KIVersionArea
    public var count: Int

    public init(area: KIVersionArea, count: Int) {
        self.area = area
        self.count = count
    }
}

public struct KIVersionRing: Equatable, Identifiable {
    public var id: String
    public var project: String
    public var name: String
    public var label: String
    public var releaseDate: String?
    public var released: Bool
    public var total: Int
    /// Nur gelieferte Bereiche, in Ringfolge (aussen nach innen).
    public var areas: [KIAreaCount]
    public var scorePercent: Int?

    public init(id: String, project: String, name: String, label: String,
                releaseDate: String? = nil, released: Bool = false, total: Int,
                areas: [KIAreaCount], scorePercent: Int? = nil) {
        self.id = id
        self.project = project
        self.name = name
        self.label = label
        self.releaseDate = releaseDate
        self.released = released
        self.total = total
        self.areas = areas
        self.scorePercent = scorePercent
    }

    /// Fuellung je Ring (Ringfolge), count / total auf 0...1 geklemmt; 0 bei total 0.
    public var fractions: [Double] {
        areas.map { total > 0 ? min(1, max(0, Double($0.count) / Double(total))) : 0 }
    }

    /// Alles fertig: total > 0 und done.count == total.
    public var allDone: Bool {
        guard total > 0, let done = areas.first(where: { $0.area == .done }) else { return false }
        return done.count == total
    }
}

public enum KIVersionsParser {
    /// Liest "versions" aus der Antwort von /api/developers. nil bei ungueltigem
    /// JSON oder fehlendem Array; kaputte Einzeleintraege werden uebersprungen.
    /// Leere `projects` = alle Projekte; sonst Reihenfolge nach Position in
    /// `projects`, innerhalb eines Projekts wie geliefert.
    public static func versions(from data: Data, projects: [String]) -> [KIVersionRing]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["versions"] as? [Any] else { return nil }
        var rings: [KIVersionRing] = []
        for item in list {
            guard let dict = item as? [String: Any], let ring = ring(from: dict) else { continue }
            if !projects.isEmpty && !projects.contains(ring.project) { continue }
            rings.append(ring)
        }
        guard !projects.isEmpty else { return rings }
        // Stabil sortieren: Projektposition, dann Lieferreihenfolge.
        let indexed = rings.enumerated().map { (offset: $0.offset, ring: $0.element) }
        return indexed.sorted { a, b in
            let pa = projects.firstIndex(of: a.ring.project) ?? Int.max
            let pb = projects.firstIndex(of: b.ring.project) ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map { $0.ring }
    }

    /// Liest {"error": "..."} aus einer Fehlerantwort.
    public static func errorMessage(from data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = root["error"] as? String, !message.isEmpty else { return nil }
        return message
    }

    private static func ring(from dict: [String: Any]) -> KIVersionRing? {
        guard let id = nonEmptyString(dict["id"]),
              let project = nonEmptyString(dict["project"]),
              let label = nonEmptyString(dict["label"]),
              let total = number(dict["total"]) else { return nil }
        var areas: [KIAreaCount] = []
        if let areaDict = dict["areas"] as? [String: Any] {
            for area in KIVersionArea.allCases {
                guard let entry = areaDict[area.rawValue] else { continue }
                // Ein vorhandener, aber kaputter Bereich macht den Eintrag unbrauchbar.
                guard let e = entry as? [String: Any], let count = number(e["count"]) else { return nil }
                areas.append(KIAreaCount(area: area, count: count))
            }
        }
        var scorePercent: Int?
        if let score = dict["score"] as? [String: Any] { scorePercent = number(score["percent"]) }
        return KIVersionRing(
            id: id, project: project, name: nonEmptyString(dict["name"]) ?? label, label: label,
            releaseDate: nonEmptyString(dict["releaseDate"]),
            released: bool(dict["released"]) ?? false,
            total: total, areas: areas, scorePercent: scorePercent)
    }

    /// Strings; ganze Zahlen werden als Text akzeptiert (Jira-IDs kommen mal so, mal so).
    private static func nonEmptyString(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = number(value) { return String(n) }
        return nil
    }

    /// Int und ganzzahlige Double, nie Bool, nie negativ.
    private static func number(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d == d.rounded(), d < 1e15 else { return nil }
        return Int(d)
    }

    /// Nur echtes JSON-Bool, nie 0 oder 1 als Zahl (Darwin bruecken sie sonst zu Bool).
    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}
