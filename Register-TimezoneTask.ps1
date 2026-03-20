<#
.SYNOPSIS
    Registers the TimezoneRemediation Scheduled Task for Scripts.

.DESCRIPTION
    This script:
    1. Registers the "TimezoneRemediation" event log source
    2. Creates C:\ProgramData\TimezoneRemediation\ and copies Fix-Timezone.ps1 there
    3. Registers a Scheduled Task under \Scripts\ that triggers on every
       timezone change event (Event ID 1, Microsoft-Windows-Kernel-General)
    4. Task runs as SYSTEM with highest privileges, hidden from the UI

    The task fires each time Windows changes the timezone, running
    Fix-Timezone.ps1 to detect the correct timezone via IP geolocation
    and correct it if needed. Works for any location worldwide.

.NOTES
    Requires:  Administrator privileges
    Tested on: Windows 10 22H2, Windows 11 23H2
    PowerShell: 5.1 (Windows PowerShell)
    Dependencies: Fix-Timezone.ps1 must be in the same directory as this script

    Author:  Scripts IT
    Version: 2.0
    Date:    2026-03-20

.EXAMPLE
    # Run from an elevated PowerShell prompt:
    .\Register-TimezoneTask.ps1

    # To unregister and clean up:
    Unregister-ScheduledTask -TaskPath '\Scripts\' -TaskName 'TimezoneRemediation' -Confirm:$false
    Remove-Item 'C:\ProgramData\TimezoneRemediation' -Recurse -Force
    Remove-EventLog -Source 'TimezoneRemediation'
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================

$TaskName       = 'TimezoneRemediation'
$TaskPath       = '\Scripts\'
$DeployFolder   = 'C:\ProgramData\TimezoneRemediation'
$ScriptFileName = 'Fix-Timezone.ps1'
$EventLogSource = 'TimezoneRemediation'
$EventLogName   = 'Application'

# ============================================================================
# STEP 1: Verify Fix-Timezone.ps1 exists alongside this script
# ============================================================================

Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' Scripts Timezone Remediation Installer' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sourceFile = Join-Path $scriptDir $ScriptFileName

if (-not (Test-Path -LiteralPath $sourceFile)) {
    Write-Host "[ERROR] Cannot find '$ScriptFileName' in '$scriptDir'." -ForegroundColor Red
    Write-Host "        Place both scripts in the same folder and re-run." -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Found source script: $sourceFile" -ForegroundColor Green

# ============================================================================
# STEP 2: Register the event log source (idempotent)
#         This must be done BEFORE Fix-Timezone.ps1 tries to write events.
# ============================================================================

Write-Host ''
Write-Host '[STEP 2] Registering event log source...' -ForegroundColor Yellow

try {
    # Check if the source already exists
    $sourceExists = [System.Diagnostics.EventLog]::SourceExists($EventLogSource)
}
catch {
    # SourceExists can throw if we don't have access — treat as not existing
    $sourceExists = $false
}

if (-not $sourceExists) {
    try {
        [System.Diagnostics.EventLog]::CreateEventSource($EventLogSource, $EventLogName)
        Write-Host "  Created event log source '$EventLogSource' in '$EventLogName' log." -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] Could not create event log source: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  The source may already exist under a different log. Continuing..." -ForegroundColor Yellow
    }
}
else {
    Write-Host "  Event log source '$EventLogSource' already exists." -ForegroundColor Green
}

# ============================================================================
# STEP 3: Create deployment folder and copy the remediation script
# ============================================================================

Write-Host ''
Write-Host '[STEP 3] Deploying remediation script...' -ForegroundColor Yellow

if (-not (Test-Path -LiteralPath $DeployFolder)) {
    New-Item -Path $DeployFolder -ItemType Directory -Force | Out-Null
    Write-Host "  Created folder: $DeployFolder" -ForegroundColor Green
}
else {
    Write-Host "  Folder already exists: $DeployFolder" -ForegroundColor Green
}

$destFile = Join-Path $DeployFolder $ScriptFileName
Copy-Item -Path $sourceFile -Destination $destFile -Force
Write-Host "  Copied script to: $destFile" -ForegroundColor Green

# ============================================================================
# STEP 4: Build and register the Scheduled Task
#
# NOTE: PowerShell 5.1's New-ScheduledTaskTrigger does NOT support event-based
# triggers natively. We must construct the trigger using CIM class instances
# and a raw Event subscription XML query. This is the standard approach for
# event-driven tasks on Windows PowerShell 5.1.
# ============================================================================

Write-Host ''
Write-Host '[STEP 4] Registering Scheduled Task...' -ForegroundColor Yellow

# --- 4a: Define the Action ---
# Run PowerShell silently with no profile, bypassing execution policy
$actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destFile`""
$action     = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs

# --- 4b: Define the Event Trigger ---
# We need an event trigger on:
#   Log:      System
#   Provider: Microsoft-Windows-Kernel-General
#   Event ID: 1  (timezone change)
#
# PowerShell 5.1 doesn't have -AtEvent, so we create the trigger via CIM.
$triggerClass = Get-CimClass -ClassName 'MSFT_TaskEventTrigger' `
                             -Namespace 'Root/Microsoft/Windows/TaskScheduler'

