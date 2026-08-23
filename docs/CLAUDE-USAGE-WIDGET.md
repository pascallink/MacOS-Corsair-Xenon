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

**Datenschutz:** Alles läuft lokal. Das Widget macht keinerlei
Netzwerkzugriffe und braucht keine macOS-Berechtigungen (kein
Eingabemonitoring, keine Bedienungshilfen) — es liest nur Dateien im eigenen
Benutzerordner.

## Starten

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
  "includeCacheReads": false
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

## Grenzen (ehrlich)

- Die Kosten sind **Schätzwerte** aus einer eingebauten Preistabelle; bei
  Abo-Plänen zahlst du sie nicht pro Token. Preisänderungen von Anthropic
  erfordern eine Aktualisierung der Tabelle (`ClaudeUsageModels.swift`).
- Die 5-h-Fenster werden aus den lokalen Logs rekonstruiert — dieselbe
  Methode wie ccusage, aber ohne Garantie, dass Anthropics Server exakt
  gleich rechnen.
- Erfasst wird nur, was auf **diesem Mac** unter `~/.claude` liegt
  (`CLAUDE_CONFIG_DIR` wird respektiert). Nutzung auf anderen Geräten oder
  im Web fehlt.
