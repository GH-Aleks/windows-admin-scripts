<#
.SYNOPSIS
    Erste Netzwerk-Diagnose bei "kein Internet": Gateway, DNS, Internet, Namensauflösung und Port 443.

.DESCRIPTION
    Prüft der Reihe nach und zeigt je Schritt OK / FEHLER / ÜBERSPRUNGEN mit einer kurzen Deutung:

      1. Aktive Netzwerkverbindung mit IPv4-Adresse und Standardgateway
      2. Ping zum Standardgateway
      3. Ping zu den konfigurierten DNS-Servern
      4. Ping zu einer Internetadresse (Standard: 1.1.1.1, ohne DNS)
      5. Namensauflösung (Standard: www.microsoft.com)
      6. TCP-Verbindung zu einem Host auf Port 443 (Standard: www.microsoft.com)

    Daraus ergibt sich eine Einordnung, z. B. "Gateway erreichbar, aber kein Internet" oder
    "Internet erreichbar, aber DNS defekt". Das Skript verändert nichts am System und
    benötigt keine Administratorrechte. Ohne Internet bleiben Ping-Ergebnisse naturgemäß
    negativ; manche Netze blockieren ICMP (Ping), obwohl Internetverkehr funktioniert.
    Deshalb wird zusätzlich der TCP-Test auf Port 443 ausgewertet.

.PARAMETER InternetAddress
    IP-Adresse für den Internet-Ping (ohne DNS). Standard: 1.1.1.1

.PARAMETER DnsTestName
    Hostname für den Namensauflösungs-Test. Standard: www.microsoft.com

.PARAMETER TcpTestHost
    Hostname für den TCP-Test auf Port 443. Standard: www.microsoft.com

.PARAMETER PingCount
    Anzahl der Ping-Versuche je Ziel (1 bis 10). Standard: 2

.PARAMETER TimeoutMs
    Wartezeit je Ping in Millisekunden (200 bis 10000). Standard: 1500

.PARAMETER PassThru
    Gibt zusätzlich die Prüfergebnisse als Objekte zurück.

.EXAMPLE
    .\Test-NetworkBasics.ps1

    Führt alle Prüfungen mit den Standardzielen aus.

.EXAMPLE
    .\Test-NetworkBasics.ps1 -TcpTestHost "example.com" -PingCount 4 -PassThru | Format-Table

    Testet Port 443 von example.com, sendet vier Pings je Ziel und gibt die Ergebnisse als Tabelle aus.

.INPUTS
    Keine.

.OUTPUTS
    Keine; mit -PassThru ein Objekt je Prüfung (Pruefung, Ziel, Ergebnis, Detail).

.NOTES
    Getestet mit Windows PowerShell 5.1. Vorgesehen für Windows PowerShell 5.1 und PowerShell 7.
    Verwendet .NET (System.Net.NetworkInformation.Ping, Dns, TcpClient), damit keine
    zusätzlichen Module nötig sind.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$InternetAddress = '1.1.1.1',

    [ValidateNotNullOrEmpty()]
    [string]$DnsTestName = 'www.microsoft.com',

    [ValidateNotNullOrEmpty()]
    [string]$TcpTestHost = 'www.microsoft.com',

    [ValidateRange(1, 10)]
    [int]$PingCount = 2,

    [ValidateRange(200, 10000)]
    [int]$TimeoutMs = 1500,

    [switch]$PassThru
)

$InformationPreference = 'Continue'
$script:Ergebnisse = New-Object -TypeName 'System.Collections.Generic.List[object]'

function Add-Pruefung {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pruefung,
        [Parameter(Mandatory)][string]$Ziel,
        [Parameter(Mandatory)][ValidateSet('OK', 'FEHLER', 'ÜBERSPRUNGEN')][string]$Ergebnis,
        [string]$Detail = ''
    )
    $script:Ergebnisse.Add([pscustomobject]@{
            Pruefung = $Pruefung
            Ziel     = $Ziel
            Ergebnis = $Ergebnis
            Detail   = $Detail
        })
    $zeile = '[{0,-13}] {1}: {2}' -f $Ergebnis, $Pruefung, $Ziel
    if ($Detail) { $zeile = '{0} ({1})' -f $zeile, $Detail }
    Write-Information -MessageData $zeile
}

