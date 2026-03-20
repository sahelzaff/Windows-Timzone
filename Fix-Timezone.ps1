<#
.SYNOPSIS
    Universal Timezone Remediation Script for Scripts.

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

    Logs every step to: %TEMP%\Timezone_Logs\TimezoneRemediation-YYYYMMDD.log

.NOTES
    Requires:  Administrator or SYSTEM privileges
    Tested on: Windows 10 22H2, Windows 11 23H2
    PowerShell: 5.1 (Windows PowerShell)
    Dependencies: None (no third-party modules)
    API: ipinfo.io (free tier, no API key required)

    Author:  Scripts IT
    Version: 2.1
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

# Log file configuration
# When running as SYSTEM, $env:TEMP = C:\Windows\Temp
# When running as admin user, $env:TEMP = C:\Users\<user>\AppData\Local\Temp
$LogFolder = Join-Path $env:TEMP 'Timezone_Logs'
$LogFile   = Join-Path $LogFolder ("TimezoneRemediation-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

# ============================================================================
# LOGGING FUNCTION
# ============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, leveled log entry to the log file.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[{0}] [{1,-7}] {2}" -f $timestamp, $Level, $Message

    try {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Last resort — if we can't write to the log, there's nothing we can do
    }
}

function Initialize-Logging {
    <#
    .SYNOPSIS
        Creates the log folder and log file, writes a session header.
    #>
    try {
        if (-not (Test-Path -LiteralPath $script:LogFolder)) {
            New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null
        }

        # Write session separator and header
        $sessionTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $separator = '=' * 80
        $headerLine1 = "  TIMEZONE REMEDIATION SESSION - $sessionTime"
        $headerLine2 = "  Computer: $env:COMPUTERNAME | User: $env:USERNAME | PID: $PID"
        $header = @('', $separator, $headerLine1, $headerLine2, $separator)
        foreach ($line in $header) {
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        return $true
    }
    catch {
        return $false
    }
}

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
                Write-Log -Level INFO -Message "IANA mapping via .NET: '$IanaId' -> '$mapped'"
                return $mapped
            }
        }
    }
    catch {
        Write-Log -Level INFO -Message ".NET TryConvertIanaIdToWindowsId not available, using fallback table."
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
        $mapped = $ianaToWindows[$IanaId]
        Write-Log -Level INFO -Message "IANA mapping via fallback table: '$IanaId' -> '$mapped'"
        return $mapped
    }

    # Not found in either method
    Write-Log -Level WARN -Message "No mapping found for IANA timezone: '$IanaId'"
    return $null
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

