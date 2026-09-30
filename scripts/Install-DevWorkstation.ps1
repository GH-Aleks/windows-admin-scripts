<#
.SYNOPSIS
    Richtet eine Entwickler-Arbeitsstation mit winget, VS-Code-Erweiterungen und Git-Grundeinstellungen ein.

.DESCRIPTION
    Führt nacheinander aus (jeder Teil lässt sich abschalten oder ist ein Schalter):

      1. Pakete aus config\packages.json per winget installieren
         (immer mit --id --exact --source winget; bereits installierte Pakete werden übersprungen).
         Pakete mit "optional": true werden nur mit -IncludeOptional berücksichtigt.
      2. VS-Code-Erweiterungen aus config\vscode-extensions.txt installieren
         (bereits installierte werden übersprungen).
      3. Git-Grundeinstellungen setzen (nur mit -ConfigureGit oder wenn -GitUserName /
         -GitUserEmail angegeben sind): init.defaultBranch=main, core.autocrlf=true,
         pull.rebase=false, core.editor="code --wait". Name und E-Mail werden
         ausschließlich aus den Parametern übernommen und nie im Skript festgelegt.
      4. Explorer-Einstellungen (nur mit -ConfigureExplorer): Dateiendungen und
         versteckte Dateien anzeigen. Es wird nur HKCU (aktueller Benutzer) geändert.

    Beispiel-Einstellungen für VS Code liegen in config\vscode-settings.json. Das Skript
    wendet sie bewusst NICHT an, damit keine vorhandene Konfiguration überschrieben wird;
    Hinweise zum manuellen Übernehmen stehen in der README.

    Die Lizenz- und Quellenvereinbarungen von winget werden nur mit dem Schalter
    -AcceptAgreements automatisch bestätigt. Ohne ihn fragt winget gegebenenfalls selbst nach.

    Alle Änderungen unterstützen -WhatIf und -Confirm. Mit -WhatIf werden lediglich lesende
    Prüfungen ausgeführt (z. B. "winget list"), aber nichts installiert oder geändert.

.PARAMETER PackageFile
    Pfad zur Paketliste (JSON). Standard: config\packages.json neben dem Skriptordner.

.PARAMETER ExtensionFile
    Pfad zur Erweiterungsliste (eine Erweiterungs-ID je Zeile, "#" beginnt einen Kommentar).
    Standard: config\vscode-extensions.txt neben dem Skriptordner.

.PARAMETER IncludeOptional
    Installiert auch Pakete, die in der Paketliste mit "optional": true markiert sind
    (Standardliste: Python und Docker Desktop).

.PARAMETER AcceptAgreements
    Übergibt --accept-package-agreements und --accept-source-agreements an winget.
    Nur setzen, wenn die Lizenzbedingungen der Pakete gelesen und akzeptiert wurden.

.PARAMETER SkipPackages
    Überspringt die Paketinstallation.

.PARAMETER SkipExtensions
    Überspringt die VS-Code-Erweiterungen.

.PARAMETER ConfigureGit
    Setzt die Git-Grundeinstellungen (global).

.PARAMETER GitUserName
    Wert für user.name. Wird nur gesetzt, wenn angegeben. Aktiviert die Git-Konfiguration.

.PARAMETER GitUserEmail
    Wert für user.email. Wird nur gesetzt, wenn angegeben. Aktiviert die Git-Konfiguration.

.PARAMETER ConfigureExplorer
    Stellt den Explorer so ein, dass Dateiendungen und versteckte Dateien angezeigt werden
    (HKCU). Das Ändern wirkt nach einem Neustart des Explorers oder einer Neuanmeldung.

.PARAMETER PassThru
    Gibt zusätzlich die Ergebnisliste als Objekte zurück.

.EXAMPLE
    .\Install-DevWorkstation.ps1 -WhatIf

    Zeigt, was installiert und eingerichtet würde, ohne etwas zu verändern.

