# Ausfuehrungsplan Issue #19 - Bitbucket-PR-Widget

Quelle: https://github.com/pascallink/MacOS-Corsair-Xenon/issues/19
Arbeitsbranch dieser Planung: `claude/bitbucket-pr-widget-fa0pm8` (auf `origin/develop`)

Dieser Plan folgt `.github/PLAN.template.md`: jeder Sub-Task ist ein Branch
und ein Pull Request, PR 1 auf `develop`, jeder weitere auf seinem
Vorgaenger (Stacked PRs). Umsetzung laeuft je Sub-Task ueber den Skill
`lokale-umsetzung` (Micro-Tasks, eine Datei, <= ~500 Zeilen); Eskalation an
den Subagenten `umsetzer`. Jeder Sub-Task endet mit dem Review-Prompt
(Stufe 1) fuer Opus.

## Kontext

Das Repo hat mit `ClaudeUsageWidget` bereits ein schwebendes Panel auf dem
Edge plus Menueleisten-Item (`WidgetAppDelegate.swift`), das alle 45 s einen
Snapshot neu baut und ihn in SwiftUI rendert. Dieselbe Mechanik fehlt fuer
den zweiten Dauerblick des Arbeitstages: den Stand der offenen Pull Requests
in Bitbucket. Heute kostet das einen Browser-Tab, mehrere Dashboard-Filter
und Handarbeit, um "wo haengt es an mir" von "wer haengt an mir" zu trennen.

Das Widget soll genau drei Zahlen je Zielgruppe liefern, nicht eine
PR-Liste nachbauen.

## Ziel

Ein eigenstaendiges Menueleisten-/Panel-Widget (`BitbucketWidget`), das je
konfiguriertem Ziel (Beispiel `refi/develop*`) drei Kennzahlen zeigt:

1. **Meine offenen, nicht genehmigten PRs** - ich bin Autor, PR ist `OPEN`
   und hat noch nicht genug Zustimmung; mit der Summe der offenen Aufgaben.
2. **Reviews an mir** - ich bin Reviewer und habe noch nicht genehmigt; mit
   der Summe der offenen Aufgaben.
3. **Fertig fuer Merge** - genehmigt, keine offenen Aufgaben; nur als Anzahl.

Gruppiert wird je Zielmuster, mehrere Muster ergeben mehrere Bloecke.

## Entscheidungen vorab

- **Bitbucket Data Center, REST 1.0.** Zielsystem ist die selbst gehostete
  Instanz, nicht Cloud. Gelesen wird ueber
  `GET /rest/api/1.0/dashboard/pull-requests?state=OPEN&role=AUTHOR` und
  dasselbe mit `role=REVIEWER` - zwei Requests je Refresh ueber alle
  Projekte hinweg, statt je Repository einer.
- **Aufgaben kommen aus `properties`.** Die DC-PR-Repraesentation liefert
  `properties.openTaskCount` und `properties.resolvedTaskCount` mit. Ein
  Zweitrequest je PR (`.../blocker-comments?count=true`) waere ein Request
  pro PR pro Refresh und bleibt deshalb aus; fehlt das Feld, zeigt die UI
  `-` statt einer erfundenen `0`.
- **Zielmuster = Projekt/Repo + Ziel-Branch.** Ein Muster ist ein Glob ueber
  `"<projekt>/<ziel-branch>"` (zwei Segmente, Beispiel `refi/develop*`) oder
  `"<projekt>/<repo>/<ziel-branch>"` (drei Segmente). Ein fuehrender Slash
  wird geschluckt, Projekt und Repo matchen case-insensitiv, der Branch ist
  der `displayId` von `toRef` (ohne `refs/heads/`). Ein PR zaehlt in genau
  eine Gruppe - das erste passende Muster gewinnt, sonst faellt er raus.
- **Token nie in der JSON.** Das HTTP Access Token kommt aus der Keychain
  (Generic Password, Service `xeneon-bitbucket`, Account = Host der
  Basis-URL), ersatzweise aus `XENEON_BITBUCKET_TOKEN`. Es wird nie
  geloggt, nie in einen Fehlertext gespiegelt und nie in
  `bitbucket-widget.json` geschrieben. Das ist hier eine andere Lage als
  bei `ClaudeUsageReader`: der Keychain-Eintrag gehoert diesem Widget, es
  liest keinen fremden.
- **"Genehmigt" ist konfigurierbar.** `requiredApprovals: Int = 1`, und ein
  `NEEDS_WORK` eines Reviewers hebt die Genehmigung auf. Der teure
  `can-merge`-Endpunkt bleibt ungenutzt; Merge-Konflikte sind nicht Teil
  der Aussage.
