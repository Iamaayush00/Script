# =============================================================================
# REMEDIATION: HP Bloatware Removal
# Purpose : Remove HP bloatware apps and programs from Windows 11
# Platform: Microsoft Intune (Proactive Remediation - Remediation Script)
# Exit 0  : Remediation completed
# Exit 1  : Remediation failed unexpectedly
# Log     : C:\Logs\HPBloatware.log
# Protected: Poly Lens, Poly Camera Pro Compatibility Add-on - never touched
#
# Removal order:
#   Phase 1 - Stop & disable HP services
#   Phase 2 - Remove AppX provisioned packages
#   Phase 3 - Remove AppX packages (all users)
#   Phase 4 - Remove standard programs (Get-Package + registry fallback)
#   Phase 5 - Remove stubborn programs (registry uninstall engine)
#   Phase 6 - HP Documentation special handling
#   Phase 7 - HP Wolf Security CIM last-resort fallback
# =============================================================================

$LogPath      = "C:\Logs\HPBloatware.log"
$LogDir       = "C:\Logs"
$HPIdentifier = "AD2F1837"

# AppX packages to remove
$TargetPackages = @(
    "AD2F1837.HPJumpStarts"
    "AD2F1837.HPPCHardwareDiagnosticsWindows"
    "AD2F1837.HPPowerManager"
    "AD2F1837.HPPrivacySettings"
    "AD2F1837.HPSupportAssistant"
    "AD2F1837.HPSureShieldAI"
    "AD2F1837.HPSystemInformation"
    "AD2F1837.HPQuickDrop"
    "AD2F1837.HPWorkWell"
    "AD2F1837.myHP"
    "AD2F1837.HPDesktopSupportUtilities"
    "AD2F1837.HPQuickTouch"
    "AD2F1837.HPEasyClean"
)

# Standard programs (try Get-Package first, registry as fallback)
$StandardPrograms = @(
    "HP Client Security Manager"
    "HP MAC Address Manager"
    "HP Notifications"
    "HP System Default Settings"
    "HP Sure Click"
    "HP Sure Click Security Browser"
    "HP Sure Run"
    "HP Sure Run Module"
    "HP Sure Recover"
    "HP Sure Sense"
    "HP Sure Sense Installer"
    "HP Support Assistant"
    "HP Wolf Security Application Support for Sure Sense"
    "HP Wolf Security Application Support for Windows"
)

# Stubborn programs — go straight to registry uninstall engine
# (Get-Package does not reliably remove these)
$StubborntPrograms = @(
    "HP Connection Optimizer"
    "HP Security Update Service"
    "HP Wolf Security"
    "HP Wolf Security - Console"
)

$RegUninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

# -----------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value "$Timestamp [REMEDIATE] $Message"
}

# -----------------------------------------------------------------------
# Stops and disables a Windows service by name (silently skips if absent)
function Stop-DisableService {
    param([string]$Name)
    $Svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($Svc) {
        try {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "SERVICE: Stopped and disabled '$Name'"
        }
        catch {
            Write-Log "SERVICE WARN: Could not stop/disable '$Name' - $_"
        }
    }
}

