---
name: tri-model-dev
description: 3-Stufen Entwicklungs-Workflow mit Modellwechsel (Opus 5 -> Fable 5 -> Sonnet 5). Analyse und Issue, technischer Plan, lokale Umsetzung — jede Stufe als Subagent auf dem passenden Modell.
---

Führe für die gegebene Anforderung oder Problemstellung den folgenden
Workflow aus. Jede Stufe läuft als eigener Subagent auf einem eigenen Modell;
du selbst orchestrierst, hältst den Kontakt zum Nutzer und triffst keine der
inhaltlichen Entscheidungen der Stufen.

## Vorbereitung

Lege ein Run-Verzeichnis an und merke dir den Pfad — alle drei Stufen legen
ihre Ergebnisse dort ab und lesen sie von dort:

```bash
mkdir -p ".tri-model-dev/$(date +%Y%m%d-%H%M)-<kurzer-slug>"
```

Der Slug beschreibt die Aufgabe in zwei, drei Wörtern. Das Verzeichnis ist
über `.gitignore` ausgenommen und gehört nicht in einen Commit.

Prüfe außerdem den Branch. Steht der Workflow auf `main` oder `develop`,
zweige vorher ab (`git checkout -b feature/<slug>`) — die Umsetzung in Stufe 3
committet auf den aktuellen Branch.

## Stufe 1: Analyse & Issue — Opus 5

Rufe den Subagenten `tri-analyst` mit `model: "opus"` und
`run_in_background: false` auf. Gib ihm im Prompt mit:

- die Problemstellung im Wortlaut des Nutzers,
- den absoluten Pfad des Run-Verzeichnisses,
- den erwarteten Output: `01-analysis.md` und `02-issue.md`.

Der Analyst legt das Issue **nicht** selbst an. Wenn er fertig ist:

1. Lies `02-issue.md` und gib Titel und Body im Gespräch wieder.
2. Frag den Nutzer, ob das Issue so angelegt werden soll. Ein Subagent kann
   diese Frage nicht stellen — deshalb liegt sie hier.
3. Erst nach einem klaren Ja: `gh issue create --title ... --body-file ...`.
   Sagt der Nutzer nein oder will Änderungen, arbeite sie ein und frag erneut.
   Will er gar kein Issue, ist das in Ordnung — Stufe 2 kommt auch mit
   `02-issue.md` allein aus.

Merke dir die Issue-Nummer für die weiteren Stufen.

## Stufe 2: Umsetzungsplanung — Fable 5

Rufe den Subagenten `tri-planner` mit `model: "fable"` und
`run_in_background: false` auf. Gib ihm mit:

- den Pfad des Run-Verzeichnisses,
- die Issue-Nummer, falls eines angelegt wurde,
- den erwarteten Output: `03-plan.md`.

Wenn der Planer meldet, dass die Analyse für eine saubere Planung nicht
ausreicht, geh zurück zu Stufe 1, statt ihn raten zu lassen.

Leg dem Nutzer die Schrittliste kurz vor, bevor implementiert wird. Er soll
den Plan korrigieren können, solange noch keine Zeile Code geschrieben ist —
das ist die günstigste Stelle im ganzen Workflow für eine Kurskorrektur.

## Stufe 3: Lokale Implementierung — Sonnet 5

Rufe den Subagenten `tri-implementer` mit `model: "sonnet"` und
`run_in_background: false` auf. Gib ihm mit:

- den Pfad des Run-Verzeichnisses,
- den Branch, auf dem committet werden soll,
- den erwarteten Output: `04-implementation.md`.

Der Implementierer baut, testet und committet lokal. Er pusht nicht und legt
keinen PR an.

Prüfe seinen Bericht, statt ihn zu übernehmen: schau in `git diff`/`git show`
und lass die Testkette bei Zweifeln selbst noch einmal laufen. Meldet er einen
Fehlschlag, gib den ungeschönt an den Nutzer weiter.

## Abschluss

Fass zusammen, was in allen drei Stufen passiert ist: Ursache, Plan in
Kurzform, umgesetzte Änderung, Testergebnis, Commit. Nenne ausdrücklich, was
offen blieb.

Push und Pull Request bietest du an — ausgeführt werden sie erst auf
ausdrückliche Anweisung des Nutzers. So will es auch `CLAUDE.md`.

## Warum drei Modelle

Die Stufen stellen verschiedene Anforderungen: Stufe 1 lebt von tiefem
Verständnis eines unscharfen Problems, Stufe 2 von sauberer technischer
Ableitung aus einer bereits geklärten Lage, Stufe 3 von zügiger, disziplinierter
Umsetzung eines fertigen Plans. Der Schnitt in Subagenten hat außerdem einen
Nebeneffekt, der unabhängig vom Modell nützt: jede Stufe startet mit frischem
Kontext und bekommt als Eingabe nur das aufgeschriebene Ergebnis der
vorherigen. Was nicht in `01`–`03` steht, existiert für die nächste Stufe
nicht — das erzwingt Ergebnisse, die für sich stehen.
