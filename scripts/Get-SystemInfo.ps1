<#
.SYNOPSIS
    Erstellt eine Systemübersicht für Tickets und Inventar.

.DESCRIPTION
    Sammelt die wichtigsten Systemdaten über CIM (Get-CimInstance, kein WMIC):
    Computername, Betriebssystem mit Version/Build, letzter Start und Laufzeit,
    Prozessor, Arbeitsspeicher, Datenträger, Netzwerkadapter (IPv4, Gateway, DNS, MAC),
    BIOS/Seriennummer, Hersteller/Modell, angemeldeter Benutzer, ausstehender Neustart,
    zuletzt installierte Windows-Updates (Get-HotFix) und den Defender-Status.

    Das Skript liest nur und verändert nichts am System. Administratorrechte sind nicht
    nötig. Einzelne Abfragen, die fehlschlagen oder mehr Rechte brauchen, werden mit einem
    Hinweis übersprungen; der Rest des Berichts wird trotzdem erstellt.

    Die Ausgabe erscheint als lesbarer Text in der Konsole. Mit -ExportPath wird der Bericht
    zusätzlich als .txt, .json oder .html gespeichert (das Format richtet sich nach der
    Dateiendung).

.PARAMETER ExportPath
    Zieldatei für den Export. Erlaubte Endungen: .txt, .json, .html (auch .htm).
    Der Zielordner muss existieren. Eine vorhandene Datei wird überschrieben.

.PARAMETER Anonymize
    Blendet Seriennummer, MAC-Adressen, Benutzernamen, Computernamen und (bei
    Domänenmitgliedschaft) den Domänennamen aus. Andere Angaben wie IP-Adressen,
    Hersteller und Modell bleiben sichtbar. Vor dem Weitergeben eines Berichts
    bitte trotzdem kurz selbst prüfen.

.PARAMETER PassThru
    Gibt statt des Textberichts das Berichtsobjekt (geordnete Hashtabelle) zurück,
    z. B. zur Weiterverarbeitung in anderen Skripten.

.EXAMPLE
    .\Get-SystemInfo.ps1

    Zeigt die Systemübersicht in der Konsole.

.EXAMPLE
    .\Get-SystemInfo.ps1 -Anonymize -ExportPath "$env:TEMP\systeminfo.html"

    Erstellt einen anonymisierten HTML-Bericht im Temp-Ordner.

.EXAMPLE
    .\Get-SystemInfo.ps1 -ExportPath .\bericht.json -WhatIf

    Zeigt nur an, welche Datei geschrieben würde.

.INPUTS
    Keine.

.OUTPUTS
    System.String (Textbericht) oder, mit -PassThru, System.Collections.Specialized.OrderedDictionary.

.NOTES
    Getestet mit Windows PowerShell 5.1. Vorgesehen für Windows PowerShell 5.1 und PowerShell 7.
    Der Bericht enthält personenbezogene und sicherheitsrelevante Angaben (ohne -Anonymize).
    Bitte nicht ungeprüft in öffentliche Tickets oder Foren einstellen.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$ExportPath,

    [switch]$Anonymize,

    [switch]$PassThru
)

$InformationPreference = 'Continue'
$script:Hinweise = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:Ausgeblendet = '[ausgeblendet]'
$script:Kultur = [System.Globalization.CultureInfo]::InvariantCulture

#region Hilfsfunktionen

function Test-Administrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identitaet = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $prinzipal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identitaet
    return $prinzipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Erfassung {
    # Führt eine Abfrage aus. Bei einem Fehler wird ein Hinweis gesammelt und $null geliefert.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Bezeichnung,
        [Parameter(Mandatory)][scriptblock]$Aktion
    )
    try {
        & $Aktion
    }
    catch {
        $grund = $_.Exception.Message.Trim()
        if (-not $script:IstAdmin) {
            $grund += ' (evtl. sind Administratorrechte nötig)'
        }
        $script:Hinweise.Add(('{0}: übersprungen - {1}' -f $Bezeichnung, $grund))
        return $null
    }
}

function Get-MaskierterWert {
    [CmdletBinding()]
    [OutputType([string], [object])]
    param($Wert)
    if ($Anonymize) { return $script:Ausgeblendet }
    return $Wert
}