.EXAMPLE
    .\Install-DevWorkstation.ps1 -AcceptAgreements -IncludeOptional

    Installiert alle Pakete inklusive der optionalen und bestätigt die winget-Vereinbarungen.

.EXAMPLE
    .\Install-DevWorkstation.ps1 -SkipPackages -ConfigureGit -GitUserName "Max Mustermann" -GitUserEmail "max@example.com" -ConfigureExplorer

    Nur Git und Explorer einrichten (Name und E-Mail sind hier Platzhalter).

.INPUTS
    Keine.

.OUTPUTS
    Keine; mit -PassThru ein Objekt je Schritt (Bereich, Element, Status, Detail).

.NOTES
    Getestet mit Windows PowerShell 5.1 (ausschließlich mit -WhatIf). Vorgesehen für Windows PowerShell 5.1
    und PowerShell 7. Benötigt winget (App-Installer) und eine Internetverbindung. Einzelne
    Installer fordern selbst Administratorrechte an (UAC-Abfrage).
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$PackageFile,

    [string]$ExtensionFile,

    [switch]$IncludeOptional,

    [switch]$AcceptAgreements,

    [switch]$SkipPackages,

    [switch]$SkipExtensions,

    [switch]$ConfigureGit,

    [string]$GitUserName,

    [string]$GitUserEmail,

    [switch]$ConfigureExplorer,

    [switch]$PassThru
)

$InformationPreference = 'Continue'
$script:Ergebnisse = New-Object -TypeName 'System.Collections.Generic.List[object]'

# winget-Exitcodes (HRESULT als vorzeichenbehaftete Zahl)
$script:WingetNichtGefunden = -1978335212   # 0x8A150014: keine Anwendung gefunden
$script:WingetSchonAktuell = -1978335189    # 0x8A15002B: bereits installiert / keine Aktualisierung anwendbar

#region Hilfsfunktionen

function Write-Status {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Information -MessageData $Text
}

function Add-Schritt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Bereich,
        [Parameter(Mandatory)][string]$Element,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ''
    )
    $script:Ergebnisse.Add([pscustomobject]@{
            Bereich = $Bereich
            Element = $Element
            Status  = $Status
            Detail  = $Detail
        })
    $zeile = '  [{0}] {1}' -f $Status, $Element
    if ($Detail) { $zeile = '{0} - {1}' -f $zeile, $Detail }
    Write-Status $zeile
}

function Get-StandardPfad {
    # Liefert den Standardpfad einer Konfigurationsdatei relativ zum Skriptordner.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Dateiname)

    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $null }
    $konfig = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'config'
    return (Join-Path -Path $konfig -ChildPath $Dateiname)
}

function Get-AktuellerPfad {
    # Liefert den PATH aus Registry (Maschine + Benutzer), damit neu installierte Programme gefunden werden.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $maschine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $benutzer = [Environment]::GetEnvironmentVariable('Path', 'User')
    $teile = @($maschine, $benutzer) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($teile.Count -eq 0) { return $env:Path }
    return ($teile -join ';')
}

function Get-WingetPfad {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $befehl = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($befehl) { return $befehl.Source }
    return $null
}

function Test-WingetPaket {
    # $true = installiert, $false = nicht installiert, $null = nicht feststellbar
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Winget,
        [Parameter(Mandatory)][string]$Id,
        [switch]$Zustimmung
    )
    $argumente = @('list', '--id', $Id, '--exact', '--source', 'winget')
    if ($Zustimmung) { $argumente += '--accept-source-agreements' }
    $null = & $Winget @argumente 2>&1
    $code = [int]$LASTEXITCODE
    if ($code -eq 0) { return $true }
    if ($code -eq $script:WingetNichtGefunden) { return $false }
    return $null
}

