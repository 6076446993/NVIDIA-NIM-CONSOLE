# NIM instruction-ledger regression checks (static source contract)
# Run from repository root: pwsh -NoProfile -File tests/InstructionLedgerRegression.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../NexusCodingWorkflow.ps1') -Raw -Encoding UTF8
$required = @('instructionLedgerVersion = 1', 'promptSha256 = Get-NexusStringSha256 $TaskDescription', "id = 'original-request'", "status = 'INCOMPLETE'", 'Original prompt changed after workflow creation.', 'Requirement not independently verified:', "requirement.status = 'VERIFIED'")
foreach ($fragment in $required) {
    if (-not $source.Contains($fragment)) { throw "Missing instruction-ledger source contract: $fragment" }
}
Write-Output 'Instruction ledger source contracts present (static check only; not an end-to-end execution test).'
