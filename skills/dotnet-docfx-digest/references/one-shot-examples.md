# One-shot documentation examples

Lead with the developer task, the smallest informative C# example, expected outcome, reproduction and optional further exploration. Keep the API page understandable without execution or external source reading. Follow [contextual source references](contextual-source-references.md): explain what selected links teach beyond the example, even when execution succeeds, and omit references that add no useful depth. Put long execution blocks in an immediately linked conceptual page or disclosure when needed; no manual project assembly, helper installation, repository-layout knowledge or full project dumps.

## Paired execution delivery

Whenever DocFX Digest delivers a runnable example, deliver the complete Native and Docker options together unless one transport is genuinely unsupported. In a direct Codex response, include both complete, independently copyable and executable script blocks. Never extract only `## Native` when a corresponding `## Docker` section exists, make a reference file or generated asset path the only delivery, or require the developer to assemble a script from fragments. On a DocFX website, place both generated assets in one association with the same C# sample so its Native and Docker copy controls are available together. Keep verification independent: mark a transport `Verified` only after that transport passes; a successful Native run leaves unexecuted Docker `Unverified`, and vice versa. Mark genuine limitations `Unsupported` with the precise reason; do not infer one transport's status from the other.

## Select and verify

1. Prefer a complete standalone console program or genuine xUnit v3 test. Use `dotnet-csrun`'s existing manifest and `New-CsrunExecutionPair`; publish both independent PowerShell 7 native and disposable Docker blocks. Both decode to identical source and dependencies. Verify each available transport separately; if a supported transport was not run, label only that transport Unverified with its precise prerequisite. Use Unsupported only for a genuine source/platform incompatibility, with its reason.
2. For intrinsic integration/assembly identity, locate the maintained application/example and associated functional test, inspect project references, shared build settings, SDK, runner and package pins, infrastructure, signing and feeds. Select an exact test that proves the documented claim. Generate one block that downloads a commit-pinned repository snapshot to OS temp, builds/runs its original graph, verifies the intended test actually passed, and cleans up. No generated application, replacement test host, new test runner or multi-project manifest.
3. Use the runner's actual filtering/reporting conventions, inspected from its help and official documentation. MTP/xUnit v3 `--filter-method` is not VSTest `--filter FullyQualifiedName=...`. Report switches vary by version: xUnit v3 4.0.3 uses `--report-xunit-xml`. Require a fresh result report containing the exact intended test, positive executed/passed counts, no skips or runner errors, and matching process status. Exit zero or listing a discovered name alone never proves execution.
4. Verify the entire published block in a fresh PowerShell process, including download, quoting, result checks and cleanup. Offer an independent Docker block using a compatible official .NET SDK image when practical, with no host SDK dependency. Reuse `dotnet-test` for fixture/lifecycle guidance and `dotnet-remote-testing` for existing managed remote workloads; these blocks directly invoke the maintained native runner, not another test engine. The user-requested native path never requires Docker.
5. Record commit, command/block identity, SDK/runtime or image digest, package pins, exact test name, stdout/stderr, exit and counts outside tracked repositories. Preserve diagnostics on failure and clean downloaded sources/build output. Failed/unavailable verification remains Failed/Unverified; never retarget, change assertions or patch upstream source to obtain success.
6. If neither strategy faithfully reproduces the behavior, retain a concise illustration explicitly labelled non-standalone and unverified. Explain why, state prerequisites, and link directly to implementation, maintained example, test and project. Do not use a source-only fallback when a working one-shot test is available. This fallback does not suppress existing DocFX quality or compilation diagnostics; resolve them in maintained source context or report completion blocked.

## ManagedApplicationFixture: actual worker startup

Use `ManagedApplicationFixture<TEntryPoint>` with `ApplicationTest` to verify services registered by an application's real entry point. Here the application builds and runs the host and registers a marker; the test resolves that marker and asserts its value. It also asserts the Development environment and the availability of IHostApplicationLifetime. The fixture selects `typeof(TEntryPoint).Assembly`, so its application and executable xUnit test runner must retain separate assemblies. This is **repository-backed integration execution**, not an isolated csrun manifest.

