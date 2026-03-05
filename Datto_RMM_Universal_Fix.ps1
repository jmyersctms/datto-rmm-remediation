<#
.SYNOPSIS
    Datto RMM Agent Universal Fix Script

.DESCRIPTION
    Monitors and remediates Datto RMM agent (CagService) failures automatically.

    Behavior:
        1. Waits 5 minutes for system stabilization
        2. Checks CagService status
        3. If stopped: Attempts service restart (90 second timeout)
        4. If restart fails: Checks event log for service failures (lookback window)
        5. If BOTH conditions are true:
              (A) CagService is still NOT Running
              (B) A qualifying CagService failure event is present within the lookback window
           ...then performs full agent reinstall
        6. Uploads logs to S3 (via Lambda URL) ONLY when:
              - A service restart resolves the issue, OR
              - A full remediation is performed

    Deployment:
        - GPO: Deploy via Group Policy scheduled task (domain-joined devices)
        - Intune: Deploy via Platform Scripts (non-domain devices)
        - Datto: Deploy via Datto RMM component (when RMM is healthy)

.PARAMETER LambdaUrl
    Optional Lambda function URL for centralized S3 log uploads.
    If not provided, logs are only stored locally.

.PARAMETER Platform
    Datto RMM platform name (default: "vidal")

.PARAMETER EventLookbackHours
    How far back to look for relevant service failure events (default: 24)

.EXAMPLE
    # Run with S3 logging
    .\Datto_RMM_Universal_Fix.ps1 -LambdaUrl "https://your-lambda-url.amazonaws.com/"

.EXAMPLE
    # Run without S3 logging (local logs only)
    .\Datto_RMM_Universal_Fix.ps1

.NOTES
    Version: 2.3.0
    Requires: PowerShell 5.1+, Windows 10/11, Datto RMM agent previously installed
    Logs: C:\ProgramData\Datto_RMM_Logs\
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$LambdaUrl = "",

    [Parameter(Mandatory=$false)]
    [string]$Platform = "vidal",

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,168)]
    [int]$EventLookbackHours = 24
)

$ErrorActionPreference = 'Stop'

# =========================
# Configuration
# =========================
$ServiceName          = "CagService"
$LocalLogRoot         = "C:\ProgramData\Datto_RMM_Logs"
$StabilizationSeconds = 300   # 5 minutes
$StartTimeoutSeconds  = 90    # service start verification
$PostRemediateWaitSec = 60
$UploadOnNoAction     = $false
$RemediateEnabled     = $true
$Tls12Enforce         = $true
$StartupGraceMinutes  = 10
$RenameRetryCount     = 3
$RenameRetryDelaySec  = 2

# Event IDs commonly seen for service failures/timeouts/crashes
$ServiceFailureEventIds = @(7000,7001,7009,7031,7034)

# Settings.json location (used to derive the "UUID" folder = siteUID)
$SettingsJsonPath = "C:\ProgramData\CentraStage\AEMAgent\Settings.json"

# Runtime diagnostics and outcome tracking
$script:LastEventQueryError = $null
$ActionTaken          = "none"
$RemediationAttempted = $false
$InstallerExitCode    = $null
$InstallerFailed      = $false
$RollbackAttempted    = $false
$RollbackSucceeded    = $false
$BackupCreated        = $false
$BackupPath           = $null
$FinalServiceStatus   = "NotChecked"

# Config parsing logs are queued until logging is initialized.
$PendingConfigLog = New-Object System.Collections.Generic.List[PSObject]

# =========================
# Helpers
# =========================
function Ensure-Dir {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-Timestamp {
    Get-Date -Format "yyyyMMdd_HHmmss"
}

function Queue-ConfigLog {
    param(
        [Parameter(Mandatory)] [ValidateSet('INFO','WARNING','DECISION')] [string]$Level,
        [Parameter(Mandatory)] [string]$Message
    )
    $PendingConfigLog.Add([PSCustomObject]@{
        Level   = $Level
        Message = $Message
    }) | Out-Null
}

function Shorten-Text {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [int]$MaxLength = 220
    )
    if ($Text.Length -le $MaxLength) { return $Text }
    return ($Text.Substring(0, $MaxLength) + "...")
}

