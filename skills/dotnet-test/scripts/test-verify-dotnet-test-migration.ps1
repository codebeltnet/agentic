Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-test-verify-' + [Guid]::NewGuid().ToString('N'))

function Write-File {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

$gate = Join-Path $PSScriptRoot 'verify-dotnet-test-migration.ps1'
$projectPath = 'test/App.FunctionalTests/App.FunctionalTests.csproj'

function Invoke-Gate {
    $output = @(& pwsh -NoProfile -File $gate -RepoRoot $workspace -ProjectPath $projectPath -ExpectedWebPattern Focused 2>&1)
    return [pscustomobject]@{
        exitCode = $LASTEXITCODE
        text = ($output -join [Environment]::NewLine)
    }
}

function Assert-Codes {
    param([string]$Scenario, [object]$Run, [int]$ExpectedExit, [string[]]$Expected = @(), [string[]]$Forbidden = @())

    if ($Run.exitCode -ne $ExpectedExit) {
        throw "[$Scenario] expected exit $ExpectedExit, found $($Run.exitCode).`n$($Run.text)"
    }
    foreach ($code in $Expected) {
        if ($Run.text -notmatch [regex]::Escape("[$code]")) { throw "[$Scenario] expected violation $code.`n$($Run.text)" }
    }
    foreach ($code in $Forbidden) {
        if ($Run.text -match [regex]::Escape("[$code]")) { throw "[$Scenario] did not expect $code.`n$($Run.text)" }
    }
}

$packagesPath = Join-Path $workspace 'Directory.Packages.props'
$testProjectPath = Join-Path $workspace 'test/App.FunctionalTests/App.FunctionalTests.csproj'
$harnessPath = Join-Path $workspace 'test/App.FunctionalTests/AppTestApplication.cs'
$assetsPath = Join-Path $workspace 'test/App.FunctionalTests/obj/project.assets.json'

$anchoredPackages = @'
<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup><ItemGroup><PackageVersion Include="Codebelt.Extensions.Xunit.App" Version="11.2.1" /><PackageVersion Include="Microsoft.AspNetCore.Mvc.Testing" Version="10.0.0" /><PackageVersion Include="xunit.v3" Version="3.2.2" /><PackageVersion Include="xunit.v3.assert" Version="3.2.2" /><PackageVersion Include="xunit.runner.visualstudio" Version="3.1.5" /></ItemGroup></Project>
'@

$legacyProjectReferences = @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><PackageReference Include="Codebelt.Extensions.Xunit.App" /><PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" /><PackageReference Include="xunit.v3" /><PackageReference Include="xunit.v3.assert" /><PackageReference Include="xunit.runner.visualstudio" /><ProjectReference Include="../../app/App.csproj" /></ItemGroup></Project>
'@

$migratedProjectReferences = @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><PackageReference Include="Codebelt.Extensions.Xunit.App" /><PackageReference Include="xunit.v3" /><PackageReference Include="xunit.v3.assert" /><PackageReference Include="xunit.runner.visualstudio" /><ProjectReference Include="../../app/App.csproj" /></ItemGroup></Project>
'@

# The exact shape the failed web-cdn-origin run produced: the legacy factory survives as a private
# nested class behind a renamed facade, so every test file changes while the host never moves.
$launderedHarness = @'
using Microsoft.AspNetCore.Mvc.Testing;

public sealed class AppTestApplication : IDisposable
{
    private readonly WebApplicationFactory<Program> _factory;

    private AppTestApplication(WebApplicationFactory<Program> factory) { _factory = factory; }

    public static AppTestApplication Create() => new AppTestApplication(new AppApplicationFactory());

    public HttpClient CreateClient() => _factory.CreateClient();

    public void Dispose() { _factory.Dispose(); }

    private sealed class AppApplicationFactory : WebApplicationFactory<Program>
    {
    }
}
'@

$migratedHarness = @'
using Codebelt.Extensions.Xunit;
using Codebelt.Extensions.Xunit.Hosting;
using Codebelt.Extensions.Xunit.Hosting.AspNetCore;

public class HealthTest : Test
{
    private readonly IHostTest _application = WebApplicationTestFactory.Create<Program>(hostFixture: new ManagedWebApplicationFixture<Program>());

    protected override void OnDisposeManagedResources() { _application.Dispose(); base.OnDisposeManagedResources(); }

    protected override async ValueTask OnDisposeManagedResourcesAsync() { await _application.DisposeAsync(); await base.OnDisposeManagedResourcesAsync(); }
}
'@

function Write-Assets {
    param([string]$XunitAssertVersion = '3.2.2')
    Write-File -Path $assetsPath -Content ('{"version":3,"targets":{"net10.0":{"Codebelt.Extensions.Xunit.App/11.2.1":{"type":"package","dependencies":{"Codebelt.Extensions.Xunit":"11.2.1","xunit.v3.assert":"' + $XunitAssertVersion + '","xunit.v3.extensibility.core":"' + $XunitAssertVersion + '"}}}},"libraries":{}}')
}

New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    Write-File -Path (Join-Path $workspace 'app/App.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'app/Program.cs') -Content @'
public class Program { public static void Main(string[] args) { var builder = WebApplication.CreateBuilder(args); builder.Build().Run(); } }
'@
    Write-File -Path $packagesPath -Content $anchoredPackages
    Write-File -Path $testProjectPath -Content $legacyProjectReferences
    Write-File -Path $harnessPath -Content $launderedHarness
    Write-Assets

    # A repository with no git history must not crash the churn check; it simply has nothing to compare.
    $noGit = Invoke-Gate
    Assert-Codes -Scenario 'laundered facade without git' -Run $noGit -ExpectedExit 1 `
        -Expected @('LAUNDERED-FACADE', 'WAF-RETAINED', 'PATTERN-MISSING', 'FIXTURE-MISSING', 'LEGACY-PACKAGE-RETAINED') `
        -Forbidden @('CHURN-WITHOUT-CONVERSION')

    # `git init` alone is enough to make every file report as untracked, which is what the churn
    # check reads. No commit, and therefore no identity configuration, is involved.
    & git -C $workspace init --quiet 2>&1 | Out-Null
    $laundered = Invoke-Gate
    Assert-Codes -Scenario 'laundered facade' -Run $laundered -ExpectedExit 1 -Expected @('LAUNDERED-FACADE', 'CHURN-WITHOUT-CONVERSION')
    if ($laundered.text -notmatch 'result\s+:\s+FAILED') { throw "[laundered facade] expected a FAILED verdict line.`n$($laundered.text)" }

    # Positive control: a real migration has to pass, otherwise the gate is noise rather than signal.
    Remove-Item -LiteralPath $harnessPath -Force
    Write-File -Path (Join-Path $workspace 'test/App.FunctionalTests/HealthTest.cs') -Content $migratedHarness
    Write-File -Path $testProjectPath -Content $migratedProjectReferences
    $migrated = Invoke-Gate
    Assert-Codes -Scenario 'completed migration' -Run $migrated -ExpectedExit 0 `
        -Forbidden @('LAUNDERED-FACADE', 'WAF-RETAINED', 'PATTERN-MISSING', 'FIXTURE-MISSING', 'LEGACY-PACKAGE-RETAINED', 'CHURN-WITHOUT-CONVERSION', 'XUNIT-ANCHOR-BREACH')
    if ($migrated.text -notmatch 'result\s+:\s+PASSED') { throw "[completed migration] expected a PASSED verdict line.`n$($migrated.text)" }
    if ($migrated.text -notmatch 'anchor\s+:\s+Codebelt\.Extensions\.Xunit\.App 11\.2\.1') { throw "[completed migration] expected the resolved anchor in the verdict.`n$($migrated.text)" }

    # Bumping an unanchored xunit id past the anchor major is the version-drift half of the same slop.
    Write-File -Path $packagesPath -Content ($anchoredPackages -replace 'Include="xunit.v3" Version="3.2.2"', 'Include="xunit.v3" Version="4.0.0"')
    $anchorBreach = Invoke-Gate
    Assert-Codes -Scenario 'xunit major breach' -Run $anchorBreach -ExpectedExit 1 -Expected @('XUNIT-ANCHOR-BREACH')
    if ($anchorBreach.text -notmatch 'xunit\.v3 is pinned to 4\.0\.0') { throw "[xunit major breach] expected the offending id and version.`n$($anchorBreach.text)" }

    # An id the anchor names itself has to match exactly, not merely stay inside the major.
    Write-File -Path $packagesPath -Content ($anchoredPackages -replace 'Include="xunit.v3.assert" Version="3.2.2"', 'Include="xunit.v3.assert" Version="3.1.0"')
    $exactBreach = Invoke-Gate
    Assert-Codes -Scenario 'anchored id drift' -Run $exactBreach -ExpectedExit 1 -Expected @('XUNIT-ANCHOR-BREACH')
    if ($exactBreach.text -notmatch 'declares 3\.2\.2') { throw "[anchored id drift] expected the declared anchor version.`n$($exactBreach.text)" }

    # Without a restored anchor the versions are unproven, which is a warning about missing evidence
    # rather than a violation: reporting an unverifiable breach would be a guess.
    Write-File -Path $packagesPath -Content $anchoredPackages
    Remove-Item -LiteralPath $assetsPath -Force
    $unverified = Invoke-Gate
    Assert-Codes -Scenario 'unrestored anchor' -Run $unverified -ExpectedExit 0 -Forbidden @('XUNIT-ANCHOR-BREACH')
    if ($unverified.text -notmatch 'XUNIT-ANCHOR-UNVERIFIED') { throw "[unrestored anchor] expected the unverified warning.`n$($unverified.text)" }

    $missingExpectation = @(& pwsh -NoProfile -File $gate -RepoRoot $workspace -ProjectPath $projectPath 2>&1)
    if ($LASTEXITCODE -ne 2) { throw "Expected a usage error without an expected pattern, found $LASTEXITCODE.`n$($missingExpectation -join [Environment]::NewLine)" }

    Write-Output 'verify-dotnet-test-migration.ps1 checks passed.'
} finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