- **Netzwerk trennt sich vom Urteil.** Transport (`URLSession`, injizierbar)
  liegt getrennt von Parser und Auswertung; Parser und Gruppierung sind
  reine Funktionen und damit ohne Server testbar - dieselbe Aufteilung wie
  `CloudUsageFetcher.parseGistResponse`.
- **Eigenes Target statt Anbau.** `BitbucketWidget` laeuft getrennt vom
  Claude-Widget: eigene Config, eigener Lebenszyklus, eigenes
  Menueleisten-Item. Ein ausgefallener Bitbucket-Server darf die
  Claude-Anzeige nicht mitreissen.

Offene Annahmen, die bei der Umsetzung zu bestaetigen sind: `currentUser`
kommt aus der Config (kein Zusatzrequest gegen `/rest/api/1.0/users`), und
"fertig fuer Merge" ignoriert Merge-Konflikte und Build-Status bewusst.

## Technisches Risiko: Refresh-Last und Paginierung

Das Dashboard-Endpoint paginiert (`limit`, `start`, `isLastPage`,
`nextPageStart`). Bei vielen offenen PRs sind das mehrere Seiten je Rolle
und Refresh. Deshalb: `limit=50`, harter Deckel von fuenf Seiten je Rolle,
`refreshSeconds` auf `>= 60` geklemmt (Default 180), Timeout 10 s, und die
Filterung auf die Zielmuster passiert lokal nach dem Laden - ein
serverseitiger Filter ueber Branch-Globs existiert in REST 1.0 nicht.
Schlaegt ein Refresh fehl, bleibt der letzte erfolgreiche Stand stehen und
wird als veraltet markiert, statt auf Nullen zu springen.

## Sub-Tasks

### Sub-Task 1 - Modell und Zielmuster
- **Branch:** `feature/issue-19-part-1` (Base: `develop`), Scope `kit`
- **Erstellen:** `Sources/XeneonEdgeKit/Bitbucket/BitbucketModels.swift`
- `BitbucketPullRequest` (id, title, projectKey, repoSlug, targetBranch,
  authorName, reviewers, openTaskCount `Int?`, url, updatedAt),
  `BitbucketReviewer` (name, status `.approved` / `.unapproved` /
  `.needsWork`), `BitbucketTargetPattern` mit
  `static func parse(_ raw: String) -> BitbucketTargetPattern?` und
  `func matches(_ pr: BitbucketPullRequest) -> Bool`.
- Glob nur mit `*` (beliebig viele Zeichen, kein Slash), zwei oder drei
  Segmente, fuehrender Slash optional, Projekt/Repo case-insensitiv.
- Keine Netz-, IOKit- oder AppKit-Abhaengigkeit in dieser Datei - reine
  Regeln, analog `TouchMapping`.
- **Tests:** neue Datei `Tests/XeneonEdgeKitTests/BitbucketTests.swift`,
  Suite `BitbucketTargetPatternTests`: `refi/develop*` trifft
  `REFI/app -> develop-2026`, trifft nicht `refi/app -> main`;
  Drei-Segment-Muster grenzt Repos ab; `*` matcht keinen Slash; leeres
  oder kaputtes Muster ergibt `nil` statt einer Falle.
  Lauf: `./Scripts/test.sh --filter BitbucketTargetPatternTests`
- **DoD:** Muster deterministisch, Kanten getestet, Target baut.

### Sub-Task 2 - Parser fuer die Dashboard-Antwort
- **Branch:** `feature/issue-19-part-2` (Base: part-1), Scope `kit`
- **Erstellen:** `Sources/XeneonEdgeKit/Bitbucket/BitbucketResponseParser.swift`
- `static func parsePage(_ data: Data) -> BitbucketPage` mit
  `values: [BitbucketPullRequest]`, `isLastPage: Bool`,
  `nextPageStart: Int?`. Liest `toRef.displayId`,
  `toRef.repository.slug`, `toRef.repository.project.key`,
  `author.user.name`, `reviewers[].status` bzw. `.approved`,
  `properties.openTaskCount` (fehlend -> `nil`), `links.self[0].href`.
- Pure und synchron, kein `URLSession` in dieser Datei. Unbekannte oder
  fehlende Felder fuehren zum Auslassen des einzelnen PR, nie zum Abbruch
  der ganzen Seite.
- **Tests:** Suite `BitbucketParserTests` gegen ein eingebettetes
  Antwort-Fixture (eine Seite, drei PRs, einer ohne `properties`, einer mit
  `NEEDS_WORK`): Feldzuordnung, `isLastPage`/`nextPageStart`, kaputtes JSON
  ergibt leere Seite.
  Lauf: `./Scripts/test.sh --filter BitbucketParserTests`
