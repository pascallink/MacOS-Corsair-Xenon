# MacOS-Corsair-Xenon

Natives SwiftPM-Paket (kein Xcode-Projekt, kein Monorepo) fuer den nativen
macOS-Treiber und das Dashboard des CORSAIR XENEON EDGE: Touch, DDC-
Helligkeit, Sensoren und ein Menueleisten-Widget fuer Claude-Session-Kosten.
Ziel-Plattform macOS 13+, ein einziges `Package.swift` im Root.

## ⚠️ Oberste Entwicklungsrichtlinie: Local First

- **Immer zuerst lokal arbeiten:** Code-Erstellung, Aenderungen und Tests
  laufen zwingend lokal auf Pascals Rechner, nie ungetestet gegen Remote.
- **Remote Repositories zweitrangig:** Ein GitHub-Repository existiert, nimmt
  aber keinen ungetesteten Code an - keine direkten Commits oder Pushes ohne
  vorherige lokale Validierung.
- **Isolierte Entwicklung:** lokale Branches je Feature/Bugfix.
- **Nach dem Push endet die Arbeit:** PR anlegen, Ergebnis melden, fertig.
  Nicht beobachten, nicht nachfassen, nicht anbieten es zu tun - Pascal kommt
  aktiv zurueck, wenn etwas ansteht. Siehe `.github/CI.md`.

## Targets

| Pfad | Scope | Zweck |
| --- | --- | --- |
| `Sources/XeneonEdgeKit/` | `kit` | Framework: Bragi-/HID-Transport, DDC-Helligkeit, Touch-Treiber und -Mapping, Claude-Session-Auswertung |
| `Sources/XeneonEdgeApp/` | `app` | Vollbild-Dashboard fuer das Edge (SwiftUI/AppKit) |
| `Sources/ClaudeUsageWidget/` | `widget` | Menueleisten-Widget fuer Claude-Session-Kosten |
| `Sources/xeneonctl/` | `ctl` | CLI: Geraetesteuerung ohne GUI-App |
| `Scripts/` | `scripts` | Build-, Test- und Bundle-Skripte |
| `.github/workflows/` | `ci` | Build- und Commitlint-Workflows - Details in [`.github/CI.md`](.github/CI.md) |
| Root/Doku | `repo` | Metadaten, Lizenz, commitlint, kein Produktivcode |

## Workspace-Befehle

| Zweck | Befehl |
| --- | --- |
| Build | `swift build` |
| Test (alles) | `./Scripts/test.sh` |
| Test (eine Suite) | `./Scripts/test.sh --filter <Suite>` |
| Release-Build | `swift build -c release` |
| App-Bundle | `./Scripts/bundle-app.sh release` |
| Commits pruefen | `npm install && npm run lint:commits` (prueft `origin/develop..HEAD`) |

Ein `.claude/hooks/session-start.sh` meldet je Sitzung die Toolchain und ob
`Testing.framework` gefunden wird, und installiert `node_modules` fuer
commitlint nur, wenn das Lockfile neuer ist als `node_modules`. Blockiert nie
eine Sitzung.

## Toolchain

Nur die **Command Line Tools**, kein volles Xcode (`xcode-select -p` ->
`/Library/Developer/CommandLineTools`). Daraus folgt: kein `xcodebuild`,
gebaut wird ausschliesslich mit `swift build`/`Scripts/`; und **kein XCTest**
- `XCTest.framework` wird nur mit Xcode ausgeliefert. Tests laufen deshalb
auf **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), dessen
`Testing.framework` den CLT beiliegt. SwiftPM verdrahtet die CLT-Kopie nicht
von selbst - `./Scripts/test.sh` kapselt die Such- und Runtime-Pfade und faellt
unter vollem Xcode automatisch auf ein schlichtes `swift test` zurueck, genau
das ruft auch `build.yml` auf. Details, Suiten-Landkarte und Geraete-Mocking
(Bragi/HID, DDC/IOKit, Touch) in [`.github/TESTS.md`](.github/TESTS.md).

## Repo-Regeln

- Deutsch in Kommentaren und UI-Texten, **ohne Umlaute** (`ue`, `ae`, `oe`,
  `ss`).
- Laufzeitcode getrennt von `Tests/` und `docs/` (fliegen aus dem
  Release-Bundle raus).
- Lizenz (`LICENSE`) und Projekt-Doku liegen im Root.
- Kein Linter (kein SwiftLint, kein SwiftFormat) - erfinde keinen. Wo eine
  Lint-Stufe erwartet wuerde, steht stattdessen die volle CI-Kette (siehe
  [`.github/CI.md`](.github/CI.md)).

