# Installation & Betrieb — Schritt für Schritt

Diese Anleitung bringt das CORSAIR XENEON EDGE unter macOS zum Laufen —
**ohne Apple-Entwicklerkonto**, ohne Kernel-Extension und ohne iCUE.

---

## 1. Was du brauchst

- Mac mit **macOS 13 (Ventura) oder neuer**.
  Für die Helligkeitssteuerung (DDC/CI): **Apple Silicon** (M1 oder neuer).
  Touch und Dashboard funktionieren auch auf Intel-Macs.
- **Xcode Command Line Tools** (kostenlos, kein Entwicklerkonto nötig):
  ```bash
  xcode-select --install
  ```
- Das XENEON EDGE mit **beiden** Kabeln:
  - **Bild**: USB-C (DP-Alt-Mode) *oder* HDMI → das Edge erscheint als
    normaler 2560×720-Monitor.
  - **Daten**: das USB-Kabel → darüber laufen Touchscreen und die
    Geräteabfrage. Ohne dieses Kabel gibt es Bild, aber keinen Touch.

## 1a. Andere Helfer-Tools: Was muss vorher weg?

**In der Regel nichts.** Die Ausnahmen:

| Tool | Konflikt? | Empfehlung |
|---|---|---|
| **ymlaine/TouchscreenDriver** (älterer Edge-Touch-Treiber) | **Ja** — liest denselben Touch-Controller und injiziert ebenfalls Klicks → Doppelklicks, springender Cursor | Vorher deinstallieren: `launchctl unload ~/Library/LaunchAgents/com.ymlaine.touchscreendriver.plist` und die Plist/Skripte löschen |
| **MonitorControl / Lunar / BetterDisplay / m1ddc** | Nur weich — gleicher DDC/CI-Kanal für Helligkeit | Können bleiben; nur die *automatische* Helligkeitsregelung für das Edge-Display dort ausschalten, sonst überschreiben sich die Werte gegenseitig |
| **iCUE für macOS** (für Tastatur/Maus) | Nein für Touch/Dashboard. Hält iCUE das Corsair-HID exklusiv offen, liefert `xeneonctl probe`/„Gerät abfragen“ evtl. nichts | Kann bleiben; bei leerer HID-Abfrage iCUE kurz beenden |
| **Karabiner-Elements, BetterTouchTool u. Ä.** | Praktisch nie (greifen Tastatur/Trackpad ab, nicht den Digitizer) | Nur im Verdachtsfall testweise beenden |

Eine ältere Version **dieses** Projekts vorher sauber entfernen
(siehe Abschnitt 6), damit nicht zwei LaunchAgents parallel laufen.

## 2. Bauen und installieren (ohne Entwicklerkonto)

Es wird **kein** Apple-Developer-Account benötigt:

- Die App ist eine normale Benutzer-App (keine System- oder Kernel-Erweiterung),
  daher genügt eine **Ad-hoc-Signatur**, die das Build-Skript selbst erstellt
  (`codesign --sign -`).
- **Lokal gebaute** Apps bekommen keine Gatekeeper-Quarantäne — macOS startet
  sie ohne Notarisierung.

```bash
git clone https://github.com/pascallink/MacOS-Corsair-Xenon.git
cd MacOS-Corsair-Xenon
./Scripts/bundle-app.sh      # baut XeneonEdge.app, ClaudeUsageWidget.app, xeneonctl
./Scripts/install.sh         # kopiert nach /Applications, richtet Autostart ein
```

`install.sh` fragt einmal nach dem Admin-Passwort (`sudo`), nur um
`xeneonctl` nach `/usr/local/bin` zu legen. Wer das nicht möchte, kann den
Schritt im Skript auskommentieren — die App braucht ihn nicht.

### Alternative: CI-Download statt selbst bauen

Die GitHub-Actions-CI baut bei jedem Push das Artefakt **XeneonEdge-macOS**.
Heruntergeladene Apps stehen unter Quarantäne und sind nur ad-hoc-signiert;
macOS blockiert den ersten Start. Freigeben mit:

```bash
xattr -dr com.apple.quarantine ~/Downloads/XeneonEdge.app
```

…oder Rechtsklick → „Öffnen“ → „Öffnen“ bestätigen. **Empfehlung:** lieber
selbst bauen (Abschnitt oben) — dann entfällt das komplett und du weißt, was
du ausführst.

## 3. Berechtigungen (einmalig, alle widerrufbar)

Beim ersten Start meldet sich macOS bis zu dreimal. Alle Freigaben unter
*Systemeinstellungen → Datenschutz & Sicherheit*:

| Berechtigung | Wofür | Pflicht? |
|---|---|---|
| **Bedienungshilfen** | Touch-Tipps werden als Mausklicks eingespeist | Ja, für Touch |
| **Eingabemonitoring** | HID-Daten des Touch-Controllers lesen | Ja, für Touch |
| **Automation (Musik/Spotify)** | Titelanzeige im Medien-Widget | Nein, optional |

