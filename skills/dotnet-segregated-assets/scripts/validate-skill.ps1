#!/usr/bin/env pwsh
# Structural + contract validation for the dotnet-segregated-assets skill.
# Confirms required files exist, SKILL.md and FORMS.md keep their non-negotiable contracts, and the
# deterministic runner harness (which includes the built-in --self-test) passes.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$required = @(
    'SKILL.md', 'FORMS.md', 'evals/evals.json',
    'scripts/segregate-assets.cs', 'scripts/test-segregated-assets.ps1', 'scripts/validate-skill.ps1',
    'references/app-vs-cdn.md', 'references/local-development.md',
    'references/production-image.md', 'references/static-web-assets-guardrail.md'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $relative) -PathType Leaf)) {
        throw "Missing required dotnet-segregated-assets file: $relative"
    }
}

$skill = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'))
$contracts = @(
    'codebeltnet/web-cdn-origin:2.0.0',
    '/cdnroot',
    'wwwroot',
    'authoring root',
    'http-segregated-assets',
    'App assets',
    'CDN assets',
    'CopyToPublishDirectory="Never"',
    'StaticWebAssetsEnabled',
    '65532',
    'orchestrat',
    'segregate-assets.cs',
    'domain sharding',
    'generated-static-assets',
    'approot'
)
foreach ($needle in $contracts) {
    if (-not $skill.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "SKILL.md is missing required contract: $needle"
    }
}

$productionImage = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'references/production-image.md'))
$dockerfileContracts = @('<something>.Dockerfile', 'PascalCase', 'Assets.Dockerfile', 'Dockerfile.assets', '--file')
foreach ($source in @(
    [pscustomobject]@{ Name = 'SKILL.md'; Text = $skill },
    [pscustomobject]@{ Name = 'references/production-image.md'; Text = $productionImage }
)) {
    foreach ($needle in $dockerfileContracts) {
        if (-not $source.Text.Contains($needle, [System.StringComparison]::Ordinal)) {
            throw "$($source.Name) is missing Dockerfile naming contract: $needle"
        }
    }
}

# The skill must not *recommend* the removed 1.4 pattern or a blanket kill switch. It may name them only
# to warn against them, so require the warning framing (a "not"/"Do not"/"Never"/"removed" cue) to be near
# each anti-pattern rather than forbidding the phrase outright.
$antiPatterns = @('approot', 'StaticWebAssetsEnabled')
foreach ($needle in $antiPatterns) {
    $idx = $skill.IndexOf($needle, [System.StringComparison]::Ordinal)
    $window = $skill.Substring([Math]::Max(0, $idx - 160), [Math]::Min(320, $skill.Length - [Math]::Max(0, $idx - 160)))
    if ($window -notmatch '(?i)\b(do not|don''t|never|not\b|removed|reintroduce|instead of|rather than)') {
        throw "SKILL.md mentions '$needle' but not in a clear warning/negative context."
    }
}

$forms = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'FORMS.md'))
if (-not $forms.Contains('### cdn_equivalent', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must define the cdn_equivalent field (the required CDN/shared-asset question).'
}
if (-not $forms.Contains('plain-text', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must define the deterministic plain-text fallback interaction.'
}

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-segregated-assets.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "Runner test harness failed with exit code $LASTEXITCODE."
}

Write-Host 'dotnet-segregated-assets skill validation: PASS'
