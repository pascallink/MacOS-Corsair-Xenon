# Termine — Terminwarnung aus dem Google Kalender auf dem Xeneon Edge

Die Terminwarnung holt deinen Google Kalender über die geheime iCal-Adresse
(ein schreibgeschützter Feed, kein Google-Login, kein API-Schlüssel) und zeigt
die nächsten Termine mit Countdown. Je näher ein Termin rückt, desto
auffälliger wird die Karte: von Grün über Gelb und Orange bis zu Rot, in der
letzten Minute pulsierend. So verpasst du keinen Termin, auch wenn das Edge am
Rand deines Blickfelds hängt.

![Layout] Uhrzeit · Titel · Countdown (mm:ss) · Fortschrittsbalken bis zum
Start · Farbe nach Restzeit

## Was es anzeigt

| Element | Inhalt |
|---|---|
| **Warnzeile** je Termin | Startzeit (HH:mm), Titel, Countdown als `mm:ss` (ab einer Stunde `h:mm:ss`) und ein Balken, der sich bis zum Start füllt |
| **Anzahl** | die nächsten `maxReminders` Termine (Standard 2), nach Startzeit sortiert; weitere stehen als „+N weitere“ darunter |
| **Zeitfenster** | alle Termine, die in den nächsten `leadMinutes` beginnen (Standard 60 min); ein begonnener Termin bleibt noch `graceMinutes` (Standard 2 min) sichtbar, der Countdown zeigt dann „laeuft“ |
| **Nächster Termin** | Liegt keine Warnung an, zeigt das Panel ruhig den nächsten Termin (siehe unten) |
| **Hinweise** | „kein Kalender-Feed eingerichtet“, „keine Termine in den naechsten N Tagen“ (bzw. „keine Termine bis morgen“), „Stand veraltet“ |

Abgesagte Termine (`STATUS:CANCELLED`) und Ganztagstermine erscheinen nie.
Serientermine werden zu konkreten Einzelterminen aufgelöst, einschließlich
ausgenommener Tage (`EXDATE`) und verschobener Einzeltermine
(`RECURRENCE-ID`); die Uhrzeit bleibt über die Zeitumstellung stabil.

### Nächster Termin

Steht keine Warnung im Vorlauf an, zeigt das Panel „Termine“ statt eines
leeren Felds den nächsten Termin, ruhig und ohne Farbe, Balken oder Puls:

| Element | Inhalt |
|---|---|
| Beschriftung | „Naechster Termin“ |
| Zeitangabe | heute `HH:mm`, morgen `morgen 09:00`, bis 6 Tage voraus der Wochentag (`Mi 09:00`), danach `dd.MM. HH:mm` |
| Titel | nur mit `showEventTitles` (Standard an) |
| Restzeit | relativ, etwa `in 25 min`, `in 2 h 15 min` oder `in 3 Tagen`; Minutentakt, kein Sekundenzähler |

Gesucht wird der früheste Termin hinter dem Vorlauf, höchstens
`nextHorizonDays` Tage voraus (Standard 7). Es gelten dieselben Filter wie
bei den Warnungen: Ganztagstermine, abgesagte und von dir abgelehnte Termine
erscheinen nie. Gibt es im Horizont keinen, steht dort „keine Termine in den
naechsten N Tagen“ (bei einem Tag „keine Termine bis morgen“). Mit
`"showNextEvent": false` entfällt die Anzeige, das Panel zeigt dann wieder
„keine Termine in der naechsten Stunde“ (bzw. „… in den naechsten N Minuten“).

Rückt der Termin in den Vorlauf, wird er sekundengenau zur Warnung mit
Countdown und Eskalationsstufen (siehe unten). Das Menüleisten-Widget zeigt
den nächsten Termin nicht: seine Karte erscheint nur bei Warnungen.

### Die Eskalationsstufen

Die Farbe richtet sich nach der Restzeit bis zum Start:

| Restzeit | Farbe | Darstellung |
|---|---|---|
| 60 bis 30 min | grün | nur der Countdown ist gefärbt |
| 30 bis 15 min | gelb (Corsair-Gelb) | dito |
| 15 bis 5 min | orange | zusätzlich ein farbiger Rand um die Karte |
| 5 bis 1 min | rot | Rand und leichte rote Tönung der Karte |
| unter 1 min (und laufend) | rot, **pulsierend** | die Zeile pulsiert, Rand und Tönung bleiben |

