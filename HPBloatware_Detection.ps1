# =============================================================================
# DETECTION: HP Bloatware Check (v2)
# Purpose : Detect presence of HP bloatware apps and programs
# Platform: Microsoft Intune (Proactive Remediation - Detection Script)
# Exit 0  : Compliant   - No HP bloatware detected
# Exit 1  : Non-Compliant - HP bloatware found, remediation needed
# Log     : C:\Logs\HPBloatware.log
# Note    : Uses registry-based program detection (fast) instead of
#           Get-WmiObject Win32_Product (slow, causes MSI reconfiguration)
#
# v2 changes:
#   - Added Poly Camera Pro Compatibility Add-on and Poly Lens to targets
#   - Removed protected status for Poly apps
# =============================================================================

$LogPath      = "C:\Logs\HPBloatware.log"
$LogDir       = "C:\Logs"
$HPIdentifier = "AD2F1837"

# AppX packages to detect (by package name)
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

# Win32 programs to detect (by display name in registry)
$TargetPrograms = @(
    "HP Client Security Manager"
    "HP Connection Optimizer"
    "HP Documentation"
    "HP MAC Address Manager"
    "HP Notifications"
    "HP Security Update Service"
    "HP System Default Settings"
    "HP Sure Click"
    "HP Sure Click Security Browser"
    "HP Sure Run"
    "HP Sure Run Module"
    "HP Sure Recover"
    "HP Sure Sense"
    "HP Sure Sense Installer"
    "HP Support Assistant"
    "HP Wolf Security"
    "HP Wolf Security - Console"
    "HP Wolf Security Application Support for Sure Sense"
    "HP Wolf Security Application Support for Windows"
    "Poly Camera Pro Compatibility Add-on"
    "Poly Lens"
)

# Registry paths covering both 32-bit and 64-bit installed programs
$RegUninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value "$Timestamp [DETECT] $Message"
}

Write-Log "------- Detection run started -------"

$DetectedItems = [System.Collections.Generic.List[string]]::new()

try {
    # --- Check 1: AppX packages installed for all users ---
    $AppxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { ($TargetPackages -contains $_.Name) -or ($_.Name -match "^$HPIdentifier") }

    foreach ($pkg in $AppxPackages) {
        Write-Log "FOUND AppX package      : $($pkg.Name)"
        $DetectedItems.Add($pkg.Name)
    }

    # --- Check 2: AppX provisioned packages (pre-installed, appear for new user profiles) ---
    $ProvPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { ($TargetPackages -contains $_.DisplayName) -or ($_.DisplayName -match "^$HPIdentifier") }

    foreach ($pkg in $ProvPackages) {
        Write-Log "FOUND provisioned package: $($pkg.DisplayName)"
        $DetectedItems.Add($pkg.DisplayName)
    }

    # --- Check 3: Win32 programs via registry (fast - no WMI/Get-WmiObject) ---
    $RegPrograms = Get-ItemProperty $RegUninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $TargetPrograms -contains $_.DisplayName }

    foreach ($prog in $RegPrograms) {
        Write-Log "FOUND installed program  : $($prog.DisplayName) (v$($prog.DisplayVersion))"
        $DetectedItems.Add($prog.DisplayName)
    }

    # --- Result ---
    if ($DetectedItems.Count -gt 0) {
        Write-Log "RESULT: Non-Compliant - $($DetectedItems.Count) HP bloatware item(s) detected"
        Write-Output "Non-Compliant: $($DetectedItems.Count) HP bloatware item(s) found"
        exit 1
    }

    Write-Log "RESULT: Compliant - No HP bloatware detected"
    Write-Output "Compliant: No HP bloatware detected"
    exit 0
}
catch {
    Write-Log "ERROR: Detection script failed - $_"
    Write-Output "Error: Detection failed"
    exit 1
}
