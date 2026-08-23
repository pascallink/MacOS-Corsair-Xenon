# CORSAIR XENEON EDGE — Technische Notizen (macOS)

Alle Protokollfakten stammen aus öffentlichem Community-Reverse-Engineering
und eigenen Ableitungen; es wurde kein proprietärer Code verwendet.

## Gerätetopologie

Das XENEON EDGE meldet sich am USB-Bus als **mehrere unabhängige Geräte**:

| Funktion | USB-ID | Typ | Zugriff unter macOS |
|---|---|---|---|
| Bildausgabe | — | USB-C DP-Alt-Mode oder HDMI 2.0 | Normaler Monitor (2560×720), keine Treiber nötig |
| Touchscreen | `27c0:0859` | HID-Digitizer (5-Punkt kapazitiv) | IOHIDManager; macOS hat keinen Touchscreen-Support → dieser Treiber übersetzt in Mausereignisse |
| Steuerinterface | `1b1c:1d0d` | Vendor-HID (Usage Page `0xFF1B`) | IOHIDManager, 64-Byte-Reports |
| Bildeinstellungen | — | DDC/CI über den I2C-Kanal des Displaykabels | IOAVService (Apple Silicon) |

## Touchscreen (verifiziert durch die Community)

- Report: Generic Desktop `X` (Usage `0x30`) und `Y` (Usage `0x31`), absolut.
- Logischer Wertebereich: X `0–16383`, Y `0–9599` (wird zur Sicherheit zur
  Laufzeit aus den HID-Elementen gelesen).
- Kontaktzustand: Button-Page `0x09`, Usage `0x01` (dieser Controller) bzw.
  Digitizer Tip Switch `0x0D/0x42` (Standard).
- Der Treiber normalisiert die Rohkoordinaten, wendet optional Rotation /
  Spiegelung an und bildet auf die globalen CoreGraphics-Koordinaten des
  Edge-Displays ab. Injektion über `CGEvent` (links/rechts, Drag, Doppelklick,
  Langdruck = Rechtsklick).

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

Schreibkommandos, die den Gerätezustand ändern, werden von dieser App nur auf
ausdrückliche Nutzeraktion gesendet (Menü „Gerät abfragen“ sendet nur den
verifizierten GET).

## DDC/CI

Helligkeit, Kontrast, Farbpreset usw. laufen — wie bei jedem Monitor — über
DDC/CI, nicht über das Vendor-HID:

- VCP `0x10` Helligkeit, `0x12` Kontrast, `0x14` Farbpreset, `0x60` Eingang,
  `0x62` Lautsprecher, `0xD6` Power.
- Apple Silicon: private `IOAVService*`-I2C-Funktionen aus IOKit
  (Ansatz von m1ddc/MonitorControl), zur Laufzeit per `dlsym` aufgelöst.
- Intel-Macs: noch nicht unterstützt (anderer I2C-Pfad); Roadmap.
- Achtung: Manche USB-C-Docks/Adapter leiten DDC nicht weiter.

## Quellen & Dank

- [aabdelghani/corsair-xeneon-edge-linux](https://github.com/aabdelghani/corsair-xeneon-edge-linux) — Bragi-Framing am echten Edge verifiziert (GPL-3.0)
- [jurkovic-nikola/OpenLinkHub](https://github.com/jurkovic-nikola/OpenLinkHub) — Xeneon-Edge-Unterstützung, Bragi-Kommandotabelle (GPL-3.0)
- [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) — `CorsairPeripheralV2Controller` (GPL-2.0)
- [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver) — Touch-IDs & Koordinatenraum unter macOS (MIT)
- [waydabber/m1ddc](https://github.com/waydabber/m1ddc) — IOAVService-DDC auf Apple Silicon (MIT)

Wegen der GPL-Herkunft wesentlicher Protokollfakten steht dieses Projekt
unter **GPL-3.0-or-later**.
