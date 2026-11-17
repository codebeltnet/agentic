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
#requires -Version 7.0
& {
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
        docker run --rm @dockerUser --env HOME=/tmp --env DOTNET_CLI_HOME=/tmp --mount "type=bind,source=$work,target=/work" --workdir /work/repo __IMAGE__ dotnet run --project $project --framework __FRAMEWORK__ -p:SkipSignAssembly=true -- --filter-method $test --report-xunit-xml --report-xunit-xml-filename result.xml --results-directory /work/results 2>&1 | Tee-Object -FilePath "$work/run.log"
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