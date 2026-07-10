<#
.SYNOPSIS
    Removes the HP OEM partitions (SR_AED, SR_IMAGE) and the factory Recovery
    partition, extends C: into the freed space, and creates a fresh 2 GB
    Windows Recovery partition -- re-registering WinRE and protecting BitLocker
    around the operation.

.DESCRIPTION
    Target factory layout:
        1 EFI | 2 MSR | 3 Windows (C:) | 4 Recovery | 5 SR_AED | 6 SR_IMAGE
    Resulting layout:
        1 EFI | 2 MSR | 3 Windows (C:, extended) | 4 Recovery (2 GB, new)

    Execution model: Intune Win32 app, run as SYSTEM, in 64-bit Windows
    PowerShell 5.1. No PowerShell 7+ only syntax is used.

    Detection rule (Intune):
        HKLM:\SOFTWARE\IT\Deployment  |  PartitionCleanup = Done   (REG_SZ)

    Install command (MUST force 64-bit via SysNative):
        %SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe
        -ExecutionPolicy Bypass -NonInteractive -File partition-cleanup.ps1

.NOTES
    VERSION : 1.3.0   (2026-07-09)   -- keep in sync with the Intune app version.
                                        Logged at runtime (see $ScriptVersion).

    CHANGE LOG  (newest first)
      1.3.0  2026-07-09  WinRE now lands on the DEDICATED Recovery partition, not
                         C:. Root cause: /setreimage pointed at C:\Windows\System32\
                         Recovery, so reagentc kept WinRE in C:\Recovery\WindowsRE
                         (partition empty). Step 6 now mounts the new partition,
                         places winre.wim + \Recovery\WindowsRE on it, /setreimage
                         at THAT folder, then /enable while mounted, then unmounts,
                         then drops the C: staging copy. Best-effort: worst case is
                         the same C: fallback. (Per MS/Wikibooks WinRE placement.)
      1.2.2  2026-07-09  New Recovery partition size 1.5 GB -> 2 GB for extra WinRE
                         headroom (Winre.wim observed at ~903 MB; no downside beyond
                         ~500 MB more of C:).
      1.2.1  2026-07-09  Register the staged image before enabling: Step 6 now runs
                         'reagentc /setreimage /path <...\System32\Recovery>' before
                         '/enable'. reagentc /enable uses the WinRE config, not a
                         folder scan, so the copied winre.wim (v1.2.0) was present
                         but unregistered -> exit 1614. /setreimage registers it.
                         (Confirmed against Microsoft REAgentC docs.)
      1.2.0  2026-07-09  WinRE preservation now COPIES winre.wim off the factory
                         Recovery partition to C:\Windows\System32\Recovery before
                         deletion (reagentc /enable then moves it onto the new
                         partition and consumes the C: copy -- no leftover), fixing
                         units where reagentc /disable returns 0 without staging the
                         image. New Recovery partition size 999 MB -> 1.5 GB for
                         WinRE-update headroom. Still best-effort: any staging or
                         /enable failure logs a WARNING and the run still succeeds.
      1.1.2  2026-07-09  WinRE re-registration is now fully best-effort -- a failed
                         reagentc /enable no longer fails the run (the partition
                         work is already complete and verified). Added a 5s settle
                         after /disable. Root cause seen on some Win11 24H2 units:
                         /disable returns 0 but does NOT stage winre.wim to C:, so
                         /enable can't find it (exit 1614); now logged as a WARNING
                         and the run still succeeds.
      1.1.1  2026-07-09  Fix false abort in Step 1: when reagentc /disable
                         succeeds (exit 0) we now trust that as the WinRE-image
                         preservation signal instead of Test-Path'ing a fixed
                         location -- C:\Windows\System32\Recovery is protected and
                         Test-Path can read false there even after a successful
                         disable, which was aborting on factory-fresh units with
                         WinRE enabled. Step 6 /enable remains the real check.
      1.1.0  2026-07-09  WinRE handling is now best-effort: proceeds on a device
                         with no WinRE to preserve, still hard-stops if a live
                         WinRE cannot be captured. Storage-cache settle added after
                         diskpart deletes. Recovery created by consuming the
                         reserved tail (no fixed SIZE=). Logger writes via
                         [Console]. PSScriptAnalyzer-clean (0 findings).
      1.0.0  2026-07-06  First hardware-test build: Recovery GPT type GUID
                         corrected (bfa5 -> bfd5); removes SR_AED / SR_IMAGE +
                         factory Recovery, extends C:, rebuilds a 999 MB Recovery;
                         BitLocker suspend/resume; WinRE preserve via reagentc;
                         C:-on-disk-0 + GPT safety guards; detection key written
                         only after all steps verify; Windows PowerShell 5.1
                         hardening.

    SAFETY DESIGN
    - Confirms C: physically lives on the target disk before ANY destructive
      diskpart call, so the wrong disk can never be wiped.
    - Suspends BitLocker before the destructive partition steps and resumes it
      once they complete, with a try/finally backstop so protection is ALWAYS
      restored even on failure -- a resize can never leave the device demanding a
      recovery key at boot.
    - WinRE handling is BEST-EFFORT and never fails the run. The factory winre.wim
      is copied off the old Recovery partition before deletion (Step 1); after the
      new partition is built, Step 6 mounts it, places the image + \Recovery\
      WindowsRE on it, points reagentc /setreimage there, and /enable -- so WinRE
      lands on the DEDICATED partition (not C:). If any sub-step or /enable fails,
      the worst case is reagentc's own C:\Recovery\WindowsRE fallback (WinRE still
      works); it's logged as a WARNING and the run still succeeds. See CHANGE LOG.
    - The detection key is written LAST, only after the partition work (delete /
      extend / recreate) verifies success. WinRE re-registration is best-effort and
      does NOT gate the key. Any earlier failure exits non-zero with the key
      absent, so Intune/ESP reports failure correctly.
    - Idempotent: a completed device is detected and skipped; a partially
      completed device converges on re-run.

    POWERSHELL 5.1 NOTE
    - This script deliberately avoids calling `exit` inside a try/finally (its
      interaction with finally is not guaranteed across hosts). The destructive
      region throws on failure, is caught, cleanup runs in finally, and the
      single exit point is reached afterward based on a $succeeded flag.
