<#
.SYNOPSIS
    Räumt temporäre Dateien und Caches auf und zeigt den gewonnenen Speicherplatz.

.DESCRIPTION
    Bereinigt fest definierte Ordner:

      - Temp-Ordner des angemeldeten Benutzers
      - Windows-Temp-Ordner (nur als Administrator)
      - Browser-Caches von Edge, Chrome und Firefox (nur Cache-Ordner, niemals
        Profile, Kennwörter, Cookies, Verlauf oder Lesezeichen)
      - Download-Cache von Windows Update (nur als Administrator; die Dienste
        wuauserv und bits werden dafür angehalten und danach wieder gestartet)

    Optional (Schalter):

      - Papierkorb leeren (-IncludeRecycleBin)
      - Miniaturansicht-Cache (-IncludeThumbnailCache)
      - Windows-Komponentenspeicher per DISM bereinigen (-IncludeComponentCleanup,
        nur als Administrator, kann mehrere Minuten dauern)

    Sicherheitsmerkmale:

      - Mit -WhatIf wird nichts gelöscht, angehalten oder geleert. Es wird nur
        angezeigt, was passieren würde, samt geschätzter Größe.
      - Jeder Zielordner muss einem festen Muster entsprechen (z. B. "...\AppData\Local\Temp")
        und wird vor dem Löschen geprüft: nicht leer, absolut, nicht zu flach,
        kein Laufwerks-/Profil-/Windows-Stammordner, kein Verknüpfungspunkt.
        Ist eine Prüfung nicht erfüllt, wird der Bereich übersprungen.
      - Verknüpfungen (Junctions/Symlinks) werden nie verfolgt und nie gelöscht.
      - Gesperrte oder geschützte Dateien werden übersprungen und gezählt.
      - Es wird ausschließlich der Inhalt der definierten Ordner gelöscht.

    Der freie Speicherplatz des Systemlaufwerks wird vorher und nachher gemessen.
    Die Differenz kann von der Summe der gelöschten Dateien abweichen, weil Windows
    im Hintergrund selbst Speicher belegt oder freigibt.

.PARAMETER IncludeRecycleBin
    Leert zusätzlich den Papierkorb (alle Laufwerke des angemeldeten Benutzers).
    Gelöschte Dateien sind danach nicht mehr wiederherstellbar.

.PARAMETER IncludeThumbnailCache
    Löscht zusätzlich die Miniaturansicht-Caches (thumbcache_*.db). Windows baut sie
    bei Bedarf neu auf. Dateien, die der Explorer gerade benutzt, werden übersprungen.

.PARAMETER IncludeComponentCleanup
    Führt zusätzlich "Dism.exe /Online /Cleanup-Image /StartComponentCleanup" aus.
    Benötigt Administratorrechte und kann lange dauern.

.PARAMETER SkipBrowserCache
    Lässt die Browser-Caches aus.

.PARAMETER LogPath
    Optionale Protokolldatei (wird angehängt). Der Ordner muss existieren.
    Die Datei wird auch bei -WhatIf geschrieben; die Zeilen sind dann als
    Simulation gekennzeichnet.

.PARAMETER PassThru
    Gibt zusätzlich die Ergebnisse je Bereich als Objekte zurück.

.EXAMPLE
    .\Invoke-Cleanup.ps1 -WhatIf

    Zeigt nur an, was bereinigt würde, ohne etwas zu verändern. Das ist der
    empfohlene erste Aufruf.

.EXAMPLE
    .\Invoke-Cleanup.ps1 -IncludeThumbnailCache -LogPath "$env:TEMP\cleanup.log"

    Bereinigt die Standardbereiche plus Miniaturansicht-Cache und schreibt ein Protokoll.

.EXAMPLE
    .\Invoke-Cleanup.ps1 -IncludeRecycleBin -IncludeComponentCleanup -Confirm

    Fragt vor jedem Bereich nach. In einer PowerShell mit Administratorrechten
    werden auch Windows-Temp, der Update-Cache und DISM berücksichtigt.

.INPUTS
    Keine.

.OUTPUTS
    Keine; mit -PassThru ein Objekt je Bereich (Bereich, Status, Dateien, Bytes, Uebersprungen).

