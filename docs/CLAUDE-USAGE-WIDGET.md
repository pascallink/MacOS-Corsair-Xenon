# Claude Usage Widget — Anzeige der Claude-Code-Nutzung auf dem Xeneon Edge

Ein leichtgewichtiges, rahmenloses Dashboard-Widget (SwiftUI, kein Server),
das sich automatisch auf dem Xeneon-Edge-Display platziert und die lokale
Claude-Code-Nutzung anzeigt.

![Layout] Ring (Tokens im aktuellen 5-h-Fenster) · Reset-Countdown ·
Kosten (Fenster + heute) · In/Out/Cache-Tokens · Modell-Badge · Plan-Badge

## Was es anzeigt

| Metrik | Quelle |
|---|---|
| **Token-Verbrauch im 5-h-Fenster** + verbleibende Zeit bis zum Reset | `~/.claude/projects/**/*.jsonl` — jede Assistant-Antwort enthält dort ihre Token-Zählung; die Fenster werden wie bei den Claude-Plänen in 5-Stunden-Blöcken gruppiert (an der vollen Stunde der ersten Nachricht verankert, wie beim ccusage-Community-Tool) |
| **Geschätzte Kosten** (aktuelles Fenster + heute) | Tokenzahlen × Preistabelle (Opus 5: $5/$25, Sonnet: $3/$15, Haiku 4.5: $1/$5, Fable 5: $10/$50 pro Mio. Tokens; Cache-Write ≈ 1,25×, Cache-Read ≈ 0,1× Input). Bei Abo-Plänen sind das *Gegenwerte*, keine echte Rechnung |
| **Modus/Modell** (Opus / Sonnet / Haiku / Fable) | Modell-ID der letzten Assistant-Antwort |
| **Plan** (Pro/Max…) | `~/.claude/.credentials.json` — es wird **ausschließlich** das Feld `subscriptionType` gelesen; die OAuth-Tokens in der Datei werden nie angefasst, geloggt oder übertragen |

**Datenschutz:** Standardmäßig läuft alles lokal. Das Widget macht keinerlei
Netzwerkzugriffe und braucht keine macOS-Berechtigungen (kein
Eingabemonitoring, keine Bedienungshilfen) — es liest nur Dateien im eigenen
Benutzerordner. Nur wer den optionalen Cloud-Relay (siehe unten) explizit
einrichtet, macht davon eine Ausnahme.

## Zwei Betriebsarten

1. **Panel im XeneonEdge-Dashboard (integriert):** In der Menüleiste der
   XeneonEdge-App → **Widgets → Claude-Nutzung** einschalten. Das
   „Claude“-Panel erscheint sofort in der mittleren Spalte (Ring,
   Reset-Countdown, Kosten, Modell-Badge) — kein Neustart, kein Editieren
   von JSON. Optional `"claudeTokenBudgetPerBlock"` in der `config.json`
   setzen (siehe unten), damit der Ring den Budget-Verbrauch statt der Zeit
   zeigt; danach „Konfiguration neu laden“ wählen.
2. **Eigenständiges Floating-Widget** (`ClaudeUsageWidget.app`) — z. B. wenn das
   große Dashboard aus ist und das Edge als normaler Monitor läuft. Beide
   können auch parallel laufen.

## Starten (eigenständiges Widget)

```bash
# einmalig bauen (baut auch XeneonEdge.app mit):
./Scripts/bundle-app.sh

# Widget starten:
open dist/ClaudeUsageWidget.app
```

Zum Entwickeln/Testen ohne Bundle: `swift run ClaudeUsageWidget`

Das Widget erscheint unten rechts auf dem Xeneon Edge (bzw. auf dem
Hauptdisplay, wenn kein Edge angeschlossen ist), aktualisiert sich alle
45 Sekunden und lässt sich mit der Maus/per Touch frei verschieben.
Steuerung über das Tacho-Symbol in der Menüleiste: sofort aktualisieren,
neu positionieren, Konfiguration öffnen/neu laden, beenden.

### Autostart (optional)

```bash
cp dist/ClaudeUsageWidget.app /Applications/
# Systemeinstellungen → Allgemein → Anmeldeobjekte → "+" → ClaudeUsageWidget
```

## Konfiguration

`~/Library/Application Support/XeneonEdge/claude-widget.json`
(wird beim ersten Start mit Standardwerten angelegt; nach Änderungen in der
Menüleiste „Konfiguration neu laden“ wählen):

```json
{
  "refreshSeconds": 45,
  "tokenBudgetPerBlock": 0,
  "corner": "bottomRight",
  "margin": 24,
  "width": 560,
  "height": 250,
  "includeCacheReads": false,
  "claudeProfiles": []
}
```