Nach dem Erteilen die App einmal beenden und neu starten (Menüleiste →
„XeneonEdge beenden“, dann neu öffnen).

**Hinweis:** Nach jedem Neu-Bauen ändert sich die Ad-hoc-Signatur — macOS kann
die Freigaben dann erneut verlangen. Einfach in den Systemeinstellungen den
alten Eintrag entfernen (−) und neu erteilen.

## 4. Erster Funktionstest

```bash
xeneonctl probe
```

Erwartete Ausgabe, wenn alles verbunden ist:

```
== CORSAIR XENEON EDGE — probe ==
Display   : XENEON EDGE (id 3)
Bounds    : 2560x720 at (1512, 0)
Vendor HID: XENEON EDGE / CORSAIR / SN 63432…
DDC       : 1 external display I2C service(s)
```

- **Display fehlt** → Bildkabel/Modus prüfen (USB-C muss DP-Alt-Mode können).
- **Vendor HID fehlt** → USB-Datenkabel prüfen.
- **Touch testen ohne Klicks auszulösen**: `xeneonctl touch-monitor`
  (reine Diagnose, es werden keine Mausereignisse erzeugt).

Danach `XeneonEdge.app` starten: Das Dashboard legt sich als Vollbild auf das
Edge; über das Menüleistensymbol lassen sich Touch, Dashboard und Helligkeit
steuern.

## 5. Risiken — ehrlich erklärt

### Kann die Software die Firmware des Edge beschädigen? — Nein.

Dafür sorgen mehrere Schichten:

1. **Es gibt im gesamten Code keine Firmware-/Flash-Kommandos.** Nirgends.
2. **Write-Gate im HID-Transport:** An das Vendor-Interface (`1b1c:1d0d`)
   werden ausschließlich **lesende** Kommandos gesendet (GET `0x02`,
   Block-Read `0x08`). Jedes andere Kommando wird vom Transport selbst mit
   einem Fehler abgewiesen — auch wenn künftiger Code es versehentlich
   versuchen würde. Der Schalter zum Umgehen (`dangerouslyAllowWrites`) wird
   weder von der App noch vom CLI gesetzt.
3. **Lesekommandos ändern keinen Gerätezustand.** Das verwendete GET ist
   von der Linux-Community am echten Gerät verifiziert; die Antwort ist ein
   Echo mit Daten. Ein unbekanntes Property liefert schlimmstenfalls
   Füllbytes (`FF…`).
4. Die Firmware selbst akzeptiert Updates ohnehin nur über einen eigenen,
   von Corsair signierten Update-Prozess — den diese Software nie anspricht.

### Was die Software sonst tut — und was dabei passieren kann

| Bereich | Was passiert | Restrisiko | Rückgängig machen |
|---|---|---|---|
| **DDC/CI** (Helligkeit/Kontrast/Power) | Standard-Monitorbefehle über das Displaykabel — dieselben, die jedes OSD nutzt | Ein falscher `xeneonctl ddc set`-Wert kann das Bild verstellen (z. B. Eingang umschalten, Bild dunkel) | Immer über das OSD/Joystick am Monitor oder erneutes `ddc set` korrigierbar; **Werksreset im OSD** setzt alles zurück. Firmware ist nicht erreichbar |
| **Touch → Klicks** | Die App darf systemweit Mausklicks erzeugen (Bedienungshilfen) | Bei falscher Kalibrierung/Rotation landen Klicks an falscher Stelle — auch auf anderen Displays | Menüleiste → „Touch-Eingabe aktiv“ abschalten (⌘T) oder App beenden; Rotation in `config.json` korrigieren |
| **Eingabemonitoring** | Die App liest nur die Reports des Touch-Controllers (27c0:0859) | Die Berechtigung selbst erlaubt technisch mehr — der Quellcode ist offen und filtert per Vendor/Product-ID | Berechtigung jederzeit in den Systemeinstellungen entziehen |
| **Wetter-Widget** | Optionaler HTTPS-Abruf bei open-meteo.com (nur Koordinaten aus der Config, keine persönlichen Daten) | — | `showWeather: false` (Standard: aus) |
| **Private IOAVService-API** (DDC auf Apple Silicon) | Nicht dokumentierte, aber weit verbreitete Apple-API (m1ddc, MonitorControl) | Kann nach einem macOS-Update brechen → DDC-Funktionen melden dann Fehler; Touch/Dashboard sind davon unabhängig | Nichts kaputt — Feature fällt kontrolliert aus |
| **Garantie** | Software nutzt nur USB-HID-Lesezugriffe und Standard-DDC | Corsair supportet macOS offiziell nicht; im Zweifel bei Supportfällen iCUE-Setup am PC zeigen | — |

**Generell gilt:** Open Source unter GPL-3.0, keine Gewährleistung
(siehe LICENSE). Auf echter Hardware noch jung — bitte Probleme mit der
Ausgabe von `xeneonctl probe` als GitHub-Issue melden.

## 5a. Aktualisieren (neue Version einspielen)

Die installierte App ist ein kompiliertes Programm — Änderungen am Quellcode
wirken erst nach einem Neubau:

