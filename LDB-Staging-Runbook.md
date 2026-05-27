# LDB Staging — Laptop Deployment Runbook
**Last Updated:** 2026-05-27  
**Scope:** ~170 HP laptops, Windows 11, Autopilot + Intune only  
**Author:** IT Team (co-op onboarding reference)

---

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Autopilot Group Tag (LDB Staging)](#3-step-1--autopilot-group-tag)
4. [Step 2 — Azure AD Dynamic Device Group](#4-step-2--azure-ad-dynamic-device-group)
5. [Step 3 — Assign Group to Deployment Profile](#5-step-3--assign-group-to-deployment-profile)
6. [Step 4 — Create the LDB Staging ESP](#6-step-4--create-the-ldb-staging-esp)
7. [Step 5 — Assign Existing Config Profiles](#7-step-5--assign-existing-config-profiles)
8. [Step 6 — Assign Existing Apps](#8-step-6--assign-existing-apps)
9. [Step 7 — Win32 App: Partition Cleanup (NEW)](#9-step-7--win32-app-partition-cleanup-new)
10. [Step 8 — Win32 App: HPIA (NEW)](#10-step-8--win32-app-hpia-new)
11. [Step 9 — Production Transition (LDB Laptop)](#11-step-9--production-transition)
12. [Appendix A — Partition-Cleanup.ps1](#appendix-a--partition-cleanupps1)
13. [Appendix B — HPIA-Install.ps1](#appendix-b--hpia-installps1)
14. [Appendix C — Manual BIOS Update Procedure](#appendix-c--manual-bios-update-procedure)
15. [Appendix D — Log Locations Reference](#appendix-d--log-locations-reference)

---

## 1. Architecture Overview

```
HP Laptop boots → Autopilot OOBE
        │
        │  Group tag "LDB Staging" read at enrollment
        │
        ▼
Azure AD Dynamic Group: "LDB Staging"
  rule: (device.devicePhysicalIds -any _ -eq "[OrderID]:LDB Staging")
        │
        ├── Deployment Profile:  LDB | Laptops | Hybrid Join
        │
        ├── Config Profiles:     LDB | Windows | Domain Join | Laptops
        │                        LDB | Windows | Config | Skip User Status Page
        │
        └── ESP: LDB Staging (copied from LDB | Default ESP)
                    │
                    │  Blocks user login until all required apps complete
                    ▼
            Apps installed during ESP (Device Phase)
              ├── Microsoft 365 Apps Windows 10/11   (existing)
              ├── Uninstall Bloatware                (existing)
              ├── IT - Partition Cleanup             (NEW — this runbook)
              └── IT - HPIA Driver Update            (NEW — this runbook)
                    │
                    ▼
            User receives clean, updated, domain-joined laptop
```

### Key Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| EFI partition size | Accept 260 MB (factory) | 260 MB is Microsoft's standard. 499 MB requires CLEAN + WinPE — nothing is gained. |
| HP SR_AED / SR_IMAGE | Delete and reclaim | ~32 GB freed per device. Doable from running Windows via Intune. |
| Recovery partition | Leave as-is (factory) | Recreating it risks losing Windows RE for a cosmetic 10 MB difference. Not worth it. |
| BitLocker | Suspend for partition ops, auto-resume | New HPs may silently encrypt during OOBE. Script handles this defensively. |
| BIOS password | Not stored in Intune — manual follow-up | See Step 8 and Appendix C. |

### ⚠️ Hybrid Join Network Requirement

The `LDB | Laptops | Hybrid Join` profile performs an on-premises domain join during Autopilot. This requires **line-of-sight to a domain controller** during staging. Laptops must be staged on your corporate network (or a network with DC access). If staged on a guest or isolated network, the Domain Join config profile will fail and the device will get stuck in the ESP.

**Confirm your staging network has DC access before running the first device through.**

---

## 2. Prerequisites

Before starting, confirm you have:

- [ ] **Intune Admin** role (or equivalent) in the tenant
- [ ] **Autopilot device registration** access (or hardware hash CSVs ready to import)
- [ ] **IntuneWinAppUtil.exe** downloaded (Microsoft Win32 Content Prep Tool)
- [ ] Access to the existing **LDB | Default ESP** profile to copy settings from
- [ ] The two PowerShell scripts from this runbook saved locally (Appendices A and B)

---

## 3. Step 1 — Autopilot Group Tag

The group tag `LDB Staging` is stamped on each device's Autopilot hardware record. It is what triggers automatic group membership and drives every assignment downstream.

### If Importing Hardware Hashes via CSV

1. Ensure your CSV has a `Group Tag` column populated with `LDB Staging` for every device.
2. Go to **Intune > Devices > Windows > Windows Enrollment > Devices**.
3. Click **Import** and upload the CSV.
4. Devices appear in the Autopilot list within a few minutes.

### If Devices Are Already Registered (Tag Update)

1. Go to **Intune > Devices > Windows > Windows Enrollment > Devices**.
2. Find the device, select it.
3. Click the kebab menu **(···) > Change Group Tag**.
4. Set to `LDB Staging` and save.

---

## 4. Step 2 — Azure AD Dynamic Device Group

> **Per senior's instructions:** Create a dynamic group called `LDB Staging` with the exact syntax below.

1. Go to **Azure AD (Entra ID) > Groups > New Group**.
2. Set:
   - **Group type:** Security
   - **Group name:** `LDB Staging`
   - **Membership type:** Dynamic Device
3. Click **Add dynamic query** and enter:

```
(device.devicePhysicalIds -any _ -eq "[OrderID]:LDB Staging")
```

4. Validate the rule, then **Save** and create the group.

> When you later change a device's tag to `LDB Laptop`, it automatically drops out of this group. See Step 9.

---

## 5. Step 3 — Assign Group to Deployment Profile

> **Per senior's instructions:** Assign `LDB Staging` group to the existing profile `LDB | Laptops | Hybrid Join`.

1. Go to **Intune > Devices > Windows > Windows Enrollment > Deployment Profiles**.
2. Open **LDB | Laptops | Hybrid Join**.
3. Go to **Assignments**.
4. Under **Included groups**, click **+ Add groups**.
5. Search for and select `LDB Staging`.
6. Save.

This ensures that when a device with the `LDB Staging` tag enrolls, it uses this Autopilot profile (which configures Hybrid Azure AD Join, OOBE settings, etc.).

---

## 6. Step 4 — Create the LDB Staging ESP

> **Per senior's instructions:** Create a new ESP called `LDB Staging` by copying `LDB | Default ESP` settings, then add Microsoft 365 Apps Windows 10/11 and Uninstall Bloatware as blocking apps.

1. Go to **Intune > Devices > Windows > Windows Enrollment > Enrollment Status Page**.
2. Open **LDB | Default ESP**.
3. Note all current settings (take a screenshot or write them down).
4. Go back and click **+ Create profile**.
5. Name it: `LDB Staging`
6. Mirror all settings from `LDB | Default ESP`, then specifically confirm:
   - **Show app and profile configuration progress:** Yes
   - **Block device use until required apps are installed:** Yes
   - **Allow users to reset device if installation error occurs:** No
   - **Show error when installation takes longer than X minutes:** 120 *(HPIA can be slow)*

7. Under **Select required apps**, add all four:
   - Microsoft 365 Apps Windows 10/11
   - Uninstall Bloatware
   - IT - Partition Cleanup *(add after creating in Step 7)*
   - IT - HPIA Driver Update *(add after creating in Step 8)*

8. **Assignments:** Assign to `LDB Staging` group.

> **Why 120 minutes:** HPIA downloads drivers and potentially firmware updates over the internet during the ESP. On a slow connection or with many updates, this can take 30–60 minutes. 120 gives comfortable headroom without hanging indefinitely on a real failure.

---

## 7. Step 5 — Assign Existing Config Profiles

> **Per senior's instructions:** Add `LDB Staging` group to these two existing configuration profiles.

### LDB | Windows | Domain Join | Laptops

1. Go to **Intune > Devices > Configuration Profiles**.
2. Open **LDB | Windows | Domain Join | Laptops**.
3. Go to **Assignments > Included groups > + Add groups**.
4. Add `LDB Staging`. Save.

### LDB | Windows | Config | Skip User Status Page

1. Open **LDB | Windows | Config | Skip User Status Page**.
2. Go to **Assignments > Included groups > + Add groups**.
3. Add `LDB Staging`. Save.

---

## 8. Step 6 — Assign Existing Apps

> **Per senior's instructions:** Add `LDB Staging` group to these two existing apps.

### Microsoft 365 Apps Windows 10/11

1. Go to **Intune > Apps > Windows**.
2. Open **Microsoft 365 Apps Windows 10/11**.
3. Go to **Assignments**.
4. Under **Required**, click **+ Add group** and add `LDB Staging`. Save.

### Uninstall Bloatware

1. Open your **Uninstall Bloatware** Win32 app.
2. Go to **Assignments**.
3. Under **Required**, click **+ Add group** and add `LDB Staging`. Save.

---

## 9. Step 7 — Win32 App: Partition Cleanup (NEW)

This is a new app created specifically for this staging workflow. It removes HP's SR_AED and SR_IMAGE partitions (~32 GB reclaimed) and extends C: into that space.

### What This Script Does
- Suspends BitLocker on C: if active (new HPs may encrypt silently during OOBE)
- Finds and deletes partitions labelled `SR_AED` and `SR_IMAGE` by label — not hardcoded numbers, so it works on both 512 GB and 1 TB drives
- Extends C: to fill all unallocated space
- Resumes BitLocker
- Writes a registry key so Intune's detection rule sees it as installed
- Logs everything to `C:\ProgramData\IT\Logs\Partition-Cleanup.log`

### Package the Script

1. Save [Partition-Cleanup.ps1](#appendix-a--partition-cleanupps1) to a local folder, e.g. `C:\Packages\PartitionCleanup\`
2. Open Command Prompt and run:
```
IntuneWinAppUtil.exe -c "C:\Packages\PartitionCleanup" -s "Partition-Cleanup.ps1" -o "C:\Packages\Output"
```
3. This produces `Partition-Cleanup.intunewin` in your output folder.

### Upload to Intune

1. Go to **Intune > Apps > Windows > + Add > Windows app (Win32)**.
2. Upload `Partition-Cleanup.intunewin`.
3. App information:
   - **Name:** `IT - Partition Cleanup`
   - **Description:** Removes HP SR_AED and SR_IMAGE partitions, extends C: drive. Handles BitLocker.
   - **Publisher:** IT Department

4. Program settings:
   - **Install command:**
     ```
     powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "Partition-Cleanup.ps1"
     ```
   - **Uninstall command:** `cmd.exe /c exit 0`
   - **Run as:** System
   - **Device restart behaviour:** No specific action

5. Detection rule:
   - **Rule type:** Registry
   - **Key path:** `HKEY_LOCAL_MACHINE\SOFTWARE\IT\Deployment`
   - **Value name:** `PartitionCleanup`
   - **Detection method:** String comparison
   - **Value:** `Done`
   - **Associated with a 32-bit app on 64-bit clients:** No

6. Assignments: **Required** → `LDB Staging`

7. Go back to the **LDB Staging ESP** and add this app to the required apps list.

---

## 10. Step 8 — Win32 App: HPIA (NEW)

### Important: BIOS Updates and the Password Limitation

HPIA runs as SYSTEM with no interactive session — there is no screen to type a BIOS password into. If the laptop has a BIOS password set, HPIA will **silently skip BIOS updates** and log "BIOS password required." Everything else (drivers, firmware, software) installs normally.

**What HPIA installs automatically:** All drivers, firmware (non-BIOS), HP software components.  
**What requires manual follow-up:** BIOS updates — see [Appendix C](#appendix-c--manual-bios-update-procedure).

This does not block the user from getting their laptop.

### What This Script Does
- Downloads `HPImageAssistant.exe` from HP to `C:\ProgramData\IT\HPIA\`
- Runs HPIA silently with `/Selection:All` — installs everything it recommends
- Saves the HPIA HTML report to `C:\ProgramData\IT\Logs\HPIA\` (kept permanently)
- Schedules a task to delete `C:\ProgramData\IT\HPIA\` 48 hours after the script runs on that device (logs are preserved)
- Writes a registry detection key

> **Staggered rollout:** Each of your 170 laptops gets its own independent 48-hour cleanup clock. A device enrolled in week 1 and one enrolled in week 4 both work identically.

### Package the Script

1. Save [HPIA-Install.ps1](#appendix-b--hpia-installps1) to `C:\Packages\HPIA\`
2. Run:
```
IntuneWinAppUtil.exe -c "C:\Packages\HPIA" -s "HPIA-Install.ps1" -o "C:\Packages\Output"
```

### Upload to Intune

1. Go to **Intune > Apps > Windows > + Add > Windows app (Win32)**.
2. Upload `HPIA-Install.intunewin`.
3. App information:
   - **Name:** `IT - HPIA Driver Update`
   - **Description:** Downloads HP Image Assistant and installs all recommended drivers, firmware, and software updates. BIOS updates require manual follow-up (see runbook Appendix C).
   - **Publisher:** HP / IT Department

4. Program settings:
   - **Install command:**
     ```
     powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "HPIA-Install.ps1"
     ```
   - **Uninstall command:** `cmd.exe /c exit 0`
   - **Run as:** System
   - **Device restart behaviour:** Intune management extension handles restart
   - **Return codes:** 0 = Success, 1641 = Success (reboot), 3010 = Soft reboot

5. Detection rule:
   - **Rule type:** Registry
   - **Key path:** `HKEY_LOCAL_MACHINE\SOFTWARE\IT\Deployment`
   - **Value name:** `HPIA`
   - **Detection method:** String comparison
   - **Value:** `Done`
   - **Associated with a 32-bit app on 64-bit clients:** No

6. Requirements: OS architecture: 64-bit, Minimum OS: Windows 11

7. Assignments: **Required** → `LDB Staging`

8. Go back to the **LDB Staging ESP** and add this app to the required apps list.

---

## 11. Step 9 — Production Transition

When a device finishes staging and is ready for a user, change its Autopilot group tag from `LDB Staging` to `LDB Laptop`.

### What Happens Automatically

Because the dynamic group uses the `[OrderID]` rule:

1. Device **leaves** `LDB Staging` group
2. Device **joins** your production `LDB Laptop` group (assuming that group exists with a matching rule)
3. LDB Staging app assignments stop applying
4. Production policies and apps begin applying

The staging apps (Partition Cleanup, Bloatware Removal, HPIA) **will not re-run** — their registry detection keys are already present. Intune sees them as satisfied.

### How to Change the Tag

**Via Intune Portal (per device):**
1. **Intune > Devices > Windows > Windows Enrollment > Devices**
2. Find device by serial number
3. Kebab menu **(···) > Change Group Tag**
4. Change `LDB Staging` → `LDB Laptop`
5. Save. Group membership updates within ~5 minutes.

**Via PowerShell (bulk):**
```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"

$devices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
    Where-Object { $_.GroupTag -eq "LDB Staging" }

foreach ($device in $devices) {
    Update-MgDeviceManagementWindowsAutopilotDeviceIdentity `
        -WindowsAutopilotDeviceIdentityId $device.Id `
        -BodyParameter @{ groupTag = "LDB Laptop" }
    Write-Host "Updated: $($device.SerialNumber)"
}
```

> Transition devices one at a time as they finish staging — not all at once.

---

## Appendix A — Partition-Cleanup.ps1

```powershell
# ============================================================
# Partition-Cleanup.ps1
# Removes HP SR_AED and SR_IMAGE partitions, extends C:
# Handles BitLocker suspension and resumption
# Logs: C:\ProgramData\IT\Logs\Partition-Cleanup.log
# Detection: HKLM:\SOFTWARE\IT\Deployment > PartitionCleanup = Done
# ============================================================

$LogDir  = "C:\ProgramData\IT\Logs"
$LogFile = "$LogDir\Partition-Cleanup.log"
$RegPath = "HKLM:\SOFTWARE\IT\Deployment"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

Write-Log "=== Partition Cleanup Started ==="
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# --- Idempotency check ---
if (Test-Path $RegPath) {
    $existing = Get-ItemProperty -Path $RegPath -Name "PartitionCleanup" -ErrorAction SilentlyContinue
    if ($existing -and $existing.PartitionCleanup -eq "Done") {
        Write-Log "Already completed on a previous run. Exiting cleanly."
        exit 0
    }
}

# --- BitLocker: suspend if active ---
$bitlockerSuspended = $false
try {
    $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($bl -and $bl.ProtectionStatus -eq "On") {
        Write-Log "BitLocker is ON — suspending for disk operations."
        Suspend-BitLocker -MountPoint "C:" -RebootCount 0
        $bitlockerSuspended = $true
    } elseif ($bl) {
        Write-Log "BitLocker status: $($bl.ProtectionStatus) — no suspension needed."
    } else {
        Write-Log "BitLocker not detected on C:."
    }
} catch {
    Write-Log "WARNING: BitLocker check/suspend failed: $_"
}

# --- Delete SR_AED and SR_IMAGE by label ---
$targets = @("SR_AED", "SR_IMAGE")
$deleted = @()

try {
    $partitions = Get-Partition -DiskNumber 0 -ErrorAction Stop
    foreach ($p in $partitions) {
        $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        if ($vol -and $targets -contains $vol.FileSystemLabel) {
            $sizeGB = [math]::Round($p.Size / 1GB, 2)
            Write-Log "Deleting: $($vol.FileSystemLabel) — Partition $($p.PartitionNumber) — $sizeGB GB"
            try {
                Remove-Partition -DiskNumber 0 -PartitionNumber $p.PartitionNumber -Confirm:$false
                Write-Log "Deleted: $($vol.FileSystemLabel)"
                $deleted += $vol.FileSystemLabel
            } catch {
                Write-Log "ERROR deleting $($vol.FileSystemLabel): $_"
            }
        }
    }
    if ($deleted.Count -eq 0) {
        Write-Log "No SR_AED or SR_IMAGE found — disk may already be clean."
    } else {
        Write-Log "Deleted partitions: $($deleted -join ', ')"
    }
} catch {
    Write-Log "ERROR reading partition table: $_"
    if ($bitlockerSuspended) {
        try { Resume-BitLocker -MountPoint "C:" } catch {}
    }
    exit 1
}

# --- Extend C: into reclaimed space ---
try {
    $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    $currentSize = (Get-Partition -DriveLetter C).Size
    $currentGB = [math]::Round($currentSize / 1GB, 2)
    $maxGB = [math]::Round($supported.SizeMax / 1GB, 2)

    if ($supported.SizeMax -gt $currentSize) {
        Write-Log "Extending C: from $currentGB GB to $maxGB GB"
        Resize-Partition -DriveLetter C -Size $supported.SizeMax
        Write-Log "C: extended successfully."
    } else {
        Write-Log "C: already at maximum size ($currentGB GB). No extension needed."
    }
} catch {
    Write-Log "ERROR extending C: partition: $_"
}

# --- Resume BitLocker ---
if ($bitlockerSuspended) {
    try {
        Resume-BitLocker -MountPoint "C:"
        Write-Log "BitLocker resumed."
    } catch {
        Write-Log "WARNING: Failed to resume BitLocker: $_"
    }
}

# --- Write detection registry key ---
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name "PartitionCleanup" -Value "Done" -Type String
    Write-Log "Detection key written: $RegPath\PartitionCleanup = Done"
} catch {
    Write-Log "WARNING: Could not write registry detection key: $_"
}

Write-Log "=== Partition Cleanup Complete ==="
exit 0
```

---

## Appendix B — HPIA-Install.ps1

> **Before deploying:** Verify HP's HPIA URL is still active by opening `https://ftp.hp.com/pub/caps-softpaq/cmit/HPImageAssistant.exe` in a browser. If the URL has changed, update `$HPIAUrl` below.

```powershell
# ============================================================
# HPIA-Install.ps1
# Downloads HP Image Assistant, runs full update (all categories)
# BIOS updates requiring a password are skipped silently by HPIA.
# Working files deleted 48 hours after script runs (per device).
# Logs preserved permanently at C:\ProgramData\IT\Logs\HPIA\
# Detection: HKLM:\SOFTWARE\IT\Deployment > HPIA = Done
# ============================================================

$WorkDir   = "C:\ProgramData\IT\HPIA"
$LogDir    = "C:\ProgramData\IT\Logs\HPIA"
$HPIAUrl   = "https://ftp.hp.com/pub/caps-softpaq/cmit/HPImageAssistant.exe"
$HPIAExe   = "$WorkDir\HPImageAssistant.exe"
$RegPath   = "HKLM:\SOFTWARE\IT\Deployment"
$DeployLog = "$LogDir\HPIA-Deploy.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Out-File -FilePath $DeployLog -Append -Encoding UTF8
}

foreach ($dir in @($WorkDir, $LogDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Write-Log "=== HPIA Deployment Started ==="
Write-Log "Device: $env:COMPUTERNAME"
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# --- Download HPIA ---
try {
    Write-Log "Downloading HPIA from: $HPIAUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($HPIAUrl, $HPIAExe)
    $fileSize = [math]::Round((Get-Item $HPIAExe).Length / 1MB, 2)
    Write-Log "Download complete. Size: $fileSize MB"
} catch {
    Write-Log "ERROR: Download failed — $_"
    exit 1
}

# --- Run HPIA ---
# /Selection:All   = all categories (drivers, firmware, BIOS, software)
# /Silent          = no UI
# /ReportFolder    = saves HTML report to log directory
# /RebootCount:1   = allow 1 automatic reboot if required (e.g. firmware)
#
# NOTE: BIOS updates requiring a password will be skipped silently.
# HPIA logs "BIOS password required" and continues. See Appendix C.

try {
    $hpiaArgs = '/Operation:Analyze /Action:Install /Selection:All /Silent' +
                " /ReportFolder:`"$LogDir`" /RebootCount:1"
    Write-Log "Starting HPIA with args: $hpiaArgs"
    $proc = Start-Process -FilePath $HPIAExe -ArgumentList $hpiaArgs -Wait -PassThru
    $exit = $proc.ExitCode
    Write-Log "HPIA exit code: $exit"

    switch ($exit) {
        0       { Write-Log "HPIA: No updates needed or already current." }
        1       { Write-Log "HPIA: Updates installed successfully." }
        2       { Write-Log "HPIA: Updates installed. Reboot initiated." }
        3       { Write-Log "HPIA: Device already up to date." }
        default { Write-Log "HPIA: Exit code $exit — check HTML report in $LogDir" }
    }
} catch {
    Write-Log "ERROR: HPIA execution failed — $_"
    exit 1
}

# --- Schedule 48-hour cleanup of working files ---
# Deletes: $WorkDir (exe + temp files)
# Preserves: $LogDir (HTML reports — kept permanently)
$cleanupScript = @"
Remove-Item -Path '$WorkDir' -Recurse -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'IT-HPIA-Cleanup' -Confirm:`$false -ErrorAction SilentlyContinue
"@

try {
    $encoded     = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupScript))
    $triggerTime = (Get-Date).AddHours(48)
    $action      = New-ScheduledTaskAction -Execute "powershell.exe" `
                       -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
    $trigger     = New-ScheduledTaskTrigger -Once -At $triggerTime
    $settings    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                       -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 5)
    $principal   = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

    Register-ScheduledTask -TaskName "IT-HPIA-Cleanup" -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log "Cleanup task scheduled for: $($triggerTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "Will delete: $WorkDir"
    Write-Log "Will preserve: $LogDir"
} catch {
    Write-Log "WARNING: Could not register cleanup task: $_ (files will remain until manually deleted)"
}

# --- Write detection registry key ---
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name "HPIA" -Value "Done" -Type String
    Write-Log "Detection key written: $RegPath\HPIA = Done"
} catch {
    Write-Log "WARNING: Could not write registry detection key: $_"
}

Write-Log "=== HPIA Deployment Complete ==="
exit 0
```

---

## Appendix C — Manual BIOS Update Procedure

After staging, check `C:\ProgramData\IT\Logs\HPIA\` on each device. Open the HTML report in a browser and look for any items marked "Skipped — BIOS password required."

**To apply the BIOS update manually:**

1. Log into the laptop with an admin account.
2. If the 48-hour cleanup has not yet run, HPIA is still at `C:\ProgramData\IT\HPIA\HPImageAssistant.exe` — run it directly.
3. If the cleanup has already run, re-download HPIA from `https://ftp.hp.com/pub/caps-softpaq/cmit/HPImageAssistant.exe`.
4. Run HPIA interactively (double-click). It will present the recommended BIOS update.
5. When prompted for the BIOS password, enter it.
6. Allow the reboot.

This can be done as a batch across all 170 devices during a quiet period after users have received their laptops — it does not need to happen during staging.

---

## Appendix D — Log Locations Reference

| Log | Path | Retention |
|---|---|---|
| Partition cleanup | `C:\ProgramData\IT\Logs\Partition-Cleanup.log` | Permanent |
| HPIA deployment log | `C:\ProgramData\IT\Logs\HPIA\HPIA-Deploy.log` | Permanent |
| HPIA update report | `C:\ProgramData\IT\Logs\HPIA\*.html` | Permanent |
| HPIA working files | `C:\ProgramData\IT\HPIA\` | Auto-deleted 48 hrs after script runs |

The 48-hour cleanup only removes `C:\ProgramData\IT\HPIA\`. The `Logs\` tree is never touched by the cleanup task.

---

*End of runbook*
