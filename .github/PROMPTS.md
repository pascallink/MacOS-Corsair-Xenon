# Prompt-Vertrag fuer Modell-Uebergaben

Feste Vorlagen fuer die Uebergabe zwischen Sessions: das lokale Modell setzt um
und korrigiert, Opus reviewt. Prosa-Prompts driften und kosten Tokens - die Struktur steht
deshalb genau einmal hier, nicht in der Root-`CLAUDE.md`. Wer wann uebergibt,
steht dort ("Workflow & QA-Regeln"). Das Planungstemplate verweist auf diese
Datei: [`.github/PLAN.template.md`](PLAN.template.md). Umsetzung und Korrektur
laufen auf `ollama/qwen2.5-coder:14b` auf Pascals Rechner - Ablauf im Skill
`.claude/skills/lokale-umsetzung/`, Auftragsformat unter "Micro-Task". Die
Subagents unter `.claude/agents/` sind der Eskalationspfad, wenn das lokale
Modell an einem Schritt zweimal scheitert - siehe "Subagents" am Ende.

## Ausgaberegeln (gelten fuer jede Stufe)

- **Kein Wrapper:** keine Begruessung, kein "Hier ist ...", kein "Ich habe
  analysiert ...", keine Signatur, keine Nachbemerkung. Stufe 1 beginnt mit der
  Status-Ueberschrift, ein Folge-Prompt mit den drei Backticks.
- **Struktur strikt:** nur die definierten Abschnitte, Enums exakt wie notiert,
  kein Zusatzabschnitt. Was der Diff nicht belegt, wird nicht behauptet - lieber
  weglassen als raten.
- **Ohne Befund kein Satz:** was in Ordnung ist, bleibt unerwaehnt. Kein Absatz
  ueber Geprueftes und fuer sauber Befundenes, keine Messwerte ohne Befund,
  keine Randnotiz und nichts "bewusst nicht als Befund gefuehrt". Entweder es
  ist ein Befund und steht im Fliesstext, oder es faellt weg. Dass hingeschaut
  wurde, belegen die Befunde.
- **Kontext beschneiden:** vor der Uebergabe Kommentare, Leerzeilen und
  unveraenderte Bloecke entfernen. Weiter geht der Ausschnitt, nie die ganze
  Datei.
- **Kopierbar:** jeder Prompt fuer eine Folge-Session steht als reiner Text in
  einem eigenen Codeblock (drei Backticks, ohne Sprache), die Modellwahl als
  Ueberschrift davor. Nichts, was zum Prompt gehoert, steht ausserhalb.

## Stufe 0 - Umsetzungsauftrag (lokal)

Eingabe: ein Sub-Task aus dem Ausfuehrungsplan
([`.github/PLAN.template.md`](PLAN.template.md)). Ausgabe ist genau dieser
Block je Sub-Task. Er geht nicht mehr an einen Subagenten, sondern an eine
orchestrierende Opus-Sitzung, die ihn mit dem Skill `lokale-umsetzung` in
Micro-Tasks zerlegt und einzeln an das lokale Modell schickt. Unveraendert
weiterreichbar bleibt er trotzdem: bei Eskalation nimmt ihn der `umsetzer`.

```
task: implement_subtask
branch: <branch des sub-tasks, z. B. feature/issue-17-part-5-otrs>
base_branch: <branch, auf dem der sub-task aufsetzt, z. B. develop oder feature/issue-17-part-4-otrs>
target: <betroffenes Target, z. B. XeneonEdgeKit>
suite: <testsuite, z. B. TouchMappingTests>

Ziel: <zwei bis drei Saetze: was danach geht, was vorher nicht ging.>

Dateiebene:
- Zu erstellen: <pfade, komma-getrennt, sonst "-">
- Zu aendern: <pfade, komma-getrennt>

Aufgaben:
1. <konkrete Anweisung mit Zielzustand>
2. <konkrete Anweisung mit Zielzustand>

Definition of Done:
- [ ] <pruefbares Kriterium, kein "sauber umgesetzt">
- [ ] Neue und bestehende Tests laufen gruen.

Constraints:
- Vor der ersten Aenderung `git fetch origin <branch> <base_branch>` und
  `git checkout <branch>`. Existiert der Branch noch nicht, mit
  `git checkout -b <branch> origin/<base_branch>` von dessen aktuellem Stand
  anlegen. Kein anderer Branch, Commit lokal - Push nur nach Freigabe durch
  Pascal (Local First, Root-`CLAUDE.md`).
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Waehrend der Arbeit nur `./Scripts/test.sh --filter <suite>`.
- Genau einmal vor dem finalen Commit die CI-Kette: `swift build &&
  ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release`.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis und
  was bewusst offen blieb.
```

