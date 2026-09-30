Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvironmentValue {
    param([Parameter(Mandatory=$true)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    }
    return $value
}

function Get-ConsoleTimestamp { return '[{0:yyyy-MM-dd HH:mm:ss zzz}]' -f (Get-Date) }

function Remove-ThinkingTrace {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return ($Text -replace '(?s)<think>.*?</think>', '').Trim()
}

function Save-SessionCheckpoint {
    param([string]$LastPrompt, [string]$LastResponse, [string]$Status = 'Active')
    $checkpoint = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        CommitHash = (git rev-parse HEAD 2>$null)
        Branch = (git branch --show-current 2>$null)
        LastPrompt = $LastPrompt
        LastResponse = $LastResponse
        Status = $Status
    }
    $checkpoint | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot '.nim_session_state.json') -Encoding UTF8
}

function Get-RemoteBranches {
    $branches = @()
    foreach ($line in @(git ls-remote --heads origin 2>$null)) {
        if ($line -match 'refs/heads/(.+)$') { $branches += $Matches[1].Trim() }
    }
    return $branches
}

function Select-GitHubBranch {
    $branches = @(Get-RemoteBranches)
    if ($branches.Count -eq 0) { Write-Host 'No remote branches found or remote unreachable.' -ForegroundColor Red; return }
    for ($i = 0; $i -lt $branches.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $branches[$i]) -ForegroundColor Cyan }
    $choice = Read-Host 'Select branch number (or Enter to cancel)'
    if ($choice -notmatch '^\d+$') { return }
    $index = [int]$choice - 1
    if ($index -lt 0 -or $index -ge $branches.Count) { return }
    $selected = $branches[$index]
    if (git status --porcelain 2>$null) {
        $stashTag = 'auto-stash-pre-branch-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        git stash push --include-untracked -m $stashTag | Out-Null
    }
    git fetch origin $selected | Out-Null
    git checkout -B $selected ('origin/' + $selected) | Out-Null
    git reset --hard ('origin/' + $selected) | Out-Null
}

function Invoke-CollaborationRequest {
    param([Parameter(Mandatory=$true)][System.Collections.IEnumerable]$Messages)
    $baseUrl = Get-EnvironmentValue 'AI_COLLABORATION_BASE_URL'
    $bearer = Get-EnvironmentValue 'AI_COLLABORATION_BEARER_TOKEN'
    $logicalModel = Get-EnvironmentValue 'AI_COLLABORATION_MODEL'
    if ([string]::IsNullOrWhiteSpace($logicalModel)) { $logicalModel = 'nexus-coding' }

    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $headers = @{}
        if (-not [string]::IsNullOrWhiteSpace($bearer)) { $headers.Authorization = 'Bearer ' + $bearer }
        $body = @{ model = $logicalModel; messages = @($Messages); temperature = 0.2 } | ConvertTo-Json -Depth 12
        $response = Invoke-RestMethod -Method Post -Uri ($baseUrl.TrimEnd('/') + '/v1/chat/completions') -Headers $headers -ContentType 'application/json' -Body $body
        return [pscustomobject]@{ Text = (Remove-ThinkingTrace $response.choices[0].message.content); Route = ('AI Collaboration/' + $logicalModel); Verification = 'UNVERIFIED' }
    }

    $direct = Get-EnvironmentValue 'NIM_DIRECT_MODE'
    if ($direct -notmatch '^(1|true|yes)$') { throw 'AI_COLLABORATION_BASE_URL is not configured. Set it, or explicitly set NIM_DIRECT_MODE=true for direct NIM fallback.' }
    $apiKey = Get-EnvironmentValue 'NIM_API_KEY'
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = Get-EnvironmentValue 'NGC_API_KEY' }
    if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'NIM_DIRECT_MODE is enabled but no NIM_API_KEY/NGC_API_KEY is configured.' }
    $base = Get-EnvironmentValue 'NIM_BASE_URL'
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'https://integrate.api.nvidia.com/v1' }
    $model = Get-EnvironmentValue 'NIM_MODEL'
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'nvidia/nemotron-3.5-lightning-30b-a3b' }
    $headers = @{ Authorization = 'Bearer ' + $apiKey }
    $body = @{ model = $model; messages = @($Messages); max_tokens = 1200; temperature = 0.2 } | ConvertTo-Json -Depth 12
    $response = Invoke-RestMethod -Method Post -Uri ($base.TrimEnd('/') + '/chat/completions') -Headers $headers -ContentType 'application/json' -Body $body
    return [pscustomobject]@{ Text = (Remove-ThinkingTrace $response.choices[0].message.content); Route = ('Direct NIM/' + $model); Verification = 'UNVERIFIED' }
}

