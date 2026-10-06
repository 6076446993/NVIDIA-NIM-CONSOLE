Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:TEMP ('nim-efficiency-regression-' + [guid]::NewGuid().ToString('N'))
$env:NIM_EFFICIENCY_STATE_ROOT = $root
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'NIMEfficiency.ps1')

try {
    $fp1 = New-NimExecutionFingerprint -Project 'NIM' -OperationClass 'repository-preflight' -Objective ' Check  HEAD ' -Repository '6076446993/NVIDIA-NIM-CONSOLE' -Branch 'main' -Head 'abc'
    $fp2 = New-NimExecutionFingerprint -Project 'NIM' -OperationClass 'repository-preflight' -Objective 'check head' -Repository '6076446993/NVIDIA-NIM-CONSOLE' -Branch 'main' -Head 'abc'
    if ($fp1 -ne $fp2) { throw 'Equivalent objectives must produce identical fingerprints.' }

    $initial = Test-NimMeaningfulChange -Previous $null -Current @{ head='abc'; inputVersion='1'; triggerState='ok' }
    if (-not $initial.Changed) { throw 'Initial state must be treated as changed.' }

    Write-NimCheckpoint -Fingerprint $fp1 -State @{ state='VERIFIED'; head='abc'; inputVersion='1'; triggerState='ok' } | Out-Null
    $prior = Read-NimCheckpoint $fp1
    $same = Test-NimMeaningfulChange -Previous $prior -Current @{ head='abc'; inputVersion='1'; triggerState='ok' }
    if ($same.Changed) { throw 'Unchanged state must take the no-change path.' }
    $changed = Test-NimMeaningfulChange -Previous $prior -Current @{ head='def'; inputVersion='1'; triggerState='ok' }
    if (-not $changed.Changed -or $changed.ChangedKeys -notcontains 'head') { throw 'Changed HEAD must trigger full work.' }

    Write-NimCheckpoint -Fingerprint $fp2 -State @{ state='EXECUTING'; head='abc' } | Out-Null
    $duplicate = Test-NimDuplicateExecution -Fingerprint $fp2
    if (-not $duplicate.Duplicate) { throw 'Active identical fingerprint must be suppressed.' }

    $failure = New-NimExecutionFingerprint -Project 'NIM' -OperationClass 'ci-repair' -Objective 'same failure'
    $first = Get-NimRetryDecision -FailureFingerprint $failure
    if (-not $first.Allowed) { throw 'Initial retry must be allowed.' }
    $blocked = Get-NimRetryDecision -FailureFingerprint $failure
    if ($blocked.Allowed) { throw 'Unchanged repeated retry must be blocked.' }
    $withEvidence = Get-NimRetryDecision -FailureFingerprint $failure -NewEvidence $true
    if (-not $withEvidence.Allowed) { throw 'New evidence must permit another retry.' }

    $messages = @(
        [pscustomobject]@{role='system';content='system'}
    )
    for ($i=1; $i -le 40; $i++) {
        $messages += [pscustomobject]@{role='user';content=('m' + $i)}
    }
    $trimmed = @(Get-NimEfficientMessages -Messages $messages -MaxConversationMessages 10)
    if ($trimmed.Count -ne 11) { throw 'Context limiter must preserve one system message plus requested tail.' }
    if ($trimmed[0].role -ne 'system' -or $trimmed[-1].content -ne 'm40') { throw 'Context limiter lost required boundary messages.' }

    $usage = Write-NimUsageRecord -Project 'NIM' -TaskId 'test' -OperationClass 'regression' -Outcome 'SUCCESS' -ChangedStateDetected $false -MessageCount 11 -ToolCallCount 0
    if ($usage.outcome -ne 'SUCCESS') { throw 'Usage record was not returned.' }
    $usagePath = Join-Path $root 'usage.jsonl'
    if (-not (Test-Path -LiteralPath $usagePath)) { throw 'Usage log was not persisted.' }
    $line = Get-Content -LiteralPath $usagePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($line.changedStateDetected -ne $false) { throw 'Usage attribution lost changed-state flag.' }

    Write-Host 'NIM efficiency regression passed.'
} finally {
    Remove-Item Env:NIM_EFFICIENCY_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
