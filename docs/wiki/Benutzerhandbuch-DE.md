# Benutzerhandbuch (DE)

EnvVarBuddy ist eine native macOS-App zur Verwaltung der Environment Variables in deinen zsh-Dotfiles (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) — ganz ohne Terminal.

## Variablen durchsuchen

- Die **Seitenleiste** zeigt *Alle Variablen* plus einen Eintrag pro Dotfile mit Zähler. Noch nicht existierende Dateien sind ausgegraut; legst du dort eine Variable an, wird die Datei erstellt.
- Die **Tabelle** zeigt Name, Wert und Quelldatei. Mit dem Suchfeld (⌘F) filterst du nach Name oder Wert.
- Ein 🔒 **Schloss-Symbol** markiert komplexe Zeilen (Command Substitution wie `$(date)`, Mehrfach-Zuweisungen wie `export A=1 B=2`). EnvVarBuddy zeigt sie ehrlich an, schreibt sie aber nie um — solche Zeilen bearbeitest du besser im Texteditor.
- Ein oranges **überschrieben**-Badge bedeutet: Eine spätere Zuweisung gewinnt. zsh lädt `.zshenv → .zprofile → .zshrc`, innerhalb einer Datei gilt die letzte Zuweisung.
- Der Toolbar-Schalter **Überschriebene gruppieren** fasst Duplikate zusammen: Die wirksame Zuweisung wird zur Hauptzeile, überschriebene Zuweisungen klappen darunter aus.

## Bearbeiten

- **Doppelklick** auf eine Zeile (oder Rechtsklick → *Bearbeiten…*) ändert Name oder Wert. Die Validierung läuft live; Werte werden wortwörtlich geschrieben — `$VARIABLEN` bleiben unausgewertet.
- **＋** in der Toolbar legt eine neue Variable an. Neue Variablen landen in einem klar markierten Block am Ende der gewählten Datei:

  ```bash
  # >>> EnvVarBuddy >>>
  export MY_VAR="value"
  # <<< EnvVarBuddy <<<
  ```

- **Werte mit `:`** (wie `PATH`) bieten *Als Liste bearbeiten*: Einträge umsortieren, hinzufügen und entfernen.
- **Löschen** (Rechtsklick → *Löschen…*) entfernt die Zeile nach Rückfrage.

## Sicherheitsnetz

Vor jeder Änderung schreibt EnvVarBuddy ein Backup mit Zeitstempel nach
`~/Library/Application Support/EnvVarBuddy/Backups/` (die letzten 20 pro Datei bleiben erhalten). Geschrieben wird atomar, symlink-sicher (Dotfile-Manager bleiben intakt) und unter Erhalt der Dateirechte. Wurde die Datei währenddessen extern geändert, wird der Schreibvorgang verweigert und die Ansicht neu geladen.

## Import & Export

- **Aus .env importieren…** liest eine dotenv-Datei, zeigt eine Vorschau zur Auswahl der Einträge (Duplikate werden markiert) und hängt sie an den verwalteten Block einer Datei deiner Wahl an.
- **Sichtbare als .env exportieren…** schreibt die aktuell angezeigten Variablen in eine `.env`-Datei.

## Geheimnisse bleiben maskiert

Variablen, deren Namen nach Zugangsdaten aussehen (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, alles mit `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `AUTH`, …), zeigen `••••••••` statt ihres Werts.

- Klicke den **Schloss-Button** in der Toolbar (oder versuche einfach, einen maskierten Wert zu bearbeiten/kopieren) und authentifiziere dich mit **Touch ID oder deinem Account-Passwort**, um sie anzuzeigen.
- Die Entsperrung läuft automatisch ab — die Dauer stellst du unter *Einstellungen → Sicherheit* ein (1/5/15 Minuten oder bis zum Beenden). Der Schloss-Button maskiert sofort wieder.
- Wert/Zeile kopieren, Bearbeiten und der `.env`-Export maskierter Variablen verlangen zuerst eine Authentifizierung.

## Einstellungen

Öffne **EnvVarBuddy → Einstellungen…** (⌘,):

- **Sprache** — System, English oder Deutsch. Wird nach einem Neustart der App wirksam.
- **Erscheinungsbild** — Auto (folgt dem System), Hell oder Dunkel.
- **Sicherheit** — wie lange Geheimnisse nach der Authentifizierung sichtbar bleiben.

## Live-Aktualisierung

EnvVarBuddy beobachtet deine Dotfiles. Änderungen aus Terminal oder Editor erscheinen innerhalb von Sekundenbruchteilen in der App.

## Problembehebung

| Symptom | Erklärung |
|---|---|
| Eine Variable erscheint nicht | Gelesen werden nur `~/.zshenv`, `~/.zprofile`, `~/.zshrc` — nicht `.bashrc` oder anderswo gesourcte Dateien. |
| Eine Zeile hat ein Schloss-Symbol | Die Zeile ist zu komplex, um sie sicher umzuschreiben. Bearbeite sie im Texteditor. |
| „Die Datei wurde extern geändert" | Etwas anderes hat die Dotfile während der Bearbeitung verändert. Die App hat neu geladen — einfach erneut speichern. |
| Alten Stand wiederherstellen | Backup aus `~/Library/Application Support/EnvVarBuddy/Backups/` über die Dotfile kopieren. |