# -----------------------------------------------------------------------
# Registry-based uninstall engine
# Finds all registry entries matching AppName and runs their uninstall string.
# Handles both MSI (msiexec /x {GUID}) and EXE uninstallers.
# Loops through all versions so duplicate installs (e.g. 2x Wolf Security) are caught.
function Invoke-RegistryUninstall {
    param([string]$AppName)

    $Apps = Get-ItemProperty $RegUninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $AppName }

    if (-not $Apps) {
        Write-Log "REG UNINSTALL: '$AppName' not found in registry — skipping"
        return
    }

    foreach ($App in $Apps) {
        $UninstallStr = $App.UninstallString
        if (-not $UninstallStr) { continue }

        $UninstallStr = $UninstallStr.Trim()
        Write-Log "REG UNINSTALL: '$AppName' v$($App.DisplayVersion) — $UninstallStr"

        try {
            if ($UninstallStr -match "(?i)msiexec") {
                # MSI-based uninstaller — extract GUID and run silent
                if ($UninstallStr -match "\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}") {
                    $GUID = $Matches[0]
                    $Proc = Start-Process "msiexec.exe" `
                                -ArgumentList "/x `"$GUID`" /qn /norestart" `
                                -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    if ($Proc.ExitCode -eq 0 -or $Proc.ExitCode -eq 3010) {
                        Write-Log "SUCCESS: '$AppName' removed via MSI (exit: $($Proc.ExitCode))"
                    }
                    else {
                        Write-Log "WARN: '$AppName' MSI exit code $($Proc.ExitCode) — may need manual review"
                    }
                }
            }
            else {
                # EXE-based uninstaller — parse path and args, append silent flags
                if ($UninstallStr -match '^"(.+?)"(.*)$') {
                    $ExePath = $Matches[1]
                    $ExeArgs = $Matches[2].Trim()
                }
                else {
                    $Parts   = $UninstallStr -split ' ', 2
                    $ExePath = $Parts[0]
                    $ExeArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" }
                }

                # Append silent switches (safe to add even if already present)
                $FinalArgs = ($ExeArgs + " /S /quiet /norestart").Trim()

                if (Test-Path $ExePath) {
                    $Proc = Start-Process -FilePath $ExePath `
                                -ArgumentList $FinalArgs `
                                -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    if ($Proc.ExitCode -eq 0 -or $Proc.ExitCode -eq 3010) {
                        Write-Log "SUCCESS: '$AppName' removed via EXE (exit: $($Proc.ExitCode))"
                    }
                    else {
                        Write-Log "WARN: '$AppName' EXE uninstaller exit code $($Proc.ExitCode)"
                    }
                }
                else {
                    Write-Log "WARN: Uninstall EXE not found at '$ExePath' for '$AppName'"
                }
            }
        }
        catch {
            Write-Log "ERROR: Exception during registry uninstall of '$AppName' - $_"
        }
    }
}