.NOTES
    Getestet mit Windows PowerShell 5.1. Vorgesehen für Windows PowerShell 5.1 und PowerShell 7.
    Vor dem ersten echten Lauf immer mit -WhatIf prüfen. Schließen Sie Browser vor der
    Bereinigung, sonst bleiben deren gesperrte Cache-Dateien liegen.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [switch]$IncludeRecycleBin,

    [switch]$IncludeThumbnailCache,

    [switch]$IncludeComponentCleanup,

    [switch]$SkipBrowserCache,

    [string]$LogPath,

    [switch]$PassThru
)

$InformationPreference = 'Continue'
$script:LogDatei = $null

#region Hilfsfunktionen

function Test-Administrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identitaet = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $prinzipal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identitaet
    return $prinzipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Status {
    # Meldung auf den Information-Stream und, falls gewünscht, in die Protokolldatei.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    Write-Information -MessageData $Text
    if ($script:LogDatei) {
        $zeile = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        try {
            # Bewusst auch bei -WhatIf schreiben: Die Protokolldatei wurde ausdrücklich angefordert.
            Add-Content -LiteralPath $script:LogDatei -Value $zeile -Encoding UTF8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
        }
        catch {
            Write-Warning "Protokolldatei nicht beschreibbar, Protokollierung wird beendet: $($_.Exception.Message)"
            $script:LogDatei = $null
        }
    }
}

function Format-Groesse {
    [CmdletBinding()]
    [OutputType([string])]
    param([Nullable[long]]$Bytes)

    if ($null -eq $Bytes) { return 'nicht ermittelbar' }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} Bytes' -f $Bytes)
}

function Get-FreierSpeicher {
    [CmdletBinding()]
    [OutputType([long])]
    param()
    try {
        $wurzel = [System.IO.Path]::GetPathRoot($env:SystemRoot)
        if ([string]::IsNullOrWhiteSpace($wurzel)) { return $null }
        $laufwerk = New-Object -TypeName System.IO.DriveInfo -ArgumentList $wurzel
        return [long]$laufwerk.AvailableFreeSpace
    }
    catch {
        return $null
    }
}

function Join-ZielPfad {
    # Verbindet zwei Pfadteile nur, wenn beide nicht leer sind. Sonst $null (nie ein halber Pfad).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Basis,
        [Parameter(Mandatory)][string]$Unterpfad
    )
    if ([string]::IsNullOrWhiteSpace($Basis)) { return $null }
    return (Join-Path -Path $Basis -ChildPath $Unterpfad)
}

function Get-ErgebnisObjekt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Bereich,
        [Parameter(Mandatory)][string]$Status,
        [int]$Dateien = 0,
        [Nullable[long]]$Bytes = 0,
        [int]$Uebersprungen = 0
    )
    return [pscustomobject]@{
        Bereich       = $Bereich
        Status        = $Status
        Dateien       = $Dateien
        Bytes         = $Bytes
        Uebersprungen = $Uebersprungen
    }
}

