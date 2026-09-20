# Testsuiten (MacOS-Corsair-Xenon)

Ausgelagert aus der Root-`CLAUDE.md` (dort knapp gehalten): Details zur
Testsuite braucht man nur, wenn man an Tests selbst arbeitet oder eine neue
Suite anlegt.

Kein Xcode auf Pascals Rechner, nur die Command Line Tools - deshalb
**swift-testing** (`import Testing`) statt XCTest: `Testing.framework` liegt
den CLT bei, `XCTest.framework` wird ausschliesslich mit Xcode ausgeliefert.
Eine Suite mit `import XCTest` ist auf diesem System nicht lauffaehig, egal
wie sie in CI aussieht - das widerspricht "Local First" direkt. SwiftPM
verdrahtet die CLT-Kopie des Frameworks nicht von selbst, deshalb laeuft jeder
Testaufruf ueber `./Scripts/test.sh`, nie ueber ein blankes `swift test`
(Suchpfade dazu im Skript selbst).

Es gibt hier keine Browser- und keine Hardware-Tests ohne angeschlossenes
Geraet: Bragi-Transport (HID), DDC-Services (IOKit) und der Touch-Digitizer
werden ueber aufzeichnende Doubles (`RecordingBragiTransport`,
`RecordingTouchSink`, feste `DDCServiceInfo`-Fixtures) gemockt. Ein Test, der
den echten Xeneon Edge braucht, gehoert nicht in `Tests/` - der laeuft manuell
gegen das Geraet, nicht automatisiert.

## Suiten-Landkarte

Eine Suite = eine Datei unter `Tests/XeneonEdgeKitTests/`. Jede Quelldatei
gehoert zu genau einer Suite, Schnitt entlang der Verantwortung im Quellcode.

| Suite | Quellen | Tests |
| --- | --- | --- |
| `BragiFrameTests` | `Sources/XeneonEdgeKit/Bragi/BragiFrame.swift` | 17 |
| `BragiTransportTests` | `Sources/XeneonEdgeKit/Bragi/BragiTransport.swift`, `BragiDevice.swift` | 10 |
| `ClaudeSessionTests` | `Sources/XeneonEdgeKit/ClaudeUsage/ClaudeSessionReader.swift`, `ClaudeSessionModels.swift` | 18 |
| `ClaudeUsageTests` | `Sources/XeneonEdgeKit/ClaudeUsage/ClaudeUsageReader.swift`, `ClaudeUsageModels.swift` | 26 |
| `DDCServiceTests` | `Sources/XeneonEdgeKit/DDC/DDCServiceLocator.swift`, `DDCControl.swift` | 8 |
| `TouchDriverTests` | `Sources/XeneonEdgeKit/Touch/TouchDriver.swift`, `TouchEventSink.swift` | 27 |
| `TouchMappingTests` | `Sources/XeneonEdgeKit/Touch/TouchMapping.swift` | 15 |

Aktuelle Testzahlen: `grep -c '@Test' Tests/XeneonEdgeKitTests/<Suite>.swift`
je Datei, oder die Gesamtausgabe von `./Scripts/test.sh`.

## Verzeichnisstruktur

```
Tests/
  XeneonEdgeKitTests/
    BragiFrameTests.swift
    BragiTransportTests.swift
    ClaudeSessionTests.swift
    ClaudeUsageTests.swift
    DDCServiceTests.swift
    TouchDriverTests.swift
    TouchMappingTests.swift
```

Ein Testtarget, keine `test/lib/`-Ebene: Doubles wie `RecordingBragiTransport`
und `RecordingTouchSink` liegen direkt in der Datei, die sie braucht, weil sie
bisher nur von einer Suite verwendet werden. Braucht eine zweite Suite dasselbe
Double, wandert es in eine eigene Datei im selben Testtarget - eine
`test/lib/`-Ebene wie bei webkit-ext lohnt sich erst ab echtem Mehrfachbedarf.

## Runner: `./Scripts/test.sh`

```
./Scripts/test.sh                        alles
./Scripts/test.sh --filter TouchMapping  eine Suite (Substring-Match auf den Suite-Namen)
./Scripts/test.sh --filter "rawZero"     ein Einzelfall (Substring-Match auf den Testnamen)
```

Das Skript reicht `"$@"` unveraendert an `swift test` durch und ergaenzt nur
die CLT-Suchpfade (`-F`/`-rpath` auf `Testing.framework`), wenn kein volles
Xcode aktiv ist - `--filter` ist also `swift test`s eigene Option
(`swift test --help`), keine Eigenentwicklung. Unter vollem Xcode fällt das
Skript auf ein schlichtes `swift test "$@"` zurueck, das ruft auch die
GitHub-CI so auf (`.github/workflows/build.yml`).

Fehlt `Testing.framework` unter einem Command-Line-Tools-Pfad, bricht das
Skript hart ab statt auf `swift test` zurueckzufallen: das ist eine kaputte
oder unvollstaendige CLT-Installation, kein volles Xcode. Ohne diesen Abbruch
wuerde der Rueckfall spaeter mit "no such module 'Testing'" an der
alphabetisch ersten Testdatei scheitern - eine irrefuehrende Fehlermeldung,
die auf den Testcode statt auf die Installation zeigt. Ebenso bricht das
Skript ab, wenn `xcode-select -p` fehlschlaegt oder der gemeldete Pfad zu
keinem der beiden bekannten Faelle (CLT oder Xcode.app) passt.

## Waehrend der Arbeit vs. vor dem Commit

- **Waehrend der Arbeit:** ausschliesslich `./Scripts/test.sh --filter <Suite>`
  fuer die betroffene Suite. Kein Gesamtlauf, um zwischendurch zu schauen, ob
  noch alles gruen ist.
- **Vor dem finalen Commit:** einmal die volle CI-Kette aus der Root-`CLAUDE.md`:
  `swift build && ./Scripts/test.sh && swift build -c release &&
  ./Scripts/bundle-app.sh release`. Rot heisst zurueck in den Suite-Lauf, nicht
  in den naechsten Gesamtlauf.

## Neue Suite anlegen

1. Datei `Tests/XeneonEdgeKitTests/<Suite>Tests.swift` anlegen, `@Suite struct
   <Suite>Tests` als Wrapper, `@Test func ...()` je Fall.
2. Zeile in der Suiten-Landkarte oben ergaenzen (Quellen, Testzahl).
3. `./Scripts/test.sh --filter <Suite>` laufen lassen, bevor die Suite in
   einen Commit geht.
4. Geraetezugriffe (HID, IOKit, CoreAudio) immer hinter einem Protokoll
   mocken, wie `BragiTransport`/`TouchEventSink` es vormachen - eine neue
   Suite, die den echten Xeneon Edge braucht, gehoert nicht hierher.