## Workflow & QA-Regeln

Kette je Aufgabe: lokales Modell setzt um -> Opus reviewt -> lokales Modell
korrigiert. Umsetzung und Korrektur laufen ueber den Skill
`.claude/skills/lokale-umsetzung/` (aider + `ollama/qwen2.5-coder:14b`), Opus
zerlegt in Micro-Tasks, bewertet den Diff und verantwortet das Ergebnis. Die
Vorlagen stehen in [`.github/PROMPTS.md`](.github/PROMPTS.md) - dort auch die
Ausgaberegeln, das Micro-Task-Format und die Zuordnung der Subagents unter
`.claude/agents/`.

- **Umsetzung (lokal):** ein Micro-Task je Datei, hoechstens ~500 Zeilen,
  aider committet, Opus prueft den Diff. Zwei Fehlversuche am selben Micro-
  Task, eine Zieldatei ueber der Grenze (`DashboardView.swift`,
  `TouchDriver.swift`) oder mehr als eine Datei je Befund: Eskalation an den
  Subagenten `umsetzer` (Sonnet).
- **Subtask-Abschluss:** jede Umsetzung endet verpflichtend mit dem
  Review-Prompt (Stufe 1) fuer Opus.
- **QA & Review (Opus):** prueft Code-Logik, macOS-/Swift-Konformitaet
  (SwiftPM-Targets, Entitlements, IOKit-/DDC-Zugriffe, Thread-Sicherheit),
  Tests und Sicherheit; Ergebnis als Stufe-1-Fliesstext, kein JSON-Bericht.
- **Korrektur-Routing (Opus-Abschluss):** Opus haengt 0, 1 oder 2 Stufe-2-
  Prompts an, je Prompt genau eine Zieldatei. Jeder Befund geht zuerst lokal;
  bei Eskalation nur `STYLE`/`MINOR` an Haiku (`korrektur-style`), alles
  andere an Sonnet (`korrektur-logik`).
- **Uebergabe per Subagent:** Review laeuft als `reviewer` aus
  `.claude/agents/`; `umsetzer`, `korrektur-style` und `korrektur-logik` sind
  Eskalationspfad, nicht erste Wahl - gleiche Vorlagen, gleiche Kette.
- **Local First gilt in jeder Stufe:** jeder Agent committet lokal, Push nur
  nach Freigabe durch Pascal.

## Test-Kontext-Regeln

Details, Suiten-Landkarte und Runner: [`.github/TESTS.md`](.github/TESTS.md).

- **Dateiauswahl:** Bei Bugfix oder Feature nur die Quelldateien des
  betroffenen Targets und dessen Suite unter `Tests/XeneonEdgeKitTests/`
  oeffnen.
- **Testausfuehrung waehrend der Arbeit:** ausschliesslich
  `./Scripts/test.sh --filter <Suite>`. Kein Gesamtlauf, um zwischendurch zu
  schauen, ob noch alles gruen ist.
- **Vor dem finalen Commit:** genau einmal die volle CI-Kette `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh
  release`. Rot heisst zurueck in den Suite-Lauf, nicht in den naechsten
  Gesamtlauf.
- **Geraetezugriffe immer gemockt:** HID (Bragi), IOKit (DDC) und der Touch-
  Digitizer laufen in Tests ueber aufzeichnende Doubles, nie gegen das echte
  Geraet.

## Commit-Konventionen

`<typ>(<scope>): <Betreff im Imperativ, ohne Punkt>`, erzwungen per commitlint
(`.github/workflows/commitlint.yml`, Basis `origin/develop`).

- Typen: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`, `ci`.
- Scope = Spalte oben; `commitlint.config.js` liest sie aus den
  Ordnernamen unter `Sources/` (Kurzformen dort in `ALIASES`).
- Ein Commit, ein Scope; repoweit `chore(repo):`.
- **Header (erste Zeile) streng maximal 72 Zeichen** - `header-max-length` in
  `commitlint.config.js` blockt die CI sonst hart. Betreff im Zweifel kuerzen,
  Details in den Commit-Body.

## Systemanweisungen an Claude

- Workspace-Pfad: `/Volumes/Sources/tools/MacOS-Corsair-Xenon`.
- Agiere als erfahrener macOS/Swift-Entwickler.
- Fuehre **keine** `git push`-Befehle selbststaendig aus - Aenderungen werden
  immer erst lokal iteriert, Push nur nach Freigabe durch Pascal.
