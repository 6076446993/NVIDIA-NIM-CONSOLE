Set-StrictMode -Version Latest

function Get-NexusStringSha256 {
    param([Parameter(Mandatory=$true)][string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-NexusRepositoryReference {
    $remote = (git config --get remote.origin.url 2>$null)
    if ([string]::IsNullOrWhiteSpace($remote)) { throw 'Git remote origin is required.' }
    $value = $remote.Trim()
    if ($value -match '^git@github\.com:(?<repo>[^/]+/[^/]+?)(?:\.git)?$') { return $Matches.repo }
    if ($value -match '^https://github\.com/(?<repo>[^/]+/[^/]+?)(?:\.git)?/?$') { return $Matches.repo }
    throw 'Only GitHub origin URLs are supported by the governed Nexus coding workflow.'
}

function Get-NexusWorkflowRoot {
    $override = [Environment]::GetEnvironmentVariable('NEXUS_WORKFLOW_STATE_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($override)) {
        $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) '.nexus-nim'
        } else {
            $base = Join-Path $base 'NexusNim'
        }
    } else {
        $base = $override
    }
    $repository = try { Get-NexusRepositoryReference } catch { 'unbound-repository' }
    $safeRepository = $repository -replace '[^A-Za-z0-9_.-]', '_'
    $root = Join-Path (Join-Path $base 'workflows') $safeRepository
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Write-NexusWorkflowRecord {
    param([Parameter(Mandatory=$true)]$Record)
    $root = Get-NexusWorkflowRoot
    $file = Join-Path $root ($Record.workflowId + '.json')
    $Record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Get-NexusSafeContext {
    param(
        [Parameter(Mandatory=$true)][string]$TaskDescription,
        [int]$MaxFiles = 20,
        [int]$MaxBytes = 96000
    )

    $sensitive = '(?i)(^|/)(\.env(?:\.|$)|.*secret.*|.*credential.*|.*private[-_.]?key.*|id_rsa|id_ed25519|\.nim_session_state\.json|\.nexus-nim/)'
    $allowed = '(?i)\.(ps1|py|js|cjs|mjs|ts|tsx|jsx|json|md|yml|yaml|txt|html|css|scss|xml|toml|ini|cfg)$'
    $terms = @($TaskDescription.ToLowerInvariant() -split '[^a-z0-9_.-]+' | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    $candidates = @()

    foreach ($path in @(git ls-files)) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path -match $sensitive -or $path -notmatch $allowed) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $info = Get-Item -LiteralPath $path
        if ($info.Length -gt 32768) { continue }
        $lower = $path.ToLowerInvariant()
        $score = 0
        foreach ($term in $terms) {
            if ($lower.Contains($term)) { $score += 10 }
        }
        if ($lower -match '(^|/)(readme|package\.json|\.thecrucible\.json)$') { $score += 2 }
        $candidates += [pscustomobject]@{ Path = $path; Score = $score; Bytes = [int]$info.Length }
    }

    $selected = @()
    $used = 0
    foreach ($item in @($candidates | Sort-Object @{Expression='Score';Descending=$true}, @{Expression='Bytes';Descending=$false}, Path)) {
        if ($selected.Count -ge $MaxFiles) { break }
        if (($used + $item.Bytes) -gt $MaxBytes) { continue }
        $content = Get-Content -LiteralPath $item.Path -Raw -Encoding UTF8
        $selected += [ordered]@{ path = $item.Path.Replace('\\','/'); content = $content }
        $used += $item.Bytes
    }
    return @($selected)
}

function Invoke-NexusCodingProposal {
    param(
        [Parameter(Mandatory=$true)][string]$TaskDescription,
        [Parameter(Mandatory=$true)][string]$TaskReference,
        [Parameter(Mandatory=$true)][string]$LineageReference,
        [Parameter(Mandatory=$true)][string]$RepositoryReference,
        [Parameter(Mandatory=$true)][string]$TargetVersion
    )

    $baseUrl = Get-EnvironmentValue 'AI_COLLABORATION_BASE_URL'
    $token = Get-EnvironmentValue 'AI_COLLABORATION_BEARER_TOKEN'
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw 'AI_COLLABORATION_BASE_URL is required for governed coding proposals.' }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'AI_COLLABORATION_BEARER_TOKEN is required for governed coding proposals.' }

    $body = [ordered]@{
        taskReference = $TaskReference
        repositoryReference = $RepositoryReference
        targetVersion = $TargetVersion
        taskDescription = $TaskDescription
        lineageReference = $LineageReference
        relevantFiles = @(Get-NexusSafeContext -TaskDescription $TaskDescription)
    } | ConvertTo-Json -Depth 20

    $response = Invoke-RestMethod -Method Post -Uri ($baseUrl.TrimEnd('/') + '/v1/coding/proposals') -Headers @{ Authorization = 'Bearer ' + $token } -ContentType 'application/json' -Body $body
    if (-not $response.codingProposal) { throw 'AI Collaboration returned no CodingProposal.' }
    if ($response.codingProposal.authorizationGranted -ne $false) { throw 'AI Collaboration violated the authority boundary by granting authorization.' }
    if ($response.codingProposal.repositoryReference -ne $RepositoryReference) { throw 'CodingProposal repository reference does not match the current repository.' }
    if ($response.codingProposal.targetVersion -ne $TargetVersion) { throw 'CodingProposal target version does not match the current HEAD.' }
    if ($response.codingProposal.proposedChanges.format -ne 'unified-diff') { throw 'CodingProposal is not a unified Git diff.' }
    if ([string]::IsNullOrWhiteSpace([string]$response.codingProposal.proposedChanges.content)) { throw 'CodingProposal contains no proposed changes.' }
    return $response
}

