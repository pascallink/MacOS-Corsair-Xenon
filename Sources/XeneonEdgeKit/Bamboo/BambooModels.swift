// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Datenmodelle fuer das Bamboo-Laufzeiten-Panel: konfigurierter Plan, ein
// fertiger Build und die ausgewertete Statistik je Plan.

import Foundation

/// Ein Bamboo-Plan, wie er in der Konfiguration steht.
public struct BambooPlan: Codable, Equatable, Identifiable {
    /// Plan-Key, z. B. "DBREFI6-DBREF".
    public var key: String
    /// Anzeigename im Panel.
    public var name: String
    /// Langlaeufer (Extended): Skala des Balkens ist dann 3 h statt 1 h.
    public var extended: Bool

    public var id: String { key }

    public init(key: String, name: String? = nil, extended: Bool = false) {
        self.key = key
        self.name = name ?? key
        self.extended = extended
    }

    /// `key` ist Pflicht, `name` faellt auf den Key zurueck, `extended` auf
    /// false - handgeschriebene Eintraege in config.json bleiben knapp.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key
        extended = try c.decodeIfPresent(Bool.self, forKey: .extended) ?? false
    }

    public static let defaultPlans: [BambooPlan] = [
        BambooPlan(key: "DBREFI6-DBREF", name: "REFI"),
        BambooPlan(key: "DBREFI6-REFIEXT", name: "REFI Extended", extended: true),
        BambooPlan(key: "DMCUBE-DMCUB", name: "DMCube"),
        BambooPlan(key: "DMCUBE-DMCF", name: "DMCube Extended", extended: true),
    ]
}

/// Ein fertiger Build (erfolgreich oder fehlgeschlagen).
public struct BambooBuild: Equatable {
    public var completedAt: Date
    /// Laufzeit in Sekunden.
    public var duration: TimeInterval
    public var successful: Bool

    public init(completedAt: Date, duration: TimeInterval, successful: Bool) {
        self.completedAt = completedAt
        self.duration = duration
        self.successful = successful
    }
}

/// Ausgewertete Laufzeiten und Erfolgsquote eines Plans im Zeitfenster.
public struct BambooPlanStats: Equatable, Identifiable {
    public var plan: BambooPlan
    public var buildCount: Int
    public var successCount: Int
    public var failedCount: Int
    /// nil ohne Builds im Fenster.
    public var averageDuration: TimeInterval?
    /// Skala des Balkens in Sekunden (3600 normal, 10800 extended).
    public var scaleMax: TimeInterval
    /// average / scaleMax, auf 0...1 geklemmt; 0 ohne Builds.
    public var fraction: Double
    /// Durchschnitt liegt ueber der Skala (Balken ist gekappt).
    public var isCapped: Bool
    /// 0...1, nil ohne Builds.
    public var successRate: Double?
    /// Fehlertext, wenn der Abruf dieses Plans scheiterte.
    public var error: String?

    public var id: String { plan.key }

    public init(plan: BambooPlan, buildCount: Int, successCount: Int, failedCount: Int,
                averageDuration: TimeInterval?, scaleMax: TimeInterval, fraction: Double,
                isCapped: Bool, successRate: Double?, error: String? = nil) {
        self.plan = plan
        self.buildCount = buildCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.averageDuration = averageDuration
        self.scaleMax = scaleMax
        self.fraction = fraction
        self.isCapped = isCapped
        self.successRate = successRate
        self.error = error
    }
}

/// Stand aller Plaene fuer das Panel.
public struct BambooSnapshot: Equatable {
    public var plans: [BambooPlanStats]
    public var updatedAt: Date?
    /// Globaler Fehler, z. B. fehlender Token.
    public var error: String?

    public init(plans: [BambooPlanStats], updatedAt: Date? = nil, error: String? = nil) {
        self.plans = plans
        self.updatedAt = updatedAt
        self.error = error
    }

    public static let empty = BambooSnapshot(plans: [], updatedAt: nil, error: nil)
}