function Format-Datum {
    [CmdletBinding()]
    [OutputType([string])]
    param($Datum)
    if ($null -eq $Datum) { return $null }
    try {
        return ([datetime]$Datum).ToString('dd.MM.yyyy HH:mm', $script:Kultur)
    }
    catch {
        return [string]$Datum
    }
}

function Get-IPv4Adresse {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($Adresse)
    return @($Adresse | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
}

#endregion

#region Datenerfassung

function Get-NeustartStatus {
    [CmdletBinding()]
    param()
    $gruende = New-Object -TypeName 'System.Collections.Generic.List[string]'

    $pruefungen = @(
        @{ Pfad = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Grund = 'Komponentenwartung (CBS) verlangt Neustart' }
        @{ Pfad = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Grund = 'Windows Update verlangt Neustart' }
    )
    foreach ($pruefung in $pruefungen) {
        if (Test-Path -LiteralPath $pruefung.Pfad) { $gruende.Add($pruefung.Grund) }
    }

    $sitzung = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    if ($sitzung.PSObject.Properties.Name -contains 'PendingFileRenameOperations') {
        $gruende.Add('Ausstehende Datei-Umbenennungen (PendingFileRenameOperations)')
    }

    $aktiv = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
    $neu = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
    if ($aktiv -ne $neu) { $gruende.Add('Computername wurde geändert') }

    $ergebnis = [ordered]@{
        'Neustart ausstehend' = ($gruende.Count -gt 0)
        'Gründe'              = if ($gruende.Count -gt 0) { $gruende.ToArray() } else { @() }
    }
    return $ergebnis
}

function Get-DefenderStatus {
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name 'Get-MpComputerStatus' -ErrorAction SilentlyContinue)) {
        throw 'Das Defender-Modul ist auf diesem System nicht verfügbar.'
    }
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $ergebnis = [ordered]@{
        'Antivirus aktiv'            = $mp.AntivirusEnabled
        'Echtzeitschutz aktiv'       = $mp.RealTimeProtectionEnabled
        'Manipulationsschutz'        = $mp.IsTamperProtected
        'Signaturversion'            = $mp.AntivirusSignatureVersion
        'Signaturen aktualisiert am' = Format-Datum -Datum $mp.AntivirusSignatureLastUpdated
    }
    return $ergebnis
}

$script:IstAdmin = Test-Administrator

# Exportziel vorab prüfen, damit nicht erst nach der Erfassung ein Fehler auftritt.
$exportFormat = $null
$exportVollpfad = $null
if ($ExportPath) {
    $endung = [System.IO.Path]::GetExtension($ExportPath).ToLowerInvariant()
    switch ($endung) {
        '.txt'  { $exportFormat = 'txt' }
        '.json' { $exportFormat = 'json' }
        '.html' { $exportFormat = 'html' }
        '.htm'  { $exportFormat = 'html' }
        default { throw "Nicht unterstützte Dateiendung '$endung'. Erlaubt sind .txt, .json und .html." }
    }
    $exportVollpfad = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExportPath)
    $exportOrdner = Split-Path -Path $exportVollpfad -Parent
    if (-not (Test-Path -LiteralPath $exportOrdner -PathType Container)) {
        throw "Der Zielordner '$exportOrdner' existiert nicht."
    }
}

Write-Information 'Sammle Systemdaten ...'

$cs = Invoke-Erfassung -Bezeichnung 'Computersystem' -Aktion { Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
$os = Invoke-Erfassung -Bezeichnung 'Betriebssystem' -Aktion { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
$bios = Invoke-Erfassung -Bezeichnung 'BIOS' -Aktion { Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop }
$cpu = Invoke-Erfassung -Bezeichnung 'Prozessor' -Aktion { @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) }
$laufwerke = Invoke-Erfassung -Bezeichnung 'Datenträger' -Aktion { @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop) }
$netzKonfig = Invoke-Erfassung -Bezeichnung 'Netzwerk (Konfiguration)' -Aktion { @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction Stop) }
$netzAdapter = Invoke-Erfassung -Bezeichnung 'Netzwerk (Adapter)' -Aktion { @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop) }
$windowsVersion = Invoke-Erfassung -Bezeichnung 'Windows-Version (Registry)' -Aktion {
    Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
}
$neustart = Invoke-Erfassung -Bezeichnung 'Ausstehender Neustart' -Aktion { Get-NeustartStatus }
$hotfixe = Invoke-Erfassung -Bezeichnung 'Windows-Updates (Get-HotFix)' -Aktion { @(Get-HotFix -ErrorAction Stop) }
$defender = Invoke-Erfassung -Bezeichnung 'Defender-Status' -Aktion { Get-DefenderStatus }
$virenschutz = Invoke-Erfassung -Bezeichnung 'Registrierte Virenschutzprodukte' -Aktion {
    @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
}

