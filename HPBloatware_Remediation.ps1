# =============================================================================
# REMEDIATION: HP Bloatware Removal (v5)
# Purpose : Remove HP bloatware apps and programs from Windows 11
# Platform: Microsoft Intune (Proactive Remediation - Remediation Script)
# Exit 0  : Remediation completed
# Exit 1  : Remediation failed unexpectedly
# Log     : C:\Logs\HPBloatware.log
#
# v5 changes:
#   - Added Poly Camera Pro Compatibility Add-on and Poly Lens to removal targets
#   - Poly Lens: processes killed in Phase 1, service stopped in Phase 2,
#     then removed via standard registry uninstall in Phase 6
#   - Removed protected status for Poly apps
# =============================================================================

$LogPath      = "C:\Logs\HPBloatware.log"
$LogDir       = "C:\Logs"
$HPIdentifier = "AD2F1837"

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
    "Poly Camera Pro Compatibility Add-on"
    "Poly Lens"
)

# Wolf Security must be removed in this specific dependency order
$WolfPrograms = @(
    "HP Wolf Security Application Support for Sure Sense"
    "HP Wolf Security Application Support for Windows"
    "HP Wolf Security - Console"
    "HP Security Update Service"
    "HP Wolf Security"
)

$RegUninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$RegUninstallBases = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
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
# Finds and deletes all registry uninstall entries matching a display name.
# This removes the app from Programs and Features immediately without reboot.
function Remove-RegistryEntry {
    param([string]$AppName)
    $Found = $false
    foreach ($BasePath in $RegUninstallBases) {
        $Keys = Get-ChildItem $BasePath -ErrorAction SilentlyContinue |
                Where-Object {
                    (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -eq $AppName
                }
        foreach ($Key in $Keys) {
            try {
                Remove-Item -Path $Key.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "REG CLEANUP: Removed Programs and Features entry for '$AppName'"
                $Found = $true
            }
            catch {
                Write-Log "REG CLEANUP WARN: Could not remove registry entry for '$AppName' - $_"
            }
        }
    }
    if (-not $Found) {
        Write-Log "REG CLEANUP: No registry entry found for '$AppName' (already clean)"
    }
}

# -----------------------------------------------------------------------
function Stop-DisableService {
    param([string]$Name)
    $Svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($Svc) {
        try {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "SERVICE: Stopped and disabled '$Name'"
        }
        catch { Write-Log "SERVICE WARN: Could not stop/disable '$Name' - $_" }
    }
}

# -----------------------------------------------------------------------
# Registry uninstall engine — handles MSI, CMD, and EXE uninstall strings
function Invoke-RegistryUninstall {
    param(
        [string]$AppName,
        [string]$ExtraMsiArgs = ""
    )

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
            # --- MSI uninstaller ---
            if ($UninstallStr -match "(?i)msiexec") {
                if ($UninstallStr -match "\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}") {
                    $GUID    = $Matches[0]
                    $MsiArgs = "/x `"$GUID`" /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable $ExtraMsiArgs".Trim()
                    $Proc    = Start-Process "msiexec.exe" -ArgumentList $MsiArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    if ($Proc.ExitCode -eq 0 -or $Proc.ExitCode -eq 3010) {
                        Write-Log "SUCCESS: '$AppName' removed via MSI (exit: $($Proc.ExitCode))"
                    }
                    else {
                        Write-Log "WARN: '$AppName' MSI exit $($Proc.ExitCode) — will try CIM fallback later"
                    }
                }
            }

            # --- CMD uninstaller (e.g. CMD /C "path\script.cmd") ---
            elseif ($UninstallStr -match "^(?i)cmd(?:\.exe)?\s+/[Cc]\s+(.+)$") {
                $CmdArgs = $Matches[1].Trim()
                Write-Log "CMD uninstaller detected for '$AppName' — args: $CmdArgs"
                $Proc = Start-Process "cmd.exe" -ArgumentList "/C $CmdArgs" -Wait -PassThru -NoNewWindow -ErrorAction Stop
                if ($Proc.ExitCode -eq 0 -or $Proc.ExitCode -eq 3010) {
                    Write-Log "SUCCESS: '$AppName' removed via CMD (exit: $($Proc.ExitCode))"
                }
                else {
                    Write-Log "WARN: '$AppName' CMD exit $($Proc.ExitCode)"
                }
            }

            # --- EXE / InstallShield uninstaller ---
            else {
                if ($UninstallStr -match '^"(.+?)"(.*)$') {
                    $ExePath = $Matches[1]
                    $ExeArgs = $Matches[2].Trim()
                }
                else {
                    $Parts   = $UninstallStr -split ' ', 2
                    $ExePath = $Parts[0]
                    $ExeArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" }
                }

                if ($ExeArgs -match "-runfromtemp") {
                    $ExeArgs = "$ExeArgs -s"
                }
                else {
                    $ExeArgs = "$ExeArgs /S /quiet /norestart"
                }

                if (Test-Path $ExePath) {
                    $Proc = Start-Process -FilePath $ExePath -ArgumentList $ExeArgs.Trim() -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    if ($Proc.ExitCode -eq 0 -or $Proc.ExitCode -eq 3010) {
                        Write-Log "SUCCESS: '$AppName' removed via EXE (exit: $($Proc.ExitCode))"
                    }
                    else {
                        Write-Log "WARN: '$AppName' EXE exit $($Proc.ExitCode)"
                    }
                }
                else {
                    Write-Log "WARN: EXE not found at '$ExePath' for '$AppName'"
                }
            }
        }
        catch {
            Write-Log "ERROR: Exception during registry uninstall of '$AppName' - $_"
        }
    }
}

# -----------------------------------------------------------------------
function Invoke-CimUninstall {
    param([string]$AppName)
    try {
        $CimApps = Get-CimInstance -ClassName Win32_Product -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq $AppName }
        if ($CimApps) {
            foreach ($CimApp in $CimApps) {
                $CimApp | Invoke-CimMethod -MethodName Uninstall -ErrorAction Stop | Out-Null
                Write-Log "CIM SUCCESS: '$AppName' v$($CimApp.Version) removed via CIM"
            }
        }
        else {
            Write-Log "CIM: '$AppName' not found — likely already removed"
        }
    }
    catch {
        Write-Log "CIM WARN: Removal failed for '$AppName' - $_"
    }
}

# =======================================================================
Write-Log "------- Remediation run started (v5) -------"
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    # -------------------------------------------------------------------
    # Phase 1: Kill HP Wolf Security and Poly Lens processes
    # -------------------------------------------------------------------
    Write-Log "--- Phase 1: Killing HP Wolf Security and Poly Lens processes ---"
    $WolfProcesses = @(
        "hpwsed","hpwseud","HPSA_Service","HpwseIntegration",
        "HPWSELauncher","hpwsepolicymanager","hpwseMgmt",
        "HP Wolf Security","HpwseBroker","hpwsenotif"
    )
    foreach ($ProcName in $WolfProcesses) {
        $Running = Get-Process -Name $ProcName -ErrorAction SilentlyContinue
        if ($Running) {
            try {
                Stop-Process -Name $ProcName -Force -ErrorAction Stop
                Write-Log "KILLED process: $ProcName"
            }
            catch { Write-Log "WARN: Could not kill '$ProcName' - $_" }
        }
    }

    # Kill Poly Lens processes (tray agent and background workers)
    $PolyProcesses = @(
        "PolyLens","PolyLensService","PolyLensTray","PolyCameraPro",
        "PolyLensAgent","PolyLensUpdater","PolyLensCore","PLService",
        "PolyLensApp","Poly Lens"
    )
    foreach ($ProcName in $PolyProcesses) {
        $Running = Get-Process -Name $ProcName -ErrorAction SilentlyContinue
        if ($Running) {
            try {
                Stop-Process -Name $ProcName -Force -ErrorAction Stop
                Write-Log "KILLED process: $ProcName"
            }
            catch { Write-Log "WARN: Could not kill '$ProcName' - $_" }
        }
    }

    # -------------------------------------------------------------------
    # Phase 2: Stop and disable HP and Poly services
    # -------------------------------------------------------------------
    Write-Log "--- Phase 2: Stopping HP and Poly services ---"
    Stop-DisableService "HotKeyServiceUWP"
    Stop-DisableService "HPAppHelperCap"
    Stop-DisableService "HP Comm Recover"
    Stop-DisableService "HPDiagsCap"
    Stop-DisableService "HPNetworkCap"
    Stop-DisableService "HPSysInfoCap"
    Stop-DisableService "HP TechPulse Core"
    Stop-DisableService "HP Wolf Security"
    Stop-DisableService "HP Security Update Service"
    Stop-DisableService "HpwseSvc"
    Stop-DisableService "HpwseIntegration"
    # Poly Lens service (try common service name variants)
    Stop-DisableService "PolyLensService"
    Stop-DisableService "PolyLens"
    Stop-DisableService "Poly Lens"
    Stop-DisableService "PolyLensAgent"
    Stop-DisableService "PolyLensUpdater"
    Stop-DisableService "PolyLensCore"
    Stop-DisableService "PLService"

    # -------------------------------------------------------------------
    # Phase 3: Disable HP Wolf Security self-protection via registry
    # -------------------------------------------------------------------
    Write-Log "--- Phase 3: Disabling HP Wolf Security self-protection ---"
    $SelfProtectPaths = @(
        "HKLM:\SOFTWARE\HP Inc.\HP Wolf Security"
        "HKLM:\SOFTWARE\HP\HP Wolf Security"
        "HKLM:\SOFTWARE\HP Inc.\HP Wolf Security\Config"
    )
    foreach ($RegPath in $SelfProtectPaths) {
        if (Test-Path $RegPath) {
            try {
                Set-ItemProperty -Path $RegPath -Name "TamperProtection"        -Value 0 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $RegPath -Name "DisableTamperProtection" -Value 1 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $RegPath -Name "SelfProtection"          -Value 0 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $RegPath -Name "SelfProtectionEnabled"   -Value 0 -ErrorAction SilentlyContinue
                Write-Log "Self-protection disabled at: $RegPath"
            }
            catch { Write-Log "WARN: Could not modify self-protection at '$RegPath' - $_" }
        }
    }
    Start-Sleep -Seconds 5

    # -------------------------------------------------------------------
    # Phase 4: Remove AppX provisioned packages
    # -------------------------------------------------------------------
    Write-Log "--- Phase 4: Removing AppX provisioned packages ---"
    $ProvPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { ($TargetPackages -contains $_.DisplayName) -or ($_.DisplayName -match "^$HPIdentifier") }
    foreach ($pkg in $ProvPackages) {
        try {
            Remove-AppxProvisionedPackage -PackageName $pkg.PackageName -Online -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Removed provisioned package '$($pkg.DisplayName)'"
        }
        catch { Write-Log "WARN: Failed provisioned package '$($pkg.DisplayName)' - $_" }
    }

    # -------------------------------------------------------------------
    # Phase 5: Remove AppX packages (all users)
    # -------------------------------------------------------------------
    Write-Log "--- Phase 5: Removing AppX packages ---"
    $AppxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { ($TargetPackages -contains $_.Name) -or ($_.Name -match "^$HPIdentifier") }
    foreach ($pkg in $AppxPackages) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Removed AppX package '$($pkg.Name)'"
        }
        catch { Write-Log "WARN: Failed AppX package '$($pkg.Name)' - $_" }
    }

    # -------------------------------------------------------------------
    # Phase 6: Remove standard programs (Get-Package + registry fallback)
    # Includes Poly Camera Pro Compatibility Add-on and Poly Lens
    # -------------------------------------------------------------------
    Write-Log "--- Phase 6: Removing standard programs ---"
    foreach ($ProgramName in $StandardPrograms) {
        $Pkgs = Get-Package -Name $ProgramName -ErrorAction SilentlyContinue
        if ($Pkgs) {
            foreach ($Pkg in $Pkgs) {
                try {
                    $Pkg | Uninstall-Package -AllVersions -Force -ErrorAction Stop | Out-Null
                    Write-Log "SUCCESS: '$ProgramName' removed via Get-Package"
                }
                catch {
                    Write-Log "WARN: Get-Package failed for '$ProgramName' — trying registry..."
                    Invoke-RegistryUninstall -AppName $ProgramName
                }
            }
        }
        else {
            $InReg = Get-ItemProperty $RegUninstallPaths -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -eq $ProgramName }
            if ($InReg) { Invoke-RegistryUninstall -AppName $ProgramName }
            else { Write-Log "NOT FOUND: '$ProgramName' — already removed or never installed" }
        }
    }

    # -------------------------------------------------------------------
    # Phase 7: HP Connection Optimizer
    # The InstallShield EXE uninstaller returns exit 0 but leaves the
    # registry entry until reboot. After it runs, we delete the registry
    # entry manually so it disappears from Programs and Features immediately.
    # -------------------------------------------------------------------
    Write-Log "--- Phase 7: HP Connection Optimizer ---"
    Invoke-RegistryUninstall -AppName "HP Connection Optimizer"

    Write-Log "Cleaning up HP Connection Optimizer registry entry (InstallShield staged removal)..."
    Remove-RegistryEntry -AppName "HP Connection Optimizer"

    # Also clean up the InstallShield installation information folder
    $ISFolder = "C:\Program Files (x86)\InstallShield Installation Information\{6468C4A5-E47E-405F-B675-A70A70983EA6}"
    if (Test-Path $ISFolder) {
        try {
            Remove-Item -Path $ISFolder -Recurse -Force -ErrorAction Stop
            Write-Log "CLEANUP: Removed InstallShield folder for HP Connection Optimizer"
        }
        catch { Write-Log "WARN: Could not remove InstallShield folder - $_" }
    }

    # -------------------------------------------------------------------
    # Phase 8: HP Wolf Security in correct dependency order
    # -------------------------------------------------------------------
    Write-Log "--- Phase 8: HP Wolf Security (dependency order) ---"
    foreach ($WolfApp in $WolfPrograms) {
        Invoke-RegistryUninstall -AppName $WolfApp
    }

    # -------------------------------------------------------------------
    # Phase 9: HP Documentation
    # Run Doc_Uninstall.cmd with the correct working directory (cmd scripts
    # often use relative paths). Regardless of exit code, force-delete the
    # Documentation folder and registry entry — it's files only, no drivers.
    # -------------------------------------------------------------------
    Write-Log "--- Phase 9: HP Documentation ---"
    $DocDir = "C:\Program Files\HP\Documentation"
    $DocCmd = "$DocDir\Doc_Uninstall.cmd"

    if (Test-Path $DocCmd) {
        try {
            # Use working directory so relative paths in the cmd script resolve correctly
            $Proc = Start-Process "cmd.exe" `
                        -ArgumentList "/C `"$DocCmd`"" `
                        -WorkingDirectory $DocDir `
                        -Wait -PassThru -NoNewWindow -ErrorAction Stop
            Write-Log "Doc_Uninstall.cmd exited with code: $($Proc.ExitCode)"
        }
        catch {
            Write-Log "WARN: Doc_Uninstall.cmd threw an exception - $_"
        }
    }
    else {
        Write-Log "Doc_Uninstall.cmd not found — proceeding to force cleanup"
    }

    # Force-delete HP Documentation folder regardless of cmd script result
    # HP Documentation is files only (HTML, PDFs) — safe to force delete
    if (Test-Path $DocDir) {
        try {
            Remove-Item -Path $DocDir -Recurse -Force -ErrorAction Stop
            Write-Log "CLEANUP: Force-deleted HP Documentation folder '$DocDir'"
        }
        catch { Write-Log "WARN: Could not force-delete '$DocDir' - $_" }
    }
    else {
        Write-Log "HP Documentation folder already gone"
    }

    # Remove the registry entry so it disappears from Programs and Features
    Remove-RegistryEntry -AppName "HP Documentation"

    # -------------------------------------------------------------------
    # Phase 10: CIM last-resort fallback for Wolf Security
    # -------------------------------------------------------------------
    Write-Log "--- Phase 10: CIM fallback for Wolf Security ---"
    $CimTargets = @(
        "HP Wolf Security"
        "HP Wolf Security - Console"
        "HP Security Update Service"
        "HP Wolf Security Application Support for Sure Sense"
        "HP Wolf Security Application Support for Windows"
    )
    foreach ($AppName in $CimTargets) {
        Invoke-CimUninstall -AppName $AppName
    }

    # -------------------------------------------------------------------
    # Phase 11: Service and registry cleanup for anything still remaining
    # -------------------------------------------------------------------
    Write-Log "--- Phase 11: Service and registry entry cleanup ---"
    $ServiceCleanup = @("HP Wolf Security","HpwseSvc","HP Security Update Service","HpwseIntegration")
    foreach ($SvcName in $ServiceCleanup) {
        if (Get-Service -Name $SvcName -ErrorAction SilentlyContinue) {
            try {
                Start-Process "sc.exe" -ArgumentList "delete `"$SvcName`"" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                Write-Log "CLEANUP: Deleted service entry '$SvcName'"
            }
            catch { Write-Log "WARN: Could not delete service '$SvcName'" }
        }
    }

    Write-Log "------- Remediation completed -------"
    Write-Output "HP bloatware removal completed — check C:\Logs\HPBloatware.log for details"
    exit 0
}
catch {
    Write-Log "ERROR: Unexpected failure — $_"
    Write-Output "Remediation failed unexpectedly"
    exit 1
}