Die Stufen hängen an der Restzeit, nicht am Vorlauf: Wer `leadMinutes` auf
120 stellt, sieht die ersten 90 Minuten durchgehend grün. Eine Grenze gehört
zur ruhigeren Stufe (bei genau 15:00 min noch Gelb). Bei mehreren Warnungen
bestimmt die dringendste Rand und Tönung der Karte.

## Zwei Betriebsarten

1. **Panel „Termine“ im XeneonEdge-Dashboard:** Es steht in der linken
   Spalte unter der Uhr. In der Menüleiste der
   XeneonEdge-App → **Widgets → Termine** einschalten (entspricht
   `"showCalendar": true` in der `config.json`, Standard: aus). Das Panel
   erscheint sofort im Dashboard, kein Neustart. Ohne eingerichteten Feed
   zeigt es „kein Kalender-Feed eingerichtet“.
2. **Karte im Menüleisten-Widget** (`ClaudeUsageWidget.app`): Schalter
   `showCalendar` in der `claude-widget.json` (Standard: **an**). Die Karte
   steht **über** der Nutzungsanzeige und erscheint nur, solange es eine
   Warnung gibt. Das Fenster wächst genau um die Karte (samt Abstand) und
   bleibt dabei an der konfigurierten Ecke (`corner`) verankert: unten
   rechts wächst es also nach oben, oben links nach unten. Ist die Warnung
   vorbei, schrumpft es wieder. Ab **15 min** Restzeit (Stufe Orange) zeigt
   zusätzlich die Menüleiste einen Kurztitel neben dem Tacho-Symbol, für die
   dringendste Warnung:

   | Restzeit | Menüleistentitel |
   |---|---|
   | 15 min bis 1 min | `14:30 - 12 min` (Startzeit, aufgerundete Minuten) |
   | unter 1 min | `14:30 - jetzt` |
   | schon begonnen | `14:30 - laeuft` |

   Davor zeigt die Menüleiste nur das Symbol.

Beide können parallel laufen; jede ruft den Feed selbst ab (siehe Grenzen).
Beide lesen dieselbe `calendar.json`.

## Einrichtung

1. **Adresse kopieren:** In Google Kalender (im Browser, calendar.google.com)
   neben dem Kalender auf die drei Punkte → **Einstellungen und Freigabe**.
   Im Abschnitt **Kalender integrieren** steht **Geheime Adresse im
   iCal-Format**. Diese URL kopieren. Sie sieht so aus:

   ```
   https://calendar.google.com/calendar/ical/<kalender-id>/private-<schluessel>/basic.ics
   ```

2. **`calendar.json` anlegen** unter
   `~/Library/Application Support/XeneonEdge/calendar.json`:

   ```json
   {
     "enabled": true,
     "feedURL": "https://calendar.google.com/calendar/ical/<kalender-id>/private-<schluessel>/basic.ics"
   }
   ```

   Alle anderen Felder sind optional und haben Standardwerte (siehe
   Optionstabelle). Die Datei muss nicht vollständig sein.
3. **Einschalten:** Im Dashboard unter **Widgets → Termine** das Panel
   aktivieren; im Widget ist die Karte ab Werk an.
4. **Neu laden:** In der Menüleiste **Konfiguration neu laden** wählen (bei
   der App wie beim Widget). Der erste Abruf läuft sofort; ohne Termin im
   Vorlauf bleibt es im Widget still; das Panel zeigt den nächsten Termin
   oder „keine Termine in den naechsten 7 Tagen“.

Nach jeder Änderung an der `calendar.json` genügt dasselbe „Konfiguration neu
laden“. Ist die Datei kaputt (JSON-Syntaxfehler), laufen die Standardwerte, der
Feed ist dann nicht eingerichtet; im Log steht nur „calendar.json nicht
lesbar“, nie ein Dateiinhalt.

### Öffentliche oder geheime Adresse

Google bietet zwei Adressen an:

- Die **öffentliche Adresse** (`…/ical/<kalender-id>/public/basic.ics`)
  funktioniert nur, wenn der Kalender **öffentlich freigegeben** ist. Sonst
  antwortet Google mit HTTP 404, und das Panel zeigt nach drei erfolglosen
  Versuchen „Stand veraltet“. Für einen Firmenkalender ist das
  Öffentlichmachen nicht empfehlenswert.