#endregion

#region Bericht zusammenbauen

$bericht = [ordered]@{}

$bericht['Berichtsinfo'] = [ordered]@{
    'Erstellt am'                  = Format-Datum -Datum (Get-Date)
    'PowerShell-Version'           = $PSVersionTable.PSVersion.ToString()
    'Als Administrator ausgeführt' = $script:IstAdmin
    'Anonymisiert'                 = [bool]$Anonymize
}

$allgemein = [ordered]@{}
$allgemein['Computername'] = Get-MaskierterWert -Wert $cs.Name
if ($cs.PartOfDomain) {
    $allgemein['Domäne'] = Get-MaskierterWert -Wert $cs.Domain
}
else {
    $allgemein['Arbeitsgruppe'] = $cs.Domain
}
$allgemein['Hersteller'] = $cs.Manufacturer
$allgemein['Modell'] = $cs.Model
$allgemein['Seriennummer'] = Get-MaskierterWert -Wert $bios.SerialNumber
$allgemein['BIOS-Version'] = $bios.SMBIOSBIOSVersion
$allgemein['BIOS-Datum'] = Format-Datum -Datum $bios.ReleaseDate
$allgemein['Angemeldeter Benutzer (Konsole)'] = Get-MaskierterWert -Wert $cs.UserName
$allgemein['Skript ausgeführt als'] = Get-MaskierterWert -Wert ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
$bericht['Allgemein'] = $allgemein

$betriebssystem = [ordered]@{}
$betriebssystem['Name'] = $os.Caption
$betriebssystem['Version'] = $windowsVersion.DisplayVersion
$betriebssystem['Build'] = if ($null -ne $windowsVersion.UBR) { '{0}.{1}' -f $os.BuildNumber, $windowsVersion.UBR } else { $os.BuildNumber }
$betriebssystem['Architektur'] = $os.OSArchitecture
$betriebssystem['Installiert am'] = Format-Datum -Datum $os.InstallDate
$betriebssystem['Letzter Start'] = Format-Datum -Datum $os.LastBootUpTime
if ($os.LastBootUpTime) {
    $laufzeit = (Get-Date) - $os.LastBootUpTime
    $betriebssystem['Laufzeit seit Start'] = '{0} Tage, {1} Std., {2} Min.' -f [int]$laufzeit.Days, $laufzeit.Hours, $laufzeit.Minutes
}
$bericht['Betriebssystem'] = $betriebssystem

$prozessor = [ordered]@{}
if ($cpu) {
    $prozessor['Name'] = ($cpu[0].Name -replace '\s+', ' ').Trim()
    $prozessor['Sockel'] = $cpu.Count
    $prozessor['Kerne'] = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    $prozessor['Logische Prozessoren'] = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $prozessor['Maximaler Takt (MHz)'] = $cpu[0].MaxClockSpeed
}
$bericht['Prozessor'] = $prozessor

$ram = [ordered]@{}
if ($os -and $cs) {
    $gesamtKB = [double]$os.TotalVisibleMemorySize
    $freiKB = [double]$os.FreePhysicalMemory
    $ram['Installiert (GB)'] = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $ram['Für Windows nutzbar (GB)'] = [math]::Round($gesamtKB / 1MB, 1)
    $ram['Frei (GB)'] = [math]::Round($freiKB / 1MB, 1)
    if ($gesamtKB -gt 0) {
        $ram['Belegt (%)'] = [math]::Round(100 * ($gesamtKB - $freiKB) / $gesamtKB, 0)
    }
}
$bericht['Arbeitsspeicher'] = $ram

$datentraeger = @()
foreach ($lw in $laufwerke) {
    $eintrag = [ordered]@{
        'Laufwerk'     = $lw.DeviceID
        'Dateisystem'  = $lw.FileSystem
        'Größe (GB)'   = [math]::Round($lw.Size / 1GB, 1)
        'Frei (GB)'    = [math]::Round($lw.FreeSpace / 1GB, 1)
    }
    if ($lw.Size -gt 0) {
        $prozentFrei = [math]::Round(100 * $lw.FreeSpace / $lw.Size, 0)
        $eintrag['Frei (%)'] = $prozentFrei
        if ($prozentFrei -lt 10) {
            $script:Hinweise.Add(('Laufwerk {0} hat nur noch {1} % freien Speicher.' -f $lw.DeviceID, $prozentFrei))
        }
    }
    $datentraeger += $eintrag
}
$bericht['Datenträger'] = $datentraeger

