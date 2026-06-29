$LogDir  = "C:\ProgramData\IT\Logs"
$LogFile = "$LogDir\Partition-Cleanup.log"
$RegPath = "HKLM:\SOFTWARE\IT\Deployment"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Out-File -FilePath $LogFile -Append
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Write-Log "START"

# Delete partitions
$targets = @("SR_AED", "SR_IMAGE", "HP_RECOVERY")

Get-Partition -DiskNumber 0 | ForEach-Object {
    $p = $_
    $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue

    if ($v -and $targets -contains $v.FileSystemLabel) {
        Write-Log "Deleting partition $($p.PartitionNumber) - $($v.FileSystemLabel)"
        Remove-Partition -DiskNumber 0 -PartitionNumber $p.PartitionNumber -Confirm:$false
    }
}

# Extend C:
try {
    $supported = Get-PartitionSupportedSize -DriveLetter C
    Resize-Partition -DriveLetter C -Size $supported.SizeMax
    Write-Log "C: extended"
} catch {
    Write-Log "Resize failed: $_"
    exit 1
}

# Detection key
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
}

Set-ItemProperty -Path $RegPath -Name "PartitionCleanup" -Value "Done"

Write-Log "DONE"
exit 0
