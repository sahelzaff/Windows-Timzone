# 🕐 Windows Timezone Auto-Remediation

**Automatically fixes incorrect timezone changes caused by Wi-Fi BSSID geolocation mismap on Windows.**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://docs.microsoft.com/en-us/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6.svg)](https://www.microsoft.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Problem

Windows uses **Wi-Fi BSSID scanning** (powered by Microsoft's geolocation database via Qualcomm/Skyhook) to automatically set the system timezone. When office access point BSSIDs are incorrectly mapped in that database to the wrong geographic coordinates, Windows silently flips the timezone — e.g., laptops in India suddenly switch to US Eastern Time.

**Root cause confirmed:**
- Windows exclusively uses Wi-Fi BSSID for automatic timezone — not NTP, not AD, not DHCP
- `GeoCoordinateWatcher` on affected machines returns wrong-country coordinates at <600m accuracy
- Every timezone change is logged as **Event ID 1** in the System log (`Microsoft-Windows-Kernel-General`)
- A Microsoft support ticket is the permanent fix, but this tool provides **immediate local remediation**

## Solution

A two-script PowerShell solution that:

1. **Detects** every timezone change via a Windows Scheduled Task (event-triggered)
2. **Verifies** the correct timezone for the machine's location using IP geolocation (`ipinfo.io`)
3. **Corrects** the timezone if it doesn't match, flushes the location cache, and logs everything

> **Works for any location worldwide** — not hardcoded to any specific timezone.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Windows Kernel                     │
│  Wi-Fi BSSID scan → wrong coordinates → wrong TZ     │
│  Logs Event ID 1 (Microsoft-Windows-Kernel-General)   │
└───────────────────────┬──────────────────────────────┘
                        │ triggers
                        ▼
┌──────────────────────────────────────────────────────┐
│              Scheduled Task (SYSTEM)                  │
│  Task: \Medpace\TimezoneRemediation                   │
│  Trigger: Event ID 1 from Kernel-General              │
│  Hidden, 2-min timeout, single instance               │
└───────────────────────┬──────────────────────────────┘
                        │ runs
                        ▼
┌──────────────────────────────────────────────────────┐
│              Fix-Timezone.ps1                         │
│                                                       │
│  1. GET ipinfo.io/json → IANA timezone                │
│  2. Map IANA → Windows TZ ID                          │
│  3. Current TZ == Correct TZ? → exit                  │
│  4. Mismatch? → tzutil /s, flush LfSvc, log          │
└──────────────────────────────────────────────────────┘
```

## Scripts

| Script | Purpose |
|--------|---------|
| `Fix-Timezone.ps1` | Remediation script — detects correct TZ via IP, fixes mismatches, clears LfSvc cache, logs to file and event log |
| `Register-TimezoneTask.ps1` | One-time installer — registers event log source, deploys script, creates Scheduled Task |

## Quick Start

### Prerequisites

- Windows 10 or Windows 11
- PowerShell 5.1 (built-in Windows PowerShell)
- Administrator privileges
- Internet connectivity (for `ipinfo.io` API)

### Installation

1. **Clone or download** both scripts to the same folder:
   ```
   Fix-Timezone.ps1
   Register-TimezoneTask.ps1
   ```

2. **Open PowerShell as Administrator**

3. **Run the installer:**
   ```powershell
   .\Register-TimezoneTask.ps1
   ```

4. **Done!** The task is now active and will auto-remediate on every timezone change.

### What the Installer Does

- Registers `TimezoneRemediation` as a Windows event log source
- Creates `C:\ProgramData\TimezoneRemediation\` and copies `Fix-Timezone.ps1` there
- Creates a hidden Scheduled Task under `\Medpace\` that:
  - Runs as **SYSTEM** with highest privileges
  - Triggers on **every timezone change** (Event ID 1)
  - Has a 2-minute execution time limit
  - Ignores duplicate triggers (single instance)

## Testing

### 1. Simulate a Timezone Flip

```powershell
# Set a wrong timezone (run as admin)
tzutil /s "Eastern Standard Time"

# Wait 5-10 seconds for the task to fire, then check:
tzutil /g
# Should show the correct timezone for your IP location
```

### 2. Check the Log File

```powershell
# Log location (when running as SYSTEM via Scheduled Task):
Get-Content "C:\Windows\Temp\Timezone_Logs\TimezoneRemediation-$(Get-Date -Format 'yyyyMMdd').log" -Tail 30

# Log location (when running manually as admin):
Get-Content "$env:TEMP\Timezone_Logs\TimezoneRemediation-$(Get-Date -Format 'yyyyMMdd').log" -Tail 30
```

### 3. Check the Event Log

```powershell
Get-EventLog -LogName Application -Source TimezoneRemediation -Newest 5 | Format-List
```

### 4. Verify the Scheduled Task

```powershell
Get-ScheduledTask -TaskPath "\Medpace\" -TaskName "TimezoneRemediation"
Get-ScheduledTaskInfo -TaskPath "\Medpace\" -TaskName "TimezoneRemediation"

# In Task Scheduler UI:
# taskschd.msc → navigate to Medpace folder
# (Task is hidden; toggle "Show Hidden Tasks" in View menu)
```

## Rollback / Uninstall

```powershell
# Run as administrator
Unregister-ScheduledTask -TaskPath "\Medpace\" -TaskName "TimezoneRemediation" -Confirm:$false
Remove-Item "C:\ProgramData\TimezoneRemediation" -Recurse -Force
Remove-EventLog -Source "TimezoneRemediation"
```

## Logging

Every script execution is logged to `%TEMP%\Timezone_Logs\`:

| Context | Log Location |
|---------|------|
| SYSTEM (Scheduled Task) | `C:\Windows\Temp\Timezone_Logs\` |
| Admin user (manual run) | `C:\Users\<user>\AppData\Local\Temp\Timezone_Logs\` |

**Log format:**
```
================================================================================
  TIMEZONE REMEDIATION SESSION — 2026-03-20 14:30:00
  Computer: LAPTOP-001 | User: SYSTEM | PID: 12345
================================================================================
[2026-03-20 14:30:00.123] [INFO   ] Script version 2.1 starting.
[2026-03-20 14:30:00.124] [INFO   ] Current system timezone: Eastern Standard Time
[2026-03-20 14:30:00.125] [INFO   ] Querying IP geolocation API: https://ipinfo.io/json
[2026-03-20 14:30:00.450] [SUCCESS] API call succeeded.
[2026-03-20 14:30:00.451] [INFO   ] Geolocation result: IP=203.0.113.1 | City=Mumbai | Country=IN | Timezone=Asia/Kolkata
[2026-03-20 14:30:00.452] [WARN   ] TIMEZONE MISMATCH DETECTED!
[2026-03-20 14:30:00.453] [WARN   ]   Current : Eastern Standard Time
[2026-03-20 14:30:00.454] [WARN   ]   Correct : India Standard Time (IANA: Asia/Kolkata)
[2026-03-20 14:30:00.500] [SUCCESS] Timezone set. Verified: India Standard Time
[2026-03-20 14:30:01.200] [SUCCESS] Deleted 3 cached file(s) from LfSvc cache.
[2026-03-20 14:30:01.500] [SUCCESS] === REMEDIATION COMPLETE ===
```

Log files rotate daily (one file per day: `TimezoneRemediation-YYYYMMDD.log`).

## Event Log IDs

| Event ID | Type | Description |
|----------|------|-------------|
| **100** | Information | Remediation succeeded — includes previous/new timezone, IP, city, country |
| **101** | Error | Script failed with an exception |
| **102** | Warning | API call failed or IANA timezone unmappable — no change made (safety) |

## How It Determines the Correct Timezone

1. Calls `ipinfo.io/json` — returns the IANA timezone based on the machine's **public IP address**
2. Maps the IANA timezone (e.g. `Asia/Kolkata`) to a Windows timezone ID (e.g. `India Standard Time`) using:
   - **Primary:** .NET `TimeZoneInfo.TryConvertIanaIdToWindowsId()` (available on newer Windows)
   - **Fallback:** Built-in lookup table with 60+ major IANA timezone mappings
3. **Safety:** If the API call fails or the IANA zone can't be mapped, the script does **nothing** and logs a warning

## Intune Deployment

Both scripts are designed for Microsoft Intune deployment:

1. Upload `Register-TimezoneTask.ps1` as an Intune **PowerShell script** (device configuration)
2. Configure: Run as SYSTEM, 64-bit PowerShell
3. The registration script will automatically deploy `Fix-Timezone.ps1` and set up the Scheduled Task

## Requirements

- Windows 10 / Windows 11
- PowerShell 5.1 (built-in)
- Administrator / SYSTEM privileges
- Internet access for `ipinfo.io` API
- No third-party modules or dependencies

## Files

```
├── Fix-Timezone.ps1            # Remediation script (deployed to ProgramData)
├── Register-TimezoneTask.ps1   # One-time installer / task registrator
├── FixTZRefresh.ps1            # Legacy remediation script (reference only)
└── README.md                   # This file
```

## License

Internal use — Medpace IT.
