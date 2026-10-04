param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$utf8 = [System.Text.UTF8Encoding]::new($false)
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-scaffold-mtp-' + [Guid]::NewGuid().ToString('N'))
$completed = $false

function Write-Text {
    param([string]$Path, [string]$Content)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Render-Template {
    param([string]$Source, [string]$Destination, [hashtable]$Map)
    $content = [System.IO.File]::ReadAllText((Join-Path $repoRoot $Source), $utf8)
    foreach ($key in $Map.Keys) { $content = $content.Replace($key, [string]$Map[$key]) }
    Write-Text -Path $Destination -Content $content
}

function Invoke-DotNet {
    param([string[]]$Arguments)
    $output = @(& dotnet @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed (exit $LASTEXITCODE):`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

try {
    [void][System.IO.Directory]::CreateDirectory($workspace)
    # Test version-line selection with a newer future major, prereleases, and mismatched ASP.NET majors.
    & {
        function Invoke-RestMethod {
            param([string]$Uri)
            if ($Uri.EndsWith('/v3/index.json')) {
                return @{ resources = @(@{ '@type' = 'PackageBaseAddress/3.0.0'; '@id' = 'https://fixture.invalid/' }) }
            }
            $versions = switch -Regex ($Uri) {
                '/codebelt.extensions.xunit.app/' { @('11.2.1', '12.0.0', '12.0.1', '12.1.0-preview.1', '13.0.0'); break }
                '/xunit.v3(?:.runner.console)?/' { @('3.2.2', '4.0.0', '4.0.1', '4.1.0-preview.1', '5.0.0'); break }
                '/microsoft.aspnetcore.' { @('9.0.14', '10.0.12', '11.0.0'); break }
                default { @('1.0.0', '1.0.1', '2.0.0-preview.1') }
            }
            return @{ versions = $versions }
        }
        $resolved = & (Join-Path $repoRoot 'skills/dotnet-new-app-slnx/scripts/resolve-package-versions.ps1') -TargetFramework net10.0 | ConvertFrom-Json
        foreach ($pair in @(
            @('{CODEBELT_EXTENSIONS_XUNIT_APP_VERSION}', '12.0.1'),
            @('{XUNIT_V3_VERSION}', '4.0.1'),
            @('{XUNIT_V3_RUNNER_CONSOLE_VERSION}', '4.0.1'),
            @('{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}', '10.0.12')
        )) {
            if ($resolved.($pair[0]).version -ne $pair[1]) { throw "Resolver selected the wrong API line for $($pair[0])." }
        }
        Write-Host '[PASS] Resolver preserves authorized test-stack majors and excludes prereleases.'
    }

    $sdkVersions = @(& dotnet --list-sdks)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate installed SDKs.' }
    $sdk = @($sdkVersions | ForEach-Object {
        if ($_ -match '^(\d+\.\d+\.\d+)\s' -and [version]$Matches[1] -ge [version]'10.0.100') { $Matches[1] }
    } | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
    if ($sdk.Count -ne 1) { throw 'A supported non-preview .NET 10+ SDK is required for scaffold MTP tests.' }

    # Fixed package versions are reproducible regression fixtures, not generated scaffold defaults.
    $versions = @{
        '{CODEBELT_EXTENSIONS_XUNIT_APP_VERSION}' = '12.0.1'
        '{XUNIT_V3_VERSION}' = '4.0.1'
        '{XUNIT_V3_RUNNER_CONSOLE_VERSION}' = '4.0.1'
        '{XUNIT_RUNNER_VISUALSTUDIO_VERSION}' = '4.0.0'
        '{CODEBELT_COVERLET_MTP_VERSION}' = '10.1.0'
        '{MICROSOFT_TESTING_EXTENSIONS_HANGDUMP_VERSION}' = '2.4.1'
        '{MICROSOFT_NET_TEST_SDK_VERSION}' = '18.10.1'
        '{MINVER_VERSION}' = '8.0.0'
        '{CODEBELT_BOOTSTRAPPER_WEB_VERSION}' = '5.2.2'
        '{CODEBELT_BOOTSTRAPPER_CONSOLE_VERSION}' = '5.2.2'
        '{CODEBELT_BOOTSTRAPPER_WORKER_VERSION}' = '5.2.2'
        '{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}' = '10.0.12'
        '{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}' = '10.0.12'
        '{MICROSOFT_EXTENSIONS_HOSTING_VERSION}' = '10.0.12'
        '{BENCHMARKDOTNET_VERSION}' = '0.15.8'
        '{BENCHMARKDOTNET_DIAGNOSTICS_WINDOWS_VERSION}' = '0.15.8'
        '{CODEBELT_EXTENSIONS_BENCHMARKDOTNET_CONSOLE_VERSION}' = '1.3.4'
    }
    # Exercise the app meta-package's net9/net10 runtime groups; do not add older-runtime workarounds.
    $cases = @(
        @{ Variant = 'app'; HostType = 'web'; AppType = 'Web'; Tfm = 'net10.0' },
        @{ Variant = 'app'; HostType = 'console'; AppType = 'Console'; Tfm = 'net9.0' },
        @{ Variant = 'app'; HostType = 'worker'; AppType = 'Worker'; Tfm = 'net10.0' },
        @{ Variant = 'lib'; Tfm = 'net10.0' },
        @{ Variant = 'lib'; Tfm = 'net9.0' }
    )
    foreach ($case in $cases) {
        $variant = $case.Variant
        $assetVariant = if ($variant -eq 'app') { 'app' } else { 'library' }
        $skillRoot = "skills/dotnet-new-$variant-slnx"
        $projectName = if ($variant -eq 'app') { "Acme.$($case.AppType)" } else { 'Acme.Library' }
        $testSuffix = if ($variant -eq 'app') { 'FunctionalTests' } else { 'Tests' }
        $caseName = "$projectName-$($case.Tfm)"
        $caseRoot = Join-Path $workspace $caseName
        $map = $versions.Clone()
        $map['{ROOT_NAMESPACE}'] = if ($variant -eq 'app') { 'Acme' } else { 'Acme.Library' }
        $map['{PROJECT_NAME}'] = $projectName
        $map['{SOLUTION_NAME}'] = 'MtpScaffold'
        $map['{AppType}'] = if ($variant -eq 'app') { $case.AppType } else { '' }
        $map['{TARGET_FRAMEWORK}'] = $case.Tfm
        $map['{TARGET_FRAMEWORKS}'] = $case.Tfm
        $map['{AUTHOR}'] = 'Scaffold Regression'
        $map['{AUTHOR_EMAIL}'] = 'fixture@example.invalid'
        $map['{COMPANY_OR_PERSON}'] = 'Scaffold Regression'
        $map['{COPYRIGHT_YEAR}'] = '2026'
        $map['{PACKAGE_PROJECT_URL}'] = 'https://example.invalid/library'
        $map['{REPOSITORY_URL}'] = 'https://example.invalid/scaffold'
        $map['{SNK_FILE}'] = 'fixture.snk'

        $manifest = [System.IO.File]::ReadAllText((Join-Path $repoRoot "$skillRoot/assets/shared.manifest.json")) | ConvertFrom-Json
        foreach ($file in $manifest.files) {
            Render-Template -Source "$skillRoot/assets/shared/$file" -Destination (Join-Path $caseRoot $file) -Map $map
        }
        $agentsPath = Join-Path $caseRoot 'AGENTS.md'
        if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) { throw "$caseName is missing root AGENTS.md." }
        if (Get-ChildItem -LiteralPath $caseRoot -Recurse -File -Force -Filter 'copilot-instructions.md') {
            throw "$caseName emitted a Copilot-specific instruction file."
        }
        $agents = [System.IO.File]::ReadAllText($agentsPath)
        foreach ($rule in @('InternalsVisibleTo', 'ExcludeFromCodeCoverage', 'Xunit.Abstractions', 'BenchmarkDotNet', 'RootNamespace', '<summary>')) {
            if (-not $agents.Contains($rule)) { throw "$caseName root AGENTS.md lost the $rule guidance." }
        }
        $bot = [System.IO.File]::ReadAllText((Join-Path $caseRoot '.bot/README.md'))
        if (-not $bot.Contains('into root `AGENTS.md`.') -or $bot -match '(?i)Copilot') {
            throw "$caseName .bot guidance must point only to root AGENTS.md."
        }
        Write-Host "[PASS] $caseName emits the complete shared inventory with vendor-neutral root AGENTS.md."
        # Select a stable installed SDK only in this isolated regression workspace.
        $globalPath = Join-Path $caseRoot 'global.json'
        $global = [System.IO.File]::ReadAllText($globalPath) | ConvertFrom-Json
        if ($global.test.runner -ne 'Microsoft.Testing.Platform') { throw "$caseName did not select MTP." }
        $global | Add-Member -NotePropertyName sdk -NotePropertyValue @{ version = $sdk[0]; rollForward = 'latestPatch'; allowPrerelease = $false }
        Write-Text -Path $globalPath -Content ($global | ConvertTo-Json -Depth 5)
        Render-Template -Source "$skillRoot/assets/$assetVariant/Directory.Build.props" -Destination (Join-Path $caseRoot 'Directory.Build.props') -Map $map
        $sourceProject = "src/$projectName/$projectName.csproj"
        $testProject = "test/$projectName.$testSuffix/$projectName.$testSuffix.csproj"
        $sourceTemplate = if ($variant -eq 'app') { "$($case.HostType).csproj" } else { 'source.csproj' }
        Render-Template -Source "$skillRoot/assets/$assetVariant/$sourceTemplate" -Destination (Join-Path $caseRoot $sourceProject) -Map $map
        Render-Template -Source "$skillRoot/assets/$assetVariant/test.csproj" -Destination (Join-Path $caseRoot $testProject) -Map $map
        $sourceCode = if ($variant -eq 'app') { "$skillRoot/assets/app/$($case.HostType)/Program.minimal.cs" } else { '' }
        if ($variant -eq 'app') {
            Render-Template -Source $sourceCode -Destination (Join-Path $caseRoot "src/$projectName/Program.cs") -Map $map
            if ($case.HostType -eq 'worker') {
                Render-Template -Source "$skillRoot/assets/app/worker/Worker.cs" -Destination (Join-Path $caseRoot "src/$projectName/Worker.cs") -Map $map
            }
        } else {
            Write-Text -Path (Join-Path $caseRoot "src/$projectName/PriceCalculator.cs") -Content @'
namespace Acme.Library;

/// <summary>Computes a price including sales tax.</summary>
public static class PriceCalculator
{
    /// <summary>Applies the specified sales tax rate to a price.</summary>
    /// <param name="price">The untaxed price.</param>
    /// <param name="taxRate">The fractional tax rate.</param>
    /// <returns>The price including sales tax.</returns>
    public static decimal AddTax(decimal price, decimal taxRate)
    {
        return price * (1 + taxRate);
    }
}
'@
        }
        $body = if ($variant -eq 'lib') {
            'Assert.Equal(120m, PriceCalculator.AddTax(100m, 0.20m));'
        } elseif ($case.HostType -eq 'web') {
            @'
using (var application = WebApplicationTestFactory.Create<Program>(hostFixture: new ManagedWebApplicationFixture<Program>()))
        using (var client = application.Host.GetTestClient())
        {
            Assert.Equal("Hello from Acme.Web.", await client.GetStringAsync("/"));
        }
'@
        } else {
            $assertion = if ($case.HostType -eq 'worker') {
                'Assert.Contains(application.Host.Services.GetServices<IHostedService>(), service => service is Worker);'
            } else {
                'Assert.NotNull(application.Host.Services.GetRequiredService<IHostApplicationLifetime>());'
            }
            "using (var application = ApplicationTestFactory.Create<Program>(hostFixture: new ManagedApplicationFixture<Program>()))`n        {`n            $assertion`n        }"
        }
        $returnType = if ($variant -eq 'app' -and $case.HostType -eq 'web') { 'async Task' } else { 'void' }
        $imports = if ($variant -eq 'lib') { '' } else {
            "using Codebelt.Extensions.Xunit.Hosting;`nusing Microsoft.Extensions.DependencyInjection;`nusing Microsoft.Extensions.Hosting;"
        }
        if ($variant -eq 'app' -and $case.HostType -eq 'web') {
            $imports += "`nusing Codebelt.Extensions.Xunit.Hosting.AspNetCore;`nusing Microsoft.AspNetCore.TestHost;"
        }
        Write-Text -Path (Join-Path $caseRoot "test/$projectName.$testSuffix/BehaviorTest.cs") -Content @"
using System.Threading.Tasks;
using Codebelt.Extensions.Xunit;
using Xunit;
$imports

namespace $projectName;

public class BehaviorTest : Test
{
    public BehaviorTest(ITestOutputHelper output) : base(output) { }

    [Fact]
    public $returnType PublicBehavior_ShouldWork_WithScaffoldTestStack()
    {
        $body
    }
}
"@
        Write-Text -Path (Join-Path $caseRoot 'MtpScaffold.slnx') -Content "<Solution><Project Path=`"$sourceProject`" /><Project Path=`"$testProject`" /></Solution>"
        Push-Location $caseRoot
        try {
            [void](Invoke-DotNet -Arguments @('build', 'MtpScaffold.slnx', '-c', 'Release', '-p:SkipSignAssembly=true', '--nologo'))
            $help = Invoke-DotNet -Arguments @('test', '--project', $testProject, '-c', 'Release', '--no-build', '--help')
            $reportOption = '--report-xunit-trx'
            foreach ($option in @($reportOption, '--coverlet', '--coverlet-output-format', '--hangdump', '--hangdump-timeout')) {
                if (-not $help.Contains($option)) { throw "$caseName runner is missing $option." }
            }
            $run = Invoke-DotNet -Arguments @('test', '--project', $testProject, '--framework', $case.Tfm, '-c', 'Release', '--no-build', '--results-directory', 'TestResults', '--', $reportOption, '--coverlet', '--coverlet-output-format', 'opencover')
            $trxFiles = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'TestResults') -Filter '*.trx' -Recurse)
            $coverageFiles = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'TestResults') -Filter '*.xml' -Recurse | Where-Object { $_.Length -gt 0 })
            if ($trxFiles.Count -eq 0) { throw "$caseName emitted no TRX.`n$run" }
            foreach ($file in $trxFiles) {
                [xml]$trx = [System.IO.File]::ReadAllText($file.FullName)
                $counts = $trx.TestRun.ResultSummary.Counters
                if ([int]$counts.total -ne 1 -or [int]$counts.passed -ne 1 -or [int]$counts.failed -ne 0) { throw "$caseName did not discover and pass its behavior test.`n$run" }
            }
            $covered = $false
            foreach ($file in $coverageFiles) {
                [xml]$coverage = [System.IO.File]::ReadAllText($file.FullName)
                if ($null -ne $coverage.SelectSingleNode("/CoverageSession/Modules/Module[ModuleName='$projectName']/Classes/Class/Methods/Method/SequencePoints/SequencePoint[number(@vc) > 0]")) { $covered = $true }
            }
            if (-not $covered) { throw "$caseName emitted no visited source sequence points in OpenCover.`n$run" }
            $assets = [System.IO.File]::ReadAllText((Join-Path $caseRoot (Join-Path (Split-Path $testProject) 'obj/project.assets.json')))
            foreach ($id in @('Codebelt.Extensions.Xunit.App/12.0.1', 'xunit.v3/4.0.1', 'Codebelt.Coverlet.MTP/10.1.0', 'Microsoft.Testing.Extensions.HangDump/2.4.1')) {
                if (-not $assets.Contains($id)) { throw "$caseName is missing restored dependency $id." }
            }
            $graph = $assets | ConvertFrom-Json
            if (@($graph.libraries.PSObject.Properties.Name | Where-Object { $_ -like 'Microsoft.Testing.Extensions.TrxReport/*' }).Count -ne 0) {
                throw "$caseName restored an out-of-scope TRX provider."
            }
            Write-Host "[PASS] ${caseName}: Release build, managed/public behavior, one passing test, xUnit TRX, visited OpenCover points, HangDump options and no separate TRX provider."
        } finally { Pop-Location }
    }
    Write-Host '[PASS] Scaffold MTP regressions passed.'
    $completed = $true
} finally {
    if ($completed -and (Test-Path $workspace)) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    } elseif (Test-Path $workspace) {
        Write-Host "Failed scaffold workspace retained for diagnosis: $workspace"
    }
}
