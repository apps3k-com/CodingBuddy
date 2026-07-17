# Benutzerhandbuch (DE)

CodingBuddy ist eine native macOS-App zur Verwaltung der Environment Variables in deinen zsh-Dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — ganz ohne Terminal.

## Variablen durchsuchen

- Die **Seitenleiste** ordnet Ziele nach Aufgaben: **Fokus**, **Umgebung**, **AI-Tools**, **Zustand & Sicherheit**, **Repositories** und **Wartung**. Unter Umgebung stehen *Alle Variablen* und je ein Eintrag pro Dotfile. Ein Zahlen-Badge erscheint nur nach vollständig geladener Quelle; fehlende oder noch nicht geprüfte Quellen bleiben neutral, eine orange Warnung markiert verweigerte oder unvollständige Daten. Noch nicht existierende Dateien sind ausgegraut; legst du dort eine Variable an, wird die Datei erstellt.
- Die obersten Seitenleisten-Gruppen lassen sich ein- und ausklappen. CodingBuddy merkt sich sowohl eingeklappte Gruppen als auch das zuletzt gewählte Ziel.
- Die **Tabelle** zeigt Name, Wert und Quelldatei. Mit dem Suchfeld (⌘F) filterst du nach Name oder Wert.
- Ein 🔒 **Schloss-Symbol** markiert komplexe Zeilen (Command Substitution wie `$(date)`, Mehrfach-Zuweisungen wie `export A=1 B=2`). CodingBuddy zeigt sie ehrlich an, schreibt sie aber nie um — solche Zeilen bearbeitest du besser im Texteditor.
- Ein oranges **überschrieben**-Badge bedeutet: Eine spätere Zuweisung gewinnt. zsh lädt `.zshenv → .zprofile → .zshrc`, innerhalb einer Datei gilt die letzte Zuweisung.
- Der Toolbar-Schalter **Überschriebene ausblenden** (Augen-Symbol) blendet überschattete Zuweisungen aus, sodass nur die tatsächlich wirksamen Werte sichtbar bleiben — die Liste behält ihre Datei-/Zeilenreihenfolge. Der *.env-Export* exportiert, was du siehst, und enthält dann nur die wirksamen Zuweisungen.

## Bearbeiten

- **Doppelklick** auf eine Zeile (oder Rechtsklick → *Bearbeiten…*) ändert Name oder Wert. Die Validierung läuft live; Werte werden wortwörtlich geschrieben — `$VARIABLEN` bleiben unausgewertet.
- **＋** in der Toolbar legt eine neue Variable an. Neue Variablen landen in einem klar markierten Block am Ende der gewählten Datei:

  ```bash
  # >>> CodingBuddy >>>
  export MY_VAR="value"
  # <<< CodingBuddy <<<
  ```

  Blöcke aus der Zeit vor der Umbenennung (`# >>> EnvVarBuddy >>>`) werden weiterhin erkannt und wiederverwendet.

- **Werte mit `:`** (wie `PATH`) bieten *Als Liste bearbeiten*: Einträge umsortieren, hinzufügen und entfernen.
- **Löschen** (Rechtsklick → *Löschen…*) entfernt die Zeile nach Rückfrage.

## Sicherheitsnetz

Vor jeder Änderung schreibt CodingBuddy ein Backup mit Zeitstempel nach
`~/Library/Application Support/CodingBuddy/Backups/` (die letzten 20 pro Datei bleiben erhalten). Geschrieben wird atomar, symlink-sicher (Dotfile-Manager bleiben intakt) und unter Erhalt der Dateirechte. Wurde die Datei währenddessen extern geändert, wird der Schreibvorgang verweigert und die Ansicht neu geladen.

CodingBuddy behandelt eine vorhandene unlesbare oder nicht als UTF-8 gültige
Shell-Datei niemals als fehlend. Ein einzelner Datei-Scope zeigt eine
Sicherheitsverweigerung; **Alle Variablen** behält Zeilen aus geprüften Dateien,
kennzeichnet das Ergebnis aber als **Unvollständige Daten**. Neu anlegen,
Bearbeiten, Löschen, Import und Export bleiben gesperrt, bis **Erneut versuchen**
alle Quellen sicher laden kann. **Im Finder anzeigen** hilft bei der Prüfung,
ohne den absoluten Pfad im Fehlertext der App offenzulegen.

