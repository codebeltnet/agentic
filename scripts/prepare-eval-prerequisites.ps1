function Invoke-EvalPreparationCommand {
    param([object]$Run, [string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 120)

    $command = Resolve-ExternalCommand -Name $Executable
    if ($null -eq $command) { throw "Infrastructure blocked: install '$Executable' or make it discoverable before preparing this evaluation." }
    $process = Invoke-RunnerProcess -FileName $command.FileName -ArgumentList (@($command.Prefix) + $Arguments) `
        -WorkingDirectory $Run.WorkingDirectoryPath -Environment (New-RunnerShellEnvironment -Run $Run) -TimeoutSeconds $TimeoutSeconds
    if ($process.ExitCode -ne 0) {
        $detail = ([string]$process.Stderr).Trim()
        $exit = if ($null -eq $process.ExitCode) { 'timeout or launch failure' } else { $process.ExitCode }
        throw "Infrastructure blocked: $Executable $($Arguments -join ' ') (exit $exit). $detail"
    }
    return ([string]$process.Stdout).Trim()
}

function Assert-EvalPublicHttpsSource {
    param([string]$Source)

    $uri = $null
    if (-not [uri]::TryCreate($Source, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw "Prerequisite sources must use HTTPS without embedded credentials, a query, or a fragment."
    }
}

function Initialize-EvalPrerequisites {
    param([object]$Requirements, [string]$RunRoot, [string]$CandidateName)

    if ($null -eq $Requirements) { return }
    $run = [pscustomobject]@{
        RunRoot = $RunRoot
        WorkingDirectoryPath = Join-Path $RunRoot 'repo'
        HomeDirectoryPath = Join-Path $RunRoot 'home'
        Contract = @{ prerequisites = $Requirements }
    }
    $dependencyRoot = Join-Path $RunRoot 'dependencies'
    $staged = [ordered]@{
        executables = @(Get-JsonProperty -Object $Requirements -Name 'executables' -Default @())
        probes = @(Get-JsonProperty -Object $Requirements -Name 'probes' -Default @())
        skills = @()
        downloads = @()
        dotnetTools = @()
        repository = $null
    }
    foreach ($name in @(Get-JsonProperty -Object $Requirements -Name 'skills' -Default @())) {
        if ($name -notmatch '^[a-z0-9][a-z0-9-]*$' -or $name -eq $CandidateName -or $name -eq 'tools') {
            throw "Invalid complementary skill '$name'."
        }
        $source = Join-Path (Get-RepoRoot) "skills/$name"
        if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) { throw "Complementary skill '$name' is missing from the source tree." }
        $destination = Join-Path $dependencyRoot $name
        [void](Copy-SkillTree -SkillDirectory $source -DestinationSkillRoot $destination)
        $staged.skills += [ordered]@{ path = "dependencies/$name"; sha256 = Get-TreeHash -Root $destination }
    }
    foreach ($asset in @(Get-JsonProperty -Object $Requirements -Name 'downloads' -Default @())) {
        Assert-EvalPublicHttpsSource -Source $asset.url
        if (-not (Test-Sha256 -Value $asset.sha256) -or $asset.file -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Downloads require a SHA-256 and a filename under dependencies/tools.' }
        $relative = "dependencies/tools/$($asset.file)"
        $destination = Join-Path $RunRoot $relative
        if (Test-Path -LiteralPath $destination) { throw "Duplicate prerequisite download '$relative'." }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $download = '$ErrorActionPreference="Stop"; Invoke-WebRequest -Uri ' + "'" + $asset.url.Replace("'", "''") + "' -OutFile '" + $destination.Replace("'", "''") + "'"
        [void](Invoke-EvalPreparationCommand -Run $run -Executable 'pwsh' -Arguments @('-NoProfile', '-NonInteractive', '-Command', $download))
        if ((Get-FileSha256 -Path $destination) -ne $asset.sha256) { throw "Infrastructure blocked: checksum mismatch for '$relative'." }
        $staged.downloads += [ordered]@{ path = $relative; sha256 = $asset.sha256.ToLowerInvariant() }
    }
    foreach ($tool in @(Get-JsonProperty -Object $Requirements -Name 'dotnetTools' -Default @())) {
        if ($tool.package -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $tool.version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$' -or $tool.executable -notin $staged.executables) {
            throw 'A .NET tool requires a package ID, an exact version, and a declared executable.'
        }
        $installed = Get-Command $tool.executable -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $supported = $false
        if ($null -ne $installed) {
            $versionCheck = Invoke-RunnerProcess -FileName $installed.Source -ArgumentList @('--version') -WorkingDirectory $run.WorkingDirectoryPath -Environment (New-RunnerShellEnvironment -Run $run) -TimeoutSeconds 15
            $supported = $versionCheck.ExitCode -eq 0 -and $versionCheck.Stdout -match ('^' + [regex]::Escape($tool.version) + '(?:\+|\s|$)')
        }
        if ($supported) {
            $staged.dotnetTools += [ordered]@{ executable = $tool.executable; source = 'installed'; requested_version = $tool.version }
            continue
        }
        $source = 'https://api.nuget.org/v3/index.json'
        $nugetConfig = Join-Path $run.HomeDirectoryPath 'tool-restore.config'
        Write-Utf8File -Path $nugetConfig -Content "<configuration><packageSources><clear/><add key='nuget.org' value='$source'/></packageSources></configuration>"
        [void](Invoke-EvalPreparationCommand -Run $run -Executable 'dotnet' -Arguments @('tool', 'install', $tool.package, '--version', $tool.version, '--tool-path', (Join-Path $run.HomeDirectoryPath 'tools'), '--configfile', $nugetConfig))
        $staged.dotnetTools += [ordered]@{ executable = $tool.executable; source = 'run-local'; requested_version = $tool.version }
    }
    $restore = Get-JsonProperty -Object $Requirements -Name 'restore'
    if ($null -ne $restore) {
        if ($restore.framework -notmatch '^net\d+\.\d+$' -or 'dotnet' -notin $staged.executables) { throw 'A restore prerequisite requires a target framework and the dotnet executable.' }
        $references = foreach ($package in @($restore.packages)) {
            if ($package.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $package.version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
                throw 'Restore prerequisite package IDs and versions must be exact.'
            }
            "<PackageReference Include='$($package.id)' Version='$($package.version)'/>"
        }
        $restoreRoot = Join-Path $run.HomeDirectoryPath 'restore-probe'
        New-Item -ItemType Directory -Path $restoreRoot -Force | Out-Null
        Write-Utf8File -Path (Join-Path $restoreRoot 'Probe.csproj') -Content "<Project Sdk='Microsoft.NET.Sdk'><PropertyGroup><TargetFramework>$($restore.framework)</TargetFramework></PropertyGroup><ItemGroup>$($references -join '')</ItemGroup></Project>"
        Write-Utf8File -Path (Join-Path $restoreRoot 'NuGet.Config') -Content "<configuration><packageSources><clear/><add key='nuget.org' value='https://api.nuget.org/v3/index.json'/></packageSources></configuration>"
        $staged.probes += [ordered]@{
            id = 'nuget-restore'
            command = @('dotnet', 'restore', '{run}/home/restore-probe/Probe.csproj', '--configfile', '{run}/home/restore-probe/NuGet.Config')
            timeoutMs = 45000
        }
    }
    $repository = Get-JsonProperty -Object $Requirements -Name 'repository'
    if ($null -ne $repository) {
        Assert-EvalPublicHttpsSource -Source $repository.url
        if ($repository.commit -notmatch '^[0-9a-f]{40}$' -or $repository.directory -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
            throw 'A repository prerequisite requires a full commit SHA and a directory name under repo/.'
        }
        $destination = Join-Path $run.WorkingDirectoryPath $repository.directory
        if (Test-Path -LiteralPath $destination) { throw "Repository prerequisite overlaps existing fixture '$($repository.directory)'." }
        [void](Invoke-EvalPreparationCommand -Run $run -Executable 'git' -Arguments @('init', '--template=', $destination))
        [void](Invoke-EvalPreparationCommand -Run $run -Executable 'git' -Arguments @('-C', $destination, '-c', 'credential.helper=', 'fetch', '--depth=1', '--no-tags', '--', $repository.url, $repository.commit))
        [void](Invoke-EvalPreparationCommand -Run $run -Executable 'git' -Arguments @('-C', $destination, '-c', 'core.autocrlf=false', 'checkout', '--detach', $repository.commit))
        $actual = Invoke-EvalPreparationCommand -Run $run -Executable 'git' -Arguments @('-C', $destination, 'rev-parse', '--verify', 'HEAD')
        if ($actual -cne $repository.commit) { throw "Repository prerequisite HEAD '$actual' differs from '$($repository.commit)'." }
        $staged.repository = [ordered]@{ path = "repo/$($repository.directory)"; commit = $actual }
        $staged.probes += [ordered]@{
            id = 'pinned-repository'
            command = @('git', '-C', "{run}/repo/$($repository.directory)", 'rev-parse', '--verify', 'HEAD')
            outputPattern = '^' + $actual + '\s*$'
        }
    }
    return $staged
}
