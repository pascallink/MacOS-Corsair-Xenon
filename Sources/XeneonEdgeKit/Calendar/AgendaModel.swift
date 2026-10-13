// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Modell der Termin-Warnungen, geteilt von Dashboard-App und Menueleisten-Widget.

import Combine
import Foundation

/// Haelt die Termin-Warnungen fuer das Panel "Termine". Die Logik (Parser,
/// Expander, Auswahl, Stufen) liegt komplett in XeneonEdgeKit; hier nur
/// Timer, Abruf und Veroeffentlichung.
///
/// Drei Timer: der Poll-Timer holt den Feed (`pollSeconds`), der Tick-Timer
/// (1 s) laeuft nur, solange mindestens eine Warnung sichtbar ist, der
/// One-Shot-Timer `entryTimer` feuert, wenn der naechste Termin in den
/// Vorlauf rueckt (dann wird er zur Warnung). Ohne gueltige Konfiguration laeuft gar kein Timer und es entsteht kein Request.
public final class AgendaModel: ObservableObject {
    @Published public private(set) var reminders: [CalendarReminder] = []
    @Published public private(set) var overflow = 0
    @Published public private(set) var isStale = false
    @Published public private(set) var showEventTitles = true
    /// Ob ein Feed eingerichtet ist; das Panel zeigt sonst einen Hinweis
    /// statt "keine Termine".
    @Published public private(set) var isConfigured = false
    /// Vorlauf in Minuten, nur fuer den Leertext des Panels.
    @Published public private(set) var leadMinutes: Double = 60
    /// Naechster Termin hinter dem Vorlauf; nil bei ausgeschaltetem
    /// `showNextEvent`, ohne Konfiguration oder ohne Termin im Horizont.
    @Published public private(set) var next: CalendarEvent?
    /// Horizont der Suche in Tagen, nur fuer den Leertext der Views.
    @Published public private(set) var nextHorizonDays: Double = 7
    @Published public private(set) var showNextEvent = true

    private var config = CalendarConfig()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var entryTimer: Timer?
    private var entryDate: Date?
    private var events: [CalendarEvent] = []
    private var expanded: [CalendarEvent] = []
    private var etag: String?
    private var lastModified: String?
    private var failures = 0
    /// Testdatei (nur DEBUG) des laufenden Stands, Teil des Vergleichs in start().
    private var runningSource = ""
    /// Verwirft Ergebnisse alter Abrufe nach stop() oder erneutem start().
    private var generation = 0

    private enum Outcome {
        case notModified
        case parsed([CalendarEvent], etag: String?, lastModified: String?)
        case failure
    }

    #if DEBUG
    /// Nur Debug-Builds: lokale ICS-Datei statt Feed (Scripts/sample-calendar.sh).
    private static var debugFilePath: String? {
        let path = ProcessInfo.processInfo.environment["XENEON_CALENDAR_ICS_FILE"] ?? ""
        return path.isEmpty ? nil : path
    }
    #endif

    /// Idempotent im Sinn von "gleicher Stand, kein Neustart": laeuft das
    /// Modell bereits und ist die Konfiguration (unter DEBUG samt Testdatei)
    /// unveraendert, kehrt der Aufruf sofort zurueck - sonst wuerde jedes
    /// Widget-Umschalten einen Abruf ausloesen und ETag, Fehlerzaehler und
    /// Anzeige zuruecksetzen. Bei geaenderter Konfiguration oder nicht
    /// laufendem Modell werden zuerst alle Timer abgeraeumt, dann neu gestartet.
    public init() {}

    public func start() {
        let loaded = CalendarConfig.load()
        var source = ""
        #if DEBUG
        source = Self.debugFilePath ?? ""
        #endif
        if pollTimer != nil, loaded == config, source == runningSource { return }
        runningSource = source
        invalidateTimers()
        generation += 1
        config = loaded
        showEventTitles = config.showEventTitles
        leadMinutes = config.leadMinutes
        nextHorizonDays = config.nextHorizonDays
        showNextEvent = config.showNextEvent
        events = []
        expanded = []
        etag = nil
        lastModified = nil
        failures = 0
        isStale = false
        reminders = []
        overflow = 0
        next = nil

        var configured = config.isConfigured
        #if DEBUG
        if Self.debugFilePath != nil { configured = true }
        #endif
        isConfigured = configured
        guard configured else { return }

        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        invalidateTimers()
        generation += 1
        events = []
        expanded = []
        etag = nil
        lastModified = nil
        failures = 0
        reminders = []
        overflow = 0
        next = nil
        isStale = false
        isConfigured = false
    }

