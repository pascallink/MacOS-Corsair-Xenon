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
| 6 | `feature/issue-20-part-6` (Base part-5) | `widget` | Karte im Menueleisten-Widget |
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

`Sources/XeneonEdgeApp/DashboardView.swift` hat 704 Zeilen und liegt damit
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
   dem Feed (z. B. "CONFIRMED", "CANCELLED"), gross geschrieben.
2. In ICSParser.swift die Funktion
   `public static func parse(_ text: String, defaultTimeZone: TimeZone = .current) -> [CalendarEvent]`
   anlegen. Sie ist rein und synchron, ohne Netz- und Dateizugriff - gleiche
   Bauform wie `CloudUsageFetcher.parseGistResponse` in
   Sources/XeneonEdgeKit/ClaudeUsage/CloudUsageFetcher.swift.
3. Als ersten Schritt im Parser die Zeilen entfalten (Unfolding): eine Zeile,
   die mit Leerzeichen oder Tabulator beginnt, gehoert an die vorherige
   angehaengt, ohne dieses erste Zeichen. Erst danach wird in
   Name/Parameter/Wert getrennt. CRLF und LF muessen beide funktionieren.
4. Nur Bloecke zwischen BEGIN:VEVENT und END:VEVENT auswerten. Ein
   BEGIN:VTIMEZONE-Block wird bis zu seinem END:VTIMEZONE vollstaendig
   uebersprungen, auch wenn er VEVENT-aehnliche Zeilen enthaelt.
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
     Mitternacht in `defaultTimeZone`.
7. Fehlt DTEND, aber DURATION ist gesetzt (Form `PT1H30M`, `PT45M`, `P1D`),
   das Ende aus Start plus Dauer berechnen. Fehlen beide, Ende gleich Start.
8. Ein VEVENT ohne verwertbares DTSTART wird uebersprungen, nicht als
   Platzhalter aufgenommen. RECURRENCE-ID wird wie ein DTSTART aufgeloest
   und in `recurrenceID` abgelegt.
9. In CalendarICSTests.swift die Suite `ICSParserTests` anlegen (import
   Testing, `@Suite struct`, `@Test func`, `#expect`), mit je einem Test fuer:
   gefaltete SUMMARY-Zeile bleibt zusammenhaengend; maskiertes Komma; jede
   der vier DTSTART-Formen; DURATION ohne DTEND; VALUE=DATE setzt isAllDay;
   unbekannte TZID faellt auf defaultTimeZone zurueck ohne den Termin zu
   verlieren; Text ohne VEVENT ergibt ein leeres Array; abgeschnittener
   VEVENT-Block ohne END ergibt ein leeres Array.

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
1. In CalendarModels.swift den Typ `RecurrenceRule` ergaenzen mit:
   `frequency` (Enum `.daily`, `.weekly`, `.monthly`, `.yearly`),
   `interval: Int = 1`, `count: Int?`, `until: Date?`,
   `byDay: [Int]` (1 = Sonntag bis 7 = Samstag, wie Calendar.component),
   `byMonthDay: [Int]`. `CalendarEvent` bekommt zusaetzlich
   `recurrence: RecurrenceRule?` und `exceptionDates: [Date]`.
2. In ICSParser.swift RRULE und EXDATE einlesen und in diese Felder
   schreiben. Unbekannte RRULE-Teile (z. B. BYSETPOS, WKST) werden
   ignoriert, ohne den Termin zu verwerfen. Eine RRULE mit unbekanntem FREQ
   ergibt `recurrence = nil`, der Termin bleibt als Einzeltermin erhalten.
3. In RecurrenceExpander.swift die Funktion
   `public static func expand(_ events: [CalendarEvent], in range: Range<Date>, calendar: Calendar = .current) -> [CalendarEvent]`
   anlegen. Sie liefert ausschliesslich Instanzen, deren Start in `range`
   liegt.
4. Die Expansion laeuft ueber Kalenderkomponenten (`calendar.date(byAdding:)`),
   nicht ueber Addition fester Sekundenbetraege - sonst verschiebt sich die
   Ortszeit beim Wechsel zwischen Sommer- und Winterzeit.
