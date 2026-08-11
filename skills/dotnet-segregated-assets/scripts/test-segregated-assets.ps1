#!/usr/bin/env pwsh
# Deterministic test harness for the dotnet-segregated-assets runner.
# Runs the bundled runner's built-in --self-test (hermetic: no dotnet publish, Docker, or network),
# then exercises the real inspect/plan/verify commands against synthetic on-disk fixtures so the
# end-to-end CLI surface is covered too. Everything is created and removed under the system temp
# directory so nothing leaks into the repository.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$runner = Join-Path $scriptRoot 'segregate-assets.cs'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Missing runner: $runner"
}

function Invoke-Runner {
    param([Parameter(Mandatory)][string[]]$RunnerArgs)
    $output = & dotnet run --file $runner -- @RunnerArgs 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
}

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Host "  [PASS] $Name" } else { $failures.Add($Name); Write-Host "  [FAIL] $Name" }
}

Write-Host 'dotnet-segregated-assets: built-in --self-test'
$selfTest = Invoke-Runner -RunnerArgs @('--self-test', '--json')
Assert-True 'built-in self-test exits 0' ($selfTest.ExitCode -eq 0)
Assert-True 'built-in self-test reports ok' ($selfTest.Output -match '"ok":\s*true')
Assert-True 'built-in self-test has zero failures' ($selfTest.Output -match '"failed":\s*0')

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("segregated-harness-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    # A conventional web app with a physical wwwroot and no CDN equivalent.
    $appDir = Join-Path $workspace 'Web'
    New-Item -ItemType Directory -Path (Join-Path $appDir 'wwwroot/css') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $appDir 'Web.csproj') -Encoding utf8 -Value @'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $appDir 'Program.cs') -Encoding utf8 -Value '// entrypoint'
    Set-Content -LiteralPath (Join-Path $appDir 'wwwroot/css/site.css') -Encoding utf8 -Value 'body{}'

    Write-Host 'inspect: conventional app'
    $inspect = Invoke-Runner -RunnerArgs @('inspect', '--repo-root', $workspace, '--json')
    Assert-True 'inspect exits 0' ($inspect.ExitCode -eq 0)
    Assert-True 'inspect classifies Simple' ($inspect.Output -match '"classification":\s*"Simple"')

    Write-Host 'plan: conventional app, no CDN equivalent'
    $plan = Invoke-Runner -RunnerArgs @('plan', '--repo-root', $workspace, '--json')
    Assert-True 'plan exits 0' ($plan.ExitCode -eq 0)
    Assert-True 'plan proposes publish-exclusion' ($plan.Output -match 'publish-exclusion')
    Assert-True 'plan names the PascalCase derived Dockerfile' ($plan.Output -match 'Assets\.Dockerfile')
    Assert-True 'plan names the canonical Compose file' ($plan.Output -match 'compose\.assets\.yml')
    Assert-True 'plan skips CDN equivalent by default' ($plan.Output -match '"cdn-equivalent"[\s\S]*?"status":\s*"skip"')

    # A Cuemon application with a previous custom URL abstraction must be reported as
    # a competing-abstraction migration; the runner only inspects and never rewrites it.
    $cuemonDir = Join-Path $workspace 'Cuemon'
    New-Item -ItemType Directory -Path (Join-Path $cuemonDir 'Views/Shared') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cuemonDir 'Cuemon.csproj') -Encoding utf8 -Value @'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
  <ItemGroup><PackageReference Include="Cuemon.AspNetCore.Razor.TagHelpers" Version="10.6.0" /></ItemGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $cuemonDir 'Program.cs') -Encoding utf8 -Value @'
using Cuemon.AspNetCore.Razor.TagHelpers;
builder.Services.Configure<AppTagHelperOptions>(builder.Configuration.GetSection("App"));
builder.Services.Configure<CdnTagHelperOptions>(builder.Configuration.GetSection("Cdn"));
builder.Services.AddAssemblyCacheBusting();
builder.Services.Configure<AppAssetOptions>(builder.Configuration.GetSection("Assets"));
'@
    Set-Content -LiteralPath (Join-Path $cuemonDir 'AppAssetOptions.cs') -Encoding utf8 -Value 'public sealed class AppAssetOptions { public string GetUrl(string path) => path; }'
    Set-Content -LiteralPath (Join-Path $cuemonDir 'Views/_ViewImports.cshtml') -Encoding utf8 -Value '@addTagHelper *, Cuemon.AspNetCore.Razor.TagHelpers'
    Set-Content -LiteralPath (Join-Path $cuemonDir 'Views/Shared/_Layout.cshtml') -Encoding utf8 -Value @'