The maintained test below belongs to the linked repository test project; it is not standalone source. Fixture injection and the base constructor retain the real application lifecycle. Run either complete block below to execute this exact test without assembling files:

```csharp
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;
using BootstrapperMinimalWorkerMarker = Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App.BootstrapperMinimalWorkerMarker;
using BootstrapperMinimalWorkerProgram = Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App.Program;

namespace Codebelt.Extensions.Xunit.Hosting;

public class BootstrapperMinimalWorkerApplicationTestTest : ApplicationTest<BootstrapperMinimalWorkerProgram, ManagedApplicationFixture<BootstrapperMinimalWorkerProgram>>
{
    public BootstrapperMinimalWorkerApplicationTestTest(ManagedApplicationFixture<BootstrapperMinimalWorkerProgram> hostFixture, ITestOutputHelper output) : base(hostFixture, output)
    {
    }

    [Fact]
    public void ShouldBootstrapMinimalWorkerProgram()
    {
        var marker = Host.Services.GetRequiredService<BootstrapperMinimalWorkerMarker>();

        Assert.Equal("Bootstrapper Minimal Worker", marker.Value);
        Assert.Equal("Development", Environment.EnvironmentName);
        Assert.NotNull(Host.Services.GetRequiredService<IHostApplicationLifetime>());
    }
}
```

Expected: exactly `ShouldBootstrapMinimalWorkerProgram` executes, with 1 passed, 0 failed and 0 skipped, followed by `Verified:`. These observations verify the application's registered marker value, Development environment and lifetime service through the fixture.

Both blocks independently download commit `84b13767cb9484f8f3a36a71875662edfdb3e511` and run its original test on net11.0. The snapshot pins xunit.v3 4.0.3 and Codebelt.Bootstrapper.Worker 5.2.3; shared props supply further dependencies. Network access to GitHub and configured NuGet feeds is required. Archive builds may warn that MinVer has no Git history; they do not reproduce release version metadata. SkipSignAssembly avoids requiring the publisher's signing key. Neither block edits the application or the assertions. A short temporary path avoids Windows path-length failures; an unusually long configured temp root can still require a shorter OS temp setting.

Failure throws and retains logs/results under the printed OS-temporary diagnostics path. Downloaded source and build output are removed in finally. Running repository build tasks and packages requires trust in that source and its dependencies; Docker mounts only the temporary workspace but is not a security sandbox.

## Native: PowerShell 7 and .NET 11 SDK

```powershell
#requires -Version 7.0
& {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    # Executes trusted repository build tasks and NuGet packages with your permissions.
    # Review the pinned source before running; a container is not a security sandbox.
    $null = Get-Command dotnet -ErrorAction Stop
    $work = Join-Path ([IO.Path]::GetTempPath()) ('dx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $work
    try {
        $commit = '84b13767cb9484f8f3a36a71875662edfdb3e511'
        Invoke-WebRequest "https://codeload.github.com/codebeltnet/xunit/zip/$commit" -OutFile "$work/source.zip"
        Expand-Archive -LiteralPath "$work/source.zip" -DestinationPath "$work/extracted"
        Move-Item -LiteralPath "$work/extracted/xunit-$commit" -Destination "$work/repo"
        $project = 'test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj'
        $test = 'Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorkerApplicationTestTest.ShouldBootstrapMinimalWorkerProgram'
        Push-Location "$work/repo"
        try {
            dotnet run --project $project --framework net11.0 -p:SkipSignAssembly=true -- --filter-method $test --report-xunit-xml --report-xunit-xml-filename result.xml --results-directory "$work/results" 2>&1 | Tee-Object -FilePath "$work/run.log"
        }
        finally { Pop-Location }
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Repository test failed with exit code $code. See $work/run.log" }
        # Require exactly the original test, executed and passing, with no runner errors.
        [xml] $report = Get-Content -LiteralPath "$work/results/result.xml" -Raw
        $tests = @($report.SelectNodes('/assemblies/assembly/collection/test'))
        $assemblies = @($report.SelectNodes('/assemblies/assembly'))
        if ($assemblies.Count -ne 1 -or $assemblies[0].total -ne '1' -or $assemblies[0].passed -ne '1' -or
            $assemblies[0].errors -ne '0' -or $tests.Count -ne 1 -or $tests[0].name -cne $test -or $tests[0].result -cne 'Pass') {
            throw "Expected exactly one passing $test; inspect $work/results/result.xml"
        }
        Write-Host "Verified: $test (1 executed, 1 passed)."
    }
    catch {
        # Preserve diagnostics outside the repository even though downloaded source is cleaned.
        $diagnostics = "$work-diagnostics"
        $null = New-Item -ItemType Directory -Path $diagnostics -Force
        foreach ($name in @('run.log', 'results')) {
            if (Test-Path -LiteralPath "$work/$name") { Copy-Item -LiteralPath "$work/$name" -Destination $diagnostics -Recurse }
        }
        Write-Warning "Execution not verified. Diagnostics: $diagnostics"
        throw
    }
    finally {
        $resolved = [IO.Path]::GetFullPath($work)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('/','\') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
```

