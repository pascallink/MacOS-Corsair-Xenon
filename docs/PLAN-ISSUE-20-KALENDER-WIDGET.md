# Ausfuehrungsplan Issue #20 - Terminwarnung aus dem Google Kalender

Begleitdokument zu
[Issue #20](https://github.com/pascallink/MacOS-Corsair-Xenon/issues/20).
Das Issue traegt Kontext, Entscheidungen und Abnahmekriterien; hier stehen
die sieben Sub-Tasks als **einsatzbereite Stufe-0-Auftraege** nach der
Vorlage in [`.github/PROMPTS.md`](../.github/PROMPTS.md).

Jeder Block ist selbsttragend: das lokale Modell wie der `umsetzer` starten
kalt und sehen nur diesen Text, nicht den Rest dieser Datei. Was nicht im
Block steht, existiert fuer sie nicht.

## Kette je Sub-Task

1. Orchestrierende Opus-Sitzung zerlegt den Stufe-0-Block mit dem Skill
   `lokale-umsetzung` in drei bis fuenf Micro-Tasks a eine Datei.
2. Nach zwei Fehlversuchen am selben Micro-Task, bei einer Zieldatei ueber
   ~500 Zeilen oder bei mehr als einer Datei je Befund: Eskalation an den
   Subagenten `umsetzer`.
3. Jede Umsetzung endet verpflichtend mit dem Review-Prompt (Stufe 1) fuer
   Opus; danach 0 bis 2 Korrektur-Prompts (Stufe 2), je Prompt genau eine
   Zieldatei.
4. Local First: jeder Agent committet lokal, Push nur nach Freigabe durch
   Pascal.

## Reihenfolge (Stacked PRs)

| # | Branch | Scope | Ergebnis |
| --- | --- | --- | --- |
| 1 | `feature/issue-20-part-1` (Base `develop`) | `kit` | ICS-Parser und Terminmodell |
| 2 | `feature/issue-20-part-2` (Base part-1) | `kit` | Serientermine expandieren |
| 3 | `feature/issue-20-part-3` (Base part-2) | `kit` | Auswahl und Eskalationsstufe |
| 4 | `feature/issue-20-part-4` (Base part-3) | `kit` | Feed-Abruf und Konfiguration |
| 5 | `feature/issue-20-part-5` (Base part-4) | `app` | Panel im Dashboard |
| 6 | `feature/issue-20-part-6` (Base part-5) | `widget` | Karte im Menueleisten-Widget, AgendaModel ins Kit |
| 7 | `feature/issue-20-part-7` (Base part-6) | `repo` | Doku |

Sub-Task 1 bis 4 bauen die komplette Logik in `XeneonEdgeKit` auf, ohne dass
sich an der Oberflaeche etwas aendert - jede Zwischenstufe kompiliert und ist
testbar. Erst 5 und 6 schalten die Anzeige frei.

**Abweichung vom Issue:** je Suite eine eigene Testdatei
(`CalendarICSTests.swift`, `CalendarRecurrenceTests.swift`,
`CalendarReminderTests.swift`, `CalendarFeedTests.swift`) statt einer
gemeinsamen `CalendarTests.swift`. Ein Micro-Task fasst genau eine Datei an;
eine geteilte Testdatei waere ueber vier Sub-Tasks hinweg der staendige
Konfliktpunkt.

## Eskalation vorab bekannt

`Sources/XeneonEdgeApp/DashboardView.swift` hat 799 Zeilen (Stand develop
`dffba8a`) und liegt damit
ueber der Eignungsgrenze des lokalen Modells. Der Micro-Task fuer diese
Datei in Sub-Task 5 geht nach `CLAUDE.md` **direkt an den `umsetzer`**, ohne
lokalen Versuch. Deshalb liegt das Panel in einer eigenen Datei
(`AgendaPanel.swift`) - in `DashboardView.swift` bleiben zwei Einfuegungen.

---

## Sub-Task 1 - ICS-Parser und Terminmodell

* **Scope:** `kit` - **Branch:** `feature/issue-20-part-1` (Base `develop`)
* **Zu erstellen:** `Sources/XeneonEdgeKit/Calendar/CalendarModels.swift`,
  `Sources/XeneonEdgeKit/Calendar/ICSParser.swift`,
  `Tests/XeneonEdgeKitTests/CalendarICSTests.swift`
* **Definition of Done:** Parser ist rein und synchron, greift weder auf
  Netz noch auf das Dateisystem zu; alle vier `DTSTART`-Formen und
  `DURATION` werden korrekt aufgeloest; kaputte Eingabe liefert ein leeres
  Ergebnis statt eines Crashs.

```
task: implement_subtask
branch: feature/issue-20-part-1
base_branch: develop
target: XeneonEdgeKit
suite: ICSParserTests

Ziel: XeneonEdgeKit kann einen iCalendar-Feed (ICS) zu Terminobjekten
parsen. Bisher existiert kein Kalendercode im Paket. Nach dieser Aenderung
liefert eine reine Funktion aus einem ICS-Text eine Liste von Terminen mit
aufgeloester Start- und Endzeit.

Dateiebene:
- Zu erstellen: Sources/XeneonEdgeKit/Calendar/CalendarModels.swift, Sources/XeneonEdgeKit/Calendar/ICSParser.swift, Tests/XeneonEdgeKitTests/CalendarICSTests.swift
- Zu aendern: -

Aufgaben:
1. In CalendarModels.swift den oeffentlichen Typ `CalendarEvent`
   (Equatable, Identifiable) anlegen mit: `uid: String`, `title: String`,
   `location: String?`, `start: Date`, `end: Date`, `isAllDay: Bool`,
   `status: String?`, `recurrenceID: Date?`. Dazu das Enum
   `CalendarEventStatus` nicht anlegen - `status` bleibt der rohe Wert aus
   dem Feed (z. B. "CONFIRMED", "CANCELLED"), per `uppercased()`
   normalisiert. `id` ist berechnet und muss je Serieninstanz eindeutig
   sein: `uid` plus Startzeitpunkt (`timeIntervalSince1970`), getrennt
   durch "|" - die `uid` allein wiederholt sich bei Serien ab Sub-Task 2.
2. In ICSParser.swift `public enum ICSParser` (caseless, wie
   `BitbucketResponseParser`) mit der Funktion
   `public static func parse(_ text: String, defaultTimeZone: TimeZone = .current) -> [CalendarEvent]`
   anlegen. Sie ist rein und synchron, ohne Netz- und Dateizugriff - gleiche
   Bauform wie `CloudUsageFetcher.parseGistResponse` in
   Sources/XeneonEdgeKit/ClaudeUsage/CloudUsageFetcher.swift.
3. Als ersten Schritt im Parser die Zeilen entfalten (Unfolding): eine Zeile,
   die mit Leerzeichen oder Tabulator beginnt, gehoert an die vorherige
   angehaengt, ohne dieses erste Zeichen. Erst danach wird in
   Name/Parameter/Wert getrennt. CRLF und LF muessen beide funktionieren.
   Eigenschaftsnamen und Parameternamen sind case-insensitiv. Name und
   Wert trennt der erste Doppelpunkt ausserhalb doppelter Anfuehrungszeichen
   (`ATTENDEE;CN="Doe: John":mailto:...`); Parameterwerte in
   Anfuehrungszeichen werden ohne die Zeichen gelesen
   (`TZID="Europe/Berlin"`).
4. Nur Bloecke zwischen BEGIN:VEVENT und END:VEVENT auswerten. Ein
   BEGIN:VTIMEZONE-Block wird bis zu seinem END:VTIMEZONE vollstaendig
   uebersprungen, auch wenn er VEVENT-aehnliche Zeilen enthaelt.
   Verschachtelte Komponenten innerhalb eines VEVENT (vor allem VALARM)
   werden ebenfalls bis zu ihrem END uebersprungen: VALARM traegt eigene
   DURATION-, DESCRIPTION- und SUMMARY-Zeilen, die sonst die Werte des
   Termins ueberschreiben.
5. Werte von SUMMARY und LOCATION entmaskieren: `\n` und `\N` werden zum
   Zeilenumbruch, `\,` zum Komma, `\;` zum Semikolon, `\\` zum
   Backslash.
6. DTSTART und DTEND in vier Formen aufloesen:
   - `DTSTART:20260919T143000Z` -> UTC.
   - `DTSTART;TZID=Europe/Berlin:20260919T143000` -> Zone ueber
     `TimeZone(identifier:)`. Ist die Zone unbekannt, `defaultTimeZone`
     verwenden und genau eine NSLog-Zeile schreiben, den Termin aber
     behalten.
   - `DTSTART:20260919T143000` ohne Zone -> `defaultTimeZone`.
   - `DTSTART;VALUE=DATE:20260919` -> `isAllDay = true`, Start auf
     Mitternacht in `defaultTimeZone`. DTEND;VALUE=DATE ist exklusiv (der
     Folgetag bei einem eintaegigen Termin) und wird unveraendert als
     Mitternacht dieses Tages uebernommen.
   Die Umrechnung laeuft ueber einen gregorianischen `Calendar` mit
   gesetzter `timeZone` und `DateComponents`, nicht ueber einen
   `DateFormatter` mit Geraete-Locale. Ungueltige Ziffernfolgen (falsche
   Laenge, Monat 13) ergeben nil, kein Crash.
7. Fehlt DTEND, aber DURATION ist gesetzt (Form `PT1H30M`, `PT45M`, `P1D`,
   auch `P1W`, `P1DT2H`, `PT30S`), das Ende aus Start plus Dauer berechnen;
   Tage und Wochen ueber `Calendar.date(byAdding:)` in der Zone des Starts,
   damit ein Tag ueber die Zeitumstellung ein Kalendertag bleibt. Eine
   unlesbare DURATION zaehlt wie eine fehlende. Fehlen beide, Ende gleich
   Start; bei VALUE=DATE ohne DTEND und DURATION Ende = Start plus ein Tag.
8. Ein VEVENT ohne verwertbares DTSTART wird uebersprungen, nicht als
   Platzhalter aufgenommen. RECURRENCE-ID wird wie ein DTSTART aufgeloest
   und in `recurrenceID` abgelegt.
9. In CalendarICSTests.swift die Suite `ICSParserTests` anlegen (import
   Testing, `@Suite struct`, `@Test func`, `#expect`), mit je einem Test fuer:
   gefaltete SUMMARY-Zeile bleibt zusammenhaengend; maskiertes Komma; jede
   der vier DTSTART-Formen; DURATION ohne DTEND; VALUE=DATE setzt isAllDay;
   unbekannte TZID faellt auf defaultTimeZone zurueck ohne den Termin zu
   verlieren; Text ohne VEVENT ergibt ein leeres Array; abgeschnittener
   VEVENT-Block ohne END ergibt ein leeres Array; ein VALARM mit DURATION
   veraendert das Ende des Termins nicht; CRLF-Eingabe ergibt dasselbe wie
   LF; RECURRENCE-ID landet in `recurrenceID`. Zeitpunkte in den Tests
   gegen feste Werte pruefen (`Date(timeIntervalSince1970:)` oder ueber
   einen Calendar mit fester Zone), `defaultTimeZone` in jedem Test
   explizit uebergeben - nie von der Zone des Testrechners abhaengen.

Definition of Done:
- [ ] `ICSParser.parse` ist rein: kein URLSession-, kein FileManager-Zugriff.
- [ ] Alle vier DTSTART-Formen und DURATION ergeben die erwarteten Zeitpunkte.
- [ ] Unvollstaendige oder kaputte Eingabe liefert ein leeres Array, nie einen Crash.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-1 develop`
  und `git checkout feature/issue-20-part-1`. Existiert der Branch noch
  nicht, mit `git checkout -b feature/issue-20-part-1 origin/develop`
  anlegen. Kein anderer Branch, Commit lokal - Push nur nach Freigabe durch
  Pascal (Local First, Root-`CLAUDE.md`).
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Neue Dateien nirgends registrieren - SwiftPM sammelt Sources/<Target>/
  selbst ein.
- Waehrend der Arbeit nur `./Scripts/test.sh --filter ICSParserTests`.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Sub-Task 2 - Serientermine expandieren

* **Scope:** `kit` - **Branch:** `feature/issue-20-part-2` (Base part-1)
* **Zu erstellen:** `Sources/XeneonEdgeKit/Calendar/RecurrenceExpander.swift`,
  `Tests/XeneonEdgeKitTests/CalendarRecurrenceTests.swift`
* **Zu aendern:** `Sources/XeneonEdgeKit/Calendar/CalendarModels.swift`,
  `Sources/XeneonEdgeKit/Calendar/ICSParser.swift`
* **Definition of Done:** Eine Serie ohne `UNTIL` erzeugt genau die
  Instanzen im angefragten Fenster und laeuft nie unbegrenzt; `EXDATE`
  entfernt, `RECURRENCE-ID` ersetzt.

```
task: implement_subtask
branch: feature/issue-20-part-2
base_branch: feature/issue-20-part-1
target: XeneonEdgeKit
suite: RecurrenceExpanderTests

Ziel: Serientermine aus einem ICS-Feed werden zu konkreten Einzelterminen
im angefragten Zeitraum aufgeloest. Bisher liefert der Parser nur die
Serien-Startinstanz, ein woechentliches Meeting taucht deshalb nur einmal
auf. Nach dieser Aenderung liefert der Expander alle Instanzen im Fenster,
abzueglich Ausnahmen.

Dateiebene:
- Zu erstellen: Sources/XeneonEdgeKit/Calendar/RecurrenceExpander.swift, Tests/XeneonEdgeKitTests/CalendarRecurrenceTests.swift
- Zu aendern: Sources/XeneonEdgeKit/Calendar/CalendarModels.swift, Sources/XeneonEdgeKit/Calendar/ICSParser.swift

Aufgaben:
1. In CalendarModels.swift den Typ `RecurrenceRule` (Equatable, Sendable)
   ergaenzen mit: `frequency` (Enum `.daily`, `.weekly`, `.monthly`,
   `.yearly`), `interval: Int = 1`, `count: Int?`, `until: Date?`,
   `byDay: [WeekdayRule]`, `byMonthDay: [Int]`, `byMonth: [Int]`.
   `WeekdayRule` hat `weekday: Int` (1 = Sonntag bis 7 = Samstag, wie
   Calendar.component) und `ordinal: Int?` (`2TU` -> 2, `-1FR` -> -1,
   `MO` -> nil) - ohne die Ordinalzahl wuerde Googles "jeden 2. Dienstag"
   zu "jeden Dienstag". `CalendarEvent` bekommt zusaetzlich
   `recurrence: RecurrenceRule?`, `exceptionDates: [Date]` und
   `timeZone: TimeZone?` (Zone des DTSTART: UTC bei `Z`, die TZID-Zone,
   sonst `defaultTimeZone`). Alle drei als Parameter mit Default (`nil`,
   `[]`, `nil`) am Ende des bestehenden `init` - bestehende Aufrufe und
   Tests aus Sub-Task 1 bleiben unveraendert gueltig.
2. In ICSParser.swift RRULE und EXDATE einlesen. UNTIL wie DTSTART
   aufloesen (bestehende `resolve`-Logik wiederverwenden); ein reines Datum
   als UNTIL gilt bis zum Ende dieses Tages. EXDATE kann mehrfach vorkommen
   und je Zeile mehrere Werte durch Komma getrennt tragen, mit eigener
   TZID oder VALUE=DATE - alle Werte sammeln. Harmlose unbekannte Teile
   (WKST) werden ignoriert. Teile, die die Menge einschraenken und hier
   nicht ausgewertet werden (BYSETPOS, BYWEEKNO, BYYEARDAY, BYHOUR,
   BYMINUTE, BYSECOND), ergeben `recurrence = nil`: der Termin bleibt als
   Einzeltermin erhalten, statt Phantom-Instanzen zu erzeugen. Ebenso ein
   unbekanntes FREQ, ein INTERVAL < 1 und ein BYDAY mit Ordinalzahl bei
   FREQ=WEEKLY oder DAILY.
3. In RecurrenceExpander.swift `public enum RecurrenceExpander` mit
   `public static func expand(_ events: [CalendarEvent], in range: Range<Date>, calendar: Calendar = .current) -> [CalendarEvent]`
   anlegen. Sie liefert ausschliesslich Instanzen, deren Start in `range`
   liegt, sortiert nach Start. Je Serie rechnet sie in
   `event.timeZone ?? calendar.timeZone` (Kopie des uebergebenen Calendar
   mit dieser Zone), damit die Ortszeit der Serie gilt, nicht die des Macs.
   Termine ohne `recurrence` werden durchgereicht, wenn ihr Start in
   `range` liegt.
4. Die Expansion laeuft ueber Kalenderkomponenten, nicht ueber Addition
   fester Sekundenbetraege - sonst verschiebt sich die Ortszeit beim
   Wechsel zwischen Sommer- und Winterzeit. Je Periode (Tag, Woche, Monat,
   Jahr ab DTSTART, im Abstand `interval`) werden die Kandidaten erzeugt:
   - WEEKLY ohne BYDAY: Wochentag des DTSTART; mit BYDAY: jeder genannte
     Wochentag dieser Woche (Wochenbeginn Montag).
   - MONTHLY ohne BYDAY/BYMONTHDAY: Tag des DTSTART; ein Monat ohne diesen
     Tag (31. im April) wird uebersprungen, nicht auf den 30. geklemmt.
     BYMONTHDAY negativ zaehlt vom Monatsende (-1 = letzter Tag). BYDAY mit
     Ordinalzahl = n-ter bzw. vom Ende gezaehlter Wochentag im Monat, ohne
     Ordinalzahl jeder dieser Wochentage im Monat.
   - YEARLY: Datum des DTSTART, mit BYMONTH je genanntem Monat; Kombination
     mit BYDAY wie MONTHLY innerhalb jedes Monats.
   - DAILY: mit BYDAY/BYMONTH/BYMONTHDAY als Filter.
   Uhrzeit immer die des DTSTART. Kandidaten vor DTSTART zaehlen nicht.
   Dauer jeder Instanz = Dauer des Mastertermins (bei Ganztag in
   Kalendertagen).
5. Abbruch, sobald der Kandidat hinter `range.upperBound` oder hinter
   `until` liegt, oder wenn `count` erreicht ist (COUNT zaehlt ab DTSTART,
   auch Instanzen vor dem Fenster). Ohne COUNT darf die Schleife vor dem
   ersten Durchlauf direkt zur Periode kurz vor `range.lowerBound`
   vorspringen (Zahl der Perioden ueber `calendar.dateComponents` berechnen
   und auf ein Vielfaches von `interval` abrunden) - eine taegliche Serie
   seit drei Jahren erreicht sonst nie das Fenster. Danach eine harte
   Obergrenze von 1000 Perioden je Serie; mit COUNT ohne Vorsprung eine
   Obergrenze von 10000 Perioden. Beides verhindert Endlosschleifen bei
   kaputten Regeln.
6. Instanzen, deren Start in `exceptionDates` steht, werden entfernt.
7. Ein Termin mit gesetzter `recurrenceID` ist eine Ausnahme: er
   unterdrueckt die generierte Instanz derselben `uid`, deren Start gleich
   seiner `recurrenceID` ist - auch wenn er selbst ausserhalb von `range`
   verschoben wurde. Er selbst erscheint, wenn sein eigener Start in
   `range` liegt. Generierte Instanzen tragen `recurrence = nil`,
   `recurrenceID = nil` und dieselbe `uid`; ihre `id` unterscheidet sich
   ueber den Start.
8. In CalendarRecurrenceTests.swift die Suite `RecurrenceExpanderTests`
   anlegen, mit je einem Test fuer: FREQ=WEEKLY;BYDAY=MO,WE trifft nur
   Montag und Mittwoch; INTERVAL=2 ueberspringt jede zweite Woche; COUNT=3
   endet nach drei Instanzen; UNTIL in der Vergangenheit liefert nichts;
   EXDATE mit zwei Werten in einer Zeile entfernt genau diese zwei
   Instanzen; RECURRENCE-ID ersetzt statt zu verdoppeln; RECURRENCE-ID mit
   Verschiebung aus dem Fenster heraus unterdrueckt die Instanz; eine Serie
   ohne UNTIL und COUNT liefert im Zwei-Stunden-Fenster genau die
   Instanzen darin; eine taegliche Serie mit DTSTART vor drei Jahren
   liefert heute ihre Instanz; eine taegliche Serie ueber die
   Zeitumstellung behaelt ihre Ortszeit; MONTHLY;BYDAY=2TU trifft nur den
   zweiten Dienstag; MONTHLY am 31. ueberspringt Monate ohne 31.; BYSETPOS
   ergibt einen Einzeltermin. Parser-Tests fuer RRULE/EXDATE gehoeren
   ebenfalls in diese Suite. Alle Daten mit fester Zone, keine
   Abhaengigkeit von der Zone des Testrechners.

Definition of Done:
- [ ] Serie ohne Ende bleibt im Fenster begrenzt, keine Endlosschleife.
- [ ] EXDATE entfernt, RECURRENCE-ID ersetzt.
- [ ] Ortszeit bleibt ueber die Zeitumstellung stabil.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git checkout feature/issue-20-part-2`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-2 feature/issue-20-part-1` anlegen (part-1 ist
  bis zur Freigabe nur lokal). Kein anderer Branch, Commit lokal - Push
  nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Bestehende Signaturen aus Sub-Task 1 nicht brechen; `ICSParser.parse`
  behaelt Name und Parameter, der `CalendarEvent`-init bleibt mit den
  bisherigen Argumenten aufrufbar.
- Waehrend der Arbeit nur `./Scripts/test.sh --filter RecurrenceExpanderTests`.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Sub-Task 3 - Auswahl und Eskalationsstufe

* **Scope:** `kit` - **Branch:** `feature/issue-20-part-3` (Base part-2)
* **Zu erstellen:** `Sources/XeneonEdgeKit/Calendar/CalendarReminder.swift`,
  `Tests/XeneonEdgeKitTests/CalendarReminderTests.swift`
* **Zu aendern:** `Sources/XeneonEdgeKit/Calendar/CalendarModels.swift`,
  `Sources/XeneonEdgeKit/Calendar/ICSParser.swift`,
  `Sources/XeneonEdgeKit/Calendar/RecurrenceExpander.swift` (nur
  `declinedBy` durchreichen)
* **Definition of Done:** Die Auswahl ist vollstaendig ueber ein
  injiziertes `now` steuerbar; jede Stufengrenze ist sekundengenau
  getestet.

```
task: implement_subtask
branch: feature/issue-20-part-3
base_branch: feature/issue-20-part-2
target: XeneonEdgeKit
suite: CalendarReminderTests

Ziel: Aus einer Terminliste werden die anzuzeigenden Warnungen samt
Eskalationsstufe bestimmt. Bisher gibt es nur Termine ohne Bewertung. Nach
dieser Aenderung liefert eine reine Funktion hoechstens zwei Warnungen mit
Restzeit, Stufe und Fortschritt, plus die Zahl der weiteren Termine im
Fenster.

Dateiebene:
- Zu erstellen: Sources/XeneonEdgeKit/Calendar/CalendarReminder.swift, Tests/XeneonEdgeKitTests/CalendarReminderTests.swift
- Zu aendern: Sources/XeneonEdgeKit/Calendar/CalendarModels.swift, Sources/XeneonEdgeKit/Calendar/ICSParser.swift, Sources/XeneonEdgeKit/Calendar/RecurrenceExpander.swift

Aufgaben:
1. Enum `ReminderStage` (Equatable, Sendable, CaseIterable) mit den Faellen `.hour`, `.halfHour`, `.quarter`,
   `.fiveMinutes`, `.imminent` und
   `public init(remaining: TimeInterval)`. Grenzen: ueber 1800 s -> .hour,
   ueber 900 s -> .halfHour, ueber 300 s -> .quarter, ueber 60 s ->
   .fiveMinutes, sonst .imminent. Die Kante gehoert damit jeweils zur
   ruhigeren Stufe: exakt 1800 s ergibt .halfHour, exakt 60 s ergibt
   .fiveMinutes. Eine negative Restzeit (Termin laeuft) ergibt .imminent.
2. Struct `CalendarReminder` (Equatable, Identifiable) mit `event:
   CalendarEvent`, `remaining: TimeInterval`, `stage: ReminderStage`,
   `progress: Double`, `Sendable`. `id` ist `event.id`. `progress` ist
   `1 - remaining / (leadMinutes * 60)`: 0 bei Restzeit gleich Vorlauf und
   1 bei Restzeit 0, immer auf 0...1 geklemmt; bei `leadMinutes <= 0` gilt
   1, nie eine Division durch 0.
3. Struct `ReminderOptions` mit `leadMinutes: Double = 60`,
   `graceMinutes: Double = 2`, `maxReminders: Int = 2`,
   `feedOwnerEmail: String = ""`, Equatable und Sendable. Dazu ein
   explizites `public init` mit allen vier Parametern samt Defaults - der
   synthetisierte memberwise-Init ist nur intern und waere aus App und
   Widget nicht aufrufbar.
4. `public enum UpcomingReminders` mit
   `static func select(events: [CalendarEvent], now: Date, options: ReminderOptions = .init()) -> (reminders: [CalendarReminder], overflow: Int)`.
   `now` wird immer uebergeben - kein `Date()` innerhalb der Auswahl, sonst
   ist sie nicht testbar. `events` ist die bereits expandierte Liste aus
   `RecurrenceExpander.expand`; die Funktion expandiert selbst nicht.
5. Auswahlregeln in dieser Reihenfolge: Termine mit `isAllDay == true`
   fallen raus; Termine mit `status == "CANCELLED"` fallen raus; abgesagte
   Termine nach Aufgabe 7 fallen raus; ein Termin zaehlt, wenn
   `now - graceMinutes*60 <= start <= now + leadMinutes*60` (beide Grenzen
   inklusive); doppelte Eintraege mit gleicher `id` zaehlen einmal;
   sortiert wird nach Startzeit, bei gleichem Start nach Titel, dann nach
   `uid`, damit die Reihenfolge stabil ist. Ein negatives `maxReminders`
   zaehlt wie 0.
6. Von den verbleibenden Terminen werden die ersten `maxReminders`
   zurueckgegeben, der Rest zaehlt in `overflow`.
7. Ist `feedOwnerEmail` nicht leer, fallen zusaetzlich Termine raus, die
   fuer genau diese Adresse `PARTSTAT=DECLINED` tragen. Dafuer:
   - In CalendarModels.swift `CalendarEvent` um
     `declinedBy: Set<String> = []` ergaenzen, als letzter init-Parameter
     mit Default - bestehende Aufrufe bleiben gueltig.
   - In ICSParser.swift jede ATTENDEE-Zeile mit Parameter
     `PARTSTAT=DECLINED` auswerten: Wert ohne fuehrendes `mailto:`
     (case-insensitiv), getrimmt und kleingeschrieben in `declinedBy`.
   - In RecurrenceExpander.swift `declinedBy` des Masters in jede
     generierte Instanz uebernehmen (eine RECURRENCE-ID-Ausnahme bringt
     ihre eigenen ATTENDEE-Zeilen mit).
   - Der Vergleich mit `feedOwnerEmail` ist case-insensitiv und getrimmt.
8. In CalendarReminderTests.swift die Suite `CalendarReminderTests` anlegen,
   mit je einem Test fuer: Ganztagstermin faellt raus; Termin in 61 Minuten
   ist nicht dabei, in 59 Minuten schon; drei passende Termine ergeben zwei
   Warnungen und overflow == 1; ein vor 1 Minute gestarteter Termin ist noch
   dabei, ein vor 3 Minuten gestarteter nicht mehr; CANCELLED faellt raus;
   je ein Test auf die Sekunde fuer 1800, 900, 300 und 60 Sekunden
   Restzeit, jeweils auch eine Sekunde darueber; negative Restzeit ergibt
   .imminent; progress ist 0 bei 3600 s und 1 bei 0 s Restzeit; ein fuer
   `feedOwnerEmail` abgesagter Termin faellt raus, bei leerer
   `feedOwnerEmail` bleibt er; gleicher Start sortiert nach Titel. Dazu in
   derselben Suite ein Parser-Test (ATTENDEE mit `PARTSTAT=DECLINED` und
   `MAILTO:` in Grossbuchstaben fuellt `declinedBy`) und ein Expander-Test
   (Instanzen einer Serie tragen `declinedBy` des Masters).

Definition of Done:
- [ ] Kein `Date()` in der Auswahl- oder Stufenlogik.
- [ ] Nie mehr als `maxReminders` Eintraege, der Rest steht in `overflow`.
- [ ] Ein fuer `feedOwnerEmail` abgesagter Termin erzeugt keine Warnung.
- [ ] Alle vier Stufengrenzen sekundengenau getestet.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git checkout feature/issue-20-part-3`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-3 feature/issue-20-part-2` anlegen (part-2 ist
  bis zur Freigabe nur lokal). Kein anderer Branch, Commit lokal - Push
  nur nach Freigabe durch Pascal.
- Bestehende Signaturen aus Sub-Task 1 und 2 nicht brechen; bestehende
  Tests in ICSParserTests und RecurrenceExpanderTests bleiben unveraendert
  gruen.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Keine Farben, keine SwiftUI-Typen in dieser Datei - die Zuordnung Stufe zu
  Farbe faellt in der jeweiligen Oberflaeche.
- Waehrend der Arbeit nur `./Scripts/test.sh --filter CalendarReminderTests`.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Sub-Task 4 - Feed-Abruf und Konfiguration

* **Scope:** `kit` - **Branch:** `feature/issue-20-part-4` (Base part-3)
* **Zu erstellen:** `Sources/XeneonEdgeKit/Calendar/CalendarFeedFetcher.swift`,
  `Sources/XeneonEdgeKit/Config/CalendarConfig.swift`,
  `Tests/XeneonEdgeKitTests/CalendarFeedTests.swift`
* **Definition of Done:** Kein Codepfad gibt die vollstaendige Feed-URL
  aus; ohne konfigurierte URL startet kein Request.

```
task: implement_subtask
branch: feature/issue-20-part-4
base_branch: feature/issue-20-part-3
target: XeneonEdgeKit
suite: CalendarFeedTests

Ziel: Der Kalender-Feed wird konfigurierbar und abrufbar. Bisher gibt es
Parser und Auswahl, aber keine Quelle. Nach dieser Aenderung liest
XeneonEdgeKit eine eigene calendar.json und laedt daraus den ICS-Feed per
HTTPS, ohne die geheime URL jemals zu protokollieren.

Dateiebene:
- Zu erstellen: Sources/XeneonEdgeKit/Calendar/CalendarFeedFetcher.swift, Sources/XeneonEdgeKit/Config/CalendarConfig.swift, Tests/XeneonEdgeKitTests/CalendarFeedTests.swift
- Zu aendern: -

Aufgaben:
1. CalendarConfig.swift nach dem Muster von
   Sources/XeneonEdgeKit/Config/AppConfig.swift anlegen: `public struct
   CalendarConfig: Codable, Equatable, Sendable` mit `enabled = false`,
   `feedURL = ""`, `leadMinutes: Double = 60`, `graceMinutes: Double = 2`,
   `maxReminders = 2`, `pollSeconds: Double = 300`,
   `showEventTitles = true`, `feedOwnerEmail = ""` und `public init()`.
2. Tolerantes `init(from:)` mit `decodeIfPresent` je Feld und Rueckfall auf
   den Default - exakt wie in AppConfig.swift, damit eine handgeschriebene
   Datei mit nur einem Schluessel gueltig bleibt. Beim Lesen klemmen:
   `pollSeconds` auf 60...3600, `leadMinutes` auf 5...240, `graceMinutes`
   auf 0...30, `maxReminders` auf 1...4. `feedURL` getrimmt.
3. Ablage in `~/Library/Application Support/XeneonEdge/calendar.json`
   (`AppConfig.directory` wiederverwenden), `public static var fileURL`.
   `public static func load(from url: URL = fileURL) -> CalendarConfig`
   und `public func save(to url: URL = fileURL) throws` - der Parameter
   macht beides ohne Zugriff auf das echte ~/Library testbar.
   - `load()` gibt bei fehlender oder kaputter Datei Defaults zurueck und
     schreibt keinen Inhalt. Die NSLog-Zeile bei kaputter Datei nennt nur
     "calendar.json nicht lesbar", nie `error` - ein DecodingError kann
     Teile des Inhalts zitieren. Sind an einer vorhandenen Datei Gruppen-
     oder Weltrechte gesetzt (von Hand angelegt, typisch 0644), setzt
     `load()` sie auf 0600 und schreibt dazu eine Logzeile ohne Inhalt.
   - `save()` legt das Verzeichnis an, schreibt eine Temp-Datei im selben
     Verzeichnis, die schon beim Anlegen 0600 hat
     (`FileManager.createFile(atPath:contents:attributes:
     [.posixPermissions: 0o600])`), und benennt sie per POSIX `rename`
     auf das Ziel um. `Data.write(.atomic)` mit nachgelagertem
     `setAttributes` reicht nicht: die Datei laege dazwischen mit 0644
     lesbar herum. Fehler werden geworfen, wie in AppConfig.save().
4. `isConfigured` liefert nur true, wenn `enabled` gesetzt ist und `feedURL`
   per `URL(string:)` eine URL mit Schema `https` und nicht-leerem Host
   ist. `public var reminderOptions: ReminderOptions` baut die Optionen fuer
   `UpcomingReminders.select` aus den Feldern.
5. CalendarFeedFetcher.swift, `public enum CalendarFeedFetcher`:
   `public static func redact(_ url: String) -> String` gibt hoechstens
   Schema und Host zurueck ("https://<host>"), nie Pfad, Query, Fragment,
   Port-Userinfo. Unparsbare Eingabe oder fehlender Host ergibt die
   Konstante "<ungueltige URL>", nie einen Teil der Eingabe. Jede Log- und
   Fehlermeldung im Modul geht ueber diese Funktion; Fehlerobjekte
   (`URLError`, `error`) werden nie interpoliert - sie tragen die volle
   URL in `NSErrorFailingURLStringKey`. Geloggt werden hoechstens
   `redact(url)`, HTTP-Status und `URLError.Code.rawValue`.
6. `public static func fetch(urlString: String, etag: String?, lastModified: String?, session: URLSession = CalendarFeedFetcher.session) async -> FeedResult`
   mit `FeedResult` (Equatable, Sendable) als Enum `.notModified`,
   `.success(text: String, etag: String?, lastModified: String?)`,
   `.failure`.
   - `CalendarFeedFetcher.session` ist eine eigene Session mit
     `URLSessionConfiguration.ephemeral`, `urlCache = nil` und
     `requestCachePolicy = .reloadIgnoringLocalCacheData` - die
     Standard-Session legt Antwort und URL sonst in Cache.db auf der
     Platte ab.
   - Nur https wird akzeptiert; bei anderem Schema kein Request,
     sofort `.failure`. Timeout 15 s. Header If-None-Match und
     If-Modified-Since werden gesetzt, wenn die Werte vorliegen.
   - HTTP 304 ergibt `.notModified`, 200 ergibt `.success`, alles andere
     `.failure`. Ist die finale `response.url` nach Weiterleitungen nicht
     https, `.failure`. Antworten ueber 20 MB ergeben `.failure`. Text als
     UTF-8, bei Fehlschlag ISO-Latin-1. ETag und Last-Modified aus den
     Antwort-Headern uebernehmen. Kein `throw` nach aussen, gleiche
     Haltung wie CloudUsageFetcher.fetch.
7. In CalendarFeedTests.swift die Suite `CalendarFeedTests` anlegen, mit je
   einem Test fuer: `redact` entfernt Pfad, Query und Userinfo
   vollstaendig (Google-Form
   `https://calendar.google.com/calendar/ical/x%40group/private-abc/basic.ics`);
   `redact` auf unparsbarer Eingabe gibt "<ungueltige URL>"; eine http-URL
   ergibt `isConfigured == false`; `enabled == false` ergibt false; Config
   ohne Schluessel dekodiert auf alle Defaults; Config mit nur einem
   Schluessel behaelt die uebrigen Defaults; pollSeconds 5 wird zu 60 und
   99999 zu 3600; maxReminders 9 wird zu 4; `save` in ein Temp-Verzeichnis
   ergibt Rechte 0600 und `load` liest denselben Wert zurueck; `load` auf
   einer Datei mit 0644 setzt 0600; `fetch` ueber einen URLProtocol-Stub
   (Muster: BitbucketStubProtocol in BitbucketClientTests.swift) liefert
   bei 200 `.success` mit ETag, bei 304 `.notModified`, bei 500
   `.failure`, sendet If-None-Match mit, und bei einer http-URL erreicht
   den Stub gar kein Request. Kein Test geht ins Netz oder nach ~/Library.

Definition of Done:
- [ ] Keine Logzeile und keine Fehlermeldung enthaelt Pfad oder Query der Feed-URL.
- [ ] calendar.json liegt zu keinem Zeitpunkt mit mehr als 0600 auf der Platte (ausser von Hand angelegt bis zum ersten load).
- [ ] Kein Abruf hinterlaesst Antwort oder URL im URL-Cache.
- [ ] Ohne `enabled` und gueltige https-URL wird kein Request gebaut.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git checkout feature/issue-20-part-4`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-4 feature/issue-20-part-3` anlegen (part-3 ist
  bis zur Freigabe nur lokal). Kein anderer Branch, Commit lokal - Push
  nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Kein Test darf eine echte Netzverbindung aufbauen.
- Die Feed-URL wird nie in einer Rueckgabe, einem Fehlertext oder einem Log
  ausgegeben.
- Waehrend der Arbeit nur `./Scripts/test.sh --filter CalendarFeedTests`.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Sub-Task 5 - Panel im Dashboard

* **Scope:** `app` - **Branch:** `feature/issue-20-part-5` (Base part-4)
* **Zu erstellen:** `Sources/XeneonEdgeApp/AgendaPanel.swift`,
  `Scripts/sample-calendar.sh`
* **Zu aendern:** `Sources/XeneonEdgeApp/Models.swift`,
  `Sources/XeneonEdgeApp/DashboardView.swift` (Eskalation: 799 Zeilen,
  direkt an den `umsetzer`), `Sources/XeneonEdgeApp/AppDelegate.swift`,
  `Sources/XeneonEdgeKit/Config/AppConfig.swift`
* **Definition of Done:** Panel laesst sich ueber das Menue ohne Neustart
  ein- und ausschalten; ohne Feed-URL bleibt es aus; kein Timer laeuft,
  solange keine Warnung sichtbar ist.

```
task: implement_subtask
branch: feature/issue-20-part-5
base_branch: feature/issue-20-part-4
target: XeneonEdgeApp
suite: -

Ziel: Das Dashboard auf dem Edge zeigt die naechsten Termine als eigenes
Panel mit Countdown und Farbeskalation. Bisher liegt die komplette Logik in
XeneonEdgeKit, ohne Anzeige. Nach dieser Aenderung erscheint das Panel
"Termine", sobald ein Termin innerhalb der Vorlaufzeit beginnt.

Dateiebene:
- Zu erstellen: Sources/XeneonEdgeApp/AgendaPanel.swift, Scripts/sample-calendar.sh
- Zu aendern: Sources/XeneonEdgeKit/Config/AppConfig.swift, Sources/XeneonEdgeApp/Models.swift, Sources/XeneonEdgeApp/DashboardView.swift, Sources/XeneonEdgeApp/AppDelegate.swift

Aufgaben:
1. In AppConfig.swift `public var showCalendar = false` ergaenzen, inklusive
   Zeile im toleranten `init(from:)` mit `decodeIfPresent` - genau nach dem
   Muster der benachbarten showX-Felder.
2. In DashboardView.swift dem Enum EdgeTheme zwei Farben hinzufuegen, mit
   exakt den Werten aus WidgetTheme in
   Sources/ClaudeUsageWidget/WidgetView.swift:
   `static let warn = Color(red: 0.95, green: 0.55, blue: 0.20)` und
   `static let critical = Color(red: 0.92, green: 0.30, blue: 0.30)`.
   Ausserdem in der mittleren Spalte (der VStack mit MediaPanel und
   ClaudeUsagePanel in `DashboardView.body`) als erste Zeile
   `if configStore.config.showCalendar { AgendaPanel() }` einfuegen - oben,
   weil eine Terminwarnung das Dringendste auf dem Edge ist - und die
   umschliessende Bedingung `if configStore.config.showMedia || ...` um
   `|| configStore.config.showCalendar` erweitern, sonst bleibt das Panel
   unsichtbar, wenn die anderen Panels der Spalte aus sind. In
   `DashboardView` `@EnvironmentObject var agenda: AgendaModel` ergaenzen,
   neben den anderen EnvironmentObjects. Sonst nichts an dieser Datei
   aendern.
3. In Models.swift die Klasse `AgendaModel: ObservableObject` ergaenzen,
   nach dem Muster von ClaudeUsageModel in derselben Datei:
   `@Published var reminders: [CalendarReminder]`,
   `@Published var overflow: Int`, `@Published var isStale: Bool`,
   `@Published var showEventTitles: Bool` (aus CalendarConfig).
   `start()` laedt die CalendarConfig neu und ist idempotent: ein erneuter
   Aufruf raeumt zuerst alle Timer ab und startet dann neu, er verdoppelt
   nie Timer. Ohne `isConfigured` startet `start()` keinen Timer und baut
   keinen Request. `stop()` raeumt alle Timer ab und leert die
   Published-Felder.
4. Zwei Timer: ein Poll-Timer mit `config.pollSeconds` holt den Feed ueber
   CalendarFeedFetcher (ETag und Last-Modified der letzten Antwort
   mitgeben; bei `.notModified` den gespeicherten Bestand weiterverwenden),
   parst mit ICSParser, expandiert mit
   RecurrenceExpander im Fenster `now - graceMinutes ... now + leadMinutes
   + 15 min` (sonst fehlt ein gerade begonnener Serientermin) und
   legt die geparsten (unexpandierten) Termine ab; nach jedem Poll -
   auch bei `.notModified` - neu expandieren und
   `UpcomingReminders.select(events:now:options:)` mit
   `config.reminderOptions` aufrufen. Ein Tick-Timer mit 1 s ruft `select`
   auf der zuletzt expandierten Liste mit `Date()` erneut auf, damit
   Restzeit, Stufe und das Herausfallen nach `graceMinutes` sekundengenau
   stimmen; er wird ausschliesslich gestartet, solange mindestens eine
   Warnung sichtbar ist, und wieder abgeraeumt, sobald keine mehr ansteht.
5. Restzeiten immer aus `Date()` gegen den Startzeitpunkt rechnen, nie aus
   aufsummierten Ticks. Der Feed-Abruf laeuft ausserhalb des Main-Threads,
   die Zuweisung an die @Published-Felder auf dem Main-Thread.
6. Drei erfolglose Abrufe nacheinander setzen `isStale = true`; der letzte
   erfolgreiche Terminbestand bleibt erhalten und der Countdown laeuft
   weiter. Ein erfolgreicher Abruf setzt das Flag zurueck.
7. In AgendaPanel.swift die View `AgendaPanel` anlegen, die die bestehende
   `Panel`-Huelle aus DashboardView.swift nutzt (Titel "Termine", Symbol
   "calendar"). Je Warnung eine Zeile mit: Uhrzeit (HH:mm), Titel nur wenn
   `showEventTitles` gesetzt ist, Countdown (mm:ss unter einer Stunde,
   h:mm:ss ab einer Stunde, "laeuft" bei negativer Restzeit),
   sowie ein Fortschrittsbalken in Stufenfarbe. Bei `overflow > 0` eine
   Zeile "+N weitere". Ohne Warnung zeigt das Panel eine ruhige Zeile
   "keine Termine in der naechsten Stunde" (bei abweichendem Vorlauf
   "keine Termine in den naechsten N Minuten"). Bei `isStale` eine kleine
   Zeile "Stand veraltet" in EdgeTheme.textSecondary - die Termine bleiben
   stehen.
8. Stufenfarben: .hour -> EdgeTheme.good, .halfHour -> EdgeTheme.accent,
   .quarter -> EdgeTheme.warn, .fiveMinutes -> EdgeTheme.critical,
   .imminent -> EdgeTheme.critical mit pulsierender Deckkraft (1.0 zu 0.45,
   1 s easeInOut, repeatForever, autoreverses). Ab .quarter zusaetzlich der
   Panelrand in Stufenfarbe mit opacity 0.35, ab .fiveMinutes zusaetzlich
   der Panelhintergrund in Stufenfarbe mit opacity 0.12. Massgeblich ist die
   dringendste Warnung. Die `Panel`-Huelle zeichnet einen deckenden
   Hintergrund und bleibt unveraendert: Rand und Toenung als `.overlay`
   mit `RoundedRectangle(cornerRadius: 18)` (gleicher Radius wie Panel)
   ueber die Huelle legen, mit `.allowsHitTesting(false)`.
9. In AppDelegate.swift den Menuepunkt "Termine" im Widgets-Menue
   ergaenzen, exakt nach dem Muster des bestehenden Wetter-Eintrags
   (neuer Fall `calendar` am Ende von `WidgetToggle`, Titel "Termine",
   Lesen und Schreiben von `showCalendar`), AgendaModel als
   EnvironmentObject an `DashboardView` durchreichen und in
   `applyWidgetServices()` nach dem Muster des Wetter-Blocks starten
   (`showCalendar` gesetzt) bzw. stoppen.
10. Lokaler Test ohne Google: nur unter `#if DEBUG` liest AgendaModel bei
   gesetzter Umgebungsvariable `XENEON_CALENDAR_ICS_FILE` den Feed aus
   dieser lokalen Datei statt ueber CalendarFeedFetcher; `isConfigured` ist
   dann nicht noetig, Poll- und Tick-Logik bleiben identisch. Im
   Release-Build existiert dieser Pfad nicht. Dazu Scripts/sample-calendar.sh
   (bash, `set -euo pipefail`, SPDX-Kopf wie Scripts/test.sh): schreibt
   eine ICS-Datei (Pfad als erstes Argument, Default
   `${TMPDIR}/xeneon-sample.ics`) mit Terminen relativ zur aktuellen Zeit
   in UTC: in 50 s, 4 min, 12 min, 25 min und 50 min, dazu einer vor 1 min
   gestartet, ein CANCELLED-Termin in 8 min und ein Ganztagstermin heute.
   Am Ende gibt es den passenden Startbefehl aus.

Definition of Done:
- [ ] Menuepunkt schaltet das Panel ohne Neustart ein und aus.
- [ ] Ohne gueltige Feed-URL laeuft kein Timer und es wird kein Request gebaut.
- [ ] Der 1-s-Tick laeuft nur, solange mindestens eine Warnung sichtbar ist.
- [ ] Mit `XENEON_CALENDAR_ICS_FILE` und der Beispieldatei zeigt der Debug-Build das Panel mit Countdown; der Release-Build kennt die Variable nicht.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git checkout feature/issue-20-part-5`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-5 feature/issue-20-part-4` anlegen (part-4 ist
  bis zur Freigabe nur lokal). Kein anderer Branch, Commit lokal - Push
  nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- DashboardView.swift hat 799 Zeilen: dort nur die beschriebenen
  Einfuegungen (zwei Farben, EnvironmentObject, Panel-Zeile, erweiterte
  Bedingung), keine Umbauten, keine Formatierungsaenderungen.
- Keine Logik in die View - Auswahl und Stufen kommen unveraendert aus
  XeneonEdgeKit.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Sub-Task 6 - Karte im Menueleisten-Widget

* **Scope:** `widget` - **Branch:** `feature/issue-20-part-6` (Base part-5)
* **Zu erstellen:** `Sources/XeneonEdgeKit/Calendar/AgendaModel.swift`,
  `Sources/XeneonEdgeKit/Calendar/ReminderFormat.swift`,
  `Sources/ClaudeUsageWidget/AgendaCard.swift`,
  `Tests/XeneonEdgeKitTests/CalendarFormatTests.swift`
* **Zu aendern:** `Sources/XeneonEdgeApp/Models.swift`,
  `Sources/XeneonEdgeApp/AgendaPanel.swift`,
  `Sources/ClaudeUsageWidget/WidgetConfig.swift`,
  `Sources/ClaudeUsageWidget/WidgetView.swift`,
  `Sources/ClaudeUsageWidget/WidgetAppDelegate.swift`
* **Definition of Done:** Ohne Warnung ist die Widget-Darstellung identisch
  zu vorher; mit Warnung waechst das Fenster um die Karte statt Inhalt
  abzuschneiden; App und Widget teilen sich ein einziges AgendaModel.

**Abweichung vom urspruenglichen Plan:** statt eines eigenen
`AgendaViewModel` im Widget wandert das fertige `AgendaModel` aus
`XeneonEdgeApp/Models.swift` nach `XeneonEdgeKit`. Eine Kopie im Widget
haette Timer-, Abruf-, Stale- und Debug-Logik doppelt gepflegt.

```
task: implement_subtask
branch: feature/issue-20-part-6
base_branch: feature/issue-20-part-5
target: ClaudeUsageWidget
suite: ReminderFormatTests

Ziel: Das schwebende Menueleisten-Widget zeigt anstehende Termine ueber der
Nutzungsanzeige und meldet die dringendste Warnung zusaetzlich im
Menueleisten-Titel. Bisher sieht nur das Dashboard Termine. Nach dieser
Aenderung ist die Warnung auch sichtbar, wenn das Dashboard aus ist, und
App und Widget nutzen dasselbe Modell aus XeneonEdgeKit.

Dateiebene:
- Zu erstellen: Sources/XeneonEdgeKit/Calendar/AgendaModel.swift, Sources/XeneonEdgeKit/Calendar/ReminderFormat.swift, Sources/ClaudeUsageWidget/AgendaCard.swift, Tests/XeneonEdgeKitTests/CalendarFormatTests.swift
- Zu aendern: Sources/XeneonEdgeApp/Models.swift, Sources/XeneonEdgeApp/AgendaPanel.swift, Sources/ClaudeUsageWidget/WidgetConfig.swift, Sources/ClaudeUsageWidget/WidgetView.swift, Sources/ClaudeUsageWidget/WidgetAppDelegate.swift

Aufgaben:
1. `AgendaModel` unveraendert im Verhalten aus
   Sources/XeneonEdgeApp/Models.swift nach
   Sources/XeneonEdgeKit/Calendar/AgendaModel.swift verschieben (`import
   Combine`, `public final class`, `public init()`, Published-Felder
   `public private(set)`, `start()`/`stop()` public). Inklusive des
   `#if DEBUG`-Pfads fuer `XENEON_CALENDAR_ICS_FILE`. In Models.swift
   bleibt nichts davon zurueck; die App nutzt den Kit-Typ, AppDelegate
   und AgendaPanel brauchen hoechstens Import-Anpassungen.
2. ReminderFormat.swift: `public enum ReminderFormat` mit
   `static func countdown(_ remaining: TimeInterval) -> String` (Logik
   unveraendert aus `ReminderRow.countdown` in AgendaPanel.swift: mm:ss,
   h:mm:ss ab einer Stunde, "laeuft" bei negativer Restzeit, aufrunden),
   `static func clock(_ date: Date, timeZone: TimeZone = .current) -> String`
   (HH:mm, 24 h, POSIX-Locale) und
   `static func statusTitle(_ reminder: CalendarReminder, timeZone: TimeZone = .current) -> String?`:
   ab Stufe .quarter "HH:mm - N min" mit aufgerundeten Minuten, bei
   Restzeit unter 60 s "HH:mm - jetzt", bei negativer Restzeit
   "HH:mm - laeuft"; unterhalb .quarter nil. AgendaPanel nutzt
   `countdown` und `clock` statt eigener Formatierung.
3. In WidgetConfig.swift `var showCalendar: Bool = true` ergaenzen,
   inklusive Zeile im toleranten `init(from:)` mit `decodeIfPresent`.
   Vorlauf, Poll-Intervall, Titel-Anzeige und Feed-URL kommen aus der
   gemeinsamen CalendarConfig, nicht aus dieser Datei.
4. AgendaCard.swift: View fuer das Widget mit je Warnung einer Zeile
   (Uhrzeit, Titel nur wenn `showEventTitles`, Countdown, Balken in
   Stufenfarbe) und bei overflow > 0 der Zeile "+N weitere", bei
   `isStale` "Stand veraltet". Bausteine aus WidgetView.swift
   (WidgetTheme, Balkenform) nutzen. Stufenfarben: .hour -> good,
   .halfHour -> accent, .quarter -> warn, .fiveMinutes/.imminent ->
   critical, .imminent pulsierend (1.0 zu 0.45, 1 s easeInOut,
   repeatForever, autoreverses). Ab .quarter Kartenrand in Stufenfarbe
   (opacity 0.35), ab .fiveMinutes Kartenhintergrund (opacity 0.12) -
   jeweils nach der dringendsten Warnung (hoechster Rang in
   `ReminderStage.allCases`, nie das Minimum). Feste Zeilenhoehen und eine
   `static func height(rows: Int, extraLines: Int) -> CGFloat`, die die
   exakte Hoehe der Karte liefert.
5. In WidgetView.swift die Karte als erstes Element oberhalb der
   Nutzungsanzeige einsetzen, nur wenn `config.showCalendar` gesetzt ist und
   mindestens eine Warnung ansteht. Ohne Warnung entsteht weder Karte noch
   Abstand - die Darstellung ist dann identisch zu vorher. WidgetView
   bekommt das AgendaModel als `@ObservedObject`.
6. In WidgetAppDelegate.swift ein AgendaModel halten, bei `showCalendar`
   in `applicationDidFinishLaunching` und in `reloadConfig` starten (sonst
   stoppen). Das Fenster waechst mit der Karte: Zielhoehe =
   `config.height` plus `AgendaCard.height(...)` plus Abstand, solange die
   Karte sichtbar ist, sonst `config.height`. Die Groesse nur bei
   geaenderter Zeilenzahl neu setzen (nicht jede Sekunde), ueber
   `position()`, damit die konfigurierte Ecke verankert bleibt (bei
   bottom-Ecken waechst das Fenster nach oben). Beobachtung per Combine
   (`$reminders`, `$overflow`, `$isStale`), Cancellables halten.
7. Statusleisten-Item: ab Stufe .quarter der dringendsten Warnung
   `button.title = ReminderFormat.statusTitle(...)`, `imagePosition =
   .imageLeading` und `statusItem.length = NSStatusItem.variableLength`;
   sonst Titel leeren und zurueck auf `NSStatusItem.squareLength` - nur das
   Symbol bleibt. Titel nur setzen, wenn er sich aendert.
8. In CalendarFormatTests.swift die Suite `ReminderFormatTests`: countdown
   fuer 0, 59.2, 61, 3599, 3600, 3725 s und -5 s; clock mit fester Zone;
   statusTitle nil bei .halfHour, "HH:mm - 12 min" bei 11:30 Restzeit,
   "jetzt" bei 30 s, "laeuft" bei -10 s. Feste Zeitzone in jedem Test.

Definition of Done:
- [ ] Ohne Warnung ist die Darstellung unveraendert, die Default-Groesse 560x320 reicht ohne Clipping.
- [ ] Mit Warnung waechst das Fenster um die Karte, an der konfigurierten Ecke verankert; kein Inhalt wird abgeschnitten.
- [ ] Der Menueleisten-Titel erscheint ab Stufe .quarter und verschwindet wieder.
- [ ] Es gibt genau ein AgendaModel (in XeneonEdgeKit); die App verhaelt sich wie vorher.
- [ ] Die Feed-URL steht nur in calendar.json, nicht in claude-widget.json.
- [ ] Neue und bestehende Tests laufen gruen; der Release-Build enthaelt XENEON_CALENDAR_ICS_FILE in keinem Binary.

Constraints:
- Vor der ersten Aenderung `git checkout feature/issue-20-part-6`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-6 feature/issue-20-part-5` anlegen (part-5 ist
  bis zur Freigabe nur lokal). Kein anderer Branch, Commit lokal - Push
  nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Keine Auswahl- oder Stufenlogik im Widget nachbauen - alles kommt aus
  XeneonEdgeKit.
- Waehrend der Arbeit `./Scripts/test.sh --filter ReminderFormatTests`.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Sub-Task 7 - Doku

* **Scope:** `repo` - **Branch:** `feature/issue-20-part-7` (Base part-6)
* **Zu erstellen:** `docs/GOOGLE-KALENDER-WIDGET.md`
* **Zu aendern:** `README.md`, `CLAUDE.md`
* **Definition of Done:** Ein Leser richtet das Feature ohne Rueckfrage
  ein.

```
task: implement_subtask
branch: feature/issue-20-part-7
base_branch: feature/issue-20-part-6
target: repo
suite: -

Ziel: Die Terminwarnung ist dokumentiert. Bisher steht die Einrichtung
nirgends. Nach dieser Aenderung findet ein Leser die geheime iCal-Adresse,
legt calendar.json an und kennt jede Option samt Wirkung und Grenzen.

Dateiebene:
- Zu erstellen: docs/GOOGLE-KALENDER-WIDGET.md
- Zu aendern: README.md, CLAUDE.md

Aufgaben:
1. docs/GOOGLE-KALENDER-WIDGET.md im Ton und Aufbau von
   docs/CLAUDE-USAGE-WIDGET.md schreiben, mit Umlauten wie dort (die Regel
   "ohne Umlaute" gilt fuer Code-Kommentare und UI-Texte, nicht fuer die
   Doku): was angezeigt wird, die beiden Betriebsarten (Panel "Termine" im
   Dashboard, eingeschaltet ueber das Menue Widgets > Termine; Karte im
   Menueleisten-Widget, Schalter `showCalendar` in claude-widget.json,
   Default an), Einrichtung, Optionstabelle, Datenschutzabsatz, Grenzen,
   lokaler Test. Beim Widget beschreiben: die Karte steht ueber der
   Nutzungsanzeige, das Fenster waechst um die Karte und bleibt an der
   konfigurierten Ecke verankert, ab 15 min Restzeit zeigt die Menueleiste
   einen Kurztitel ("14:30 - 12 min", "jetzt", "laeuft").
2. Einrichtung Schritt fuer Schritt: in Google Kalender die
   Kalendereinstellungen oeffnen, unter "Geheime Adresse im iCal-Format" die
   URL kopieren, calendar.json unter ~/Library/Application
   Support/XeneonEdge/ anlegen, `enabled` auf true setzen, Widget oder
   Dashboard neu laden (Menue "Konfiguration neu laden").
   Eigener Unterabschnitt "Oeffentliche oder geheime Adresse": Die
   oeffentliche Adresse (`.../ical/<kalender-id>/public/basic.ics`)
   funktioniert nur, wenn der Kalender oeffentlich freigegeben ist - sonst
   antwortet Google mit HTTP 404 und das Panel zeigt nach drei Versuchen
   "Stand veraltet". Fuer einen Firmenkalender ist das Oeffentlichmachen
   nicht empfehlenswert. Die geheime Adresse funktioniert ohne Freigabe;
   fehlt der Eintrag "Geheime Adresse im iCal-Format", hat der
   Google-Workspace-Admin ihn gesperrt. Ein Freigabelink der Form
   `calendar.google.com/calendar/u/0?cid=...` ist kein Feed.
3. Optionstabelle mit Default und Wirkung je Feld: enabled, feedURL,
   leadMinutes, graceMinutes, maxReminders, pollSeconds, showEventTitles,
   feedOwnerEmail. Dazu die geklemmten Bereiche (pollSeconds 60 bis 3600,
   leadMinutes 5 bis 240, graceMinutes 0 bis 30, maxReminders 1 bis 4).
   Bei feedOwnerEmail erklaeren: Termine, die diese Adresse abgesagt hat
   (PARTSTAT=DECLINED), erzeugen keine Warnung.
4. Die Eskalationstabelle uebernehmen: 60 bis 30 min gruen, 30 bis 15 min
   gelb, 15 bis 5 min orange, 5 bis 1 min rot, unter 1 min rot pulsierend.
5. Einen Abschnitt zu den Grenzen: Ganztagstermine werden nie angezeigt; der
   Google-Feed aktualisiert sich traege (Minuten), ein spontan eingetragener
   Termin in fuenf Minuten kann fehlen; ist gerade keine Warnung sichtbar,
   erscheint ein neu in den Vorlauf ruckender Termin erst beim naechsten
   Abruf (hoechstens pollSeconds); kein Schreibzugriff auf den Kalender;
   bei Netzausfall bleibt der letzte Stand stehen und der Countdown laeuft
   weiter; Serienregeln mit BYSETPOS, BYWEEKNO, BYYEARDAY oder
   Stundenangaben werden nicht expandiert, der Termin erscheint dann nur
   als Einzeltermin; Dashboard-App und Widget rufen den Feed jeweils
   selbst ab.
5a. Abschnitt "Lokal testen ohne Google": `./Scripts/sample-calendar.sh`
   erzeugt eine Beispieldatei mit Terminen relativ zur aktuellen Zeit, der
   Debug-Build liest sie ueber die Umgebungsvariable
   `XENEON_CALENDAR_ICS_FILE` statt des Feeds (im Release-Build gibt es
   diese Variable nicht). Startbefehle fuer App und Widget nennen.
6. Datenschutzabsatz: die geheime Adresse ist ein Zugangsschluessel in
   URL-Form - wer sie hat, liest den ganzen Kalender. Sie steht nur in
   calendar.json (Rechte 0600), wird nie geloggt und nie angezeigt.
   showEventTitles auf false laesst nur Uhrzeit und Countdown stehen, falls
   das Edge nicht privat haengt.
7. In README.md das Feature in der Feature-Liste ergaenzen und auf die neue
   Doku verlinken, im Stil der vorhandenen Eintraege.
8. In CLAUDE.md unter "Tech-Stack-Vorgaben" einen Punkt ergaenzen: die
   Kalender-Feed-URL ist ein Geheimnis, sie wird nie geloggt, nie in einer
   Fehlermeldung ausgegeben und nie in der UI angezeigt; Logs nennen
   hoechstens Host und HTTP-Status. Diese Zusage nicht aufweichen. Konkret:
   Fehlerobjekte (URLError, error) nie interpolieren, der Abruf laeuft ueber
   die ephemere Session ohne URL-Cache, calendar.json wird mit 0600
   angelegt. Zusaetzlich unter "Targets" bzw. passender Stelle: die
   Kalender-Logik inklusive AgendaModel liegt in XeneonEdgeKit/Calendar,
   App und Widget teilen sie.

Definition of Done:
- [ ] Ein Leser richtet das Feature allein anhand der Doku ein.
- [ ] Jede Option aus CalendarConfig steht mit Default und Wirkung in der Tabelle.
- [ ] README und CLAUDE.md verweisen auf die neue Datei bzw. die Geheimnis-Zusage.

Constraints:
- Vor der ersten Aenderung `git checkout feature/issue-20-part-7`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-7 feature/issue-20-part-6` anlegen (part-6 ist
  bis zur Freigabe nur lokal). Kein anderer Branch, Commit lokal - Push
  nur nach Freigabe durch Pascal.
- Jede Aussage in der Doku gegen den Code pruefen (Defaults, Klemmbereiche,
  Texte im Panel, Menuepunkte) - Quelle sind die Dateien unter
  Sources/XeneonEdgeKit/Calendar/, Sources/XeneonEdgeKit/Config/CalendarConfig.swift,
  Sources/XeneonEdgeApp/AgendaPanel.swift und Sources/ClaudeUsageWidget/.
- Nur Dokumentation, kein Produktivcode in diesem Sub-Task.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

---

## Abschluss jeder Session

Jeder Sub-Task endet mit dem Review-Prompt fuer Opus nach der Form in
[`.github/PLAN.template.md`](../.github/PLAN.template.md): Aenderungen,
Designentscheidungen, bedachte Edge Cases, drei bis vier konkrete
Pruefpunkte mit Datei und Funktion, bekannte Luecken. Ein einzelner
Codeblock, hoechstens 40 Zeilen, kein Selbstlob.
