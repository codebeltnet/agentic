Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PackageTreeIntegrity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Force | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $file.FullName).Replace('\', '/')
        $entries.Add("$relative`:$(Get-Sha256HexFromFile -Path $file.FullName)")
    }
    $joined = [string]::Join("`n", @($entries | Sort-Object))
    return [pscustomobject]@{
        Path = $resolvedRoot
        FileCount = $entries.Count
        Sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($joined))
    }
}

function Assert-PackageRunnerToolsIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $declared = Get-JsonProperty -Object $Manifest -Name 'runner_tools_integrity' -Default $null
    if ($null -eq $declared -or [string](Get-JsonProperty -Object $declared -Name 'schema' -Default '') -ne 'codebeltnet/agentic/package-tree-integrity/1') {
        throw 'manifest.json does not declare the versioned package-local Eval Runner tool integrity record.'
    }
    $runnerToolsRelative = [string](Get-JsonProperty -Object $Manifest -Name 'runner_tools' -Default '')
    $declaredPath = [string](Get-JsonProperty -Object $declared -Name 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace($runnerToolsRelative) -or $declaredPath -ne $runnerToolsRelative) {
        throw 'manifest.runner_tools_integrity.path does not match manifest.runner_tools.'
    }
    $runnerToolsPath = Resolve-ContainedPath -BasePath $IterationDirectory -RelativePath $runnerToolsRelative -FieldName 'runner_tools' -Kind Directory
    $actual = Get-PackageTreeIntegrity -Root $runnerToolsPath
    $declaredHash = [string](Get-JsonProperty -Object $declared -Name 'sha256' -Default '')
    $declaredCount = [int](Get-JsonProperty -Object $declared -Name 'file_count' -Default -1)
    if ($declaredHash -ne [string]$actual.Sha256 -or $declaredCount -ne [int]$actual.FileCount) {
        throw "Package-local Eval Runner tools changed after preparation (expected hash $declaredHash/$declaredCount files, found $($actual.Sha256)/$($actual.FileCount) files). Requires a fresh package."
    }
    return $actual
}

function Resolve-PackageRunnerToolsDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $runnerToolsRelative = [string](Get-JsonProperty -Object $Manifest -Name 'runner_tools' -Default '')
    if ([string]::IsNullOrWhiteSpace($runnerToolsRelative)) {
        throw 'manifest.json does not declare runner_tools.'
    }
    return Resolve-ContainedPath -BasePath $IterationDirectory -RelativePath $runnerToolsRelative -FieldName 'runner_tools' -Kind Directory
}

function Get-PackageRunnerDescriptorFromPath {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerName,
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$RunnerToolsDirectory
    )

    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $descriptorProcess = Invoke-RunnerProcess -FileName $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $RunnerPath, 'describe') -WorkingDirectory $RunnerToolsDirectory -Environment (New-RunnerProbeEnvironment) -TimeoutSeconds 30
    if ($descriptorProcess.TimedOut) {
        throw "Package-local runner '$RunnerName' descriptor exceeded the 30-second model-free probe timeout."
    }
    if ($descriptorProcess.ExitCode -ne 0) {
        throw "Package-local runner '$RunnerName' descriptor failed: $([string]::Join(' ', @($descriptorProcess.Stdout, $descriptorProcess.Stderr)))"
    }

    try {
        $descriptor = [string]$descriptorProcess.Stdout | ConvertFrom-Json
        [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    } catch {
        throw "Package-local runner '$RunnerName' returned an invalid descriptor: $($_.Exception.Message)"
    }
    if ([string]$descriptor.name -ne $RunnerName) {
        throw "Package-local runner descriptor name '$($descriptor.name)' does not match selected runner '$RunnerName'."
    }
    return $descriptor
}

function Assert-PackageRunnerIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [string]$ExpectedRunner = ''
    )

    $selection = Get-JsonProperty -Object $Manifest -Name 'execution_selection' -Default $null
    $manifestRunner = [string](Get-JsonProperty -Object $selection -Name 'runner' -Default '')
    if ([string]::IsNullOrWhiteSpace($manifestRunner)) {
        throw 'manifest.execution_selection.runner must identify the selected Eval Runner.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunner) -and $manifestRunner -ne $ExpectedRunner) {
        throw "manifest.execution_selection.runner '$manifestRunner' does not match the requested runner '$ExpectedRunner'."
    }

    $profileRelative = [string](Get-JsonProperty -Object $Manifest -Name 'execution_profile' -Default '')
    if ([string]::IsNullOrWhiteSpace($profileRelative)) {
        throw 'manifest.json must declare execution_profile.'
    }
    $profilePath = Resolve-ContainedPath -BasePath $IterationDirectory -RelativePath $profileRelative -FieldName 'execution_profile' -Kind File
    $profile = Resolve-ExecutionProfile -ProfilePath $profilePath
    if ([string]$profile.Runner -ne $manifestRunner) {
        throw "execution-profile.json runner '$($profile.Runner)' does not match manifest.execution_selection.runner '$manifestRunner'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunner) -and [string]$profile.Runner -ne $ExpectedRunner) {
        throw "execution-profile.json runner '$($profile.Runner)' does not match the requested runner '$ExpectedRunner'."
    }

    $runnerToolsDirectory = Resolve-PackageRunnerToolsDirectory -IterationDirectory $IterationDirectory -Manifest $Manifest
    $resolverPath = Join-Path $runnerToolsDirectory 'resolve-runner.ps1'
    if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
        throw "Package-local Eval Runner resolver is missing at '$resolverPath'."
    }
    $resolutionOutput = & pwsh -NoProfile -NonInteractive -File $resolverPath ([string]$profile.Runner) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Selected runner '$($profile.Runner)' could not be resolved package-locally: $([string]::Join(' ', @($resolutionOutput)))"
    }
    $resolutionText = [string]::Join([Environment]::NewLine, @($resolutionOutput | ForEach-Object { [string]$_ }))
    try {
        $resolution = $resolutionText | ConvertFrom-Json
    } catch {
        throw "Selected runner '$($profile.Runner)' resolver returned invalid JSON: $($_.Exception.Message)"
    }
    if ([string](Get-JsonProperty -Object $resolution -Name 'runner' -Default '') -ne [string]$profile.Runner) {
        throw "Package-local runner resolver returned '$($resolution.runner)' for selected runner '$($profile.Runner)'."
    }
    $runnerRelative = [string](Get-JsonProperty -Object $resolution -Name 'path' -Default '')
    $runnerPath = Resolve-ContainedPath -BasePath $runnerToolsDirectory -RelativePath $runnerRelative -FieldName 'resolved runner path' -Kind File
    $expectedRunnerPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $runnerToolsDirectory ([string]$profile.Runner)) 'runner.ps1'))
    $pathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($runnerPath), $expectedRunnerPath, $pathComparison)) {
        throw "Package-local runner resolver path '$runnerRelative' does not resolve to '$($profile.Runner)/runner.ps1'."
    }

    $descriptor = Get-PackageRunnerDescriptorFromPath -RunnerName ([string]$profile.Runner) -RunnerPath $runnerPath -RunnerToolsDirectory $runnerToolsDirectory
    return [pscustomobject]@{
        Runner = [string]$profile.Runner
        Profile = $profile
        ManifestRunner = $manifestRunner
        RunnerToolsDirectory = $runnerToolsDirectory
        RunnerPath = $runnerPath
        Resolution = $resolution
        Descriptor = $descriptor
    }
}
