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

# Create folders
foreach ($dir in @($WorkDir, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Write-Log "=== HPIA Deployment Started ==="

# Download
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($HPIAUrl, $HPIAExe)
    Write-Log "Download complete"
} catch {
    Write-Log "Download failed: $_"
    exit 1
}

# Run HPIA
try {
    $args = "/Operation:Analyze /Action:Install /Selection:All /Silent /ReportFolder:`"$LogDir`" /RebootCount:1"
    $proc = Start-Process -FilePath $HPIAExe -ArgumentList $args -Wait -PassThru
    Write-Log "Exit code: $($proc.ExitCode)"
} catch {
    Write-Log "Execution failed: $_"
    exit 1
}

# Detection key
try {
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $RegPath -Name "HPIA" -Value "Done"
} catch {
    Write-Log "Registry write failed: $_"
    exit 1
}

Write-Log "=== COMPLETE ==="
exit 0
``