#>

# -- Config --------------------------------------------------------------------
$ScriptVersion = "1.3.0"                                  # keep in sync with the .NOTES CHANGE LOG
$LogDir       = "C:\ProgramData\IT\Logs"
$LogFile      = "$LogDir\Partition-Cleanup.log"
$RegPath      = "HKLM:\SOFTWARE\IT\Deployment"
$RegName      = "PartitionCleanup"
$Disk         = 0
$RecoveryMB   = 2048                                     # 2 GB -- generous headroom for future WinRE updates (avoids the 0x80070643 "partition too small" failures)
$RecoveryGuid = "de94bba4-06d1-4d40-a16a-bfd50179d6ac"   # Windows RE partition TYPE GUID
$OemLabels    = @("SR_AED", "SR_IMAGE")
$WinreWim     = Join-Path $env:SystemRoot "System32\Recovery\Winre.wim"
$WinreDir     = Split-Path -Parent $WinreWim              # ...\System32\Recovery -- /setreimage /path target

# -- Logging -------------------------------------------------------------------
function Write-CleanupLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Console echo is intentional (reaches Intune stdout) and must stay OFF the success stream so it cannot pollute the return value of any function that logs. Do not change to Write-Output.')]
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts  [$Level]  $Message"
    try { $line | Out-File -FilePath $LogFile -Append -Encoding UTF8 } catch { $null = $_ }
    # Console (not Write-Output) so log lines reach Intune stdout without
    # polluting the return value of any function that logs.
    [Console]::WriteLine($line)
}

# -- Diskpart helper (temp-file form -- more reliable than piping as SYSTEM) ----
function Invoke-Diskpart {
    param([string]$Script)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $Script | Set-Content -Path $tmp -Encoding ASCII
        $output = & diskpart.exe /s $tmp 2>&1
        $code   = $LASTEXITCODE
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($output -join " | ") }
}

