param(
    [string]$LogRoot = 'C:\Windows\Logs\Timezone',
    [string]$IpApiUrl = 'https://ipinfo.io/json',
    [switch]$SkipIpFallback,
    [switch]$VerboseConsole,
    [int]$UserContextActionTimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFilePath = $null
$script:VerboseToConsole = [bool]$VerboseConsole

function Write-Console {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    try { Write-Host $Message -ForegroundColor $Color }
    catch { Write-Host $Message }
}

function Out2Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

    $show = $false
    if ($Level -in @('WARN', 'ERROR', 'SUCCESS')) { $show = $true }
    elseif ($script:VerboseToConsole) { $show = $true }
    elseif ($Message -like '[IMPORTANT]*') { $show = $true }

    if ($show) {
        $color = [ConsoleColor]::Gray
        if ($Level -eq 'WARN') { $color = [ConsoleColor]::Yellow }
        if ($Level -eq 'ERROR') { $color = [ConsoleColor]::Red }
        if ($Level -eq 'SUCCESS') { $color = [ConsoleColor]::Green }
        Write-Console -Message $line -Color $color
    }

    if ($script:LogFilePath) {
        try { Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8 }
        catch { Write-Console -Message "[${ts}] [ERROR] Log write failed: $($_.Exception.Message)" -Color Red }
    }
}

function Initialize-Log {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    try {
        if (-not (Test-Path -LiteralPath $RootPath)) {
            New-Item -Path $RootPath -ItemType Directory -Force | Out-Null
        }

        $name = 'TimezoneRemediation-{0}.txt' -f (Get-Date -Format 'yyyyMMdd')
        $script:LogFilePath = Join-Path $RootPath $name
        if (-not (Test-Path -LiteralPath $script:LogFilePath)) {
            New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null
        }

        Out2Log -Level INFO -Message "Logging to $script:LogFilePath"
        return $true
    }
    catch {
        Write-Console -Color Red -Message ("[{0}] [ERROR] Cannot initialize log at {1}. {2}" -f (Get-Date -Format s), $RootPath, $_.Exception.Message)
        return $false
    }
}

function Test-IsElevatedOrSystem {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        $isAdmin = $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
        $isSystem = $id.Name -eq 'NT AUTHORITY\SYSTEM'
        return ($isAdmin -or $isSystem)
    }
    catch {
        return $false
    }
}

function Fail-Fast {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw [System.InvalidOperationException]("FATAL: $Message")
}

function SafeText {
    param($Value, [string]$Default = 'N/A')
    if ($null -eq $Value) { return $Default }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s
}

function Get-InteractiveUserContext {
    $fullUser = $null
    $sessionId = $null

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.UserName) { $fullUser = $cs.UserName.Trim() }
    }
    catch {
        Out2Log -Level WARN -Message "Could not read Win32_ComputerSystem user: $($_.Exception.Message)"
    }

    try {
        $rows = & quser 2>$null
        if ($rows) {
            foreach ($row in ($rows | Select-Object -Skip 1)) {
                $t = $row.TrimStart()
                if (-not $t) { continue }
                if ($t -match '^>?\s*(?<User>\S+)\s+(?<Session>\S+)\s+(?<Id>\d+)\s+(?<State>\S+)\s+') {
                    if ($matches['State'] -eq 'Active') {
                        if (-not $fullUser) { $fullUser = "$env:COMPUTERNAME\$($matches['User'])" }
                        $sessionId = [int]$matches['Id']
                        break
                    }
                }
            }
        }
    }
    catch {
        Out2Log -Level WARN -Message "Could not parse quser output: $($_.Exception.Message)"
    }

    if (-not $fullUser) {
        Out2Log -Level WARN -Message "No interactive user found. User-context step will be skipped."
        return $null
    }

    $domain = $env:COMPUTERNAME
    $user = $fullUser
    if ($fullUser -match '^(?<D>[^\\]+)\\(?<U>.+)$') {
        $domain = $matches['D']
        $user = $matches['U']
    }
    else {
        $fullUser = "$domain\$user"
    }

    $sid = $null
    $profilePath = $null
    try {
        $acct = New-Object System.Security.Principal.NTAccount($fullUser)
        $sid = $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $reg = Get-ItemProperty -Path ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{0}" -f $sid) -ErrorAction SilentlyContinue
        if ($reg -and $reg.ProfileImagePath) {
            $profilePath = [Environment]::ExpandEnvironmentVariables($reg.ProfileImagePath)
        }
    }
    catch {
        Out2Log -Level WARN -Message "Could not resolve SID/profile for ${fullUser}: $($_.Exception.Message)"
    }

    $ctx = [pscustomobject]@{
        UserName     = $user
        Domain       = $domain
        FullUserName = $fullUser
        SessionId    = $sessionId
        ProfilePath  = $profilePath
        Sid          = $sid
    }

    Out2Log -Level INFO -Message ("Interactive user: {0} | Session={1} | Profile={2} | SID={3}" -f $ctx.FullUserName, (SafeText $ctx.SessionId), (SafeText $ctx.ProfilePath), (SafeText $ctx.Sid))
    return $ctx
}

