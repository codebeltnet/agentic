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

Network access to GitHub and NuGet is required. The block downloads published csrun v0.2.1 and verifies its SHA-256 before executing it with your permissions. No Docker is needed.

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
# Downloads and executes the published csrun v0.2.1 asset with your permissions.
$engineDirectory = Join-Path ([IO.Path]::GetTempPath()) ('csrun-021-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $engineDirectory
$enginePath = Join-Path $engineDirectory 'csrun.ps1'
$process = $null
try {
    Invoke-WebRequest 'https://github.com/codebeltnet/csrun/releases/download/v0.2.1/csrun.ps1' -OutFile $enginePath
    $actualHash = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne '6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802') { throw "csrun asset checksum mismatch: $actualHash" }
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
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedEngineDirectory = [IO.Path]::GetFullPath($engineDirectory)
    if (-not $resolvedEngineDirectory.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if ($process -and $process.ExitCode -eq 0) { Remove-Item -LiteralPath $resolvedEngineDirectory -Recurse -Force }
}
if ($process.ExitCode -ne 0) { throw "csrun execution failed with exit code $($process.ExitCode). $diagnostics" }
if ($verifyTests) { Assert-CsrunTestOutput $output }
}

```

## Disposable Docker: PowerShell 7 and Docker with Linux containers

No host .NET SDK is needed. Network access is needed for the image and dependencies. Docker is not a security sandbox for untrusted code.

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
$global:LASTEXITCODE = -1
$output = (@($manifest | & docker run --rm -i 'codebeltnet/csrun:10') -join [Environment]::NewLine)
$dockerExitCode = $LASTEXITCODE
$process = [pscustomobject]@{ ExitCode = $dockerExitCode }
$diagnostics = ''
Write-Output $output
if ($process.ExitCode -ne 0) { throw "csrun execution failed with exit code $($process.ExitCode). $diagnostics" }
if ($verifyTests) { Assert-CsrunTestOutput $output }
}

```

The Native wrapper pins and verifies published csrun v0.2.1. The Docker convenience tag is mutable; pin an immutable image digest when available. See [presentation](presentation.md). The sample helper generates these blocks and the focused helper tests enforce parity with the maintained manifest.
