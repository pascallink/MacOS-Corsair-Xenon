---
name: lokale-umsetzung
description: Delegiert Code-Implementierung an das lokale Modell ollama/qwen2.5-coder:14b via aider - Micro-Task schreiben, aider aufrufen, Diff bewerten, bei Fehlern zuruecksetzen und neu ansetzen. Nutze diesen Skill fuer Stufe 0 (Umsetzung eines Sub-Tasks) und Stufe 2 (Korrektur eines Befunds) der Kette aus .github/PROMPTS.md, statt an die Subagents umsetzer, korrektur-logik oder korrektur-style zu delegieren. Nicht fuer Review, Planung oder Release.
---

# Lokale Umsetzung (aider + Qwen 14B)

Implementierung laeuft auf Pascals Rechner, nicht auf einem Anthropic-Modell.
Du zerlegst, beauftragst, bewertest und verantwortest das Ergebnis - der Code
selbst kommt von `ollama/qwen2.5-coder:14b`.

Rollen der Kette bleiben wie in [`.github/PROMPTS.md`](../../../.github/PROMPTS.md):
Opus plant und reviewt, die Umsetzung ist delegiert. Neu ist nur, an wen.

## Eignungsgrenze - zuerst pruefen

Aider faehrt dieses Modell im **whole**-Edit-Format: das Modell gibt jede
angefasste Datei komplett neu aus. Das begrenzt den Einsatz hart.

- **Bis ~500 Zeilen je Zieldatei:** delegieren.
- **Darueber** (`Sources/XeneonEdgeApp/DashboardView.swift` 704,
  `Sources/XeneonEdgeKit/Touch/TouchDriver.swift` 638) gibt das Modell die
  Datei nicht vollstaendig zurueck - es kuerzt stillschweigend. Entweder den
  Micro-Task so schneiden, dass er eine neue oder kleine Datei trifft, oder
  gar nicht delegieren und direkt an `korrektur-logik` bzw. `umsetzer` geben.
- **Eine Zieldatei je Lauf.** Zwei Dateien in einem Micro-Task heisst zwei
  vollstaendige Ausgaben - das Modell verliert dabei eine davon.
- Nicht delegieren: `Package.swift`-Targetdefinitionen, `Resources/Info.plist`
  und `LaunchAgents/*.plist`, Testfixtures, alles mit Release-Bezug
  (`Scripts/bundle-app.sh`, `Scripts/install.sh`).

## Ablauf

Das Protokoll ist bewusst eng: jeder Schritt hat einen definierten Eingang und
Ausgang, und nur der Ausgang landet im Kontext. Der Grund, lokal zu delegieren,
ist Token-Ersparnis - ein Handshake, der die ganze Datei dreimal in den
Kontext zieht, hebt sie wieder auf.

| Schritt | Was in den Kontext kommt | Was nicht |
| --- | --- | --- |
| 1 Vorbedingung | `git status --short` (leer) | - |
| 2 Kontext lesen | betroffene Region per `grep -n` / `sed -n` | die ganze Datei |
| 3 Auftrag | nichts (Heredoc nach `local_task.md`) | - |
| 4 Aufruf | Exit-Code, Zeitstempel | aiders stdout (geht in `.aider.run.log`) |
| 5 Bewerten | `git show --stat`, Diff, Swift-Grep, Testergebnis | Modell-Prosa, Testprotokoll |
| 6 Amend / Reset | `git log --oneline -1` | - |

### 1. Vorbedingung und Zerlegen

Arbeitsbaum sauber (`git status --short` leer) - sonst nimmt aider fremde
Aenderungen mit in seinen Commit und der Reset in Schritt 6 trifft auch sie.

Ein Micro-Task ist eine Aenderung an genau einer Datei, die in einen Absatz
Anweisung passt und deren Ergebnis am Diff pruefbar ist. Aus einem Sub-Task
werden typischerweise drei bis fuenf Micro-Tasks. Reihenfolge festlegen, dann
strikt nacheinander - aider committet in denselben Arbeitsbaum.

### 2. Kontext lesen - nur die Region