Der Eintrag **Wartung → Backups** (Alpha) listet diese Backups für
zsh-Dotfiles und unterstützte Agent-Konfigurations-/Env-Dateien
(`~/.codex/mcp.env`, Claude-Code-Settings, Cursor `mcp.json`). Wähle ein
Backup aus, um eine redigierte **Backup**-Vorschau mit dem aktuellen Ziel zu
vergleichen. **Wiederherstellen …** schreibt das ausgewählte Backup über
denselben sicheren Writer zurück; dadurch wird die aktuelle Datei vor dem
Ersetzen erneut gesichert. Backups, die keinem bekannten von CodingBuddy
verwalteten Ziel zugeordnet werden können, bleiben reine Vorschau. CodingBuddy
verweigert Vorschau und Wiederherstellung außerdem, wenn ein gefundenes Backup
ersetzt wurde, zu einem Symlink geworden ist, keine sichere reguläre Datei mehr
ist oder das Vorschau-Limit von 8 MiB überschreitet. Die Erkennung hält nur
stabile No-Follow-Metadaten; die ausgewählte Datei wird erst für Vorschau oder
Wiederherstellung geöffnet und geprüft. Dadurch benötigt eine normale Retention
über viele verwaltete Dateien nicht einen Descriptor pro Zeile. Ein reguläres,
anhand seines Namens erkanntes Backup, das die Eigentümer-, Berechtigungs- oder
Größenprüfung nicht besteht, bleibt mit dem Status **Abgelehnt** und einer
konkreten Erklärung sichtbar. Vorschau und Wiederherstellung bleiben gesperrt;
**Im Finder anzeigen** steht für eine manuelle Wiederherstellung weiterhin zur
Verfügung. Die
Verzeichniserkennung bleibt auf 4.096 Einträge begrenzt. Wird diese Grenze
überschritten, zeigt CodingBuddy eine Sicherheitsverweigerung mit **Erneut
versuchen** und **Im Finder anzeigen**, statt eine irreführend unvollständige
oder leere Liste anzuzeigen.
Kann eine Wiederherstellungstransaktion nicht sauber abgeschlossen werden,
unterscheidet die Meldung, ob das Backup nicht angewendet, angewendet mit
verbliebenen Recovery-Dateien, angewendet mit noch ausstehender
Dauerhaftigkeitsprüfung oder nicht abschließend bestätigt wurde. Ein persistentes
Recovery-Band hält Ergebnis und Aktionen wie **Recovery-Dateien im Finder
anzeigen** und **Recovery-Pfad kopieren** auch nach Schließen der Meldung sowie
nach Weg- und Zurücknavigieren sichtbar.
Wiederherstellen bleibt gesperrt, bis du **Als geprüft markieren** wählst, damit
bei unbekanntem Zielzustand kein blindes Wiederholen nahegelegt wird.
Shell-Backup-Vorschauen erhalten Namen und harmlose Struktur, maskieren aber
jeden Zuweisungswert und nicht nur bekannte Credential-Namen. JSON-Vorschauen
erhalten Schlüssel und Container-Struktur, während jeder Skalarwert maskiert
wird; fehlerhaftes JSON erscheint als eine einzige undurchsichtige Maske.

## Import & Export

- **Aus .env importieren…** (Ablage-Menü oder Toolbar, ⇧⌘I) liest eine dotenv-Datei, zeigt eine Vorschau zur Auswahl der Einträge (Duplikate werden markiert) und hängt sie an den verwalteten Block einer Datei deiner Wahl an. Die Import-Schaltfläche nennt die ausgewählte Anzahl, etwa **1 Variable importieren** oder **2 Variablen importieren**.
- **Sichtbare als .env exportieren…** (Ablage-Menü oder Toolbar, ⇧⌘E) schreibt die aktuell angezeigten Variablen in eine `.env`-Datei.

## Hilfe-Menü

**Hilfe → CodingBuddy-Hilfe** (⌘?) öffnet diese Dokumentation in deiner App-Sprache — das deutsche Benutzerhandbuch, wenn die App auf Deutsch läuft, sonst den englischen Guide. **Hilfe → Dokumentation (Wiki)** öffnet das vollständige Wiki.

## Fokusliste

Der Eintrag **Fokus → Fokusliste** (Alpha) ordnet die bereits vom
Agent PR Monitor geladenen Pull Requests projektübergreifend zu einer einzigen
Liste nächster Aktionen. Er legt keine zweite Repository-Liste an und ruft
GitHub nicht eigenständig ab.

- **Jetzt** enthält bestätigte Blocker wie fehlgeschlagene CI,
  angeforderte Änderungen, aktuelle ungelöste Review-Hinweise oder fehlende
  GitHub-Sichtbarkeit.
- **Als Nächstes** enthält begrenzte Folgearbeit ohne bestätigten unmittelbaren
  Blocker, etwa einen Entwurf oder einen erneut zu ladenden Repository-Snapshot.
- **Warten** bedeutet, dass zuerst ein anderer Prozess oder eine andere Person
  fertig werden muss. Laufende CI, ausstehendes Review, eine aktive
  Aktualisierung und GitHub-Rate-Limits erzeugen keine falsche Dringlichkeit.
- **Bereit** bleibt für Abschluss oder Merge-Nachverfolgung sichtbar, steht aber
  nie vor tatsächlich bearbeitbarer Arbeit.

Die erste Zeile ist die Empfehlung. Jede kompakte Eintragszelle hält
Repository, Titel und PR-Nummer zusammen, damit die Tabelle auch neben dem
nativen Inspector in schmalen Fenstern nutzbar bleibt. Wähle einen Eintrag aus,
um **Warum jetzt**, die einfache Erklärung, mögliche Folgen und die vorhandene
sichere nächste Aktion zu sehen. Ein Repository-weites Aktualisierungsproblem erscheint nur
einmal statt für jeden veralteten PR. Schlägt ein beobachtetes Repository fehl,
bevor es PR-Zeilen liefert, hält ein Repository-Eintrag diese fehlende
Sichtbarkeit bearbeitbar, ohne einen Pull Request zu erfinden. Der Hinweis auf
einen unvollständigen Stand bleibt neutral, wenn nur Repository-Status
verfügbar ist; gültige PR-Snapshots anderer beobachteter Repositories bleiben
in der Liste, wenn sie vorhanden sind.

v1-Grenzen: Die Liste stellt Arbeit nicht zurück, sendet keine
Benachrichtigungen, läuft nicht im Hintergrund, verändert GitHub nicht und
priorisiert noch keine Zustands-, Sicherheits- oder Paketsignale. Diese Quellen
werden nach ihren Guidance-Verträgen in dieselbe deterministische Liste
aufgenommen.

## Secrets bleiben maskiert

