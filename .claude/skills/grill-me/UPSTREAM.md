# Herkunft: grill-me

Vendored aus [`mattpocock/skills`](https://github.com/mattpocock/skills),
Lizenz MIT (c) 2026 Matt Pocock.

| Datei | Upstream-Pfad |
| --- | --- |
| `.claude/skills/grill-me/SKILL.md` | `skills/productivity/grill-me/SKILL.md` |
| `.claude/skills/grilling/SKILL.md` | `skills/productivity/grilling/SKILL.md` |

Stand: Commit `c55ee46` (2026-09-18).

## Warum zwei Ordner

`grill-me` ist nur der Einstiegspunkt: ein Alias mit
`disable-model-invocation: true`, damit der Skill ausschliesslich per
`/grill-me` startet und sich nie von selbst einmischt. Der eigentliche
Ablauf steht in `grilling`. Wer `grilling/` loescht, macht `/grill-me`
kaputt - beide Ordner gehoeren zusammen.

## Aktualisieren

Beide `SKILL.md` neu aus dem Upstream kopieren und den Commit-Stand oben
nachziehen. Die Dateien bleiben absichtlich woertlich englisch wie im
Upstream, damit ein Update ein reines `cp` bleibt - die Deutsch-Regel des
Repos gilt fuer eigenen Code, nicht fuer fremde Vendor-Dateien.
