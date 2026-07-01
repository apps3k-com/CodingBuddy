# Benutzerhandbuch (DE)

CodingBuddy ist eine native macOS-App zur Verwaltung der Environment Variables in deinen zsh-Dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — ganz ohne Terminal.

## Variablen durchsuchen

- Die **Seitenleiste** zeigt *Alle Variablen* plus einen Eintrag pro Dotfile mit Zähler. Noch nicht existierende Dateien sind ausgegraut; legst du dort eine Variable an, wird die Datei erstellt.
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

Der Eintrag **Sicherheit → Backups** (Alpha) listet diese Backups für
zsh-Dotfiles und unterstützte Agent-Konfigurations-/Env-Dateien
(`~/.codex/mcp.env`, Claude-Code-Settings, Cursor `mcp.json`). Wähle ein
Backup aus, um eine redigierte **Backup**-Vorschau mit dem aktuellen Ziel zu
vergleichen. **Wiederherstellen …** schreibt das ausgewählte Backup über
denselben sicheren Writer zurück; dadurch wird die aktuelle Datei vor dem
Ersetzen erneut gesichert. Backups, die keinem bekannten von CodingBuddy
verwalteten Ziel zugeordnet werden können, bleiben reine Vorschau.

## Import & Export

- **Aus .env importieren…** (Ablage-Menü oder Toolbar, ⇧⌘I) liest eine dotenv-Datei, zeigt eine Vorschau zur Auswahl der Einträge (Duplikate werden markiert) und hängt sie an den verwalteten Block einer Datei deiner Wahl an. Die Import-Schaltfläche nennt die ausgewählte Anzahl, etwa **1 Variable importieren** oder **2 Variablen importieren**.
- **Sichtbare als .env exportieren…** (Ablage-Menü oder Toolbar, ⇧⌘E) schreibt die aktuell angezeigten Variablen in eine `.env`-Datei.

## Hilfe-Menü

**Hilfe → CodingBuddy-Hilfe** (⌘?) öffnet diese Dokumentation in deiner App-Sprache — das deutsche Benutzerhandbuch, wenn die App auf Deutsch läuft, sonst den englischen Guide. **Hilfe → Dokumentation (Wiki)** öffnet das vollständige Wiki.

## Secrets bleiben maskiert

Variablen, deren Namen nach Zugangsdaten aussehen (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, alles mit `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …), zeigen `••••••••` statt ihres Werts.

- Klicke den **Schloss-Button** in der Toolbar (oder versuche einfach, einen maskierten Wert zu bearbeiten/kopieren) und authentifiziere dich mit **Touch ID oder deinem Account-Passwort**, um sie anzuzeigen.
- Die Entsperrung läuft automatisch ab — die Dauer stellst du unter *Einstellungen → Sicherheit* ein (1/5/15 Minuten oder bis CodingBuddy beendet wird). Der Schloss-Button maskiert sofort wieder.
- Wert/Zeile kopieren, Bearbeiten und der `.env`-Export maskierter Variablen verlangen zuerst eine Authentifizierung.

## MCP-Zugangsdaten (~/.mcp-auth)

Der Sidebar-Bereich **Zugangsdaten → MCP Auth** verwaltet den OAuth-Cache, den `mcp-remote` für entfernte MCP-Server anlegt — das Verzeichnis, das du bisher mit `rm -rf ~/.mcp-auth` löschen musstest.

- Jeder Eintrag ist ein Server. CodingBuddy löst die kryptischen Datei-Hashes über deine Claude-Konfiguration (`~/.claude.json`, Claude-Desktop-Config) zu Server-URLs auf; nicht auflösbare Einträge zeigen den Hash plus den OAuth-Scope als Hinweis.
- Die **Status-Spalte** zeigt, ob der Access-Token noch aktiv ist (mit geschätztem Ablauf), abgelaufen ist oder der Eintrag unvollständig ist (ein nie abgeschlossener Login).
- **Eintrag zurücksetzen…** legt nur die Dateien dieses Servers nach einer Bestätigung in den **Papierkorb**, die den Server und die Folge klar benennt — chirurgisch, reversibel, und die nächste Verbindung startet einfach den OAuth-Flow neu. **Alles zurücksetzen…** nutzt eine eigene Bestätigung für alle Zugangsdaten (das GUI-Pendant zu `rm -rf ~/.mcp-auth`, aber rückgängig machbar).
- **Dateien ansehen…** (oder Doppelklick) öffnet die Credential-Dateien mit maskierten Token-Werten. Nach Authentifizierung mit Touch ID oder Passwort kannst du das rohe JSON bearbeiten; ungültiges JSON wird beim Speichern abgelehnt.
- Fehlt `~/.mcp-auth` oder ist das Verzeichnis leer, verweist der leere Zustand zuerst auf die Verbindung mit einem OAuth-fähigen MCP-Server. CodingBuddy listet zwischengespeicherte Zugangsdaten, nachdem `mcp-remote` sie erstellt hat.
- Kein App-Neustart nötig: Die Ansicht lädt live nach, wenn `mcp-remote` die Dateien neu schreibt.

## AI-Tools

### Agent Doctor

Der Seitenleisten-Eintrag **Agent Doctor** (Alpha) ist ein Nur-Lese-Gesundheitscheck für die lokale Agent-Einrichtung. Er markiert:

- Fehlende Tool-Verzeichnisse.
- Fehlende verwaltete zsh-Startdateien (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`).
- Ungültige JSON-Konfigurationsdateien.
- Codex-MCP-Umgebungsvariablen, die in der Konfiguration referenziert werden, aber in `~/.codex/mcp.env` fehlen.
- Credential-Dateien mit zu offenen Dateirechten.
- Abgelaufene oder unvollständige Einträge in `~/.mcp-auth`.