# -- WinRE image stager --------------------------------------------------------
# Copies winre.wim off a (hidden) Recovery partition to C:'s standard recovery
# folder ($DestFile), from where reagentc /enable later MOVES it onto the new
# Recovery partition (removing the C: copy -- no leftover). Best-effort: returns
# $true only if the copy reports success; always unmounts the temporary letter.
function Copy-WinreImageFromPartition {
    param($Partition, [string]$DestFile)
    $mount = $null
    try {
        $used   = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
        $letter = (90..68 | ForEach-Object { [char]$_ } | Where-Object { $used -notcontains $_ } | Select-Object -First 1)   # Z..D
        if (-not $letter) { Write-CleanupLog "No free drive letter to mount the Recovery partition." -Level "WARN"; return $false }

        Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$($letter):\" -ErrorAction Stop
        $mount = "$($letter):"
        Start-Sleep -Milliseconds 500

        $src = Get-ChildItem -Path "$mount\" -Recurse -Filter "winre.wim" -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $src) { Write-CleanupLog "winre.wim not found on the Recovery partition (mounted $mount)." -Level "WARN"; return $false }
        Write-CleanupLog "Found factory WinRE image: $($src.FullName) ($([math]::Round($src.Length/1MB))MB)."

        $destDir = Split-Path -Parent $DestFile
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        # robocopy /B uses backup semantics so it can read the ACL-protected WindowsRE folder.
        & robocopy.exe $src.DirectoryName $destDir $src.Name /B /R:1 /W:1 /NJH /NJS /NP /NFL /NDL | Out-Null
        $rc = $LASTEXITCODE
        Write-CleanupLog "robocopy winre.wim -> $destDir (exit=$rc; <8 means success)."
        return ($rc -lt 8)
    } catch {
        Write-CleanupLog "Staging winre.wim failed: $_" -Level "WARN"
        return $false
    } finally {
        if ($mount) {
            try {
                Remove-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$mount\" -ErrorAction Stop
                Write-CleanupLog "Unmounted temporary Recovery access path $mount."
            } catch {
                Write-CleanupLog "Could not remove temp mount $mount ($_); harmless -- partition delete uses OVERRIDE." -Level "WARN"
            }
        }
    }
}

# -- Detection-key writer ------------------------------------------------------
function Write-DetectionKey {
    param([string]$Value)
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    New-ItemProperty -Path $RegPath -Name $RegName -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
}

# -- Init ----------------------------------------------------------------------
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

Write-CleanupLog "===== Partition Cleanup Started ====="
Write-CleanupLog "Script ver   : $ScriptVersion"
Write-CleanupLog "User context : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-CleanupLog "PowerShell   : $([IntPtr]::Size * 8)-bit v$($PSVersionTable.PSVersion)"

# 64-bit guard -- Storage/BitLocker cmdlets and diskpart must run 64-bit on x64.
# Intune should invoke this via SysNative; if it did not, stop rather than act
# on a redirected/mis-scoped view of the disk.
if ([IntPtr]::Size -ne 8) {
    Write-CleanupLog "Running as 32-bit PowerShell. Fix the install command to use SysNative. Aborting." -Level "ERROR"
    exit 1
}

# -- Idempotency check ---------------------------------------------------------
# Both OEM partitions gone AND detection key present => a previous run fully
# succeeded (the key is only ever written after WinRE verifies).
$presentLabels = @()
foreach ($p in (Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue)) {
    $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystemLabel) { $presentLabels += $v.FileSystemLabel }
}
$oemGone = $true
foreach ($lbl in $OemLabels) { if ($presentLabels -contains $lbl) { $oemGone = $false } }

if ($oemGone) {
    $regVal = Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction SilentlyContinue
    if ($regVal.$RegName -eq "Done") {
        Write-CleanupLog "OEM partitions already removed and detection key present -- nothing to do."
        exit 0
    }
    Write-CleanupLog "OEM partitions already gone but detection key absent -- will converge remaining steps." -Level "WARN"
}

# -- Safety guard: confirm C: lives on the target disk AND the disk is GPT ------
try {
    $sysPart = Get-Partition -DriveLetter C -ErrorAction Stop
    if ($sysPart.DiskNumber -ne $Disk) {
        Write-CleanupLog "C: is on disk $($sysPart.DiskNumber), not target disk $Disk. Refusing to run." -Level "ERROR"
        exit 1
    }
    $targetDisk = Get-Disk -Number $Disk -ErrorAction Stop
    if ($targetDisk.PartitionStyle -ne 'GPT') {
        Write-CleanupLog "Disk $Disk is $($targetDisk.PartitionStyle), not GPT. This script only supports UEFI/GPT. Aborting." -Level "ERROR"
        exit 1
    }
    Write-CleanupLog "Confirmed C: is on GPT disk $Disk (partition #$($sysPart.PartitionNumber))."
} catch {
    Write-CleanupLog "Could not resolve/validate the disk hosting C:: $_" -Level "ERROR"
    exit 1
}