$netzwerk = @()
foreach ($konfig in $netzKonfig) {
    $adapter = $netzAdapter | Where-Object { $_.InterfaceIndex -eq $konfig.InterfaceIndex } | Select-Object -First 1
    $name = if ($adapter -and $adapter.NetConnectionID) { $adapter.NetConnectionID } else { $konfig.Description }
    $netzwerk += [ordered]@{
        'Name'         = $name
        'Beschreibung' = $konfig.Description
        'IPv4-Adresse' = @(Get-IPv4Adresse -Adresse $konfig.IPAddress)
        'Gateway'      = @(Get-IPv4Adresse -Adresse $konfig.DefaultIPGateway)
        'DNS-Server'   = @(Get-IPv4Adresse -Adresse $konfig.DNSServerSearchOrder)
        'DHCP aktiv'   = [bool]$konfig.DHCPEnabled
        'MAC-Adresse'  = Get-MaskierterWert -Wert $konfig.MACAddress
    }
}
$bericht['Netzwerk'] = $netzwerk

$bericht['Neustart ausstehend'] = if ($neustart) { $neustart } else { [ordered]@{ 'Status' = 'nicht ermittelt' } }

$updates = @()
if ($hotfixe) {
    $sortiert = $hotfixe | Sort-Object -Property @{ Expression = { if ($_.InstalledOn -as [datetime]) { [datetime]$_.InstalledOn } else { [datetime]::MinValue } } } -Descending
    foreach ($fix in ($sortiert | Select-Object -First 5)) {
        $updates += [ordered]@{
            'Update'         = $fix.HotFixID
            'Beschreibung'   = $fix.Description
            'Installiert am' = if ($fix.InstalledOn -as [datetime]) { Format-Datum -Datum $fix.InstalledOn } else { $null }
        }
    }
}
$bericht['Windows-Updates (letzte 5 laut Get-HotFix)'] = $updates

$schutz = [ordered]@{}
if ($virenschutz) { $schutz['Registrierte Produkte'] = @($virenschutz) }
if ($defender) { foreach ($schluessel in $defender.Keys) { $schutz[$schluessel] = $defender[$schluessel] } }
if ($schutz.Count -eq 0) { $schutz['Status'] = 'nicht ermittelt' }
$bericht['Virenschutz'] = $schutz

$script:Hinweise.Add('Get-HotFix zeigt nicht alle Updates (z. B. keine Defender-Signaturen, nicht jedes Feature-Update).')
$script:Hinweise.Add('"Ausstehende Datei-Umbenennungen" kann auch ohne echten Neustartbedarf auftreten (z. B. nach Installationen).')
$bericht['Hinweise'] = $script:Hinweise.ToArray()

#endregion

#region Ausgabe

function Format-Wert {
    [CmdletBinding()]
    [OutputType([string])]
    param($Wert)
    if ($null -eq $Wert) { return '-' }
    if ($Wert -is [bool]) { if ($Wert) { return 'Ja' } else { return 'Nein' } }
    if ($Wert -is [string]) { if ($Wert.Trim().Length -eq 0) { return '-' } else { return $Wert } }
    if ($Wert -is [System.Collections.IEnumerable]) {
        $teile = @($Wert | ForEach-Object { Format-Wert -Wert $_ })
        if ($teile.Count -eq 0) { return '-' }
        return ($teile -join ', ')
    }
    if ($Wert -is [System.IFormattable]) { return $Wert.ToString($null, [System.Globalization.CultureInfo]::CurrentCulture) }
    return [string]$Wert
}

