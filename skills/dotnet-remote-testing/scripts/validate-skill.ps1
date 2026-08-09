#!/usr/bin/env pwsh
# Structural + contract validation for the dotnet-remote-testing skill.
# Confirms required files exist, SKILL.md keeps its non-negotiable contracts, and the deterministic
# runner test harness (which includes the built-in --self-test) passes.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$required = @(
    'SKILL.md', 'FORMS.md', 'evals/evals.json',
    'scripts/remote-test.cs', 'scripts/test-remote-testing.ps1', 'scripts/validate-skill.ps1',
    'references/testenvironments-json.md', 'references/release-discovery.md', 'references/docker-execution.md'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $relative) -PathType Leaf)) {
        throw "Missing required dotnet-remote-testing file: $relative"
    }
}

$skill = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'))
$contracts = @(
    'testenvironments.json',
    'mcr.microsoft.com/dotnet/sdk',
    'remote-test.cs',
    'Choose a test environment',
    'Do not generate container plumbing',
    'Do not hardcode .NET versions',
    'never silently fall back to local',
    'reproduce'
)
foreach ($needle in $contracts) {
    if (-not $skill.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "SKILL.md is missing required contract: $needle"
    }
}

# Guard the governing principle: Docker complexity must not be the boundary of the capability.
if (-not $skill.Contains('orchestration', [System.StringComparison]::Ordinal)) {
    throw 'SKILL.md must describe the skill as the orchestration layer over a deterministic runner.'
}

$forms = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'FORMS.md'))
$projectField = [regex]::Match($forms, '(?ms)^### project\s*(?<body>.*?)(?=^### |\z)')
if (-not $projectField.Success -or
    -not $projectField.Groups['body'].Value.Contains('- **choices:**', [System.StringComparison]::Ordinal) -or
    -not $projectField.Groups['body'].Value.Contains('exact target returned by `remote-test.cs plan`', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must expose the computed project target as a selectable choice.'
}

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-remote-testing.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "Runner test harness failed with exit code $LASTEXITCODE."
}

Write-Host 'dotnet-remote-testing skill validation: PASS'