function Rename-AgentDirWithRetry {
    param(
        [Parameter(Mandatory)] [string]$AgentDir,
        [int]$Attempts = 3,
        [int]$DelaySec = 2
    )

    $result = [PSCustomObject]@{
        Success    = $false
        BackupPath = $null
        Attempts   = 0
    }

    if (-not (Test-Path $AgentDir)) { return $result }

    $agentLeaf = Split-Path $AgentDir -Leaf
    $parentDir = Split-Path $AgentDir -Parent

    for ($i = 1; $i -le $Attempts; $i++) {
        $result.Attempts = $i
        $backupName = "{0}.OLD_{1}_{2}" -f $agentLeaf, (Get-Timestamp), $i
        $candidateBackupPath = Join-Path $parentDir $backupName

        try {
            Rename-Item -Path $AgentDir -NewName $backupName -Force -ErrorAction Stop
            $result.Success = $true
            $result.BackupPath = $candidateBackupPath
            return $result
        } catch {
            Write-WarnLine "Rename attempt $i/$Attempts failed for '$AgentDir': $($_.Exception.Message)"
            if ($i -lt $Attempts) {
                Start-Sleep -Seconds $DelaySec
            }
        }
    }

    return $result
}

function Restore-AgentDirFromBackup {
    param(
        [Parameter(Mandatory)] [string]$BackupPath,
        [Parameter(Mandatory)] [string]$TargetDir
    )

    if (-not (Test-Path $BackupPath)) {
        Write-WarnLine "Rollback skipped: backup path not found: $BackupPath"
        return $false
    }

    $targetLeaf = Split-Path $TargetDir -Leaf
    if (Test-Path $TargetDir) {
        $failedName = "{0}.FAILED_{1}" -f $targetLeaf, (Get-Timestamp)
        try {
            Rename-Item -Path $TargetDir -NewName $failedName -Force -ErrorAction Stop
            Write-WarnLine "Existing '$TargetDir' moved to '$failedName' before rollback restore."
        } catch {
            Write-ErrorLine "Rollback failed: could not move existing '$TargetDir': $($_.Exception.Message)"
            return $false
        }
    }

    try {
        Rename-Item -Path $BackupPath -NewName $targetLeaf -Force -ErrorAction Stop
        Write-LogLine "Rollback restore succeeded: '$BackupPath' -> '$TargetDir'"
        return $true
    } catch {
        Write-ErrorLine "Rollback restore failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-DomainOrTenantName {
    # Prefer AD domain if joined; fallback to Azure AD tenant; else WORKGROUP
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.PartOfDomain -and $cs.Domain) { return $cs.Domain }
    } catch {}

    # Azure AD tenant name (best-effort)
    try {
        $ds = & dsregcmd /status 2>$null
        if ($ds) {
            $tenantLine = ($ds | Select-String -Pattern 'TenantName\s*:\s*(.+)' | Select-Object -First 1)
            if ($tenantLine) {
                $tenant = $tenantLine.Matches[0].Groups[1].Value.Trim()
                if ($tenant) { return $tenant }
            }
        }
    } catch {}

    return "WORKGROUP"
}

function Get-SiteUid {
    if (Test-Path $SettingsJsonPath) {
        try {
            $json = Get-Content -Path $SettingsJsonPath -Raw | ConvertFrom-Json
            if ($json.siteUID -and ($json.siteUID -match '^[0-9a-fA-F-]{36}$')) {
                return $json.siteUID
            }
        } catch {}
    }
    return $null
}