- **Branch-Vorgabe schlaegt Default** - hier haerter als bei Stufe 2, weil der
  Sub-Task in einem Stapel sitzt (PR 2 auf PR 1, PR 3 auf PR 2). Fehlt der
  Branch im Block, nimmt eine Cloud-Sitzung ihren `claude/...`-Branch auf
  `develop`: die Arbeit landet neben dem PR, auf einem Stand ohne die Vorstufe.
- **Stufe 0 nimmt den Branch, Stufe 2 den SHA - und das ist kein Versehen.**
  Eine Korrektur muss auf exakt den reviewten Stand, deshalb dort `base_sha`.
  Ein Sub-Task muss auf den *aktuellen* Stand seiner Vorstufe, denn die hat
  zwischen Plan und Start ihre eigene Korrekturrunde hinter sich. Ein SHA aus
  dem Plan wuerde genau diese Fixes abschneiden - und fuer jeden Sub-Task
  ausser dem ersten steht er zum Planungszeitpunkt ohnehin nicht fest.
  Deshalb loest der `umsetzer` den Base beim Auschecken selbst auf: der Plan
  bleibt vollstaendig, niemand traegt vor dem Start etwas nach.
- **Der Block steht fuer sich.** Der `umsetzer` startet kalt und sieht nur
  diesen Text, nicht den uebrigen Plan. Was nicht drinsteht, existiert fuer ihn
  nicht.
- **Ein Sub-Task, ein Target, ein Scope.** Passt der Auftrag nicht in einen
  Commit-Scope aus der Root-`CLAUDE.md`, ist er zu gross geschnitten - teilen,
  bevor er startet.
- Repo- und Test-Kontext-Regeln bleiben bindend, auch wenn der Auftrag sie
  nicht wiederholt.

## Stufe 1 - Review-Ergebnis (Opus)

Eingabe: Diff gegen `develop`, PR-Titel, PR-Beschreibung, Branch und Head-SHA.
Ausgabe: Markdown-Fliesstext, kein JSON-Bericht.

```
## Review PR #<nummer> (<branch> @ <head-sha>) - <APPROVED | CHANGES_REQUESTED>

<Ein Absatz je Befund: was bricht, warum, und was daraus folgt. Datei- und
Zeilenangaben inline als `datei.swift:18`. Keine Tabelle, keine Befundliste,
kein Wiederholen des Diffs. Keine Befunde, kein Absatz - dann folgt direkt
die Empfehlung.>

**Empfehlung:** <ein Satz zur Richtung der Korrektur.>
```

- Status ist `CHANGES_REQUESTED`, sobald ein Befund `CRITICAL` oder `MAJOR` ist,
  sonst `APPROVED`.
- Schweregrade (`CRITICAL`, `MAJOR`, `MINOR`) und Typen (`SECURITY`, `BUG`,
  `PERFORMANCE`, `STYLE`) gelten weiter: sie benennen den Befund im Fliesstext
  und steuern das Routing der Stufe 2.
- Keine Befunde heisst: kein Korrektur-Prompt, das Review endet nach der
  Empfehlung.
- Branch und Head-SHA stehen in der Ueberschrift, damit jede Stufe 2 sie
  erbt. Ohne diesen Anker korrigiert die Folge-Session auf irgendeinem Stand.

## Stufe 2 - Korrektur (lokal)

Direkt im Anschluss an Stufe 1: 0, 1 oder 2 Prompts, je Prompt genau **eine**
Zieldatei, jeweils mit dem Ziel als Ueberschrift davor
(`### Korrektur-Prompt -> lokal`, bei Eskalation `-> Sonnet` bzw. `-> Haiku`).

```
task: apply_refactoring
branch: <branch des PR, z. B. feature/issue-49-part-1>
base_sha: <head-sha, auf dem das Review basiert>
target_file: <pfad/zur/datei>

Kontext: <zwei bis drei Saetze: was defekt ist und warum.>

Aufgaben:
1. <konkrete Anweisung mit Zielzustand>
2. <konkrete Anweisung mit Zielzustand>

Constraints:
- Vor der ersten Aenderung `git fetch origin <branch>` und
  `git checkout <branch>`. Kein neuer Branch, Commit lokal - Push nur nach
  Freigabe durch Pascal (Local First, Root-`CLAUDE.md`).
- Passt `target_file` auf diesem Branch nicht zum Kontext oben: abbrechen und
  melden. Nichts nachbauen, nichts erfinden.
- Deutsch ohne Umlaute in Kommentaren und UI-Texten.
- Bestehende Struktur beibehalten, wenn nicht ausdruecklich anders verlangt.
- Vor dem Commit die CI-Kette: `swift build && ./Scripts/test.sh &&
  swift build -c release && ./Scripts/bundle-app.sh release`.
- Nur die geaenderte Datei ausgeben, kein Fliesstext.
- Abschluss melden: Branch, Commit-SHA, geaenderte Dateien, Testergebnis.
```