## Docker: PowerShell 7 and Docker with Linux containers

No host .NET SDK is required. The official SDK image supplies it; first use pulls the image. On Linux, the container runs with the host UID and GID so build and test outputs remain removable during cleanup. Its home and .NET CLI state use container-local `/tmp`, which is writable by that identity.

```powershell
#requires -Version 7.0
& {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    # Executes trusted repository build tasks and NuGet packages with your permissions.
    # Review the pinned source before running; a container is not a security sandbox.
    $null = Get-Command docker -ErrorAction Stop
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker daemon unavailable.' }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('dx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $work
    try {
        $commit = '84b13767cb9484f8f3a36a71875662edfdb3e511'
        Invoke-WebRequest "https://codeload.github.com/codebeltnet/xunit/zip/$commit" -OutFile "$work/source.zip"
        Expand-Archive -LiteralPath "$work/source.zip" -DestinationPath "$work/extracted"
        Move-Item -LiteralPath "$work/extracted/xunit-$commit" -Destination "$work/repo"
        $project = 'test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj'
        $test = 'Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorkerApplicationTestTest.ShouldBootstrapMinimalWorkerProgram'
        $dockerUser = @()
        if ($IsLinux) {
            # Keep bind-mounted build output removable by the host user.
            $hostUid = id -u
            if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve host UID.' }
            $hostGid = id -g
            if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve host GID.' }
            $dockerUser = @('--user', "${hostUid}:${hostGid}")
        }
        docker run --rm @dockerUser --env HOME=/tmp --env DOTNET_CLI_HOME=/tmp --mount "type=bind,source=$work,target=/work" --workdir /work/repo mcr.microsoft.com/dotnet/sdk:11.0 dotnet run --project $project --framework net11.0 -p:SkipSignAssembly=true -- --filter-method $test --report-xunit-xml --report-xunit-xml-filename result.xml --results-directory /work/results 2>&1 | Tee-Object -FilePath "$work/run.log"
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Repository test failed with exit code $code. See $work/run.log" }
        # Require exactly the original test, executed and passing, with no runner errors.
        [xml] $report = Get-Content -LiteralPath "$work/results/result.xml" -Raw
        $tests = @($report.SelectNodes('/assemblies/assembly/collection/test'))
        $assemblies = @($report.SelectNodes('/assemblies/assembly'))
        if ($assemblies.Count -ne 1 -or $assemblies[0].total -ne '1' -or $assemblies[0].passed -ne '1' -or
            $assemblies[0].errors -ne '0' -or $tests.Count -ne 1 -or $tests[0].name -cne $test -or $tests[0].result -cne 'Pass') {
            throw "Expected exactly one passing $test; inspect $work/results/result.xml"
        }
        Write-Host "Verified: $test (1 executed, 1 passed)."
    }
    catch {
        # Preserve diagnostics outside the repository even though downloaded source is cleaned.
        $diagnostics = "$work-diagnostics"
        $null = New-Item -ItemType Directory -Path $diagnostics -Force
        foreach ($name in @('run.log', 'results')) {
            if (Test-Path -LiteralPath "$work/$name") { Copy-Item -LiteralPath "$work/$name" -Destination $diagnostics -Recurse }
        }
        Write-Warning "Execution not verified. Diagnostics: $diagnostics"
        throw
    }
    finally {
        $resolved = [IO.Path]::GetFullPath($work)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('/','\') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
```

