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
    'reproduce',
    # Devex contract: invoking the skill is the request. A capability menu instead of a test run is the
    # regression these guards exist to prevent.
    'Default action: run the tests',
    'Forbidden as a first response',
    'You were invoked. That is the request. Run the tests.',
    'SelectionRequired',
    'Branch on the exit code',
    # A Microsoft SDK image carries one runtime, so multi-targeted repositories need a multi-SDK runner.
    # Losing this guidance means silently planning runs that build and then cannot execute.
    'codebeltnet/ubuntu-testrunner',
    'ships exactly **one** runtime',
    # A staged workspace without .git stops being a repository: version stamping falls back to 0.0.0 and
    # repository-root probes resolve elsewhere, which makes a suite fail here that passes in Visual
    # Studio's remote testing. Losing this guidance sends the agent chasing the repository instead.
    'The staged workspace is still a repository',
    # Reporting contract: a red test must be actionable from the report alone.
    'Do not compress this into a bare count'
)
foreach ($needle in $contracts) {
    if (-not $skill.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "SKILL.md is missing required contract: $needle"
    }
}

# Smaller models act on whatever they read first. The imperative must lead the file, ahead of any
# command enumeration they could mistake for a menu to offer the developer.
# Offsets are measured from the start of the body, not the file, so the frontmatter length does not
# affect the verdict.
$bodyMatch = [regex]::Match($skill, '(?ms)^---\r?\n.*?\r?\n---\r?\n')
$bodyStart = if ($bodyMatch.Success) { $bodyMatch.Index + $bodyMatch.Length } else { 0 }
$body = $skill.Substring($bodyStart)

$doThisNow = $body.IndexOf('## Do this now', [System.StringComparison]::Ordinal)
$commands = $body.IndexOf('Commands: ', [System.StringComparison]::Ordinal)
if ($doThisNow -lt 0) {
    throw 'SKILL.md must open with a "## Do this now" section so the default action is read first.'
}
if ($commands -ge 0 -and $commands -lt $doThisNow) {
    throw 'SKILL.md lists the command surface before "## Do this now"; the imperative must come first.'
}
if ($doThisNow -gt 100) {
    throw "SKILL.md places '## Do this now' too late (body offset $doThisNow); it must lead the document body."
}

# The exit-code decision table is what makes behavior identical across models. Every documented exit
# code must be present, so no outcome is left to improvisation.
foreach ($code in 0..16) {
    if (-not [regex]::IsMatch($skill, "(?m)^\|\s*``$code``\s*\|")) {
        throw "SKILL.md exit-code decision table is missing exit code $code."
    }
}

# Guard the governing principle: Docker complexity must not be the boundary of the capability.
if (-not $skill.Contains('orchestration', [System.StringComparison]::Ordinal)) {
    throw 'SKILL.md must describe the skill as the orchestration layer over a deterministic runner.'
}

$forms = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'FORMS.md'))

# The form must gate itself. Without this, the field list reads as an intake checklist and the skill
# interrogates developers who already stated what they want.
$formsContracts = @('Autonomy gate', 'not an intake checklist')
foreach ($needle in $formsContracts) {
    if (-not $forms.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "FORMS.md is missing required autonomy contract: $needle"
    }
}

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