- **Routing:** jeder Befund geht zuerst lokal, unabhaengig von Schweregrad und
  Typ - der Prompt wird dazu in Micro-Tasks zerlegt ("Micro-Task"). Zwei
  Ausnahmen gehen direkt an einen Subagenten, ohne lokalen Versuch: eine
  Zieldatei ueber ~500 Zeilen (`DashboardView.swift`, `TouchDriver.swift`) und
  ein Befund, der mehr als eine Datei anfassen muss. Beides sprengt das
  whole-Edit-Format des lokalen Modells.
- **Eskalation:** nach zwei Fehlversuchen an demselben Micro-Task ist Schluss.
  `STYLE`/`MINOR` (Formatierung, Umlaute, Doku- und Typ-Fixes) geht dann an
  `korrektur-style` (Haiku), alles andere - `BUG`, `SECURITY`, `PERFORMANCE`,
  Testanpassungen, gemischte Korrekturen - an `korrektur-logik` (Sonnet). Der
  eskalierte Prompt nennt zusaetzlich, was lokal gescheitert ist, damit der
  Agent nicht denselben Weg nochmal geht.
- **Branch-Vorgabe schlaegt Default:** eine Cloud-Sitzung bekommt vom Harness
  einen eigenen `claude/...`-Branch auf aktuellem `develop`. Nennt der Prompt
  den PR-Branch nicht, gewinnt diese Vorgabe - die Korrektur landet am PR
  vorbei, im schlimmsten Fall auf einem Stand ohne die reviewte Datei.
- **Ohne Rueckmeldung kein Abschluss:** Stufe 1 beobachtet nicht nach (siehe
  Root-`CLAUDE.md`). Bleibt die Abschlussmeldung aus, gilt die Korrektur als
  nicht geliefert, nicht als erledigt.
- Repo-Regeln bleiben bindend, auch wenn der Prompt sie nicht wiederholt.

## Micro-Task - Auftrag an das lokale Modell

Die Ebene unter Stufe 0 und Stufe 2: ein Stufe-0- oder Stufe-2-Block wird in
drei bis fuenf Micro-Tasks zerlegt, jeder eine Aenderung an genau einer Datei.
Der Text unten geht als `local_task.md` per `--message-file` an aider (headless:
`--yes --no-pretty`), also direkt an `ollama/qwen2.5-coder:14b`. Ablauf, Aufruf, Bewertung und Revert
stehen im Skill `.claude/skills/lokale-umsetzung/SKILL.md` - hier steht nur
das Format.

```
Aufgabe: <ein Satz, was danach funktioniert und vorher nicht.>

Datei: Sources/<Target>/<Pfad>.swift

Aenderung:
1. <Konkrete Anweisung mit Zielzustand: welche Funktion, welches Verhalten,
   welcher Rueckgabewert in welchem Fall.>
2. <Naechste Anweisung, gleiche Praezision.>

Erwartetes Verhalten nach der Aenderung:
- Eingabe <x> ergibt <y>.
- Eingabe <leer oder ungueltig> ergibt <definierter Fall, kein Crash>.

Nicht aendern:
- Keine anderen Dateien anfassen, auch nicht Tests.
- Bestehende Funktionsnamen, Signaturen und Zugriffsmodifikatoren bleiben wie
  sie sind.
- <Weitere Stelle, die in der Naehe liegt und nicht gemeint ist.>

Vorgaben fuer den Code (bindend):
- Swift 5.9, keine neuen Package-Abhaengigkeiten.
- Bestehende Signaturen und Zugriffsmodifikatoren (public/internal/private)
  bleiben, wenn nicht ausdruecklich anders verlangt.
- Beruehrt die Aenderung eine Testdatei: `import Testing` statt XCTest - auf
  diesem System ohne Xcode ist XCTest nicht lauffaehig.
- Kommentare und sichtbare Texte auf Deutsch, ohne Umlaute: `ue`, `ae`, `oe`,
  `ss` statt der Umlaute und des scharfen s.
- Nur die genannte Datei ausgeben, vollstaendig, ohne Auslassungszeichen und
  ohne Kommentare wie "unveraendert" oder "Rest wie vorher".
```

- **Pfade sind bereits repo-relativ.** Aider laeuft im Repo-Root, das hier
  zugleich der Paketordner ist - anders als im Monorepo webkit-ext braucht ein
  Pfad kein Praefix: `Sources/XeneonEdgeKit/Touch/TouchMapping.swift` ist schon
  der Pfad, den auch `git status` zeigt.