Variablen, deren Namen nach Zugangsdaten aussehen (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, alles mit `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …), zeigen `••••••••` statt ihres Werts.

- Klicke den **Schloss-Button** in der Toolbar (oder versuche einfach, einen maskierten Wert zu bearbeiten/kopieren) und authentifiziere dich mit **Touch ID oder deinem Account-Passwort**, um sie anzuzeigen.
- Die Entsperrung läuft automatisch ab — die Dauer stellst du unter *Einstellungen → Sicherheit* ein (1/5/15 Minuten oder bis CodingBuddy beendet wird). Der Schloss-Button maskiert sofort wieder.
- Wert/Zeile kopieren, Bearbeiten und der `.env`-Export maskierter Variablen verlangen zuerst eine Authentifizierung.
- Die Authentifizierung ist an die exakte sichtbare Zeile und den Ansichts-Snapshot gebunden. Wird eine Datei neu geladen oder änderst du Scope, Suche oder den Filter für wirksame Variablen, während der macOS-Dialog offen ist, verwirft CodingBuddy die ausstehende Kopier-, Bearbeitungs- oder Exportaktion, statt sie auf geänderte Daten anzuwenden.
- **Alle eingeblendeten Secrets sperren** leert nur Editoren, die einen sensiblen Wert aus einem Store eingeblendet haben. Normale Entwürfe wie `PATH` bleiben geöffnet. Bei einem geänderten Secret-Entwurf stehen **Sichern und sperren**, **Verwerfen und sperren** und **Abbrechen** bereit; dieselben Optionen erscheinen 30 Sekunden vor dem automatischen Ablauf. **Sichern und sperren** schließt erst nach erfolgreichem Schreiben. Ein verweigerter oder veralteter Write lässt den Editor mit seiner Recovery-Meldung geöffnet.

## MCP-Zugangsdaten (~/.mcp-auth)

Der Sidebar-Bereich **Zustand & Sicherheit → MCP Auth** verwaltet den OAuth-Cache, den `mcp-remote` für entfernte MCP-Server anlegt — das Verzeichnis, das du bisher mit `rm -rf ~/.mcp-auth` löschen musstest.

- Jeder Eintrag ist ein Server. CodingBuddy löst die kryptischen Datei-Hashes über deine Claude-Konfiguration (`~/.claude.json`, Claude-Desktop-Config) zu Server-URLs auf; nicht auflösbare Einträge zeigen den Hash plus den OAuth-Scope als Hinweis.
- Die **Status-Spalte** zeigt, ob der Access-Token noch aktiv ist (mit geschätztem Ablauf), abgelaufen, unvollständig (ein nie abgeschlossener Login) oder **Nur zurücksetzen** ist, weil Token-Artefakte vorhanden sind, aber nicht sicher gelesen werden können.
- **Eintrag zurücksetzen…** legt nur die Dateien dieses Servers nach einer Bestätigung in den **Papierkorb**, die den Server und die Folge klar benennt — chirurgisch, reversibel, und die nächste Verbindung startet einfach den OAuth-Flow neu. **Alles zurücksetzen…** nutzt eine eigene Bestätigung für alle Zugangsdaten (das GUI-Pendant zu `rm -rf ~/.mcp-auth`, aber rückgängig machbar). CodingBuddy prüft jede Komponente der Cache-, privaten Staging- und Recovery-Pfade, ohne symbolischen Links zu folgen; nur die exakten unveränderlichen macOS-Kompatibilitätsaliase sind zulässig. Unmittelbar vor dem Staging scannt CodingBuddy erneut und vergleicht die vollständige descriptor-gebundene Root- und rekursive Artefaktinventur mit der bestätigten Ansicht. An jeder letzten Rename-Grenze öffnet CodingBuddy den Elternpfad erneut, prüft den exakten Eintrag und den vollständigen begrenzten Unterbaum und bestätigt bei **Alles zurücksetzen**, dass kein unbestätigter Root-Eintrag hinzugekommen ist. CodingBuddy sammelt die exakten Einträge in einer nur für den Eigentümer zugänglichen Transaktion, prüft jeden verschobenen Eintrag und Verzeichnis-Unterbaum erneut, verschiebt die Transaktion exklusiv in ein privates CodingBuddy-Staging und validiert sie nochmals unmittelbar vor dem Papierkorb-Aufruf. Ein erkanntes Hinzufügen, Entfernen oder Ersetzen bricht vor dem Papierkorb-Aufruf ab und rollt exakte verschobene Einträge zurück; fehlt ein exaktes Objekt, behält CodingBuddy einen ausdrücklichen Recovery-Zustand, statt Erfolg zu behaupten. Die Wiederherstellung überschreibt nie einen währenddessen neu angelegten Pfad. Eine verbliebene Recovery blockiert weitere Resets, übersteht durch einen privaten identitätsgebundenen Datensatz einen App-Neustart und bleibt nach Schließen der Meldung über die Toolbar erreichbar; erst nach Auflösung des exakten Recovery-Verzeichnisses entfernt ein Reload die Aktion.
- **Dateien ansehen…** (oder Doppelklick) öffnet die Credential-Dateien mit maskierten Token-Werten. Nach Authentifizierung mit Touch ID oder Passwort kannst du das rohe JSON bearbeiten; ungültiges JSON wird beim Speichern abgelehnt. Das Speichern legt zuerst ein Backup an, schreibt atomar und erhält Symlink sowie Dateirechte. Hat ein anderer Prozess die Datei nach dem Laden im Editor geändert, verweigert CodingBuddy den veralteten Write und bietet das Neuladen der aktuellen Festplattenversion an. Ein Editor mit ungesicherten Änderungen verhindert das Beenden der App. Editor und Liste bieten die appweite Aktion **Alle eingeblendeten Secrets sperren**; im Editor stehen bei ungesicherten Änderungen Speichern, Verwerfen und Abbrechen bereit. 30 Sekunden vor der automatischen Sperre bietet ein persistenter Countdown Sichern und Sperren, erneute Authentifizierung oder Verwerfen und Sperren. Ein Abbruch durch den Benutzer bleibt still; ein echter Systemfehler der Authentifizierung bleibt neben der Recovery-Aktion sichtbar und setzt Tastatur- sowie VoiceOver-Fokus dorthin zurück, ohne den Entwurf zu verwerfen. Beim Ablauf löscht CodingBuddy den Klartext sofort, setzt Tastatur- und VoiceOver-Fokus auf Entsperren zurück und kündigt die Sperre an. Das macOS-Menü **Zugangsdaten** spiegelt Dateien ansehen, globale Sperre, verbliebene Wiederherstellung und Alles zurücksetzen, damit diese Aktionen auch bei ausgeblendeter Toolbar erreichbar bleiben.
- Fehlt `~/.mcp-auth` oder ist das Verzeichnis leer, verweist der leere Zustand zuerst auf die Verbindung mit einem OAuth-fähigen MCP-Server. CodingBuddy listet zwischengespeicherte Zugangsdaten, nachdem `mcp-remote` sie erstellt hat. Sicher identifizierte Symlinks, Spezialdateien sowie extern beschreibbare, wechselnde oder übergroße Artefakte (über 1 MiB) bleiben als **Nur zurücksetzen** sichtbar; CodingBuddy zeigt oder bearbeitet niemals ihre Inhalte. Beim Reset verschiebt CodingBuddy den exakten, ohne Link-Verfolgung identifizierten Verzeichniseintrag in die reversible Transaktion. Dadurch werden weder das Ziel eines Symlinks noch der Inhalt einer Spezialdatei geöffnet oder verändert. Eine am Aktionszeitpunkt erkannte Ersetzung bricht ab, ohne den Ersatz zu löschen. Cache- und Recovery-Auflistungen sind begrenzt: Kann die Erkennung keine vollständige Credential-Inventur garantieren, zeigt die Ansicht statt „keine Zugangsdaten“ eine Sicherheitswarnung mit erneutem Versuch und Finder-Aktion. Resets bleiben deaktiviert, bis die vollständige Abdeckung wiederhergestellt ist.
- Kein App-Neustart nötig: Die Ansicht lädt live nach, wenn `mcp-remote` die Dateien neu schreibt.

## AI-Tools

### Grundlage für verständliche Empfehlungen

CodingBuddy führt ein gemeinsames Erklärungsmuster für technische Befunde ein.
Sobald ein Alpha-Bereich darauf umgestellt ist, trennt sein Inspector **Einfach
erklärt**, **Warum wichtig**, **Empfohlener nächster Schritt** und eingeklappte
**Technische Details**. Wiederkehrende Entwicklerbegriffe verweisen auf ein
kurzes eingebautes Glossar, statt Git-, CI-, MCP-, OAuth- oder
Paketmanager-Wissen vorauszusetzen.

Die Empfehlungen sind redaktionell gepflegt und deterministisch. CodingBuddy
sendet Befunde nicht an einen KI-Dienst, erfindet keine Aktionen und umgeht
keine bestehende Bestätigung oder Sicherheitsprüfung. Kann eine empfohlene
Aktion nicht ausgeführt werden, erklärt die App den Grund, statt eine wirkungslose
Schaltfläche anzuzeigen. Ein gesunder Zustand kann ausdrücklich sagen, dass
keine Aktion nötig ist, ohne wie ein Blocker zu wirken.

### Agent Doctor

Der Seitenleisten-Eintrag **Agent Doctor** (Alpha) ist ein Nur-Lese-Gesundheitscheck für die lokale Agent-Einrichtung. Er markiert:

- Fehlende Tool-Verzeichnisse.
- Fehlende verwaltete zsh-Startdateien (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`).
- Ungültige JSON-Konfigurationsdateien.
- Codex-MCP-Umgebungsvariablen, die in der Konfiguration referenziert werden, aber in `~/.codex/mcp.env` fehlen.
- Credential-Dateien mit zu offenen Dateirechten.
- Abgelaufene oder unvollständige Einträge in `~/.mcp-auth` sowie eine eigene
  Warnung, wenn Sicherheitsgrenzen verhindern, dass Agent Doctor die
  Vollständigkeit des Scans bestätigen kann.

