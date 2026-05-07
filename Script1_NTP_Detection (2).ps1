# =============================================================================
# Script 1 - DETECTION: NTP Server Check
# Purpose : Detect if the NTP server is correctly set to ldbtime.bcliquor.com
#           in BOTH the W32Time service registry (actual sync) AND the
#           Settings UI registry (Date & Time page display).
#           Flags non-compliant if either location is wrong or missing.
# Platform: Microsoft Intune (Proactive Remediation - Detection Script)
# Exit 0  : Compliant   - Both locations correctly set to ldbtime.bcliquor.com
# Exit 1  : Non-Compliant - One or both locations are incorrect (remediation runs)
# Log     : C:\Logs\NTPServer.log
# =============================================================================

$LogPath    = "C:\Logs\NTPServer.log"
$LogDir     = "C:\Logs"
$W32RegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
$UIRegPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DateTime\Servers"
$TargetNTP  = "ldbtime.bcliquor.com"
$BadNTP     = "time.windows.com"

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
    # --- Check 1: W32Time service registry (controls actual NTP sync) ---
    $W32NTP = (Get-ItemProperty -Path $W32RegPath -Name "NtpServer" -ErrorAction Stop).NtpServer
    Write-Log "W32Time NTP server value : $W32NTP"

    $W32Compliant = $W32NTP -like "*$TargetNTP*"

    # --- Check 2: Settings UI registry (controls Date & Time settings page display) ---
    $UICompliant = $false
    $UIValue     = $null

    if (Test-Path $UIRegPath) {
        $UIDefault = (Get-ItemProperty -Path $UIRegPath -Name "(Default)" -ErrorAction SilentlyContinue)."(Default)"
        if ($UIDefault) {
            $UIValue = (Get-ItemProperty -Path $UIRegPath -Name $UIDefault -ErrorAction SilentlyContinue).$UIDefault
        }
        Write-Log "Settings UI NTP value    : $UIValue (slot '$UIDefault')"
        $UICompliant = $UIValue -like "*$TargetNTP*"
    } else {
        Write-Log "Settings UI registry key not found - UI not yet configured"
    }

    # --- Evaluate combined result ---
    if ($W32Compliant -and $UICompliant) {
        Write-Log "RESULT: Compliant - Both W32Time and Settings UI are set to $TargetNTP"
        Write-Output "Compliant: NTP correctly set to $TargetNTP in both locations"
        exit 0
    }
    elseif ($W32Compliant -and -not $UICompliant) {
        Write-Log "RESULT: Non-Compliant - W32Time is correct but Settings UI still shows '$UIValue'. Remediation will update the UI registry."
        Write-Output "Non-Compliant: W32Time correct but Settings UI is out of sync ($UIValue)"
        exit 1
    }
    elseif (-not $W32Compliant -and $UICompliant) {
        Write-Log "RESULT: Non-Compliant - Settings UI is correct but W32Time still shows '$W32NTP'. Remediation will update W32Time."
        Write-Output "Non-Compliant: Settings UI correct but W32Time is out of sync ($W32NTP)"
        exit 1
    }
    else {
        Write-Log "RESULT: Non-Compliant - Both locations are incorrect. W32Time='$W32NTP' | UI='$UIValue'. Remediation will fix both."
        Write-Output "Non-Compliant: Both W32Time ($W32NTP) and Settings UI ($UIValue) are incorrect"
        exit 1
    }
}
catch {
    Write-Log "ERROR: Could not read registry - $_"
    Write-Output "Error: Failed to read NTP registry values"
    exit 1
}