function Invoke-NexusCodingTask {
    param([Parameter(Mandatory=$true)][string]$TaskDescription)

    $dirty = @(git status --porcelain)
    if ($dirty.Count -gt 0) { throw 'Coding workflow requires a clean working tree so proposal lineage cannot be mixed with pre-existing changes.' }

    $repository = Get-NexusRepositoryReference
    $targetVersion = (git rev-parse HEAD).Trim()
    $workflowId = 'workflow-' + [guid]::NewGuid().ToString('N')
    $requestId = 'request-' + [guid]::NewGuid().ToString('N')
    $taskId = 'task-' + [guid]::NewGuid().ToString('N')
    $lineageId = 'lineage-' + [guid]::NewGuid().ToString('N')
    $now = (Get-Date).ToUniversalTime().ToString('o')

    $record = [ordered]@{
        schemaVersion = 1
        workflowId = $workflowId
        promptRequest = [ordered]@{
            requestIdentifier = $requestId
            promptContent = $TaskDescription
            timestamp = $now
            sessionReference = $workflowId
            lineageReference = $lineageId
        }
        taskRequest = [ordered]@{
            taskIdentifier = $taskId
            taskDescription = $TaskDescription
            taskType = 'coding'
            timestamp = $now
            lineageReference = $lineageId
        }
        repositoryReference = $repository
        targetVersion = $targetVersion
        workflowState = 'REQUESTED'
        completionStatus = 'UNVERIFIED'
        codingProposal = $null
        verificationReceipt = $null
        updatedAt = $now
    }
    $recordFile = Write-NexusWorkflowRecord -Record $record

    try {
        $response = Invoke-NexusCodingProposal -TaskDescription $TaskDescription -TaskReference $taskId -LineageReference $lineageId -RepositoryReference $repository -TargetVersion $targetVersion
        $proposal = $response.codingProposal
        $record.codingProposal = $proposal

        if ((git rev-parse HEAD).Trim() -ne $targetVersion) { throw 'Repository HEAD changed after the CodingProposal was generated.' }
        if (@(git status --porcelain).Count -gt 0) { throw 'Working tree changed after the CodingProposal was generated.' }

        $patch = Join-Path ([System.IO.Path]::GetTempPath()) ($workflowId + '.diff')
        try {
            [System.IO.File]::WriteAllText($patch, [string]$proposal.proposedChanges.content, [System.Text.UTF8Encoding]::new($false))
            & git apply --check --whitespace=error-all -- $patch
            if ($LASTEXITCODE -ne 0) { throw 'CodingProposal failed git apply --check.' }
            & git apply --whitespace=error-all -- $patch
            if ($LASTEXITCODE -ne 0) { throw 'CodingProposal could not be applied.' }
            & git diff --check
            if ($LASTEXITCODE -ne 0) {
                & git reset --hard $targetVersion | Out-Null
                throw 'Applied CodingProposal failed git diff --check and was rolled back.'
            }
        } finally {
            Remove-Item -LiteralPath $patch -Force -ErrorAction SilentlyContinue
        }

        $executionDiff = (& git diff --binary $targetVersion)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($executionDiff -join [Environment]::NewLine))) {
            throw 'CodingProposal produced no auditable working-tree diff.'
        }
        $record.executedPaths = @(& git diff --name-only $targetVersion)
        $record.executedDiffSha256 = Get-NexusStringSha256 (($executionDiff -join [Environment]::NewLine) + [Environment]::NewLine)
        $record.workflowState = 'EXECUTED'
        $record.completionStatus = 'UNVERIFIED'
        $record.executedAt = (Get-Date).ToUniversalTime().ToString('o')
        $record.updatedAt = $record.executedAt
        $recordFile = Write-NexusWorkflowRecord -Record $record
        return [pscustomobject]@{ record = $record; recordFile = $recordFile }
    } catch {
        $record.workflowState = 'BLOCKED'
        $record.completionStatus = 'UNVERIFIED'
        $record.blockedReason = $_.Exception.Message
        $record.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-NexusWorkflowRecord -Record $record | Out-Null
        throw
    }
}