    private func invalidateTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        cancelEntryTimer()
    }

    private func poll() {
        let gen = generation
        let config = self.config
        let etag = self.etag
        let lastModified = self.lastModified
        Task { [weak self] in
            // Abruf und Parsing laufen im Hintergrund, nur die Zuweisung
            // an die Published-Felder auf dem Main-Thread.
            let outcome = await Self.load(config: config, etag: etag, lastModified: lastModified)
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                self.apply(outcome)
            }
        }
    }

    private static func load(config: CalendarConfig, etag: String?,
                             lastModified: String?) async -> Outcome {
        #if DEBUG
        if let path = debugFilePath {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8)
            else { return .failure }
            return .parsed(ICSParser.parse(text), etag: nil, lastModified: nil)
        }
        #endif
        let result = await CalendarFeedFetcher.fetch(urlString: config.feedURL,
                                                     etag: etag, lastModified: lastModified)
        switch result {
        case .notModified:
            return .notModified
        case .success(let text, let etag, let lastModified):
            return .parsed(ICSParser.parse(text), etag: etag, lastModified: lastModified)
        case .failure:
            return .failure
        }
    }

    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .notModified:
            failures = 0
            isStale = false
        case .parsed(let parsed, let newETag, let newLastModified):
            events = parsed
            etag = newETag
            lastModified = newLastModified
            failures = 0
            isStale = false
        case .failure:
            failures += 1
            if failures >= 3 { isStale = true }
        }

        // Nach jedem Poll neu expandieren, auch bei .notModified. Der
        // Horizont reicht ueber den Vorlauf hinaus (mindestens 15 min bzw.
        // ein Poll-Intervall), damit Termine, die zwischen zwei Polls in den
        // Vorlauf wandern, im Bestand sind.
        let now = Date()
        let from = now.addingTimeInterval(-config.graceMinutes * 60)
        var reach = config.leadMinutes * 60 + max(15 * 60, config.pollSeconds)
        if config.showNextEvent { reach = max(reach, config.nextHorizonDays * 86400) }
        expanded = RecurrenceExpander.expand(events, in: from..<now.addingTimeInterval(reach))
        refreshSelection()
    }

    private func refreshSelection() {
        let selection = UpcomingReminders.select(events: expanded, now: Date(),
                                                 options: config.reminderOptions)
        reminders = selection.reminders
        overflow = selection.overflow
        updateTick()
        updateNext(now: Date())
    }

    /// Bestimmt `next` neu (nur Zuweisung bei Aenderung) und plant den
    /// Eintritts-Timer auf `next.start - Vorlauf`.
    private func updateNext(now: Date) {
        let found = config.showNextEvent
            ? UpcomingReminders.next(events: expanded, now: now, options: config.reminderOptions)
            : nil
        if found != next { next = found }
        guard let found else {
            cancelEntryTimer()
            return
        }
        let entry = found.start.addingTimeInterval(-config.leadMinutes * 60)
        if entry <= now {
            // Schon im Vorlauf: sofort neu auswaehlen statt Timer.
            cancelEntryTimer()
            refreshSelection()
            return
        }
        if entryDate == entry, entryTimer != nil { return }
        cancelEntryTimer()
        entryDate = entry
        let timer = Timer(fire: entry, interval: 0, repeats: false) { [weak self] _ in
            self?.entryTimer = nil
            self?.entryDate = nil
            self?.refreshSelection()
        }
        RunLoop.main.add(timer, forMode: .common)
        entryTimer = timer
    }

    private func cancelEntryTimer() {
        entryTimer?.invalidate()
        entryTimer = nil
        entryDate = nil
    }

    /// Der Tick laeuft nur, solange mindestens eine Warnung sichtbar ist.
    private func updateTick() {
        if reminders.isEmpty {
            tickTimer?.invalidate()
            tickTimer = nil
        } else if tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshSelection()
            }
        }
    }
}