# Build the event subscription XML as a standalone here-string
# (here-string closing "@ MUST be at column 0 — no leading whitespace)
$subscriptionXml = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">
      *[System[Provider[@Name='Microsoft-Windows-Kernel-General'] and EventID=1]]
    </Select>
  </Query>
</QueryList>
"@

$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly -Property @{
    Enabled      = $true
    Subscription = $subscriptionXml
}

# --- 4c: Define the Principal ---
# Run as SYSTEM with highest privileges
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
                                        -RunLevel Highest `
                                        -LogonType ServiceAccount

# --- 4d: Define Settings ---
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew `
    -Hidden

# --- 4e: Remove existing task if it exists (idempotent re-registration) ---
$existingTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
    Write-Host "  Removed existing task: $TaskPath$TaskName" -ForegroundColor Yellow
}

# --- 4f: Register the task ---
Register-ScheduledTask -TaskName $TaskName `
                       -TaskPath $TaskPath `
                       -Action $action `
                       -Trigger $trigger `
                       -Principal $principal `
                       -Settings $settings `
                       -Description 'Remediates incorrect timezone changes caused by Wi-Fi BSSID geolocation mismap. Detects correct timezone via IP geolocation and corrects it. Works for any location worldwide.' `
                       -Force | Out-Null

Write-Host "  Registered task: $TaskPath$TaskName" -ForegroundColor Green

# ============================================================================
# STEP 5: Verify registration
# ============================================================================

Write-Host ''
Write-Host '[STEP 5] Verifying...' -ForegroundColor Yellow

$registeredTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($registeredTask) {
    $taskInfo = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  Task Details:' -ForegroundColor Cyan
    Write-Host "    Name         : $($registeredTask.TaskName)"
    Write-Host "    Path         : $($registeredTask.TaskPath)"
    Write-Host "    State        : $($registeredTask.State)"
    Write-Host "    Run As       : $($registeredTask.Principal.UserId)"
    Write-Host "    Run Level    : $($registeredTask.Principal.RunLevel)"
    Write-Host "    Hidden       : $($registeredTask.Settings.Hidden)"
    Write-Host "    Time Limit   : $($registeredTask.Settings.ExecutionTimeLimit)"
    Write-Host "    Multi-Inst   : $($registeredTask.Settings.MultipleInstances)"
    if ($taskInfo) {
        Write-Host "    Last Run     : $($taskInfo.LastRunTime)"
        Write-Host "    Last Result  : $($taskInfo.LastTaskResult)"
    }
}
else {
    Write-Host '  [ERROR] Task registration verification FAILED.' -ForegroundColor Red
    exit 1
}

# ============================================================================
# DONE — Print summary and testing instructions
# ============================================================================

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' INSTALLATION COMPLETE' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''
Write-Host 'The TimezoneRemediation task is now active.' -ForegroundColor Green
Write-Host 'It will fire automatically every time the system timezone changes.' -ForegroundColor Green
Write-Host ''
Write-Host '--- TESTING INSTRUCTIONS ---' -ForegroundColor Cyan
Write-Host ''
Write-Host "1. SIMULATE A TIMEZONE FLIP (run as admin):" -ForegroundColor White
Write-Host "   tzutil /s `"Eastern Standard Time`"" -ForegroundColor Gray
Write-Host "   # Wait 5-10 seconds, then check:" -ForegroundColor Gray
Write-Host "   tzutil /g" -ForegroundColor Gray
Write-Host "   # Should show `"India Standard Time`"" -ForegroundColor Gray
Write-Host ""
Write-Host "2. CHECK THE EVENT LOG:" -ForegroundColor White
Write-Host "   Get-EventLog -LogName Application -Source TimezoneRemediation -Newest 5" -ForegroundColor Gray
Write-Host ""
Write-Host "3. VERIFY TASK STATUS:" -ForegroundColor White
Write-Host "   Get-ScheduledTask -TaskPath `"\Scripts\`" -TaskName `"TimezoneRemediation`"" -ForegroundColor Gray
Write-Host "   Get-ScheduledTaskInfo -TaskPath `"\Scripts\`" -TaskName `"TimezoneRemediation`"" -ForegroundColor Gray
Write-Host ""
Write-Host "4. VIEW TASK IN TASK SCHEDULER UI:" -ForegroundColor White
Write-Host "   taskschd.msc - navigate to Scripts folder" -ForegroundColor Gray
Write-Host "   (Task is hidden; toggle `"Show Hidden Tasks`" in View menu)" -ForegroundColor Gray
Write-Host ""
Write-Host "5. ROLLBACK / UNINSTALL (run as admin):" -ForegroundColor White
Write-Host "   Unregister-ScheduledTask -TaskPath `"\Scripts\`" -TaskName `"TimezoneRemediation`" -Confirm:`$false" -ForegroundColor Gray
Write-Host "   Remove-Item `"C:\ProgramData\TimezoneRemediation`" -Recurse -Force" -ForegroundColor Gray
Write-Host "   Remove-EventLog -Source `"TimezoneRemediation`"" -ForegroundColor Gray
Write-Host ""