function Test-Ping {
    # Gibt die Anzahl erfolgreicher Antworten und die mittlere Antwortzeit zurück.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ziel,
        [Parameter(Mandatory)][int]$Versuche,
        [Parameter(Mandatory)][int]$Wartezeit
    )

    $ping = New-Object -TypeName System.Net.NetworkInformation.Ping
    $erfolge = 0
    $zeiten = New-Object -TypeName 'System.Collections.Generic.List[long]'
    try {
        for ($i = 0; $i -lt $Versuche; $i++) {
            try {
                $antwort = $ping.Send($Ziel, $Wartezeit)
                if ($antwort.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $erfolge++
                    $zeiten.Add($antwort.RoundtripTime)
                }
            }
            catch {
                continue
            }
        }
    }
    finally {
        $ping.Dispose()
    }
    $mittel = $null
    if ($zeiten.Count -gt 0) { $mittel = [math]::Round((($zeiten | Measure-Object -Average).Average), 0) }
    return [pscustomobject]@{ Erfolge = $erfolge; Versuche = $Versuche; Mittel = $mittel }
}

function Invoke-PingPruefung {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Pruefung,
        [Parameter(Mandatory)][string]$Ziel,
        [Parameter(Mandatory)][int]$Versuche,
        [Parameter(Mandatory)][int]$Wartezeit
    )
    $ergebnis = Test-Ping -Ziel $Ziel -Versuche $Versuche -Wartezeit $Wartezeit
    if ($ergebnis.Erfolge -gt 0) {
        $detail = '{0} von {1} Antworten, ca. {2} ms' -f $ergebnis.Erfolge, $ergebnis.Versuche, $ergebnis.Mittel
        Add-Pruefung -Pruefung $Pruefung -Ziel $Ziel -Ergebnis 'OK' -Detail $detail
        return $true
    }
    Add-Pruefung -Pruefung $Pruefung -Ziel $Ziel -Ergebnis 'FEHLER' -Detail ('keine Antwort auf {0} Versuche' -f $ergebnis.Versuche)
    return $false
}

Write-Information -MessageData 'Netzwerk-Kurzdiagnose'
Write-Information -MessageData ''

# 1. Aktive Verbindung, Gateway, DNS
$gateways = @()
$dnsServer = @()
$konfiguration = $null
try {
    $konfiguration = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction Stop |
            Where-Object { $_.DefaultIPGateway })
}
catch {
    Add-Pruefung -Pruefung 'Netzwerkkonfiguration' -Ziel 'lokal' -Ergebnis 'FEHLER' -Detail $_.Exception.Message
}