5. Die Schleife bricht ab, sobald der Kandidat hinter `range.upperBound`
   oder hinter `until` liegt, oder wenn `count` erreicht ist. Zusaetzlich
   eine harte Obergrenze von 1000 Iterationen je Serie, damit eine kaputte
   Regel keine Endlosschleife erzeugt.
6. Instanzen, deren Start in `exceptionDates` steht, werden entfernt.
7. Ein Termin mit gesetzter `recurrenceID` ist eine Ausnahme: er ersetzt die
   generierte Instanz derselben `uid` mit demselben Startzeitpunkt, statt
   zusaetzlich zu erscheinen.
8. In CalendarRecurrenceTests.swift die Suite `RecurrenceExpanderTests`
   anlegen, mit je einem Test fuer: FREQ=WEEKLY;BYDAY=MO,WE trifft nur
   Montag und Mittwoch; INTERVAL=2 ueberspringt jede zweite Woche; COUNT=3
   endet nach drei Instanzen; UNTIL in der Vergangenheit liefert nichts;
   EXDATE entfernt genau eine Instanz; RECURRENCE-ID ersetzt statt zu
   verdoppeln; eine Serie ohne UNTIL und COUNT liefert im
   Zwei-Stunden-Fenster genau die Instanzen darin; eine taegliche Serie
   ueber die Zeitumstellung behaelt ihre Ortszeit.

Definition of Done:
- [ ] Serie ohne Ende bleibt im Fenster begrenzt, keine Endlosschleife.
- [ ] EXDATE entfernt, RECURRENCE-ID ersetzt.
- [ ] Ortszeit bleibt ueber die Zeitumstellung stabil.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-2
  feature/issue-20-part-1` und `git checkout feature/issue-20-part-2`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-2 origin/feature/issue-20-part-1` anlegen. Kein
  anderer Branch, Commit lokal - Push nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Bestehende Signaturen aus Sub-Task 1 nicht brechen; `ICSParser.parse`
  behaelt Name und Parameter.
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
- Zu aendern: -

Aufgaben:
1. Enum `ReminderStage` mit den Faellen `.hour`, `.halfHour`, `.quarter`,
   `.fiveMinutes`, `.imminent` und
   `public init(remaining: TimeInterval)`. Grenzen: ueber 1800 s -> .hour,
   ueber 900 s -> .halfHour, ueber 300 s -> .quarter, ueber 60 s ->
   .fiveMinutes, sonst .imminent. Die Kante gehoert damit jeweils zur
   ruhigeren Stufe: exakt 1800 s ergibt .halfHour, exakt 60 s ergibt
   .fiveMinutes. Eine negative Restzeit (Termin laeuft) ergibt .imminent.
2. Struct `CalendarReminder` (Equatable, Identifiable) mit `event:
   CalendarEvent`, `remaining: TimeInterval`, `stage: ReminderStage`,
   `progress: Double`. `progress` ist 0 bei Restzeit gleich Vorlauf und 1
   bei Restzeit 0, immer auf 0...1 geklemmt.
3. Struct `ReminderOptions` mit `leadMinutes: Double = 60`,
   `graceMinutes: Double = 2`, `maxReminders: Int = 2`,
   `feedOwnerEmail: String = ""`.
4. `public enum UpcomingReminders` mit
   `static func select(events: [CalendarEvent], now: Date, options: ReminderOptions = .init()) -> (reminders: [CalendarReminder], overflow: Int)`.
   `now` wird immer uebergeben - kein `Date()` innerhalb der Auswahl, sonst
   ist sie nicht testbar.
5. Auswahlregeln in dieser Reihenfolge: Termine mit `isAllDay == true`
   fallen raus; Termine mit `status == "CANCELLED"` fallen raus; ein Termin
   zaehlt, wenn sein Start zwischen `now - graceMinutes` und `now +
   leadMinutes` liegt; sortiert wird nach Startzeit, bei gleichem Start nach
   Titel, damit die Reihenfolge stabil ist.
6. Von den verbleibenden Terminen werden die ersten `maxReminders`
   zurueckgegeben, der Rest zaehlt in `overflow`.