function Read-Paketliste {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pfad)

    if (-not (Test-Path -LiteralPath $Pfad -PathType Leaf)) {
        throw "Paketliste nicht gefunden: $Pfad"
    }
    try {
        $inhalt = Get-Content -LiteralPath $Pfad -Raw -Encoding UTF8 -ErrorAction Stop
        $daten = $inhalt | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Paketliste ist kein gültiges JSON ($Pfad): $($_.Exception.Message)"
    }
    if ($null -eq $daten -or $null -eq $daten.packages) {
        throw "Paketliste enthält keinen Eintrag 'packages': $Pfad"
    }

    $gueltig = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($eintrag in @($daten.packages)) {
        $id = [string]$eintrag.id
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
            Write-Warning "Eintrag mit ungültiger Paket-ID wird ignoriert: '$id'"
            continue
        }
        $name = [string]$eintrag.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
        $gueltig.Add([pscustomobject]@{
                Id       = $id
                Name     = $name
                Optional = [bool]$eintrag.optional
            })
    }
    return $gueltig.ToArray()
}

function Read-Erweiterungsliste {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pfad)

    if (-not (Test-Path -LiteralPath $Pfad -PathType Leaf)) {
        throw "Erweiterungsliste nicht gefunden: $Pfad"
    }
    $ids = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($zeile in (Get-Content -LiteralPath $Pfad -Encoding UTF8)) {
        $text = ($zeile -split '#', 2)[0].Trim()
        if ($text.Length -eq 0) { continue }
        if ($text -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$') {
            Write-Warning "Ungültige Erweiterungs-ID wird ignoriert: '$text'"
            continue
        }
        $ids.Add($text)
    }
    return $ids.ToArray()
}

function Get-CodeBefehl {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $befehl = Get-Command -Name 'code.cmd', 'code' -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($befehl) { return $befehl.Source }

    $kandidaten = @(
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($kandidat in $kandidaten) {
        if ($kandidat -and (Test-Path -LiteralPath $kandidat -PathType Leaf)) { return $kandidat }
    }
    return $null
}

function Get-GitBefehl {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $befehl = Get-Command -Name 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($befehl) { return $befehl.Source }

    $kandidat = Join-Path -Path $env:ProgramFiles -ChildPath 'Git\cmd\git.exe'
    if (Test-Path -LiteralPath $kandidat -PathType Leaf) { return $kandidat }
    return $null
}

#endregion

#region Schritte

function Install-Pakete {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Datei,
        [switch]$MitOptionalen,
        [switch]$Zustimmung
    )

    Write-Status '== Pakete (winget) =='

    $pfad = $Datei
    if ([string]::IsNullOrWhiteSpace($pfad)) { $pfad = Get-StandardPfad -Dateiname 'packages.json' }
    if ([string]::IsNullOrWhiteSpace($pfad)) {
        Add-Schritt -Bereich 'Pakete' -Element 'Paketliste' -Status 'Fehler' -Detail 'Pfad nicht bestimmbar, bitte -PackageFile angeben'
        return
    }
    try {
        $pakete = @(Read-Paketliste -Pfad $pfad)
    }
    catch {
        Add-Schritt -Bereich 'Pakete' -Element 'Paketliste' -Status 'Fehler' -Detail $_.Exception.Message
        return
    }

    $winget = Get-WingetPfad
    if (-not $winget) {
        Add-Schritt -Bereich 'Pakete' -Element 'winget' -Status 'Fehler' -Detail 'winget nicht gefunden (App-Installer aus dem Microsoft Store installieren)'
        return
    }

    $installiert = $false
    foreach ($paket in $pakete) {
        $anzeige = '{0} ({1})' -f $paket.Name, $paket.Id
        if ($paket.Optional -and -not $MitOptionalen) {
            Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'übersprungen' -Detail 'optional, -IncludeOptional nicht gesetzt'
            continue
        }

        $vorhanden = Test-WingetPaket -Winget $winget -Id $paket.Id -Zustimmung:$Zustimmung
        if ($vorhanden -eq $true) {
            Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'bereits installiert'
            continue
        }

        $argumente = @('install', '--id', $paket.Id, '--exact', '--source', 'winget')
        if ($Zustimmung) { $argumente += @('--accept-package-agreements', '--accept-source-agreements') }

        $hinweis = 'winget ' + ($argumente -join ' ')
        if (-not $PSCmdlet.ShouldProcess($anzeige, $hinweis)) {
            if ($WhatIfPreference) {
                $detail = 'würde installiert'
                if ($null -eq $vorhanden) { $detail = 'Installationsstatus unbekannt, würde installiert' }
                Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'Simulation' -Detail $detail
            }
            else {
                Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'abgelehnt'
            }
            continue
        }

        Write-Status ('  Installiere {0} ...' -f $anzeige)
        & $winget @argumente | Out-Host
        $code = [int]$LASTEXITCODE
        if ($code -eq 0) {
            Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'installiert'
            $installiert = $true
        }
        elseif ($code -eq $script:WingetSchonAktuell) {
            Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'bereits installiert' -Detail 'winget: keine Änderung nötig'
        }
        else {
            Add-Schritt -Bereich 'Pakete' -Element $anzeige -Status 'Fehler' -Detail ('winget-Exitcode {0}' -f $code)
        }
    }

    if ($installiert) { $env:Path = Get-AktuellerPfad }
}