function ConvertTo-TextBericht {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bericht)

    $zeilen = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $zeilen.Add('SYSTEMÜBERSICHT')
    $zeilen.Add('===============')

    foreach ($abschnitt in $Bericht.Keys) {
        $zeilen.Add('')
        $zeilen.Add($abschnitt)
        $zeilen.Add('-' * $abschnitt.Length)
        $inhalt = $Bericht[$abschnitt]

        if ($inhalt -is [System.Collections.IDictionary]) {
            $eintraege = @($inhalt)
        }
        else {
            $eintraege = @($inhalt)
            if ($eintraege.Count -eq 0) { $zeilen.Add('  (keine Daten)') }
        }

        $erster = $true
        foreach ($eintrag in $eintraege) {
            if ($eintrag -is [System.Collections.IDictionary]) {
                if (-not $erster -and $eintraege.Count -gt 1) { $zeilen.Add('') }
                $breite = ($eintrag.Keys | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum
                foreach ($schluessel in $eintrag.Keys) {
                    $zeilen.Add(('  {0} : {1}' -f ([string]$schluessel).PadRight($breite), (Format-Wert -Wert $eintrag[$schluessel])))
                }
            }
            else {
                $zeilen.Add(('  - {0}' -f (Format-Wert -Wert $eintrag)))
            }
            $erster = $false
        }
    }
    return $zeilen.ToArray()
}

function ConvertTo-HtmlBericht {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bericht)

    $kodiere = { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }
    $html = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $html.Add('<!DOCTYPE html>')
    $html.Add('<html lang="de"><head><meta charset="utf-8">')
    $html.Add('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $html.Add('<title>Systemübersicht</title>')
    $html.Add('<style>')
    $html.Add('body{font-family:Segoe UI,Arial,sans-serif;margin:2rem auto;max-width:60rem;padding:0 1rem;color:#1b1b1b;background:#fff}')
    $html.Add('h1{font-size:1.6rem}h2{font-size:1.15rem;margin-top:1.8rem;border-bottom:2px solid #0b5cad;padding-bottom:.2rem}')
    $html.Add('table{border-collapse:collapse;width:100%;margin:.4rem 0 1rem}th,td{text-align:left;padding:.3rem .6rem;border-bottom:1px solid #ddd;vertical-align:top}')
    $html.Add('th{width:16rem;font-weight:600;background:#f3f6fa}ul{margin:.3rem 0}')
    $html.Add('</style></head><body>')
    $html.Add('<h1>Systemübersicht</h1>')

    foreach ($abschnitt in $Bericht.Keys) {
        $html.Add(('<h2>{0}</h2>' -f (& $kodiere $abschnitt)))
        $inhalt = $Bericht[$abschnitt]
        $eintraege = @($inhalt)
        if ($inhalt -isnot [System.Collections.IDictionary] -and $eintraege.Count -eq 0) {
            $html.Add('<p><em>(keine Daten)</em></p>')
            continue
        }
        $skalare = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($eintrag in $eintraege) {
            if ($eintrag -is [System.Collections.IDictionary]) {
                $html.Add('<table>')
                foreach ($schluessel in $eintrag.Keys) {
                    $html.Add(('<tr><th>{0}</th><td>{1}</td></tr>' -f (& $kodiere $schluessel), (& $kodiere (Format-Wert -Wert $eintrag[$schluessel]))))
                }
                $html.Add('</table>')
            }
            else {
                $skalare.Add((& $kodiere (Format-Wert -Wert $eintrag)))
            }
        }
        if ($skalare.Count -gt 0) {
            $html.Add('<ul>')
            foreach ($text in $skalare) { $html.Add(('<li>{0}</li>' -f $text)) }
            $html.Add('</ul>')
        }
    }
    $html.Add('</body></html>')
    return ($html -join [Environment]::NewLine)
}

$textZeilen = ConvertTo-TextBericht -Bericht $bericht

if ($exportFormat) {
    switch ($exportFormat) {
        'txt'  { $inhalt = $textZeilen -join [Environment]::NewLine }
        'json' { $inhalt = $bericht | ConvertTo-Json -Depth 6 }
        'html' { $inhalt = ConvertTo-HtmlBericht -Bericht $bericht }
    }
    if ($PSCmdlet.ShouldProcess($exportVollpfad, 'Bericht schreiben')) {
        try {
            Set-Content -LiteralPath $exportVollpfad -Value $inhalt -Encoding UTF8 -ErrorAction Stop
            Write-Information "Bericht gespeichert: $exportVollpfad"
        }
        catch {
            throw "Der Bericht konnte nicht gespeichert werden: $($_.Exception.Message)"
        }
    }
}

if ($PassThru) {
    $bericht
}
else {
    $textZeilen
}

#endregion
