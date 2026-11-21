#requires -Version 7.0
# Artifact generation only: no downloads, builds or test execution when dot-sourced.
function New-RepositoryExamplePair {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][string] $Test,
        [Parameter(Mandatory)][string] $Framework,
        [Parameter(Mandatory)][string] $Image
    )
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Commit -notmatch '^[a-fA-F0-9]{40}$' -or
        $Project -notmatch '^[A-Za-z0-9_./-]+\.csproj$' -or $Project.Split('/') -contains '..' -or $Project.StartsWith('/') -or
        $Test -notmatch '^[A-Za-z0-9_.+]+$' -or $Framework -notmatch '^net\d+\.\d+$' -or
        $Image -notmatch '^mcr\.microsoft\.com/dotnet/sdk:[A-Za-z0-9_.-]+$') {
        throw 'Expected a pinned GitHub repository, relative project, exact xUnit method, TFM and official SDK image.'
    }
    $template = @'
& {
#requires -Version 7.0
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    # Executes trusted repository build tasks and NuGet packages with your permissions.
    # Review the pinned source before running; a container is not a security sandbox.
    __PREREQUISITE__
    $work = Join-Path ([IO.Path]::GetTempPath()) ('dx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $work
    try {
        $commit = '__COMMIT__'
        Invoke-WebRequest "https://codeload.github.com/__REPOSITORY__/zip/$commit" -OutFile "$work/source.zip"
        Expand-Archive -LiteralPath "$work/source.zip" -DestinationPath "$work/extracted"
        Move-Item -LiteralPath "$work/extracted/__ARCHIVE__-$commit" -Destination "$work/repo"
        $project = '__PROJECT__'
        $test = '__TEST__'
        __EXECUTE__
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
'@
    $native = @'
Push-Location "$work/repo"
        try {
            dotnet run --project $project --framework __FRAMEWORK__ -p:SkipSignAssembly=true -- --filter-method $test --report-xunit-xml --report-xunit-xml-filename result.xml --results-directory "$work/results" 2>&1 | Tee-Object -FilePath "$work/run.log"
        }
        finally { Pop-Location }
'@
    $docker = @'
$dockerUser = @()
        if ($IsLinux) {
            # Keep bind-mounted build output removable by the host user.
            $hostUid = id -u
            if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve host UID.' }
            $hostGid = id -g
            if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve host GID.' }
            $dockerUser = @('--user', "${hostUid}:${hostGid}")
        }
        # Let Docker's init reap orphaned build processes and keep build servers disposable.
        docker run --rm --init @dockerUser --env HOME=/tmp --env DOTNET_CLI_HOME=/tmp --env MSBUILDDISABLENODEREUSE=1 --mount "type=bind,source=$work,target=/work" --workdir /work/repo __IMAGE__ dotnet run --disable-build-servers --project $project --framework __FRAMEWORK__ -p:SkipSignAssembly=true -- --filter-method $test --report-xunit-xml --report-xunit-xml-filename result.xml --results-directory /work/results 2>&1 | Tee-Object -FilePath "$work/run.log"
'@
    $template = $template.Replace('__COMMIT__', $Commit).Replace('__REPOSITORY__', $Repository).Replace('__ARCHIVE__', $Repository.Split('/')[1]).Replace('__PROJECT__', $Project).Replace('__TEST__', $Test)
    $native = $native.Replace('__FRAMEWORK__', $Framework)
    $docker = $docker.Replace('__FRAMEWORK__', $Framework).Replace('__IMAGE__', $Image)
    [pscustomobject]@{
        Native = $template.Replace('__PREREQUISITE__', "`$null = Get-Command dotnet -ErrorAction Stop").Replace('__EXECUTE__', $native)
        Docker = $template.Replace('__PREREQUISITE__', "`$null = Get-Command docker -ErrorAction Stop`n    docker info *> `$null`n    if (`$LASTEXITCODE -ne 0) { throw 'Docker daemon unavailable.' }").Replace('__EXECUTE__', $docker)
    }
}

# Compatibility wrapper for the already published example.
function New-ManagedApplicationExamplePair {
    New-RepositoryExamplePair -Repository 'codebeltnet/xunit' -Commit '84b13767cb9484f8f3a36a71875662edfdb3e511' -Project 'test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj' -Test 'Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorkerApplicationTestTest.ShouldBootstrapMinimalWorkerProgram' -Framework net11.0 -Image mcr.microsoft.com/dotnet/sdk:11.0
}

function New-HostExamplePair {
    param(
        [Parameter(Mandatory)][string] $Source,
        [string] $Framework = 'net10.0',
        [string] $Sdk = 'Microsoft.NET.Sdk.Web',
        [string[]] $DependsOn = @(),
        [string] $ProbePath = '/',
        [string] $ProbeMethod = 'GET',
        [int] $TimeoutSeconds = 15,
        [int] $ExpectedStatusCode = 0,
        [string] $ExpectedBodyContains = '',
        [int] $StartupDelayMs = 1000,
        [string] $Image = 'codebeltnet/csrun:10'
    )
    if ($Framework -notmatch '^net\d+\.\d+$') { throw "Invalid host framework: $Framework" }
    if ($Sdk -notmatch '^[A-Za-z0-9_.]+$') { throw "Invalid host SDK: $Sdk" }
    if ($ProbeMethod -notmatch '^(GET|HEAD|POST|PUT|DELETE|OPTIONS|PATCH)$') { throw "Invalid host probeMethod: $ProbeMethod" }
    if ($TimeoutSeconds -lt 3 -or $TimeoutSeconds -gt 300) { throw "Host timeoutSeconds must be between 3 and 300." }
    $cleanDependsOn = @($DependsOn | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    foreach ($pin in $cleanDependsOn) {
        if ($pin -notmatch '^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$') { throw "Invalid host dependsOn pin: $pin" }
    }
    $pkgLines = @($cleanDependsOn | ForEach-Object {
        $parts = $_ -split '@', 2
        "    <PackageReference Include=""$($parts[0])"" Version=""$($parts[1])"" />"
    })
    $itemGroup = if ($pkgLines.Count) { "`n  <ItemGroup>`n" + ($pkgLines -join "`n") + "`n  </ItemGroup>" } else { '' }
    $csproj = "<Project Sdk=""$Sdk"">`n  <PropertyGroup>`n    <OutputType>Exe</OutputType>`n    <TargetFramework>$Framework</TargetFramework>`n    <ImplicitUsings>enable</ImplicitUsings>`n    <Nullable>enable</Nullable>`n  </PropertyGroup>$itemGroup`n</Project>`n"
    $payloadJson = ([ordered]@{
        csproj = $csproj
        source = $Source.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
        probePath = $ProbePath
        probeMethod = $ProbeMethod
        timeoutSeconds = $TimeoutSeconds
        expectedStatusCode = $ExpectedStatusCode
        expectedBodyContains = $ExpectedBodyContains
        startupDelayMs = $StartupDelayMs
    } | ConvertTo-Json -Depth 10).Replace("`r`n", "`n")
    $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $runnerBody = @'
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadB64)) | ConvertFrom-Json
$work = Join-Path ([IO.Path]::GetTempPath()) ('dx-host-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work
$buildProcess = $null
$hostProcess = $null
$deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$payload.timeoutSeconds)
try {
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $csprojPath = Join-Path $work 'HostSample.csproj'
    [IO.File]::WriteAllText($csprojPath, $payload.csproj, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $work 'Program.cs'), $payload.source, $utf8NoBom)
    $buildStartInfo = [Diagnostics.ProcessStartInfo]::new('dotnet')
    foreach ($a in @('build', $csprojPath, '-c', 'Release', '--nologo', '-v', 'quiet')) { $buildStartInfo.ArgumentList.Add($a) }
    $buildStartInfo.WorkingDirectory = $work
    $buildStartInfo.RedirectStandardOutput = $true
    $buildStartInfo.RedirectStandardError = $true
    $buildStartInfo.UseShellExecute = $false
    $buildProcess = [Diagnostics.Process]::new()
    $buildProcess.StartInfo = $buildStartInfo
    if (-not $buildProcess.Start()) { throw 'Could not start host sample build.' }
    $buildStdoutTask = $buildProcess.StandardOutput.ReadToEndAsync()
    $buildStderrTask = $buildProcess.StandardError.ReadToEndAsync()
    $buildRemainingMs = [int][Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
    if ($buildRemainingMs -le 0 -or -not $buildProcess.WaitForExit($buildRemainingMs)) {
        try { if (-not $buildProcess.HasExited) { $buildProcess.Kill($true) } } catch {}
        $null = $buildProcess.WaitForExit(5000)
        throw "Host sample build timed out after $($payload.timeoutSeconds)s."
    }
    $buildOut = $buildStdoutTask.GetAwaiter().GetResult()
    $buildErr = $buildStderrTask.GetAwaiter().GetResult()
    if ($buildProcess.ExitCode -ne 0) {
        $buildText = ($buildOut + "`n" + $buildErr).Trim()
        throw "Host sample build failed (exit $($buildProcess.ExitCode)): $buildText"
    }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "Host sample timed out after $($payload.timeoutSeconds)s before starting host."
    }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $baseUrl = "http://127.0.0.1:$port"
    $startInfo = [Diagnostics.ProcessStartInfo]::new('dotnet')
    foreach ($a in @('run','--no-build','-c','Release','--project',$csprojPath)) { $startInfo.ArgumentList.Add($a) }
    $startInfo.Environment['ASPNETCORE_URLS'] = $baseUrl
    $startInfo.Environment['DOTNET_ENVIRONMENT'] = 'Development'
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $hostProcess = [Diagnostics.Process]::new()
    $hostProcess.StartInfo = $startInfo
    if (-not $hostProcess.Start()) { throw 'Could not start host process.' }
    $stdoutTask = $hostProcess.StandardOutput.ReadToEndAsync()
    $stderrTask = $hostProcess.StandardError.ReadToEndAsync()
    if ($payload.probePath) {
        $probeUrl = $baseUrl + $payload.probePath
        $probed = $false
        $lastError = ''
        $httpClient = [Net.Http.HttpClient]::new()
        $httpClient.Timeout = [TimeSpan]::FromSeconds(3)
        try {
            while ([DateTimeOffset]::UtcNow -lt $deadline) {
                if ($hostProcess.HasExited) {
                    $stdOut = $stdoutTask.GetAwaiter().GetResult()
                    $errOut = $stderrTask.GetAwaiter().GetResult()
                    throw "Host exited before probe succeeded (exit $($hostProcess.ExitCode)). $stdOut $errOut"
                }
                $probeRemainingMs = [int][Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
                if ($probeRemainingMs -le 0) { break }
                $cts = [Threading.CancellationTokenSource]::new([Math]::Min(3000, $probeRemainingMs))
                try {
                    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new([string]$payload.probeMethod), $probeUrl)
                    $resp = $httpClient.Send($req, $cts.Token)
                    $statusCode = [int]$resp.StatusCode
                    $body = $resp.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult()
                    if ([int]$payload.expectedStatusCode -gt 0 -and $statusCode -ne [int]$payload.expectedStatusCode) {
                        throw "Expected HTTP $($payload.expectedStatusCode) from $($payload.probePath), got HTTP $statusCode. Body: $body"
                    }
                    if ($payload.expectedBodyContains -and -not $body.Contains([string]$payload.expectedBodyContains, [StringComparison]::Ordinal)) {
                        throw "Expected response body to contain '$($payload.expectedBodyContains)'. Body: $body"
                    }
                    Write-Output "HTTP $statusCode $($payload.probeMethod) $($payload.probePath)"
                    if ($body) { Write-Output $body }
                    $probed = $true
                    break
                } catch [Net.Http.HttpRequestException] {
                    $lastError = $_.Exception.Message
                    Start-Sleep -Milliseconds 200
                } catch [Threading.Tasks.TaskCanceledException] {
                    $lastError = $_.Exception.Message
                    Start-Sleep -Milliseconds 200
                } catch [OperationCanceledException] {
                    $lastError = $_.Exception.Message
                    Start-Sleep -Milliseconds 200
                } finally {
                    $cts.Dispose()
                }
            }
        } finally {
            $httpClient.Dispose()
        }
        if (-not $probed) { throw "Host probe '$($payload.probeMethod) $($payload.probePath)' timed out after $($payload.timeoutSeconds)s. Last error: $lastError" }
    } else {
        $delayRemainingMs = [int][Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
        $sleepMs = [Math]::Min([int]$payload.startupDelayMs, [Math]::Max($delayRemainingMs, 0))
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        if ($hostProcess.HasExited -and $hostProcess.ExitCode -ne 0) {
            $stdOut = $stdoutTask.GetAwaiter().GetResult()
            $errOut = $stderrTask.GetAwaiter().GetResult()
            throw "Host exited with code $($hostProcess.ExitCode). $stdOut $errOut"
        }
        Write-Output "Host started cleanly and ran for $($payload.startupDelayMs)ms."
    }
} finally {
    if ($buildProcess) {
        try {
            if (-not $buildProcess.HasExited) { $buildProcess.Kill($true) }
            $null = $buildProcess.WaitForExit(5000)
        } catch {}
        $buildProcess.Dispose()
    }
    if ($hostProcess) {
        try {
            if (-not $hostProcess.HasExited) { $hostProcess.Kill($true) }
            $null = $hostProcess.WaitForExit(5000)
        } catch {}
        $hostProcess.Dispose()
    }
    $resolved = [IO.Path]::GetFullPath($work)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('/','\') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
'@
    $runnerNorm = $runnerBody.Replace("`r`n", "`n").TrimEnd()
    $native = "& {`n#requires -Version 7.0`n`$ErrorActionPreference = 'Stop'`n`$PSNativeCommandUseErrorActionPreference = `$false`n`$OutputEncoding = [Text.UTF8Encoding]::new(`$false)`n[Console]::OutputEncoding = `$OutputEncoding`n`$null = Get-Command dotnet -ErrorAction Stop`n`$payloadB64 = '$payloadB64'`n" + $runnerNorm + "`n}`n"
    $runnerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("`$ErrorActionPreference = 'Stop'`n`$PSNativeCommandUseErrorActionPreference = `$false`n`$payloadB64 = '$payloadB64'`n" + $runnerNorm + "`n"))
    $quotedImage = "'" + $Image.Replace("'", "''") + "'"
    $docker = @"
& {
#requires -Version 7.0
    `$ErrorActionPreference = 'Stop'
    `$PSNativeCommandUseErrorActionPreference = `$false
    `$OutputEncoding = [Text.UTF8Encoding]::new(`$false)
    [Console]::OutputEncoding = `$OutputEncoding
    `$null = Get-Command docker -ErrorAction Stop
    docker info *> `$null
    if (`$LASTEXITCODE -ne 0) { throw 'Docker daemon unavailable.' }
    `$runnerB64 = '$runnerB64'
    `$command = '`$ErrorActionPreference = "Stop"; `$s = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd())); `$p = Join-Path ([IO.Path]::GetTempPath()) ("dx-host-runner-" + [guid]::NewGuid().ToString("N") + ".ps1"); [IO.File]::WriteAllText(`$p, `$s); try { & pwsh -NoProfile -NonInteractive -File `$p; exit `$LASTEXITCODE } finally { Remove-Item -LiteralPath `$p -Force -ErrorAction SilentlyContinue }'
    `$output = (@(`$runnerB64 | & docker run --rm -i --init --entrypoint pwsh $quotedImage -NoProfile -NonInteractive -Command `$command) -join [Environment]::NewLine)
    `$code = `$LASTEXITCODE
    Write-Output `$output
    if (`$code -ne 0) { throw "Host execution failed in Docker with exit code `$code." }
}
"@ + "`n"
    [pscustomobject]@{
        Native = $native
        Docker = $docker
    }
}