Die kompakte Tabelle hält Schweregrad, Befund und Tool sichtbar. Wähle einen Befund, um in einfachen Worten zu erfahren, was erkannt wurde, warum es wichtig ist, was passieren könnte und welcher nächste Schritt am sichersten ist. CodingBuddy empfiehlt genau eine Aktion und führt zum zuständigen Tool, zur MCP-Authentifizierung oder zur Quelldatei, wenn dieser Weg bereits existiert. Kann CodingBuddy eine empfohlene Aktion nicht selbst ausführen, etwa Dateirechte zu ändern, nennt der Inspector den Grund statt eine wirkungslose Schaltfläche anzuzeigen.

Technische Nachweise bleiben standardmäßig eingeklappt und enthalten ausschließlich bereinigte Felder wie Diagnosecode, Tool, Quelle und betroffenes Subjekt. Credential-Werte, OAuth-URLs oder rohe Konfiguration mit Secrets werden nie angezeigt.

v1-Grenzen: Agent Doctor prüft keine Netzwerk-Erreichbarkeit, startet keine Agent-Prozesse neu, nimmt keine Auto-Fixes vor und zeigt keine Secret-Werte an.

### Agent Context

Der Seitenleisten-Eintrag **Repositories → Agent Context** (Alpha) ist ein Nur-Lese-Inspector für einen Repository-Ordner. Er zeigt, welche Instruktions- und Setup-Dateien ein Agent vor einer Coding-Session wahrscheinlich berücksichtigen würde.

