Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ConfiguredEnvironmentValue {
    param([Parameter(Mandatory=$true)][string[]]$Names)
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, "User")
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

function Remove-ThinkingTrace {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $clean = $Text -replace "(?s)<think>.*?</think>", ""
    return $clean.Trim()
}

function Get-ConsoleTimestamp {
    return "[{0:yyyy-MM-dd hh:mm tt}]" -f (Get-Date)
}

function Save-SessionCheckpoint {
    param(
        [string]$LastPrompt,
        [string]$LastResponse,
        [ValidateSet("Active","Interrupted","Complete")][string]$Status = "Active"
    )
    $checkpoint = [ordered]@{
        Timestamp    = (Get-Date).ToString("o")
        CommitHash   = (git rev-parse HEAD 2>$null)
        Branch       = (git branch --show-current 2>$null)
        LastPrompt   = $LastPrompt
        LastResponse = $LastResponse
        Status       = $Status
    }
    $checkpoint | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $PSScriptRoot ".nim_session_state.json") -Encoding UTF8
}

function Get-RemoteBranches {
    $raw = git ls-remote --heads origin 2>$null
    @($raw | ForEach-Object {
        if ($_ -match 'refs/heads/(.+)$') { $Matches[1].Trim() }
    })
}

function Select-GitHubBranch {
    $branches = @(Get-RemoteBranches)
    if ($branches.Count -eq 0) {
        Write-Host "No remote branches found or remote unreachable." -ForegroundColor Red
        return
    }
    for ($i = 0; $i -lt $branches.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $branches[$i]) -ForegroundColor Cyan
    }
    $choice = Read-Host "Select branch number (Enter to cancel)"
    if ($choice -notmatch '^\d+$') { return }
    $index = [int]$choice - 1
    if ($index -lt 0 -or $index -ge $branches.Count) { return }

    $status = git status --porcelain 2>$null
    if ($status) {
        $stashTag = "nim-console-auto-stash-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
        git stash push --include-untracked -m $stashTag | Out-Null
        Write-Host "Working tree stashed as $stashTag." -ForegroundColor Yellow
    }

    $selected = $branches[$index]
    git fetch origin $selected | Out-Null
    git checkout -B $selected "origin/$selected" --force | Out-Null
    git reset --hard "origin/$selected" | Out-Null
    Write-Host "Now on $selected." -ForegroundColor Green
}

function Invoke-AiCollaboration {
    param([Parameter(Mandatory=$true)][object[]]$Messages)

    $baseUrl = Get-ConfiguredEnvironmentValue -Names @("AI_COLLABORATION_URL","AI_COLLABORATION_BASE_URL")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { return $null }

    $token = Get-ConfiguredEnvironmentValue -Names @("AI_COLLABORATION_BEARER_TOKEN")
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "AI Collaboration is configured but AI_COLLABORATION_BEARER_TOKEN is missing."
    }

    $uri = "$($baseUrl.TrimEnd('/'))/v1/chat/completions"
    $body = @{
        model = "nexus-coding"
        messages = $Messages
        temperature = 0.2
        max_tokens = 800
    } | ConvertTo-Json -Depth 10

    $headers = @{ Authorization = "Bearer $token" }
    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json" -Body $body
    $content = $response.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw "AI Collaboration returned no assistant content." }
    return [pscustomobject]@{ Content = $content; Route = "AI Collaboration / nexus-coding" }
}