function Invoke-InInteractiveUserContext {
    param(
        [Parameter(Mandatory = $true)]$UserContext,
        [Parameter(Mandatory = $true)][string]$ScriptContent,
        [int]$TimeoutSec = 120
    )

    $taskName = "TimezoneFix-UserCtx-{0}" -f ([guid]::NewGuid().ToString('N'))
    $tempDir = Join-Path $env:ProgramData 'TimezoneRemediation\Temp'
    $tempScript = Join-Path $tempDir ($taskName + '.ps1')

    try {
        if (-not (Test-Path -LiteralPath $tempDir)) {
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        }
        Set-Content -Path $tempScript -Value $ScriptContent -Encoding UTF8 -Force
        Out2Log -Level INFO -Message "Prepared temp user script: $tempScript"

        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
        $principal = New-ScheduledTaskPrincipal -UserId $UserContext.FullUserName -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Out2Log -Level INFO -Message "Registered temp task $taskName as $($UserContext.FullUserName)"

        Start-ScheduledTask -TaskName $taskName
        Out2Log -Level INFO -Message "Started user-context task $taskName"

        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do {
            Start-Sleep -Seconds 2
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            if ($task.State -eq 'Ready' -and $info.LastRunTime -gt [datetime]'2000-01-01') {
                if ($info.LastTaskResult -eq 0) {
                    Out2Log -Level SUCCESS -Message "User-context task completed successfully."
                    return $true
                }
                Out2Log -Level WARN -Message "User-context task finished with LastTaskResult=$($info.LastTaskResult)."
                return $false
            }
        } while ((Get-Date) -lt $deadline)

        Out2Log -Level WARN -Message "User-context task timeout after $TimeoutSec seconds."
        return $false
    }
    catch {
        Out2Log -Level WARN -Message "User-context task failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Out2Log -Level INFO -Message "Removed temp task $taskName"
        }
        catch {
            Out2Log -Level WARN -Message "Could not remove temp task ${taskName}: $($_.Exception.Message)"
        }
        try { Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue }
        catch { Out2Log -Level WARN -Message "Could not remove temp script ${tempScript}: $($_.Exception.Message)" }
    }
}

function Set-TimezoneAutoUpdatePolicy {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate'
    try {
        if (-not (Test-Path -LiteralPath $path)) { Fail-Fast "Missing registry key: $path" }
        Set-ItemProperty -Path $path -Name Start -Value 3 -Type DWord
        $v = (Get-ItemProperty -Path $path -Name Start).Start
        if ($v -ne 3) { Fail-Fast "tzautoupdate Start verification failed (value=$v)." }
        Out2Log -Level SUCCESS -Message "tzautoupdate Start is set to 3."
    }
    catch {
        if ($_.Exception.Message -like 'FATAL:*') { throw }
        Fail-Fast "Unable to set tzautoupdate Start. $($_.Exception.Message)"
    }
}

function Set-LocationConsentAllow {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    try {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name Value -Value 'Allow' -Type String
        $v = (Get-ItemProperty -Path $path -Name Value).Value
        if ($v -ne 'Allow') { Fail-Fast "Location consent verification failed (value=$v)." }
        Out2Log -Level SUCCESS -Message "Location consent is set to Allow."
    }
    catch {
        if ($_.Exception.Message -like 'FATAL:*') { throw }
        Fail-Fast "Unable to set location consent. $($_.Exception.Message)"
    }
}