v1-Grenzen: Agent Doctor prüft keine Netzwerk-Erreichbarkeit, startet keine Agent-Prozesse neu, nimmt keine Auto-Fixes vor und zeigt keine Secret-Werte an.

### Agent Context

Der Seitenleisten-Eintrag **Agent Context** (Alpha, unter Inventar) ist ein Nur-Lese-Inspector für einen Repository-Ordner. Er zeigt, welche Instruktions- und Setup-Dateien ein Agent vor einer Coding-Session wahrscheinlich berücksichtigen würde.

- Wähle einen Repository-Ordner; CodingBuddy merkt sich den zuletzt gewählten Ordner.
- Die Tabelle prüft eine feste Allowlist: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, `.mcp.json`, `.codex`-Projektkonfiguration und offensichtliche Entwicklerdokumentation wie `README.md`, `CONTRIBUTING.md` und Development-Setup-Dokumente.
- Signale markieren fehlende `AGENTS.md` oder `CLAUDE.md`, zwei gleichzeitig vorhandene Governance-Dateien, leere Dateien, ungewöhnlich große Dateien sowie projektlokale MCP-/Codex-Konfiguration.
- Mit **Öffnen** oder **Im Finder anzeigen** springst du nativ zum Eintrag. **Öffnen** verwendet deinen konfigurierten Standard-Editor für textartige Dateien; der Inspector bearbeitet diese Dateien nie.

v1-Grenzen: Agent Context ist ausschließlich deterministische Erkennung. Er durchsucht das Repository nicht rekursiv, vergleicht Policy-Text nicht semantisch, entscheidet nicht, welche Regel gewinnt, und führt keine Natural-Language-Analyse über Instruktionen aus.

### Repo Readiness

Der Seitenleisten-Eintrag **Repo Readiness** (Alpha, unter Inventar) ist eine Nur-Lese-Checkliste für einen Repository-Ordner, bevor du Arbeit an einen Coding-Agent übergibst.

- Wähle einen Repository-Ordner; CodingBuddy merkt sich den zuletzt gewählten Ordner.
- Die Tabelle prüft Agent-Governance, README-Abdeckung, dokumentierte Build-/Testbefehle, Contribution-Workflow-Dokumente, GitHub-Issue-/PR-Templates, Feature-Flag-Dokumentation für Swift-App-Repositories, Setup-Skripte und Hooks, CI-Workflows sowie leichte `.git`-Marker für laufende Operationen.
- Jede Zeile ist **Bestanden**, **Warnung** oder **Fehlgeschlagen** und enthält einen kurzen Hinweis zur Behebung. Warnungen bedeuten, dass die App ein teilweises oder mehrdeutiges Signal gefunden hat.
- Die Checkliste bearbeitet keine Dateien, ruft GitHub nicht auf, startet kein `git` und prüft nicht, ob Befehle tatsächlich erfolgreich laufen.