function Invoke-DirectNim {
    param([Parameter(Mandatory=$true)][object[]]$Messages)

    $apiKey = Get-ConfiguredEnvironmentValue -Names @("NIM_API_KEY","NGC_API_KEY")
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Neither AI Collaboration nor a direct NVIDIA NIM API key is configured."
    }

    $baseUrl = Get-ConfiguredEnvironmentValue -Names @("NIM_BASE_URL")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = "https://integrate.api.nvidia.com/v1" }
    $model = Get-ConfiguredEnvironmentValue -Names @("NVIDIA_NIM_MODEL","CHARGPT_MODEL")
    if ([string]::IsNullOrWhiteSpace($model)) { $model = "nvidia/nemotron-3.5-lightning-30b-a3b" }

    $body = @{
        model = $model
        messages = $Messages
        temperature = 0.2
        max_tokens = 800
    } | ConvertTo-Json -Depth 10

    $headers = @{ Authorization = "Bearer $apiKey" }
    $response = Invoke-RestMethod -Method Post -Uri "$($baseUrl.TrimEnd('/'))/chat/completions" -Headers $headers -ContentType "application/json" -Body $body
    $content = $response.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw "NVIDIA NIM returned no assistant content." }
    return [pscustomobject]@{ Content = $content; Route = "Direct NVIDIA NIM" }
}

function Invoke-CodingAssistant {
    param([Parameter(Mandatory=$true)][object[]]$Messages)
    $collaboration = Invoke-AiCollaboration -Messages $Messages
    if ($null -ne $collaboration) { return $collaboration }
    return Invoke-DirectNim -Messages $Messages
}

function Render-Banner {
    Clear-Host
    $branch = git branch --show-current 2>$null
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "(detached)" }
    $collabUrl = Get-ConfiguredEnvironmentValue -Names @("AI_COLLABORATION_URL","AI_COLLABORATION_BASE_URL")
    $route = if ($collabUrl) { "AI Collaboration / nexus-coding" } else { "Direct NVIDIA NIM fallback" }
    Write-Host "==========================================================================" -ForegroundColor Green
    Write-Host "                    NVIDIA NIM AGENTIC GIT CONSOLE" -ForegroundColor Green
    Write-Host "==========================================================================" -ForegroundColor Green
    Write-Host "Branch : $branch" -ForegroundColor Yellow
    Write-Host "Route  : $route" -ForegroundColor Cyan
    Write-Host "Commands: :branch, :sync, clear, exit" -ForegroundColor DarkCyan
    Write-Host ""
}

$systemPrompt = @"
You are the NVIDIA NIM prompt-based coding console inside the Nexus architecture.
Return concise, actionable coding assistance.
Do not claim that code was executed, committed, tested, or verified unless the supplied context proves it.
Council agreement is advisory; Crucible verification remains the verification authority.
"@

$messages = [System.Collections.Generic.List[object]]::new()
$messages.Add([ordered]@{ role = "system"; content = $systemPrompt })
Render-Banner

while ($true) {
    $userInput = Read-Host "You"
    if ([string]::IsNullOrWhiteSpace($userInput)) { continue }

    switch ($userInput) {
        "exit" { break }
        ":q" { break }
        "clear" {
            $messages.Clear()
            $messages.Add([ordered]@{ role = "system"; content = $systemPrompt })
            Render-Banner
            continue
        }
        ":branch" {
            Select-GitHubBranch
            Render-Banner
            continue
        }
        ":sync" {
            $current = git branch --show-current 2>$null
            if ([string]::IsNullOrWhiteSpace($current)) { throw "Cannot sync a detached HEAD." }
            git fetch origin --prune | Out-Null
            git reset --hard "origin/$current" | Out-Null
            Render-Banner
            continue
        }
    }

    $messages.Add([ordered]@{ role = "user"; content = $userInput })
    Save-SessionCheckpoint -LastPrompt $userInput -LastResponse "" -Status "Active"

    try {
        $result = Invoke-CodingAssistant -Messages @($messages)
        $reply = Remove-ThinkingTrace -Text $result.Content
        Write-Host "$(Get-ConsoleTimestamp) AI [$($result.Route)] > " -ForegroundColor Cyan -NoNewline
        Write-Host $reply
        Write-Host ""
        $messages.Add([ordered]@{ role = "assistant"; content = $reply })
        Save-SessionCheckpoint -LastPrompt $userInput -LastResponse $reply -Status "Complete"
    }
    catch {
        Save-SessionCheckpoint -LastPrompt $userInput -LastResponse $_.Exception.Message -Status "Interrupted"
        Write-Host "[Error] $($_.Exception.Message)" -ForegroundColor Red
    }
}
