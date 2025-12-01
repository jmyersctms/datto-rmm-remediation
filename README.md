# Datto RMM Self-Healing Remediation

Automated monitoring and remediation solution for Datto RMM agents. Detects and fixes offline or stopped CagService through service restart or full agent reinstallation.

## Features

- 🔄 **Automatic Service Restart** - Attempts to restart CagService with 90-second timeout
- 🔍 **Event Log Analysis** - Checks Windows Event Log for service failure patterns
- 🚨 **Full Remediation** - Reinstalls Datto RMM agent when restart fails
- 📊 **Centralized Logging** - Optional S3 upload via AWS Lambda
- 🌐 **Multi-Platform Support** - Works with domain-joined (GPO) and non-domain devices (Intune)
- 🔐 **Azure AD Detection** - Properly identifies Azure AD tenant names

## Requirements

- Windows 10/11 (excluding Home editions)
- PowerShell 5.1 or later
- Datto RMM agent previously installed
- Administrator/SYSTEM privileges

## Deployment Methods

### Option 1: Group Policy (Domain-Joined Devices)

Deploy via GPO scheduled task that runs:
- At system startup (5-minute delay)
- Daily at 12:00 PM

**Script location:** `\\domain.com\SYSVOL\domain.com\scripts\Datto\Datto_RMM_Universal_Fix.ps1`

### Option 2: Microsoft Intune (Non-Domain Devices)

Deploy as Platform Script or Proactive Remediation to Azure AD joined or workgroup devices.

### Option 3: Direct Execution

Run manually for testing or one-off remediation:

```powershell
# Without S3 logging
.\Datto_RMM_Universal_Fix.ps1

# With S3 logging
.\Datto_RMM_Universal_Fix.ps1 -LambdaUrl "https://your-lambda-url.amazonaws.com/"
```

## Parameters

### `-LambdaUrl` (Optional)
AWS Lambda function URL for centralized S3 log uploads.

**Example:**
```powershell
-LambdaUrl "https://abc123.lambda-url.us-east-1.on.aws/"
```

### `-Platform` (Optional)
Datto RMM platform name. Default: `"vidal"`

**Example:**
```powershell
-Platform "concord"
```

## How It Works

1. **System Stabilization** - Waits 5 minutes after boot for services to initialize
2. **Service Check** - Checks if CagService is running
3. **Service Restart** - If stopped, attempts to start the service (90-second timeout)
4. **Event Log Analysis** - Checks for service failure events (IDs: 7000, 7001, 7009, 7031, 7034)
5. **Full Remediation** - If restart fails AND event log shows failures:
   - Stops CagService
   - Renames agent directory (`C:\ProgramData\CentraStage` → `CentraStage.OLD_timestamp`)
   - Downloads fresh agent installer from Datto portal
   - Installs silently
6. **Logging** - Creates detailed transcript log locally and optionally uploads to S3

## Log Files

**Local logs:** `C:\ProgramData\Datto_RMM_Logs\`

**Filename format:** `DOMAIN_HOSTNAME_TIMESTAMP.log`

**Examples:**
- `contoso.com_SERVER01_20251201_120530.log`
- `contoso.onmicrosoft.com_LAPTOP42_20251201_083045.log`
- `WORKGROUP_PC123_20251201_094512.log`

## S3 Folder Structure

When Lambda URL is provided, logs are organized by remediation type:

```
S3_BUCKET/
├── ServiceRestartFix/
│   ├── contoso.com_SERVER01_20251201_120530.log
│   └── fabrikam.com_WS042_20251201_141203.log
└── FullRemediation/
    ├── contoso.com_DC03_20251201_083421.log
    └── adventureworks.local_SQL01_20251201_152337.log
```

## AWS Lambda Setup (Optional)

If you want centralized S3 logging, you'll need:

1. **S3 Bucket** - For storing log files
2. **Lambda Function** - To receive logs and upload to S3
3. **Lambda Function URL** - Public HTTPS endpoint

**Required query parameters:**
- `device` - Hostname
- `mode` - `restart` or `remediation`
- `prefix` - S3 folder path
- `domain` - Domain or tenant name
- `s3filename` - Log filename
- `ts` - Timestamp

See the [Lambda example](#lambda-example) below for implementation details.

## Security Considerations

- Script runs as SYSTEM (highest privileges)
- Lambda URL should be kept private if using S3 logging
- No credentials are stored in the script
- Agent downloads use HTTPS (TLS 1.2)
- Old agent directories are renamed, not deleted (for forensics)

## Troubleshooting

**Script doesn't run:**
- Verify scheduled task exists and is enabled
- Check execution policy: `Get-ExecutionPolicy`
- Review Windows Event Log → Task Scheduler

**Service restart fails:**
- Check if CagService exists: `Get-Service CagService`
- Verify Settings.json exists: `C:\ProgramData\CentraStage\AEMAgent\Settings.json`
- Review local log file for errors

**Logs not uploading to S3:**
- Verify Lambda URL is correct and accessible
- Check Lambda function logs in CloudWatch
- Test Lambda endpoint manually with `Invoke-RestMethod`

**Agent reinstall fails:**
- Verify siteUID in Settings.json is valid GUID format
- Check network connectivity to `*.rmm.datto.com`
- Ensure HTTPS/TLS 1.2 is not blocked by firewall

## Version History

### v2.0.8 (2025-12-01)
- Improved Azure AD tenant name detection using `dsregcmd`
- Enhanced domain detection fallback logic
- Added configurable Lambda URL parameter
- Updated log filename format to include domain/tenant

### v2.0.0 (2025-11-28)
- Initial public release
- Core remediation logic
- GPO and Intune deployment support

## Lambda Example

Sample Python Lambda function for S3 uploads:

```python
import json
import boto3
from datetime import datetime

BUCKET_NAME = "your-log-bucket"
s3 = boto3.client("s3")

def lambda_handler(event, context):
    try:
        # Get query parameters
        qs = event.get("queryStringParameters") or {}
        prefix = qs.get("prefix", "")
        s3filename = qs.get("s3filename", "")
        
        if prefix and s3filename:
            key = f"{prefix}{s3filename}"
        else:
            # Fallback for old format
            device = qs.get("device", "unknown")
            ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
            key = f"{device}/{ts}.log"
        
        # Get log content from body
        body = event.get("body", "")
        if event.get("isBase64Encoded"):
            import base64
            body = base64.b64decode(body).decode("utf-8")
        
        # Upload to S3
        s3.put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=body.encode("utf-8"),
            ContentType="text/plain"
        )
        
        return {
            "statusCode": 200,
            "body": json.dumps({"ok": True, "key": key})
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)})
        }
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For issues or questions:
- Open an issue on GitHub
- Check existing issues for solutions
- Review troubleshooting section above

## Acknowledgments

Built for MSPs managing Datto RMM across multiple client environments.