v1-Grenzen: Repo Readiness ist deterministisch und beratend. Es prüft keinen entfernten Project-Status, erstellt keine fehlenden Templates und entscheidet nicht, ob ein Repository merge-sicher ist.

### MCP Inventory

Der Seitenleisten-Eintrag **MCP Inventory** (Alpha) ist eine Nur-Lese-Tabelle der MCP-Server, die CodingBuddy in Codex, Claude Code und Cursor findet.

- Die Tabelle zeigt Quell-Tool, Servername, Repository- oder Workspace-Name, Scope oder Projektpfad, Transport, sichere Command- oder URL-Zusammenfassung, referenzierte Environment-Variable-Namen, Header-Keys und Quelldatei.
- Die Suche filtert nach Servername, Tool, Repository- oder Workspace-Name, Scope, Command- oder URL-Zusammenfassung und Environment-Variable-Name.
- Codex-Server, die Variablen referenzieren, die in `~/.codex/mcp.env` fehlen, werden hervorgehoben. Mit **Tool öffnen** springst du aus einer ausgewählten Codex-, Claude-Code- oder Cursor-Zeile zum bestehenden Tool-Editor.
- Secret-Werte werden nie angezeigt: URL-Userinfo, Query-Strings, Fragmente und tokenartige Command-Argumente werden redigiert.

v1-Grenzen: MCP Inventory bearbeitet, installiert und prüft keine Server im Netzwerk. Claude-Code- und Cursor-Zeilen zeigen nur konfigurierte `env`- und Header-Keys; sie leiten keine fehlenden Variablen aus Command-Text ab.

### Agent PR Monitor

Der Seitenleisten-Eintrag **Agent PR Monitor** (Alpha, unter Inventar) ist eine Nur-Lese-Tabelle für offene GitHub-Pull-Requests in einem ausgewählten Repository. Jede Zeile wird als vermutlich Agent, vermutlich Mensch oder unbekannt klassifiziert.

- Füge den feingranularen GitHub-Nur-Lese-Token unter **Einstellungen → Sicherheit** hinzu oder ersetze ihn dort; CodingBuddy speichert ihn im Schlüsselbund, nicht in UserDefaults oder Dateien. Wenn kein Token gespeichert ist oder GitHub ihn ablehnt, führt dich der Monitor zurück in die Einstellungen.
- Wähle ein Repository aus der durchsuchbaren Auswahl; die Suche passt auf Owner, Repository-Namen, volles `owner/name` und sichtbare Beschreibungen. Die manuelle `owner/name`-Eingabe bleibt als Fallback verfügbar, wenn die Repository-Liste nicht geladen werden kann.
- Die Tabelle zeigt PR-Titel, Autor-/Quellklassifizierung, verknüpfte Closing-Issues, CI-Status, Review-Status, ungelöste Befunde, beratende Merge-Bereitschaft und letzte Aktualisierung.
- Mit **Aktualisieren** lädst du manuell neu, mit **PR öffnen** arbeitest du im Browser weiter. Der Monitor kommentiert nie, genehmigt nie, löst keine Threads auf und führt keine Merges aus.
- Rate-Limits, fehlende Rechte, verweigerte Repositories und Offline-Fehler erscheinen als UI-sichere Zustände; der letzte erfolgreiche Snapshot bleibt möglichst sichtbar.

v1-Grenzen: Agent PR Monitor liest nur GitHub.com, überwacht jeweils ein Repository und aktualisiert keine GitHub Projects. Nach dem Beenden von CodingBuddy läuft er nicht im Hintergrund weiter.

### Codex

Der Seitenleisten-Eintrag **Codex** (Alpha) verwaltet die Umgebungsdatei von OpenAI Codex:

- **`~/.codex/mcp.env`** — die Variablen, die Codex lädt (z. B. Bearer-Tokens für MCP-Server). Einträge lassen sich wie Dotfile-Variablen bearbeiten, anlegen und löschen; Werte, die wie Secrets aussehen, sind maskiert, Kommentare in der Datei bleiben erhalten, die Datei behält ihre restriktiven `600`-Rechte. Backups wie bei den Dotfiles.
- **MCP-Server** — eine Nur-Lese-Übersicht aus `~/.codex/config.toml`: welcher Server welche Umgebungsvariable referenziert (`bearer_token_env_var`, `env_vars`).
- **Warnung bei fehlenden Variablen** — referenziert ein Server eine Variable, die in `mcp.env` nicht definiert ist, zeigt CodingBuddy eine Warnung mit **Definieren …**-Shortcut. Das beantwortet die klassische Frage „Woher liest Codex dieses Token?“.

