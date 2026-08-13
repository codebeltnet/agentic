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
    'references/production-image.md', 'references/static-web-assets-guardrail.md',
    'assets/Dockerfile', 'assets/LocalDevelopment.Dockerfile', 'assets/Assets.Dockerfile',
    'assets/compose.assets.yml', 'assets/.dockerignore', 'assets/docker-compose.dcproj',
    'assets/launchSettings.json', 'assets/LocalPublishTarget.targets', 'assets/ci-artifact-jobs.yml',
    'assets/ci-pipeline.yml'
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
    '<ordinary-project-profile>.Assets',
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
    'app-img',
    'cdn-link',
    'cdn-script',
    'cdn-img',
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
foreach ($needle in @('AssetsProfileSuffix', 'LaunchProfileNaming.Resolve', 'ASSET_SOURCE_NOT_VERSIONED', 'ASSET_IMAGE_NOT_VALIDATED_IN_CI', 'com.microsoft.visual-studio.project-name', 'HasVisualStudioProjectOptOut')) {
    if (-not $runner.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "segregate-assets.cs is missing the profile/source/Visual Studio contract: $needle"
    }
}
foreach ($needle in @('resolvedNuGetPackages', 'Directory.Packages.props', 'prerelease', 'stop without proposing a package edit')) {
    if (-not $appVsCdn.Contains($needle, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "references/app-vs-cdn.md is missing package-version guidance: $needle"
    }
}
foreach ($staleSyntax in @('app-href', 'cdn-src', 'app-src', 'cdn-href', 'app-image', 'cdn-image')) {
    if ($appVsCdn.Contains($staleSyntax, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "references/app-vs-cdn.md contains stale or unverified Cuemon syntax: $staleSyntax"
    }
}

$evals = Get-Content -Raw (Join-Path $skillRoot 'evals/evals.json') | ConvertFrom-Json
$cuemonEval = @($evals.evals | Where-Object { $_.id -eq 3 })[0]
if ($null -eq $cuemonEval) {
    throw 'evals/evals.json must retain the Cuemon migration eval with id 3.'
}
foreach ($expected in @('app-link', 'app-script', 'app-img', 'cdn-link', 'cdn-script', 'cdn-img', 'AppAssetOptions', 'latest stable', 'NuGet.org', 'PackageVersion')) {
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
    'does not introduce a second asset configuration hierarchy alongside existing AppTagHelperOptions/CdnTagHelperOptions',
    'does not infer app-image or cdn-image from TagHelper class names instead of using HtmlTargetElement selectors'
)) {
    if (-not ((@($cuemonEval.expectations) -join "`n").Contains("NEGATIVE: $negative", [System.StringComparison]::Ordinal))) {
        throw "The Cuemon eval is missing required negative expectation: $negative"
    }
}
$cuemonFixtureLayout = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'evals/files/cuemon-app/Views/Shared/_Layout.cshtml'))
foreach ($staleSyntax in @('app-href', 'cdn-src', 'app-src', 'cdn-href', 'app-image', 'cdn-image')) {
    if ($cuemonFixtureLayout.Contains($staleSyntax, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The Cuemon eval fixture contains stale or unverified syntax: $staleSyntax"
    }
}
foreach ($selector in @('app-link', 'app-script', 'app-img', 'cdn-link', 'cdn-script', 'cdn-img')) {
    if (-not $runner.Contains("<$selector\b", [System.StringComparison]::Ordinal)) {
        throw "segregate-assets.cs does not detect the public Cuemon selector: $selector"
    }
}
foreach ($invalidSelector in @('app-image', 'cdn-image')) {
    if ($runner.Contains("<$invalidSelector\b", [System.StringComparison]::Ordinal)) {
        throw "segregate-assets.cs detects a class-name-inferred selector that Cuemon does not expose: $invalidSelector"
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
foreach ($needle in @('Microsoft.Docker.Sdk', 'DockerComposeBaseFilePath', 'DockerDevelopmentMode', 'DockerComposeProjectPath', 'commandName: DockerCompose', 'StartDebugging', 'StartWithoutDebugging', 'dhi.io/aspnetcore', 'Dockerfile', 'LocalDevelopment.Dockerfile', 'LocalPublishDirectory', 'artifacts/publish/', 'dhi.io/aspnetcore:<channel>-alpine<version>-dev', '/remote_debugger/linux-musl-x64/vsdbg', 'vsdbg --interpreter=vscode', 'A `.dcproj` build or Compose CLI smoke test is not proof of debugger attachment', 'directly builds the web service with `LocalDevelopment.Dockerfile`', 'do not add `DockerfileFile` or `BuildingInsideVisualStudio`', 'com.microsoft.visual-studio.project-name', 'do not add `docker-compose.vs.release.yml`')) {
    if (-not ($skill.Contains($needle, [System.StringComparison]::Ordinal) -or $localDevelopment.Contains($needle, [System.StringComparison]::Ordinal) -or $productionImage.Contains($needle, [System.StringComparison]::Ordinal))) {
        throw "The Visual Studio Compose guidance is missing required contract: $needle"
    }
}
$visualStudioComposeEval = @($evals.evals | Where-Object { $_.id -eq 14 })[0]
if ($null -eq $visualStudioComposeEval) {
    throw 'evals/evals.json must include the Visual Studio Docker Compose orchestration regression with id 14.'
}
foreach ($needle in @('commandName DockerCompose', 'Microsoft.Docker.Sdk', 'DockerComposeBaseFilePath', 'DockerDevelopmentMode', 'DockerComposeProjectPath', 'dhi.io/aspnetcore', 'LocalDevelopment.Dockerfile', 'dhi.io/aspnetcore:10-alpine3.23-dev', 'LocalPublishDirectory', 'COPY artifacts/publish/ .', 'web-app with debugging', 'app-assets without debugging', 'Assets.Dockerfile', 'same commit', '65532', 'Contoso.Web.Assets', 'com.microsoft.visual-studio.project-name', '/remote_debugger/linux-musl-x64/vsdbg', 'actual F5', 'vsdbg --interpreter=vscode')) {
    if (-not ($visualStudioComposeEval.expected_output.Contains($needle) -or (@($visualStudioComposeEval.expectations) -join "`n").Contains($needle))) {
        throw "The Visual Studio Compose eval is missing the expected contract: $needle"
    }
}
foreach ($negative in @(
    'does not claim that changing commandName from Project to Docker makes Visual Studio consume compose.assets.yml',
    'does not replace the asset-only Assets.Dockerfile with the web application Dockerfile',
    'does not compile the web application inside its Dockerfile',
    'does not add a second .dcproj when the repository already has a suitable Docker Compose project',
    'does not claim Visual Studio F5 debugging was tested from a dcproj build or Docker Compose CLI smoke test alone',
    'does not describe the ASP.NET -dev runtime as a .NET SDK image',
    'does not add DockerfileFile or BuildingInsideVisualStudio image-switching properties',
    'does not retain the legacy project-level segregated profile beside the root Contoso.Web.Assets DockerCompose profile',
    'does not add or retain docker-compose.vs.release.yml for debugger injection repair',
    'does not add a custom vsdbg volume mapping when LocalDevelopment.Dockerfile provides the supported development image'
)) {
    if (-not ((@($visualStudioComposeEval.expectations) -join "`n").Contains("NEGATIVE: $negative", [System.StringComparison]::Ordinal))) {
        throw "The Visual Studio Compose eval is missing required negative expectation: $negative"
    }
}

# The artifact-first templates are the fix for agents reconstructing Dockerfiles from memory.
# Keep them literal, artifact-first, and free of the SDK multi-stage pattern they replace.
$assetRoot = Join-Path $skillRoot 'assets'
foreach ($applicationDockerfile in @('Dockerfile', 'LocalDevelopment.Dockerfile')) {
    $text = [System.IO.File]::ReadAllText((Join-Path $assetRoot $applicationDockerfile))
    if (-not $text.Contains('COPY --chown=65532:65532 artifacts/publish/ .', [System.StringComparison]::Ordinal)) {
        throw "assets/$applicationDockerfile must package the published artifact with COPY --chown=65532:65532 artifacts/publish/ ."
    }
    if (-not $text.Contains('dhi.io/aspnetcore:', [System.StringComparison]::Ordinal)) {
        throw "assets/$applicationDockerfile must use the shell-less dhi.io/aspnetcore runtime family."
    }
    foreach ($forbidden in @('dotnet/sdk', 'dotnet publish', 'dotnet build', 'dotnet restore', 'adduser', 'addgroup', 'mcr.microsoft.com')) {
        if ($text.Contains($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "assets/$applicationDockerfile must stay artifact-first but contains: $forbidden"
        }
    }
}
$assetsDockerfile = [System.IO.File]::ReadAllText((Join-Path $assetRoot 'Assets.Dockerfile'))
if (-not $assetsDockerfile.Contains('FROM codebeltnet/web-cdn-origin:2.0.0', [System.StringComparison]::Ordinal)) {
    throw 'assets/Assets.Dockerfile must derive from codebeltnet/web-cdn-origin:2.0.0.'
}
$assetCompose = [System.IO.File]::ReadAllText((Join-Path $assetRoot 'compose.assets.yml'))
foreach ($needle in @('web-app:', 'app-assets:', 'com.microsoft.visual-studio.project-name: ""', 'read_only: true', 'no-new-privileges:true', 'LocalDevelopment.Dockerfile', 'Assets.Dockerfile')) {
    if (-not $assetCompose.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "assets/compose.assets.yml is missing required Compose contract: $needle"
    }
}
foreach ($forbidden in @('version:', 'networks:')) {
    if ($assetCompose.Contains($forbidden, [System.StringComparison]::Ordinal)) {
        throw "assets/compose.assets.yml must not declare: $forbidden"
    }
}
$assetDockerIgnore = [System.IO.File]::ReadAllText((Join-Path $assetRoot '.dockerignore'))
if ($assetDockerIgnore -match '(?m)^\s*(\*\*/)?artifacts') {
    throw 'assets/.dockerignore must not exclude artifacts/ — both application Dockerfiles copy artifacts/publish/.'
}
foreach ($needle in @('Microsoft.Docker.Sdk', '<DockerComposeBaseFilePath>compose.assets<', '<DockerDevelopmentMode>Regular<')) {
    if (-not ([System.IO.File]::ReadAllText((Join-Path $assetRoot 'docker-compose.dcproj'))).Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "assets/docker-compose.dcproj is missing required contract: $needle"
    }
}
foreach ($needle in @('"commandName": "DockerCompose"', '"web-app": "StartDebugging"', '"app-assets": "StartWithoutDebugging"')) {
    if (-not ([System.IO.File]::ReadAllText((Join-Path $assetRoot 'launchSettings.json'))).Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "assets/launchSettings.json is missing required contract: $needle"
    }
}
foreach ($ciTemplate in @('ci-artifact-jobs.yml', 'ci-pipeline.yml')) {
    $assetCiJobs = [System.IO.File]::ReadAllText((Join-Path $assetRoot $ciTemplate))
    foreach ($needle in @('--output artifacts/publish', 'Assets.Dockerfile', 'docker/build-push-action')) {
        if (-not $assetCiJobs.Contains($needle, [System.StringComparison]::Ordinal)) {
            throw "assets/$ciTemplate is missing required contract: $needle"
        }
    }
}
# The CI fallback stays two-tier because GitHub Actions is the assumed delivery surface.
foreach ($needle in @('assets/ci-pipeline.yml', 'A workflow exists', 'No workflow exists')) {
    if (-not $productionImage.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "references/production-image.md is missing the CI fallback contract: $needle"
    }
}
foreach ($vendor in @('azure-pipelines', 'gitlab-ci', 'Jenkinsfile', 'bitbucket-pipelines', 'circleci', 'teamcity')) {
    if ($productionImage.Contains($vendor, [System.StringComparison]::OrdinalIgnoreCase) -or $runner.Contains($vendor, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The skill must stay GitHub Actions-opinionated; remove the multi-vendor CI branch for: $vendor"
    }
}
$assetPublishTarget = [System.IO.File]::ReadAllText((Join-Path $assetRoot 'LocalPublishTarget.targets'))
foreach ($needle in @('$(LocalPublishDirectory)', "'`$(CI)' != 'true'", "'`$(DesignTimeBuild)' != 'true'")) {
    if (-not $assetPublishTarget.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "assets/LocalPublishTarget.targets is missing required contract: $needle"
    }
}

# File placement and the artifact-first contract are the regression this skill version fixes.
foreach ($needle in @('beside the web `.csproj`', 'Never place a Dockerfile at the repository root', 'assets/', 'artifact-first')) {
    if (-not ($skill.Contains($needle, [System.StringComparison]::Ordinal) -or $localDevelopment.Contains($needle, [System.StringComparison]::Ordinal))) {
        throw "The file-placement contract is missing from SKILL.md and references/local-development.md: $needle"
    }
}
foreach ($needle in @('ArtifactFirstValidator', 'UnsafeOriginDetector', 'NoObsoleteVersionKey', 'DockerfilesColocated', 'NoSourceCompilation', 'CiPublishesArtifact')) {
    if (-not $runner.Contains($needle, [System.StringComparison]::Ordinal)) {
        throw "segregate-assets.cs is missing the artifact-first verification contract: $needle"
    }
}
$placementEval = @($evals.evals | Where-Object { $_.id -eq 15 })[0]
if ($null -eq $placementEval) {
    throw 'evals/evals.json must include the Dockerfile-placement and artifact-first regression with id 15.'
}
foreach ($negative in @(
    'does not place any Dockerfile at the repository root',
    'does not emit a multi-stage SDK build that compiles the application inside Dockerfile or LocalDevelopment.Dockerfile',
    'does not use mcr.microsoft.com/dotnet/sdk or mcr.microsoft.com/dotnet/aspnetcore images for this topology',
    'does not create the runtime user with RUN addgroup or RUN adduser',
    'does not invent Compose host ports such as 5000 and 5001 instead of deriving 51642 from the ordinary Project profile',
    'does not emit the obsolete top-level Compose version key or a custom networks block',
    'does not omit .dockerignore, docker-compose.dcproj, or the root DockerCompose launchSettings.json when Visual Studio F5 is requested',
    'does not leave the artifact-first Dockerfile without a CI job that publishes artifacts/publish',
    'does not treat LocalPublishDirectory and the guarded publish target as optional once compose.assets.yml exists'
)) {
    if (-not ((@($placementEval.expectations) -join "`n").Contains("NEGATIVE: $negative", [System.StringComparison]::Ordinal))) {
        throw "The placement/artifact-first eval is missing required negative expectation: $negative"
    }
}

$forms = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'FORMS.md'))
if (-not $forms.Contains('### cdn_equivalent', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must define the cdn_equivalent field (the required CDN/shared-asset question).'
}
if (-not $forms.Contains('plain-text', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must define the deterministic plain-text fallback interaction.'
}
if (-not $forms.Contains('### visual_studio_compose', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must define the conditional Visual Studio Compose orchestration field.'
}
if (-not $forms.Contains('### web_host_port', [System.StringComparison]::Ordinal)) {
    throw 'FORMS.md must define web_host_port so the Compose web service reuses the ordinary profile HTTP port.'
}

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-segregated-assets.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "Runner test harness failed with exit code $LASTEXITCODE."
}

Write-Host 'dotnet-segregated-assets skill validation: PASS'