function Get-CrucibleVerificationReceipt {
    param(
        [string]$WorkflowId,
        [Parameter(Mandatory=$true)][string]$RecordTargetVersion,
        [Parameter(Mandatory=$true)][string]$ExpectedDiffSha256
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required to consume hosted Crucible evidence.' }
    if (@(git status --porcelain).Count -gt 0) { throw 'Verification requires a clean committed working tree. Commit the executed change before requesting hosted verification evidence.' }

    $repository = Get-NexusRepositoryReference
    $head = (git rev-parse HEAD).Trim()
    & git merge-base --is-ancestor $recordTargetVersion $head 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Current HEAD does not descend from the CodingProposal target version.' }
    $committedDiff = (& git diff --binary $recordTargetVersion $head)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to reconstruct the committed coding diff for verification.' }
    $committedDiffSha256 = Get-NexusStringSha256 (($committedDiff -join [Environment]::NewLine) + [Environment]::NewLine)
    if ($committedDiffSha256 -ne $expectedDiffSha256) { throw 'Current committed diff does not match the executed CodingProposal lineage.' }
    $runs = (gh api ('repos/' + $repository + '/actions/runs?head_sha=' + $head + '&per_page=50') | ConvertFrom-Json).workflow_runs
    $successful = @($runs | Where-Object { $_.conclusion -eq 'success' } | Sort-Object {[datetime]$_.updated_at} -Descending)
    if ($successful.Count -eq 0) { throw 'No successful GitHub Actions run exists for the current HEAD.' }

    $selected = $null
    $artifact = $null
    foreach ($run in $successful) {
        $artifacts = (gh api ('repos/' + $repository + '/actions/runs/' + $run.id + '/artifacts') | ConvertFrom-Json).artifacts
        $candidate = @($artifacts | Where-Object { $_.name -like 'the-crucible-report-*' } | Select-Object -First 1)
        if ($candidate.Count -gt 0) {
            $selected = $run
            $artifact = $candidate[0]
            break
        }
    }
    if (-not $selected -or -not $artifact) { throw 'No successful run for the current HEAD contains a Crucible report artifact.' }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('nim-crucible-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        & gh run download ([string]$selected.id) --repo $repository --name ([string]$artifact.name) --dir $temp
        if ($LASTEXITCODE -ne 0) { throw 'Unable to download the Crucible report artifact.' }
        $reportFile = Get-ChildItem -LiteralPath $temp -Recurse -File | Where-Object { $_.Name -eq '.the-crucible-report.json' } | Select-Object -First 1
        if (-not $reportFile) { throw 'Downloaded Crucible artifact does not contain .the-crucible-report.json.' }
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($report.commit -ne $head) { throw 'Crucible report commit does not match the current HEAD.' }
        $failed = @($report.results | Where-Object { $_.status -ne 'passed' })
        if ($failed.Count -gt 0) { throw 'Crucible report contains one or more non-passing checks.' }

        return [ordered]@{
            sourceAuthority = 'The-Crucible'
            repositoryReference = $repository
            targetVersion = $head
            workflowRunId = [string]$selected.id
            workflowName = [string]$selected.name
            artifactId = [string]$artifact.id
            artifactName = [string]$artifact.name
            reportCommit = [string]$report.commit
            checkReferences = @($report.results | ForEach-Object { [ordered]@{ action = $_.action; status = $_.status; timestamp = $_.timestamp } })
            receivedAt = (Get-Date).ToUniversalTime().ToString('o')
            lineageReference = $WorkflowId
            verificationOutcome = 'VERIFIED'
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-NexusWorkflowVerification {
    param([string]$WorkflowId)

    $root = Get-NexusWorkflowRoot
    $file = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkflowId)) {
        $candidate = Join-Path $root ($WorkflowId + '.json')
        if (Test-Path -LiteralPath $candidate) { $file = Get-Item -LiteralPath $candidate }
    } else {
        $file = Get-ChildItem -LiteralPath $root -Filter 'workflow-*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    }
    if (-not $file) { throw 'No Nexus NIM workflow record is available to verify.' }

    $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$record.executedDiffSha256)) { throw 'Workflow record predates executable diff lineage and cannot be promoted to VERIFIED.' }
    $receipt = Get-CrucibleVerificationReceipt -WorkflowId $record.workflowId -RecordTargetVersion $record.targetVersion -ExpectedDiffSha256 $record.executedDiffSha256
    if ($receipt.repositoryReference -ne $record.repositoryReference) { throw 'Crucible receipt repository does not match the workflow repository.' }

    $record.verificationReceipt = $receipt
    $record.workflowState = 'VERIFIED'
    $record.completionStatus = 'VERIFIED'
    $record.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file.FullName -Encoding UTF8
    return $record
}
