# XeneonEdge für macOS

**Nativer Treiber + iCUE-ähnliches Dashboard für das CORSAIR XENEON EDGE 14,5″ LCD-Touchscreen — ganz ohne Windows/iCUE.**

*English summary below.*

Das XENEON EDGE ist unter macOS „nur“ ein zweiter Monitor: Bild kommt per
USB-C (DP-Alt-Mode) oder HDMI, aber Touch, Widgets, Helligkeitssteuerung und
Sensor-Dashboards gibt es offiziell nur mit iCUE unter Windows. Dieses Projekt
liefert diese Funktionen nativ für macOS:

| Windows / iCUE | Dieses Projekt |
|---|---|
| Touchscreen-Bedienung | ✅ Touch-Treiber: Tippen = Klick, Ziehen = Drag, Doppeltipp = Doppelklick, Langdruck = Rechtsklick; Rotation/Spiegelung konfigurierbar |
| Widget-Dashboard (Uhr, Sensoren, Medien …) | ✅ Vollbild-Dashboard auf dem Edge: Uhr + Datum, CPU/RAM/Netzwerk-Monitoring mit Verlaufsgraph, Medien-Widget (Musik/Spotify) mit Steuerung, Lautstärkeregler, Wetter (Open-Meteo) |
| Virtual Stream Deck | ✅ „Schnellstart“-Raster mit frei konfigurierbaren App-Buttons |
| Helligkeit/Bild über iCUE | ✅ DDC/CI: Helligkeit, Kontrast, Power (Apple Silicon) |
| Geräteerkennung/Firmware | ✅ Vendor-HID (Corsair-Bragi-Protokoll): Erkennung, Seriennummer, Property-Abfrage |
| Autostart mit Windows | ✅ LaunchAgent (Autostart bei Anmeldung) |

## Aufbau

- **`XeneonEdgeKit`** — die Treiber-Bibliothek: HID-Touch-Treiber,
  Bragi-Vendor-HID-Transport, DDC/CI, Systemsensoren, Medien/Audio,
  Claude-Code-Nutzungsparser.
- **`XeneonEdgeApp`** — Menüleisten-App mit dem Touch-Dashboard.
- **Claude-Code-Nutzungsanzeige** — Token im 5-h-Fenster, Reset-Countdown,
  Kosten-Schätzung, aktives Modell; wahlweise als Panel im Dashboard
  (`"showClaudeUsage": true` in der config.json) oder als eigenständiges
  Floating-Widget (`ClaudeUsageWidget.app`) →
  [docs/CLAUDE-USAGE-WIDGET.md](docs/CLAUDE-USAGE-WIDGET.md).
- **`xeneonctl`** — Kommandozeilenwerkzeug (probe, brightness, ddc, touch-monitor).

Technische Details zum Gerät und Protokoll: [PROTOCOL-MACOS.md](PROTOCOL-MACOS.md).

## Sicherheit: Firmware & Gerät

- **Keine Firmware-Gefahr:** Der Code enthält keinerlei Firmware-/Flash-Kommandos,
  und der HID-Transport hat ein **Write-Gate**: An das Vendor-Interface werden
  ausschließlich lesende Kommandos (GET/Block-Read) durchgelassen — alles andere
  wird vom Transport selbst abgewiesen und ist per Unit-Test abgesichert.
- Helligkeit & Co. laufen über **Standard-DDC/CI** (dieselben Befehle wie das
  Monitor-OSD) und sind jederzeit am Gerät zurücksetzbar.
- **Kein Apple-Entwicklerkonto nötig:** reine Userspace-App mit Ad-hoc-Signatur,
  keine Kernel-/System-Extension.

Details und die vollständige Risikoübersicht: **[INSTALL.md](INSTALL.md)**.

## Installation

**Ausführliche Schritt-für-Schritt-Anleitung inkl. Berechtigungen,
Fehlersuche und Deinstallation: [INSTALL.md](INSTALL.md).** Kurzfassung:

Voraussetzungen: macOS 13+ (DDC-Helligkeit: Apple Silicon), Xcode Command
Line Tools (`xcode-select --install`). Ein Apple-Entwicklerkonto ist
**nicht** erforderlich.