function Get-CagServiceFailureEvents {
    param(
        [Parameter(Mandatory)] [datetime]$StartTime
    )

    # We filter to Service Control Manager provider and the common IDs above,
    # then require explicit CagService evidence to avoid unrelated service noise.
    $filter = @{
        LogName      = 'System'
        ProviderName = 'Service Control Manager'
        Id           = $ServiceFailureEventIds
        StartTime    = $StartTime
    }

    $script:LastEventQueryError = $null
    try {
        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
    } catch {
        $script:LastEventQueryError = $_.Exception.Message
        return @()
    }

    $hits = foreach ($e in $events) {
        $msg = $e.Message
        if ($msg -match '(?i)\bCagService\b') {
            [PSCustomObject]@{
                TimeCreated = $e.TimeCreated
                Id          = $e.Id
                Provider    = $e.ProviderName
                Message     = ($msg -replace '\s+', ' ').Trim()
            }
        }
    }

    return @($hits | Sort-Object TimeCreated -Descending)
}

function Invoke-LambdaUpload {
    param(
        [Parameter(Mandatory)] [string]$Mode,      # "restart" | "remediation" | "noaction"
        [Parameter(Mandatory)] [string]$DomainName,
        [Parameter(Mandatory)] [string]$DeviceName,
        [Parameter(Mandatory)] [string]$UuidFolder,
        [Parameter(Mandatory)] [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LambdaUrl)) {
        Write-DecisionLine "Upload skipped (mode=$Mode): Lambda URL not configured."
        return
    }

    # Folder preference:
    #   Service Restarts --> UUID --> Device
    #   Remediations     --> UUID --> Device
    $prefixRoot = switch ($Mode) {
        'restart'     { 'ServiceRestarts' }
        'remediation' { 'Remediations' }
        default       { 'NoAction' }
    }
    $prefix     = "$prefixRoot/$UuidFolder/$DeviceName"

    $fileName   = Split-Path $LogPath -Leaf

    # Send log contents as text body.
    # Your Lambda can key off query params to place into S3.
    $uri = "{0}?mode={1}&domain={2}&device={3}&uuid={4}&prefix={5}&s3filename={6}&ts={7}" -f `
        $LambdaUrl,
        [uri]::EscapeDataString($Mode),
        [uri]::EscapeDataString($DomainName),
        [uri]::EscapeDataString($DeviceName),
        [uri]::EscapeDataString($UuidFolder),
        [uri]::EscapeDataString($prefix),
        [uri]::EscapeDataString($fileName),
        [uri]::EscapeDataString((Get-Date).ToString("o"))

    try {
        $body = Get-Content -Path $LogPath -Raw -ErrorAction Stop
        Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'text/plain' -TimeoutSec 30 | Out-Null
        Write-DecisionLine "Upload complete (mode=$Mode, prefix=$prefix)."
    } catch {
        # Don't fail the whole fix if logging fails
        Write-WarnLine "S3/Lambda upload failed (mode=$Mode): $($_.Exception.Message)"
    }
}

# Datto component environment variable overrides (if provided)
if (-not [string]::IsNullOrWhiteSpace($env:LAMBDA_URL)) {
    $candidate = $env:LAMBDA_URL.Trim()
    $candidateUri = $null
    if ([uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$candidateUri)) {
        $LambdaUrl = $candidate
        Queue-ConfigLog -Level DECISION -Message "Config override applied: LAMBDA_URL (source=env)."
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid LAMBDA_URL '$candidate' ignored; using default/parameter value."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:DATTO_PLATFORM)) {
    $candidate = $env:DATTO_PLATFORM.Trim().ToLower()
    if ($candidate -match '^[a-z0-9-]+$') {
        $Platform = $candidate
        Queue-ConfigLog -Level DECISION -Message "Config override applied: DATTO_PLATFORM='$Platform' (source=env)."
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid DATTO_PLATFORM '$candidate' ignored; expected pattern ^[a-z0-9-]+$."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:EVENT_LOOKBACK_HOURS)) {
    $candidateRaw = $env:EVENT_LOOKBACK_HOURS.Trim()
    if ($candidateRaw -match '^\d+$') {
        $candidate = [int]$candidateRaw
        if ($candidate -ge 1 -and $candidate -le 168) {
            $EventLookbackHours = $candidate
            Queue-ConfigLog -Level DECISION -Message "Config override applied: EVENT_LOOKBACK_HOURS=$EventLookbackHours (source=env)."
        } else {
            Queue-ConfigLog -Level WARNING -Message "Invalid EVENT_LOOKBACK_HOURS '$candidateRaw' ignored; valid range is 1-168."
        }
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid EVENT_LOOKBACK_HOURS '$candidateRaw' ignored; expected integer."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:STABILIZATION_SECONDS)) {
    $candidateRaw = $env:STABILIZATION_SECONDS.Trim()
    if ($candidateRaw -match '^\d+$') {
        $candidate = [int]$candidateRaw
        if ($candidate -ge 0 -and $candidate -le 1800) {
            $StabilizationSeconds = $candidate
            Queue-ConfigLog -Level DECISION -Message "Config override applied: STABILIZATION_SECONDS=$StabilizationSeconds (source=env)."
        } else {
            Queue-ConfigLog -Level WARNING -Message "Invalid STABILIZATION_SECONDS '$candidateRaw' ignored; valid range is 0-1800."
        }
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid STABILIZATION_SECONDS '$candidateRaw' ignored; expected integer."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:START_TIMEOUT_SECONDS)) {
    $candidateRaw = $env:START_TIMEOUT_SECONDS.Trim()
    if ($candidateRaw -match '^\d+$') {
        $candidate = [int]$candidateRaw
        if ($candidate -ge 5 -and $candidate -le 600) {
            $StartTimeoutSeconds = $candidate
            Queue-ConfigLog -Level DECISION -Message "Config override applied: START_TIMEOUT_SECONDS=$StartTimeoutSeconds (source=env)."
        } else {
            Queue-ConfigLog -Level WARNING -Message "Invalid START_TIMEOUT_SECONDS '$candidateRaw' ignored; valid range is 5-600."
        }
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid START_TIMEOUT_SECONDS '$candidateRaw' ignored; expected integer."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:POST_REMEDIATE_WAIT_SECONDS)) {
    $candidateRaw = $env:POST_REMEDIATE_WAIT_SECONDS.Trim()
    if ($candidateRaw -match '^\d+$') {
        $candidate = [int]$candidateRaw
        if ($candidate -ge 0 -and $candidate -le 600) {
            $PostRemediateWaitSec = $candidate
            Queue-ConfigLog -Level DECISION -Message "Config override applied: POST_REMEDIATE_WAIT_SECONDS=$PostRemediateWaitSec (source=env)."
        } else {
            Queue-ConfigLog -Level WARNING -Message "Invalid POST_REMEDIATE_WAIT_SECONDS '$candidateRaw' ignored; valid range is 0-600."
        }
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid POST_REMEDIATE_WAIT_SECONDS '$candidateRaw' ignored; expected integer."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:LOG_ROOT)) {
    $LocalLogRoot = $env:LOG_ROOT.Trim()
    Queue-ConfigLog -Level DECISION -Message "Config override applied: LOG_ROOT='$LocalLogRoot' (source=env)."
}

if (-not [string]::IsNullOrWhiteSpace($env:UPLOAD_ON_NO_ACTION)) {
    $candidateRaw = $env:UPLOAD_ON_NO_ACTION.Trim()
    if ($candidateRaw -match '^(?i:true|false)$') {
        $UploadOnNoAction = [bool]::Parse($candidateRaw)
        Queue-ConfigLog -Level DECISION -Message "Config override applied: UPLOAD_ON_NO_ACTION=$UploadOnNoAction (source=env)."
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid UPLOAD_ON_NO_ACTION '$candidateRaw' ignored; expected TRUE/FALSE."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:REMEDIATE_ENABLED)) {
    $candidateRaw = $env:REMEDIATE_ENABLED.Trim()
    if ($candidateRaw -match '^(?i:true|false)$') {
        $RemediateEnabled = [bool]::Parse($candidateRaw)
        Queue-ConfigLog -Level DECISION -Message "Config override applied: REMEDIATE_ENABLED=$RemediateEnabled (source=env)."
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid REMEDIATE_ENABLED '$candidateRaw' ignored; expected TRUE/FALSE."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:TLS12_ENFORCE)) {
    $candidateRaw = $env:TLS12_ENFORCE.Trim()
    if ($candidateRaw -match '^(?i:true|false)$') {
        $Tls12Enforce = [bool]::Parse($candidateRaw)
        Queue-ConfigLog -Level DECISION -Message "Config override applied: TLS12_ENFORCE=$Tls12Enforce (source=env)."
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid TLS12_ENFORCE '$candidateRaw' ignored; expected TRUE/FALSE."
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:STARTUP_GRACE_MINUTES)) {
    $candidateRaw = $env:STARTUP_GRACE_MINUTES.Trim()
    if ($candidateRaw -match '^\d+$') {
        $candidate = [int]$candidateRaw
        if ($candidate -ge 0 -and $candidate -le 120) {
            $StartupGraceMinutes = $candidate
            Queue-ConfigLog -Level DECISION -Message "Config override applied: STARTUP_GRACE_MINUTES=$StartupGraceMinutes (source=env)."
        } else {
            Queue-ConfigLog -Level WARNING -Message "Invalid STARTUP_GRACE_MINUTES '$candidateRaw' ignored; valid range is 0-120."
        }
    } else {
        Queue-ConfigLog -Level WARNING -Message "Invalid STARTUP_GRACE_MINUTES '$candidateRaw' ignored; expected integer."
    }
}

# Service control paths require elevated context.
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: Script must run elevated (Administrator/SYSTEM). Exiting."
        exit 1
    }
} catch {
    Write-Host "ERROR: Unable to validate execution context. Exiting."
    exit 1
}

# =========================
# Start logging
# =========================
Ensure-Dir $LocalLogRoot

$DomainName   = Get-DomainOrTenantName
$DeviceName   = $env:COMPUTERNAME
$Timestamp    = Get-Timestamp
$LogFileName  = "{0}_{1}_{2}.log" -f $DomainName, $DeviceName, $Timestamp
$LogPath      = Join-Path $LocalLogRoot $LogFileName
$ActionTaken  = "none"

$transcribing = $false
try {
    Start-Transcript -Path $LogPath -Append | Out-Null
    $transcribing = $true
} catch {
    # If transcript can't start, we still continue with best-effort Write-Host
}

function Write-LogLine {
    param([Parameter(Mandatory)][string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
    Write-Host $line
}

function Write-WarnLine {
    param([Parameter(Mandatory)][string]$Message)
    Write-LogLine ("WARNING: {0}" -f $Message)
}

function Write-ErrorLine {
    param([Parameter(Mandatory)][string]$Message)
    Write-LogLine ("ERROR: {0}" -f $Message)
}

function Write-DecisionLine {
    param([Parameter(Mandatory)][string]$Message)
    Write-LogLine ("DECISION: {0}" -f $Message)
}

if (-not $transcribing) {
    Write-WarnLine "Transcript could not be started. Continuing with file/console logging."
}

Write-LogLine "===== Datto RMM Universal Fix starting at $(Get-Date) on $DeviceName ====="
Write-LogLine "Domain/Tenant: $DomainName"
Write-LogLine "Platform: $Platform"
Write-LogLine "Event lookback: $EventLookbackHours hour(s)"
Write-LogLine "Remediation enabled: $RemediateEnabled"
Write-LogLine "Upload on no action: $UploadOnNoAction"
Write-LogLine "Startup grace window: $StartupGraceMinutes minute(s)"
Write-LogLine "Rename retries: $RenameRetryCount attempt(s), delay: $RenameRetryDelaySec second(s)"

foreach ($entry in $PendingConfigLog) {
    switch ($entry.Level) {
        'WARNING'  { Write-WarnLine $entry.Message }
        'DECISION' { Write-DecisionLine $entry.Message }
        default    { Write-LogLine $entry.Message }
    }
}

Write-LogLine "Waiting $([int]($StabilizationSeconds/60)) minutes before checking $ServiceName to allow system services to stabilize..."
Start-Sleep -Seconds $StabilizationSeconds

# =========================
# Core logic
# =========================
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-ErrorLine "Service '$ServiceName' not found."
    Write-DecisionLine "Exiting because required service is missing."
    $FinalServiceStatus = "NotFound"
    goto Done
}

$svc.Refresh()
Write-LogLine "Initial $ServiceName status: $($svc.Status)"

# IMPORTANT CHANGE:
# If service is currently Running, we do NOT remediate based on historical events.
if ($svc.Status -eq 'Running') {
    Write-DecisionLine "$ServiceName is Running. No remediation path entered (historical events intentionally ignored)."
    $FinalServiceStatus = "Running"
    goto Done
}

# Service is NOT running -> attempt start
Write-LogLine "$ServiceName is NOT Running. Attempting to start service (timeout ${StartTimeoutSeconds}s)..."
$startSucceeded = $false

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
} catch {
    Write-WarnLine "Start-Service threw exception: $($_.Exception.Message)"
}

# Wait up to timeout for Running
$deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
do {
    Start-Sleep -Seconds 5
    $svc.Refresh()
    Write-LogLine "Waiting for $ServiceName... current status: $($svc.Status)"
    if ($svc.Status -eq 'Running') { $startSucceeded = $true; break }
} while ((Get-Date) -lt $deadline)

if ($startSucceeded) {
    Write-LogLine "SUCCESS: $ServiceName started and is Running. No full remediation required."
    $ActionTaken = "restart"
    $FinalServiceStatus = "Running"
    Write-DecisionLine "Restart path resolved service outage; full remediation skipped."

    # Upload ONLY because restart resolved a stopped service
    $siteUid = Get-SiteUid
    if (-not $siteUid) {
        $siteUid = "UnknownUUID"
        Write-WarnLine "siteUID unavailable for restart upload; using UnknownUUID in upload path."
    }
    Invoke-LambdaUpload -Mode "restart" -DomainName $DomainName -DeviceName $DeviceName -UuidFolder $siteUid -LogPath $LogPath

    goto Done
}

Write-WarnLine "Start attempt did not result in Running state."

# Now (and ONLY now) check for qualifying failure events within lookback window
$lookbackStart = (Get-Date).AddHours(-1 * $EventLookbackHours)
Write-LogLine "Checking System event log for qualifying service failure events since $lookbackStart (Provider: Service Control Manager, IDs: $($ServiceFailureEventIds -join ','))..."
$failEvents = Get-CagServiceFailureEvents -StartTime $lookbackStart

if (-not $failEvents -or $failEvents.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($script:LastEventQueryError)) {
        Write-WarnLine "Event query returned no data due to query/access issue: $script:LastEventQueryError"
    }
    Write-LogLine "No qualifying $ServiceName failure events found in the last $EventLookbackHours hour(s)."
    Write-DecisionLine "Skipping full remediation: service is not running but no corroborating failure event was found."
    $FinalServiceStatus = "$($svc.Status)"
    goto Done
}

Write-LogLine "Found $($failEvents.Count) qualifying failure event(s)."
Write-LogLine ("Event window: newest={0} oldest={1}" -f $failEvents[0].TimeCreated, $failEvents[-1].TimeCreated)
Write-LogLine "Top 3 qualifying events:"
foreach ($evt in ($failEvents | Select-Object -First 3)) {
    Write-LogLine ("  - {0} | ID {1} | {2}" -f $evt.TimeCreated, $evt.Id, (Shorten-Text -Text $evt.Message -MaxLength 220))
}

# BOTH conditions met:
# (A) service not running
# (B) failure event exists
if (-not $RemediateEnabled) {
    Write-DecisionLine "Remediation disabled by configuration (REMEDIATE_ENABLED=FALSE). Reinstall path skipped."
    $FinalServiceStatus = "$($svc.Status)"
    goto Done
}

if ($StartupGraceMinutes -gt 0) {
    try {
        $bootAt = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $uptime = (Get-Date) - $bootAt
        if ($uptime.TotalMinutes -lt $StartupGraceMinutes) {
            Write-DecisionLine ("Inside startup grace window ({0:N1} < {1} minutes). Skipping full remediation to avoid transient startup churn." -f $uptime.TotalMinutes, $StartupGraceMinutes)
            $FinalServiceStatus = "$($svc.Status)"
            goto Done
        }
    } catch {
        Write-WarnLine "Could not calculate uptime for startup grace evaluation: $($_.Exception.Message)"
    }
}

# Final sanity check: service may recover while we query events or evaluate guards.
try {
    $svc.Refresh()
} catch {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

if ($svc -and $svc.Status -eq 'Running') {
    Write-DecisionLine "$ServiceName recovered to Running after start timeout/event review. Skipping full remediation."
    $FinalServiceStatus = "Running"
    goto Done
}

Write-DecisionLine "Both conditions met (service not Running + failure event detected). Proceeding with FULL REMEDIATION."
$ActionTaken = "remediation"
$RemediationAttempted = $true

# =========================
# Full remediation
# =========================
# Determine siteUID before any destructive change
$siteUid = Get-SiteUid
if (-not $siteUid) {
    Write-ErrorLine "Unable to read valid siteUID from $SettingsJsonPath."
    Write-DecisionLine "Aborting full remediation before any destructive change."
    $FinalServiceStatus = "$($svc.Status)"
    goto Done
} else {
    Write-LogLine "Using siteUID (UUID folder): $siteUid"
}

# Preflight download before changing service/files
if ($Tls12Enforce) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-DecisionLine "TLS 1.2 enforced for web requests."
} else {
    Write-WarnLine "TLS12_ENFORCE is FALSE; using system default security protocol."
}

$downloadUrl = "https://$Platform.rmm.datto.com/download-agent/windows/$siteUid"
$tempExe     = Join-Path $env:TEMP ("AgentInstall_{0}.exe" -f $siteUid)

Write-LogLine "Preflight: downloading agent installer before mutation: $downloadUrl"
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempExe -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path $tempExe)) {
        throw "Installer not found at expected path after download."
    }

    $downloaded = Get-Item -Path $tempExe -ErrorAction Stop
    if ($downloaded.Length -le 0) {
        throw "Downloaded installer is empty."
    }

    Write-LogLine "Preflight download complete: $tempExe ($($downloaded.Length) bytes)"
} catch {
    Write-ErrorLine "Preflight download failed. Aborting before service/file changes: $($_.Exception.Message)"
    $FinalServiceStatus = "$($svc.Status)"
    goto Done
}

try {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
} catch {
    Write-WarnLine "Stop-Service raised an exception during remediation: $($_.Exception.Message)"
}

# Rename agent dir (forensics)
$agentDir = "C:\ProgramData\CentraStage"
if (Test-Path $agentDir) {
    $renameResult = Rename-AgentDirWithRetry -AgentDir $agentDir -Attempts $RenameRetryCount -DelaySec $RenameRetryDelaySec
    if ($renameResult.Success) {
        $BackupCreated = $true
        $BackupPath = $renameResult.BackupPath
        Write-LogLine "Agent directory backup created: '$BackupPath'"
    } else {
        Write-WarnLine "Agent directory rename failed after $($renameResult.Attempts) attempt(s). Continuing with installer per policy."
    }
} else {
    Write-WarnLine "Agent directory not found at $agentDir; continuing installer path without backup."
}

Write-LogLine "Running installer silently..."
try {
    $p = Start-Process -FilePath $tempExe -ArgumentList "/S" -Wait -PassThru -ErrorAction Stop
    $InstallerExitCode = $p.ExitCode
    Write-LogLine "Installer exit code: $InstallerExitCode"
    if ($InstallerExitCode -ne 0) {
        $InstallerFailed = $true
        Write-ErrorLine "Installer returned non-zero exit code: $InstallerExitCode"
    }
} catch {
    $InstallerFailed = $true
    Write-ErrorLine "Installer execution failed: $($_.Exception.Message)"
}

try {
    Remove-Item $tempExe -Force -ErrorAction SilentlyContinue
} catch {
    Write-WarnLine "Failed to remove temporary installer '$tempExe': $($_.Exception.Message)"
}

Write-LogLine "Waiting $PostRemediateWaitSec seconds, then re-checking $ServiceName..."
Start-Sleep -Seconds $PostRemediateWaitSec

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) { $svc.Refresh() }

if ($svc -and $svc.Status -eq 'Running') {
    Write-LogLine "SUCCESS: $ServiceName is Running after FULL REMEDIATION."
    $FinalServiceStatus = "Running"
} else {
    $st = if ($svc) { $svc.Status } else { "NotFound" }
    $FinalServiceStatus = "$st"
    Write-ErrorLine "$ServiceName is not Running after FULL REMEDIATION. Status: $st"
    $InstallerFailed = $true
}

if ($BackupCreated -and ($InstallerFailed -or $FinalServiceStatus -ne "Running")) {
    $RollbackAttempted = $true
    Write-DecisionLine "Attempting rollback restore from backup due to remediation failure signal."
    $RollbackSucceeded = Restore-AgentDirFromBackup -BackupPath $BackupPath -TargetDir $agentDir

    if ($RollbackSucceeded) {
        Start-Sleep -Seconds 5
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) { $svc.Refresh() }
        $FinalServiceStatus = if ($svc) { "$($svc.Status)" } else { "NotFound" }
        Write-LogLine "Post-rollback service status: $FinalServiceStatus"
    }
} elseif (-not $BackupCreated -and ($InstallerFailed -or $FinalServiceStatus -ne "Running")) {
    Write-WarnLine "Rollback not possible because no backup directory was created."
}

# Upload ONLY because full remediation was performed
Invoke-LambdaUpload -Mode "remediation" -DomainName $DomainName -DeviceName $DeviceName -UuidFolder $siteUid -LogPath $LogPath

# =========================
# Done
# =========================
:Done
if ($ActionTaken -eq "none" -and $UploadOnNoAction) {
    $siteUid = Get-SiteUid
    if (-not $siteUid) {
        $siteUid = "UnknownUUID"
        Write-WarnLine "siteUID unavailable for no-action upload; using UnknownUUID in upload path."
    }
    Invoke-LambdaUpload -Mode "noaction" -DomainName $DomainName -DeviceName $DeviceName -UuidFolder $siteUid -LogPath $LogPath
} elseif ($ActionTaken -eq "none" -and -not $UploadOnNoAction) {
    Write-DecisionLine "No-action upload skipped because UPLOAD_ON_NO_ACTION is FALSE."
}

if ($FinalServiceStatus -eq "NotChecked") {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $svc.Refresh()
        $FinalServiceStatus = "$($svc.Status)"
    } else {
        $FinalServiceStatus = "NotFound"
    }
}

Write-LogLine "Run Summary:"
Write-LogLine ("  ActionTaken: {0}" -f $ActionTaken)
Write-LogLine ("  RemediationAttempted: {0}" -f $RemediationAttempted)
Write-LogLine ("  InstallerExitCode: {0}" -f ($(if ($null -eq $InstallerExitCode) { "N/A" } else { $InstallerExitCode })))
Write-LogLine ("  RollbackAttempted: {0}" -f $RollbackAttempted)
Write-LogLine ("  RollbackSucceeded: {0}" -f $RollbackSucceeded)
Write-LogLine ("  FinalServiceStatus: {0}" -f $FinalServiceStatus)
Write-LogLine "===== Datto RMM Universal Fix finished at $(Get-Date) on $DeviceName ====="

if ($transcribing) {
    try { Stop-Transcript | Out-Null } catch {}
}
