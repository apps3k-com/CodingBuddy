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

## Import & Export

- **Aus .env importieren…** (Ablage-Menü oder Toolbar, ⇧⌘I) liest eine dotenv-Datei, zeigt eine Vorschau zur Auswahl der Einträge (Duplikate werden markiert) und hängt sie an den verwalteten Block einer Datei deiner Wahl an.
- **Sichtbare als .env exportieren…** (Ablage-Menü oder Toolbar, ⇧⌘E) schreibt die aktuell angezeigten Variablen in eine `.env`-Datei.

## Hilfe-Menü

**Hilfe → CodingBuddy-Hilfe** (⌘?) öffnet diese Dokumentation in deiner App-Sprache — das deutsche Benutzerhandbuch, wenn die App auf Deutsch läuft, sonst den englischen Guide. **Hilfe → Dokumentation (Wiki)** öffnet das vollständige Wiki.

## Geheimnisse bleiben maskiert

Variablen, deren Namen nach Zugangsdaten aussehen (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, alles mit `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …), zeigen `••••••••` statt ihres Werts.

- Klicke den **Schloss-Button** in der Toolbar (oder versuche einfach, einen maskierten Wert zu bearbeiten/kopieren) und authentifiziere dich mit **Touch ID oder deinem Account-Passwort**, um sie anzuzeigen.
- Die Entsperrung läuft automatisch ab — die Dauer stellst du unter *Einstellungen → Sicherheit* ein (1/5/15 Minuten oder bis zum Beenden). Der Schloss-Button maskiert sofort wieder.
- Wert/Zeile kopieren, Bearbeiten und der `.env`-Export maskierter Variablen verlangen zuerst eine Authentifizierung.

## MCP-Zugangsdaten (~/.mcp-auth)

Der Sidebar-Bereich **Zugangsdaten → MCP Auth** verwaltet den OAuth-Cache, den `mcp-remote` für entfernte MCP-Server anlegt — das Verzeichnis, das du bisher mit `rm -rf ~/.mcp-auth` löschen musstest.

- Jeder Eintrag ist ein Server. CodingBuddy löst die kryptischen Datei-Hashes über deine Claude-Konfiguration (`~/.claude.json`, Claude-Desktop-Config) zu Server-URLs auf; nicht auflösbare Einträge zeigen den Hash plus den OAuth-Scope als Hinweis.
- Die **Status-Spalte** zeigt, ob der Access-Token noch aktiv ist (mit geschätztem Ablauf), abgelaufen ist oder der Eintrag unvollständig ist (ein nie abgeschlossener Login).
- **Eintrag zurücksetzen…** legt nur die Dateien dieses Servers in den **Papierkorb** — chirurgisch, reversibel, und die nächste Verbindung startet einfach den OAuth-Flow neu. **Alles zurücksetzen…** macht dasselbe für alles (das GUI-Pendant zu `rm -rf ~/.mcp-auth`, aber rückgängig machbar).
- **Dateien ansehen…** (oder Doppelklick) öffnet die Credential-Dateien mit maskierten Token-Werten. Nach Authentifizierung mit Touch ID oder Passwort kannst du das rohe JSON bearbeiten; ungültiges JSON wird beim Speichern abgelehnt.
- Kein App-Neustart nötig: Die Ansicht lädt live nach, wenn `mcp-remote` die Dateien neu schreibt.

## AI-Tools

### Codex

Der Seitenleisten-Eintrag **Codex** (Alpha) verwaltet die Umgebungsdatei von OpenAI Codex:

- **`~/.codex/mcp.env`** — die Variablen, die Codex lädt (z. B. Bearer-Tokens für MCP-Server). Einträge lassen sich wie Dotfile-Variablen bearbeiten, anlegen und löschen; geheimnisartige Werte sind maskiert, Kommentare in der Datei bleiben erhalten, die Datei behält ihre restriktiven `600`-Rechte. Backups wie bei den Dotfiles.
- **MCP-Server** — eine Nur-Lese-Übersicht aus `~/.codex/config.toml`: welcher Server welche Umgebungsvariable referenziert (`bearer_token_env_var`, `env_vars`).
- **Warnung bei fehlenden Variablen** — referenziert ein Server eine Variable, die in `mcp.env` nicht definiert ist, zeigt CodingBuddy eine Warnung mit **Definieren …**-Shortcut. Das beantwortet die klassische Frage „Woher liest Codex dieses Token?“.

### Claude Code

Der Eintrag **Claude Code** (Alpha) verwaltet die Claude-Code-Konfiguration:

- **`env`-Blöcke** aus `~/.claude/settings.json` und `settings.local.json` — Variablen bearbeiten, anlegen, löschen. CodingBuddy patcht nur den betroffenen Wert (der Rest der Datei bleibt Byte für Byte unverändert, keine Umsortierung), schreibt vorher ein Backup und verweigert den Write, wenn Claude Code die Datei zwischenzeitlich geändert hat.
- **MCP-Server** — Nur-Lese-Übersicht aus `~/.claude.json` (User-Scope und existierende Projekte) sowie den `.mcp.json`-Dateien der Projekte, mit den referenzierten env-/Header-Keys.

## Einstellungen

Öffne **CodingBuddy → Einstellungen…** (⌘,). Die Einstellungen erscheinen als Panel direkt am Hauptfenster; schließe sie mit **Fertig**, um in der App weiterzuarbeiten.

- **Sprache** — System, English oder Deutsch. Wird nach einem Neustart der App wirksam.
- **Erscheinungsbild** — Auto (folgt dem System), Hell oder Dunkel.
- **Sicherheit** — wie lange Geheimnisse nach der Authentifizierung sichtbar bleiben.

## Live-Aktualisierung

CodingBuddy beobachtet deine Dotfiles. Änderungen aus Terminal oder Editor erscheinen innerhalb von Sekundenbruchteilen in der App.

## Problembehebung

| Symptom | Erklärung |
|---|---|
| Eine Variable erscheint nicht | Gelesen werden nur `~/.zshenv`, `~/.zprofile`, `~/.zshrc` — nicht `.bashrc` oder anderswo gesourcte Dateien. |
| Eine Zeile hat ein Schloss-Symbol | Die Zeile ist zu komplex, um sie sicher umzuschreiben. Bearbeite sie im Texteditor. |
| „Die Datei wurde extern geändert" | Etwas anderes hat die Dotfile während der Bearbeitung verändert. Die App hat neu geladen — einfach erneut speichern. |
| Alten Stand wiederherstellen | Backup aus `~/Library/Application Support/CodingBuddy/Backups/` über die Dotfile kopieren. |