function Restart-ServiceWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [bool]$Mandatory = $false,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 5
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $svc = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($svc.Status -eq 'Stopped') {
                Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
            }
            Restart-Service -Name $ServiceName -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            $svc = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                Out2Log -Level SUCCESS -Message "$ServiceName restart succeeded (attempt $i)."
                return $true
            }
            Out2Log -Level WARN -Message "$ServiceName restart attempt $i ended with status $($svc.Status)."
        }
        catch {
            Out2Log -Level WARN -Message "$ServiceName restart attempt $i failed: $($_.Exception.Message)"
        }
        if ($i -lt $MaxAttempts) { Start-Sleep -Seconds $DelaySeconds }
    }

    if ($Mandatory) { Fail-Fast "Could not restart mandatory service $ServiceName after $MaxAttempts attempts." }
    Out2Log -Level WARN -Message "$ServiceName could not be restarted (best effort)."
    return $false
}

function Restart-TimezoneDetectionServices {
    Out2Log -Level INFO -Message 'Restarting lfsvc (best effort) and tzautoupdate (mandatory).'
    [void](Restart-ServiceWithRetry -ServiceName 'lfsvc' -Mandatory:$false)
    [void](Restart-ServiceWithRetry -ServiceName 'tzautoupdate' -Mandatory:$true)
}

function Get-CurrentWindowsTimeZone {
    try { return (& tzutil /g).Trim() }
    catch { return $null }
}

function Resolve-WindowsTimeZoneIdFromIana {
    param([Parameter(Mandatory = $true)][string]$IanaId)

    try {
        $mapped = $null
        $method = [System.TimeZoneInfo].GetMethod(
            'TryConvertIanaIdToWindowsId',
            [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
        )
        if ($method) {
            $ok = [System.TimeZoneInfo]::TryConvertIanaIdToWindowsId($IanaId, [ref]$mapped)
            if ($ok -and $mapped) { return $mapped }
        }
    }
    catch {
        Out2Log -Level WARN -Message "Dynamic IANA mapping failed for '$IanaId': $($_.Exception.Message)"
    }

    $fallback = @{
        'Asia/Kolkata' = 'India Standard Time'
        'America/New_York' = 'Eastern Standard Time'
        'America/Chicago' = 'Central Standard Time'
        'America/Denver' = 'Mountain Standard Time'
        'America/Los_Angeles' = 'Pacific Standard Time'
        'America/Phoenix' = 'US Mountain Standard Time'
        'America/Anchorage' = 'Alaskan Standard Time'
        'Pacific/Honolulu' = 'Hawaiian Standard Time'
        'Europe/London' = 'GMT Standard Time'
        'Europe/Berlin' = 'W. Europe Standard Time'
        'Europe/Paris' = 'Romance Standard Time'
        'Europe/Moscow' = 'Russian Standard Time'
        'Asia/Dubai' = 'Arabian Standard Time'
        'Asia/Karachi' = 'Pakistan Standard Time'
        'Asia/Dhaka' = 'Bangladesh Standard Time'
        'Asia/Bangkok' = 'SE Asia Standard Time'
        'Asia/Singapore' = 'Singapore Standard Time'
        'Asia/Hong_Kong' = 'China Standard Time'
        'Asia/Shanghai' = 'China Standard Time'
        'Asia/Tokyo' = 'Tokyo Standard Time'
        'Asia/Seoul' = 'Korea Standard Time'
        'Australia/Sydney' = 'AUS Eastern Standard Time'
        'Australia/Perth' = 'W. Australia Standard Time'
        'Pacific/Auckland' = 'New Zealand Standard Time'
        'Africa/Johannesburg' = 'South Africa Standard Time'
        'UTC' = 'UTC'
        'Etc/UTC' = 'UTC'
    }

    if ($fallback.ContainsKey($IanaId)) { return $fallback[$IanaId] }
    return $null
}

function Invoke-IpTimezoneFallback {
    param([Parameter(Mandatory = $true)][string]$ApiUrl)

    $before = Get-CurrentWindowsTimeZone
    Out2Log -Level INFO -Message ("Timezone before IP fallback: {0}" -f (SafeText $before 'Unknown'))

    try {
        $ip = Invoke-RestMethod -Uri $ApiUrl -Method Get -TimeoutSec 20 -ErrorAction Stop
    }
    catch {
        Out2Log -Level WARN -Message "IP lookup failed ($ApiUrl): $($_.Exception.Message)"
        return $false
    }

    $iana = $null
    if ($ip -and ($ip.PSObject.Properties.Name -contains 'timezone')) {
        $iana = [string]$ip.timezone
    }

    if ([string]::IsNullOrWhiteSpace($iana)) {
        Out2Log -Level WARN -Message 'IP API response had no timezone field.'
        return $false
    }

    Out2Log -Level INFO -Message "IANA timezone from IP API: $iana"
    $winTz = Resolve-WindowsTimeZoneIdFromIana -IanaId $iana
    if (-not $winTz) {
        Out2Log -Level WARN -Message "No Windows timezone mapping for '$iana'."
        return $false
    }

    try {
        & tzutil /s "$winTz" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Out2Log -Level WARN -Message "tzutil failed applying '$winTz' (exit $LASTEXITCODE)."
            return $false
        }
    }
    catch {
        Out2Log -Level WARN -Message "Could not set timezone '$winTz': $($_.Exception.Message)"
        return $false
    }

    $after = Get-CurrentWindowsTimeZone
    Out2Log -Level SUCCESS -Message ("Timezone after IP fallback: {0}" -f (SafeText $after 'Unknown'))
    return $true
}

