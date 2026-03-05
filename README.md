# Datto RMM Agent Remediation Framework

This repository contains a remediation framework designed to monitor and repair Datto RMM agents when the **CagService** becomes non-functional or stops running.

The goal is to provide **safe, automated remediation** while avoiding unnecessary agent reinstalls caused by benign service events.

---

# Background

During normal operation, Datto RMM agents occasionally log **CagService failure events** in the Windows System Event Log.

Through investigation with Datto Support (Ticket **#6736841**), it was determined that:

- Approximately **98% of observed CagService failure events** occurred during normal system state transitions such as:
  - Shutdown
  - Sleep
  - Hibernate
  - Resume

These events were being recorded by the Windows **Service Control Manager**, even though:

- The Datto agent recovered automatically
- The service was already **Running** again by the time remediation scripts executed

Earlier versions of this remediation script interpreted **any failure event within a time window** as justification to reinstall the agent.

This resulted in **unnecessary agent reinstallations**, even when the agent was healthy.

Datto Support confirmed this behavior is related to a known internal issue:

> PT 5134512 — CagService failure events logged during power state transitions.

To address this, the remediation logic was redesigned to require **multiple verification conditions** before reinstalling the agent.

---

# Problem Statement

Datto RMM agents in our environment were triggering repeated remediation actions due to CagService failure events recorded during normal Windows power-state transitions.

Observed behavior:

- CagService failure events logged during:
  - Shutdown
  - Sleep
  - Hibernate
  - Resume
- The service automatically recovered within seconds.
- By the time remediation executed, **CagService was already Running**.
- However, historical failure events within the lookback window caused full agent reinstalls.

## Impact

- Unnecessary agent uninstall/reinstall cycles
- Increased bandwidth usage
- Excessive log noise
- Operational uncertainty around true agent failures
- Risk of masking legitimate underlying issues

Through coordination with Datto Support, it was confirmed that:

- ~98% of failure events were benign and power-state related
- This behavior aligns with internal tracking issue **PT 5134512**

The core issue is not that remediation is impossible — it is that:

> Benign service state transitions are logged in a way that is indistinguishable from true service failures without additional contextual validation.

Therefore remediation logic must:

- Validate current service health
- Validate recent failure evidence
- Avoid acting on stale or benign events

---

# Desired Product Behavior

Ideally, the Datto RMM agent should internally differentiate between **benign service transitions** and **true service failures**, eliminating the need for external remediation logic.

## Ignore Expected Power-State Transitions

Service state changes during the following conditions should not be interpreted as failures:

- System shutdown
- Sleep / hibernate
- Resume from sleep
- Fast startup transitions

## Perform Internal Self-Recovery

If the agent service stops unexpectedly, the agent should:

1. Attempt automatic service restart
2. Validate internal agent health
3. Reconnect to the RMM platform
4. Report recovery status

Only when these steps fail should external remediation be considered.

## Provide Accurate Failure Signals

Failure events intended to trigger remediation should represent **true agent failures**, such as:

- Service crash
- Service startup failure
- Agent corruption
- Dependency failure

These signals should be distinguishable from routine operating system lifecycle events.

---

# Reproduction Scenario

The issue can be reproduced using normal Windows lifecycle events.

## Scenario 1 — System Shutdown

1. Device runs normally with **CagService Running**
2. User initiates Windows shutdown
3. Windows logs an event similar to:

```
Event ID: 7031
Provider: Service Control Manager

The CagService service terminated unexpectedly.
```

4. Device powers down normally
5. Device boots again
6. CagService starts successfully

Despite the service running normally, the failure event remains in the log.

---

## Scenario 2 — Sleep / Hibernate

1. Device enters sleep
2. Windows suspends services
3. Event log records CagService stop/failure
4. Device resumes
5. CagService resumes normally

Again, the failure event remains even though the service recovered automatically.

---

## False Remediation Flow

```
Shutdown Event Logged
        ↓
Device Restarts
        ↓
CagService Already Running
        ↓
Remediation Script Detects Event
        ↓
Agent Reinstall Triggered
```

---

# Architecture Overview

```
Device
   ↓
Universal Fix Script
   ↓
Decision Logic
   ↓
Restart Service OR Reinstall Agent
   ↓
Optional Lambda Logging
   ↓
AWS S3 Storage
   ↓
Operational Analysis
```

---

# Script Behavior

The remediation script performs the following workflow:

1. Waits **5 minutes** for system stabilization
2. Checks **CagService** status
3. If service is **NOT running**, attempts service restart
4. If restart fails, checks Windows Event Logs
5. Full remediation occurs only when:

```
CagService NOT Running
AND
Failure Event Present
```

If the service is already running, the script **exits without remediation**, even if failure events exist.

When remediation occurs:

- Agent directory is backed up
- Agent installer is downloaded using **siteUID**
- Agent reinstall is executed
- Service status is verified

---

# Datto RMM Component Variables (env:)

Use Datto RMM component custom variables to override behavior without editing the script.

| Name | Type | Default Value | Description |
|------|------|---------------|-------------|
| `LAMBDA_URL` | String | `""` | Optional Lambda URL for centralized log upload. If empty, logs stay local. |
| `DATTO_PLATFORM` | Selection | `vidal` | Datto platform shard used for agent download URL construction. |
| `EVENT_LOOKBACK_HOURS` | String | `24` | Hours to search System log for qualifying `CagService` failures. Valid range: `1-168`. |
| `STABILIZATION_SECONDS` | String | `300` | Delay before initial service check after script start. |
| `START_TIMEOUT_SECONDS` | String | `90` | Time to wait for `CagService` to reach `Running` after start attempt. |
| `POST_REMEDIATE_WAIT_SECONDS` | String | `60` | Time to wait after reinstall before final service validation. |
| `LOG_ROOT` | String | `C:\ProgramData\Datto_RMM_Logs` | Local directory used for script logs. |
| `UPLOAD_ON_NO_ACTION` | Boolean {TRUE/FALSE} | `FALSE` | If `TRUE`, uploads log output even when no restart/remediation action occurred. |
| `REMEDIATE_ENABLED` | Boolean {TRUE/FALSE} | `TRUE` | If `FALSE`, full reinstall remediation is disabled (detection/logging still run). |
| `TLS12_ENFORCE` | Boolean {TRUE/FALSE} | `TRUE` | If `TRUE`, enforces TLS 1.2 for web requests. |
| `STARTUP_GRACE_MINUTES` | String | `10` | Skips full remediation during early post-boot window to reduce startup transient false positives. |

---

# Logging

Logs are written locally to:

```
C:\ProgramData\Datto_RMM_Logs\
```

Log format:

```
<Domain_or_Tenant>_<DeviceName>_<Timestamp>.log
```

Example:

```
CONTOSO-PC01_20260305_101455.log
```

Logs include:

- Service status checks
- Event log evidence
- Remediation decisions
- Installer results
- Final service status

---

# Optional Centralized Logging (AWS)

If a **LambdaUrl** is configured, logs can be uploaded to AWS.

S3 folder structure:

```
ServiceRestarts/<siteUID>/<device>/
Remediations/<siteUID>/<device>/
NoAction/<siteUID>/<device>/
```

Uploads occur when action occurs, and optionally when no action occurs if enabled.

| Action | S3 Location |
|------|------|
| Service restart resolved issue | ServiceRestarts |
| Full remediation executed | Remediations |
| No action required + UPLOAD_ON_NO_ACTION=TRUE | NoAction |

---

# Deployment Options

## Group Policy (Recommended)

Deploy via **Scheduled Task GPO**

Runs as:

```
NT AUTHORITY\SYSTEM
```

Triggers:

- System startup
- Daily scheduled task (optional)

---

## Microsoft Intune

Deploy using:

```
Devices → Scripts → Platform Scripts
```

Recommended for:

- Azure AD joined devices
- Non-domain laptops

---

## Datto RMM Component

The script can also be executed as a **Datto RMM component** for:

- manual remediation
- controlled deployments
- troubleshooting

---

# Repository Structure

```
datto-rmm-remediation
│
├── Datto_RMM_Universal_Fix.ps1
└── README.md
```

---

# Version History

## v2.2.0 — Safety and Component Controls

Changes:

- Added preflight-first remediation sequence (validate `siteUID` and download installer before mutation)
- Added Datto RMM `env:` variable overrides for component-driven behavior
- Added optional startup grace window to reduce startup transient remediations
- Tightened failure-event correlation to explicit `CagService` evidence
- Added optional no-action log upload mode and remediation kill switch
- Improved tenant parsing and execution-context guardrails

Purpose:

Improve endpoint safety, reduce false positives, and support operator-controlled behavior in Datto RMM components.

---

## v2.1.0 — Remediation Logic Correction

Changes:

- Implemented **AND-gated remediation logic**
- Prevented unnecessary agent reinstalls
- Added failure event timestamp logging
- Improved restart validation
- Improved S3 log categorization

Purpose:

Prevent remediation from triggering due to benign power-state events.

---

## v2.0.9 — Initial Universal Script

Initial release including:

- Service monitoring
- Restart logic
- Agent reinstall capability
- AWS logging integration

---

# Disclaimer

This script is provided to maintain Datto RMM agent stability in environments experiencing service state inconsistencies.

It is **not an official Datto/Kaseya product component** and should be tested prior to large-scale deployment.

---

# Author

Jonathan Myers
CTMS IT

# Code Reviewed

Alex Sierputowski
CTMS IT
