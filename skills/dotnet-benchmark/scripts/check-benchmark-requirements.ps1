#requires -Version 5.1
<#
.SYNOPSIS
    Detects the current state of a repository's BenchmarkDotNet harness for the dotnet-benchmark skill.

.DESCRIPTION
    Emits a single JSON object describing what already exists so the skill adds only what is missing.
    Read-only: it inspects files and the dotnet CLI but changes nothing.

.PARAMETER RepoRoot
    Repository root to inspect. Defaults to the current directory.

.PARAMETER BenchmarkType
    Optional namespace-qualified or simple benchmark type name used to detect matching reports that would suppress execution.

.PARAMETER SkipSdkCheck
    Skips invoking dotnet --version. Intended for deterministic detector tests; normal skill runs should not use it.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-benchmark-requirements.ps1 -RepoRoot C:\src\myrepo
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$BenchmarkType,
    [switch]$SkipSdkCheck
)

$ErrorActionPreference = 'Stop'

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DotNetSdkVersion {
    param([int]$TimeoutMilliseconds = 10000)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command 'dotnet' -ErrorAction Stop).Source
    $startInfo.Arguments = '--version'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return [ordered]@{ status = 'start-failed'; version = $null }
        }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            return [ordered]@{ status = 'timed-out'; version = $null }
        }
        if ($process.ExitCode -ne 0) {
            return [ordered]@{ status = 'failed'; version = $null }
        }
        $version = ($process.StandardOutput.ReadToEnd() -split '\r?\n' | Select-Object -First 1).Trim()
        return [ordered]@{ status = 'available'; version = $version }
    } finally {
        $process.Dispose()
    }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

# --- .NET SDK ---------------------------------------------------------------
$sdkAvailable = $false
$sdkVersion = $null
$sdkStatus = if ($SkipSdkCheck) { 'skipped' } else { 'not-found' }
if (-not $SkipSdkCheck -and (Test-CommandExists 'dotnet')) {
    try {
        $sdkProbe = Get-DotNetSdkVersion
        $sdkVersion = $sdkProbe.version
        $sdkStatus = $sdkProbe.status
        $sdkAvailable = -not [string]::IsNullOrWhiteSpace($sdkVersion)
    } catch {
        $sdkAvailable = $false
        $sdkStatus = 'failed'
    }
}

# --- Solution files ---------------------------------------------------------
$rootFiles = @(Get-ChildItem -LiteralPath $RepoRoot -File -ErrorAction SilentlyContinue)
$slnx = @($rootFiles | Where-Object { $_.Extension -ieq '.slnx' } | Select-Object -ExpandProperty Name -Unique)
$sln  = @($rootFiles | Where-Object { $_.Extension -ieq '.sln'  } | Select-Object -ExpandProperty Name -Unique)
$solutionFormat = if ($slnx.Count -gt 0) { 'slnx' } elseif ($sln.Count -gt 0) { 'sln' } else { 'none' }
$solutionFiles = @($slnx + $sln)

