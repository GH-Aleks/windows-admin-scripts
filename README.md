# windows-admin-scripts

Kleine Sammlung von PowerShell-Skripten für den IT-Support unter Windows:
Systemübersicht erstellen, temporäre Dateien aufräumen, einen Entwickler-PC
einrichten und eine erste Netzwerkdiagnose machen.

Die Skripte sind als Übungs- und Portfolio-Projekt entstanden. Sie sind bewusst
klein, gut lesbar und vorsichtig gebaut (Simulation mit `-WhatIf`, keine
versteckten Änderungen, deutsche Ausgaben, Fehlerbehandlung). Sie ersetzen
keine professionellen Verwaltungswerkzeuge.

**Ehrlicher Hinweis zur Entstehung:** Das Projekt wurde KI-gestützt
(Claude, Anthropic) umgesetzt. Ich habe die Anforderungen vorgegeben, die
Ergebnisse geprüft und auf meinem eigenen PC getestet. Was getestet wurde und
was nicht, steht im Abschnitt [Teststand](#teststand).

## Inhalt

| Skript | Zweck | Ändert etwas? | Admin nötig? |
| --- | --- | --- | --- |
| `scripts/Get-SystemInfo.ps1` | Systemübersicht (Hardware, Windows, Datenträger, Netzwerk, Updates), Export als TXT/JSON/HTML | nur die Exportdatei | nein |
| `scripts/Invoke-Cleanup.ps1` | Temporäre Dateien und Caches löschen, freigegebenen Platz melden | ja (löscht Dateien), `-WhatIf` möglich | teilweise |
| `scripts/Install-DevWorkstation.ps1` | Programme per winget, VS-Code-Erweiterungen, Git-Grundeinstellungen, Explorer-Einstellungen | ja, `-WhatIf` möglich | meist nein (einzelne Installer fragen selbst) |
| `scripts/Test-NetworkBasics.ps1` | Netzwerk-Kurzdiagnose: Adapter, Gateway, DNS, Internet, Namensauflösung, TCP 443 | nein (nur lesen und testen) | nein |

Weitere Dateien:

- `config/packages.json` - Paketliste (winget-IDs) für `Install-DevWorkstation.ps1`
- `config/vscode-extensions.txt` - VS-Code-Erweiterungen
- `config/vscode-settings.json` - Beispiel für VS-Code-Einstellungen, wird von keinem Skript angewendet
- `PSScriptAnalyzerSettings.psd1` - Einstellungen für die statische Code-Prüfung

## Voraussetzungen

- Windows 10/11
- Windows PowerShell 5.1 (in Windows enthalten) oder PowerShell 7
- für `Install-DevWorkstation.ps1`: winget (App-Installer) und Internetzugang;
  für die VS-Code-Erweiterungen der Befehl `code` im PATH

Jedes Skript hat eine eingebaute Hilfe:

```powershell
Get-Help .\scripts\Invoke-Cleanup.ps1 -Full
```

## Download

ZIP-Datei: <https://github.com/GH-Aleks/windows-admin-scripts/archive/refs/heads/main.zip>

Oder mit Git:

```powershell
git clone https://github.com/GH-Aleks/windows-admin-scripts.git
```

## Skripte ausführen (ExecutionPolicy)

Windows blockiert heruntergeladene Skripte je nach ExecutionPolicy. Die
Richtlinie muss dafür **nicht** systemweit gelockert werden. Zwei saubere Wege:

1. Die heruntergeladenen Dateien einmalig entsperren (nach dem Entpacken der ZIP-Datei):

   ```powershell
   Get-ChildItem -Path .\scripts -Filter *.ps1 | Unblock-File
   ```

2. Oder ein Skript nur für diesen einen Aufruf ausführen:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-SystemInfo.ps1
   ```

   Das gilt nur für diesen Prozess und verändert keine Einstellung.

Vorher den Quelltext lesen. Das sollte man bei jedem Skript aus dem Internet tun,
auch bei diesem.

## Die Skripte im Einzelnen

### Get-SystemInfo.ps1

Sammelt per CIM: Computer, BIOS, Windows-Version, Prozessor, Arbeitsspeicher,
Datenträger, Netzwerkadapter, ausstehenden Neustart, Defender-Status und die zuletzt installierten
Updates. Braucht keine Administratorrechte.

```powershell
# Bericht im Fenster anzeigen
.\scripts\Get-SystemInfo.ps1

# Anonymisiert als HTML exportieren (Format richtet sich nach der Endung)
.\scripts\Get-SystemInfo.ps1 -Anonymize -ExportPath "$env:TEMP\systeminfo.html"

# Als Objekt weiterverarbeiten
.\scripts\Get-SystemInfo.ps1 -PassThru
```

`-Anonymize` blendet Seriennummer, MAC-Adressen, Benutzernamen, Computernamen und
den Domänennamen aus. **IP-Adressen bleiben sichtbar**, weil sie bei der
Fehlersuche gebraucht werden. Vor dem Weitergeben eines Berichts bitte
trotzdem selbst prüfen.

### Invoke-Cleanup.ps1

Löscht nur fest hinterlegte Ziele: Temp-Ordner des Benutzers, Windows-Temp,
Browser-Caches (Edge, Chrome, Firefox), Windows-Update-Download-Cache. Optional
Papierkorb, Miniaturansicht-Cache und Komponentenspeicher-Bereinigung (DISM).
Persönliche Ordner wie Dokumente, Downloads oder Desktop werden nicht angefasst.
Verknüpfungspunkte (Junctions/Symlinks) werden nicht verfolgt. Gesperrte Dateien
werden übersprungen und gezählt. Am Ende steht der tatsächlich freigegebene Platz.

```powershell
# IMMER ZUERST: nur anzeigen, was gelöscht würde
.\scripts\Invoke-Cleanup.ps1 -WhatIf

# Dann wirklich aufräumen (mit Rückfrage je Ziel: -Confirm)
.\scripts\Invoke-Cleanup.ps1

# Mit Papierkorb und Protokolldatei
.\scripts\Invoke-Cleanup.ps1 -IncludeRecycleBin -LogPath "$env:TEMP\cleanup.log"
```

Ohne Administratorrechte werden Windows-Temp, Update-Cache und DISM übersprungen
und das im Ergebnis gemeldet.

### Install-DevWorkstation.ps1

Richtet einen Entwickler-PC ein. Jeder Teil lässt sich einzeln abschalten.

```powershell
# IMMER ZUERST: nur anzeigen, was passieren würde
.\scripts\Install-DevWorkstation.ps1 -WhatIf

# Pakete und Erweiterungen installieren
.\scripts\Install-DevWorkstation.ps1

# Mit optionalen Paketen, Git-Grundeinstellungen und Explorer-Einstellungen
.\scripts\Install-DevWorkstation.ps1 -IncludeOptional -ConfigureGit `
    -GitUserName "Vorname Nachname" -GitUserEmail "name@example.com" -ConfigureExplorer
```

Wichtige Punkte:

- Installiert wird per `winget install --id <ID> --exact --source winget`.
  Die Lizenzbedingungen werden **nicht** automatisch akzeptiert; das passiert nur,
  wenn ausdrücklich `-AcceptAgreements` angegeben wird.
- Git-Name und -E-Mail werden **nur** gesetzt, wenn sie als Parameter übergeben
  werden. Im Skript steht keine persönliche Angabe.
- Explorer-Einstellungen (Dateiendungen, versteckte Dateien anzeigen) werden nur
  mit `-ConfigureExplorer` geändert, und nur für den aktuellen Benutzer (HKCU).
- VS-Code-Einstellungen werden nicht verändert. `config/vscode-settings.json`
  ist nur ein Beispiel zum Selbst-Übernehmen.
- Die Paketliste liegt in `config/packages.json` und kann angepasst werden.

### Test-NetworkBasics.ps1

Prüft der Reihe nach: Netzwerkadapter mit IP, Ping zum Gateway, Ping zu den
DNS-Servern, Ping ins Internet (per IP, ohne DNS), Namensauflösung und eine
TCP-Verbindung auf Port 443. Am Ende steht eine Einordnung, wo das Problem
vermutlich liegt. Es wird nichts verändert.

```powershell
.\scripts\Test-NetworkBasics.ps1
.\scripts\Test-NetworkBasics.ps1 -TcpTestHost "example.com" -PingCount 4 -PassThru | Format-Table
```

## Sicherheitshinweise

- Bei `Invoke-Cleanup.ps1` und `Install-DevWorkstation.ps1` zuerst mit `-WhatIf` laufen lassen.
- Berichte von `Get-SystemInfo.ps1` enthalten Geräte- und Benutzerdaten.
  Nicht ungeprüft in öffentliche Tickets oder Foren stellen.
- Die Skripte enthalten keine Zugangsdaten und laden keinen Code aus dem Internet nach
  (außer den Paketen, die winget aus der offiziellen Quelle installiert).
- Keine Skripte mit Administratorrechten starten, die man nicht gelesen hat.

## Code-Prüfung

Die Skripte werden mit [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
geprüft, lokal und bei jedem Push über GitHub Actions
(`.github/workflows/lint.yml`):

```powershell
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

## Teststand

Getestet auf einem Windows-11-PC mit **Windows PowerShell 5.1**:

- PSScriptAnalyzer 1.25.0: keine Fehler und keine Warnungen, auch nicht mit der
  Syntax-Prüfung für 5.1 und 7.0.
- `Get-SystemInfo.ps1`: echt ausgeführt, auch mit `-Anonymize` und mit Export
  nach TXT, JSON und HTML.
- `Test-NetworkBasics.ps1`: echt ausgeführt.
- `Invoke-Cleanup.ps1` und `Install-DevWorkstation.ps1`: **nur mit `-WhatIf`**
  ausgeführt (Install-DevWorkstation auch mit Git- und Explorer-Optionen).

**Nicht getestet:**

- PowerShell 7 (auf dem Testrechner nicht installiert). Die Skripte sind dafür
  geschrieben und syntaktisch geprüft, aber nicht ausgeführt.
- Echtes Löschen, echte Installation über winget und echte Änderung der
  Git- und Explorer-Einstellungen.
- Pfade, die Administratorrechte brauchen (Windows-Temp, Update-Cache mit
  Dienst-Stopp, DISM).
- Automatische Tests mit Pester. Auf dem Testrechner ist nur Pester 3.4
  vorhanden; Tests dafür gibt es daher noch nicht.

Bekannte Grenzen: `Get-HotFix` zeigt nicht alle Updates (z. B. keine
Defender-Signaturen). Beim ersten `winget`-Aufruf kann Windows eine
Quellen-Vereinbarung anzeigen, die einmalig bestätigt werden muss.

## English summary

A small collection of PowerShell scripts for IT support on Windows: a system
overview report (TXT/JSON/HTML, optional anonymisation), a cautious cleanup tool
with `-WhatIf`, a winget-based developer workstation setup (licence agreements
only accepted with an explicit switch; Git identity only via parameters) and a
read-only network diagnosis. All scripts target Windows PowerShell 5.1 and
PowerShell 7, use comment-based help and German output. Only 5.1 has been run;
PowerShell 7 and destructive paths are untested (see "Teststand"). The project
was implemented with AI assistance (Claude) and reviewed and tested by me.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