# ==============================================================================
# DESTRUCTIVE REGION
# Wrapped so BitLocker is ALWAYS resumed (finally) even on failure, and so the
# detection key is only written after every step verifies. No `exit` occurs
# inside this try -- failures throw, are caught, and the single exit point is
# reached after cleanup (PowerShell 5.1-safe).
# ==============================================================================
$succeeded          = $false
$bitlockerSuspended = $false
$haveWinreImage     = $false   # set in Step 1: was there a WinRE image to preserve/re-register?

try {
    # NB: we deliberately do NOT set $ErrorActionPreference = 'Stop' here. Under
    # 'Stop', a native command using 2>&1 (diskpart/reagentc below) throws a
    # NativeCommandError as soon as it writes to stderr -- which both tools do on
    # ordinary runs -- and would abort spuriously on PowerShell 5.1. Instead,
    # every critical cmdlet carries explicit -ErrorAction Stop and every
    # verification is an explicit throw, so real failures still land in catch.

    # -- Step 0: Suspend BitLocker on C: (only if protection is actually on) ----
    Write-CleanupLog "--- Step 0: BitLocker ---"
    $blv = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
    Write-CleanupLog "BitLocker C: ProtectionStatus=$($blv.ProtectionStatus) VolumeStatus=$($blv.VolumeStatus)"
    if ($blv.ProtectionStatus -eq 'On') {
        Suspend-BitLocker -MountPoint "C:" -RebootCount 1 -ErrorAction Stop | Out-Null
        $bitlockerSuspended = $true
        Write-CleanupLog "BitLocker protection suspended on C: (also auto-resumes after next reboot as a safety net)."
    } else {
        Write-CleanupLog "BitLocker protection not On -- nothing to suspend."
    }

    # -- Step 1: Preserve WinRE (stage winre.wim onto C:) BEFORE deleting Recovery
    # Goal: guarantee a WinRE image sits in C:'s standard recovery folder, from
    # where Step 6's reagentc /enable moves it onto the NEW Recovery partition.
    #   1. reagentc /disable deactivates WinRE (on many units it also stages the
    #      image to C:; some Win11 24H2 units return 0 but do NOT stage it).
    #   2. If the image is not on C:, copy it off the factory Recovery partition
    #      ourselves while that partition still exists (best-effort).
    # reagentc /enable (Step 6) is the real verification; nothing here is fatal.
    Write-CleanupLog "--- Step 1: Preserve WinRE ---"

    # Capture the factory Recovery partition (WinRE source) before disable/delete.
    $recoveryPart = Get-Partition -DiskNumber $Disk | Where-Object { $_.Type -eq 'Recovery' } | Select-Object -First 1

    $dis     = & reagentc.exe /disable 2>&1
    $disCode = $LASTEXITCODE
    Write-CleanupLog "reagentc /disable exit=$disCode : $($dis -join ' | ')"

    # NB: Test-Path can read false on the protected Recovery folder even when the
    # image is present; that only makes us do a harmless redundant copy attempt.
    $haveWinreImage = Test-Path $WinreWim
    if ($haveWinreImage) {
        Write-CleanupLog "WinRE image already staged at $WinreWim."
    } elseif ($recoveryPart) {
        Write-CleanupLog "WinRE image not staged on C: -- copying it off the factory Recovery partition (#$($recoveryPart.PartitionNumber))."
        $haveWinreImage = Copy-WinreImageFromPartition -Partition $recoveryPart -DestFile $WinreWim
    } else {
        Write-CleanupLog "No factory Recovery partition present to stage WinRE from." -Level "WARN"
    }

    if ($haveWinreImage) {
        Write-CleanupLog "WinRE image is staged for re-registration onto the new Recovery partition (Step 6)."
    } else {
        Write-CleanupLog "No WinRE image could be staged -- the new Recovery partition may end up empty; best-effort re-enable at Step 6." -Level "WARN"
    }

    # Brief settle before Step 2 deletes the (now unmounted) source partition.
    Start-Sleep -Seconds 2

    # -- Step 2: Remove factory Recovery partition(s) --------------------------
    # WHY DISKPART: hidden/required GPT partitions cannot be removed by
    # Remove-Partition; diskpart DELETE PARTITION OVERRIDE is required. Loop +
    # re-query is robust to any partition renumbering between deletions.
    Write-CleanupLog "--- Step 2: Remove factory Recovery partition(s) ---"
    $guard = 0
    while ($true) {
        $rp = Get-Partition -DiskNumber $Disk | Where-Object { $_.Type -eq 'Recovery' } | Select-Object -First 1
        if (-not $rp) { if ($guard -eq 0) { Write-CleanupLog "No Recovery-type partition present." }; break }
        $guard++
        if ($guard -gt 8) { throw "Recovery partition deletion not converging." }
        Write-CleanupLog "Deleting Recovery #$($rp.PartitionNumber) ($([math]::Round($rp.Size/1MB))MB) via diskpart."
        $dp = Invoke-Diskpart -Script @"
SELECT DISK=$Disk
SELECT PARTITION=$($rp.PartitionNumber)
DELETE PARTITION OVERRIDE
"@
        Write-CleanupLog "diskpart (exit=$($dp.ExitCode)): $($dp.Output)"
        Start-Sleep -Milliseconds 500
        try { Update-HostStorageCache } catch { $null = $_ }
    }

    # -- Step 3: Remove HP OEM partitions by label (SR_AED, SR_IMAGE) ----------
    # These are plain Basic Data partitions -- identified by label, not type.
    # Re-query per iteration so we always act on the current correct partition.
    Write-CleanupLog "--- Step 3: Remove HP OEM partitions ($($OemLabels -join ', ')) ---"
    foreach ($label in $OemLabels) {
        $guard = 0
        while ($true) {
            $target = $null
            foreach ($p in (Get-Partition -DiskNumber $Disk)) {
                $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
                if ($v -and $v.FileSystemLabel -eq $label) { $target = $p; break }
            }
            if (-not $target) { if ($guard -eq 0) { Write-CleanupLog "No partition labelled '$label' -- already absent." }; break }
            $guard++
            if ($guard -gt 8) { throw "Deletion of '$label' not converging." }

            Write-CleanupLog "Deleting #$($target.PartitionNumber) '$label' ($([math]::Round($target.Size/1MB))MB)."
            try {
                Remove-Partition -DiskNumber $Disk -PartitionNumber $target.PartitionNumber -Confirm:$false -ErrorAction Stop
                Write-CleanupLog "Removed '$label' via Remove-Partition."
            } catch {
                Write-CleanupLog "Remove-Partition failed ($_) -- diskpart fallback." -Level "WARN"
                $dp = Invoke-Diskpart -Script @"
SELECT DISK=$Disk
SELECT PARTITION=$($target.PartitionNumber)
DELETE PARTITION OVERRIDE
"@
                Write-CleanupLog "diskpart fallback (exit=$($dp.ExitCode)): $($dp.Output)"
            }
            Start-Sleep -Milliseconds 500
            try { Update-HostStorageCache } catch { $null = $_ }
        }
    }

    # Refresh the Storage view so space freed by diskpart deletes is visible to
    # Get-PartitionSupportedSize below (diskpart changes can lag the CIM cache).
    $dp = Invoke-Diskpart -Script "RESCAN"
    Write-CleanupLog "diskpart RESCAN (exit=$($dp.ExitCode)): $($dp.Output)"
    try { Update-HostStorageCache } catch { Write-CleanupLog "Update-HostStorageCache unavailable: $_" -Level "WARN" }

    # -- Step 4: Extend C: into freed space, reserving space for new Recovery ---
    # WHY NOT SizeMax: SizeMax consumes every free byte. We must leave exactly
    # $RecoveryMB MB at the end of the disk for Step 5.
    Write-CleanupLog "--- Step 4: Extend C: (reserving $RecoveryMB MB for Recovery) ---"
    $supported    = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    $curSize      = [int64](Get-Partition -DriveLetter C).Size
    $reserveBytes = [int64]$RecoveryMB * 1MB
    $newSize      = [int64]$supported.SizeMax - $reserveBytes
    Write-CleanupLog ("Current C: {0:N2} GB | Max {1:N2} GB | Reserve {2} MB | Target {3:N2} GB" -f ($curSize/1GB), ([int64]$supported.SizeMax/1GB), $RecoveryMB, ($newSize/1GB))

    if ($newSize -le $curSize) {
        Write-CleanupLog "C: already at/above target size -- skipping resize (already extended)."
    } elseif ($newSize -lt [int64]$supported.SizeMin) {
        throw "Computed C: size ($newSize) is below minimum supported ($([int64]$supported.SizeMin))."
    } else {
        Resize-Partition -DriveLetter C -Size $newSize -ErrorAction Stop
        Write-CleanupLog "C: extended to $([math]::Round($newSize/1GB,2)) GB."
    }

    # -- Step 5: Create the new Recovery partition (diskpart for GPT type+attrs)-
    # WHY DISKPART: PowerShell 5.1 has no cmdlet to set the GPT partition TYPE
    # GUID and the hidden/required attributes. Skipped if one already exists
    # (converge case).
    Write-CleanupLog "--- Step 5: Create new Recovery partition ---"
    $existing = Get-Partition -DiskNumber $Disk | Where-Object { $_.Type -eq 'Recovery' } | Select-Object -First 1
    if ($existing) {
        Write-CleanupLog "Recovery partition already present (#$($existing.PartitionNumber), $([math]::Round($existing.Size/1MB))MB) -- skipping creation."
    } else {
        # No SIZE= : consume the ~$RecoveryMB MB tail reserved in Step 4. This
        # avoids the alignment edge case where a fixed SIZE fails to fit the
        # freed extent. The reserved tail is the only free space on the disk.
        $dp = Invoke-Diskpart -Script @"
SELECT DISK=$Disk
CREATE PARTITION PRIMARY
FORMAT QUICK FS=NTFS LABEL="Recovery"
SET ID=$RecoveryGuid
GPT ATTRIBUTES=0x8000000000000001
"@
        Write-CleanupLog "diskpart (exit=$($dp.ExitCode)): $($dp.Output)"
    }

    # Allow the CIM view to catch up with diskpart before verifying.
    $newRecovery = $null
    for ($i = 1; $i -le 10; $i++) {
        try { Update-HostStorageCache } catch { $null = $_ }
        $newRecovery = Get-Partition -DiskNumber $Disk | Where-Object { $_.Type -eq 'Recovery' } | Select-Object -First 1
        if ($newRecovery) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $newRecovery) {
        throw "New Recovery partition not found after creation (verify GPT type GUID $RecoveryGuid)."
    }
    Write-CleanupLog "Recovery present: #$($newRecovery.PartitionNumber), $([math]::Round($newRecovery.Size/1MB))MB, GptType=$($newRecovery.GptType), IsHidden=$($newRecovery.IsHidden), NoDefaultDriveLetter=$($newRecovery.NoDefaultDriveLetter)"

    # Strip any stray drive letter auto-assigned in the brief window before the
    # hidden/no-letter GPT attribute took effect.
    if ($newRecovery.DriveLetter) {
        Write-CleanupLog "Recovery has drive letter $($newRecovery.DriveLetter): -- removing." -Level "WARN"
        try {
            Remove-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $newRecovery.PartitionNumber -AccessPath "$($newRecovery.DriveLetter):\" -ErrorAction Stop
        } catch {
            Write-CleanupLog "Could not remove stray drive letter: $_" -Level "WARN"
        }
    }

    # Resume BitLocker BEFORE re-enabling WinRE: the partition work is complete,
    # and reagentc should configure the WinRE<->BitLocker relationship against the
    # real (protected) state. Non-fatal on failure (auto-resume at reboot applies).
    if ($bitlockerSuspended) {
        try {
            Resume-BitLocker -MountPoint "C:" -ErrorAction Stop | Out-Null
            $bitlockerSuspended = $false
            Write-CleanupLog "BitLocker protection resumed on C: (before WinRE re-enable)."
        } catch {
            Write-CleanupLog "Resume-BitLocker before WinRE enable failed: $_ (continuing; auto-resume at reboot applies)." -Level "WARN"
        }
    }

    # -- Step 6: Re-register WinRE ONTO the dedicated Recovery partition ---------
    # ALWAYS best-effort and NEVER fails the run; the partition cleanup (the
    # script's job) is already complete and verified by this point.
    #
    # reagentc /enable auto-selects C:\Recovery\WindowsRE (on the OS volume) unless
    # /setreimage points at a \Recovery\WindowsRE folder ON the recovery partition.
    # So we mount the new partition, place winre.wim + the folder there, register
    # that path, then /enable (while mounted) -- landing WinRE on the dedicated
    # partition (best practice) rather than C:. Worst case (any sub-step fails) is
    # the same C: fallback, so this can only improve the result.
    Write-CleanupLog "--- Step 6: Re-register WinRE onto the Recovery partition ---"
    $enCode = $null
    $mnt    = $null
    try {
        if ($haveWinreImage -and (Test-Path $WinreWim)) {
            try {
                $used   = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
                $letter = (90..68 | ForEach-Object { [char]$_ } | Where-Object { $used -notcontains $_ } | Select-Object -First 1)
                if (-not $letter) { throw "no free drive letter to mount the new Recovery partition" }
                Add-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $newRecovery.PartitionNumber -AccessPath "$($letter):\" -ErrorAction Stop
                $mnt = "$($letter):"
                Start-Sleep -Milliseconds 500
                $reDir = "$mnt\Recovery\WindowsRE"
                New-Item -ItemType Directory -Path $reDir -Force | Out-Null
                & robocopy.exe $WinreDir $reDir (Split-Path -Leaf $WinreWim) /B /R:1 /W:1 /NJH /NJS /NP /NFL /NDL | Out-Null
                Write-CleanupLog "Placed winre.wim onto Recovery partition ($mnt) -- robocopy exit=$LASTEXITCODE."
                $sr = & reagentc.exe /setreimage /path "$reDir" 2>&1
                Write-CleanupLog "reagentc /setreimage /path `"$reDir`" exit=$LASTEXITCODE : $($sr -join ' | ')"
            } catch {
                Write-CleanupLog "Could not place WinRE on the partition ($_) -- /enable will fall back to a location it chooses." -Level "WARN"
            }
        }

        # Runs whether or not the placement above succeeded. If it did, WinRE lands
        # on the partition; if not, reagentc auto-selects (same as before).
        $en     = & reagentc.exe /enable 2>&1
        $enCode = $LASTEXITCODE
        Write-CleanupLog "reagentc /enable exit=$enCode : $($en -join ' | ')"
        if ($enCode -eq 0) {
            $info = & reagentc.exe /info 2>&1
            Write-CleanupLog "reagentc /info: $($info -join ' | ')"
            Write-CleanupLog "WinRE re-registered successfully (see 'Windows RE location' above -- expect ...\harddisk0\partition4)."
        } elseif ($haveWinreImage) {
            Write-CleanupLog "reagentc /enable failed (exit $enCode) despite a staged + registered image -- WinRE NOT registered. Provision separately. Continuing (best-effort)." -Level "WARN"
        } else {
            Write-CleanupLog "reagentc /enable did not register WinRE (exit $enCode); no image was staged. Continuing (best-effort)." -Level "WARN"
        }
    } finally {
        if ($mnt) {
            try {
                Remove-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $newRecovery.PartitionNumber -AccessPath "$mnt\" -ErrorAction Stop
                Write-CleanupLog "Unmounted Recovery partition access path $mnt."
            } catch {
                Write-CleanupLog "Could not remove Recovery mount $mnt ($_)." -Level "WARN"
            }
        }
    }

    # WinRE now lives on the partition; drop the ~900 MB C: staging copy so nothing
    # is left behind (only after a successful enable).
    if ($enCode -eq 0) { Remove-Item $WinreWim -Force -ErrorAction SilentlyContinue }

    $succeeded = $true
}
catch {
    Write-CleanupLog "FATAL: $_" -Level "ERROR"
    # $succeeded stays $false -- detection key will NOT be written.
}
finally {
    if ($bitlockerSuspended) {
        try {
            Resume-BitLocker -MountPoint "C:" -ErrorAction Stop | Out-Null
            Write-CleanupLog "BitLocker protection resumed on C:."
        } catch {
            Write-CleanupLog "Resume-BitLocker failed: $_ (auto-resume at next reboot still applies)." -Level "ERROR"
        }
    }
}

# -- Single exit point ---------------------------------------------------------
if (-not $succeeded) {
    Write-CleanupLog "===== Partition Cleanup FAILED -- detection key NOT written =====" -Level "ERROR"
    exit 1
}

Write-CleanupLog "--- Final: Write detection key ---"
try {
    Write-DetectionKey -Value "Done"
    Write-CleanupLog "Written: $RegPath\$RegName = Done"
} catch {
    Write-CleanupLog "Registry write failed: $_" -Level "ERROR"
    exit 1
}

Write-CleanupLog "===== Partition Cleanup Completed Successfully ====="
exit 0
