// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Zeitplan fuer den Abruf der Versionsringe: reines Regelwerk ohne Timer und
// I/O. Der Lauf beim App-Start ist Sache der App, nicht dieses Regelwerks.

import Foundation

public struct KISlot: Equatable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public struct KIVersionsSchedule: Equatable {
    public var slots: [KISlot]
    public var calendar: Calendar

    public static let defaultSlots: [KISlot] = [
        KISlot(hour: 7, minute: 45), KISlot(hour: 9, minute: 45), KISlot(hour: 11, minute: 45),
        KISlot(hour: 13, minute: 45), KISlot(hour: 15, minute: 45), KISlot(hour: 17, minute: 45),
        KISlot(hour: 18, minute: 45),
    ]

    public init(slots: [KISlot] = KIVersionsSchedule.defaultSlots, calendar: Calendar = .current) {
        self.slots = slots
        self.calendar = calendar
    }

    /// Erster Slot streng nach `datum` an einem Werktag (Mo-Fr) in Ortszeit des
    /// Kalenders. Bei leeren Slots oder ohne Treffer in 8 Tagen: `datum` + 1 Stunde
    /// als Rueckfallwert, damit Aufrufer nie in einer Schleife haengen.
    public func naechsterLauf(nach datum: Date) -> Date {
        let sorted = slots.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        let startOfDay = calendar.startOfDay(for: datum)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard (2...6).contains(weekday) else { continue }
            for slot in sorted {
                guard let candidate = calendar.date(bySettingHour: slot.hour, minute: slot.minute,
                                                    second: 0, of: day),
                      candidate > datum else { continue }
                return candidate
            }
        }
        return datum.addingTimeInterval(3600)
    }
}
