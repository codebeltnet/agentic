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
    'Static Web Assets',
    '65532',
    'orchestrat',
    'segregate-assets.cs',
    'generated-static-assets',
    'Boundaries',
    'AppTagHelperOptions',
    'CdnTagHelperOptions',
    'app-link',
    'app-script',
    'app-image',
    'cdn-link',
    'cdn-script',
    'cdn-image',
    'Automatic',
    'BaseUrlMode',
    'TagHelperBaseUrlMode',
    'ProtocolUriScheme',
    'ICacheBusting',
    'CacheBustingTagHelper',
    'AddCacheBusting',
    'runner never edits',
    'NuGet.org',
    'resolvedNuGetPackages',
    'latest-stable'
)
foreach ($needle in $contracts) {
    if (-not $skill.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "SKILL.md is missing required contract: $needle"
    }
}

$productionImage = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'references/production-image.md'))
$appVsCdn = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'references/app-vs-cdn.md'))
$runner = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts/segregate-assets.cs'))
foreach ($needle in @(
    'https://api.nuget.org/v3/index.json',
    'PackageBaseAddress/3.0.0',
    'latest-stable',
    'DependencyResolutionFailed',
    'nuget-package-version'
)) {
    if (-not $runner.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "segregate-assets.cs is missing deterministic NuGet contract: $needle"
    }
}
foreach ($needle in @('resolvedNuGetPackages', 'Directory.Packages.props', 'prerelease', 'stop without proposing a package edit')) {
    if (-not $appVsCdn.Contains($needle, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "references/app-vs-cdn.md is missing package-version guidance: $needle"
    }
}
foreach ($staleSyntax in @('app-href', 'cdn-src', 'app-src', 'cdn-href')) {
    if ($appVsCdn.Contains($staleSyntax, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "references/app-vs-cdn.md contains stale or unverified Cuemon syntax: $staleSyntax"
    }
}

$evals = Get-Content -Raw (Join-Path $skillRoot 'evals/evals.json') | ConvertFrom-Json
$cuemonEval = @($evals.evals | Where-Object { $_.id -eq 3 })[0]
if ($null -eq $cuemonEval) {
    throw 'evals/evals.json must retain the Cuemon migration eval with id 3.'
}
foreach ($expected in @('app-link', 'app-script', 'app-image', 'cdn-link', 'cdn-script', 'cdn-image', 'AppAssetOptions', 'latest stable', 'NuGet.org', 'PackageVersion')) {
    if (-not ($cuemonEval.expected_output.Contains($expected) -or (@($cuemonEval.expectations) -join "`n").Contains($expected))) {
        throw "The Cuemon eval is missing the expected contract: $expected"
    }
}
foreach ($negative in @(
    'does not create AppAssetOptions when Cuemon TagHelpers are available',
    'does not retain AppAssetOptions after all consumers have migrated',
    'does not use fictional app-href/cdn-src syntax',
    'does not configure CDN assets to fall back to the application host',
    'does not duplicate shared CDN assets into wwwroot',
    'does not alter the normal Development profile merely to support segregation',
    'does not add Cuemon to a project that otherwise does not use Cuemon',
    'does not add a Cuemon cache-busting package or registration merely to implement segregation',
    'does not reuse the obsolete 6.1.0 version or fall back to a version from templates, fixtures, examples, or memory when NuGet resolution fails',
    'does not make the deterministic runner rewrite Razor source',
    'does not introduce a second asset configuration hierarchy alongside existing AppTagHelperOptions/CdnTagHelperOptions'
)) {
    if (-not ((@($cuemonEval.expectations) -join "`n").Contains("NEGATIVE: $negative", [System.StringComparison]::Ordinal))) {
        throw "The Cuemon eval is missing required negative expectation: $negative"
    }
}
$cuemonFixtureLayout = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'evals/files/cuemon-app/Views/Shared/_Layout.cshtml'))
foreach ($staleSyntax in @('app-href', 'cdn-src', 'app-src', 'cdn-href')) {
    if ($cuemonFixtureLayout.Contains($staleSyntax, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The Cuemon eval fixture contains stale or unverified syntax: $staleSyntax"
    }
}
$cuemonFixturePackages = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'evals/files/cuemon-app/Directory.Packages.props'))
$cuemonFixtureProject = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'evals/files/cuemon-app/Tolk.Web.csproj'))
if (-not $cuemonFixturePackages.Contains('<PackageVersion Include="Cuemon.AspNetCore.Razor.TagHelpers" Version="6.1.0" />', [System.StringComparison]::Ordinal)) {
    throw 'The Cuemon eval must retain the stale Central Package Management version that reproduces the regression.'
}
if (-not $cuemonFixtureProject.Contains('<PackageReference Include="Cuemon.AspNetCore.Razor.TagHelpers" />', [System.StringComparison]::Ordinal)) {
    throw 'The Cuemon eval project must keep its centrally managed PackageReference versionless.'
}

$dockerfileContracts = @('<something>.Dockerfile', 'PascalCase', 'Assets.Dockerfile', '--file')
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

$localDevelopment = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'references/local-development.md'))
$composeSources = @(
    [pscustomobject]@{ Name = 'SKILL.md'; Text = $skill },
    [pscustomobject]@{ Name = 'references/local-development.md'; Text = $localDevelopment },
    [pscustomobject]@{ Name = 'references/production-image.md'; Text = $productionImage }
)
foreach ($source in $composeSources) {
    if (-not $source.Text.Contains('compose.assets.yml', [System.StringComparison]::Ordinal)) {
        throw "$($source.Name) is missing Compose naming contract: compose.assets.yml"
    }
}
if (-not $localDevelopment.Contains('docker compose -f compose.assets.yml', [System.StringComparison]::Ordinal)) {
    throw 'references/local-development.md must show the canonical compose.assets.yml invocation.'
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