# =======================================================================
Write-Log "------- Remediation run started -------"
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    # -------------------------------------------------------------------
    # Phase 1: Stop and disable HP services before attempting removal
    # -------------------------------------------------------------------
    Write-Log "--- Phase 1: Stopping HP services ---"
    Stop-DisableService "HotKeyServiceUWP"
    Stop-DisableService "HPAppHelperCap"
    Stop-DisableService "HP Comm Recover"
    Stop-DisableService "HPDiagsCap"
    Stop-DisableService "HPNetworkCap"
    Stop-DisableService "HPSysInfoCap"
    Stop-DisableService "HP TechPulse Core"
    Stop-DisableService "HP Wolf Security"
    Stop-DisableService "HP Security Update Service"

    # -------------------------------------------------------------------
    # Phase 2: Remove AppX provisioned packages (pre-installed for new users)
    # -------------------------------------------------------------------
    Write-Log "--- Phase 2: Removing AppX provisioned packages ---"
    $ProvPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { ($TargetPackages -contains $_.DisplayName) -or ($_.DisplayName -match "^$HPIdentifier") }

    foreach ($pkg in $ProvPackages) {
        try {
            Remove-AppxProvisionedPackage -PackageName $pkg.PackageName -Online -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Removed provisioned package '$($pkg.DisplayName)'"
        }
        catch {
            Write-Log "WARN: Failed to remove provisioned package '$($pkg.DisplayName)' - $_"
        }
    }

    # -------------------------------------------------------------------
    # Phase 3: Remove AppX packages for all users
    # -------------------------------------------------------------------
    Write-Log "--- Phase 3: Removing AppX packages ---"
    $AppxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { ($TargetPackages -contains $_.Name) -or ($_.Name -match "^$HPIdentifier") }

    foreach ($pkg in $AppxPackages) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Removed AppX package '$($pkg.Name)'"
        }
        catch {
            Write-Log "WARN: Failed to remove AppX package '$($pkg.Name)' - $_"
        }
    }

    # -------------------------------------------------------------------
    # Phase 4: Remove standard programs via Get-Package, registry as fallback
    # -------------------------------------------------------------------
    Write-Log "--- Phase 4: Removing standard programs ---"
    foreach ($ProgramName in $StandardPrograms) {
        $Pkgs = Get-Package -Name $ProgramName -ErrorAction SilentlyContinue

        if ($Pkgs) {
            foreach ($Pkg in $Pkgs) {
                try {
                    $Pkg | Uninstall-Package -AllVersions -Force -ErrorAction Stop | Out-Null
                    Write-Log "SUCCESS: Uninstalled '$ProgramName' via Get-Package"
                }
                catch {
                    Write-Log "WARN: Get-Package failed for '$ProgramName' - trying registry fallback..."
                    Invoke-RegistryUninstall -AppName $ProgramName
                }
            }
        }
        else {
            # Not found via Get-Package — try registry directly
            $InReg = Get-ItemProperty $RegUninstallPaths -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -eq $ProgramName }
            if ($InReg) {
                Invoke-RegistryUninstall -AppName $ProgramName
            }
            else {
                Write-Log "NOT FOUND: '$ProgramName' — already removed or never installed"
            }
        }
    }

    # -------------------------------------------------------------------
    # Phase 5: Remove stubborn programs using registry uninstall engine
    # (HP Connection Optimizer, HP Security Update Service,
    #  HP Wolf Security both versions, HP Wolf Security - Console)
    # -------------------------------------------------------------------
    Write-Log "--- Phase 5: Removing stubborn programs via registry uninstall ---"
    foreach ($ProgramName in $StubborntPrograms) {
        Invoke-RegistryUninstall -AppName $ProgramName
    }

    # -------------------------------------------------------------------
    # Phase 6: HP Documentation — custom uninstall cmd, registry fallback
    # -------------------------------------------------------------------
    Write-Log "--- Phase 6: HP Documentation special handling ---"
    $DocCmd = "C:\Program Files\HP\Documentation\Doc_uninstall.cmd"
    if (Test-Path $DocCmd) {
        try {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$DocCmd`"" -Wait -NoNewWindow -ErrorAction Stop
            Write-Log "SUCCESS: HP Documentation removed via custom uninstall cmd"
        }
        catch {
            Write-Log "WARN: Custom cmd failed for HP Documentation - trying registry..."
            Invoke-RegistryUninstall -AppName "HP Documentation"
        }
    }
    else {
        Invoke-RegistryUninstall -AppName "HP Documentation"
    }

    # -------------------------------------------------------------------
    # Phase 7: HP Wolf Security CIM last-resort fallback
    # Catches any Wolf Security version that survived Phases 4 and 5.
    # Note: Get-CimInstance is slower than registry but most thorough for Wolf.
    # -------------------------------------------------------------------
    Write-Log "--- Phase 7: HP Wolf Security CIM fallback ---"
    $WolfTargets = @(
        "HP Wolf Security"
        "HP Wolf Security - Console"
        "HP Security Update Service"
    )

    foreach ($WolfApp in $WolfTargets) {
        try {
            $CimApps = Get-CimInstance -ClassName Win32_Product -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -eq $WolfApp }
            if ($CimApps) {
                foreach ($CimApp in $CimApps) {
                    $CimApp | Invoke-CimMethod -MethodName Uninstall -ErrorAction Stop | Out-Null
                    Write-Log "SUCCESS: '$WolfApp' v$($CimApp.Version) removed via CIM"
                }
            }
            else {
                Write-Log "CIM: '$WolfApp' not found — likely already removed"
            }
        }
        catch {
            Write-Log "WARN: CIM removal failed for '$WolfApp' - $_"
        }
    }

    Write-Log "------- Remediation completed -------"
    Write-Output "HP bloatware removal completed — check C:\Logs\HPBloatware.log for details"
    exit 0
}
catch {
    Write-Log "ERROR: Unexpected failure during remediation - $_"
    Write-Output "Remediation failed unexpectedly"
    exit 1
}
