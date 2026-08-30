# CORSAIR XENEON EDGE — Technische Notizen (macOS)

Alle Protokollfakten stammen aus öffentlichem Community-Reverse-Engineering
und eigenen Ableitungen; es wurde kein proprietärer Code verwendet.

## Gerätetopologie

Das XENEON EDGE meldet sich am USB-Bus als **mehrere unabhängige Geräte**:

| Funktion | USB-ID | Typ | Zugriff unter macOS |
|---|---|---|---|
| Bildausgabe | — | USB-C DP-Alt-Mode oder HDMI 2.0 | Normaler Monitor (2560×720), keine Treiber nötig |
| Touchscreen | `27c0:0859` | meldet **drei** HID-Interfaces unter derselben VID/PID (siehe unten) | IOHIDManager; macOS hat keinen Touchscreen-Support → dieser Treiber übersetzt in Mausereignisse |
| Steuerinterface | `1b1c:1d0d` | Vendor-HID (Usage Page `0xFF1B`) | IOHIDManager, 64-Byte-Reports |
| Bildeinstellungen | — | DDC/CI über den I2C-Kanal des Displaykabels | IOAVService (Apple Silicon) |

## Touchscreen (verifiziert am angeschlossenen Gerät, Issue #10)

Der Touch-Controller `27c0:0859` meldet unter derselben VID/PID **drei**
unabhängige HID-Interfaces; ein Matching allein auf VID/PID öffnet alle drei:

| Interface | Usage Page/Usage | Inhalt | Von diesem Treiber geöffnet |
|---|---|---|---|
| Digitizer | `0x0D`/`0x04` | 10 Kontaktslots, siehe unten | ja |
| Maus-Emulation | `0x01`/`0x02` | 1× X/Y/Wheel, Button 1/2/3 (`0x09`) | nein |
| Hersteller-Kanal | `0xFF0A`/`0xFF` | wch.cn-spezifisch, ungenutzt | nein |

Der Digitizer im Detail:

- **10 Kontaktslots** (`Contact Count Maximum`, Feature `0x0D/0x55`,
  `logicalMax = 15`; `MaxInputReportSize = 54` = 1 Report-ID + 10 × 5 Byte +
  2 Byte Scan Time + 1 Byte Contact Count) — nicht „5-Punkt kapazitiv“, wie
  frühere Fassungen dieser Datei behaupteten. Alle zehn Finger-Collections
  sind im Deskriptor identisch aufgebaut; der Treiber bindet HID-Element-
  Cookies über deren Eltern-Collection an den jeweiligen Kontaktslot und
  verarbeitet ausschließlich Slot 0 — ungenutzte Slots melden sonst `0` und
  würden den Cursor in die Panel-Ecke ziehen.
- Report: Generic Desktop `X` (Usage `0x30`) und `Y` (Usage `0x31`), absolut,
  je zehnmal (einmal pro Slot).
- Logischer Wertebereich: X `0–16383`, Y `0–9599` (wird zur Sicherheit zur
  Laufzeit aus den HID-Elementen gelesen; am Gerät bestätigt).
- Kontaktzustand: Digitizer Tip Switch `0x0D/0x42`. **Button 1 (`0x09/0x01`)
  liegt auf der Maus-Emulation, nicht auf dem Digitizer** — frühere Fassungen
  dieser Datei und ein Codekommentar behaupteten das Gegenteil; der Treiber
  öffnet die Maus-Emulation seit Issue #10 gar nicht mehr.
- Die Physical-Extents des Deskriptors (X 21,69 cm, Y 9,06 cm; Unit
  Exponent −2) sind **unbrauchbar**: bei 14,5″ und 32:9 wären ≈ 35,4 × 9,97 cm
  zu erwarten. Der Code verwendet sie bewusst nicht.