Fuer einen praezisen Auftrag brauchst du die Stelle, nicht die Datei:
`grep -n '<symbol>' <datei>` und `sed -n '<von>,<bis>p' <datei>` um die
Treffer herum. Die ganze Datei nur, wenn sie unter ~80 Zeilen hat oder der
Task sie strukturell umbaut. Zeilenzahl der Datei (`wc -l`) gehoert immer
dazu - sie entscheidet ueber die Eignungsgrenze.

### 3. Micro-Task schreiben

Per Heredoc nach `local_task.md` im **Repo-Root**, Format unter "Micro-Task"
in [`.github/PROMPTS.md`](../../../.github/PROMPTS.md). Die Datei wird vor
jedem Lauf ueberschrieben, nicht angehaengt - aider schickt ihren gesamten
Inhalt. Nicht zuruecklesen, du hast sie gerade geschrieben.

Aider laeuft ohnehin im Repo-Root - anders als bei einem Monorepo mit
Projektordnern braucht ein Pfad hier kein Praefix: `Sources/XeneonEdgeKit/...`
ist schon der Pfad, den auch `git status` zeigt. Was am haeufigsten
schiefgeht: der Vorgaben-Block, der wortgleich in jeden Auftrag gehoert -
aider liest keine `CLAUDE.md`.

### 4. Aufrufen - headless, Ausgabe ins Log

```
aider <zieldatei> --model ollama/qwen2.5-coder:14b --message-file local_task.md --yes --no-pretty > .aider.run.log 2>&1
```

Vom Repo-Root, genau dieser Befehl, `<zieldatei>` als repo-relativer Pfad
(z. B. `Sources/XeneonEdgeKit/Touch/TouchMapping.swift`). **Headless-Modus
ist Pflicht:** `--yes` (Auto-Bestaetigung) und `--no-pretty` (reiner
Text-Output), weil aider als Hintergrundprozess ohne menschliche
Tastatureingabe laeuft - ohne sie blockiert der Prozess an einer Rueckfrage
oder verstopft die Ausgabe mit Steuerzeichen.

**Die Umleitung ins Log ist Teil des Befehls.** Aider echot im whole-Format
die komplette Datei nach stdout - das waeren ~2k Tokens je Lauf im Kontext,
die nichts sagen, was `git show` nicht besser sagt. `.aider.run.log` ist per
`.gitignore` (`.aider*`) unsichtbar und wird nur bei einem Fehlschlag gelesen
(Schritt 6).

Start mit `run_in_background: true`, sofort danach `TaskOutput` (block,
Timeout 600000) - ein Lauf dauert 7 bis 9 Minuten fuer eine 180-Zeilen-Datei
und sprengt das Bash-Timeout. Sequenziell bleibt es trotzdem: kein zweiter
Micro-Task, bevor der erste durch ist. Zurueck kommen nur Exit-Code und
Zeitstempel; `exit=0` heisst "aider ist durchgelaufen", nicht "der Diff
stimmt".

**Warnungen im Log sind erwartet:** `Warning: Input is not a terminal (fd=0).`
beim Start und `Summarization failed ... cannot schedule new futures after
shutdown` am Ende sind bei programmatischer Ausfuehrung normal, bedeuten
keinen Fehler und unterbrechen nichts. Nicht darauf reagieren, nicht
abbrechen.

Drei Rueckfragen, die `--yes` sonst falsch beantworten wuerde, sind ueber die
Konfiguration im Repo-Root abgestellt - ohne sie kippt der Lauf:

- `.aider.conf.yml` - `OLLAMA_API_BASE`, Modell-Warnungen aus,
  `detect-urls: false` (eine Beispiel-URL im Auftrag wuerde sonst gescrapt,
  und dafuer installiert aider ungefragt Playwright).
- `.aider.model.settings.yml` - Kontextfenster 32k, whole-Format.
- `.aiderignore` - die beiden Dateien ueber der Eignungsgrenze plus Tests und
  Doku. Nennt ein Kommentar oder die Modellantwort einen Dateinamen aus dem
  Repo, fragt aider "Add file to the chat?", `--yes` bejaht, **die fertige
  Ausgabe wird verworfen** und eine zweite Runde mit der Datei im Kontext
  startet. Ignorierte Dateien sind nicht erwaehnbar.