- Wähle einen Repository-Ordner; CodingBuddy merkt sich den zuletzt gewählten Ordner.
- Eine abgeschlossene Prüfung ohne unterstützte Dateien zeigt **Keine Kontextdateien**. **Keine Ergebnisse** ist einer aktiven Suche vorbehalten, die alle geladenen Zeilen herausfiltert.
- Beim Auswählen oder erneuten Prüfen eines Ordners entfernt CodingBuddy sofort
  die Zeilen des vorherigen Repositories und zeigt den Prüfstatus. Ist die Wurzel
  nicht verfügbar oder enthält eine benutzerkontrollierte Pfadkomponente einen
  symbolischen Link, zeigt der Inspector eine ausdrückliche
  Sicherheitsverweigerung mit **Erneut versuchen** und **Anderen Ordner
  auswählen …** statt eines leeren Ergebnisses. Ein unsicherer Pfad wird nicht an
  den Finder übergeben.
- Die Tabelle prüft eine feste Allowlist: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, `.mcp.json`, `.codex`-Projektkonfiguration und offensichtliche Entwicklerdokumentation wie `README.md`, `CONTRIBUTING.md` und Development-Setup-Dokumente.
- Signale markieren fehlende `AGENTS.md` oder `CLAUDE.md`, zwei gleichzeitig vorhandene Governance-Dateien, leere Dateien, ungewöhnlich große Dateien sowie projektlokale MCP-/Codex-Konfiguration.
- **Öffnen** ermöglicht eine native Nur-Lese-Nachverfolgung für reguläre Dateien. CodingBuddy prüft das Repository und jede Pfadkomponente erneut, lehnt ein über einen symbolischen Link ausgewähltes oder später durch einen solchen ersetztes Repository ab, kopiert begrenzte stabile Bytes aus dem geprüften Datei-Descriptor in einen privaten `0400`-Snapshot in einem nur für den Eigentümer zugänglichen Verzeichnis und öffnet ihn mit dem konfigurierten Texteditor. Die unveränderlichen macOS-Kompatibilitätsaliase `/var`, `/tmp` und `/etc` bleiben nach exakter Zielprüfung unterstützt. Auch eine Fallback-Meldung kennzeichnet die Datei ausdrücklich als schreibgeschützten, verifizierten Snapshot; ein Launch-Services-Fehler wird getrennt von einer fehlgeschlagenen Dateiprüfung gemeldet. Erfolg, Fallback und Fehler werden VoiceOver angekündigt. Repository-Verzeichnisse und Finder-Anzeigen sind bewusst keine externen Aktionsrouten, weil AppKit für einen normalen Pfad keine descriptorgebundene Identität bewahren kann. Wurde ein Eintrag ersetzt, umgeleitet, ist zu groß oder ändert sich beim Kopieren, verweigert CodingBuddy die Aktion und lädt den Inspector neu. CodingBuddy entfernt Snapshots nach zehn Minuten. Beim normalen Beenden und beim nächsten Start werden abgelaufene validierte Snapshots entfernt; ein frischer Snapshot bleibt lange genug verfügbar, damit ein kalt startender Editor die Launch-Services-Übergabe abschließen kann.

v1-Grenzen: Agent Context ist ausschließlich deterministische Erkennung. Er durchsucht das Repository nicht rekursiv, vergleicht Policy-Text nicht semantisch, entscheidet nicht, welche Regel gewinnt, und führt keine Natural-Language-Analyse über Instruktionen aus.

### Repo Readiness

Der Seitenleisten-Eintrag **Repositories → Repo Readiness** (Alpha) ist eine Nur-Lese-Checkliste für einen Repository-Ordner, bevor du Arbeit an einen Coding-Agent übergibst.

- Wähle einen Repository-Ordner; CodingBuddy merkt sich den zuletzt gewählten Ordner.
- Die Tabelle prüft Agent-Governance, README-Abdeckung, dokumentierte Build-/Testbefehle, Contribution-Workflow-Dokumente, GitHub-Issue-/PR-Templates, Feature-Flag-Dokumentation für Swift-App-Repositories, Setup-Skripte und Hooks, CI-Workflows sowie leichte `.git`-Marker für laufende Operationen.
- Jede Zeile ist **Bestanden**, **Warnung** oder **Fehlgeschlagen** und enthält einen kurzen Hinweis zur Behebung. Warnungen bedeuten, dass die App ein teilweises oder mehrdeutiges Signal gefunden hat.
- Wähle eine Zeile, um die Prüfung in einfachen Worten zu verstehen. Bestandene Prüfungen sagen ausdrücklich, dass keine Aktion nötig ist; Warnungen und Fehler empfehlen, das Repository anzuzeigen, damit du die relevante Datei prüfen oder ergänzen kannst, ohne dass CodingBuddy sie verändert.
- Die Checkliste bearbeitet keine Dateien, ruft GitHub nicht auf, startet kein `git` und prüft nicht, ob Befehle tatsächlich erfolgreich laufen.

v1-Grenzen: Repo Readiness ist deterministisch und beratend. Es prüft keinen entfernten Project-Status, erstellt keine fehlenden Templates und entscheidet nicht, ob ein Repository merge-sicher ist.

### MCP Inventory

Der Seitenleisten-Eintrag **MCP Inventory** (Alpha) ist eine Nur-Lese-Tabelle der MCP-Server, die CodingBuddy in Codex, Claude Code und Cursor findet.