function Invoke-UserSessionRefreshAction {
    param(
        [Parameter(Mandatory = $false)]$UserContext,
        [int]$TimeoutSec = 120
    )

    if (-not $UserContext) {
        Out2Log -Level WARN -Message 'Skipping user-session action because no interactive user was found.'
        return $false
    }

    $scriptBody = @'
$ErrorActionPreference = "Stop"
$root = Join-Path $env:LOCALAPPDATA "TimezoneRemediation"
if (-not (Test-Path -LiteralPath $root)) {
    New-Item -Path $root -ItemType Directory -Force | Out-Null
}
$marker = Join-Path $root "last-run.txt"
$tz = (tzutil /g).Trim()
$line = "{0}`tUser={1}`tSession={2}`tTZ={3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $env:USERNAME, $env:SESSIONNAME, $tz
Set-Content -Path $marker -Value $line -Encoding UTF8 -Force
exit 0
'@

    Out2Log -Level INFO -Message 'Running user-session marker action.'
    $ok = Invoke-InInteractiveUserContext -UserContext $UserContext -ScriptContent $scriptBody -TimeoutSec $TimeoutSec
    if ($ok) {
        Out2Log -Level SUCCESS -Message 'User-session marker action completed.'
        return $true
    }

    Out2Log -Level WARN -Message 'User-session marker action did not complete successfully.'
    return $false
}

function Invoke-Main {
    $start = Get-Date

    if (-not (Test-IsElevatedOrSystem)) {
        Write-Console -Color Red -Message ("[{0}] [ERROR] Run this script as Administrator or SYSTEM." -f (Get-Date -Format s))
        return 1
    }

    if (-not (Initialize-Log -RootPath $LogRoot)) {
        return 1
    }

    Out2Log -Level INFO -Message 'Starting timezone remediation.'

    try {
        $ctx = Get-InteractiveUserContext

        Set-TimezoneAutoUpdatePolicy
        Set-LocationConsentAllow
        Restart-TimezoneDetectionServices

        $tzBefore = Get-CurrentWindowsTimeZone
        Out2Log -Level INFO -Message ("Timezone before fallback stage: {0}" -f (SafeText $tzBefore 'Unknown'))

        if ($SkipIpFallback) {
            Out2Log -Level WARN -Message 'IP fallback skipped due to -SkipIpFallback.'
        }
        else {
            [void](Invoke-IpTimezoneFallback -ApiUrl $IpApiUrl)
        }

        [void](Invoke-UserSessionRefreshAction -UserContext $ctx -TimeoutSec $UserContextActionTimeoutSec)

        $tzAfter = Get-CurrentWindowsTimeZone
        $seconds = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds
        Out2Log -Level SUCCESS -Message ("Finished. Final timezone: {0}. Elapsed: {1:N1}s" -f (SafeText $tzAfter 'Unknown'), $seconds)
        return 0
    }
    catch {
        $m = $_.Exception.Message
        if ($m -like 'FATAL:*') {
            Out2Log -Level ERROR -Message $m
            return 1
        }

        Out2Log -Level ERROR -Message "Unexpected error: $m"
        Out2Log -Level ERROR -Message "Stack: $($_.ScriptStackTrace)"
        return 2
    }
}

$code = Invoke-Main
exit $code