- **Der Vorgaben-Block bleibt wortgleich in jedem Micro-Task.** Aider liest
  keine `CLAUDE.md` - was nicht im Auftrag steht, haelt das Modell nicht ein.
  Das ist der Unterschied zu einem Subagenten, der die Repo-Regeln ohnehin
  kennt: hier ist Wiederholung Pflicht, nicht Redundanz.
- **Zielzustand statt Absicht.** "Fehlerbehandlung verbessern" produziert
  Erfindungen. Welche Funktion bei welcher Eingabe was zurueckgibt, produziert
  Code.
- **Verbote gehoeren in den Auftrag.** Ohne den Abschnitt "Nicht aendern"
  raeumt das Modell in der Nachbarschaft mit auf.
- **Kein Wrapper, kein Kontext ueber die Kette.** Das Modell sieht nur diesen
  Text und die Repo-Map. Verweise auf Stufen, Issues, Reviews oder Dateien,
  die es nicht geoeffnet hat, sind toter Ballast.
- **Tests schreibt das lokale Modell nicht.** Sie sind ein eigener Micro-Task
  oder bleiben bei der orchestrierenden Sitzung - Wissen ueber bestehende
  Testsuiten und Mocks steht in keinem Auftrag, der in ein 14B-Fenster passt.

## Subagents

`.claude/agents/` haelt je Stufe einen Agenten, das Frontmatter setzt Modell
und Werkzeuge, der Rumpf die Rolle. Umsetzung und Korrektur laufen im
Normalfall lokal - die beiden Korrektur-Agenten und der `umsetzer` sind
Eskalationspfad, nicht erste Wahl. Nur das Review ist unveraendert Opus.

| Stufe | Ziel | Modell | Zustaendig fuer |
| --- | --- | --- | --- |
| 0 Umsetzung | Skill `lokale-umsetzung` | Qwen 14B lokal | Micro-Tasks eines Subtasks, eine Datei je Lauf |
| 0 Eskalation | `umsetzer` | Sonnet | Subtask ueber der Eignungsgrenze oder zweimal lokal gescheitert |
| 1 Review | `reviewer` | Opus | Stufe 1 plus 0 bis 2 Folge-Prompts, ohne Edit |
| 2 Korrektur | Skill `lokale-umsetzung` | Qwen 14B lokal | jeder Befund, zerlegt in Micro-Tasks |
| 2 Eskalation | `korrektur-style` | Haiku | `STYLE`/`MINOR`, eine Datei, kein Verhalten |
| 2 Eskalation | `korrektur-logik` | Sonnet | alles andere, Testanpassung erlaubt |

- **Diese Datei bleibt die Quelle der Formate.** Die Agenten wiederholen sie
  nicht, sie verweisen darauf - der `reviewer` liest sie zu Beginn seines Laufs.
  Aendert sich ein Format, aendert es sich hier und nirgends sonst.
- **Der Rumpf traegt nur, was hier nicht steht:** Rolle, Scope-Grenzen,
  Abbruchbedingung, Ausgabeform. Repo- und Test-Kontext-Regeln kommen aus der
  Root-`CLAUDE.md` und gelten fuer jeden Agenten ohnehin.
- **Werkzeuge beschneiden ist Teil des Vertrags.** Der `reviewer` hat kein
  `Edit`, die Korrektur-Agenten kein `Glob` - was ein Agent nicht hat, kann er
  auch nicht an Kontext verbrennen.
- **Ein Agent startet kalt.** Er kennt die rufende Sitzung nicht, der Auftrag
  muss vollstaendig sein. Deshalb steht der Anker in jedem Block: `branch`
  plus `base_branch` bei Stufe 0, `branch` plus `base_sha` bei Stufe 2. Ohne
  ihn arbeitet der Agent auf irgendeinem Stand.
- **Parallel nur getrennt.** Zwei Agenten gleichzeitig auf demselben Branch
  kollidieren im Arbeitsbaum - entweder nacheinander oder je in einem eigenen
  Worktree. Fuer die lokale Umsetzung gilt das doppelt: aider committet in den
  Arbeitsbaum, in dem es gestartet wurde, und ein zweiter Lauf daneben nimmt
  die halbfertige Aenderung des ersten mit in seinen Commit.
- **Das lokale Modell ist kein Agent.** Es hat keine Werkzeuge, keinen
  Branch-Auftrag und keine Abschlussmeldung - `git`, Tests und die Bewertung
  des Diffs bleiben bei der orchestrierenden Sitzung. Deshalb steht der Ablauf
  im Skill und nicht im Auftrag: was der Micro-Task nicht abdeckt, deckt
  niemand ab.
