# CI

Ausgelagert aus der Root-`CLAUDE.md`: diese Details braucht man beim Arbeiten
an der CI, nicht in jeder Sitzung.

## CI-Workflows

| Workflow | Trigger | Zweck |
| --- | --- | --- |
| `build.yml` | Push auf jeden Branch, jeder PR | `swift build`, Tests (`swift test -v`), Release-Build, App-Bundle - Ergebnis als Artefakt |
| `commitlint.yml` | Jeder PR | Prueft die Commit-Konvention gegen `origin/develop` |

`build.yml` laeuft auf `macos-latest` mit vollem Xcode - dort greift
`swift test -v` direkt, ohne den Umweg ueber `./Scripts/test.sh` (siehe
`.github/TESTS.md`). Lokal, mit nur den Command Line Tools, ist das Skript
Pflicht.

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