# --- Central Package Management --------------------------------------------
$packagesProps = Join-Path $RepoRoot 'Directory.Packages.props'
$cpm = Test-Path -LiteralPath $packagesProps
$declaredPackages = @()
if ($cpm) {
    $packagesText = [System.IO.File]::ReadAllText($packagesProps)
    foreach ($id in @('BenchmarkDotNet', 'BenchmarkDotNet.Diagnostics.Windows', 'Codebelt.Extensions.BenchmarkDotNet.Console')) {
        if ($packagesText -match [regex]::Escape("Include=`"$id`"")) { $declaredPackages += $id }
    }
}

# --- Root Directory.Build.props conventions --------------------------------
$buildProps = Join-Path $RepoRoot 'Directory.Build.props'
$centralizesBenchmarkConventions = $false
if (Test-Path -LiteralPath $buildProps) {
    $buildText = [System.IO.File]::ReadAllText($buildProps)
    $centralizesBenchmarkConventions = ($buildText -match 'IsBenchmarkProject') -and ($buildText -match 'IsToolingProject')
}

# --- Existing tuning benchmark projects ------------------------------------
$tuningDir = Join-Path $RepoRoot 'tuning'
$benchmarkProjects = @()
if (Test-Path -LiteralPath $tuningDir) {
    $benchmarkProjects = @(
        Get-ChildItem -LiteralPath $tuningDir -Recurse -Filter *.Benchmarks.csproj -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/' }
    )
}

# --- Existing tooling runner host ------------------------------------------
$toolingDir = Join-Path $RepoRoot 'tooling'
$runner = $null
if (Test-Path -LiteralPath $toolingDir) {
    $runnerCsproj = Get-ChildItem -LiteralPath $toolingDir -Recurse -Filter *.csproj -File -ErrorAction SilentlyContinue |
        Where-Object {
            $text = [System.IO.File]::ReadAllText($_.FullName)
            $text -match 'Codebelt\.Extensions\.BenchmarkDotNet\.Console'
        } | Select-Object -First 1
    if ($runnerCsproj) {
        $programFile = Get-ChildItem -LiteralPath $runnerCsproj.Directory.FullName -Filter Program.cs -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $programText = if ($programFile) { [System.IO.File]::ReadAllText($programFile.FullName) } else { '' }
        $configuredRuntimes = @(
            [regex]::Matches($programText, '(?:ClrRuntime|CoreRuntime)\.[A-Za-z0-9_]+') |
            ForEach-Object { $_.Value } |
            Select-Object -Unique
        )
        $runner = [ordered]@{
            name                      = $runnerCsproj.Directory.Name
            path                      = $runnerCsproj.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            programPath               = if ($programFile) { $programFile.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/' } else { $null }
            referencesConsole         = $true
            skipBenchmarksWithReports = $programText -match 'SkipBenchmarksWithReports\s*=\s*true'
            usesSlimJob               = $programText -match 'BenchmarkWorkspaceOptions\.Slim'
            configuredRuntimes        = $configuredRuntimes
        }
    }
}

# --- reports/ ---------------------------------------------------------------
$reportsPath = Join-Path $RepoRoot 'reports'
$reportsTuningPath = Join-Path $reportsPath 'tuning'
$reportsExists = Test-Path -LiteralPath $reportsPath
$reportFiles = @()
if (Test-Path -LiteralPath $reportsTuningPath) {
    $reportFiles = @(
        Get-ChildItem -LiteralPath $reportsTuningPath -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/' }
    )
}

$matchingReportFiles = @()
if (-not [string]::IsNullOrWhiteSpace($BenchmarkType)) {
    $benchmarkTypeName = ($BenchmarkType -split '\.')[-1]
    $matchingReportFiles = @(
        $reportFiles | Where-Object {
            $filename = [System.IO.Path]::GetFileNameWithoutExtension($_)
            $potentialTypeFullName = ($filename -split '-', 2)[0]
            $potentialTypeName = ($potentialTypeFullName -split '\.')[-1]
            $potentialTypeName.Equals($benchmarkTypeName, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
}

$wouldSkipRequestedBenchmark = ($runner -ne $null) -and
    $runner.skipBenchmarksWithReports -and
    (-not [string]::IsNullOrWhiteSpace($BenchmarkType)) -and
    ($matchingReportFiles.Count -gt 0)

$harnessReady = ($runner -ne $null) -and ($benchmarkProjects.Count -gt 0)

$result = [ordered]@{
    repoRoot                        = $RepoRoot
    sdk                             = [ordered]@{ available = $sdkAvailable; version = $sdkVersion; status = $sdkStatus }
    solutionFormat                  = $solutionFormat
    solutionFiles                   = $solutionFiles
    centralPackageManagement        = $cpm
    declaredBenchmarkPackages       = $declaredPackages
    centralizesBenchmarkConventions = $centralizesBenchmarkConventions
    benchmarkProjects               = $benchmarkProjects
    runner                          = $runner
    reportsFolderExists             = $reportsExists
    reports                         = [ordered]@{
        path                         = $reportsPath.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        tuningPath                   = $reportsTuningPath.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        files                        = $reportFiles
        requestedBenchmarkType       = $BenchmarkType
        matchingReportFiles          = $matchingReportFiles
        wouldSkipRequestedBenchmark  = $wouldSkipRequestedBenchmark
    }
    harnessReady                    = $harnessReady
}

$result | ConvertTo-Json -Depth 6