- **DoD:** Fixture vollstaendig abgebildet, kein Crash bei Teilmuell.

### Sub-Task 3 - Client mit Auth und Paginierung
- **Branch:** `feature/issue-19-part-3` (Base: part-2), Scope `kit`
- **Erstellen:** `Sources/XeneonEdgeKit/Bitbucket/BitbucketClient.swift`,
  `Sources/XeneonEdgeKit/Bitbucket/BitbucketCredentials.swift`
- Client: `init(baseURL:token:session:)`, `func openPullRequests(role:)
  async throws -> [BitbucketPullRequest]`, Bearer-Header, `state=OPEN`,
  `limit=50`, Schleife bis `isLastPage` mit Deckel 5 Seiten,
  `timeoutInterval = 10`. Fehler als `BitbucketError`
  (`.unauthorized`, `.http(Int)`, `.transport`) - der Token taucht in
  keinem `description` und keinem `NSLog` auf.
- Credentials: Keychain-Lesung gekapselt hinter einem Protokoll
  `BitbucketTokenSource`, Default-Implementierung `SecItemCopyMatching`,
  Fallback `ProcessInfo.processInfo.environment["XENEON_BITBUCKET_TOKEN"]`.
  Kein Schreiben in die Keychain, kein Loeschen.
- **Tests:** Suite `BitbucketClientTests` mit `URLProtocol`-Stub: zwei
  Seiten werden zusammengefuehrt, `401` ergibt `.unauthorized`, der Deckel
  greift bei einem Server, der `isLastPage: false` endlos meldet; und ein
  Test, dass der Token in `String(describing:)` des Fehlers nicht vorkommt.
  Lauf: `./Scripts/test.sh --filter BitbucketClientTests`
- **DoD:** Kein Netzzugriff im Test, Paginierung und Fehlerpfade gruen.

### Sub-Task 4 - Auswertung und Gruppierung
- **Branch:** `feature/issue-19-part-4` (Base: part-3), Scope `kit`
- **Erstellen:** `Sources/XeneonEdgeKit/Bitbucket/BitbucketOverview.swift`
- `static func build(author:reviewer:patterns:currentUser:requiredApprovals:)
  -> BitbucketOverview` mit `groups: [BitbucketGroup]` je Muster; jede
  Gruppe traegt `mine`, `toReview`, `readyToMerge` als
  `(count: Int, openTasks: Int?)` bzw. reine Anzahl fuer `readyToMerge`.
- Regeln an genau einer Stelle: genehmigt = mindestens
  `requiredApprovals` Reviewer `.approved` **und** kein `.needsWork`;
  meine offenen = Autor ich und nicht genehmigt; zu reviewen = ich unter
  den Reviewern ohne `.approved`; merge-bereit = genehmigt und
  `openTaskCount == 0`. Ein PR, der in beiden Rollenlisten steht, wird
  ueber die PR-Id entduped.
- **Tests:** Suite `BitbucketOverviewTests`: PR mit einem Approval und
  einem `NEEDS_WORK` ist nicht merge-bereit; `requiredApprovals: 2`
  verschiebt die Zaehlung; `openTaskCount == nil` summiert zu `nil`, nicht
  zu `0`; PR ohne passendes Muster taucht nirgends auf; ueberlappende
  Muster zaehlen ihn genau einmal.
  Lauf: `./Scripts/test.sh --filter BitbucketOverviewTests`
- **DoD:** Zaehlregeln zentral, keine Doppelzaehlung, Kanten getestet.

### Sub-Task 5 - Target-Geruest und Config
- **Branch:** `feature/issue-19-part-5` (Base: part-4), Scope `repo`
- **Erstellen:** `Sources/BitbucketWidget/main.swift`,
  `Sources/BitbucketWidget/BitbucketWidgetConfig.swift`,
  `Sources/BitbucketWidget/BitbucketWidgetAppDelegate.swift`,
  `Resources/BitbucketWidget-Info.plist`
- **Aendern:** `Package.swift` (Product + `executableTarget`, Abhaengigkeit
  `XeneonEdgeKit`, AppKit/SwiftUI), `Scripts/bundle-app.sh` (drittes
  Bundle analog `ClaudeUsageWidget.app`), `commitlint.config.js`
  (`ALIASES`: `BitbucketWidget: 'bitbucket'`).
- Config als `~/Library/Application Support/XeneonEdge/bitbucket-widget.json`
  mit tolerantem `init(from:)` wie `WidgetConfig`: `baseURL: String = ""`,
  `currentUser: String = ""`, `targets: [String] = []`,
  `requiredApprovals: Int = 1`, `refreshSeconds: Double = 180`,
  `corner`, `margin`, `width`, `height`. Kein Token-Feld.