7. Ist `feedOwnerEmail` nicht leer, fallen zusaetzlich Termine raus, die
   fuer genau diese Adresse `PARTSTAT=DECLINED` tragen. Dafuer bekommt
   `CalendarEvent` in dieser Datei keine neuen Felder - stattdessen die
   Signatur so waehlen, dass die Absage-Information als
   `declinedBy: Set<String>` am Event liegt; das Feld in
   CalendarModels.swift ergaenzen und im Parser aus ATTENDEE-Zeilen fuellen
   ist Teil dieses Sub-Tasks nur, falls es ohne Aenderung an ICSParser.swift
   nicht geht - andernfalls `declinedBy` leer lassen und den Filter
   vorbereiten.
8. In CalendarReminderTests.swift die Suite `CalendarReminderTests` anlegen,
   mit je einem Test fuer: Ganztagstermin faellt raus; Termin in 61 Minuten
   ist nicht dabei, in 59 Minuten schon; drei passende Termine ergeben zwei
   Warnungen und overflow == 1; ein vor 1 Minute gestarteter Termin ist noch
   dabei, ein vor 3 Minuten gestarteter nicht mehr; CANCELLED faellt raus;
   je ein Test auf die Sekunde fuer 1800, 900, 300 und 60 Sekunden
   Restzeit; progress ist 0 bei 3600 s und 1 bei 0 s Restzeit.

