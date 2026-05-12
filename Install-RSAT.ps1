# =============================================================================
# Install-RSAT.ps1
# Purpose : Install the following RSAT features on Windows 11:
#             - Active Directory DS & LDS Tools
#             - Group Policy Management Tools
#             - DHCP Tools
#             - DNS Tools
# Method  : DISM.exe running in parallel (all features install simultaneously)
#           Reduces total install time from ~40+ mins sequential to ~20 mins
# Context : Runs as SYSTEM via Intune Win32 app deployment
# Log     : C:\Logs\RSAT.log
# =============================================================================

$LogPath = "C:\Logs\RSAT.log"
$LogDir  = "C:\Logs"

$Features = @(
    @{ Name = "Active Directory DS & LDS Tools"; Capability = "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" },
    @{ Name = "Group Policy Management Tools";   Capability = "Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0" },
    @{ Name = "DHCP Tools";                      Capability = "Rsat.DHCP.Tools~~~~0.0.1.0" },
    @{ Name = "DNS Tools";                        Capability = "Rsat.Dns.Tools~~~~0.0.1.0" }
)

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value "$Timestamp [INSTALL] $Message"
}

Write-Log "------- RSAT Installation started -------"
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Install method: DISM.exe parallel (all features launch simultaneously)"

# --- Phase 1: Check current state and queue features that need installing ---
$Queue = @()

foreach ($Feature in $Features) {
    try {
        $State = Get-WindowsCapability -Online -Name $Feature.Capability -ErrorAction Stop
        if ($State.State -eq "Installed") {
            Write-Log "SKIPPED  : $($Feature.Name) is already installed"
        }
        else {
            Write-Log "QUEUED   : $($Feature.Name) — will install in parallel"
            $Queue += $Feature
        }
    }
    catch {
        Write-Log "ERROR    : Could not check state of $($Feature.Name) - $_"
    }
}

if ($Queue.Count -eq 0) {
    Write-Log "RESULT: All RSAT features already installed — nothing to do"
    Write-Output "RSAT already installed"
    exit 0
}

# --- Phase 2: Launch all queued DISM installs simultaneously ---
Write-Log "Launching $($Queue.Count) DISM process(es) in parallel..."

$Jobs = @()

foreach ($Feature in $Queue) {
    try {
        $DismArgs = "/Online /Add-Capability /CapabilityName:$($Feature.Capability) /NoRestart /Quiet"
        $Process  = Start-Process -FilePath "dism.exe" `
                                  -ArgumentList $DismArgs `
                                  -PassThru `
                                  -NoNewWindow

        Write-Log "STARTED  : $($Feature.Name) — PID $($Process.Id)"
        $Jobs += @{ Feature = $Feature; Process = $Process; StartTime = (Get-Date) }
    }
    catch {
        Write-Log "ERROR    : Failed to launch DISM for $($Feature.Name) - $_"
    }
}

# --- Phase 3: Wait for all processes to complete and log results ---
Write-Log "Waiting for all installs to complete..."

$Errors = @()

foreach ($Job in $Jobs) {
    $Job.Process.WaitForExit()
    $ExitCode = $Job.Process.ExitCode
    $Duration = [math]::Round(((Get-Date) - $Job.StartTime).TotalMinutes, 1)

    if ($ExitCode -eq 0) {
        Write-Log "SUCCESS  : $($Job.Feature.Name) installed successfully in $Duration min (exit: 0)"
    }
    elseif ($ExitCode -eq 3010) {
        Write-Log "SUCCESS  : $($Job.Feature.Name) installed successfully in $Duration min (reboot may be required)"
    }
    else {
        Write-Log "ERROR    : $($Job.Feature.Name) failed in $Duration min — DISM exit code: $ExitCode"
        $Errors += $Job.Feature.Name
    }
}

if ($Errors.Count -eq 0) {
    Write-Log "RESULT: All RSAT features installed successfully"
    Write-Output "RSAT installation complete"
    exit 0
}
else {
    Write-Log "RESULT: Installation completed with errors on: $($Errors -join ', ')"
    Write-Output "RSAT installation failed for: $($Errors -join ', ')"
    exit 1
}