function Install-Erweiterungen {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Datei)

    Write-Status '== VS-Code-Erweiterungen =='

    $pfad = $Datei
    if ([string]::IsNullOrWhiteSpace($pfad)) { $pfad = Get-StandardPfad -Dateiname 'vscode-extensions.txt' }
    if ([string]::IsNullOrWhiteSpace($pfad)) {
        Add-Schritt -Bereich 'Erweiterungen' -Element 'Erweiterungsliste' -Status 'Fehler' -Detail 'Pfad nicht bestimmbar, bitte -ExtensionFile angeben'
        return
    }
    try {
        $erweiterungen = @(Read-Erweiterungsliste -Pfad $pfad)
    }
    catch {
        Add-Schritt -Bereich 'Erweiterungen' -Element 'Erweiterungsliste' -Status 'Fehler' -Detail $_.Exception.Message
        return
    }
    if ($erweiterungen.Count -eq 0) {
        Add-Schritt -Bereich 'Erweiterungen' -Element 'Erweiterungsliste' -Status 'leer'
        return
    }

    $code = Get-CodeBefehl
    if (-not $code) {
        $detail = 'VS Code (Befehl "code") nicht gefunden'
        if ($WhatIfPreference) { $detail = $detail + '; wäre ggf. erst nach der Paketinstallation vorhanden' }
        Add-Schritt -Bereich 'Erweiterungen' -Element 'VS Code' -Status 'übersprungen' -Detail $detail
        return
    }

    $vorhandene = @(& $code --list-extensions 2>$null)
    if ([int]$LASTEXITCODE -ne 0) {
        Add-Schritt -Bereich 'Erweiterungen' -Element 'VS Code' -Status 'Fehler' -Detail 'Erweiterungen ließen sich nicht auflisten'
        return
    }
    $vorhandeneKlein = @($vorhandene | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() })

    foreach ($id in $erweiterungen) {
        if ($vorhandeneKlein -contains $id.ToLowerInvariant()) {
            Add-Schritt -Bereich 'Erweiterungen' -Element $id -Status 'bereits installiert'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($id, 'VS-Code-Erweiterung installieren')) {
            if ($WhatIfPreference) {
                Add-Schritt -Bereich 'Erweiterungen' -Element $id -Status 'Simulation' -Detail 'würde installiert'
            }
            else {
                Add-Schritt -Bereich 'Erweiterungen' -Element $id -Status 'abgelehnt'
            }
            continue
        }
        & $code --install-extension $id | Out-Host
        if ([int]$LASTEXITCODE -eq 0) {
            Add-Schritt -Bereich 'Erweiterungen' -Element $id -Status 'installiert'
        }
        else {
            Add-Schritt -Bereich 'Erweiterungen' -Element $id -Status 'Fehler' -Detail ('Exitcode {0}' -f $LASTEXITCODE)
        }
    }
}