- Der Treiber normalisiert die Rohkoordinaten, wendet optional Rotation /
  Spiegelung an und bildet auf die globalen CoreGraphics-Koordinaten des
  Edge-Displays ab. Injektion über `CGEvent` (links/rechts, Drag, Doppelklick,
  Langdruck = Rechtsklick). Nach jeder abgeschlossenen Geste springt der
  Cursor an seine vorherige Position zurück (`restoreCursorAfterTouch`,
  Default an, unabhängig von `dragEnabled`) — dafür wird nach dem Warp
  `CGAssociateMouseAndMouseCursorPosition(1)` gerufen (sonst reißt die
  nächste physische Mausbewegung den Cursor zurück) und mit einem eigenen
  `CGEventSource` gepostet, dessen Local-Events-Suppression-Intervall auf 0
  gesetzt ist (sonst verschluckt das Standardintervall von 0,25 s
  nachfolgende Klicks).

## Vendor-HID: Corsair „Bragi“ / Protocol V2

- 64-Byte-Reports: `[Report-ID 0x01][63 Byte Payload]`.
- Payload beginnt mit Kommandopaar `{group, id}`; das Gerät **echot** das
  Kommandopaar in der Antwort.
- Verifiziert (Community, Echo-Test am echten Gerät):
  `TX 01 02 13 00…` → `RX 01 02 13 00 00 14 FF×20 …`
- Kommandotabelle (Status siehe Quellen):

| Kommando | Bytes | Status |
|---|---|---|
| GET Property | `0x02 <prop>` | Framing verifiziert |
| SET Property | `0x01 <prop> <val…>` | Kandidat |
| Software-Modus | `0x01 0x03 0x00 0x02` | Kandidat |
| Hardware-Modus | `0x01 0x03 0x00 0x01` | Kandidat |
| Endpoint öffnen | `0x0D 0x01` | Kandidat |
| Endpoint schließen | `0x05 0x01 0x01` | Kandidat |
| Blockdaten lesen | `0x08 0x01` | Kandidat |

**Der Ausgabepuffer für `IOHIDDeviceSetReport` muss das Report-ID-Byte
enthalten** (Issue #10, A/B-Beleg am echten Gerät, mehrfach in beiden
Reihenfolgen reproduziert):

```
64 Byte inkl. führendem 0x01  -> setReport 0x00000000, Antwort: 01 02 13 00 00 14 FF FF ...
63 Byte ohne 0x01             -> setReport 0x00000000, keine Antwort
```

Das `reportID`-Argument von `IOHIDDeviceSetReport` selbst ist für dieses
Gerät irrelevant — nur das Byte im Puffer zählt. Erschwerend meldet
`IOHIDDeviceSetReport` **in beiden Fällen** `kIOReturnSuccess`; ein falsch
gesendeter Puffer fällt deshalb erst ~1 s später als `BragiError.timeout`
auf, nicht sofort als Schreibfehler. Zusätzlich muss der Input-Report-
Callback im Runloop registriert sein, bevor der erste Request gesendet wird
— `BragiTransport.open()` wartet dafür auf die erste Runloop-Iteration,
statt sofort nach dem Thread-Start zurückzukehren.

Am angeschlossenen Edge nachgeprüfter Rohdump (`xeneonctl firmware`):

```
GET 0x13 raw : 01 02 13 00 00 14 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 00 00 00 00 00 00
GET 0x13 data: 00 00 14 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 00 00 00 00 00 00 00
```

**Write-Gate (Firmware-Schutz):** Der HID-Transport (`BragiDevice.send`)
lässt nur die lesenden Kommandos `0x02` (GET) und `0x08` (Block-Read) durch.
Alle zustandsändernden Kommandos (SET, Modewechsel, Endpoints) werden mit
`BragiError.writesDisabled` abgewiesen, solange nicht das Entwickler-Flag
`dangerouslyAllowWrites` gesetzt wird — was weder App noch CLI je tun.
Firmware-/Flash-Kommandos sind in diesem Projekt nicht implementiert.
Das Gate ist durch Unit-Tests (`WriteGateTests`) abgesichert und bleibt
wörtlich unverändert; die Transportschicht dahinter (`BragiTransport`) ist
seit Issue #10 austauschbar, damit Framing, Gate und Reportlayout ohne
Hardware testbar sind.

## DDC/CI

Helligkeit, Kontrast, Farbpreset usw. laufen — wie bei jedem Monitor — über
DDC/CI, nicht über das Vendor-HID:

- VCP `0x10` Helligkeit, `0x12` Kontrast, `0x14` Farbpreset, `0x60` Eingang,
  `0x62` Lautsprecher, `0xD6` Power.
- Apple Silicon: private `IOAVService*`-I2C-Funktionen aus IOKit
  (Ansatz von m1ddc/MonitorControl), zur Laufzeit per `dlsym` aufgelöst.
- Intel-Macs: noch nicht unterstützt (anderer I2C-Pfad); Roadmap.
- Achtung: Manche USB-C-Docks/Adapter leiten DDC nicht weiter.

### DDC-Serviceauswahl (Issue #10)

`Location == "External"` allein genügt nicht, um einen brauchbaren
I2C-Service zu erkennen: Auf dem Testsystem trägt ein toter
`DCPAVServiceProxy` (ohne `DCPAVServiceProxyUserClient`-Kind und ohne
zugehörigen Framebuffer) ebenfalls `Location = "External"` und belegt
Index 0 — `--display 0` (der frühere Default) schlägt dort deterministisch
mit `IOReturn 0xE0114000` fehl.

Die Zuordnung Service → Display läuft über einen **Port-Tag**, nicht über
einen Registry-Aufstieg: `AppleCLCD2` (der Framebuffer, trägt
`DisplayAttributes` → `ProductAttributes` mit `ProductName`,
`LegacyManufacturerID`, `ProductID`, `SerialNumber`) ist **kein** Vorfahre
von `DCPAVServiceProxy` — beide hängen in getrennten Teilbäumen
(`dispext2@…` bzw. `dcpext2@…`), die sich erst bei einem gemeinsamen
Großelternteil treffen. Stattdessen trägt der **direkte Parent** jeder
Seite denselben Tag im Namen: `AppleCLCD2`s Parent heißt `dispext2`,
`DCPAVServiceProxy`s Parent heißt `dispext2:dcpav-service-epic:0`. Gleicher
Tag (Präfix bis zum ersten `:` bzw. `@`) = gleicher Anschluss.

Messdaten vom Testsystem (3 externe Displays):

```
== AppleCLCD2 ==
clcd parent=dispext0  product=BenQ RD280UA  vendor=2513 model=32915 serial=0
clcd parent=dispext1  product=BenQ RD280UA  vendor=2513 model=32915 serial=0
clcd parent=dispext2  product=XENEON EDGE   vendor=3672 model=60672 serial=16843009

== DCPAVServiceProxy (Location == External) ==
[0] dispextE  — (kein Framebuffer, kein UserClient)
[1] dispext2  XENEON EDGE   <- Edge
[2] dispext0  BenQ RD280UA
[3] dispext1  BenQ RD280UA
```

`vendor`/`model`/`serial` sind deckungsgleich mit `CGDisplayVendorNumber` /
`CGDisplayModelNumber` / `CGDisplaySerialNumber` der zugehörigen
`CGDirectDisplayID` — darüber findet `DDCControl.openEdge()` den richtigen
Service deterministisch, mit einem Produktnamen-Fallback und dem
Index-Pfad (`--display <n>`) als manueller Übersteuerung. Verifiziert:
`xeneonctl brightness` ohne `--display` liest seither `95%` (vorher:
`I2C transfer failed (IOReturn 0xE0114000)`).

## Quellen & Dank

- [aabdelghani/corsair-xeneon-edge-linux](https://github.com/aabdelghani/corsair-xeneon-edge-linux) — Bragi-Framing am echten Edge verifiziert (GPL-3.0)
- [jurkovic-nikola/OpenLinkHub](https://github.com/jurkovic-nikola/OpenLinkHub) — Xeneon-Edge-Unterstützung, Bragi-Kommandotabelle (GPL-3.0)
- [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) — `CorsairPeripheralV2Controller` (GPL-2.0)
- [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver) — Touch-IDs & Koordinatenraum unter macOS (MIT)
- [waydabber/m1ddc](https://github.com/waydabber/m1ddc) — IOAVService-DDC auf Apple Silicon (MIT)

Wegen der GPL-Herkunft wesentlicher Protokollfakten steht dieses Projekt
unter **GPL-3.0-or-later**.
