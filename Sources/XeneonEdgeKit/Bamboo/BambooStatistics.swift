// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reine Auswertung der Builds eines Plans - ohne Netz, ohne Uhr (now wird
// uebergeben), damit sie ohne Server testbar ist.

import Foundation

public enum BambooStatistics {
    /// Skala des Balkens fuer normale Plaene (1 h) und Extended (3 h).
    public static let normalScale: TimeInterval = 3600
    public static let extendedScale: TimeInterval = 10800

    /// Toleranz fuer Uhrenversatz zwischen Server und Mac.
    private static let clockSkew: TimeInterval = 60

    /// Wertet die Builds im Fenster `now - windowDays ... now (+60 s)` aus.
    /// `windowDays < 1` zaehlt wie 1.
    public static func evaluate(plan: BambooPlan, builds: [BambooBuild], now: Date,
                                windowDays: Int) -> BambooPlanStats {
        let days = max(windowDays, 1)
        let from = now.addingTimeInterval(-Double(days) * 86400)
        let until = now.addingTimeInterval(clockSkew)
        let inWindow = builds.filter { $0.completedAt >= from && $0.completedAt <= until }

        let scale = plan.extended ? extendedScale : normalScale
        let success = inWindow.filter(\.successful).count
        let failed = inWindow.count - success

        guard !inWindow.isEmpty else {
            return BambooPlanStats(plan: plan, buildCount: 0, successCount: 0, failedCount: 0,
                                   averageDuration: nil, scaleMax: scale, fraction: 0,
                                   isCapped: false, successRate: nil)
        }

        let average = inWindow.reduce(0) { $0 + $1.duration } / Double(inWindow.count)
        return BambooPlanStats(plan: plan, buildCount: inWindow.count, successCount: success,
                               failedCount: failed, averageDuration: average, scaleMax: scale,
                               fraction: min(max(average / scale, 0), 1),
                               isCapped: average > scale,
                               successRate: Double(success) / Double(success + failed))
    }
}