@inject Microsoft.Extensions.Options.IOptions<AppAssetOptions> AppAssets
<app-link href="css/site.css" />
<cdn-script src="packages/htmx/2.0.4/htmx.min.js"></cdn-script>
@AppAssets.Value.GetUrl("~/css/site.css")
'@
    Write-Host 'inspect: Cuemon and competing custom asset abstraction'
    $cuemonInspect = Invoke-Runner -RunnerArgs @('inspect', '--repo-root', $cuemonDir, '--json')
    Assert-True 'Cuemon inspect exits 0' ($cuemonInspect.ExitCode -eq 0)
    Assert-True 'Cuemon package is detected' ($cuemonInspect.Output -match '"packageReference":\s*true')
    Assert-True 'Cuemon custom elements are detected' ($cuemonInspect.Output -match '"appLinkMarkup":\s*true')
    Assert-True 'Cuemon cache-busting registration is detected' ($cuemonInspect.Output -match '"cuemonCacheBusting":\s*true')
    Assert-True 'custom abstraction is detected' ($cuemonInspect.Output -match '"custom"[\s\S]*?"present":\s*true')
    Assert-True 'competing abstractions are reported' ($cuemonInspect.Output -match '"competingAbstractions":\s*true')
    Assert-True 'runner reports legacy attribute syntax without rewriting' ($cuemonInspect.Output -match '"legacyAttributeSyntax":\s*false')

    # An explicitly selected web project without wwwroot can still consume a shared/CDN asset root.
    $apiDir = Join-Path $workspace 'Api'
    New-Item -ItemType Directory -Path $apiDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $apiDir 'Api.csproj') -Encoding utf8 -Value @'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $apiDir 'Program.cs') -Encoding utf8 -Value '// entrypoint'
    Write-Host 'plan: no wwwroot with CDN equivalent'
    $cdnOnlyPlan = Invoke-Runner -RunnerArgs @('plan', '--repo-root', $workspace, '-p', 'Api/Api.csproj', '--cdn-equivalent', '--json')
    Assert-True 'CDN-only plan exits 0' ($cdnOnlyPlan.ExitCode -eq 0)
    Assert-True 'CDN-only plan creates CDN-equivalent work' ($cdnOnlyPlan.Output -match '"step":\s*"cdn-equivalent"[\s\S]*?"status":\s*"create"')
    Assert-True 'CDN-only plan is not blocked' ($cdnOnlyPlan.Output -notmatch '"status":\s*"blocked"')

    # verify against a fabricated publish output that leaked app assets => must fail.
    $leakedPub = Join-Path $workspace 'pub-leak'
    New-Item -ItemType Directory -Path (Join-Path $leakedPub 'wwwroot/css') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $leakedPub 'wwwroot/css/site.css') -Encoding utf8 -Value 'body{}'
    Write-Host 'verify: leaked publish output'
    $verifyLeak = Invoke-Runner -RunnerArgs @('verify', '--repo-root', $workspace, '-p', 'Web/Web.csproj', '--publish-dir', $leakedPub, '--json')
    Assert-True 'verify detects leak (exit 66)' ($verifyLeak.ExitCode -eq 66)
    Assert-True 'verify reports leaked app asset' ($verifyLeak.Output -match 'css/site\.css')

    # verify against a clean publish output (app assets absent, shared _content preserved) => passes.
    $cleanPub = Join-Path $workspace 'pub-clean'
    New-Item -ItemType Directory -Path (Join-Path $cleanPub 'wwwroot/_content/Lib') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanPub 'wwwroot/_content/Lib/shared.css') -Encoding utf8 -Value '/*shared*/'
    Write-Host 'verify: clean publish output'
    $verifyClean = Invoke-Runner -RunnerArgs @('verify', '--repo-root', $workspace, '-p', 'Web/Web.csproj', '--publish-dir', $cleanPub, '--json')
    Assert-True 'verify passes on clean publish (exit 0)' ($verifyClean.ExitCode -eq 0)
    Assert-True 'verify preserves shared _content asset' ($verifyClean.Output -match '_content/Lib/shared\.css')

    Write-Host 'verify: incomplete local topology'
    $verifyIncompleteLocal = Invoke-Runner -RunnerArgs @('verify', '--repo-root', $workspace, '-p', 'Web/Web.csproj', '--publish-dir', $cleanPub, '--check-local', '--json')
    Assert-True 'verify rejects missing local topology (exit 66)' ($verifyIncompleteLocal.ExitCode -eq 66)
    Assert-True 'verify reports incomplete local topology as not ok' ($verifyIncompleteLocal.Output -match '"ok":\s*false')
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    Write-Error ("dotnet-segregated-assets harness FAILED: {0} check(s) failed:`n  - {1}" -f $failures.Count, ($failures -join "`n  - "))
    exit 1
}

Write-Host 'dotnet-segregated-assets runner harness: PASS'
