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

Network access to GitHub and NuGet is required. The block downloads and executes the publisher's engine with your permissions; review it before running. No Docker is needed.

```powershell
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
# Trust warning: downloads and executes publisher code with your permissions. Review before running.
# releases/latest is mutable; retain a reviewed release asset/hash for reproducibility.
$engine = Invoke-RestMethod 'https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1'
& ([scriptblock]::Create($engine)) -ManifestJson $manifest
$code = $LASTEXITCODE
if ($code -ne 0) { throw "csrun execution failed with exit code $code." }
```

## Disposable Docker: PowerShell 7 and Docker with Linux containers

No host .NET SDK is needed. Network access is needed for the image and dependencies. Docker is not a security sandbox for untrusted code.

```powershell
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
$manifest | docker run --rm -i 'codebeltnet/csrun:10'
$code = $LASTEXITCODE
if ($code -ne 0) { throw "csrun execution failed with exit code $code." }
```

The native latest-release URL and Docker SDK tag are mutable. Record the actual engine hash/image digest and environment when claiming verification; see [presentation](presentation.md). The sample helper generates these blocks and the focused helper tests enforce parity with the maintained manifest.
