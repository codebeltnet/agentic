#requires -Version 7.0
param([string]$ValidatorPath = (Join-Path $PSScriptRoot 'docfx.cs'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
$helper = Join-Path $PSScriptRoot '../../../scripts/file-based-app.ps1'
if (Test-Path -LiteralPath $helper -PathType Leaf) {
    . $helper
} else {
    function Get-FileBasedAppCommand {
        param([string]$SourcePath)
        [pscustomobject]@{ Executable = 'dotnet'; ArgumentPrefix = @('run', '--file', $SourcePath, '--') }
    }
}
$validator = Get-FileBasedAppCommand -SourcePath $ValidatorPath
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('docfx-references-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Fixture([string]$Path, [string]$Content) {
    $target = Join-Path $workspace $Path
    $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    [IO.File]::WriteAllText($target, $Content, $utf8)
}
function Invoke-Check([string[]]$ExtraArgs = @()) {
    $output = & $validator.Executable @($validator.ArgumentPrefix + @('--repo-root', $workspace, '--json', '--quiet') + $ExtraArgs) 2>$null | Out-String
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin @(0, 1)) { throw "Validator failed with exit ${exitCode}: $output" }
    $output.Substring($output.IndexOf('{')) | ConvertFrom-Json
}
function Assert-NoSampleErrors($Report) {
    $failures = @($Report.errors | Where-Object { $_.code -like 'SAMPLE_*' -or $_.code -like 'EXAMPLE_*' })
    if ($failures.Count) { throw ($failures | ConvertTo-Json -Depth 5) }
}

# Curated reference destinations protect this authored example from path drift or unrelated links.
# This is offline golden-data verification, not a general URL or editorial-quality analyzer.
$revision = '84b13767cb9484f8f3a36a71875662edfdb3e511'
$usagePaths = @(
    'app/Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App/Program.cs'
    'test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/BootstrapperMinimalWorkerApplicationTestTest.cs'
    'test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj'
)
foreach ($entry in @(
    @{ File = 'contextual-source-references.md'; Ref = 'main'; Paths = $usagePaths }
    @{ File = 'one-shot-examples.md'; Ref = $revision; Paths = $usagePaths + 'src/Codebelt.Extensions.Xunit.Hosting/ManagedApplicationFixture.cs' }
)) {
    $content = Get-Content (Join-Path $PSScriptRoot "../references/$($entry.File)") -Raw
    $actual = @([regex]::Matches($content, '\]\((https://github\.com/[^)]+)\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $expected = @($entry.Paths | ForEach-Object { "https://github.com/codebeltnet/xunit/blob/$($entry.Ref)/$_" } | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) { throw "Curated source references changed in $($entry.File). Inspect targets and update the evidence deliberately." }
}

try {
    Write-Fixture 'src/Inventory.csproj' '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>'
    Write-Fixture 'src/StockQuantity.cs' @'
namespace Acme.Inventory;
public sealed record StockQuantity(int Value)
{
    public static StockQuantity Parse(string text) => new(int.Parse(text));
}
'@
    Write-Fixture 'samples/Quantity/Quantity.csproj' '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><ProjectReference Include="../../src/Inventory.csproj" /></ItemGroup></Project>'
    Write-Fixture 'samples/Quantity/Program.cs' @'
using System;
using Acme.Inventory;
Console.WriteLine(StockQuantity.Parse(args.Length == 0 ? "42" : args[0]).Value);
'@
    Write-Fixture '.docfx/docfx.json' @'
{"metadata":[{"src":[{"src":"../","files":["src/Inventory.csproj"]}],"dest":"api","properties":{"TargetFramework":"net10.0"}}],"build":{"content":[{"files":["*.md"],"exclude":["api/namespaces/**","api/types/**"]}],"overwrite":[{"files":["api/namespaces/**/*.md","api/types/**/*.md"]}],"dest":"_site"}}
'@
    Write-Fixture '.docfx/api/namespaces/Acme.Inventory.md' @'
---
uid: Acme.Inventory
summary: *content
---
Parse inventory quantities from text before reporting stock levels. Use `StockQuantity.Parse` to obtain the numeric value for a stock report.

Available on .NET 10.0.
'@
    $page = '.docfx/api/types/Acme.Inventory.StockQuantity.md'
    $header = "---`nuid: Acme.Inventory.StockQuantity`nexample:`n- *content`n---`n"
    $simple = @'
Parse a stock quantity from text and print its numeric value.

```csharp
// Program.cs
using System;
using Acme.Inventory;
Console.WriteLine(StockQuantity.Parse("42").Value);
```

Expected output: `42`.
'@
    Write-Fixture $page ($header + $simple)
    $plain = Invoke-Check
    Assert-NoSampleErrors $plain
    foreach ($process in @('dotnet', 'msbuild', 'docfx', 'gh')) {
        if ($plain.summary.processes.$process -ne 0) { throw "Fast reference checks started $process." }
    }

    $related = 'Related: [quantity implementation](../../../src/StockQuantity.cs).'
    $exploration = @'
### Further exploration

The maintained [quantity application](../../../samples/Quantity/Program.cs) accepts command-line input as well as the default value. Its [project](../../../samples/Quantity/Quantity.csproj) shows how a console consumer references the inventory library.
'@
    $runnable = $header + $simple + "`n`nRun the maintained application with ``dotnet run --project samples/Quantity/Quantity.csproj -- 42`` from the repository root using the .NET 10 SDK.`n`n$exploration`n`n$related`n"
    Write-Fixture $page $runnable
    $before = [IO.File]::ReadAllBytes((Join-Path $workspace $page))
    $compiled = Invoke-Check @('--validate-samples')
    Assert-NoSampleErrors $compiled
    if ($compiled.summary.samplesCompiled -ne 1) { throw 'Linked runnable sample did not compile.' }
    if ($compiled.summary.canClaimCompletion -or $compiled.summary.fullVerificationRan -or $compiled.summary.remainingGates.Count -eq 0) { throw 'Source links bypassed full DocFX verification.' }
    $output = & dotnet run --project (Join-Path $workspace 'samples/Quantity/Quantity.csproj') --disable-build-servers -- 42 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $output.Trim() -cne '42') { throw "Runnable exploration example failed: $output" }
    if ([Convert]::ToHexString($before) -cne [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $workspace $page)))) { throw 'Validation modified the sample or existing Related links.' }

    # An honest excerpt retains its maintained project context and limitations.
    $partial = @'
This non-standalone excerpt prints the parsed quantity inside the maintained console application. It omits imports and command-line setup, requires the .NET 10 SDK and referenced inventory project, and is compiled in that project context; no execution of this excerpt is claimed.

```csharp
// docfx-context: samples/Quantity/Quantity.csproj
// docfx-source: samples/Quantity/Program.cs
Console.WriteLine(StockQuantity.Parse(args.Length == 0 ? "42" : args[0]).Value);
```

Expected output with no arguments: `42`.
'@
    Write-Fixture $page ($header + $partial + "`n`n$exploration`n`n$related`n")
    $bound = Invoke-Check @('--validate-samples')
    Assert-NoSampleErrors $bound
    if ($bound.summary.samplesCompiled -ne 1) { throw 'Partial source context was not compiled.' }

    # Optional references never fulfill the C# obligation or hide a compiler failure.
    Write-Fixture $page ($header + "Read the maintained application to parse stock quantities.`n`n$exploration`n`n$related`n")
    $linksOnly = Invoke-Check
    if (-not @($linksOnly.errors | Where-Object code -eq 'EXAMPLE_MISSING').Count) { throw 'Links replaced required C#.' }
    Write-Fixture $page ($runnable.Replace('StockQuantity.Parse("42")', 'StockQuantity.Missing("42")'))
    $broken = Invoke-Check @('--validate-samples')
    if (-not @($broken.errors | Where-Object code -eq 'SAMPLE_COMPILE_FAILED').Count) { throw 'Links bypassed compilation.' }
    Write-Host 'DocFX contextual references passed: curated destinations, concise/runnable/partial examples, Related preservation, missing C#, compile failure and completion gates (offline links; editorial value requires review).'
}
finally {
    $resolved = [IO.Path]::GetFullPath($workspace)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('/','\') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

# The last native command is an expected compiler failure. Assertions determine suite success.
exit 0
