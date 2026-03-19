<#
.SYNOPSIS
    Universal Timezone Remediation Script for Medpace.

.DESCRIPTION
    Detects if the system timezone has been incorrectly changed (caused by
    Wi-Fi BSSID geolocation mismap) and corrects it using the machine's
    actual timezone determined via IP geolocation.

    Works for ANY location worldwide — not hardcoded to any specific timezone.

    Flow:
    1. Query ipinfo.io to get the correct IANA timezone for the public IP
    2. Map the IANA timezone to a Windows timezone ID
    3. Compare with the current system timezone
    4. If mismatch → set correct TZ, flush LfSvc cache, log success
    5. If match → exit silently (nothing to do)
    6. If API fails → exit silently, log warning (don't change anything)

    Designed to run silently as SYSTEM via a Scheduled Task triggered on
    timezone change events (Event ID 1, Microsoft-Windows-Kernel-General).

.NOTES
    Requires:  Administrator or SYSTEM privileges
    Tested on: Windows 10 22H2, Windows 11 23H2
    PowerShell: 5.1 (Windows PowerShell)
    Dependencies: None (no third-party modules)
    API: ipinfo.io (free tier, no API key required)

    Author:  Medpace IT
    Version: 2.0
    Date:    2026-03-20
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================

# IP geolocation API endpoint (returns JSON with a 'timezone' field in IANA format)
$GeoApiUrl     = 'https://ipinfo.io/json'
$ApiTimeoutSec = 15

# Event log configuration
$EventLogSource = 'TimezoneRemediation'
$EventLogName   = 'Application'
$SuccessEventId = 100
$FailureEventId = 101
$WarningEventId = 102

# Location Framework Service cache path
$LfSvcCachePath = 'C:\ProgramData\Microsoft\Windows\LfSvc\Cache'

# ============================================================================
# IANA → WINDOWS TIMEZONE MAPPING
# ============================================================================

function Convert-IanaToWindowsTimezone {
    <#
    .SYNOPSIS
        Converts an IANA timezone ID (e.g. 'Asia/Kolkata') to a Windows
        timezone ID (e.g. 'India Standard Time').
    .DESCRIPTION
        Tries .NET's TryConvertIanaIdToWindowsId first (available on newer
        .NET runtimes). Falls back to a comprehensive static lookup table
        covering 60+ common IANA zones.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$IanaId
    )

    # --- Attempt 1: .NET built-in conversion (available on .NET 6+ / newer Win11) ---
    try {
        $mapped = $null
        $method = [System.TimeZoneInfo].GetMethod(
            'TryConvertIanaIdToWindowsId',
            [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
        )
        if ($method) {
            $result = [System.TimeZoneInfo]::TryConvertIanaIdToWindowsId($IanaId, [ref]$mapped)
            if ($result -and $mapped) {
                return $mapped
            }
        }
    }
    catch {
        # Method not available on this .NET version — fall through to lookup table
    }

    # --- Attempt 2: Static IANA → Windows timezone lookup table ---
    # Covers all major cities and regions. Source: Unicode CLDR / Microsoft docs.
    $ianaToWindows = @{
        # --- Asia ---
        'Asia/Kolkata'         = 'India Standard Time'
        'Asia/Calcutta'        = 'India Standard Time'
        'Asia/Dubai'           = 'Arabian Standard Time'
        'Asia/Karachi'         = 'Pakistan Standard Time'
        'Asia/Dhaka'           = 'Bangladesh Standard Time'
        'Asia/Bangkok'         = 'SE Asia Standard Time'
        'Asia/Ho_Chi_Minh'     = 'SE Asia Standard Time'
        'Asia/Jakarta'         = 'SE Asia Standard Time'
        'Asia/Singapore'       = 'Singapore Standard Time'
        'Asia/Kuala_Lumpur'    = 'Singapore Standard Time'
        'Asia/Hong_Kong'       = 'China Standard Time'
        'Asia/Shanghai'        = 'China Standard Time'
        'Asia/Taipei'          = 'Taipei Standard Time'
        'Asia/Tokyo'           = 'Tokyo Standard Time'
        'Asia/Seoul'           = 'Korea Standard Time'
        'Asia/Riyadh'          = 'Arab Standard Time'
        'Asia/Tehran'          = 'Iran Standard Time'
        'Asia/Jerusalem'       = 'Israel Standard Time'
        'Asia/Baghdad'         = 'Arabic Standard Time'
        'Asia/Kabul'           = 'Afghanistan Standard Time'
        'Asia/Colombo'         = 'Sri Lanka Standard Time'
        'Asia/Kathmandu'       = 'Nepal Standard Time'
        'Asia/Almaty'          = 'Central Asia Standard Time'
        'Asia/Tashkent'        = 'West Asia Standard Time'
        'Asia/Vladivostok'     = 'Vladivostok Standard Time'
        'Asia/Yekaterinburg'   = 'Ekaterinburg Standard Time'
        'Asia/Novosibirsk'     = 'N. Central Asia Standard Time'
        'Asia/Krasnoyarsk'     = 'North Asia Standard Time'
        'Asia/Irkutsk'         = 'North Asia East Standard Time'
        'Asia/Yakutsk'         = 'Yakutsk Standard Time'
        'Asia/Magadan'         = 'Magadan Standard Time'

        # --- Americas ---
        'America/New_York'     = 'Eastern Standard Time'
        'America/Chicago'      = 'Central Standard Time'
        'America/Denver'       = 'Mountain Standard Time'
        'America/Los_Angeles'  = 'Pacific Standard Time'
        'America/Phoenix'      = 'US Mountain Standard Time'
        'America/Anchorage'    = 'Alaskan Standard Time'
        'America/Toronto'      = 'Eastern Standard Time'
        'America/Vancouver'    = 'Pacific Standard Time'
        'America/Winnipeg'     = 'Central Standard Time'
        'America/Edmonton'     = 'Mountain Standard Time'
        'America/Halifax'      = 'Atlantic Standard Time'
        'America/St_Johns'     = 'Newfoundland Standard Time'
        'America/Regina'       = 'Canada Central Standard Time'
        'America/Mexico_City'  = 'Central Standard Time (Mexico)'
        'America/Bogota'       = 'SA Pacific Standard Time'
        'America/Lima'         = 'SA Pacific Standard Time'
        'America/Santiago'     = 'Pacific SA Standard Time'
        'America/Buenos_Aires' = 'Argentina Standard Time'
        'America/Sao_Paulo'    = 'E. South America Standard Time'
        'America/Caracas'      = 'Venezuela Standard Time'

        # --- Europe ---
        'Europe/London'        = 'GMT Standard Time'
        'Europe/Dublin'        = 'GMT Standard Time'
        'Europe/Berlin'        = 'W. Europe Standard Time'
        'Europe/Paris'         = 'Romance Standard Time'
        'Europe/Madrid'        = 'Romance Standard Time'
        'Europe/Rome'          = 'W. Europe Standard Time'
        'Europe/Amsterdam'     = 'W. Europe Standard Time'
        'Europe/Brussels'      = 'Romance Standard Time'
        'Europe/Zurich'        = 'W. Europe Standard Time'
        'Europe/Vienna'        = 'W. Europe Standard Time'
        'Europe/Stockholm'     = 'W. Europe Standard Time'
        'Europe/Warsaw'        = 'Central European Standard Time'
        'Europe/Prague'        = 'Central Europe Standard Time'
        'Europe/Budapest'      = 'Central Europe Standard Time'
        'Europe/Bucharest'     = 'GTB Standard Time'
        'Europe/Athens'        = 'GTB Standard Time'
        'Europe/Istanbul'      = 'Turkey Standard Time'
        'Europe/Moscow'        = 'Russian Standard Time'
        'Europe/Helsinki'      = 'FLE Standard Time'
        'Europe/Kiev'          = 'FLE Standard Time'
        'Europe/Kyiv'          = 'FLE Standard Time'
        'Europe/Lisbon'        = 'GMT Standard Time'

        # --- Africa ---
        'Africa/Johannesburg'  = 'South Africa Standard Time'
        'Africa/Cairo'         = 'Egypt Standard Time'
        'Africa/Lagos'         = 'W. Central Africa Standard Time'
        'Africa/Nairobi'       = 'E. Africa Standard Time'
        'Africa/Casablanca'    = 'Morocco Standard Time'

        # --- Oceania ---
        'Australia/Sydney'     = 'AUS Eastern Standard Time'
        'Australia/Melbourne'  = 'AUS Eastern Standard Time'
        'Australia/Brisbane'   = 'E. Australia Standard Time'
        'Australia/Perth'      = 'W. Australia Standard Time'
        'Australia/Adelaide'   = 'Cen. Australia Standard Time'
        'Australia/Darwin'     = 'AUS Central Standard Time'
        'Pacific/Auckland'     = 'New Zealand Standard Time'
        'Pacific/Honolulu'     = 'Hawaiian Standard Time'
        'Pacific/Fiji'         = 'Fiji Standard Time'

        # --- UTC ---
        'UTC'                  = 'UTC'
        'Etc/UTC'              = 'UTC'
        'Etc/GMT'              = 'UTC'
    }

    if ($ianaToWindows.ContainsKey($IanaId)) {
        return $ianaToWindows[$IanaId]
    }

    # Not found in either method
    return $null
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

try {
    # -----------------------------------------------------------------------
    # Step 1: Get the current system timezone
    # -----------------------------------------------------------------------
    $currentTz = (& tzutil /g).Trim()

    # -----------------------------------------------------------------------
    # Step 2: Query IP geolocation API for the correct timezone
    # -----------------------------------------------------------------------
    $geoResponse = $null
    try {
        $geoResponse = Invoke-RestMethod -Uri $GeoApiUrl -Method Get -TimeoutSec $ApiTimeoutSec -ErrorAction Stop
    }
    catch {
        # API call failed — could be no internet, API down, firewall, etc.
        # SAFETY: do NOT change the timezone if we can't verify what it should be
        try {
            Write-EventLog -LogName $EventLogName `
                           -Source  $EventLogSource `
                           -EventId $WarningEventId `
                           -EntryType Warning `
                           -Message ("IP geolocation lookup failed. No timezone change made.`n`nError: {0}`nCurrent TZ: {1}`nComputer: {2}" -f $_.Exception.Message, $currentTz, $env:COMPUTERNAME)
        }
        catch { }
        exit 0
    }

    # -----------------------------------------------------------------------
    # Step 3: Extract and validate the IANA timezone from the API response
    # -----------------------------------------------------------------------
    $ianaTz = $null
    if ($geoResponse -and ($geoResponse.PSObject.Properties.Name -contains 'timezone')) {
        $ianaTz = [string]$geoResponse.timezone
    }

    if ([string]::IsNullOrWhiteSpace($ianaTz)) {
        # API returned a response but without a valid timezone field
        try {
            Write-EventLog -LogName $EventLogName `
                           -Source  $EventLogSource `
                           -EventId $WarningEventId `
                           -EntryType Warning `
                           -Message ("IP geolocation returned no timezone field. No change made.`nCurrent TZ: {0}`nComputer: {1}" -f $currentTz, $env:COMPUTERNAME)
        }
        catch { }
        exit 0
    }

    # -----------------------------------------------------------------------
    # Step 4: Map IANA timezone to Windows timezone ID
    # -----------------------------------------------------------------------
    $correctWindowsTz = Convert-IanaToWindowsTimezone -IanaId $ianaTz

    if (-not $correctWindowsTz) {
        # Unknown IANA timezone — can't map it, so don't change anything
        try {
            Write-EventLog -LogName $EventLogName `
                           -Source  $EventLogSource `
                           -EventId $WarningEventId `
                           -EntryType Warning `
                           -Message ("Could not map IANA timezone to Windows timezone.`n`nIANA: {0}`nCurrent TZ: {1}`nComputer: {2}" -f $ianaTz, $currentTz, $env:COMPUTERNAME)
        }
        catch { }
        exit 0
    }

    # -----------------------------------------------------------------------
    # Step 5: Compare — if timezone is already correct, exit silently
    # -----------------------------------------------------------------------
    if ($currentTz -eq $correctWindowsTz) {
        # Timezone is correct — nothing to do
        exit 0
    }

    # -----------------------------------------------------------------------
    # Step 6: Timezone mismatch detected — remediate
    # -----------------------------------------------------------------------

    # 6a: Set the correct timezone
    & tzutil /s "$correctWindowsTz"
    if ($LASTEXITCODE -ne 0) {
        throw "tzutil /s failed with exit code $LASTEXITCODE when setting '$correctWindowsTz'"
    }

    # 6b: Stop the Location Framework Service (lfsvc)
    #     This service performs the Wi-Fi BSSID geolocation that causes
    #     the incorrect timezone mapping.
    $lfsvc = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    if ($lfsvc) {
        Stop-Service -Name 'lfsvc' -Force -ErrorAction SilentlyContinue

        # Wait for the service to fully stop
        $timeout = 15
        $elapsed = 0
        while ((Get-Service -Name 'lfsvc').Status -ne 'Stopped' -and $elapsed -lt $timeout) {
            Start-Sleep -Seconds 1
            $elapsed++
        }
    }

    # 6c: Delete the LfSvc cache files
    #     These cached geolocation results contain the wrong coordinates.
    if (Test-Path -LiteralPath $LfSvcCachePath) {
        Get-ChildItem -Path $LfSvcCachePath -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }

    # 6d: Restart lfsvc
    if ($lfsvc) {
        Start-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    }

    # 6e: Write success entry to the Application event log
    $verifyTz = (& tzutil /g).Trim()
    $ipInfo = ""
    if ($geoResponse.PSObject.Properties.Name -contains 'ip')      { $ipInfo += "Public IP     : $($geoResponse.ip)`n" }
    if ($geoResponse.PSObject.Properties.Name -contains 'city')    { $ipInfo += "City          : $($geoResponse.city)`n" }
    if ($geoResponse.PSObject.Properties.Name -contains 'region')  { $ipInfo += "Region        : $($geoResponse.region)`n" }
    if ($geoResponse.PSObject.Properties.Name -contains 'country') { $ipInfo += "Country       : $($geoResponse.country)`n" }

    $logMessage = @"
Timezone remediation completed successfully.

Previous timezone : $currentTz
Correct timezone  : $correctWindowsTz (IANA: $ianaTz)
Verified timezone : $verifyTz
LfSvc cache       : Cleared

$ipInfo
Timestamp         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer          : $env:COMPUTERNAME
"@

    Write-EventLog -LogName $EventLogName `
                   -Source  $EventLogSource `
                   -EventId $SuccessEventId `
                   -EntryType Information `
                   -Message $logMessage

    exit 0
}
catch {
    # -----------------------------------------------------------------------
    # Error handling: attempt to log the failure to the event log
    # -----------------------------------------------------------------------
    $errorMessage = @"
Timezone remediation FAILED.

Error    : $($_.Exception.Message)
Stack    : $($_.ScriptStackTrace)
Computer : $env:COMPUTERNAME
"@

    try {
        Write-EventLog -LogName $EventLogName `
                       -Source  $EventLogSource `
                       -EventId $FailureEventId `
                       -EntryType Error `
                       -Message $errorMessage
    }
    catch {
        # If we can't even write to the event log, there's nothing more we can do
    }

    exit 1
}
