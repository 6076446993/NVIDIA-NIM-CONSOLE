# Shared Codex retrieval adapter for NIM
# Reads the published Google Docs plain-text export URL when explicitly configured.
# A private Google Doc requires an authenticated provider; never treat an unauthenticated 403 as success.
Set-StrictMode -Version Latest
function Get-NimSharedCodex {
    param([Parameter(Mandatory=$true)][string]$ExportUrl)
    $expected = 'https://docs.google.com/document/d/1fDgUEvtrcUs-0F2RA2X6TibMvfU65MFU2LuVVgFYmOU/export?format=txt'
    if ($ExportUrl -ne $expected) { throw 'Codex export URL is not the approved document.' }
    $response = Invoke-WebRequest -Uri $ExportUrl -Method Get -MaximumRedirection 3 -ErrorAction Stop
    $body = [string]$response.Content
    if ([string]::IsNullOrWhiteSpace($body) -or $body -notmatch 'Codex Instructions' -or $body -notmatch 'Evidence-Based Instruction Following') {
        throw 'Codex response failed required content checks.'
    }
    return [pscustomobject]@{
        source = $ExportUrl
        sha256 = Get-NexusStringSha256 $body
        text = $body
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}