- Die **geheime Adresse** (`…/private-<schluessel>/basic.ics`) funktioniert
  ohne Freigabe. Fehlt der Eintrag „Geheime Adresse im iCal-Format“, hat der
  Google-Workspace-Administrator ihn gesperrt; dann bleibt nur die Bitte an
  die IT oder ein anderer Kalender.

Ein Freigabelink der Form `calendar.google.com/calendar/u/0?cid=…` ist
**kein Feed**: er öffnet nur die Kalenderansicht im Browser.

## Optionen (`calendar.json`)

| Option | Standard | Wirkung |
|---|---|---|
| `enabled` | `false` | Hauptschalter. Ohne `true` wird nie ein Request gebaut |
| `feedURL` | `""` | geheime iCal-Adresse. Nur `https` mit Host wird je abgerufen; Leerzeichen am Rand werden entfernt |
| `leadMinutes` | `60` | Vorlauf: so viele Minuten vor dem Start erscheint ein Termin (geklemmt auf 5 bis 240) |
| `graceMinutes` | `2` | so lange bleibt ein bereits begonnener Termin mit „laeuft“ stehen (geklemmt auf 0 bis 30) |
| `maxReminders` | `2` | wie viele Warnzeilen gleichzeitig; der Rest steht als „+N weitere“ da (geklemmt auf 1 bis 4) |
| `pollSeconds` | `300` | Abstand zwischen zwei Feed-Abrufen in Sekunden (geklemmt auf 60 bis 3600) |
| `showEventTitles` | `true` | `false` zeigt nur Uhrzeit und Countdown, keinen Titel |
| `showNextEvent` | `true` | `false` blendet den nächsten Termin im Panel aus; ohne Warnung steht dann nur der Leertext |
| `nextHorizonDays` | `7` | so viele Tage voraus wird der nächste Termin gesucht (geklemmt auf 1 bis 31) |
| `feedOwnerEmail` | `""` | deine Adresse im Kalender; Termine, die du abgesagt hast (`PARTSTAT=DECLINED`), erzeugen keine Warnung |

Zahlen außerhalb des Bereichs werden auf den nächsten Randwert gesetzt, nicht
auf den Standard. Fehlt ein Feld, gilt sein Standard, eine Datei mit nur einem
Schlüssel ist also gültig. Ein Feld mit falschem Typ (etwa `"leadMinutes":
"60"` als Text) macht dagegen die ganze Datei unlesbar: dann laufen alle
Standardwerte, der Feed gilt als nicht eingerichtet.

**`feedOwnerEmail`:** Im Feed können auch Termine stehen, die du
abgelehnt hast; sie tragen dann bei deiner Adresse den Teilnehmerstatus
`DECLINED`. Trage deine Kalenderadresse ein, damit sie keine Warnung
auslösen (Groß-/Kleinschreibung ist egal). Ohne Eintrag werden abgelehnte
Termine nicht ausgefiltert.

Das Widget hat nur einen eigenen Schalter: **`showCalendar`** in der
`claude-widget.json` (Standard `true`). Alles andere steht in der
`calendar.json`.

## Datenschutz

Die geheime Adresse ist ein **Zugangsschlüssel in URL-Form**: Wer sie kennt,
liest deinen ganzen Kalender, ohne Anmeldung. Deshalb:

- Sie steht ausschließlich in der `calendar.json` (Rechte `0600`, nur du
  kannst sie lesen; eine von Hand angelegte Datei mit weiteren Rechten wird
  beim Laden auf `0600` gesetzt).
- Sie wird **nie geloggt** und nie in einer Fehlermeldung ausgegeben und nie
  im Panel angezeigt. Das Log nennt höchstens den Host (`https://calendar.google.com`)
  und den HTTP-Status.
- Der Abruf läuft über eine eigene flüchtige Session ohne Festplatten-Cache;
  die URL landet nicht in einem Cache. Umleitungen auf Nicht-`https` werden
  verworfen, ebenso Antworten über 20 MB.
- Gib die `calendar.json` nie weiter, committe sie nicht und füge die URL
  nicht in Issues oder Screenshots ein. Ist sie doch gelandet: in den
  Google-Kalendereinstellungen die geheime Adresse zurücksetzen, die alte
  Adresse wird dadurch ungültig.