function Render-Banner {
    Clear-Host
    $branch = git branch --show-current 2>$null
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = '(detached)' }
    if (Get-EnvironmentValue 'AI_COLLABORATION_BASE_URL') { $route = 'AI Collaboration / nexus-coding' } else { $route = 'Direct NIM fallback (explicit opt-in required)' }
    Write-Host '===========================================================================' -ForegroundColor Green
    Write-Host '                     NVIDIA NIM AGENTIC GIT CONSOLE' -ForegroundColor Green
    Write-Host '===========================================================================' -ForegroundColor Green
    Write-Host ('Branch       : ' + $branch)
    Write-Host ('Route        : ' + $route)
    Write-Host 'Verification : AI output is UNVERIFIED until the repository Crucible gate passes.' -ForegroundColor Yellow
    Write-Host 'Commands     : :branch, :sync, clear, exit'
    Write-Host ''
}

$systemPrompt = 'You are the NVIDIA NIM prompt-based coding console inside the Nexus architecture. Return concise coding assistance and explicit execution evidence. Never claim a coding change is VERIFIED unless a Crucible verification result proves it. AI Collaboration consensus is advisory and never grants execution authorization.'
$messages = [System.Collections.Generic.List[object]]::new()
$messages.Add([ordered]@{ role = 'system'; content = $systemPrompt })
Render-Banner

while ($true) {
    $userInput = Read-Host 'You'
    if ([string]::IsNullOrWhiteSpace($userInput)) { continue }
    if ($userInput -in @('exit', ':q')) { break }
    if ($userInput -eq 'clear') { $messages.Clear(); $messages.Add([ordered]@{ role = 'system'; content = $systemPrompt }); Render-Banner; continue }
    if ($userInput -eq ':branch') { Select-GitHubBranch; Render-Banner; continue }
    if ($userInput -eq ':sync') {
        $current = git branch --show-current 2>$null
        if ([string]::IsNullOrWhiteSpace($current)) { Write-Host 'Cannot sync a detached HEAD.' -ForegroundColor Red; continue }
        if (git status --porcelain 2>$null) { Write-Host 'Refusing :sync while the working tree has uncommitted changes.' -ForegroundColor Red; continue }
        git fetch origin --prune | Out-Null
        git reset --hard ('origin/' + $current) | Out-Null
        Render-Banner
        continue
    }
    $messages.Add([ordered]@{ role = 'user'; content = $userInput })
    try {
        $result = Invoke-CollaborationRequest -Messages $messages
        Write-Host ((Get-ConsoleTimestamp) + ' AI [' + $result.Route + '] [' + $result.Verification + '] > ') -ForegroundColor Cyan -NoNewline
        Write-Host $result.Text
        $messages.Add([ordered]@{ role = 'assistant'; content = $result.Text })
        Save-SessionCheckpoint -LastPrompt $userInput -LastResponse $result.Text
    } catch {
        Write-Host ('[BLOCKED] ' + $_.Exception.Message) -ForegroundColor Red
        Save-SessionCheckpoint -LastPrompt $userInput -LastResponse $_.Exception.Message -Status 'Blocked'
    }
}