function Set-GitGrundeinstellung {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Status '== Git-Grundeinstellungen (global) =='

    $git = Get-GitBefehl
    if (-not $git) {
        $detail = 'Git nicht gefunden'
        if ($WhatIfPreference) { $detail = $detail + '; wäre ggf. erst nach der Paketinstallation vorhanden' }
        Add-Schritt -Bereich 'Git' -Element 'Git' -Status 'übersprungen' -Detail $detail
        return
    }

    $einstellungen = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $einstellungen.Add([pscustomobject]@{ Schluessel = 'init.defaultBranch'; Wert = 'main' })
    $einstellungen.Add([pscustomobject]@{ Schluessel = 'core.autocrlf'; Wert = 'true' })
    $einstellungen.Add([pscustomobject]@{ Schluessel = 'pull.rebase'; Wert = 'false' })
    $einstellungen.Add([pscustomobject]@{ Schluessel = 'core.editor'; Wert = 'code --wait' })

    if (-not [string]::IsNullOrWhiteSpace($GitUserName)) {
        if ($GitUserName -match '[\x00-\x1F]') {
            Add-Schritt -Bereich 'Git' -Element 'user.name' -Status 'Fehler' -Detail 'Name enthält Steuerzeichen'
        }
        else {
            $einstellungen.Add([pscustomobject]@{ Schluessel = 'user.name'; Wert = $GitUserName.Trim() })
        }
    }
    else {
        Add-Schritt -Bereich 'Git' -Element 'user.name' -Status 'nicht gesetzt' -Detail '-GitUserName nicht angegeben'
    }

    if (-not [string]::IsNullOrWhiteSpace($GitUserEmail)) {
        if ($GitUserEmail.Trim() -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Add-Schritt -Bereich 'Git' -Element 'user.email' -Status 'Fehler' -Detail 'E-Mail-Adresse hat kein gültiges Format'
        }
        else {
            $einstellungen.Add([pscustomobject]@{ Schluessel = 'user.email'; Wert = $GitUserEmail.Trim() })
        }
    }
    else {
        Add-Schritt -Bereich 'Git' -Element 'user.email' -Status 'nicht gesetzt' -Detail '-GitUserEmail nicht angegeben'
    }

    foreach ($einstellung in $einstellungen) {
        $schluessel = $einstellung.Schluessel
        $aktuell = (& $git config --global --get $schluessel 2>$null)
        if ($aktuell -is [array]) { $aktuell = $aktuell -join "`n" }
        if ($null -ne $aktuell -and $aktuell.ToString().Trim() -ceq $einstellung.Wert) {
            Add-Schritt -Bereich 'Git' -Element $schluessel -Status 'bereits gesetzt'
            continue
        }

        $beschreibung = 'git config --global {0} "{1}"' -f $schluessel, $einstellung.Wert
        if (-not $PSCmdlet.ShouldProcess($schluessel, $beschreibung)) {
            if ($WhatIfPreference) {
                Add-Schritt -Bereich 'Git' -Element $schluessel -Status 'Simulation' -Detail ('würde auf "{0}" gesetzt' -f $einstellung.Wert)
            }
            else {
                Add-Schritt -Bereich 'Git' -Element $schluessel -Status 'abgelehnt'
            }
            continue
        }
        & $git config --global $schluessel $einstellung.Wert
        if ([int]$LASTEXITCODE -eq 0) {
            Add-Schritt -Bereich 'Git' -Element $schluessel -Status 'gesetzt' -Detail $einstellung.Wert
        }
        else {
            Add-Schritt -Bereich 'Git' -Element $schluessel -Status 'Fehler' -Detail ('Exitcode {0}' -f $LASTEXITCODE)
        }
    }
}

