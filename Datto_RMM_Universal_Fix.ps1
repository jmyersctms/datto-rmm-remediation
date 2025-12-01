<#
.SYNOPSIS
    Datto RMM Agent Universal Fix Script

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
    Version: 2.0.9
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
$GlobalSiteUid = $null

# Ensure log directory exists
if (-not (Test-Path $LogDirectory)) { 
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null 
}

$TimeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Get domain name or Azure AD tenant for log filename
$DomainName = try {
    # First try traditional AD domain
    if ($env:USERDNSDOMAIN) {
        $env:USERDNSDOMAIN
    }
    else {
        # Try Azure AD / Entra ID detection
        try {
            $dsregOutput = dsregcmd /status 2>&1
            
            # Look for TenantName line
            $tenantLine = $dsregOutput | Where-Object { $_ -match '^\s*TenantName\s*:' }
            
            if ($tenantLine) {
                $tenantName = ($tenantLine -split ':', 2)[1].Trim()
                
                # Clean up tenant name - remove spaces and special chars for filename safety
                $tenantName = $tenantName -replace '[^\w\-\.]', '_'
                
                if (![string]::IsNullOrWhiteSpace($tenantName)) {
                    $tenantName
                }
                else {
                    "WORKGROUP"
                }
            }
            else {
                "WORKGROUP"
            }
        }
        catch {
            "WORKGROUP"
        }
    }
}
catch {
    "WORKGROUP"
}

if ([string]::IsNullOrWhiteSpace($DomainName)) { 
    $DomainName = "WORKGROUP" 
}

$LogFile = Join-Path $LogDirectory "${DomainName}_${env:COMPUTERNAME}_${TimeStamp}.log"

Start-Transcript -Path $LogFile -Force
Write-Host "===== Datto RMM Universal Fix v2.0.9 starting at $(Get-Date) on $env:COMPUTERNAME (Domain/Tenant: $DomainName) ====="
if ([string]::IsNullOrWhiteSpace($LambdaUrl)) {
    Write-Host "S3 logging: Disabled (no Lambda URL provided)"
} else {
    Write-Host "S3 logging: Enabled"
}

# Try to read siteUID early
if (Test-Path $SettingsJson) {
    try {
        $settings = Get-Content $SettingsJson -Raw | ConvertFrom-Json
        $GlobalSiteUid = $settings.siteUID
        if (-not [string]::IsNullOrWhiteSpace($GlobalSiteUid)) {
            Write-Host "Detected siteUID: $GlobalSiteUid"
        }
    } catch {
        Write-Warning "Early siteUID read failed: $($_.Exception.Message)"
    }
}

Write-Host "Waiting 5 minutes for system stabilization..."
Start-Sleep -Seconds 300

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) { 
    Write-Host "Initial CagService status: $($svc.Status)" 
}

# Service Restart Logic
if ($svc -and $svc.Status -eq 'Stopped') {
    Write-Host "CagService stopped. Attempting restart..."
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    
    $maxWait = 90
    $interval = 5
    $elapsed = 0
    
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
    
    if (-not $ServiceRestartFixedIssue) {
        Write-Warning "Service restart failed or timed out after $maxWait seconds."
    }
}

