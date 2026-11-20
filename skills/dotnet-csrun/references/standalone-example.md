# Standalone host service resolution

This xUnit v3 test demonstrates registration and resolution in a host constructed by the test. It asserts the resolved identity value. It does not exercise a separate application's entry point; for that behavior use DocFX's repository-backed integration example instead.

The complete source is below. Both independent PowerShell blocks embed exactly this source and the same dependency pins; neither needs source files, scaffolding, a checkout, or the other block. Expected: 1 executed, 1 passed, 0 failed and 0 skipped. Source and canonical manifest are maintained in [standalone-host.json](../evals/files/standalone-host.json).

```csharp
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;

public sealed class HostTests
{
    [Fact]
    public void StandaloneHostResolvesRegisteredIdentity()
    {
        var builder = Host.CreateApplicationBuilder();
        builder.Services.AddSingleton(new WorkerIdentity("Inventory worker"));
        using var host = builder.Build();
        Assert.Equal("Inventory worker", host.Services.GetRequiredService<WorkerIdentity>().Name);
    }
}

public sealed record WorkerIdentity(string Name);
```

## Native: PowerShell 7 and a .NET 10-compatible SDK/runtime

The native block requires access to GitHub and NuGet. It downloads the latest stable release and checks the SHA-256 digest published by GitHub before executing the script with your permissions. [csrun source and releases](https://github.com/codebeltnet/csrun)

```powershell
& {
#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$manifest = @'
{
  "dependsOn": [
    "Codebelt.Extensions.Xunit.App@13.0.0",
    "xunit.v3@4.0.3"
  ],
  "framework": "net10.0",
  "mode": "test",
  "schemaVersion": 1,
  "source": "using Microsoft.Extensions.DependencyInjection;\nusing Microsoft.Extensions.Hosting;\nusing Xunit;\n\npublic sealed class HostTests\n{\n    [Fact]\n    public void StandaloneHostResolvesRegisteredIdentity()\n    {\n        var builder = Host.CreateApplicationBuilder();\n        builder.Services.AddSingleton(new WorkerIdentity(\"Inventory worker\"));\n        using var host = builder.Build();\n        Assert.Equal(\"Inventory worker\", host.Services.GetRequiredService<WorkerIdentity>().Name);\n    }\n}\n\npublic sealed record WorkerIdentity(string Name);"
}
'@
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$verifyTests = $true
function Assert-CsrunTestOutput([string] $Output) {
    $lines = @($Output -split '\r?\n')
    $headers = @($lines | Where-Object { $_ -match '^Test run summary: Passed! - .+\)$' })
    if ($headers.Count -ne 1) { throw 'Expected exactly one completed xUnit test summary.' }
    $headerIndex = [Array]::IndexOf($lines, $headers[0])
    $summaryLines = @($lines | Select-Object -Skip ($headerIndex + 1) -First 4)
    $counts = @{}
    foreach ($line in $summaryLines) {
        if ($line -match '^\s*(total|failed|succeeded|skipped):\s*(\d+)\s*$') { $counts[$Matches[1]] = [int]$Matches[2] }
    }
    if ($counts.Count -ne 4) { throw 'The xUnit test summary counts are incomplete or ambiguous.' }
    $failed = $counts.failed
    $passed = $counts.succeeded
    $skipped = $counts.skipped
    $total = $counts.total
    if ($total -lt 1 -or $passed -lt 1 -or $failed -ne 0 -or $skipped -ne 0 -or $passed -ne $total) {
        throw 'Tests must execute at least once, all pass, and none fail or skip.'
    }
}
# Downloads and executes the latest stable csrun release with your permissions.
# Source and release history: https://github.com/codebeltnet/csrun
$engineDirectory = Join-Path ([IO.Path]::GetTempPath()) ('csrun-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $engineDirectory
$enginePath = Join-Path $engineDirectory 'csrun.ps1'
$process = $null
try {
    $release = Invoke-RestMethod 'https://api.github.com/repos/codebeltnet/csrun/releases/latest'
    $assets = @($release.assets | Where-Object name -CEQ 'csrun.ps1')
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "csrun release $($release.tag_name) must publish one csrun.ps1 asset with a SHA-256 digest."
    }
    $asset = $assets[0]
    Invoke-WebRequest $asset.browser_download_url -OutFile $enginePath
    $actualHash = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
    if ("sha256:$actualHash" -ne $asset.digest) { throw "csrun asset checksum mismatch: $actualHash" }
$startInfo = [Diagnostics.ProcessStartInfo]::new('pwsh')
foreach ($argument in @('-NoProfile','-NonInteractive','-File')) { $startInfo.ArgumentList.Add($argument) }
$startInfo.ArgumentList.Add($enginePath)
$startInfo.ArgumentList.Add('-ManifestJson')
$startInfo.ArgumentList.Add($manifest)
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.UseShellExecute = $false
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) { throw 'Could not start csrun.' }
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$output = $stdoutTask.GetAwaiter().GetResult()
$diagnostics = $stderrTask.GetAwaiter().GetResult()
Write-Output $output
if ($diagnostics) { [Console]::Error.Write($diagnostics) }
} catch {
    [Console]::Error.WriteLine("csrun diagnostics retained in: $engineDirectory")
    throw
} finally {
    $resolvedTemp = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $resolvedEngineDirectory = [IO.Path]::GetFullPath($engineDirectory)
    if ([IO.Path]::GetDirectoryName($resolvedEngineDirectory) -ne $resolvedTemp -or
        [IO.Path]::GetFileName($resolvedEngineDirectory) -cnotmatch '^csrun-[a-f0-9]{32}$') { throw 'Unsafe cleanup path.' }
    if ($process -and $process.ExitCode -eq 0) { Remove-Item -LiteralPath $resolvedEngineDirectory -Recurse -Force }
}
if ($process.ExitCode -ne 0) { throw "csrun execution failed with exit code $($process.ExitCode). $diagnostics" }
if ($verifyTests) { Assert-CsrunTestOutput $output }
}
```

## Disposable Docker: PowerShell 7 and Docker with Linux containers

Docker provides the .NET SDK and PowerShell. This block fetches and verifies the latest csrun release using the same procedure as Native. The Docker wrapper streams the asset and manifest over stdin. The command needs network access to GitHub and NuGet.

```powershell
& {
#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$manifest = @'
{
  "dependsOn": [
    "Codebelt.Extensions.Xunit.App@13.0.0",
    "xunit.v3@4.0.3"
  ],
  "framework": "net10.0",
  "mode": "test",
  "schemaVersion": 1,
  "source": "using Microsoft.Extensions.DependencyInjection;\nusing Microsoft.Extensions.Hosting;\nusing Xunit;\n\npublic sealed class HostTests\n{\n    [Fact]\n    public void StandaloneHostResolvesRegisteredIdentity()\n    {\n        var builder = Host.CreateApplicationBuilder();\n        builder.Services.AddSingleton(new WorkerIdentity(\"Inventory worker\"));\n        using var host = builder.Build();\n        Assert.Equal(\"Inventory worker\", host.Services.GetRequiredService<WorkerIdentity>().Name);\n    }\n}\n\npublic sealed record WorkerIdentity(string Name);"
}
'@
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$verifyTests = $true
function Assert-CsrunTestOutput([string] $Output) {
    $lines = @($Output -split '\r?\n')
    $headers = @($lines | Where-Object { $_ -match '^Test run summary: Passed! - .+\)$' })
    if ($headers.Count -ne 1) { throw 'Expected exactly one completed xUnit test summary.' }
    $headerIndex = [Array]::IndexOf($lines, $headers[0])
    $summaryLines = @($lines | Select-Object -Skip ($headerIndex + 1) -First 4)
    $counts = @{}
    foreach ($line in $summaryLines) {
        if ($line -match '^\s*(total|failed|succeeded|skipped):\s*(\d+)\s*$') { $counts[$Matches[1]] = [int]$Matches[2] }
    }
    if ($counts.Count -ne 4) { throw 'The xUnit test summary counts are incomplete or ambiguous.' }
    $failed = $counts.failed
    $passed = $counts.succeeded
    $skipped = $counts.skipped
    $total = $counts.total
    if ($total -lt 1 -or $passed -lt 1 -or $failed -ne 0 -or $skipped -ne 0 -or $passed -ne $total) {
        throw 'Tests must execute at least once, all pass, and none fail or skip.'
    }
}
# Downloads and executes the latest stable csrun release with your permissions.
# Source and release history: https://github.com/codebeltnet/csrun
$engineDirectory = Join-Path ([IO.Path]::GetTempPath()) ('csrun-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $engineDirectory
$enginePath = Join-Path $engineDirectory 'csrun.ps1'
$process = $null
try {
    $release = Invoke-RestMethod 'https://api.github.com/repos/codebeltnet/csrun/releases/latest'
    $assets = @($release.assets | Where-Object name -CEQ 'csrun.ps1')
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "csrun release $($release.tag_name) must publish one csrun.ps1 asset with a SHA-256 digest."
    }
    $asset = $assets[0]
    Invoke-WebRequest $asset.browser_download_url -OutFile $enginePath
    $actualHash = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
    if ("sha256:$actualHash" -ne $asset.digest) { throw "csrun asset checksum mismatch: $actualHash" }
$enginePayload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($enginePath))
$containerInput = $enginePayload + "`n" + $manifest
$command = '
$ErrorActionPreference = "Stop"
$enginePath = Join-Path ([IO.Path]::GetTempPath()) ("csrun-release-" + [guid]::NewGuid().ToString("N") + ".ps1")
$engineBytes = [Convert]::FromBase64String([Console]::In.ReadLine())
[IO.File]::WriteAllBytes($enginePath, $engineBytes)
$manifest = [Console]::In.ReadToEnd()
& $enginePath -ManifestJson $manifest
exit $LASTEXITCODE
'
$output = (@($containerInput | & docker run --rm -i --entrypoint pwsh 'codebeltnet/csrun:10' -NoProfile -NonInteractive -Command $command) -join [Environment]::NewLine)
$process = [pscustomobject]@{ ExitCode = $LASTEXITCODE }
$diagnostics = ''
Write-Output $output
} catch {
    [Console]::Error.WriteLine("csrun diagnostics retained in: $engineDirectory")
    throw
} finally {
    $resolvedTemp = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $resolvedEngineDirectory = [IO.Path]::GetFullPath($engineDirectory)
    if ([IO.Path]::GetDirectoryName($resolvedEngineDirectory) -ne $resolvedTemp -or
        [IO.Path]::GetFileName($resolvedEngineDirectory) -cnotmatch '^csrun-[a-f0-9]{32}$') { throw 'Unsafe cleanup path.' }
    if ($process -and $process.ExitCode -eq 0) { Remove-Item -LiteralPath $resolvedEngineDirectory -Recurse -Force }
}
if ($process.ExitCode -ne 0) { throw "csrun execution failed with exit code $($process.ExitCode). $diagnostics" }
if ($verifyTests) { Assert-CsrunTestOutput $output }
}
```

The native wrapper resolves the latest stable release each time it runs. For reproducible runs, use a reviewed local engine via the sample helper's `-EnginePath` option and pin the Docker image by digest. The focused helper tests enforce parity with the maintained manifest. [Presentation guidance](presentation.md)