function Set-ExplorerEinstellung {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Status '== Explorer-Einstellungen (HKCU) =='

    $schluesselPfad = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $einstellungen = @(
        [pscustomobject]@{ Name = 'HideFileExt'; Wert = 0; Text = 'Dateiendungen anzeigen' }
        [pscustomobject]@{ Name = 'Hidden'; Wert = 1; Text = 'Versteckte Dateien anzeigen' }
    )

    foreach ($einstellung in $einstellungen) {
        $aktuell = $null
        try {
            $aktuell = (Get-ItemProperty -LiteralPath $schluesselPfad -Name $einstellung.Name -ErrorAction Stop).($einstellung.Name)
        }
        catch {
            $aktuell = $null
        }
        if ($null -ne $aktuell -and [int]$aktuell -eq $einstellung.Wert) {
            Add-Schritt -Bereich 'Explorer' -Element $einstellung.Text -Status 'bereits gesetzt'
            continue
        }

        $beschreibung = '{0}\{1} = {2}' -f $schluesselPfad, $einstellung.Name, $einstellung.Wert
        if (-not $PSCmdlet.ShouldProcess($einstellung.Text, $beschreibung)) {
            if ($WhatIfPreference) {
                Add-Schritt -Bereich 'Explorer' -Element $einstellung.Text -Status 'Simulation' -Detail 'würde gesetzt'
            }
            else {
                Add-Schritt -Bereich 'Explorer' -Element $einstellung.Text -Status 'abgelehnt'
            }
            continue
        }
        try {
            Set-ItemProperty -LiteralPath $schluesselPfad -Name $einstellung.Name -Value $einstellung.Wert -Type DWord -ErrorAction Stop
            Add-Schritt -Bereich 'Explorer' -Element $einstellung.Text -Status 'gesetzt' -Detail 'wirkt nach Neustart des Explorers bzw. Neuanmeldung'
        }
        catch {
            Add-Schritt -Bereich 'Explorer' -Element $einstellung.Text -Status 'Fehler' -Detail $_.Exception.Message
        }
    }
}

#endregion

#region Ablauf

$simulation = [bool]$WhatIfPreference
if ($simulation) {
    Write-Status 'Einrichtung gestartet - SIMULATION (-WhatIf): es wird nichts installiert oder verändert'
}
else {
    Write-Status 'Einrichtung gestartet'
}
Write-Status ''

if (-not $SkipPackages) { Install-Pakete -Datei $PackageFile -MitOptionalen:$IncludeOptional -Zustimmung:$AcceptAgreements; Write-Status '' }
if (-not $SkipExtensions) { Install-Erweiterungen -Datei $ExtensionFile; Write-Status '' }

$gitAktiv = $ConfigureGit -or (-not [string]::IsNullOrWhiteSpace($GitUserName)) -or (-not [string]::IsNullOrWhiteSpace($GitUserEmail))
if ($gitAktiv) { Set-GitGrundeinstellung; Write-Status '' }

if ($ConfigureExplorer) { Set-ExplorerEinstellung; Write-Status '' }

# Zusammenfassung
Write-Status '== Zusammenfassung =='
$gruppen = @($script:Ergebnisse | Group-Object -Property Status | Sort-Object -Property Name)
if ($gruppen.Count -eq 0) {
    Write-Status '  Es wurde nichts ausgeführt.'
}
foreach ($gruppe in $gruppen) {
    Write-Status ('  {0}: {1}' -f $gruppe.Name, $gruppe.Count)
}
$fehler = @($script:Ergebnisse | Where-Object { $_.Status -eq 'Fehler' })
if ($fehler.Count -gt 0) {
    Write-Warning ('{0} Schritt(e) mit Fehler - Details siehe oben.' -f $fehler.Count)
}
if ($simulation) {
    Write-Status '  Simulation beendet: Es wurde nichts installiert oder verändert.'
}
if ($gitAktiv -or $ConfigureExplorer -or -not $SkipPackages) {
    Write-Status '  Hinweis: Neu installierte Programme sind ggf. erst in einem neuen Terminal im PATH.'
}

if ($PassThru) {
    $script:Ergebnisse.ToArray()
}

#endregion