```bash
git clone https://github.com/pascallink/MacOS-Corsair-Xenon.git
cd MacOS-Corsair-Xenon
./Scripts/bundle-app.sh          # baut dist/XeneonEdge.app + dist/xeneonctl
./Scripts/install.sh             # nach /Applications + Autostart (LaunchAgent)
```

Alternativ baut die GitHub-Actions-CI bei jedem Push ein fertiges
App-Artefakt (`XeneonEdge-macOS`).

### Berechtigungen (einmalig)

macOS fragt beim ersten Start nach:

1. **Bedienungshilfen** — nötig, damit Touch-Eingaben als Klicks ankommen.
2. **Eingabemonitoring** — nötig, um die HID-Touchdaten zu lesen.
3. **Automation** (optional) — nur für Titelanzeige aus Musik/Spotify.

Jeweils unter *Systemeinstellungen → Datenschutz & Sicherheit* freigeben und
die App neu starten.

## Benutzung

1. Edge per **USB-C (DP-Alt-Mode) oder HDMI** anschließen → erscheint als
   2560×720-Display. Zusätzlich das **USB-Datenkabel** verbinden (Touch + HID).
2. `XeneonEdge.app` starten → Menüleistensymbol erscheint, das Dashboard legt
   sich automatisch als Vollbild auf das Edge-Display.
3. Ohne angeschlossenes Edge zeigt die App auf Wunsch ein Vorschaufenster auf
   dem Hauptdisplay (`previewWithoutDevice` in der Konfiguration).

Menüleiste: Touch ein/aus, Dashboard ein/aus, Helligkeit (DDC), Geräteabfrage,
Konfigurationsdatei öffnen.

Konfiguration (Widgets, Wetter-Koordinaten, Schnellstart-Apps, Touch-Rotation):
`~/Library/Application Support/XeneonEdge/config.json` — Änderungen werden beim
nächsten Start übernommen.

### CLI

```bash
xeneonctl probe                 # Display, Touch-Controller, Vendor-HID erkennen
xeneonctl brightness 70         # Helligkeit über DDC/CI
xeneonctl ddc get 0x12          # beliebige VCP-Codes lesen/schreiben
xeneonctl firmware              # Bragi-GET an das Steuerinterface
xeneonctl touch-monitor         # Live-Touchereignisse (Diagnose, keine Klicks)
```

## Status / Roadmap

Dieses Projekt ist jung und **auf echter Hardware noch nicht flächendeckend
getestet** — Fehlerberichte mit `xeneonctl probe`-Ausgabe sind sehr willkommen.

- [ ] Mehrfinger-Gesten (Scrollen mit zwei Fingern)
- [ ] Intel-Macs: DDC über IOI2C
- [ ] Weitere Bragi-Properties (Orientierung, Panel-Info) verifizieren
- [ ] GPU-/Temperatur-Sensoren
- [ ] Grafische Einstellungen statt JSON

## English summary

Native macOS support for the CORSAIR XENEON EDGE 14.5″ touchscreen:
a touch driver (HID → CGEvent: tap, drag, double-tap, long-press right-click),
an iCUE-style fullscreen widget dashboard (clock, CPU/RAM/network, media
controls, volume, weather, app launcher), DDC/CI picture control on Apple
Silicon, and a Bragi vendor-HID probe — plus a CLI (`xeneonctl`) and a
LaunchAgent for autostart. See [PROTOCOL-MACOS.md](PROTOCOL-MACOS.md) for the
reverse-engineered device details.

## Lizenz & Dank

GPL-3.0-or-later. Dieses Projekt baut auf dem Community-Reverse-Engineering
von [corsair-xeneon-edge-linux](https://github.com/aabdelghani/corsair-xeneon-edge-linux),
[OpenLinkHub](https://github.com/jurkovic-nikola/OpenLinkHub),
[OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB),
[TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver) und
[m1ddc](https://github.com/waydabber/m1ddc) auf — danke!

CORSAIR und XENEON sind Marken der Corsair Memory, Inc. Dieses Projekt ist ein
unabhängiges Community-Projekt und steht in keiner Verbindung zu Corsair.