Laeuft der Aufruf ins Leere: `ollama list` (Modell da?),
`curl -s localhost:11434/api/tags` (Server laeuft?), `ollama ps` (rechnet
gerade?).

### 5. Bewerten - am Diff, nicht an der Prosa

Genau diese Befehle, in dieser Reihenfolge, jeder mit gefilterter Ausgabe:

```
git log --oneline -1                      # neuer Commit da? sonst Schritt 6
git show --stat HEAD --format=            # genau eine Datei, plausible +/-?
git show HEAD --format=                   # der Diff selbst
grep -nE '\bimport XCTest\b' <zieldatei>                          # falsches Testframework
perl -ne 'print "$.:$_" if /[^\x00-\x7F]/' <zieldatei>            # Nicht-ASCII: Umlaute, scharfes s
./Scripts/test.sh --filter <Suite> 2>&1 | tail -10
```

Anders als bei `node --test` gibt es bei swift-testing kein zweizeiliges
`pass`/`fail`-Muster zum Filtern - `tail -10` zeigt die Zusammenfassung
(`Test run ... passed` bzw. `Test run ... failed`) im Klartext. Erst bei
einem Fehlschlag das vollstaendige Protokoll lesen.

Fehlerhaft ist ein Lauf schon dann, wenn eine dieser Fragen mit ja
beantwortet wird - nicht erst, wenn Tests rot sind:

- Fehlen Teile der Datei, die vorher da waren? (`--stat`: Minus-Zeilen weit
  ueber dem, was der Task entfernt. Der typische whole-Format-Fehler.)
- Steckt eine weitere Datei im Commit, die der Task nicht genannt hat?
- Neue Package-Abhaengigkeit, geaenderte Signatur oder Zugriffsmodifikator,
  `import XCTest` statt `import Testing`, Umlaute?
- Kommentare, die den Auftrag nachplappern statt das Warum zu erklaeren?

Bei einem Verhalten, das kein Test abdeckt, ein einzeiliger Beleg am
Beispiel aus "Erwartetes Verhalten" - nicht die Testdatei erweitern, das ist
ein eigener Schritt.

### 6. Amend oder Reset

**Richtig:** Commit-Message auf die Konvention ziehen. Aider formuliert sie
selbst, mit demselben 14B-Modell - im Test beschrieb sie einmal das Gegenteil
des Diffs. Das Amend ist deshalb Pflicht, nicht Kosmetik:

```
git commit --amend -m "<typ>(<scope>): <betreff im imperativ, max 72 zeichen>" \
  -m "Umgesetzt von ollama/qwen2.5-coder:14b via aider." \
  -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

Dann der naechste Micro-Task ab Schritt 2.

**Falsch:** der Aider-Commit ist lokal und nicht gepusht - er wird verworfen,
nicht revertiert:

```
git reset --hard HEAD~1
```

Kein Commit entstanden (Schritt 5, erste Zeile)? Dann `grep -nE
'Add file|Add URL|Error|Traceback' .aider.run.log` - mehr vom Log nur, wenn
das nichts ergibt. Danach `local_task.md` schaerfen: die *eine* Stelle
benennen, an der das Modell abgebogen ist. Denselben Task unveraendert erneut
zu schicken, liefert dasselbe Ergebnis.

**Nach zwei Fehlversuchen an einem Micro-Task wird nicht weiter iteriert.**
Dann ist der Task falsch geschnitten oder die Aufgabe zu gross fuer 14B:
weiter mit `korrektur-logik` (Sonnet) bzw. `umsetzer`, mit einem Satz dazu,
was lokal gescheitert ist. Das ist kein Ausnahmefall, sondern der
vorgesehene Ausgang fuer alles ueber der Eignungsgrenze.

### 7. Abschluss

Nach dem letzten Micro-Task genau einmal, gefiltert auf das Ende der Ausgabe:

```
swift build && ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release 2>&1 | tail -20
```

`local_task.md` und `.aider.run.log` bleiben liegen (ignoriert) - sie gehoeren
nie in einen Commit. Danach geht der Stand ins Review (Stufe 1, Agent
`reviewer`), unveraendert wie bei einer Anthropic-Umsetzung. Dass lokal
umgesetzt wurde, steht in der Uebergabe - das Review bewertet Code, nicht
Herkunft.