function Test-SicheresZiel {
    # Liefert $null, wenn das Ziel unbedenklich ist, sonst den Grund der Ablehnung.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Pfad,
        [Parameter(Mandatory)][string]$Muster
    )

    if ([string]::IsNullOrWhiteSpace($Pfad)) { return 'Pfad ist leer (fehlt eine Umgebungsvariable?)' }
    if ($Pfad.IndexOfAny([char[]]'*?<>|"') -ge 0) { return 'Pfad enthält Platzhalter oder ungültige Zeichen' }
    if (-not [System.IO.Path]::IsPathRooted($Pfad)) { return 'Pfad ist nicht absolut' }

    try {
        $voll = [System.IO.Path]::GetFullPath($Pfad)
    }
    catch {
        return 'Pfad ist ungültig'
    }
    $ohneEnde = $voll.TrimEnd('\')
    if ($ohneEnde -ne $Pfad.TrimEnd('\')) { return 'Pfad ist nicht normalisiert (z. B. ".." enthalten)' }

    $segmente = @($ohneEnde.Split('\') | Where-Object { $_.Length -gt 0 })
    if ($segmente.Count -lt 3) { return 'Pfad ist zu flach (Laufwerks- oder Stammordner)' }

    $geschuetzt = @(
        $env:SystemDrive, $env:SystemRoot, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
        $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}
    )
    foreach ($eintrag in $geschuetzt) {
        if (-not [string]::IsNullOrWhiteSpace($eintrag) -and $eintrag.TrimEnd('\') -ieq $ohneEnde) {
            return 'Pfad ist ein geschützter Systemordner'
        }
    }

    if (-not [regex]::IsMatch($ohneEnde, $Muster, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        return 'Pfad entspricht nicht dem erwarteten Muster'
    }
    return $null
}

function Get-ZielInhalt {
    # Sammelt Dateien und Ordner unterhalb von Pfad, ohne Verknüpfungen zu verfolgen.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pfad,
        [string]$Filter
    )

    $dateien = New-Object -TypeName 'System.Collections.Generic.List[System.IO.FileInfo]'
    $ordner = New-Object -TypeName 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $links = 0
    $fehler = 0
    $verknuepfung = [System.IO.FileAttributes]::ReparsePoint
    $wurzel = New-Object -TypeName System.IO.DirectoryInfo -ArgumentList $Pfad

    if ($Filter) {
        # Nur Dateien direkt im Ordner, die zum Muster passen (kein Abstieg in Unterordner).
        try {
            foreach ($datei in $wurzel.EnumerateFiles($Filter)) {
                if (($datei.Attributes -band $verknuepfung) -ne 0) { $links++ } else { $dateien.Add($datei) }
            }
        }
        catch {
            $fehler++
        }
    }
    else {
        $stapel = New-Object -TypeName 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stapel.Push($wurzel)
        while ($stapel.Count -gt 0) {
            $aktuell = $stapel.Pop()
            try {
                foreach ($eintrag in @($aktuell.EnumerateFileSystemInfos())) {
                    if (($eintrag.Attributes -band $verknuepfung) -ne 0) {
                        $links++
                    }
                    elseif ($eintrag -is [System.IO.DirectoryInfo]) {
                        $ordner.Add($eintrag)
                        $stapel.Push($eintrag)
                    }
                    else {
                        $dateien.Add($eintrag)
                    }
                }
            }
            catch {
                $fehler++
            }
        }
    }

    return [pscustomobject]@{
        Dateien = $dateien
        Ordner  = $ordner
        Links   = $links
        Fehler  = $fehler
    }
}

function Remove-Verzeichnisinhalt {
    # Löscht den Inhalt eines geprüften Zielordners (den Ordner selbst nie).
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Ziel)

    $bereich = $Ziel.Bereich

    $grund = Test-SicheresZiel -Pfad $Ziel.Pfad -Muster $Ziel.Muster
    if ($grund) {
        Write-Status ('  [übersprungen] {0}: {1}' -f $bereich, $grund)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes 0)
    }
    if ($Ziel.Art -eq 'Dateimuster' -and [string]::IsNullOrWhiteSpace($Ziel.Filter)) {
        Write-Status ('  [übersprungen] {0}: Dateimuster fehlt' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes 0)
    }

    $pfad = $Ziel.Pfad
    if (-not (Test-Path -LiteralPath $pfad -PathType Container)) {
        Write-Status ('  [nicht vorhanden] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'nicht vorhanden' -Bytes 0)
    }
    $wurzelInfo = Get-Item -LiteralPath $pfad -Force
    if (($wurzelInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-Status ('  [übersprungen] {0}: Zielordner ist eine Verknüpfung' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes 0)
    }

    $filter = $null
    if ($Ziel.Art -eq 'Dateimuster') { $filter = $Ziel.Filter }
    $inhalt = Get-ZielInhalt -Pfad $pfad -Filter $filter

    [long]$gesamtBytes = 0
    foreach ($datei in $inhalt.Dateien) {
        try { $gesamtBytes += $datei.Length }
        catch { $gesamtBytes += 0 }
    }
    $anzahl = $inhalt.Dateien.Count

    if ($anzahl -eq 0) {
        Write-Status ('  [leer] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'leer' -Bytes 0 -Uebersprungen $inhalt.Fehler)
    }

    $aktion = 'Inhalt löschen ({0} Dateien, {1})' -f $anzahl, (Format-Groesse -Bytes $gesamtBytes)
    if (-not $PSCmdlet.ShouldProcess($pfad, $aktion)) {
        if ($WhatIfPreference) {
            Write-Status ('  [Simulation] {0}: {1} Dateien, ca. {2} würden gelöscht' -f $bereich, $anzahl, (Format-Groesse -Bytes $gesamtBytes))
            return (Get-ErgebnisObjekt -Bereich $bereich -Status 'simuliert' -Dateien $anzahl -Bytes $gesamtBytes -Uebersprungen $inhalt.Fehler)
        }
        Write-Status ('  [abgelehnt] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'abgelehnt' -Bytes 0)
    }

    # Zusätzliche Absicherung: Jede Datei muss wirklich unter dem Zielordner liegen.
    $praefix = $pfad.TrimEnd('\') + '\'
    $vergleich = [System.StringComparison]::OrdinalIgnoreCase
    [long]$geloeschtBytes = 0
    $geloescht = 0
    $uebersprungen = 0

    foreach ($datei in $inhalt.Dateien) {
        if (-not $datei.FullName.StartsWith($praefix, $vergleich)) {
            $uebersprungen++
            continue
        }
        try {
            $groesse = $datei.Length
            Remove-Item -LiteralPath $datei.FullName -Force -Confirm:$false -ErrorAction Stop
            $geloescht++
            $geloeschtBytes += $groesse
        }
        catch {
            $uebersprungen++
        }
    }

    # Leere Unterordner von innen nach außen entfernen; nicht leere bleiben einfach stehen.
    for ($i = $inhalt.Ordner.Count - 1; $i -ge 0; $i--) {
        $ordnerPfad = $inhalt.Ordner[$i].FullName
        if (-not $ordnerPfad.StartsWith($praefix, $vergleich)) { continue }
        try {
            [System.IO.Directory]::Delete($ordnerPfad, $false)
        }
        catch {
            continue
        }
    }

    Write-Status ('  [bereinigt] {0}: {1} Dateien gelöscht ({2}), {3} übersprungen (gesperrt/kein Zugriff)' -f $bereich, $geloescht, (Format-Groesse -Bytes $geloeschtBytes), $uebersprungen)
    if ($inhalt.Links -gt 0) {
        Write-Status ('    Hinweis: {0} Verknüpfung(en) wurden bewusst nicht angefasst.' -f $inhalt.Links)
    }
    return (Get-ErgebnisObjekt -Bereich $bereich -Status 'bereinigt' -Dateien $geloescht -Bytes $geloeschtBytes -Uebersprungen ($uebersprungen + $inhalt.Fehler))
}

function Invoke-UpdateCacheBereinigung {
    # Hält die Update-Dienste an, leert den Download-Cache und startet die Dienste in jedem Fall wieder.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Ziel)

    $bereich = $Ziel.Bereich

    # Erst prüfen, dann Dienste anfassen.
    $grund = Test-SicheresZiel -Pfad $Ziel.Pfad -Muster $Ziel.Muster
    if ($grund) {
        Write-Status ('  [übersprungen] {0}: {1}' -f $bereich, $grund)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes 0)
    }
    if (-not (Test-Path -LiteralPath $Ziel.Pfad -PathType Container)) {
        Write-Status ('  [nicht vorhanden] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'nicht vorhanden' -Bytes 0)
    }

    $angehalten = New-Object -TypeName 'System.Collections.Generic.List[string]'
    try {
        foreach ($name in @('wuauserv', 'bits')) {
            $dienst = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $dienst -or $dienst.Status -ne 'Running') { continue }
            if ($PSCmdlet.ShouldProcess($name, 'Dienst vorübergehend anhalten')) {
                try {
                    Stop-Service -Name $name -ErrorAction Stop
                    $dienst.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30))
                    $angehalten.Add($name)
                }
                catch {
                    Write-Status ('  [übersprungen] {0}: Dienst {1} ließ sich nicht anhalten ({2})' -f $bereich, $name, $_.Exception.Message)
                    return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes 0)
                }
            }
        }
        return (Remove-Verzeichnisinhalt -Ziel $Ziel)
    }
    finally {
        # Reihenfolge umgekehrt wieder starten. -WhatIf/-Confirm bewusst abgeschaltet: Das Wiederherstellen ist Pflicht.
        for ($i = $angehalten.Count - 1; $i -ge 0; $i--) {
            try {
                Start-Service -Name $angehalten[$i] -WhatIf:$false -Confirm:$false -ErrorAction Stop
                Write-Status ('  Dienst {0} wurde wieder gestartet.' -f $angehalten[$i])
            }
            catch {
                Write-Warning ('Dienst {0} konnte nicht wieder gestartet werden: {1}' -f $angehalten[$i], $_.Exception.Message)
            }
        }
    }
}

function Clear-Papierkorb {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $bereich = 'Papierkorb'
    [long]$bytes = 0
    $anzahl = 0
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $papierkorb = $shell.Namespace(0xA)
        foreach ($element in $papierkorb.Items()) {
            $anzahl++
            try { $bytes += [long]$element.Size }
            catch { $bytes += 0 }
        }
    }
    catch {
        Write-Status ('  [übersprungen] {0}: Inhalt nicht lesbar ({1})' -f $bereich, $_.Exception.Message)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes $null)
    }
    finally {
        if ($null -ne $shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    if ($anzahl -eq 0) {
        Write-Status ('  [leer] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'leer' -Bytes 0)
    }

    $aktion = 'Leeren ({0} Elemente, ca. {1}, nicht wiederherstellbar)' -f $anzahl, (Format-Groesse -Bytes $bytes)
    if (-not $PSCmdlet.ShouldProcess('Papierkorb', $aktion)) {
        if ($WhatIfPreference) {
            Write-Status ('  [Simulation] {0}: {1} Elemente, ca. {2} würden gelöscht' -f $bereich, $anzahl, (Format-Groesse -Bytes $bytes))
            return (Get-ErgebnisObjekt -Bereich $bereich -Status 'simuliert' -Dateien $anzahl -Bytes $bytes)
        }
        Write-Status ('  [abgelehnt] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'abgelehnt' -Bytes 0)
    }

    try {
        Clear-RecycleBin -Force -Confirm:$false -ErrorAction Stop
        Write-Status ('  [bereinigt] {0}: {1} Elemente (ca. {2})' -f $bereich, $anzahl, (Format-Groesse -Bytes $bytes))
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'bereinigt' -Dateien $anzahl -Bytes $bytes)
    }
    catch {
        Write-Status ('  [Fehler] {0}: {1}' -f $bereich, $_.Exception.Message)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'Fehler' -Bytes 0)
    }
}

function Invoke-KomponentenBereinigung {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $bereich = 'Windows-Komponentenspeicher (DISM)'
    $dism = Join-ZielPfad -Basis (Join-ZielPfad -Basis $env:SystemRoot -Unterpfad 'System32') -Unterpfad 'Dism.exe'
    if (-not $dism -or -not (Test-Path -LiteralPath $dism -PathType Leaf)) {
        Write-Status ('  [übersprungen] {0}: Dism.exe nicht gefunden' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'übersprungen' -Bytes $null)
    }

    if (-not $PSCmdlet.ShouldProcess('Windows-Komponentenspeicher', 'DISM /StartComponentCleanup ausführen (kann mehrere Minuten dauern)')) {
        if ($WhatIfPreference) {
            Write-Status ('  [Simulation] {0}: würde ausgeführt, Platzgewinn nicht vorhersagbar' -f $bereich)
            return (Get-ErgebnisObjekt -Bereich $bereich -Status 'simuliert' -Bytes $null)
        }
        Write-Status ('  [abgelehnt] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'abgelehnt' -Bytes $null)
    }

    Write-Status ('  {0}: läuft, bitte warten ...' -f $bereich)
    & $dism /Online /Cleanup-Image /StartComponentCleanup | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Status ('  [bereinigt] {0}' -f $bereich)
        return (Get-ErgebnisObjekt -Bereich $bereich -Status 'bereinigt' -Bytes $null)
    }
    Write-Status ('  [Fehler] {0}: Dism.exe endete mit Code {1}' -f $bereich, $exitCode)
    return (Get-ErgebnisObjekt -Bereich $bereich -Status 'Fehler' -Bytes $null)
}

#endregion

#region Zieldefinition

function Get-CleanupZiel {
    # Die einzige Stelle, an der festgelegt wird, was gelöscht werden darf.
    [CmdletBinding()]
    param(
        [switch]$MitBrowser,
        [switch]$MitThumbnails
    )

    $ziele = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $lokal = $env:LOCALAPPDATA
    $windows = $env:SystemRoot

    $ziele.Add([pscustomobject]@{
            Bereich = 'Temp-Ordner des Benutzers'
            Art     = 'Ordner'
            Pfad    = Join-ZielPfad -Basis $lokal -Unterpfad 'Temp'
            Muster  = '^[A-Za-z]:\\.+\\AppData\\Local\\Temp$'
            Filter  = $null
            Admin   = $false
        })

    $ziele.Add([pscustomobject]@{
            Bereich = 'Windows-Temp-Ordner'
            Art     = 'Ordner'
            Pfad    = Join-ZielPfad -Basis $windows -Unterpfad 'Temp'
            Muster  = '^[A-Za-z]:\\Windows\\Temp$'
            Filter  = $null
            Admin   = $true
        })

    if ($MitBrowser) {
        $chromium = @(
            @{ Name = 'Microsoft Edge'; Basis = (Join-ZielPfad -Basis $lokal -Unterpfad 'Microsoft\Edge\User Data') }
            @{ Name = 'Google Chrome'; Basis = (Join-ZielPfad -Basis $lokal -Unterpfad 'Google\Chrome\User Data') }
        )
        foreach ($browser in $chromium) {
            if (-not $browser.Basis -or -not (Test-Path -LiteralPath $browser.Basis -PathType Container)) { continue }
            $profilListe = @(Get-ChildItem -LiteralPath $browser.Basis -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(Default|Profile \d+)$' })
            foreach ($profilOrdner in $profilListe) {
                foreach ($unter in @('Cache', 'Code Cache', 'GPUCache')) {
                    $ziele.Add([pscustomobject]@{
                            Bereich = ('{0} ({1}): {2}' -f $browser.Name, $profilOrdner.Name, $unter)
                            Art     = 'Ordner'
                            Pfad    = Join-Path -Path $profilOrdner.FullName -ChildPath $unter
                            Muster  = '^[A-Za-z]:\\.+\\AppData\\Local\\(Microsoft\\Edge|Google\\Chrome)\\User Data\\(Default|Profile \d+)\\(Cache|Code Cache|GPUCache)$'
                            Filter  = $null
                            Admin   = $false
                        })
                }
            }
        }

        # Firefox legt den Cache unter Local ab; Kennwörter, Cookies usw. liegen unter Roaming und werden nie angefasst.
        $firefoxBasis = Join-ZielPfad -Basis $lokal -Unterpfad 'Mozilla\Firefox\Profiles'
        if ($firefoxBasis -and (Test-Path -LiteralPath $firefoxBasis -PathType Container)) {
            $firefoxProfile = @(Get-ChildItem -LiteralPath $firefoxBasis -Directory -ErrorAction SilentlyContinue)
            $nummer = 0
            foreach ($profilOrdner in $firefoxProfile) {
                $nummer++
                $ziele.Add([pscustomobject]@{
                        Bereich = 'Mozilla Firefox (Profil {0}): cache2' -f $nummer
                        Art     = 'Ordner'
                        Pfad    = Join-Path -Path $profilOrdner.FullName -ChildPath 'cache2'
                        Muster  = '^[A-Za-z]:\\.+\\AppData\\Local\\Mozilla\\Firefox\\Profiles\\[^\\]+\\cache2$'
                        Filter  = $null
                        Admin   = $false
                    })
            }
        }
    }

    $ziele.Add([pscustomobject]@{
            Bereich = 'Windows-Update-Download-Cache'
            Art     = 'UpdateCache'
            Pfad    = Join-ZielPfad -Basis $windows -Unterpfad 'SoftwareDistribution\Download'
            Muster  = '^[A-Za-z]:\\Windows\\SoftwareDistribution\\Download$'
            Filter  = $null
            Admin   = $true
        })

    if ($MitThumbnails.IsPresent) {
        $ziele.Add([pscustomobject]@{
                Bereich = 'Miniaturansicht-Cache (thumbcache_*.db)'
                Art     = 'Dateimuster'
                Pfad    = Join-ZielPfad -Basis $lokal -Unterpfad 'Microsoft\Windows\Explorer'
                Muster  = '^[A-Za-z]:\\.+\\AppData\\Local\\Microsoft\\Windows\\Explorer$'
                Filter  = 'thumbcache_*.db'
                Admin   = $false
            })
    }

    return $ziele.ToArray()
}

#endregion

#region Ablauf

$script:IstAdmin = Test-Administrator

if ($LogPath) {
    $logVoll = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    $logOrdner = Split-Path -Path $logVoll -Parent
    if (-not (Test-Path -LiteralPath $logOrdner -PathType Container)) {
        throw "Der Ordner für die Protokolldatei existiert nicht: $logOrdner"
    }
    $script:LogDatei = $logVoll
}

$simulation = [bool]$WhatIfPreference
$modus = if ($simulation) { 'SIMULATION (-WhatIf): es wird nichts verändert' } else { 'ECHTLAUF' }
Write-Status ('Bereinigung gestartet - {0}' -f $modus)
Write-Status ('Administratorrechte: {0}' -f $(if ($script:IstAdmin) { 'ja' } else { 'nein (Windows-Temp, Update-Cache und DISM werden übersprungen)' }))

$browserLaufen = @(Get-Process -Name 'msedge', 'chrome', 'firefox' -ErrorAction SilentlyContinue)
if (-not $SkipBrowserCache -and $browserLaufen.Count -gt 0) {
    Write-Status 'Hinweis: Ein Browser läuft noch. Dessen gesperrte Cache-Dateien werden übersprungen; für ein vollständiges Ergebnis Browser schließen.'
}

$freiVorher = Get-FreierSpeicher
Write-Status ('Freier Speicher auf dem Systemlaufwerk vorher: {0}' -f (Format-Groesse -Bytes $freiVorher))

$ergebnisse = New-Object -TypeName 'System.Collections.Generic.List[object]'
$ziele = Get-CleanupZiel -MitBrowser:(-not $SkipBrowserCache) -MitThumbnails:$IncludeThumbnailCache

foreach ($ziel in $ziele) {
    if ($ziel.Admin -and -not $script:IstAdmin) {
        Write-Status ('  [übersprungen] {0}: Administratorrechte erforderlich' -f $ziel.Bereich)
        $ergebnisse.Add((Get-ErgebnisObjekt -Bereich $ziel.Bereich -Status 'übersprungen' -Bytes 0))
        continue
    }
    if ($ziel.Art -eq 'UpdateCache') {
        $ergebnisse.Add((Invoke-UpdateCacheBereinigung -Ziel $ziel))
    }
    else {
        $ergebnisse.Add((Remove-Verzeichnisinhalt -Ziel $ziel))
    }
}

if ($IncludeRecycleBin) {
    $ergebnisse.Add((Clear-Papierkorb))
}

if ($IncludeComponentCleanup) {
    if ($script:IstAdmin) {
        $ergebnisse.Add((Invoke-KomponentenBereinigung))
    }
    else {
        Write-Status '  [übersprungen] Windows-Komponentenspeicher (DISM): Administratorrechte erforderlich'
        $ergebnisse.Add((Get-ErgebnisObjekt -Bereich 'Windows-Komponentenspeicher (DISM)' -Status 'übersprungen' -Bytes $null))
    }
}

# Zusammenfassung
[long]$summeBytes = 0
$summeDateien = 0
$summeUebersprungen = 0
foreach ($ergebnis in $ergebnisse) {
    if ($ergebnis.Status -in @('bereinigt', 'simuliert')) {
        if ($null -ne $ergebnis.Bytes) { $summeBytes += [long]$ergebnis.Bytes }
        $summeDateien += $ergebnis.Dateien
    }
    $summeUebersprungen += $ergebnis.Uebersprungen
}

Write-Status ''
if ($simulation) {
    Write-Status ('Ergebnis der Simulation: {0} Dateien/Elemente, geschätzt {1} könnten freigegeben werden.' -f $summeDateien, (Format-Groesse -Bytes $summeBytes))
    Write-Status ('Freier Speicher auf dem Systemlaufwerk: {0} (unverändert, es wurde nichts gelöscht)' -f (Format-Groesse -Bytes $freiVorher))
}
else {
    $freiNachher = Get-FreierSpeicher
    Write-Status ('Gelöscht: {0} Dateien/Elemente, Summe der Dateigrößen {1}; {2} übersprungen.' -f $summeDateien, (Format-Groesse -Bytes $summeBytes), $summeUebersprungen)
    Write-Status ('Freier Speicher auf dem Systemlaufwerk nachher: {0}' -f (Format-Groesse -Bytes $freiNachher))
    if ($null -ne $freiVorher -and $null -ne $freiNachher) {
        $differenz = $freiNachher - $freiVorher
        if ($differenz -ge 0) {
            Write-Status ('Tatsächlich gewonnen: {0} (kann von der Dateigrößen-Summe abweichen)' -f (Format-Groesse -Bytes $differenz))
        }
        else {
            Write-Status ('Freier Speicher ist um {0} gesunken (Windows hat währenddessen selbst Speicher belegt).' -f (Format-Groesse -Bytes (-$differenz)))
        }
    }
}
if ($script:LogDatei) { Write-Status ('Protokoll: {0}' -f $script:LogDatei) }

if ($PassThru) {
    $ergebnisse.ToArray()
}

#endregion