- **`tokenBudgetPerBlock`** — Anthropic veröffentlicht keine festen
  Token-Limits pro Plan; die Grenze hängt von Plan, Modell und Last ab.
  Deshalb ist der Ring standardmäßig eine 5-h-Zeitanzeige. Wenn du einmal
  ans Limit gelaufen bist, trage den dabei erreichten Tokenstand hier ein —
  ab dann zeigt der Ring den Budget-Verbrauch in Grün/Orange/Rot.
- **`corner`** — `topLeft`, `topRight`, `bottomLeft`, `bottomRight`, `center`.
- **`includeCacheReads`** — Cache-Reads mitzählen (Standard: aus, da sie
  bei den Limits kaum ins Gewicht fallen).
- **`cloudGistID`** / **`cloudPollSeconds`** — siehe Abschnitt Cloud-Relay.
- **`claudeProfiles`** — mehrere Claude-Logins getrennt anzeigen, siehe
  nächster Abschnitt. Leer (Standard) = ein Profil automatisch erkennen.

## Mehrere Claude-Profile (z. B. privat + geschäftlich)

Wer zwei Claude-Logins nutzt, hat **zwei getrennte 5-h-Limits**. Ihre
Verbräuche zu addieren wäre nicht nur unvollständig, sondern falsch: Die
Summe gehört zu keinem der beiden echten Limits, und ein gemeinsamer
Reset-Countdown wäre für mindestens eines der Profile verkehrt. Das Widget
führt sie deshalb strikt getrennt — es wird nichts über Profile hinweg
summiert.

### Zweites Profil anlegen

Ein Profil entsteht dadurch, dass Claude Code mit eigenem
Konfigurationsverzeichnis gestartet wird:

```bash
CLAUDE_CONFIG_DIR=~/.claude-work claude
```

Der Login erfolgt darin getrennt, und die Transkripte landen unter
`~/.claude-work/projects`. Praktisch ist ein Shell-Alias:

```bash
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
```

### Im Widget eintragen

```json
{
  "claudeProfiles": [
    { "name": "Privat", "configDir": "~/.claude" },
    { "name": "Arbeit", "configDir": "~/.claude-work" }
  ]
}
```