Definition of Done:
- [ ] Kein `Date()` in der Auswahl- oder Stufenlogik.
- [ ] Nie mehr als `maxReminders` Eintraege, der Rest steht in `overflow`.
- [ ] Alle vier Stufengrenzen sekundengenau getestet.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-3
  feature/issue-20-part-2` und `git checkout feature/issue-20-part-3`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-3 origin/feature/issue-20-part-2` anlegen. Kein
  anderer Branch, Commit lokal - Push nur nach Freigabe durch Pascal.
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
   CalendarConfig: Codable, Equatable` mit `enabled = false`,
   `feedURL = ""`, `leadMinutes: Double = 60`, `graceMinutes: Double = 2`,
   `maxReminders = 2`, `pollSeconds: Double = 300`,
   `showEventTitles = true`, `feedOwnerEmail = ""`.
2. Tolerantes `init(from:)` mit `decodeIfPresent` je Feld und Rueckfall auf
   den Default - exakt wie in AppConfig.swift, damit eine handgeschriebene
   Datei mit nur einem Schluessel gueltig bleibt.
3. Ablage in `~/Library/Application Support/XeneonEdge/calendar.json`
   (`AppConfig.directory` wiederverwenden). `load()` gibt bei fehlender oder
   kaputter Datei Defaults zurueck und schreibt dabei nichts; `save()`
   schreibt atomar und setzt anschliessend die Dateirechte auf 0600
   (`FileManager.setAttributes([.posixPermissions: 0o600])`), weil die Datei
   ein Geheimnis enthaelt.
4. `isConfigured` liefert nur true, wenn `enabled` gesetzt ist und `feedURL`
   eine https-URL ist. `pollSeconds` wird beim Lesen auf 60...3600 geklemmt,
   `leadMinutes` auf 5...240, `maxReminders` auf 1...4.
5. CalendarFeedFetcher.swift: `public static func redact(_ url: String) ->
   String` gibt hoechstens Schema und Host zurueck ("https://<host>"), nie
   Pfad, nie Query. Jede Log- und Fehlermeldung im Modul geht ueber diese
   Funktion.
6. `public static func fetch(urlString:etag:lastModified:session:) async ->
   FeedResult` mit `FeedResult` als Enum `.notModified`,
   `.success(text: String, etag: String?, lastModified: String?)`,
   `.failure`. Nur https wird akzeptiert, Timeout 15 s, Header
   If-None-Match und If-Modified-Since werden gesetzt, wenn die Werte
   vorliegen. HTTP 304 ergibt `.notModified`, 200 ergibt `.success`, alles
   andere `.failure` - kein `throw` nach aussen, gleiche Haltung wie
   CloudUsageFetcher.fetch.
7. In CalendarFeedTests.swift die Suite `CalendarFeedTests` anlegen, mit je
   einem Test fuer: `redact` entfernt Pfad und Query vollstaendig; `redact`
   auf einer unparsbaren Eingabe gibt keinen Teil der Eingabe zurueck; eine
   http-URL ergibt `isConfigured == false`; Config ohne Schluessel dekodiert
   auf alle Defaults; Config mit nur einem Schluessel behaelt die uebrigen
   Defaults; pollSeconds 5 wird zu 60 und 99999 zu 3600; maxReminders 9 wird
   zu 4. Kein Test geht ins Netz.

Definition of Done:
- [ ] Keine Logzeile und keine Fehlermeldung enthaelt Pfad oder Query der Feed-URL.
- [ ] calendar.json wird mit 0600 geschrieben.
- [ ] Ohne `enabled` und gueltige https-URL wird kein Request gebaut.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-4
  feature/issue-20-part-3` und `git checkout feature/issue-20-part-4`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-4 origin/feature/issue-20-part-3` anlegen. Kein
  anderer Branch, Commit lokal - Push nur nach Freigabe durch Pascal.
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
* **Zu erstellen:** `Sources/XeneonEdgeApp/AgendaPanel.swift`
* **Zu aendern:** `Sources/XeneonEdgeApp/Models.swift`,
  `Sources/XeneonEdgeApp/DashboardView.swift` (Eskalation: 704 Zeilen,
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
- Zu erstellen: Sources/XeneonEdgeApp/AgendaPanel.swift
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
   Ausserdem in der mittleren Spalte, vor dem Claude-Panel, die Zeile
   `if configStore.config.showCalendar { AgendaPanel() }` einfuegen. Sonst
   nichts an dieser Datei aendern.
3. In Models.swift die Klasse `AgendaModel: ObservableObject` ergaenzen,
   nach dem Muster von ClaudeUsageModel in derselben Datei:
   `@Published var reminders: [CalendarReminder]`,
   `@Published var overflow: Int`, `@Published var isStale: Bool`.
   `start()` laedt die CalendarConfig, `stop()` raeumt alle Timer ab.
4. Zwei Timer: ein Poll-Timer mit `config.pollSeconds` holt den Feed ueber
   CalendarFeedFetcher, parst mit ICSParser, expandiert mit
   RecurrenceExpander im Fenster `now ... now + leadMinutes + 15 min` und
   legt die Termine ab. Ein Tick-Timer mit 1 s rechnet nur die Restzeiten
   und Stufen neu; er wird ausschliesslich gestartet, solange mindestens
   eine Warnung sichtbar ist, und wieder abgeraeumt, sobald keine mehr
   ansteht.
5. Restzeiten immer aus `Date()` gegen den Startzeitpunkt rechnen, nie aus
   aufsummierten Ticks. Der Feed-Abruf laeuft ausserhalb des Main-Threads,
   die Zuweisung an die @Published-Felder auf dem Main-Thread.
6. Drei erfolglose Abrufe nacheinander setzen `isStale = true`; der letzte
   erfolgreiche Terminbestand bleibt erhalten und der Countdown laeuft
   weiter. Ein erfolgreicher Abruf setzt das Flag zurueck.
7. In AgendaPanel.swift die View `AgendaPanel` anlegen, die die bestehende
   `Panel`-Huelle aus DashboardView.swift nutzt (Titel "Termine", Symbol
   "calendar"). Je Warnung eine Zeile mit: Uhrzeit (HH:mm), Titel nur wenn
   `showEventTitles` gesetzt ist, Countdown (mm:ss unter einer Stunde),
   sowie ein Fortschrittsbalken in Stufenfarbe. Bei `overflow > 0` eine
   Zeile "+N weitere". Ohne Warnung zeigt das Panel eine ruhige Zeile
   "keine Termine in der naechsten Stunde".
8. Stufenfarben: .hour -> EdgeTheme.good, .halfHour -> EdgeTheme.accent,
   .quarter -> EdgeTheme.warn, .fiveMinutes -> EdgeTheme.critical,
   .imminent -> EdgeTheme.critical mit pulsierender Deckkraft (1.0 zu 0.45,
   1 s easeInOut, repeatForever, autoreverses). Ab .quarter zusaetzlich der
   Panelrand in Stufenfarbe mit opacity 0.35, ab .fiveMinutes zusaetzlich
   der Panelhintergrund in Stufenfarbe mit opacity 0.12.
9. In AppDelegate.swift den Menuepunkt "Termine" im Widgets-Menue
   ergaenzen, exakt nach dem Muster des bestehenden Wetter-Eintrags
   (Aufzaehlungsfall, Lesen und Schreiben von `showCalendar`), und
   AgendaModel wie die uebrigen Modelle starten, stoppen und als
   EnvironmentObject durchreichen.

Definition of Done:
- [ ] Menuepunkt schaltet das Panel ohne Neustart ein und aus.
- [ ] Ohne gueltige Feed-URL laeuft kein Timer und es wird kein Request gebaut.
- [ ] Der 1-s-Tick laeuft nur, solange mindestens eine Warnung sichtbar ist.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-5
  feature/issue-20-part-4` und `git checkout feature/issue-20-part-5`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-5 origin/feature/issue-20-part-4` anlegen. Kein
  anderer Branch, Commit lokal - Push nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- DashboardView.swift hat 704 Zeilen: dort nur die beiden beschriebenen
  Einfuegungen, keine Umbauten, keine Formatierungsaenderungen.
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
* **Zu erstellen:** `Sources/ClaudeUsageWidget/AgendaCard.swift`,
  `Sources/ClaudeUsageWidget/AgendaViewModel.swift`
* **Zu aendern:** `Sources/ClaudeUsageWidget/WidgetConfig.swift`,
  `Sources/ClaudeUsageWidget/WidgetView.swift`,
  `Sources/ClaudeUsageWidget/WidgetAppDelegate.swift`
* **Definition of Done:** Ohne Warnung ist die Widget-Darstellung identisch
  zu vorher; die Default-Groesse 560x320 bleibt ohne Clipping.

```
task: implement_subtask
branch: feature/issue-20-part-6
base_branch: feature/issue-20-part-5
target: ClaudeUsageWidget
suite: -

