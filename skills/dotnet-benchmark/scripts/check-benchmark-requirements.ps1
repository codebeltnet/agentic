#requires -Version 5.1
<#
.SYNOPSIS
    Detects the current state of a repository's BenchmarkDotNet harness for the dotnet-benchmark skill.

.DESCRIPTION
    Emits a single JSON object describing what already exists so the skill adds only what is missing.
    Read-only: it inspects files and the dotnet CLI but changes nothing.

.PARAMETER RepoRoot
    Repository root to inspect. Defaults to the current directory.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-benchmark-requirements.ps1 -RepoRoot C:\src\myrepo
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

# --- .NET SDK ---------------------------------------------------------------
$sdkAvailable = $false
$sdkVersion = $null
if (Test-CommandExists 'dotnet') {
    try {
        $sdkVersion = (& dotnet --version 2>$null | Select-Object -First 1)
        $sdkAvailable = -not [string]::IsNullOrWhiteSpace($sdkVersion)
    } catch {
        $sdkAvailable = $false
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
        $runner = [ordered]@{
            name             = $runnerCsproj.Directory.Name
            path             = $runnerCsproj.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            referencesConsole = $true
        }
    }
}

# --- reports/ ---------------------------------------------------------------
$reportsExists = Test-Path -LiteralPath (Join-Path $RepoRoot 'reports')

$harnessReady = ($runner -ne $null) -and ($benchmarkProjects.Count -gt 0)

$result = [ordered]@{
    repoRoot                        = $RepoRoot
    sdk                             = [ordered]@{ available = $sdkAvailable; version = $sdkVersion }
    solutionFormat                  = $solutionFormat
    solutionFiles                   = $solutionFiles
    centralPackageManagement        = $cpm
    declaredBenchmarkPackages       = $declaredPackages
    centralizesBenchmarkConventions = $centralizesBenchmarkConventions
    benchmarkProjects               = $benchmarkProjects
    runner                          = $runner
    reportsFolderExists             = $reportsExists
    harnessReady                    = $harnessReady
}

$result | ConvertTo-Json -Depth 6