# Event Log Check
if (-not $ServiceRestartFixedIssue) {
    Write-Host "Checking event log for CagService failures in the last $FailureLookbackHours hours..."
    
    $lookbackTime = (Get-Date).AddHours(-$FailureLookbackHours)
    $failureEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ID = $FailureEventIds
        StartTime = $lookbackTime
    } -ErrorAction SilentlyContinue | Where-Object { $_.Message -like "*$ServiceName*" }
    
    if ($failureEvents) {
        Write-Host "Found $($failureEvents.Count) CagService failure event(s). Proceeding with full remediation."
        
        # Full Remediation Logic
        try {
            # Stop service
            Write-Host "Stopping CagService..."
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            
            # Rename old agent directory
            if (Test-Path $AgentDir) {
                $backupName = "CentraStage.OLD_$TimeStamp"
                $backupPath = Join-Path (Split-Path $AgentDir -Parent) $backupName
                Write-Host "Renaming $AgentDir to $backupName..."
                Rename-Item -Path $AgentDir -NewName $backupName -Force
            }
            
            # Read siteUID from backed up Settings.json
            $siteUID = $null
            $backupSettingsJson = Join-Path $backupPath "AEMAgent\Settings.json"
            
            if (Test-Path $backupSettingsJson) {
                try {
                    $settings = Get-Content $backupSettingsJson -Raw | ConvertFrom-Json
                    $siteUID = $settings.siteUID
                    Write-Host "Retrieved siteUID from backup: $siteUID"
                } catch {
                    Write-Warning "Could not read siteUID from backup: $($_.Exception.Message)"
                }
            }
            
            if ([string]::IsNullOrWhiteSpace($siteUID)) {
                Write-Error "Could not retrieve siteUID. Cannot download installer."
                throw "Missing siteUID"
            }
            
            # Download installer
            $installerUrl = "https://$Platform.centrastage.net/csm/profile/downloadAgent/$siteUID"
            $installerPath = Join-Path $env:TEMP "DattoRMMInstaller_$TimeStamp.exe"
            
            Write-Host "Downloading installer from: $installerUrl"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 300
            
            if (-not (Test-Path $installerPath)) {
                throw "Installer download failed"
            }
            
            Write-Host "Installer downloaded successfully: $installerPath"
            
            # Install agent
            Write-Host "Installing Datto RMM agent silently..."
            $installProcess = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
            
            if ($installProcess.ExitCode -eq 0) {
                Write-Host "Agent installation completed successfully."
                $RemediationPerformed = $true
            } else {
                Write-Warning "Agent installation returned exit code: $($installProcess.ExitCode)"
            }
            
            # Cleanup installer
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
            
        } catch {
            Write-Error "Full remediation failed: $($_.Exception.Message)"
        }
        
    } else {
        Write-Host "No CagService failure events found in the last $FailureLookbackHours hours."
    }
}

Write-Host "Script execution complete."
Write-Host "ServiceRestartFixedIssue = $ServiceRestartFixedIssue"
Write-Host "RemediationPerformed = $RemediationPerformed"
Stop-Transcript

# Upload to S3 with folder structure
if (($ServiceRestartFixedIssue -or $RemediationPerformed) -and -not [string]::IsNullOrWhiteSpace($LambdaUrl)) {
    Start-Sleep -Seconds 1
    
    try {
        $mode = 'noaction'
        $prefix = $null
        
        if ($ServiceRestartFixedIssue) {
            $mode = 'restart'
            $prefix = "ServiceRestartFix/"
        }
        elseif ($RemediationPerformed) {
            $mode = 'remediation'
            $prefix = "FullRemediation/"
        }
        
        if ($mode -ne 'noaction') {
            $fileName = Split-Path $LogFile -Leaf
            $body = [IO.File]::ReadAllText($LogFile)
            
            # Build query string with all parameters
            $queryParams = @(
                "device=$([Uri]::EscapeDataString($env:COMPUTERNAME))"
                "mode=$([Uri]::EscapeDataString($mode))"
                "prefix=$([Uri]::EscapeDataString($prefix))"
                "domain=$([Uri]::EscapeDataString($DomainName))"
                "s3filename=$([Uri]::EscapeDataString($fileName))"
                "ts=$([Uri]::EscapeDataString($TimeStamp))"
            )
            
            if ($GlobalSiteUid) {
                $queryParams += "siteuid=$([Uri]::EscapeDataString($GlobalSiteUid))"
            }
            
            $uri = "{0}?{1}" -f $LambdaUrl.TrimEnd('/'), ($queryParams -join '&')
            
            Write-Host "Uploading log to S3..."
            Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'text/plain' -TimeoutSec 15 -ErrorAction Stop | Out-Null
            Write-Host "Log uploaded successfully."
        }
    } catch {
        Write-Warning "Failed to upload log to S3: $($_.Exception.Message)"
    }
}