Ziel: Das schwebende Menueleisten-Widget zeigt anstehende Termine ueber der
Nutzungsanzeige und meldet die letzte Stufe zusaetzlich im
Menueleisten-Titel. Bisher sieht das Widget keine Termine. Nach dieser
Aenderung ist die Warnung auch sichtbar, wenn das Dashboard aus ist.

Dateiebene:
- Zu erstellen: Sources/ClaudeUsageWidget/AgendaViewModel.swift, Sources/ClaudeUsageWidget/AgendaCard.swift
- Zu aendern: Sources/ClaudeUsageWidget/WidgetConfig.swift, Sources/ClaudeUsageWidget/WidgetView.swift, Sources/ClaudeUsageWidget/WidgetAppDelegate.swift

Aufgaben:
1. In WidgetConfig.swift `var showCalendar: Bool = true` ergaenzen,
   inklusive Zeile im toleranten `init(from:)` mit `decodeIfPresent`.
   Vorlauf, Poll-Intervall und Titel-Anzeige kommen aus der gemeinsamen
   CalendarConfig in XeneonEdgeKit, nicht aus dieser Datei - die Feed-URL
   wird hier nicht dupliziert.
2. AgendaViewModel.swift anlegen: `final class AgendaViewModel:
   ObservableObject` mit `@Published var reminders: [CalendarReminder]`,
   `@Published var overflow: Int`, `@Published var isStale: Bool`.
   Poll-Timer und 1-s-Tick-Timer wie in AgendaModel des App-Targets: Tick
   nur solange eine Warnung sichtbar ist, Restzeit immer aus `Date()`, Abruf
   abseits des Main-Threads, Zuweisung auf dem Main-Thread, isStale nach
   drei Fehlversuchen.
3. AgendaCard.swift anlegen: eine View, die je Warnung eine Zeile mit
   Uhrzeit (HH:mm), Titel (nur wenn CalendarConfig.showEventTitles),
   Countdown und einem Balken in Stufenfarbe zeigt, dazu bei overflow > 0
   die Zeile "+N weitere". Die Karte nutzt die vorhandenen Bausteine aus
   WidgetView.swift (WidgetTheme, die Balkenform, Capsule-Badges).
4. Stufenfarben: .hour -> WidgetTheme.good, .halfHour -> WidgetTheme.accent,
   .quarter -> WidgetTheme.warn, .fiveMinutes -> WidgetTheme.critical,
   .imminent -> WidgetTheme.critical mit pulsierender Deckkraft (1.0 zu
   0.45, 1 s easeInOut, repeatForever, autoreverses). Ab .quarter
   zusaetzlich der Kartenrand in Stufenfarbe mit opacity 0.35, ab
   .fiveMinutes zusaetzlich der Kartenhintergrund mit opacity 0.12.
