# Handoff — XeneonEdge für macOS

Stand: 2026-08-29. Dieses Dokument ist für eine **neue Claude-Code-Session
(anderes Profil)**, die diese Arbeit fortsetzt, ohne den bisherigen Chat-
verlauf zu kennen. Es fasst zusammen: was das Projekt ist, was fertig ist,
was offen ist, und wichtige Entscheidungen/Fallstricke, die nicht rückgängig
gemacht werden sollten, ohne den Grund zu kennen.

## 1. Repo & Branch

- Repo: `pascallink/MacOS-Corsair-Xenon` (GitHub)
- Arbeits-Branch: `claude/corsair-xenon-edge-macos-4jjvf9`
- Default-Branch: `main` (nachträglich beim initialen Commit `232e479`
  erzeugt, damit ein PR möglich war — enthält NICHT die späteren Commits)
- **Offener PR #1**: `claude/corsair-xenon-edge-macos-4jjvf9` → `main`,
  https://github.com/pascallink/MacOS-Corsair-Xenon/pull/1 — Stand: alle
  CI-Läufe grün (zuletzt Run #16/#17 auf Commit `f5b581c`). Noch nicht
  gemerged, keine offenen Review-Threads bekannt.
- CI: GitHub Actions, `.github/workflows/build.yml`, macOS-Runner
  (Debug-Build, `swift test`, Release-Build, App-Bundling). Läuft bei jedem
  Push automatisch.

**Erste Aktion in der neuen Session:** `git pull` auf diesem Branch, dann
`git log --oneline -15` zum Abgleich mit der Commit-Liste unten.

## 2. Was das Projekt ist

Nativer macOS-Treiber + Dashboard für das **CORSAIR XENEON EDGE** (14,5″
LCD-Touchscreen, 2560×720), damit dessen iCUE/Windows-only-Funktionen auch
unter macOS ohne iCUE nutzbar sind. Swift Package mit drei ausführbaren
Targets + einer gemeinsamen Bibliothek:

| Target | Zweck |
|---|---|
| `XeneonEdgeKit` | Bibliothek: Touch-Treiber (HID→CGEvent), Bragi-Vendor-HID-Transport, DDC/CI, Systemsensoren, Medien/Audio, Claude-Usage-Parser |
| `XeneonEdgeApp` | Menüleisten-App mit Vollbild-Dashboard auf dem Edge (Uhr, System, Medien, Lautstärke, Schnellstart, Wetter, Claude-Nutzung) |
| `ClaudeUsageWidget` | Eigenständiges rahmenloses Floating-Widget für die Claude-Code-Nutzungsanzeige |
| `xeneonctl` | CLI (probe, brightness, ddc, touch-monitor, firmware) |

Dokumentation für Endnutzer: `README.md` (Überblick), `INSTALL.md`
(Schritt-für-Schritt inkl. Risiken), `docs/CLAUDE-USAGE-WIDGET.md`
(Claude-Widget-Details), `PROTOCOL-MACOS.md` (reverse-engineertes
HID-Protokoll, Quellenangaben).

**Wichtig — nicht auf echter Hardware getestet.** Der gesamte Code
kompiliert und die Unit-Tests laufen auf der macOS-CI, aber es gab in
keiner Session Zugriff auf ein echtes XENEON EDGE. Der erste Schritt zur
Verifikation für den Nutzer ist `xeneonctl probe`.

## 3. Chronologie der bisherigen Arbeit (11 Commits)

1. `232e479` — Initialer Treiber: Touch (HID `27c0:0859`→CGEvent), Bragi-
   Vendor-HID (`1b1c:1d0d`), DDC/CI via private `IOAVService`-API (Apple
   Silicon), Dashboard-App, CLI, CI, Packaging, GPL-3.0. **CI initial rot**
   (fehlende `public init()` in zwei Structs).
2. `76637f4` — Build-Fixes + **Firmware-Write-Gate**: `BragiDevice.send`
   lässt nur lesende Kommandos (GET `0x02`, Block-Read `0x08`) zum
   Vendor-HID durch; alles andere wird abgewiesen, außer
   `dangerouslyAllowWrites` wird explizit gesetzt (tut niemand im Code).
   Durch `WriteGateTests` abgesichert. Plus `INSTALL.md`.
3. `b606b10` — INSTALL.md: Koexistenz mit anderen Tools (iCUE, MonitorControl,
   älterer Community-Touch-Treiber).
4. `029dc83` — Claude-Usage-Widget (Erstversion, Standalone-App).
5. `3433ffb` — Fix: Modellnamen-Anzeige bei datumsbehafteten Modell-IDs.
6. `925d4a4` — Claude-Usage-Panel ins Dashboard integriert +
   feldweise tolerantes Config-Decoding eingeführt. **CI rot** (1 Testfehler:
   `LauncherItem` verlangte zwingend ein `id`-Feld).
7. `4d4a522` — Fix: `LauncherItem.id` optional, generiert sich selbst.
8. `1cc173b` — `install.sh`: installiert jetzt auch das Claude-Widget,
   beendet laufende Instanzen vor dem Ersetzen.
9. `2677f58` — Menüleiste bekommt "Widgets"-Untermenü (alle 7 Panels live
   an/ausschaltbar) + "Konfiguration neu laden". Grund: Nutzer meldete, das
   Claude-Panel sei "noch nicht integriert" — Ursache war u. a., dass Panels
   nur per Hand-Edit + Neustart umschaltbar waren.
10. `af235ee` — **Wichtiger Bugfix**: Config-Änderungen (Datei UND Menü)
    gingen verloren. Zwei Ursachen: (a) `AppConfig.load()`/
    `WidgetConfig.load()` fielen bei JEDEM Decodierfehler auf Defaults
    zurück und **schrieben diese Defaults sofort zurück** — u. a. weil
    Swifts `@Published`-`didSet` auch beim Zuweisen in `init()` feuert
    (bekannte Falle); (b) zwei App-Instanzen (LaunchAgent + manueller Start)
    überschrieben sich gegenseitig. Fix: Laden schreibt nie mehr, Fehler
    gehen nach `NSLog`+Alert, doppelte Instanzen beenden sich selbst.
11. `f5b581c` — **Cloud-Relay** für Claude-Code-Sessions aus Remote-/Cloud-
    Umgebungen (siehe Abschnitt 5).

## 4. Kernarchitektur-Entscheidungen (bitte respektieren)

- **Firmware-Sicherheit ist nicht verhandelbar.** `BragiDevice.send` (in
  `Sources/XeneonEdgeKit/Bragi/BragiDevice.swift`) darf niemals ohne
  ausdrückliche, im Code sichtbare Begründung erweitert werden, zusätzliche
  Kommandos durchzulassen. Jede neue Bragi-Funktionalität muss zuerst prüfen,
  ob sie mit den bestehenden Lesekommandos auskommt.
- **Config-Dateien werden nie ungefragt überschrieben.** `AppConfig.load()`
  / `WidgetConfig.load()` schreiben nur, wenn die Datei fehlt — niemals bei
  einem Parse-Fehler. Jedes neue Feld braucht eine `decodeIfPresent`-Zeile
  im manuellen `init(from:)`, sonst bricht das tolerante Decoding für
  ältere Configs. Beim Hinzufügen eines Feldes: Muster aus den
  bestehenden Zeilen kopieren (siehe `AppConfig.swift`/`WidgetConfig.swift`).
- **Zwei-Instanzen-Schutz**: `AppDelegate.applicationDidFinishLaunching`
  und `WidgetAppDelegate` beenden sich selbst, wenn bereits eine Instanz mit
  derselben Bundle-ID läuft. Nicht entfernen — sonst kommt der
  Config-Überschreib-Bug zurück.
- **Datenschutz beim Claude-Usage-Feature**: Aus `.credentials.json` wird
  ausschließlich `subscriptionType` gelesen, nie die OAuth-Tokens. Beim
  Cloud-Relay verlässt nur `{timestamp, model, token counts}` die
  Remote-Umgebung — nie Prompt-/Antworttext. Diese Grenze beim Erweitern
  nicht aufweichen.
- **Keine Anthropic-API für Nutzungsdaten verfügbar.** Vor dem Bau des
  Cloud-Relays wurde per `claude-api`-Skill geprüft: Die Admin Usage & Cost
  API und die Claude-Code-Analytics-API sind organisationsgebunden
  ("Admin API is unavailable for individual accounts") und bilden ohnehin
  nur API-Key-Abrechnung ab, nicht das 5-h-Limit eines persönlichen
  Pro/Max/Team-Abos. Der GitHub-Gist-Relay ist ein bewusster Workaround,
  keine Verlegenheitslösung — das nicht durch eine vermeintlich "einfachere"
  API ersetzen, ohne das erneut zu verifizieren.

## 5. Claude-Usage-Feature im Detail (zuletzt gebaut, am wenigsten "abgehangen")

Zeigt Token-Verbrauch im aktuellen 5-h-Fenster, Reset-Countdown, geschätzte
Kosten, aktuelles Modell — als Dashboard-Panel UND als Standalone-Widget.

- Parser: `Sources/XeneonEdgeKit/ClaudeUsage/ClaudeUsageReader.swift`
  (liest `~/.claude/projects/**/*.jsonl` + `.credentials.json`),
  `ClaudeUsageModels.swift` (Preistabelle, 5-h-Block-Logik).
- **Cloud-Relay** (neu, Commit `f5b581c`): Da eine Remote-/Cloud-Session
  (wie z. B. eine, die in dieser Umgebung läuft) ihr Transkript nie auf dem
  Mac hat, gibt es einen opt-in Relay über ein GitHub-Gist:
  - `.claude/hooks/publish-claude-usage.sh` — `Stop`-Hook, läuft in der
    Remote-Session, schreibt gefilterte Nutzungszeilen ins Gist (nur mit
    `XENEON_USAGE_GIST_ID` + `XENEON_USAGE_GIST_TOKEN` als Env-Vars, sonst
    No-Op).
  - `.claude/settings.json` — bindet den Hook ein.
  - `Scripts/setup-cloud-usage-relay.sh` — legt das Gist einmalig an
    (braucht lokal `gh auth login`; **wurde in dieser Session nicht
    ausgeführt**, da hier kein `gh` verfügbar war — der Nutzer muss das
    selbst lokal laufen lassen).
  - `Sources/XeneonEdgeKit/ClaudeUsage/CloudUsageFetcher.swift` — liest das
    Gist zurück (kein Auth-Token nötig für Lesen).
  - **Ungetestet mit echtem Gist/Token** — nur durch Unit-Tests mit
    kanonischen JSON-Antworten abgesichert (`CloudUsageFetcherTests` in
    `Tests/XeneonEdgeKitTests/ClaudeUsageTests.swift`). Ein echter
    End-to-End-Test (Hook → Gist → Fetch → Anzeige) steht noch aus.
- Config-Felder: `cloudGistID`, `cloudPollSeconds` (Default 90s, Minimum
  60s wegen GitHubs unauthentifiziertem Rate-Limit von 60 Anfragen/h/IP) in
  `AppConfig` und `WidgetConfig`.

### Offene Punkte / mögliche nächste Schritte

- [ ] **End-to-End-Test des Cloud-Relays** mit echtem Gist: Setup-Skript
  laufen lassen, Env-Vars in einer echten Remote-Session setzen, prüfen ob
  der Hook tatsächlich feuert und das Gist befüllt, prüfen ob das Mac-Widget
  es abruft und anzeigt.
- [ ] **Auf echter XENEON-EDGE-Hardware verifizieren** (Touch-Kalibrierung,
  DDC-Helligkeit, Bragi-Firmware-Abfrage) — bisher nur über
  `xeneonctl probe`-Rückmeldung des Nutzers denkbar, kein direkter
  Hardwarezugriff in dieser Session.
- [ ] Grafische Einstellungsoberfläche statt reinem JSON-Edit für Widgets
  (in der Roadmap der README erwähnt).
- [ ] Mehrfinger-Gesten, Intel-Mac-DDC (`IOI2C`), weitere Bragi-Properties
  (Orientierung, Panel-Info) — siehe README "Status / Roadmap".
- [ ] Der `gh: command not found`-Hinweis beim letzten Push (harmlos,
  Commit/Push erfolgreich) nicht weiter untersucht — kein Repo-Git-Hook
  dahinter gefunden, vermutlich Umgebungsartefakt dieser Session.

## 6. Wie man weiterarbeitet

```bash
git clone https://github.com/pascallink/MacOS-Corsair-Xenon.git
cd MacOS-Corsair-Xenon
git checkout claude/corsair-xenon-edge-macos-4jjvf9
swift build            # oder: ./Scripts/bundle-app.sh für App-Bundles
./Scripts/test.sh       # alle Unit-Tests (swift-testing, läuft ohne Xcode)
```

CI-Status prüfen: GitHub-MCP-Tools (`actions_list` mit
`method: list_workflow_runs`, `owner: pascallink`,
`repo: MacOS-Corsair-Xenon`) oder https://github.com/pascallink/MacOS-Corsair-Xenon/actions.

Nach jedem Push: CI abwarten (Debug-Build + Tests + Release + Bundling,
macOS-Runner, dauert ca. 60–90s), Ergebnis prüfen, bei Rot sofort fixen —
das war in dieser Session durchgehend die Praxis (siehe Commits 1, 6 oben:
beide Male wurde der rote CI-Lauf im nächsten Commit direkt behoben).

**Committen/Pushen**: In dieser Session wurde direkt auf den Feature-Branch
committet und gepusht (kein separater Review-Schritt), da der Nutzer das
so angestoßen hatte. Neue Session sollte beim Nutzer nachfragen, falls
unklar ist, ob das weiterhin gewünscht ist, oder ob z. B. PR-Reviews
abgewartet werden sollen.

## 7. Ton/Stil-Konventionen dieses Projekts

- Alle nutzerseitige Doku (README, INSTALL, docs/) ist **auf Deutsch**,
  da der Nutzer durchgehend Deutsch geschrieben hat.
- Code-Kommentare sind auf Englisch (Projektkonvention, GPL-Historie
  verweist auf englischsprachige Quellen).
- Risiken werden **explizit und ehrlich** benannt (z. B. INSTALL.md
  Abschnitt 5 "Risiken — ehrlich erklärt", docs/CLAUDE-USAGE-WIDGET.md
  "Grenzen (ehrlich)", "Datenschutz-Kompromiss — ehrlich"). Diesen Ton
  beibehalten, nicht beschönigen.
- Commit-Messages: ausführlich, erklären das WARUM eines Fixes, nicht nur
  das WAS (siehe bisherige Commits als Vorlage).