- Die kompakte Tabelle zeigt Server, Quell-Tool, Repository oder Workspace und den Konfigurationszustand. Wähle eine Zeile, um Scope, Transport, sichere Command- oder URL-Zusammenfassung, referenzierte Environment-Variable-Namen, Header-Keys und Quelldatei im Inspector zu prüfen.
- Die Suche filtert nach Servername, Tool, Repository- oder Workspace-Name, Scope, Command- oder URL-Zusammenfassung und Environment-Variable-Name.
- Codex-Server, die Variablen referenzieren, die in `~/.codex/mcp.env` fehlen, werden hervorgehoben. Mit **Tool öffnen** springst du aus einer ausgewählten Codex-, Claude-Code- oder Cursor-Zeile zum bestehenden Tool-Editor.
- Der Inspector erklärt jeweils den Zustand eines Servers. Fehlende Variablen empfehlen das zuständige Tool zu öffnen, ein unbekannter Transport wird als Konfigurationswarnung erklärt und eine konfigurierte Zeile sagt anhand der lokalen Dateinachweise klar, dass keine Aktion nötig ist.
- Secret-Werte werden nie angezeigt: URL-Userinfo, Query-Strings, Fragmente, tokenartige Command-Argumente und Zugangsdaten enthaltende Header-Argumente werden redigiert. Sichere Header-Werte bleiben sichtbar, damit die Zusammenfassung nützlich bleibt.
- Gleichnamige Claude-Code-Definitionen in `.claude.json` und einer projektbezogenen `.mcp.json` bleiben getrennte Vorkommen. Dadurch bleiben Nachweise für Shadowing und widersprüchliche Definitionen erhalten, statt eine Quelle still auszublenden.

v1-Grenzen: MCP Inventory bearbeitet, installiert, prüft und authentifiziert keine Server. **Konfiguriert** bedeutet, dass der Scan die lokale Definition erkannt und keine sicher fehlende Variable festgestellt hat; es beweist weder die Vollständigkeit der Definition noch Erreichbarkeit oder erfolgreiche Authentifizierung. Claude-Code- und Cursor-Zeilen zeigen nur konfigurierte `env`- und Header-Keys; sie leiten keine fehlenden Variablen aus Command-Text ab.

### Agent PR Monitor

Der Seitenleisten-Eintrag **Repositories → Agent PR Monitor** (Alpha) ist eine Nur-Lese-Tabelle für offene GitHub-Pull-Requests über eine überwachte Repository-Liste hinweg. Jede Zeile wird als vermutlich Agent, vermutlich Mensch oder unbekannt klassifiziert.

- Füge den feingranularen GitHub-Nur-Lese-Token unter **Einstellungen → Sicherheit** hinzu oder ersetze ihn dort; CodingBuddy speichert ihn im Schlüsselbund, nicht in UserDefaults oder Dateien. Wenn kein Token gespeichert ist oder GitHub ihn ablehnt, führt dich der Monitor zurück in die Einstellungen.
- Füge überwachte Repositories über die durchsuchbare Auswahl hinzu oder entferne sie dort; die Suche passt auf Owner, Repository-Namen, volles `owner/name` und sichtbare Beschreibungen. Die manuelle `owner/name`-Eingabe bleibt als Fallback verfügbar, wenn die Repository-Liste nicht geladen werden kann.
- Die kompakte Tabelle zeigt PR-Titel, Repository, beratende Merge-Bereitschaft und letzte Aktualisierung. Wähle eine Zeile, um Autor-/Quellklassifizierung, Branches, verknüpfte Closing-Issues, CI-Status, Review-Status und ungelöste Befunde im Inspector zu prüfen.
- Mit aktivierten verständlichen Empfehlungen erklärt der ausgewählte PR zuerst, was seine aktuelle Bereitschaft bedeutet, warum sie wichtig ist und was als Nächstes sinnvoll ist. Grüne und tatsächlich wartende Zustände sagen ausdrücklich, dass jetzt keine Aktion nötig ist; fehlgeschlagene Checks, angeforderte Änderungen, ungelöste Befunde und Drafts empfehlen, den PR zu öffnen.
- Eine laufende Snapshot-Aktualisierung oder ein veralteter Repository-Snapshot hat Vorrang vor der alten Bereitschaftsaussage. Authentifizierungsprobleme führen zu den Einstellungen, gewöhnliche Ladefehler empfehlen eine Aktualisierung und laufende Aktualisierungen oder Rate-Limits erklären, dass Abwarten der sinnvolle nächste Schritt ist, statt falsche Dringlichkeit zu erzeugen.
- GitHub-Review- und Legacy-Status-Sammlungen werden mit begrenzter Pagination gelesen. Meldet GitHub mehr Einträge, als CodingBuddy sicher laden kann, bleiben Review und CI **unbekannt/ausstehend**, statt als genehmigt oder grün zu erscheinen.
- Mit **Aktualisieren** lädst du manuell neu, mit **PR öffnen** arbeitest du im Browser weiter. Der Monitor kommentiert nie, genehmigt nie, löst keine Threads auf und führt keine Merges aus.
- Rate-Limits, fehlende Rechte, verweigerte Repositories und Offline-Fehler erscheinen als UI-sichere Zustände; der letzte erfolgreiche Snapshot bleibt möglichst sichtbar. Repository-spezifische Fehler sind abgegrenzt, sodass erfolgreiche Repositories sichtbar bleiben, wenn ein anderes überwachtes Repository fehlschlägt. Ein Fehler ohne zwischengespeicherte PR-Zeilen bleibt als einzelner Repository-Eintrag in der Fokusliste sichtbar.

v1-Grenzen: Agent PR Monitor liest nur GitHub.com, aktualisiert keine GitHub Projects und läuft nach dem Beenden von CodingBuddy nicht im Hintergrund weiter.

