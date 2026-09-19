**Rolle & Kontext**
Du agierst als Senior Lead Architect. Deine Aufgabe ist es, das nachfolgende GitHub Issue #[ISSUE_NUMBER] in eine Reihe von extrem fokussierten, aufeinander aufbauenden Sub-Tasks zu zerlegen. Die Sub-Tasks werden sequenziell im Rahmen einer **Stacked PRs Architecture** umgesetzt: eine orchestrierende Sitzung zerlegt je Sub-Task mit dem Skill `lokale-umsetzung` in Micro-Tasks für das lokale Modell (aider), bei Eskalation übergibt sie an den `umsetzer`-Subagenten aus `.claude/agents/`; danach läuft die Kette aus Review (Stufe 1) und Korrektur (Stufe 2) weiter. Welches Modell welche Stufe fährt, steht in `.github/PROMPTS.md` und im Frontmatter der Agenten - der Plan nennt Rollen, keine Modelle.

**Ziel**
Erstelle einen detaillierten Ausführungsplan für Issue #[ISSUE_NUMBER]. Jeder Sub-Task entspricht genau einem Branch und einem Pull Request (PR 1 basiert auf `develop`, PR 2 auf PR 1, PR 3 auf PR 2 usw.).

**Regeln für die Erstellung der Sub-Tasks**
1. **Kontext-Fokus:** Jeder Sub-Task muss atomar sein und sich in drei bis fünf Micro-Tasks à eine Datei (≤ ~500 Zeilen) zerlegen lassen; was das nicht kann, muss im Kontextfenster eines einzelnen `umsetzer`-Laufs ohne Kontextverlust abgeschlossen werden können.
2. **Keine Breaking Changes:** Jeder Schritt muss eine voll funktionsfähige, kompilierbare und testbare Zwischenstufe des Projekts darstellen.
3. **Klare Instruktion:** Die Anweisungen für den Agenten müssen deterministisch und eindeutig sein (welche Dateien, welche Formate, welche Test-Befehle).

**Struktur für jeden Sub-Task im Plan**

**Sub-Task [X]: [Kurzer, prägnanter Name]**
* **Git Branch:** `feature/issue-[ISSUE_NUMBER]-part-[X]` (Base Branch: `[Name des vorherigen Branches oder develop]`)
* **Scope / Ziel:** Kurze Beschreibung des Ziels.
* **Dateiebene:**
  * Zu erstellen: `[Pfade/Dateinamen]`
  * Zu ändern: `[Pfade/Dateinamen]`
* **Schritt-für-Schritt Anweisungen für die Umsetzung (Micro-Tasks bzw. `umsetzer`):**
  1. Erstelle/Passe die Logik in `[Datei]` an.
  2. Schreibe/Erweitere Tests in `[Testsuite unter Tests/XeneonEdgeKitTests/]`.
  3. Führe den Test-Befehl aus: `./Scripts/test.sh --filter [Suite]`.
* **Definition of Done (Acceptance Criteria):**
  * [ ] Code kompiliert und entspricht den Projekt-Standards.
  * [ ] Neue und bestehende Tests laufen grün durch.
  * [ ] Git Commit lokal ausgeführt, Push nur nach Freigabe durch Pascal (Local First).
* **Umsetzungsauftrag (Stufe 0):** *(Nach der Stufe-0-Vorlage in [`.github/PROMPTS.md`](PROMPTS.md) - reiner Text in einem eigenen Codeblock, drei Backticks, ohne Sprache. `branch` und `base_branch` gehören in den Block selbst: das lokale Modell wie der `umsetzer` starten kalt und sehen nur diesen Text, nicht den übrigen Plan.)*

## Abschluss jeder Session: Review-Prompt fuer Opus

Jeder Sub-Task endet nicht mit dem Push. Die umsetzende Session gibt zum
Schluss **einen Review-Prompt zum Kopieren aus**, mit dem der PR an Opus
weitergereicht wird. Der Auftrag an die Session lautet woertlich:

> Erstelle einen Review-Prompt fuer Opus, der die Code-Aenderungen, deine
> Designentscheidungen, potenzielle Edge Cases und 3-4 konkrete Pruefpunkte
> fuer diesen PR zusammenfasst.

Form der Ausgabe - ein einzelner Codeblock, sonst nichts drumherum:

```text
Review von PR "<Titel>" (Branch feature/issue-[ISSUE_NUMBER]-part-<X>, Base <Base>).
Projekt: MacOS-Corsair-Xenon, Swift 5.9 / SwiftPM, macOS 13+.

Aenderungen
- <Datei>: <was und warum, ein Satz>
- ...

Designentscheidungen
- <Entscheidung>: <Alternative, die verworfen wurde, und der Grund>
- ...

Edge Cases, die ich bedacht habe
- <Fall> -> <Verhalten>
- ...

Bitte pruefe gezielt
1. <konkreter Pruefpunkt mit Datei und Funktion>
2. <...>
3. <...>
(4. <...>)

Bekannte Luecken: <was bewusst offen blieb, oder "keine">
```

Regeln fuer diesen Prompt:

* **Beruehrte Testsuiten nennen.** Opus soll wissen, welche Suiten unter
  `Tests/XeneonEdgeKitTests/` gelaufen sind und welche bewusst zu blieben.
* **Selbsttragend.** Opus sieht den Chatverlauf der Session nicht. Jede
  Behauptung nennt Datei und Funktion.
* **Pruefpunkte sind Fragen an den Code, keine Zusammenfassung.** Gut:
  "gibt `DDCService.setBrightness` bei einem Timeout des I2C-Bus einen
  definierten Fehler zurueck?". Schlecht: "bitte die neuen Tests anschauen".
* **Ehrlich bei den Luecken.** Was nicht getestet ist, steht drin - erfundene
  Sicherheit kostet die Runde.
* Kein Selbstlob, keine Wiederholung des Plans, hoechstens 40 Zeilen.

**Korrektur-Routing:** Opus entscheidet nach dem Review, ob und wie viele
Korrektur-Prompts folgen - 0, 1 oder 2, je Prompt genau eine Zieldatei. Nur
Triviales (Formatierung, Umlaute, Doku, Typos) geht an Haiku, alles mit
Logik, Architektur oder Tests darin an Sonnet. Form und Ausgabeort dieser
Korrektur-Prompts stehen im folgenden Abschnitt.

**Format des PR-Review-Ergebnisses (Opus)**

Das Review am Sessionende wird als kurzer Markdown-Fliesstext ausgegeben, nicht
als JSON-Bericht:

1. Ueberschrift mit PR-Nummer und Status: `APPROVED` oder `CHANGES_REQUESTED`.
2. Zwei bis drei Absaetze: was bricht, warum, und die empfohlene Richtung.
   Datei- und Zeilenangaben inline (`datei.swift:18`), keine Tabelle, keine
   Aufzaehlung aller Befunde als Liste.
3. Danach 0, 1 oder 2 Korrektur-Prompts, je Prompt genau eine Zieldatei, jeder
   als reiner Text in einem eigenen Codeblock (drei Backticks, ohne Sprache),
   die Modellwahl als Ueberschrift davor. Ausserhalb der Codebloecke steht
   nichts, was zum Prompt gehoert.

Routing wie in [`.github/PROMPTS.md`](PROMPTS.md): jeder Befund geht zuerst
lokal; bei Eskalation nur `STYLE`/`MINOR` an Haiku, alles andere an Sonnet. Die inhaltlichen Felder eines Korrektur-Prompts
(Zieldatei, Befunde, Constraints, Ausgabeformat) folgen der Stufe-2-Vorlage
dort - als Klartext, nicht als JSON-Objekt.

---

### Issue #[ISSUE_NUMBER] Details & Technische Vorgaben

#### Beschreibung
[Hier die Problembeschreibung aus dem GitHub Issue einfügen]

#### Anforderungen & User Story
[Hier funktionale und nicht-funktionale Anforderungen einfügen]

#### Technische Umsetzungshinweise
* **Ziel-Umgebung:** macOS 13+, nur Command Line Tools (kein Xcode, kein XCTest).
* **Architektur / Module:** [Relevante Pfade, z. B. Sources/XeneonEdgeKit/DDC/, Sources/XeneonEdgeApp/, etc.]

#### Zu erarbeitende Sub-Tasks:
- [Sub-Task 1 Stichpunkt]
- [Sub-Task 2 Stichpunkt]

**Technische Leitplanken für die Umsetzung:**
* [Leitplanke 1, z. B. IOKit-/DDC-Zugriffe, Thread-Sicherheit, Race Conditions]
* [Leitplanke 2, z. B. Error-Handling, Fallbacks, Geraete-Mocking ohne echte Hardware]

---

Analysiere das oben beschriebene Issue #[ISSUE_NUMBER] und erstelle jetzt den vollständigen Ausführungsplan gemäß den definierten Vorgaben. Erzeuge alle Sub-Tasks nacheinander inklusive aller Details, Checklisten und der einsatzbereiten Umsetzungsaufträge nach der Stufe-0-Vorlage.