```bash
cd MacOS-Corsair-Xenon
git pull
./Scripts/bundle-app.sh      # neu bauen
./Scripts/install.sh         # ersetzen + neu starten
```

`install.sh` beendet dabei die laufenden Instanzen, ersetzt
`XeneonEdge.app`, `ClaudeUsageWidget.app` und `xeneonctl` und startet die
Menüleisten-App über den LaunchAgent neu.

Ohne Installation nach `/Applications` genügt auch:
`open dist/XeneonEdge.app` bzw. `open dist/ClaudeUsageWidget.app`
(vorher die alte Instanz beenden).

**Wichtig:** Beim Neubau ändert sich die Ad-hoc-Signatur, deshalb kann macOS
die Berechtigungen (Bedienungshilfen, Eingabemonitoring) erneut verlangen.
Falls der Touch danach nicht reagiert: unter *Systemeinstellungen →
Datenschutz & Sicherheit* den alten Eintrag mit „−“ entfernen und neu
erteilen. Deine Konfigurationsdateien bleiben beim Update erhalten.

## 5b. Widgets des Dashboards anpassen

**Am einfachsten über die Menüleiste:** Menüleistensymbol → **Widgets** —
dort lassen sich Uhrzeit, System, Medien, Lautstärke, Schnellstart, Wetter
und Claude-Nutzung einzeln an- und abschalten. Die Änderung wirkt sofort
und wird gespeichert; kein Neustart nötig.

Für alles Weitere (Wetter-Koordinaten, Schnellstart-Buttons, Touch-Rotation)
liegt die Konfiguration in
`~/Library/Application Support/XeneonEdge/config.json` (Menüleiste →
„Konfigurationsdatei öffnen …“). Nach dem Bearbeiten genügt
„Konfiguration neu laden“ (⌘L) — ein Neustart ist nicht erforderlich.

Panels ein-/ausschalten:

```json
{
  "showClock": true,
  "showStats": true,
  "showMedia": true,
  "showVolume": true,
  "showLauncher": true,
  "showWeather": false,
  "showClaudeUsage": false,
  "use24HourClock": true
}
```

- **`showClaudeUsage`** — Panel mit der lokalen Claude-Code-Nutzung
  (Token im 5-h-Fenster, Reset-Countdown, Kosten, Modell); Details in
  [docs/CLAUDE-USAGE-WIDGET.md](docs/CLAUDE-USAGE-WIDGET.md).
- **`showWeather`** — braucht zusätzlich `weatherLatitude`,
  `weatherLongitude` und `weatherPlaceName`.

Schnellstart-Buttons (`launcherItems`): Name, Ziel (Bundle-ID **oder**
absoluter App-Pfad) und ein [SF-Symbol](https://developer.apple.com/sf-symbols/).
Ein `id`-Feld ist nicht nötig — es wird automatisch vergeben:

```json
"launcherItems": [
  { "name": "VS Code", "target": "com.microsoft.VSCode", "symbol": "chevron.left.forwardslash.chevron.right" },
  { "name": "Steam", "target": "/Applications/Steam.app", "symbol": "gamecontroller" }
]
```

Die Bundle-ID einer installierten App liefert `osascript -e 'id of app "Steam"'`.

Fehlende Schlüssel sind unkritisch: Jedes Feld fällt einzeln auf seinen
Standardwert zurück, deine übrigen Einstellungen bleiben erhalten.

## 6. Deinstallation (rückstandsfrei)

```bash
launchctl unload ~/Library/LaunchAgents/de.pascallink.xeneonedge.plist
rm ~/Library/LaunchAgents/de.pascallink.xeneonedge.plist
rm -rf /Applications/XeneonEdge.app
sudo rm -f /usr/local/bin/xeneonctl
rm -rf ~/Library/Application\ Support/XeneonEdge
```

Anschließend die erteilten Berechtigungen unter *Datenschutz & Sicherheit*
entfernen. Das Edge selbst bleibt unverändert — es wurde nie etwas darauf
gespeichert.

## 7. Häufige Probleme

| Symptom | Ursache / Lösung |
|---|---|
| Touch bewirkt nichts | Bedienungshilfen + Eingabemonitoring erteilt? App danach neu gestartet? USB-Datenkabel dran? `xeneonctl touch-monitor` zeigt, ob Daten ankommen |
| Klicks an falscher Stelle | Edge in den macOS-Displayeinstellungen gedreht montiert? `touchRotation` (90/180/270) bzw. `touchInvertX/Y` in `config.json` setzen |
| Helligkeit schlägt fehl | Intel-Mac (noch nicht unterstützt) oder Dock/Adapter leitet DDC nicht durch → Edge direkt anschließen |
| Dashboard auf falschem Display | Displaynamen prüfen: App sucht „XENEON“, dann 32:9-Seitenverhältnis; ggf. Issue melden |
| App startet nach Neubau nicht mehr / fragt erneut nach Rechten | Ad-hoc-Signatur hat sich geändert → alte Einträge in Datenschutz & Sicherheit entfernen, neu erteilen |