Kurzform genügt — fehlt `name`, wird der Verzeichnisname verwendet
(`~/.claude-work` → „claude-work"):

```json
{ "claudeProfiles": [{ "configDir": "~/.claude-work" }] }
```

Ab zwei Profilen wechselt die Darstellung auf eine kompakte Zeile pro
Profil, jeweils mit eigenem Tokenstand, eigenem Balken und eigenem
Reset-Countdown. Bei nur einem Profil (oder leerer Liste) bleibt die
Anzeige unverändert.

### Cloud-Relay pro Profil

Jedes Profil kann sein eigenes Gist mitbringen:

```json
{ "claudeProfiles": [
    { "name": "Arbeit", "configDir": "~/.claude-work", "cloudGistID": "abc123" }
] }
```

Sind Profile konfiguriert, wird das **oberste** `cloudGistID` ignoriert (es
wäre nicht zuzuordnen); ein entsprechender Hinweis landet im Log. Das
Abfrageintervall skaliert automatisch mit der Zahl der Gists, damit GitHubs
Limit von 60 unauthentifizierten Anfragen pro Stunde und IP eingehalten
wird — bei zwei Gists sind es mindestens 120 s.

## Cloud-Relay: Sessions aus der Cloud/Remote-Umgebung

Läuft eine Claude-Code-Session in einer entfernten/Cloud-Umgebung (z. B.
Claude Code on the web), liegt ihr Transkript auf einem anderen Rechner —
`~/.claude/projects` auf deinem Mac sieht sie nie, egal wie lange man
wartet. Der Cloud-Relay schließt diese Lücke: Ein Claude-Code-**Hook**
läuft in der Remote-Session selbst, extrahiert **ausschließlich**
Zeitstempel, Modell-ID und Tokenzahlen (**nie** Prompt- oder Antworttext)
und veröffentlicht sie in einem GitHub-Gist. Mac und Widget lesen dieses
Gist zusätzlich zu den lokalen Logs mit.

### Einmaliges Setup

1. **Gist anlegen** (lokal, einmalig; braucht `gh auth login`):
   ```bash
   ./Scripts/setup-cloud-usage-relay.sh
   ```
   Gibt eine Gist-ID aus.

2. **Mac (lesend, kein Token nötig):** In `config.json` und/oder
   `claude-widget.json`:
   ```json
   { "cloudGistID": "<die Gist-ID>", "cloudPollSeconds": 90 }
   ```
   Danach „Konfiguration neu laden“. Ein „Cloud“-Badge erscheint im Panel,
   sobald mindestens ein Eintrag aus dem Relay kommt.

3. **Jede Remote-/Cloud-Umgebung, die getrackt werden soll** (schreibend,
   braucht ein Token) — dort als Umgebungsvariablen setzen, je nachdem, wie
   diese Umgebung persistente Variablen anbietet (z. B. die
   Umgebungseinstellungen von Claude Code on the web):
   ```
   XENEON_USAGE_GIST_ID=<die Gist-ID>
   XENEON_USAGE_GIST_TOKEN=<classic GitHub PAT mit Scope "gist">
   ```
   **Wichtig:** Nur ein **klassischer** Personal Access Token mit dem Scope
   `gist` kann die Gist-API schreiben — feingranulare PATs und
   GitHub-App-Tokens (wie sie viele Cloud-Sessions schon für Repo-Zugriff
   mitbringen) können das nicht. PAT erstellen:
   <https://github.com/settings/tokens> (classic, nur `gist` ankreuzen).

4. **Hook aktivieren:** Dieses Repo bringt `.claude/settings.json` +
   `.claude/hooks/publish-claude-usage.sh` bereits mit — jede Remote-Session,
   die dieses Repo auscheckt, meldet sich damit automatisch (sofern die
   beiden Variablen aus Schritt 3 gesetzt sind). Für andere Repos/Setups
   beide Dateien dorthin kopieren.

### Wie es funktioniert

- Der Hook läuft nach jeder Antwort (`Stop`-Hook, `async: true` — blockiert
  die Session nicht) und schickt bei jedem Turn den **gesamten** bisherigen
  Nutzungsverlauf **dieser einen Session** (eine Gist-Datei pro
  `session_id`, komplett überschrieben — kein fehleranfälliges Anhängen).
- Mehrere gleichzeitige Remote-Sessions schreiben in unterschiedliche
  Dateien desselben Gists und stören sich nicht gegenseitig.
- Das Mac-seitige Polling ist auf **≥60 Sekunden** begrenzt
  (`cloudPollSeconds`, Standard 90), um unter dem unauthentifizierten
  GitHub-API-Limit von 60 Anfragen/Stunde/IP zu bleiben.

### Datenschutz-Kompromiss — ehrlich

- Ein **„secret“ Gist ist unlisted, nicht zugriffsgeschützt**: Wer die
  Gist-ID kennt, kann sie lesen, ohne Anmeldung. Das ist der Grund, warum
  der Hook **ausschließlich** Zeitstempel/Modell/Tokenzahlen hinterlegt —
  niemals Prompt-Text, Werkzeugausgaben oder Dateiinhalte.
- Der Schreib-Token (`XENEON_USAGE_GIST_TOKEN`) muss in jeder getrackten
  Remote-Umgebung als Umgebungsvariable liegen. Behandle ihn wie ein
  Passwort; scope ihn nur auf `gist`, sonst nichts.
- Deaktivieren: `cloudGistID` leer lassen (Standard) — dann ist der
  gesamte Abschnitt wirkungslos, es bleibt bei rein lokalen Logs.

## Grenzen (ehrlich)

- Die Kosten sind **Schätzwerte** aus einer eingebauten Preistabelle; bei
  Abo-Plänen zahlst du sie nicht pro Token. Preisänderungen von Anthropic
  erfordern eine Aktualisierung der Tabelle (`ClaudeUsageModels.swift`).
- Die 5-h-Fenster werden aus den lokalen Logs rekonstruiert — dieselbe
  Methode wie ccusage, aber ohne Garantie, dass Anthropics Server exakt
  gleich rechnen.
- Erfasst wird nur, was auf **diesem Mac** unter `~/.claude` liegt
  (`CLAUDE_CONFIG_DIR` bzw. `claudeProfiles` werden respektiert), plus
  optional die per Cloud-Relay angebundenen Remote-Sessions (siehe oben) —
  jede Umgebung, die weder hier noch dort erfasst ist, bleibt unsichtbar.
- Der **Plan-Name** (Pro/Max) stammt aus `.credentials.json` im jeweiligen
  Profilverzeichnis. Auf macOS legt Claude Code die Zugangsdaten oft im
  Schlüsselbund statt in dieser Datei ab — dann fehlt die Datei und das
  Plan-Abzeichen bleibt aus. Aus dem Schlüsselbund wird bewusst **nicht**
  gelesen: Der Eintrag enthält die OAuth-Tokens, und die sollen dieses
  Programm nie erreichen. Lieber kein Abzeichen als diese Grenze aufweichen.
- Der Cloud-Relay ist ein Community-Workaround (Gist + Hook), keine
  offizielle Anthropic-Schnittstelle — es gibt derzeit keine dokumentierte
  API, die den 5-h-Fensterverbrauch eines Pro/Max/Team-Abos aus der Ferne
  abfragbar macht.
