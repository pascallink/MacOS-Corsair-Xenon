# Projekt: MacOS-Corsair-Xenon

Dies ist die zentrale Anweisungsdatei (`claude.md`) für Claude Code zur Entwicklung der Mac-App für den **Corsair Xenon Edge**.

## Projektpfad
`Workspace: /Volumes/Sources/tools/MacOS-Corsair-Xenon`

## ⚠️ Oberste Entwicklungsrichtlinie: Local First
- **Immer zuerst lokal arbeiten:** Jegliche Code-Erstellung, Änderungen und Tests müssen zwingend **lokal** durchgeführt werden.
- **Remote Repositories zweitrangig:** Es existiert ein Remote GitHub-Repository, dieses darf jedoch **nicht** für ungetesteten Code verwendet werden. Keine direkten Commits oder Pushes auf den Remote-Server ohne vorherige lokale Validierung.
- **Isolierte Entwicklung:** Erstelle lokale Branches für neue Features oder Bugfixes.

## Build- und Test-Anweisungen

### Toolchain auf diesem Rechner
Es sind **nur die Command Line Tools** installiert, **kein** vollständiges
Xcode (`xcode-select -p` → `/Library/Developer/CommandLineTools`). Daraus
folgt:
- `xcodebuild` steht **nicht** zur Verfügung. Gebaut wird ausschließlich mit
  `swift build` bzw. den Skripten unter `Scripts/`.
- **`XCTest` existiert auf diesem System nicht** — es wird nur mit Xcode
  ausgeliefert. Tests, die `import XCTest` verwenden, sind hier prinzipiell
  nicht lauffähig.
- Ein Wechsel per `sudo xcode-select -s /Library/Developer/CommandLineTools`
  ändert daran nichts — das ist bereits der aktive Zustand.

### Testframework: swift-testing, nicht XCTest
Die Unit-Tests nutzen **swift-testing** (`import Testing`, `@Suite`, `@Test`,
`#expect`, `#require`), weil dessen `Testing.framework` im Gegensatz zu
XCTest auch den Command Line Tools beiliegt. **Neue Tests deshalb niemals in
XCTest schreiben** — sie wären lokal nicht ausführbar und würden die
„Local First"-Richtlinie unterlaufen.

SwiftPM verdrahtet die CLT-Kopie des Frameworks nicht von selbst; die nötigen
Such- und Runtime-Pfade kapselt `Scripts/test.sh`. Lokal deshalb immer:

```bash
./Scripts/test.sh          # statt: swift test
```

Auf einem Rechner mit vollem Xcode fällt das Skript automatisch auf ein
schlichtes `swift test` zurück — genau das ruft auch die GitHub-CI auf,
`.github/workflows/build.yml` braucht dafür keine Anpassung.

### Vollständige CI-Kette lokal
Die vier Schritte aus `.github/workflows/build.yml` lassen sich damit
komplett lokal nachstellen — vor jedem Commit durchlaufen lassen:

```bash
swift build && ./Scripts/test.sh && swift build -c release && ./Scripts/bundle-app.sh release
```

- **Lokale Tests:** Alle Tests müssen lokal erfolgreich durchlaufen, bevor
  committet wird. Die CI ist die Zweitmeinung, nicht die Erstprüfung.
- **Hardware-Simulation/Test:** Da es sich um eine App für den Corsair Xenon Edge (Monitor) handelt, stelle sicher, dass die Gerätekommunikation (z.B. DDC/CI oder USB-HID) entweder mit dem echten Gerät lokal getestet oder über Protokolle gemockt wird.

## Git Workflow (Strikt)
1. **Branching:** Nutze lokale Branches für die Entwicklung (`git checkout -b feature/mein-neues-feature`).
2. **Entwicklung & Build:** Code schreiben und lokal fehlerfrei kompilieren.
3. **Testing:** App lokal ausführen und Funktionalität prüfen.
4. **Lokaler Commit:** Änderungen lokal mit aussagekräftigen Nachrichten committen.
5. **Push (Nur nach Freigabe):** Erst wenn der Code lokal vollständig verifiziert ist, darf ein `git push` auf das Remote-Repository erfolgen.

## Systemanweisungen an Claude
- Behalte den Projektpfad `/Volumes/Sources/tools/MacOS-Corsair-Xenon` immer im Kontext.
- Agiere als erfahrener macOS/Swift-Entwickler.
- Führe **keine** `git push` Befehle selbstständig aus. Gehe immer davon aus, dass Änderungen erst lokal iteriert werden.