try {
    # -----------------------------------------------------------------------
    # Step 0: Initialize logging
    # -----------------------------------------------------------------------
    $logOk = Initialize-Logging
    if ($logOk) {
        Write-Log -Level INFO -Message "Log file initialized: $LogFile"
    }

    Write-Log -Level INFO -Message "Script version 2.1 starting."
    Write-Log -Level INFO -Message "Running as: $env:USERDOMAIN\$env:USERNAME"

    # -----------------------------------------------------------------------
    # Step 1: Get the current system timezone
    # -----------------------------------------------------------------------
    $currentTz = (& tzutil /g).Trim()
    Write-Log -Level INFO -Message "Current system timezone: $currentTz"

    # -----------------------------------------------------------------------
    # Step 2: Query IP geolocation API for the correct timezone
    # -----------------------------------------------------------------------
    Write-Log -Level INFO -Message "Querying IP geolocation API: $GeoApiUrl (timeout: ${ApiTimeoutSec}s)"

    $geoResponse = $null
    try {
        $geoResponse = Invoke-RestMethod -Uri $GeoApiUrl -Method Get -TimeoutSec $ApiTimeoutSec -ErrorAction Stop
        Write-Log -Level SUCCESS -Message "API call succeeded."
    }
    catch {
        # API call failed — could be no internet, API down, firewall, etc.
        # SAFETY: do NOT change the timezone if we can't verify what it should be
        Write-Log -Level WARN -Message "API call FAILED: $($_.Exception.Message)"
        Write-Log -Level WARN -Message "No timezone change will be made (safety: cannot verify correct TZ)."

        try {
            Write-EventLog -LogName $EventLogName `
                           -Source  $EventLogSource `
                           -EventId $WarningEventId `
                           -EntryType Warning `
                           -Message ("IP geolocation lookup failed. No timezone change made.`n`nError: {0}`nCurrent TZ: {1}`nComputer: {2}" -f $_.Exception.Message, $currentTz, $env:COMPUTERNAME)
        }
        catch {
            Write-Log -Level ERROR -Message "Could not write warning to event log: $($_.Exception.Message)"
        }
        Write-Log -Level INFO -Message "Exiting (no action taken)."
        exit 0
    }

    # Log the geolocation response details
    if ($geoResponse) {
        $geoDetails = @()
        if ($geoResponse.PSObject.Properties.Name -contains 'ip')       { $geoDetails += "IP=$($geoResponse.ip)" }
        if ($geoResponse.PSObject.Properties.Name -contains 'city')     { $geoDetails += "City=$($geoResponse.city)" }
        if ($geoResponse.PSObject.Properties.Name -contains 'region')   { $geoDetails += "Region=$($geoResponse.region)" }
        if ($geoResponse.PSObject.Properties.Name -contains 'country')  { $geoDetails += "Country=$($geoResponse.country)" }
        if ($geoResponse.PSObject.Properties.Name -contains 'timezone') { $geoDetails += "Timezone=$($geoResponse.timezone)" }
        Write-Log -Level INFO -Message "Geolocation result: $($geoDetails -join ' | ')"
    }

    # -----------------------------------------------------------------------
    # Step 3: Extract and validate the IANA timezone from the API response
    # -----------------------------------------------------------------------
    $ianaTz = $null
    if ($geoResponse -and ($geoResponse.PSObject.Properties.Name -contains 'timezone')) {
        $ianaTz = [string]$geoResponse.timezone
    }

    if ([string]::IsNullOrWhiteSpace($ianaTz)) {
        Write-Log -Level WARN -Message "API response did not contain a valid 'timezone' field."
        Write-Log -Level WARN -Message "No timezone change will be made."

        try {
            Write-EventLog -LogName $EventLogName `
                           -Source  $EventLogSource `
                           -EventId $WarningEventId `
                           -EntryType Warning `
                           -Message ("IP geolocation returned no timezone field. No change made.`nCurrent TZ: {0}`nComputer: {1}" -f $currentTz, $env:COMPUTERNAME)
        }
        catch {
            Write-Log -Level ERROR -Message "Could not write warning to event log: $($_.Exception.Message)"
        }
        Write-Log -Level INFO -Message "Exiting (no action taken)."
        exit 0
    }

    Write-Log -Level INFO -Message "IANA timezone from API: $ianaTz"

    # -----------------------------------------------------------------------
    # Step 4: Map IANA timezone to Windows timezone ID
    # -----------------------------------------------------------------------
    Write-Log -Level INFO -Message "Mapping IANA timezone to Windows timezone ID..."

    $correctWindowsTz = Convert-IanaToWindowsTimezone -IanaId $ianaTz

    if (-not $correctWindowsTz) {
        Write-Log -Level WARN -Message "Could not map IANA timezone '$ianaTz' to any Windows timezone."
        Write-Log -Level WARN -Message "No timezone change will be made."

        try {
            Write-EventLog -LogName $EventLogName `
                           -Source  $EventLogSource `
                           -EventId $WarningEventId `
                           -EntryType Warning `
                           -Message ("Could not map IANA timezone to Windows timezone.`n`nIANA: {0}`nCurrent TZ: {1}`nComputer: {2}" -f $ianaTz, $currentTz, $env:COMPUTERNAME)
        }
        catch {
            Write-Log -Level ERROR -Message "Could not write warning to event log: $($_.Exception.Message)"
        }
        Write-Log -Level INFO -Message "Exiting (no action taken)."
        exit 0
    }

    Write-Log -Level INFO -Message "Correct Windows timezone: $correctWindowsTz"

    # -----------------------------------------------------------------------
    # Step 5: Compare — if timezone is already correct, exit silently
    # -----------------------------------------------------------------------
    if ($currentTz -eq $correctWindowsTz) {
        Write-Log -Level SUCCESS -Message "Timezone is ALREADY CORRECT ($currentTz). No action needed."
        Write-Log -Level INFO -Message "Exiting (no action taken)."
        exit 0
    }

    Write-Log -Level WARN -Message "TIMEZONE MISMATCH DETECTED!"
    Write-Log -Level WARN -Message "  Current : $currentTz"
    Write-Log -Level WARN -Message "  Correct : $correctWindowsTz (IANA: $ianaTz)"
    Write-Log -Level INFO -Message "Starting remediation..."

    # -----------------------------------------------------------------------
    # Step 6: Timezone mismatch detected — remediate
    # -----------------------------------------------------------------------

    # 6a: Set the correct timezone
    Write-Log -Level INFO -Message "Setting timezone to '$correctWindowsTz' via tzutil..."
    & tzutil /s "$correctWindowsTz"
    if ($LASTEXITCODE -ne 0) {
        throw "tzutil /s failed with exit code $LASTEXITCODE when setting '$correctWindowsTz'"
    }
    $verifyTz = (& tzutil /g).Trim()
    Write-Log -Level SUCCESS -Message "Timezone set. Verified: $verifyTz"

    # 6b: Stop the Location Framework Service (lfsvc)
    Write-Log -Level INFO -Message "Stopping lfsvc service..."
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
        $lfsvcStatus = (Get-Service -Name 'lfsvc').Status
        Write-Log -Level INFO -Message "lfsvc status after stop: $lfsvcStatus (waited ${elapsed}s)"
    }
    else {
        Write-Log -Level WARN -Message "lfsvc service not found."
    }

    # 6c: Delete the LfSvc cache files
    Write-Log -Level INFO -Message "Clearing LfSvc cache: $LfSvcCachePath"
    if (Test-Path -LiteralPath $LfSvcCachePath) {
        $cacheFiles = Get-ChildItem -Path $LfSvcCachePath -Recurse -Force -ErrorAction SilentlyContinue
        $cacheCount = ($cacheFiles | Measure-Object).Count
        $cacheFiles | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log -Level SUCCESS -Message "Deleted $cacheCount cached file(s) from LfSvc cache."
    }
    else {
        Write-Log -Level INFO -Message "LfSvc cache folder does not exist (nothing to clear)."
    }

    # 6d: Restart lfsvc
    if ($lfsvc) {
        Write-Log -Level INFO -Message "Restarting lfsvc service..."
        Start-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $lfsvcStatus = (Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue).Status
        Write-Log -Level INFO -Message "lfsvc status after restart: $lfsvcStatus"
    }

    # 6e: Write success entry to the Application event log
    Write-Log -Level INFO -Message "Writing success event to Application event log (Event ID $SuccessEventId)..."
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
LfSvc cache       : Cleared ($cacheCount files)

$ipInfo
Timestamp         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer          : $env:COMPUTERNAME
"@

    Write-EventLog -LogName $EventLogName `
                   -Source  $EventLogSource `
                   -EventId $SuccessEventId `
                   -EntryType Information `
                   -Message $logMessage

    Write-Log -Level SUCCESS -Message "Event log entry written."
    Write-Log -Level SUCCESS -Message "=== REMEDIATION COMPLETE ==="
    Write-Log -Level SUCCESS -Message "  Previous: $currentTz -> Corrected: $verifyTz"

    exit 0
}
catch {
    # -----------------------------------------------------------------------
    # Error handling: log to file and attempt to log to event log
    # -----------------------------------------------------------------------
    Write-Log -Level ERROR -Message "REMEDIATION FAILED: $($_.Exception.Message)"
    Write-Log -Level ERROR -Message "Stack trace: $($_.ScriptStackTrace)"

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
        Write-Log -Level ERROR -Message "Could not write error to event log: $($_.Exception.Message)"
    }

    exit 1
}
