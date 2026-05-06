# =============================================================================
# Script 1 - REMEDIATION: NTP Server Fix
# Purpose : Set Windows NTP server to ldbtime.bcliquor.com,
#           restart the Windows Time service, force an immediate sync,
#           and update the Settings UI registry so the Date & Time page
#           reflects the correct server (not just the actual sync config)
# Platform: Microsoft Intune (Proactive Remediation - Remediation Script)
# Exit 0  : Remediation succeeded
# Exit 1  : Remediation failed
# Log     : C:\Logs\NTPServer.log
# =============================================================================

$LogPath    = "C:\Logs\NTPServer.log"
$LogDir     = "C:\Logs"
$TargetNTP  = "ldbtime.bcliquor.com"
$W32RegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
$UIRegPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DateTime\Servers"

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value "$Timestamp [REMEDIATE] $Message"
}

Write-Log "------- Remediation run started -------"
Write-Log "Target NTP server: $TargetNTP"

try {
    # Step 1: Configure W32tm with the new NTP server
    Write-Log "Step 1: Configuring W32tm..."
    $configResult = & w32tm /config /manualpeerlist:"$TargetNTP" /syncfromflags:manual /reliable:YES /update 2>&1
    Write-Log "W32tm config output: $configResult"

    # Step 2: Restart the Windows Time service to apply the new config
    Write-Log "Step 2: Restarting Windows Time service..."
    Restart-Service -Name "W32Time" -Force -ErrorAction Stop
    Write-Log "Windows Time service restarted successfully"

    # Step 3: Allow the service a moment to fully start before syncing
    Start-Sleep -Seconds 3

    # Step 4: Force an immediate time resync against the new server
    Write-Log "Step 4: Forcing NTP resync..."
    $syncResult = & w32tm /resync /force 2>&1
    Write-Log "W32tm resync output: $syncResult"

    # Step 5: Update the Settings UI registry key so the Windows Date & Time
    #         settings page reflects the correct NTP server. This is a display-only
    #         key -- it does not affect actual time sync, but keeps the UI consistent.
    Write-Log "Step 5: Updating Settings UI registry (DateTime\Servers)..."
    if (-not (Test-Path $UIRegPath)) {
        New-Item -Path $UIRegPath -Force | Out-Null
        Write-Log "Created UI registry key (did not previously exist)"
    }
    # Write the new server into slot 1 and set it as the selected default
    Set-ItemProperty -Path $UIRegPath -Name "1"          -Value $TargetNTP -Type String -Force
    Set-ItemProperty -Path $UIRegPath -Name "(Default)"   -Value "1"        -Type String -Force
    Write-Log "UI registry updated - slot 1 set to '$TargetNTP', default pointer set to '1'"

    # Step 6: Confirm both registry locations are correct
    Write-Log "Step 6: Confirming both registry locations..."
    $ConfirmW32 = (Get-ItemProperty -Path $W32RegPath -Name "NtpServer" -ErrorAction Stop).NtpServer
    $ConfirmUI  = (Get-ItemProperty -Path $UIRegPath  -Name "1"         -ErrorAction Stop)."1"
    Write-Log "Confirmed W32Time registry : $ConfirmW32"
    Write-Log "Confirmed UI registry      : $ConfirmUI"

    Write-Log "RESULT: Remediation completed successfully - both W32Time and Settings UI updated"
    Write-Output "Remediation successful: NTP server set to $TargetNTP (W32Time + Settings UI)"
    exit 0
}
catch {
    Write-Log "ERROR: Remediation failed - $_"
    Write-Output "Remediation failed: $_"
    exit 1
}