5. In WidgetView.swift die Karte oberhalb der Nutzungsanzeige einsetzen,
   nur wenn `config.showCalendar` gesetzt ist und mindestens eine Warnung
   ansteht. Ohne Warnung belegt sie keinen Platz, damit die konfigurierte
   height unveraendert reicht.
6. In WidgetAppDelegate.swift dem Statusleisten-Item ab Stufe .quarter
   zusaetzlich einen Kurztitel geben, Form "14:30 - 12 min", basierend auf
   der dringendsten Warnung. Faellt die Stufe darunter oder verschwindet die
   Warnung, wird der Titel wieder geleert und nur das Symbol bleibt.
7. Die Terminzeilen ersetzen nichts am bestehenden Aufbau: ohne
   anstehenden Termin sieht das Widget exakt aus wie vorher.

Definition of Done:
- [ ] Ohne Warnung ist die Darstellung unveraendert, die Default-Groesse 560x320 reicht ohne Clipping.
- [ ] Der Menueleisten-Titel erscheint ab Stufe .quarter und verschwindet wieder.
- [ ] Die Feed-URL steht nur in calendar.json, nicht in claude-widget.json.
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-6
  feature/issue-20-part-5` und `git checkout feature/issue-20-part-6`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-6 origin/feature/issue-20-part-5` anlegen. Kein
  anderer Branch, Commit lokal - Push nur nach Freigabe durch Pascal.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Keine Auswahl- oder Stufenlogik im Widget nachbauen - alles kommt aus
  XeneonEdgeKit.
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
   docs/CLAUDE-USAGE-WIDGET.md schreiben: was angezeigt wird, die beiden
   Betriebsarten (Panel im Dashboard, Karte im Widget), Einrichtung,
   Optionstabelle, Datenschutzabsatz, Grenzen.
2. Einrichtung Schritt fuer Schritt: in Google Kalender die
   Kalendereinstellungen oeffnen, unter "Geheime Adresse im iCal-Format" die
   URL kopieren, calendar.json unter ~/Library/Application
   Support/XeneonEdge/ anlegen, `enabled` auf true setzen, Widget oder
   Dashboard neu laden.
3. Optionstabelle mit Default und Wirkung je Feld: enabled, feedURL,
   leadMinutes, graceMinutes, maxReminders, pollSeconds, showEventTitles,
   feedOwnerEmail. Dazu die geklemmten Bereiche (pollSeconds 60 bis 3600,
   leadMinutes 5 bis 240, maxReminders 1 bis 4).
4. Die Eskalationstabelle uebernehmen: 60 bis 30 min gruen, 30 bis 15 min
   gelb, 15 bis 5 min orange, 5 bis 1 min rot, unter 1 min rot pulsierend.
5. Einen Abschnitt zu den Grenzen: Ganztagstermine werden nie angezeigt; der
   Google-Feed aktualisiert sich traege (Minuten), ein spontan eingetragener
   Termin in fuenf Minuten kann fehlen; kein Schreibzugriff auf den
   Kalender; bei Netzausfall bleibt der letzte Stand stehen und der
   Countdown laeuft weiter.
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
   hoechstens Host und HTTP-Status. Diese Zusage nicht aufweichen.

Definition of Done:
- [ ] Ein Leser richtet das Feature allein anhand der Doku ein.
- [ ] Jede Option aus CalendarConfig steht mit Default und Wirkung in der Tabelle.
- [ ] README und CLAUDE.md verweisen auf die neue Datei bzw. die Geheimnis-Zusage.

Constraints:
- Vor der ersten Aenderung `git fetch origin feature/issue-20-part-7
  feature/issue-20-part-6` und `git checkout feature/issue-20-part-7`.
  Existiert der Branch noch nicht, mit `git checkout -b
  feature/issue-20-part-7 origin/feature/issue-20-part-6` anlegen. Kein
  anderer Branch, Commit lokal - Push nur nach Freigabe durch Pascal.
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