### Claude Code

Der Eintrag **Claude Code** (Alpha) verwaltet die Claude-Code-Konfiguration:

- **`env`-Blöcke** aus `~/.claude/settings.json` und `settings.local.json` — Variablen bearbeiten, anlegen, löschen. CodingBuddy patcht nur den betroffenen Wert (der Rest der Datei bleibt Byte für Byte unverändert, keine Umsortierung), schreibt vorher ein Backup und verweigert den Write, wenn Claude Code die Datei zwischenzeitlich geändert hat.
- **MCP-Server** — Nur-Lese-Übersicht aus `~/.claude.json` (User-Scope und existierende Projekte) sowie den `.mcp.json`-Dateien der Projekte, mit den referenzierten env-/Header-Keys.

### Cursor

Der Eintrag **Cursor** (Alpha) verwaltet `~/.cursor/mcp.json`: die `env`-Werte pro Server sind editierbar (maskiert, wertgenaues Patchen mit Backups und Schutz vor externen Änderungen); die Serverliste selbst ist nur lesend.

### Craft Agents

Der Eintrag **Craft Agents** (Alpha) zeigt, was die Craft-Agents-App in `~/.craft-agent/` speichert — strikt nur lesend:

- **LLM-Verbindungen** aus `config.json`.
- **Token-Dateien** unter `secrets/` mit Ablaufstatus; jede lässt sich einzeln nach einer Bestätigung zurücksetzen, die Datei und frischen Login klar nennt.
- **Der verschlüsselte Credential-Speicher** (`credentials.enc`): CodingBuddy zeigt Größe und Alter, öffnet die Datei aber nie; seine Reset-Bestätigung ist getrennt von Token-Datei-Resets und erklärt, dass jeder Craft-Connector eine neue Anmeldung verlangt.
- Ist der Ordner vorhanden, enthält aber noch keine Zugangsdaten, verweist der leere Zustand zurück auf die Einrichtung von Craft Agents oder die Verbindung eines Craft-Connectors. CodingBuddy wartet, bis Craft die Dateien erstellt.

## Einstellungen

Öffne **CodingBuddy → Einstellungen…** (⌘,). Die Einstellungen erscheinen als Panel direkt am Hauptfenster; schließe sie mit **Fertig**, um in der App weiterzuarbeiten.

- **Sprache** — System, English oder Deutsch. Wird nach einem Neustart der App wirksam.
- **Erscheinungsbild** — Auto (folgt dem System), Hell oder Dunkel.
- **Standard-Editor** — wähle die macOS-App, die CodingBuddy beim Öffnen von Markdown, JSON, YAML und anderen textartigen Repository-Dateien verwenden soll, oder setze auf den Systemstandard zurück.
- **Sicherheit** — wie lange Secrets nach der Authentifizierung sichtbar bleiben, plus der GitHub-Token für den Agent PR Monitor.

## Live-Aktualisierung

CodingBuddy beobachtet deine Dotfiles. Änderungen aus Terminal oder Editor erscheinen innerhalb von Sekundenbruchteilen in der App.

## Problembehebung

| Symptom | Erklärung |
|---|---|
| Eine Variable erscheint nicht | Gelesen werden nur `~/.zshenv`, `~/.zprofile`, `~/.zshrc` — nicht `.bashrc` oder anderswo gesourcte Dateien. |
| Eine Zeile hat ein Schloss-Symbol | Die Zeile ist zu komplex, um sie sicher umzuschreiben. Bearbeite sie im Texteditor. |
| „Die Datei wurde extern geändert" | Etwas anderes hat die Dotfile während der Bearbeitung verändert. Die App hat neu geladen — einfach erneut speichern. |
| Alten Stand wiederherstellen | Nutze **Sicherheit → Backups**, wähle ein unterstütztes Backup, prüfe die Vorschau und klicke **Wiederherstellen …**. Unbekannte Backup-Namen lassen sich weiterhin ansehen, bleiben aber reine Vorschau. |
