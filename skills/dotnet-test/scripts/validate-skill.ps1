Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$required = @(
    'SKILL.md', 'FORMS.md', 'evals/evals.json',
    'scripts/inspect-dotnet-tests.ps1', 'scripts/resolve-test-package-versions.ps1', 'scripts/verify-dotnet-test-migration.ps1',
    'scripts/test-inspect-dotnet-tests.ps1', 'scripts/test-resolve-test-package-versions.ps1', 'scripts/test-verify-dotnet-test-migration.ps1',
    'references/unit-tests.md', 'references/web-functional-tests.md', 'references/application-functional-tests.md',
    'references/bootstrapper-hosts.md', 'references/xunit-v3-modernization.md', 'references/migration-invariants.md',
    'assets/unit/BehaviorTest.cs', 'assets/web/FocusedWebApplicationTest.cs', 'assets/web/SharedWebApplicationTest.cs',
    'assets/application/FocusedApplicationTest.cs', 'assets/application/SharedApplicationTest.cs',
    'assets/bootstrapper/console/Program.cs', 'assets/bootstrapper/console/Startup.cs',
    'assets/bootstrapper/worker/Program.cs', 'assets/bootstrapper/worker/Startup.cs', 'assets/bootstrapper/worker/Worker.cs',
    'assets/bootstrapper/console-minimal/Program.cs', 'assets/bootstrapper/worker-minimal/Program.cs',
    'assets/bootstrapper/web-minimal/Program.cs'
)

foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $relative) -PathType Leaf)) { throw "Missing required dotnet-test file: $relative" }
}

$skill = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'))
foreach ($needle in @('WebApplicationTestFactory', 'ApplicationTestFactory', 'ManagedWebApplicationFixture', 'ManagedApplicationFixture', 'verify-dotnet-test-migration.ps1', '-ExpectedWebPattern', '-ExpectedApplicationPattern', 'second composition root')) {
    if (-not $skill.Contains($needle, [System.StringComparison]::Ordinal)) { throw "SKILL.md is missing required contract: $needle" }
}
if (-not $skill.Contains('An MTP executable run may supplement that gate but never replaces it', [System.StringComparison]::Ordinal)) { throw 'SKILL.md must reject MTP executable substitution for requested dotnet test validation.' }
foreach ($needle in @('What finishing looks like', 'Wrapping the factory', 'Renaming the seam', 'Bumping packages instead')) {
    if (-not $skill.Contains($needle, [System.StringComparison]::Ordinal)) { throw "SKILL.md must keep the named laundering failure mode: $needle" }
}

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-resolve-test-package-versions.ps1')
if ($LASTEXITCODE -ne 0) { throw "Resolver regression failed with exit code $LASTEXITCODE." }

$evals = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'evals/evals.json'))
foreach ($needle in @('WebApplicationTestFactory.Create<Program>', 'ManagedWebApplicationFixture<Program>', 'WebApplication.CreateBuilder', 'verify-dotnet-test-migration.ps1', 'nested private CdnOriginApplicationFactory')) {
    if (-not $evals.Contains($needle, [System.StringComparison]::Ordinal)) { throw "Web eval is missing regression contract: $needle" }
}

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-inspect-dotnet-tests.ps1')
if ($LASTEXITCODE -ne 0) { throw "Inspection regression failed with exit code $LASTEXITCODE." }

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-verify-dotnet-test-migration.ps1')
if ($LASTEXITCODE -ne 0) { throw "Migration gate regression failed with exit code $LASTEXITCODE." }

Write-Host 'dotnet-test skill validation: PASS'
