Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-EnvironmentValue {
    param([string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, 'Process')
}

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'NexusCodingWorkflow.ps1')

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('nim-workflow-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Push-Location $fixture
try {
    git init -q
    git config user.email 'nexus-test@example.invalid'
    git config user.name 'Nexus Test'
    git remote add origin 'https://github.com/6076446993/example.git'
    Set-Content -LiteralPath 'a.txt' -Value 'old'
    Set-Content -LiteralPath '.env' -Value 'SHOULD_NOT_LEAVE_CONTEXT' -NoNewline
    git add a.txt .env
    git commit -qm 'fixture'
    $base = (git rev-parse HEAD).Trim()

    $context = @(Get-NexusSafeContext -TaskDescription 'change a.txt')
    Assert-True ($context.path -contains 'a.txt') 'Safe context should include the task-relevant tracked file.'
    Assert-True (-not ($context.path -contains '.env')) 'Safe context must exclude tracked environment files.'

    function Invoke-NexusCodingProposal {
        param([string]$TaskDescription,[string]$TaskReference,[string]$LineageReference,[string]$RepositoryReference,[string]$TargetVersion)
        Set-Content -LiteralPath 'a.txt' -Value 'new'
        try {
            $diff = ((& git diff --binary -- a.txt) -join [Environment]::NewLine) + [Environment]::NewLine
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($diff)) { throw 'Fixture failed to generate a Git-applicable proposal diff.' }
        } finally {
            & git checkout -- a.txt
            if ($LASTEXITCODE -ne 0) { throw 'Fixture failed to restore a.txt after generating the proposal diff.' }
        }
        return [pscustomobject]@{
            codingProposal = [pscustomobject]@{
                schemaVersion = 1
                proposalId = 'proposal-test'
                taskReference = $TaskReference
                repositoryReference = $RepositoryReference
                targetVersion = $TargetVersion
                proposedChanges = [pscustomobject]@{ format = 'unified-diff'; content = $diff }
                reasoningReference = ('a' * 64)
                timestamp = '2026-09-30T02:00:00.000Z'
                lineageReference = $LineageReference
                collaborationArtifactSha256 = ('b' * 64)
                authorizationGranted = $false
            }
        }
    }

    $execution = Invoke-NexusCodingTask -TaskDescription 'change a.txt from old to new'
    Assert-True (@(Get-Content -LiteralPath a.txt).Count -eq 1 -and (Get-Content -LiteralPath a.txt) -eq 'new') 'CodingProposal must be applied to the working tree.'
    Assert-True ($execution.record.workflowState -eq 'EXECUTED') 'Applied proposal must enter EXECUTED.'
    Assert-True ($execution.record.completionStatus -eq 'UNVERIFIED') 'Applied proposal must remain UNVERIFIED.'
    Assert-True ($execution.record.targetVersion -eq $base) 'Workflow must retain the exact proposal target version.'
    Assert-True ($execution.record.executedPaths.Count -eq 1 -and $execution.record.executedPaths[0] -eq 'a.txt') 'Executed path lineage must match the applied diff.'
    Assert-True ([string]$execution.record.executedDiffSha256 -match '^[a-f0-9]{64}$') 'Executed diff must carry a SHA-256 lineage commitment.'

    git add a.txt
    git commit -qm 'apply proposal'
    $head = (git rev-parse HEAD).Trim()
    git merge-base --is-ancestor $base $head
    Assert-True ($LASTEXITCODE -eq 0) 'Committed execution must descend from the exact proposal target.'
    $committed = (& git diff --binary $base $head)
    $committedHash = Get-NexusStringSha256 (($committed -join [Environment]::NewLine) + [Environment]::NewLine)
    Assert-True ($committedHash -eq $execution.record.executedDiffSha256) 'Committed diff must match the executed proposal commitment.'

    Add-Content -LiteralPath a.txt -Value 'tamper'
    git add a.txt
    git commit -qm 'unrelated mutation'
    $tampered = (& git diff --binary $base HEAD)
    $tamperedHash = Get-NexusStringSha256 (($tampered -join [Environment]::NewLine) + [Environment]::NewLine)
    Assert-True ($tamperedHash -ne $execution.record.executedDiffSha256) 'Additional committed mutations must break exact-diff lineage.'

    Write-Host 'Nexus coding workflow regression passed.'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
