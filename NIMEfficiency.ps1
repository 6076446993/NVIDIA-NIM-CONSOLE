Set-StrictMode -Version Latest

function Get-NimEfficiencyRoot {
    $override = [Environment]::GetEnvironmentVariable('NIM_EFFICIENCY_STATE_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($override)) {
        $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.nexus-nim'
        } else {
            $base = Join-Path $base 'NexusNim'
        }
        $override = Join-Path $base 'efficiency'
    }
    if (-not (Test-Path -LiteralPath $override)) {
        New-Item -ItemType Directory -Path $override -Force | Out-Null
    }
    return $override
}

function Get-NimSha256 {
    param([Parameter(Mandatory=$true)][string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-NimNormalizedTask {
    param([Parameter(Mandatory=$true)][string]$Task)
    return (($Task.Trim().ToLowerInvariant() -replace '\s+', ' ') -replace '[\r\n]+', ' ')
}

function New-NimExecutionFingerprint {
    param(
        [Parameter(Mandatory=$true)][string]$Project,
        [Parameter(Mandatory=$true)][string]$OperationClass,
        [Parameter(Mandatory=$true)][string]$Objective,
        [string]$Repository = '',
        [string]$Branch = '',
        [string]$Head = '',
        [string]$InputVersion = '',
        [string]$Trigger = ''
    )
    $payload = [ordered]@{
        project = $Project
        operationClass = $OperationClass
        objective = Get-NimNormalizedTask $Objective
        repository = $Repository
        branch = $Branch
        head = $Head
        inputVersion = $InputVersion
        trigger = $Trigger
    } | ConvertTo-Json -Compress
    return Get-NimSha256 $payload
}

function Get-NimCheckpointPath {
    param([Parameter(Mandatory=$true)][string]$Fingerprint)
    return Join-Path (Get-NimEfficiencyRoot) ('checkpoint-' + $Fingerprint + '.json')
}

function Read-NimCheckpoint {
    param([Parameter(Mandatory=$true)][string]$Fingerprint)
    $path = Get-NimCheckpointPath $Fingerprint
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-NimCheckpoint {
    param(
        [Parameter(Mandatory=$true)][string]$Fingerprint,
        [Parameter(Mandatory=$true)][hashtable]$State
    )
    $path = Get-NimCheckpointPath $Fingerprint
    $copy = [ordered]@{}
    foreach ($key in $State.Keys) { $copy[$key] = $State[$key] }
    $copy.fingerprint = $Fingerprint
    $copy.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $copy | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Test-NimMeaningfulChange {
    param(
        $Previous,
        [Parameter(Mandatory=$true)][hashtable]$Current,
        [string[]]$Keys = @('head','inputVersion','triggerState')
    )
    if (-not $Previous) {
        return [pscustomobject]@{ Changed = $true; ChangedKeys = @('initial') }
    }
    $changed = @()
    foreach ($key in $Keys) {
        $old = if ($Previous.PSObject.Properties.Name -contains $key) { [string]$Previous.$key } else { '' }
        $new = if ($Current.ContainsKey($key)) { [string]$Current[$key] } else { '' }
        if ($old -ne $new) { $changed += $key }
    }
    return [pscustomobject]@{ Changed = ($changed.Count -gt 0); ChangedKeys = @($changed) }
}

function Write-NimUsageRecord {
    param(
        [Parameter(Mandatory=$true)][string]$Project,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$OperationClass,
        [Parameter(Mandatory=$true)][string]$Outcome,
        [string]$ExecutionEnvironment = 'NVIDIA-NIM-CONSOLE',
        [string]$Trigger = 'interactive',
        [string]$StartingCheckpoint = '',
        [string]$EndingCheckpoint = '',
        [bool]$ChangedStateDetected = $true,
        [int]$HandoffCount = 0,
        [int]$RetryCount = 0,
        [int]$MessageCount = 0,
        [int]$ToolCallCount = 0,
        [int]$InputCharacters = 0,
        [int]$OutputCharacters = 0,
        [string]$ModelClass = '',
        [string]$VerificationLevel = 'UNVERIFIED'
    )
    $root = Get-NimEfficiencyRoot
    $log = Join-Path $root 'usage.jsonl'
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        project = $Project
        taskId = $TaskId
        executionEnvironment = $ExecutionEnvironment
        trigger = $Trigger
        operationClass = $OperationClass
        startingCheckpoint = $StartingCheckpoint
        endingCheckpoint = $EndingCheckpoint
        changedStateDetected = $ChangedStateDetected
        outcome = $Outcome
        handoffCount = $HandoffCount
        retryCount = $RetryCount
        messageCount = $MessageCount
        toolCallCount = $ToolCallCount
        inputCharacters = $InputCharacters
        outputCharacters = $OutputCharacters
        modelClass = $ModelClass
        verificationLevel = $VerificationLevel
    }
    Add-Content -LiteralPath $log -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
    return [pscustomobject]$record
}

function Get-NimEfficientMessages {
    param(
        [Parameter(Mandatory=$true)][System.Collections.IEnumerable]$Messages,
        [int]$MaxConversationMessages = 24
    )
    $all = @($Messages)
    if ($all.Count -le ($MaxConversationMessages + 1)) { return $all }

    $system = @($all | Where-Object { $_.role -eq 'system' } | Select-Object -First 1)
    $nonSystem = @($all | Where-Object { $_.role -ne 'system' })
    $tail = @($nonSystem | Select-Object -Last $MaxConversationMessages)
    return @($system + $tail)
}

function Get-NimRetryDecision {
    param(
        [Parameter(Mandatory=$true)][string]$FailureFingerprint,
        [bool]$MaterialChange = $false,
        [bool]$NewEvidence = $false
    )
    $root = Get-NimEfficiencyRoot
    $path = Join-Path $root ('retry-' + $FailureFingerprint + '.json')
    $attempts = 0
    if (Test-Path -LiteralPath $path) {
        try { $attempts = [int](Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).attempts } catch { $attempts = 0 }
    }
    if ($attempts -ge 1 -and -not ($MaterialChange -or $NewEvidence)) {
        return [pscustomobject]@{ Allowed = $false; Attempts = $attempts; Reason = 'UNCHANGED_FAILURE_REQUIRES_NEW_EVIDENCE_OR_MATERIAL_CHANGE' }
    }
    $next = $attempts + 1
    [ordered]@{ attempts = $next; updatedAt = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    return [pscustomobject]@{ Allowed = $true; Attempts = $next; Reason = 'ALLOWED' }
}

function Reset-NimRetryState {
    param([Parameter(Mandatory=$true)][string]$FailureFingerprint)
    $path = Join-Path (Get-NimEfficiencyRoot) ('retry-' + $FailureFingerprint + '.json')
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Test-NimDuplicateExecution {
    param(
        [Parameter(Mandatory=$true)][string]$Fingerprint,
        [string[]]$BlockingStates = @('REQUESTED','EXECUTING','EXECUTED')
    )
    $checkpoint = Read-NimCheckpoint $Fingerprint
    if (-not $checkpoint) { return [pscustomobject]@{ Duplicate = $false; State = $null } }
    $state = if ($checkpoint.PSObject.Properties.Name -contains 'state') { [string]$checkpoint.state } else { '' }
    return [pscustomobject]@{
        Duplicate = ($BlockingStates -contains $state)
        State = $state
        Checkpoint = $checkpoint
    }
}