## Further exploration

The [worker application entry point](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/app/Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App/Program.cs) shows the setup omitted from the concise test: host construction, marker and hosted-service registration, and `RunAsync`. The [corresponding functional test](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/BootstrapperMinimalWorkerApplicationTestTest.cs) places the displayed fixture usage and assertions in their maintained source context. To understand the separate application/test assemblies and supported frameworks, inspect the [referencing test project](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj) and its inherited build settings. For the lifecycle mechanism behind this usage, the [fixture implementation](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/ManagedApplicationFixture.cs) shows how it selects the entry-point assembly and connects the deferred host.

These links retain the exact revision executed by the blocks. For ongoing maintained branch exploration, see the [contextual reference example](contextual-source-references.md#principal-example-managedapplicationfixture); branch content can evolve independently of this verification. Following source links is optional and is not required to understand or run the example.

Maintainers generate both blocks with [integration-example.ps1](../scripts/integration-example.ps1). It only produces artifacts and introduces no runner or manifest. Focused tests compare these published blocks byte-for-byte and exercise failure checks with offline doubles; those checks alone do not verify the actual integration test.

## Observed verification, 2026-11-17

Before the UID/GID cleanup fix, both execution blocks were executed in fresh PowerShell processes from fresh archive downloads. Native Windows x64 used SDK 11.0.100/runtime 11.0.0. Linux Docker used official SDK 11.0.100/runtime 11.0.0, observed image digest `mcr.microsoft.com/dotnet/sdk@sha256:65f3c7c6a25a239ab3e6719f2896147e7b68242ff2d8818dd70498bde6ef8bea`. Each exited 0 after checking the XML report for exactly the named test passing: total 1, succeeded 1, failed/skipped 0. The image tag remains mutable; this is evidence of the tested image, not future tag contents.

A separate native negative run replaced only the filter with `DoesNotExist.NoSuchTest`: MTP reported zero tests and exit 8; the block threw (PowerShell exit 1), retained log/XML diagnostics outside the repository, and removed the downloaded workspace. The initial long-path launch failed before execution on Windows; the published blocks use a short temporary root and rename the archive root before building. No application source or assertion was changed.

The UID/GID fix was checked with a Linux Docker volume shared by SDK containers running as numeric UID:GID `1234:5678`: a console build ran successfully, and a separate non-root PowerShell process confirmed `bin` and `obj` ownership and removed the workspace. Both that build command and a full Docker-block retest remained running after printing their successful application/test output, even after explicit build-server shutdown, and were stopped. The full retest reported one passing integration test but ended with container exit 137; the wrapper retained diagnostics and removed its downloaded source. This confirms the focused ownership/cleanup smoke check, not a successful end-to-end rerun of the published block.

Focused deterministic checks: `pwsh -NoProfile -File skills/dotnet-docfx-digest/scripts/test-integration-example.ps1` checks published parity, PowerShell parsing and 28 offline cases covering exact passing test identity, wrong identity, zero tests, skips, runner errors, missing reports, missing dependencies, missing commands, unavailable Docker daemon, Linux UID/GID forwarding, writable container home settings and identity lookup failures. Both Linux and non-Linux Docker branches are exercised on every host. Offline doubles prove wrapper checks, not integration behavior. Existing `test-quality.ps1` retains source-backed compilation, architecture diagnostics and real application/standalone/middleware controls. These checks do not replace `agents.cs` or the build-backed DocFX completion gates when editing a target documentation repository. This change does not modify codebeltnet/xunit or claim the published API page was repaired.
