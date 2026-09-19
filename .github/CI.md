# CI

Ausgelagert aus der Root-`CLAUDE.md`: diese Details braucht man beim Arbeiten
an der CI, nicht in jeder Sitzung.

## CI-Workflows

| Workflow | Trigger | Zweck |
| --- | --- | --- |
| `build.yml` | Push auf `develop`, jeder PR, `workflow_dispatch` | `swift build`, Tests (`swift test -v`), Release-Build, App-Bundle - Ergebnis als Artefakt |
| `commitlint.yml` | Jeder PR | Prueft die Commit-Konvention gegen `origin/develop` |
| `codeql.yml` | Push auf `develop`, jeder PR, montags 3:17 UTC, `workflow_dispatch` | CodeQL-Analyse (Swift) mit eigener Konfiguration - siehe "Code-Scanning" |
| `ai-build-checker.yml` | `workflow_run` nach rotem `Build` | Baut nichts selbst: analysiert das Log des fehlgeschlagenen Jobs und postet es als PR-Kommentar |

`build.yml` laeuft auf `macos-latest` mit vollem Xcode - dort greift
`swift test -v` direkt, ohne den Umweg ueber `./Scripts/test.sh` (siehe
`.github/TESTS.md`). Lokal, mit nur den Command Line Tools, ist das Skript
Pflicht.

Der Trigger ist bewusst `develop` plus Pull Requests und nicht jeder
Branch-Push: sonst laeuft derselbe Commit zweimal auf `macos-latest`, und
macOS-Minuten rechnet GitHub zehnfach ab. Ein Branch ohne PR braucht keinen
Lauf.

### Action-Versionen

Der Node-20-Runtime entkommt man nicht pauschal ueber eine Major-Nummer -
massgeblich ist `runs.using` in der `action.yml` des Tags, und die Warnung am
Ende des Job-Logs nennt die Nachzuegler namentlich. In Benutzung:
`checkout@v5`, `setup-node@v5`, `upload-artifact@v5` und
`github/codeql-action@v4` - alle auf Node 24.

### Modellaufruf in der CI

`ai-build-checker.yml` liefert Beiwerk, keinen Pruefbefund. Ist das Modell
nicht erreichbar - fehlender Schluessel, leeres Guthaben, Ratsperre, Stoerung -,
setzt der Job eine `::warning::`-Anmerkung und endet gruen; ein Fehler im
eigenen Code laesst ihn weiter hart scheitern. Die Einteilung sitzt in
`Scripts/ci/lib/anthropic.js` (`ModelUnavailableError`), Modell-ID und
Retry-Verhalten stehen dort an *einer* Stelle.

Der Job braucht das Repository-Secret `ANTHROPIC_API_KEY`. Fehlt es, bleibt
er gruen und schreibt nur die Warnung - der rote Build, auf den er reagiert,
ist das eigentliche Signal.

Er haengt als `workflow_run` am Build, statt ihn ein zweites Mal auszufuehren.
Zwei Konsequenzen: Aenderungen daran wirken erst, wenn sie auf `develop`
liegen (GitHub nimmt bei `workflow_run` immer die Version des Default-Branch),
und der Lauf traegt ein Token mit Schreibrecht, weshalb der Kommentar auch bei
Fork-PRs funktioniert. Er laeuft auf `ubuntu-latest`: er liest nur ein Log und
ruft eine API, eine Swift-Toolchain braucht er nicht.

Die Skripte unter `Scripts/ci/` haben eigene Tests:
`npm run test:scripts` (Node, ohne Netz - `fetch` wird je Test ersetzt).

### Code-Scanning

CodeQL laeuft als **advanced setup**, also ueber `codeql.yml` im Repo, nicht
ueber den Schalter unter *Settings -> Advanced Security -> Code scanning*.
Zwei Gruende: die Analyse braucht einen `macos-latest`-Runner (Swift ist
compiliert, CodeQL sieht nur was ein echter Build uebersetzt, und der braucht
hier IOKit/AppKit), und nur das advanced setup liest
`.github/codeql-config.yml`.

Beides parallel geht nicht. Ist das Default-Setup aktiv, weist GitHub das
Ergebnis von `codeql.yml` beim Upload zurueck (`409`, "default setup is
enabled") und der Lauf wird rot. Das Default-Setup muss also abgeschaltet
bleiben.

`build-mode: manual` statt `autobuild`: dieses Repo hat kein Xcode-Projekt und
wird ausschliesslich mit `swift build` gebaut - autobuild wuerde zuerst nach
`xcodebuild` suchen. Schlaegt der Build im CodeQL-Lauf fehl, ist der Build
kaputt und nicht die Analyse; der Ort dafuer ist dann `build.yml`.

Und eine Erwartung, die man kennen muss: bei einer compilierten Sprache folgt
die Analyse dem Build, nicht dem Dateibaum. `paths-ignore` wirkt hier deshalb
nur schwach - was `swift build` uebersetzt, wird analysiert.

## Lokale CI-Kette

Die vier Schritte aus `build.yml` lassen sich lokal komplett nachstellen -
vor jedem Commit durchlaufen lassen, nicht erst danach:

```bash
swift build && ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release
```

Gruen wird vor dem Commit hergestellt, die CI in `build.yml` ist die
Zweitmeinung. Es gibt hier **keinen Linter** (kein SwiftLint, kein
SwiftFormat) - wo eine andere Kette an dieser Stelle Lint erwarten wuerde,
steht in diesem Repo nichts.

## Local First

**Push nur nach Freigabe durch Pascal.** Lokale Branches, lokal committen,
lokal die CI-Kette gruen bekommen - das Remote-Repository ist zweitrangig und
nimmt keinen ungetesteten Code an. Details in der Root-`CLAUDE.md`
("Oberste Entwicklungsrichtlinie: Local First").

## Hinweis fuer Claude

**Ein gepushter PR ist erledigt.** Der Auftrag endet mit dem Push und der
Meldung, was drin ist. Danach:

- keine Workflow-Runs pollen, kein `sleep`, keine Selbst-Termine, kein
  Abonnieren von PR-Ereignissen;
- nicht fragen, ob du den PR beobachten, CI reparieren oder auf Review-
  Kommentare antworten sollst. Die Frage kostet Token und die Antwort ist
  immer dieselbe.

Pascal liest den PR selbst und kommt aktiv zurueck, wenn etwas zu tun ist.
Erst dann wird gearbeitet - und nur an dem, was er nennt.

Was das nicht aufweicht: Vor jedem Push die lokale CI-Kette oben laufen
lassen. Gruen wird vor dem Push hergestellt, nicht danach.