- Hängt das Edge nicht privat (Büro, Besprechungsraum), setze
  `"showEventTitles": false`. Dann bleiben nur Uhrzeit und Countdown stehen.
  Auch die Menüleiste des Widgets zeigt dann nur Uhrzeit und Restzeit; der
  nächste Termin im Panel zeigt dann nur Zeitangabe und Restzeit.

## Grenzen (ehrlich)

- **Ganztagstermine werden nie angezeigt**, auch nicht „heute“.
- **Der Google-Feed aktualisiert sich träge** (Minuten, nicht Sekunden).
  Ein spontan eingetragener Termin, der in fünf Minuten beginnt, kann im Feed
  noch fehlen. Das ist Googles Verzögerung, kein Fehler der App.
- Ein **im Kalender neu angelegter Termin** ist erst nach dem nächsten
  Abruf bekannt, also nach höchstens `pollSeconds` (plus Googles eigene
  Verzögerung). Ein bereits bekannter Termin, der in den Vorlauf rückt, wird
  dagegen sekundengenau zur Warnung: ein Timer löst zum Eintritt aus, solange
  eine Warnung steht, wird die Auswahl sekündlich neu getroffen.
- **Kein Schreibzugriff:** der Feed ist nur lesbar, die App ändert,
  bestätigt oder löscht nichts im Kalender.
- **Bei Netzausfall bleibt der letzte Stand stehen** und der Countdown läuft
  weiter. Nach drei erfolglosen Abrufen in Folge erscheint „Stand
  veraltet“; der nächste erfolgreiche Abruf nimmt den Hinweis zurück.
- **Nicht unterstützte Serienregeln:** `BYSETPOS`, `BYWEEKNO`, `BYYEARDAY`,
  Stunden- oder Minutenangaben (`BYHOUR`, `BYMINUTE`, `BYSECOND`) und
  stündliche oder minütliche Wiederholungen werden nicht aufgelöst. Der
  Termin erscheint dann nur als **Einzeltermin** (der erste), nicht als
  Serie. Gleiches gilt für Ordnungszahlen in `BYDAY` (etwa `2TU`) bei
  täglicher oder wöchentlicher Wiederholung sowie für jährliche Regeln mit
  `BYDAY` oder `BYMONTHDAY` ohne `BYMONTH`.
- **Dashboard-App und Widget rufen den Feed jeweils selbst ab.** Laufen
  beide, sind es zwei Abrufe pro Intervall; ein ETag erspart Google die
  Übertragung unveränderter Feeds.
- Es gibt genau eine `feedURL`; mehrere Kalender werden nicht
  zusammengeführt.

## Lokal testen ohne Google

```bash
./Scripts/sample-calendar.sh                # schreibt $TMPDIR/xeneon-sample.ics
./Scripts/sample-calendar.sh /pfad/test.ics # oder an einen eigenen Ort
```

Das Skript erzeugt eine Beispieldatei mit Terminen **relativ zur aktuellen
Zeit**: in 50 Sekunden, 4, 12, 25 und 50 Minuten, einen vor einer Minute
begonnenen, einen abgesagten und einen Ganztagstermin, also alle Stufen und
die beiden Ausschlüsse. Damit mehr als zwei Zeilen erscheinen, in der
`calendar.json` `"maxReminders": 4` setzen. Der **Debug-Build** liest sie über die
Umgebungsvariable `XENEON_CALENDAR_ICS_FILE` statt des Feeds (im
Release-Build gibt es diese Variable nicht). `calendar.json` ist dann nicht
nötig, Vorlauf und Co. kommen aus ihr oder den Standardwerten.

```bash
swift build

# Dashboard (Widgets → Termine einschalten):
XENEON_CALENDAR_ICS_FILE="$TMPDIR/xeneon-sample.ics" .build/debug/XeneonEdgeApp

# Menüleisten-Widget:
XENEON_CALENDAR_ICS_FILE="$TMPDIR/xeneon-sample.ics" .build/debug/ClaudeUsageWidget
```

Die Termine wandern mit der Zeit durch die Stufen; zum erneuten Durchlauf das
Skript noch einmal ausführen und „Konfiguration neu laden“ wählen. Die
Auswahl-, Stufen- und Parserlogik ist zusätzlich durch Unit-Tests abgedeckt
(`./Scripts/test.sh`).