### Codex

Der Seitenleisten-Eintrag **Codex** (Alpha) verwaltet die Umgebungsdatei von OpenAI Codex:

- **`~/.codex/mcp.env`** — die Variablen, die Codex lädt (z. B. Bearer-Tokens für MCP-Server). Einträge lassen sich wie Dotfile-Variablen bearbeiten, anlegen und löschen; Werte, die wie Secrets aussehen, sind maskiert, Kommentare in der Datei bleiben erhalten, die Datei behält ihre restriktiven `600`-Rechte. Backups wie bei den Dotfiles.
- **MCP-Server** — eine Nur-Lese-Übersicht aus `~/.codex/config.toml`: welcher Server welche Umgebungsvariable referenziert (`bearer_token_env_var`, `env_vars`).
- **Warnung bei fehlenden Variablen** — referenziert ein Server eine Variable, die in `mcp.env` nicht definiert ist, zeigt CodingBuddy eine Warnung mit **Definieren …**-Shortcut. Das beantwortet die klassische Frage „Woher liest Codex dieses Token?“.

### Claude Code

Der Eintrag **Claude Code** (Alpha) verwaltet die Claude-Code-Konfiguration:

- **`env`-Blöcke** aus `~/.claude/settings.json` und `settings.local.json` — Variablen bearbeiten, anlegen, löschen. CodingBuddy patcht nur den betroffenen Wert (der Rest der Datei bleibt Byte für Byte unverändert, keine Umsortierung), schreibt vorher ein Backup und verweigert den Write, wenn Claude Code die Datei zwischenzeitlich geändert hat.
- **MCP-Server** — Nur-Lese-Übersicht aus `~/.claude.json` (User-Scope und existierende Projekte) sowie den `.mcp.json`-Dateien der Projekte, mit den referenzierten env-/Header-Keys. CodingBuddy lädt diese Übersicht erst beim Öffnen von Claude Code; zu große Dateien, symbolische Links, Spezialdateien und unsichere Projektwurzeln werden ausdrücklich verweigert und als **Zugriff blockiert** eingestuft.
- Beim Öffnen zeigt der Eintrag einen ausdrücklichen Ladezustand. Das Verlassen bricht die Darstellungsanfrage ab; ein älterer oder verspäteter Scan kann kein neueres Ergebnis überschreiben.
- Eine unsichere Quelle wird weder als fehlend gemeldet noch stillschweigend übersprungen. Eine vollständig verweigerte Ladung zeigt **Zugriff blockiert**, den quellspezifischen Grund, **Erneut versuchen** und **Im Finder zeigen**, ohne Konfigurationsinhalte offenzulegen. Bei einer teilweisen Ladung bleiben geprüfte Quellen sichtbar, jede abgelehnte Quelle wird benannt und Änderungen sind nur für betroffene Settings-Dateien gesperrt.
- Lesevorgänge sind durch Limits pro Datei, für die Projektanzahl und für die Gesamtgröße der Projektdateien begrenzt. Ungültiges UTF-8, fehlerhaftes oder nicht unterstütztes JSON, symbolische Links, Spezialdateien, unsichere Pfadkomponenten und während der Prüfung veränderte Dateien werden sicher verweigert.

### Cursor

Der Eintrag **Cursor** (Alpha) verwaltet `~/.cursor/mcp.json`: die `env`-Werte pro Server sind editierbar (maskiert, wertgenaues Patchen mit Backups und Schutz vor externen Änderungen); die Serverliste selbst ist nur lesend.

Die Cursor-Konfiguration hat drei ausdrückliche Zustände: sicher fehlend,
vollständig geladen oder verweigert. CodingBuddy liest höchstens 4 MiB über
einen descriptorgebundenen No-Follow-Snapshot und verweigert unsichere Pfade,
unlesbare oder nicht reguläre Dateien, zu große Dateien, ungültiges UTF-8,
fehlerhaftes JSON und nicht unterstützte JSON-Strukturen. Eine Verweigerung
erscheint nie als gültige leere Konfiguration oder als Ergebnis mit null
Variablen. Stattdessen zeigt die Ansicht **Zugriff blockiert**, den konkreten
Grund, **Erneut versuchen** und **Im Finder zeigen**. Bei einem unsicheren Pfad
erhält der Finder nur den sicheren übergeordneten Ort.

Anlegen, Bearbeiten und Löschen sind in Ansicht und Store gesperrt, bis die
Konfiguration vollständig geladen ist. Ein verweigerter Reload entfernt zuvor
geladene Zeilen und schließt Editoren oder Löschbestätigungen, deren Quelldaten
nicht mehr aktuell sind. CodingBuddy schließt die Aktion auch dann, wenn Cursor
währenddessen eine Serverdefinition ersetzt; selbst eine Ersetzung mit gleichem
Servernamen wird abgewiesen, bevor ein Secret in ein geändertes Kommando oder
eine geänderte URL, Umgebung, Header oder andere Servereinstellungen geschrieben
werden kann.

### Craft Agents

Der Eintrag **Craft Agents** (Alpha) zeigt, was die Craft-Agents-App in `~/.craft-agent/` speichert — strikt nur lesend:

- **LLM-Verbindungen** aus `config.json`.
- **Token-Dateien** unter `secrets/` mit Ablaufstatus; jede lässt sich einzeln nach einer Bestätigung zurücksetzen, die Datei und frischen Login klar nennt.
- **Der verschlüsselte Credential-Speicher** (`credentials.enc`): CodingBuddy zeigt Größe und Alter, öffnet die Datei aber nie; seine Reset-Bestätigung ist getrennt von Token-Datei-Resets und erklärt, dass jeder Craft-Connector eine neue Anmeldung verlangt.
- Ist der Ordner vorhanden, enthält aber noch keine Zugangsdaten, verweist der leere Zustand zurück auf die Einrichtung von Craft Agents oder die Verbindung eines Craft-Connectors. CodingBuddy wartet, bis Craft die Dateien erstellt.

