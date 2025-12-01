# Datto_RMM_Universal_Fix.ps1
# Version: 2.0.8
# Last Modified: 2025-12-01
# GitHub: https://github.com/jmyersctms/datto-rmm-remediation

<#
.SYNOPSIS
    Universal Datto RMM agent remediation script.

.DESCRIPTION
    Monitors and remediates Datto RMM agent (CagService) failures automatically.
    
    Behavior:
      1. Waits 5 minutes for system stabilization
      2. Checks CagService status
      3. If stopped: Attempts service restart (90 second timeout)
      4. If restart fails: Checks event log for service failures
      5. If failures detected: Performs full agent reinstallation
      6. Uploads logs to S3 (if Lambda URL provided)
    
    Deployment:
      - GPO: Deploy via Group Policy scheduled task (domain-joined devices)
      - Intune: Deploy via Platform Scripts (non-domain devices)
      - Datto: Deploy via Datto RMM component (when RMM is healthy)

.PARAMETER LambdaUrl
    Optional Lambda function URL for centralized S3 log uploads.
    If not provided, logs are only stored locally.

.PARAMETER Platform
    Datto RMM platform name (default: "vidal")

.EXAMPLE
    # Run with S3 logging
    .\Datto_RMM_Universal_Fix.ps1 -LambdaUrl "https://your-lambda-url.amazonaws.com/"

.EXAMPLE
    # Run without S3 logging (local logs only)
    .\Datto_RMM_Universal_Fix.ps1

.NOTES
    Requires: PowerShell 5.1+, Windows 10/11, Datto RMM agent installed
    Logs: C:\ProgramData\Datto_RMM_Logs\
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$LambdaUrl = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Platform = "vidal"
)

$ErrorActionPreference = 'Continue'

# Configuration
$ServiceName = "CagService"
$AgentDir = "C:\ProgramData\CentraStage"
$SettingsJson = "C:\ProgramData\CentraStage\AEMAgent\Settings.json"
$LogDirectory = "C:\ProgramData\Datto_RMM_Logs"
$FailureEventIds = 7000,7001,7009,7031,7034
$FailureLookbackHours = 24
$ServiceRestartFixedIssue = $false
$RemediationPerformed = $false

# Ensure log directory exists
if (-not (Test-Path $LogDirectory)) { 
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null 
}

$TimeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Get domain name for log filename
$DomainName = try { 
    if ($env:USERDNSDOMAIN) {
        $env:USERDNSDOMAIN
    } else {
        # Try to get domain from WMI
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs.Domain -and $cs.Domain -ne "WORKGROUP" -and $cs.Domain -notlike "*.*") {
            # Single label domain, likely Azure AD - try dsregcmd
            $dsregcmd = dsregcmd /status
            $tenantName = ($dsregcmd | Select-String "TenantName").ToString().Split(":")[1].Trim()
            if ($tenantName) {
                $tenantName
            } else {
                $cs.Domain
            }
        } elseif ($cs.Domain -and $cs.Domain -ne "WORKGROUP") {
            $cs.Domain
        } else {
            "WORKGROUP"
        }
    }
} catch { 
    "WORKGROUP" 
}
if ([string]::IsNullOrWhiteSpace($DomainName)) { $DomainName = "WORKGROUP" }

$LogFile = Join-Path $LogDirectory "${DomainName}_${env:COMPUTERNAME}_$TimeStamp.log"

Start-Transcript -Path $LogFile -Force
Write-Host "===== Datto RMM Universal Fix v2.0.8 starting at $(Get-Date) on $env:COMPUTERNAME (Domain: $DomainName) ====="
if ([string]::IsNullOrWhiteSpace($LambdaUrl)) {
    Write-Host "S3 logging: Disabled (no Lambda URL provided)"
} else {
    Write-Host "S3 logging: Enabled"
}

Write-Host "Waiting 5 minutes for system stabilization..."
Start-Sleep -Seconds 300

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) { Write-Host "Initial CagService status: $($svc.Status)" }

if ($svc -and $svc.Status -eq 'Stopped') {
    Write-Host "CagService stopped. Attempting restart..."
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    
    $maxWait = 90; $interval = 5; $elapsed = 0
    while ($elapsed -lt $maxWait) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host "Service restart succeeded after $elapsed seconds."
            $ServiceRestartFixedIssue = $true
            break
        }
    }
}

if (-not $ServiceRestartFixedIssue) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $ServiceUnhealthy = (-not $svc -or $svc.Status -ne 'Running')

    if ($ServiceUnhealthy) {
        $HasFailureEvents = $false
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName = 'System'; Id = $FailureEventIds
                StartTime = (Get-Date).AddHours(-$FailureLookbackHours)
            } -ErrorAction SilentlyContinue
            if ($events) {
                $relevant = $events | Where-Object { $_.Message -match 'CagService|Datto RMM' }
                if ($relevant) { $HasFailureEvents = $true }
            }
        } catch {}

        if ($HasFailureEvents -and (Test-Path $SettingsJson)) {
            try {
                $settings = Get-Content $SettingsJson -Raw | ConvertFrom-Json
                $siteUID = $settings.siteUID
                if ($siteUID) {
                    $InstallerUrl = "https://$Platform.rmm.datto.com/download-agent/windows/$siteUID"
                    if ($svc) { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 5 }
                    if (Test-Path $AgentDir) { Rename-Item -Path $AgentDir -NewName "$AgentDir.OLD_$TimeStamp" -Force -ErrorAction SilentlyContinue }
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $TempExe = Join-Path $env:TEMP "DattoAgent_$siteUID_$TimeStamp.exe"
                    Invoke-WebRequest -Uri $InstallerUrl -OutFile $TempExe -UseBasicParsing -ErrorAction Stop
                    Start-Process -FilePath $TempExe -ArgumentList "/S" -Wait -PassThru | Out-Null
                    Remove-Item -Path $TempExe -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 30
                    $RemediationPerformed = $true
                }
            } catch {}
        }
    }
}

Write-Host "Script execution complete."
Stop-Transcript

# Upload with simple folder structure and domain in filename
if (($ServiceRestartFixedIssue -or $RemediationPerformed) -and -not [string]::IsNullOrWhiteSpace($LambdaUrl)) {
    Start-Sleep -Seconds 1
    try {
        $mode = if ($ServiceRestartFixedIssue) { 'restart' } else { 'remediation' }
        $prefix = if ($ServiceRestartFixedIssue) { 'ServiceRestartFix/' } else { 'FullRemediation/' }
        
        # Build S3 filename: DOMAIN_HOSTNAME_TIMESTAMP.log (same as local)
        $s3FileName = "${DomainName}_${env:COMPUTERNAME}_${TimeStamp}.log"
        
        $body = [IO.File]::ReadAllText($LogFile)
        
        $uri = "{0}?device={1}&mode={2}&prefix={3}&domain={4}&s3filename={5}&ts={6}" -f `
               $LambdaUrl,
               [Uri]::EscapeDataString($env:COMPUTERNAME),
               [Uri]::EscapeDataString($mode),
               [Uri]::EscapeDataString($prefix),
               [Uri]::EscapeDataString($DomainName),
               [Uri]::EscapeDataString($s3FileName),
               [Uri]::EscapeDataString($TimeStamp)
        
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'text/plain' -TimeoutSec 15 -ErrorAction Stop | Out-Null
    } catch {}
}