- Single-Instance-Guard und Fensteraufbau nach dem Muster aus
  `WidgetAppDelegate.swift`.
- **DoD:** `swift build` und `./Scripts/bundle-app.sh release` erzeugen
  `dist/BitbucketWidget.app`; leere Config startet ohne Absturz und zeigt
  den Hinweis "nicht konfiguriert"; `npm run lint:commits` akzeptiert
  `feat(bitbucket): ...`.

### Sub-Task 6 - ViewModel und Refresh-Zyklus
- **Branch:** `feature/issue-19-part-6` (Base: part-5), Scope `bitbucket`
- **Erstellen:** `Sources/BitbucketWidget/BitbucketViewModel.swift`
- `@Published var overview: BitbucketOverview`, `@Published var state:
  .loading / .ok(Date) / .stale(Date, String)`. Timer mit auf `>= 60`
  geklemmtem Intervall, Laden im Hintergrund, Zuweisung auf dem
  Main-Thread; ein laufender Refresh verhindert den naechsten (kein
  Ueberholen bei langsamem Server).
- Fehlender Token oder leere `baseURL` fuehrt zu einem definierten
  Konfigurationszustand, nicht zu einem Request.
- **DoD:** Fehlschlag laesst die letzten Zahlen stehen und markiert sie als
  veraltet; keine UI-Aktualisierung ausserhalb des Main-Threads.

### Sub-Task 7 - Widget-UI
- **Branch:** `feature/issue-19-part-7` (Base: part-6), Scope `bitbucket`
- **Erstellen:** `Sources/BitbucketWidget/BitbucketWidgetView.swift`
- Je Gruppe ein Block: Kopfzeile mit dem Muster (`refi/develop*`), darunter
  drei Zeilen - "Meine PR: n (m Aufgaben)", "Review: n (m Aufgaben)",
  "Merge-bereit: n". Fehlende Aufgabenzahl als `-`. Deutsch ohne Umlaute.
- Menueleisten-Titel zeigt die Summe der offenen Reviews ueber alle
  Gruppen; Klick auf eine Zeile oeffnet das passende Bitbucket-Dashboard
  im Browser.
- Veralteter Stand wird sichtbar abgesetzt (gedimmt plus Zeitstempel).
- **DoD:** Default-Groesse ohne Clipping bei drei Gruppen; kein
  Layout-Sprung zwischen `loading` und `ok`.

### Sub-Task 8 - Doku
- **Branch:** `feature/issue-19-part-8` (Base: part-7), Scope `repo`
- **Erstellen:** `docs/BITBUCKET-PR-WIDGET.md`
- **Aendern:** `CLAUDE.md` (Target-Tabelle um `bitbucket`), `README.md`,
  `INSTALL.md`
- Inhalt: Beispiel-`bitbucket-widget.json`, Syntax der Zielmuster mit zwei
  und drei Segmenten, Anlegen des HTTP Access Token (nur Leserecht) und
  sein Ablegen in der Keychain (`security add-generic-password -s
  xeneon-bitbucket -a <host> -w`), der Env-Fallback, die Zaehlregeln fuer
  "genehmigt" und "merge-bereit", und warum keine Aufgabenzahl je PR
  nachgeladen wird.
- **DoD:** Ein Leser kann das Widget ohne Blick in den Code konfigurieren.

## Abnahme (gesamt)

- [ ] Je Zielmuster ein Block mit den drei Kennzahlen, Aufgaben summiert.
- [ ] `refi/develop*` gruppiert projektweit ueber alle Repos mit passendem
      Ziel-Branch.
- [ ] Ein PR zaehlt nie in zwei Gruppen.
- [ ] Token steht nur in der Keychain oder der Env-Variable - nicht in der
      JSON, nicht im Log, nicht in einem Fehlertext.
- [ ] Ein nicht erreichbarer Server laesst den letzten Stand stehen und
      markiert ihn als veraltet.
- [ ] Hoechstens zwei Requests je Refresh und Seite, Intervall `>= 60` s.
- [ ] Volle CI-Kette gruen: `swift build && ./Scripts/test.sh && swift build
      -c release && ./Scripts/bundle-app.sh release`.

## Nicht in diesem Plan

- Bitbucket Cloud (REST 2.0) - anderer Dialekt, andere Tasks-API.
- Aktionen aus dem Widget heraus (genehmigen, mergen, Aufgaben abhaken).
- Anzeige von PR-Titeln, Kommentartexten oder Diffs - das Widget zaehlt,
  es liest nicht mit.
- Eine UI zum Pflegen der Ziele; `targets` wird in der JSON gepflegt.
- Merge-Konflikte oder Build-Status als Kriterium fuer "fertig fuer Merge".