## Workstation-Wartung

Der Eintrag **Wartung → Software-Updates** (Alpha) inventarisiert globale Pakete aus je einer aktiven Homebrew-, npm- und pnpm-Installation.

- Die Tabelle zeigt Paketname, Manager, installierte Version, verfügbare Version und Status. Filtere nach Updates, direkten Installationen oder allen Paketen; die Suche berücksichtigt Paket- und Managernamen.
- **Kompatibel** verwendet bei npm/pnpm die Wanted-Version. **Neueste** schließt ausdrücklich neuere Hauptversionen ein. Homebrew verwendet die gemeldete aktuelle Formel- oder Cask-Version.
- Wähle eine oder mehrere aktualisierbare Zeilen und klicke **Ausgewählte aktualisieren**. CodingBuddy zeigt jedes Paket und den exakten Versionswechsel, bevor ein Befehl startet.
- Bestätigte Updates laufen nacheinander mit sichtbarem Protokoll pro Paket. **Stoppen** bricht den aktuellen Befehl ab und markiert noch nicht gestartete Arbeit; abgeschlossene Updates werden nicht zurückgerollt. Danach prüft CodingBuddy den Bestand erneut.
- Angeheftete Formeln, selbstaktualisierende Casks und nicht beschreibbare Installationen erklären, warum CodingBuddy sie nicht direkt aktualisiert.
- Mit aktivierten verständlichen Empfehlungen folgt der sichtbare Status der ausgewählten Zielrichtlinie. Die Auswahl eines Pakets unterscheidet ein gewöhnliches kompatibles Update von einem ausdrücklichen Major-Update, erklärt direkte Installationen und Abhängigkeiten und empfiehlt genau einen nächsten Schritt. **Update prüfen** öffnet weiterhin die vorhandene Versionsvorschau und Bestätigung; die Erklärung startet nie direkt ein Update.
- Die Auswahl eines Pakets lädt Versionshinweise verzögert. CodingBuddy bevorzugt ein passendes GitHub Release und verlinkt sonst Repository, Homepage oder Changelog-Quelle. Fehlende Versionshinweise sind ein normaler Zustand.
- Falls die automatische Erkennung die falsche Installation wählt, hinterlege unter **Einstellungen → Wartung** einen expliziten Homebrew-, npm- oder pnpm-Pfad.

Alle Befehle verwenden die native POSIX-Prozess-API mit absolutem Programmpfad und getrennten Argumenten. Jeder Aufruf erhält eine eigene Prozessgruppe; bei Timeout oder **Stoppen** fordert CodingBuddy zuerst die Beendigung an und stoppt resistente Kindprozesse nach einer kurzen Frist zwangsweise. CodingBuddy startet nie eine Login-Shell, `sudo` oder einen frei zusammengesetzten Befehlsstring. Der Fehler eines Providers blendet erfolgreiche Ergebnisse anderer Provider nicht aus; der Hinweis nennt den betroffenen Manager und erklärt, dass Ergebnisse anderer Manager sichtbar bleiben.

v1-Grenzen: nur globale Pakete; eine aktive Installation pro Provider; keine Projekt-Abhängigkeiten, Installation, Deinstallation, Pin-Verwaltung, Rechteerhöhung oder automatischen Hintergrundupdates. Bun, Yarn, pipx, uv, Cargo und Editor-Erweiterungen werden noch nicht unterstützt.

## Einstellungen

Öffne **CodingBuddy → Einstellungen…** (⌘,). Die Einstellungen erscheinen als Panel direkt am Hauptfenster; schließe sie mit **Fertig**, um in der App weiterzuarbeiten.

- **Sprache** — System, English oder Deutsch. Wird nach einem Neustart der App wirksam.
- **Erscheinungsbild** — Auto (folgt dem System), Hell oder Dunkel.
- **Standard-Editor** — wähle die macOS-App, die CodingBuddy beim Öffnen von Markdown, JSON, YAML und anderen textartigen Repository-Dateien verwenden soll, oder setze auf den Systemstandard zurück.
- **Sicherheit** — wie lange Secrets nach der Authentifizierung sichtbar bleiben, plus der GitHub-Token für den Agent PR Monitor.
- **Wartung** — optionale Programmpfade für Homebrew, npm und pnpm; leere Felder verwenden die automatische Erkennung.

## Live-Aktualisierung

CodingBuddy beobachtet deine Dotfiles. Änderungen aus Terminal oder Editor erscheinen innerhalb von Sekundenbruchteilen in der App.

## Problembehebung

| Symptom | Erklärung |
|---|---|
| Eine Variable erscheint nicht | Gelesen werden nur `~/.zshenv`, `~/.zprofile`, `~/.zshrc` — nicht `.bashrc` oder anderswo gesourcte Dateien. |
| Eine Zeile hat ein Schloss-Symbol | Die Zeile ist zu komplex, um sie sicher umzuschreiben. Bearbeite sie im Texteditor. |
| „Die Datei wurde extern geändert" | Etwas anderes hat die Dotfile während der Bearbeitung verändert. Die App hat neu geladen — einfach erneut speichern. |
| Alten Stand wiederherstellen | Nutze **Wartung → Backups**, wähle ein unterstütztes Backup, prüfe die Vorschau und klicke **Wiederherstellen …**. Unbekannte Backup-Namen lassen sich weiterhin ansehen, bleiben aber reine Vorschau. |