if ($null -ne $konfiguration -and $konfiguration.Count -gt 0) {
    foreach ($adapter in $konfiguration) {
        $v4 = @($adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
        $gateways += @($adapter.DefaultIPGateway | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
        $dnsServer += @($adapter.DNSServerSearchOrder | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
        $detail = 'IPv4 {0}, Gateway {1}' -f ($v4 -join ', '), (@($adapter.DefaultIPGateway) -join ', ')
        Add-Pruefung -Pruefung 'Netzwerkkonfiguration' -Ziel $adapter.Description -Ergebnis 'OK' -Detail $detail
    }
}
elseif ($null -ne $konfiguration) {
    Add-Pruefung -Pruefung 'Netzwerkkonfiguration' -Ziel 'lokal' -Ergebnis 'FEHLER' -Detail 'keine aktive Verbindung mit Standardgateway (Kabel/WLAN/Adapter prüfen)'
}
$gateways = @($gateways | Select-Object -Unique)
$dnsServer = @($dnsServer | Select-Object -Unique)

# 2. Gateway
$gatewayOk = $false
if ($gateways.Count -gt 0) {
    foreach ($gateway in $gateways) {
        if (Invoke-PingPruefung -Pruefung 'Ping Gateway' -Ziel $gateway -Versuche $PingCount -Wartezeit $TimeoutMs) { $gatewayOk = $true }
    }
}
else {
    Add-Pruefung -Pruefung 'Ping Gateway' -Ziel '-' -Ergebnis 'ÜBERSPRUNGEN' -Detail 'kein Gateway bekannt'
}

# 3. DNS-Server (Ping)
if ($dnsServer.Count -gt 0) {
    foreach ($server in $dnsServer) {
        $null = Invoke-PingPruefung -Pruefung 'Ping DNS-Server' -Ziel $server -Versuche $PingCount -Wartezeit $TimeoutMs
    }
}
else {
    Add-Pruefung -Pruefung 'Ping DNS-Server' -Ziel '-' -Ergebnis 'ÜBERSPRUNGEN' -Detail 'kein DNS-Server konfiguriert'
}

# 4. Internet per IP
$internetPingOk = Invoke-PingPruefung -Pruefung 'Ping Internet (ohne DNS)' -Ziel $InternetAddress -Versuche $PingCount -Wartezeit $TimeoutMs

# 5. Namensauflösung
$dnsOk = $false
try {
    $adressen = @([System.Net.Dns]::GetHostAddresses($DnsTestName))
    if ($adressen.Count -gt 0) {
        $dnsOk = $true
        $erste = ($adressen | Select-Object -First 2 | ForEach-Object { $_.IPAddressToString }) -join ', '
        Add-Pruefung -Pruefung 'Namensauflösung' -Ziel $DnsTestName -Ergebnis 'OK' -Detail $erste
    }
    else {
        Add-Pruefung -Pruefung 'Namensauflösung' -Ziel $DnsTestName -Ergebnis 'FEHLER' -Detail 'keine Adresse geliefert'
    }
}
catch {
    Add-Pruefung -Pruefung 'Namensauflösung' -Ziel $DnsTestName -Ergebnis 'FEHLER' -Detail $_.Exception.Message
}

# 6. TCP 443
$tcpOk = $false
$klient = New-Object -TypeName System.Net.Sockets.TcpClient
try {
    $aufgabe = $klient.ConnectAsync($TcpTestHost, 443)
    if ($aufgabe.Wait(5000) -and $klient.Connected) {
        $tcpOk = $true
        Add-Pruefung -Pruefung 'TCP-Verbindung Port 443' -Ziel $TcpTestHost -Ergebnis 'OK'
    }
    else {
        Add-Pruefung -Pruefung 'TCP-Verbindung Port 443' -Ziel $TcpTestHost -Ergebnis 'FEHLER' -Detail 'Zeitüberschreitung nach 5 s (Firewall/Proxy?)'
    }
}
catch {
    $meldung = $_.Exception.Message
    if ($_.Exception.InnerException) { $meldung = $_.Exception.InnerException.Message }
    Add-Pruefung -Pruefung 'TCP-Verbindung Port 443' -Ziel $TcpTestHost -Ergebnis 'FEHLER' -Detail $meldung
}
finally {
    $klient.Close()
}

# Einordnung
Write-Information -MessageData ''
Write-Information -MessageData 'Einordnung:'
if ($null -ne $konfiguration -and $konfiguration.Count -eq 0) {
    Write-Information -MessageData '  Keine aktive Netzwerkverbindung mit Gateway: Kabel, WLAN, Flugmodus und Adapter prüfen (lokales Problem).'
}
elseif ($gateways.Count -gt 0 -and -not $gatewayOk) {
    Write-Information -MessageData '  Gateway antwortet nicht auf Ping: Verbindung zum Router prüfen (Kabel, WLAN-Signal, Router-Neustart). Manche Router blockieren Ping, dann Folgetests beachten.'
}
elseif ($internetPingOk -and $tcpOk -and $dnsOk) {
    Write-Information -MessageData '  Netzwerk, Internet und Namensauflösung funktionieren. Das Problem liegt vermutlich bei einer einzelnen Anwendung, einem Proxy oder dem Zielserver.'
}
elseif ($internetPingOk -and -not $dnsOk) {
    Write-Information -MessageData '  Internet per IP erreichbar, aber Namensauflösung schlägt fehl: DNS-Server prüfen (z. B. ipconfig /flushdns, anderen DNS-Server testen).'
}
elseif ($gatewayOk -and -not $internetPingOk -and -not $tcpOk) {
    Write-Information -MessageData '  Gateway erreichbar, aber kein Internet: Problem liegt hinter dem Router (Internetanschluss/Provider, Modem, Router-Neustart).'
}
elseif ($tcpOk) {
    Write-Information -MessageData '  Port 443 ist erreichbar, Ping wird vermutlich blockiert. Verbindung ist im Kern vorhanden.'
}
else {
    Write-Information -MessageData '  Gemischtes Ergebnis: Einzelne Zeilen oben prüfen. Bei Firmennetzen können Proxy oder Firewall Tests blockieren.'
}

if ($PassThru) {
    $script:Ergebnisse.ToArray()
}
