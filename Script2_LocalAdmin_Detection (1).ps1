# =============================================================================
# Script 2 - DETECTION: Local Admin Account Check
# Purpose : Detect if the local "Admin" account exists AND is enabled,
#           while "LocalAdmin" is present as a safe fallback.
#           Remediation (disabling Admin) only triggers when:
#             - Admin exists AND is currently ENABLED, AND
#             - LocalAdmin exists (safe to proceed)
#           If Admin exists but is already DISABLED, detection returns Compliant
#           so Intune stops cycling the remediation unnecessarily.
# Platform: Microsoft Intune (Proactive Remediation - Detection Script)
# Exit 0  : Compliant   - Admin is absent, already disabled, or LocalAdmin
#                         not yet ready (deferred)
# Exit 1  : Non-Compliant - Admin is ENABLED and LocalAdmin exists; disable it
# Log     : C:\Logs\LocalAdmin.log
# =============================================================================

$LogPath = "C:\Logs\LocalAdmin.log"
$LogDir  = "C:\Logs"

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value "$Timestamp [DETECT] $Message"
}

Write-Log "------- Detection run started -------"

try {
    $AdminUser      = Get-LocalUser -Name "Admin"      -ErrorAction SilentlyContinue
    $LocalAdminUser = Get-LocalUser -Name "LocalAdmin" -ErrorAction SilentlyContinue

    $AdminExists      = $null -ne $AdminUser
    $AdminEnabled     = $AdminExists -and $AdminUser.Enabled
    $LocalAdminExists = $null -ne $LocalAdminUser

    Write-Log "Account 'Admin' exists      : $AdminExists"
    Write-Log "Account 'Admin' enabled     : $AdminEnabled"
    Write-Log "Account 'LocalAdmin' exists : $LocalAdminExists"

    # Admin doesn't exist at all - nothing to do
    if (-not $AdminExists) {
        Write-Log "RESULT: Compliant - 'Admin' account does not exist. No action required."
        Write-Output "Compliant: Admin account does not exist"
        exit 0
    }

    # Admin exists but is already disabled - remediation already done
    if ($AdminExists -and -not $AdminEnabled) {
        Write-Log "RESULT: Compliant - 'Admin' account exists but is already disabled. No action required."
        Write-Output "Compliant: Admin account is already disabled"
        exit 0
    }

    # Admin is enabled but LocalAdmin not yet present - hold off, check again next cycle
    if ($AdminEnabled -and -not $LocalAdminExists) {
        Write-Log "RESULT: Compliant (deferred) - 'Admin' is enabled but 'LocalAdmin' not found. Waiting for LocalAdmin before taking action."
        Write-Output "Compliant (deferred): Admin enabled but LocalAdmin not found - no action this cycle"
        exit 0
    }

    # Admin is enabled AND LocalAdmin exists - safe to disable Admin
    if ($AdminEnabled -and $LocalAdminExists) {
        Write-Log "RESULT: Non-Compliant - 'Admin' is ENABLED and 'LocalAdmin' exists. Remediation will disable Admin."
        Write-Output "Non-Compliant: Admin is enabled and LocalAdmin exists - remediation will disable Admin"
        exit 1
    }
}
catch {
    Write-Log "ERROR: Unexpected failure during detection - $_"
    Write-Output "Error: Detection script failed - $_"
    exit 1
}
