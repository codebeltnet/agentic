#!/usr/bin/env pwsh
# Deterministic historical-validation regressions; all mutations stay in a temporary repository.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempRoot ('agent-smith-ref-' + [guid]::NewGuid().ToString('N'))))
if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test workspace escaped the temporary root: $testRoot"
}

function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $output = & git -C $testRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture git $Arguments failed (exit $LASTEXITCODE): $output" }
    return $output
}

function Assert-Validation {
    param([string]$Name, [string]$GitRef, [bool]$ShouldPass, [string]$Evidence)
    $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $testRoot 'scripts/tests/test-agent-smith.ps1'))
    if ($GitRef) { $arguments += @('-Ref', $GitRef) }
    $output = (& pwsh @arguments 2>&1) -join "`n"
    $exitCode = $LASTEXITCODE
    if (($exitCode -eq 0) -ne $ShouldPass -or -not $output.Contains($Evidence)) {
        throw "${Name}: expected pass=$ShouldPass and evidence '$Evidence'; exit ${exitCode}:`n$output"
    }
    if (-not $ShouldPass -and $output.Contains('All Agent Smith focused checks passed')) {
        throw "${Name}: validator reported success after a required regression failed."
    }
    Write-Output "[PASS] $Name"
}

try {
    $null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'scripts/tests'), (Join-Path $testRoot 'skills') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'test-agent-smith.ps1') -Destination (Join-Path $testRoot 'scripts/tests')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'skills/agent-smith') -Destination (Join-Path $testRoot 'skills') -Recurse
    $scriptsRoot = Join-Path $testRoot 'skills/agent-smith/scripts'
    $regressionPath = Join-Path $scriptsRoot 'test-repair-roslyn-multiproject-artifacts.ps1'
    $repairPath = Join-Path $scriptsRoot 'repair-roslyn-multiproject-artifacts.ps1'
    $regression = [System.IO.File]::ReadAllText($regressionPath)
    $repair = [System.IO.File]::ReadAllText($repairPath)
    $null = Invoke-FixtureGit @('init', '--quiet')
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('-c', 'user.name=Validation Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '-m', 'Passing historical fixture')
    $passingRef = Invoke-FixtureGit @('rev-parse', 'HEAD')

    # Keep content assertions intact while making the worktree executable observably different.
    [System.IO.File]::WriteAllText($regressionPath, $regression + "`nthrow 'WORKTREE REGRESSION SENTINEL'`n")
    Assert-Validation 'Historical regression ignores failing worktree regression' $passingRef $true 'All Roslyn multi-project artifact repair tests passed.'
    Assert-Validation 'No-ref validation executes the worktree regression' '' $false 'WORKTREE REGRESSION SENTINEL'

    [System.IO.File]::WriteAllText($regressionPath, $regression)
    [System.IO.File]::WriteAllText($repairPath, $repair.Replace('Set-StrictMode -Version Latest', "throw 'WORKTREE REPAIR SENTINEL'`nSet-StrictMode -Version Latest"))
    Assert-Validation 'Historical regression ignores failing worktree sibling' $passingRef $true 'All Roslyn multi-project artifact repair tests passed.'

    # Store a regression that fails after exercising the real repair cases, then restore a passing worktree.
    [System.IO.File]::WriteAllText($repairPath, $repair)
    [System.IO.File]::WriteAllText($regressionPath, $regression + "`nthrow 'HISTORICAL REGRESSION SENTINEL'`n")
    $null = Invoke-FixtureGit @('add', '.')
    $null = Invoke-FixtureGit @('-c', 'user.name=Validation Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '-m', 'Failing historical fixture')
    $failingRef = Invoke-FixtureGit @('rev-parse', 'HEAD')
    [System.IO.File]::WriteAllText($regressionPath, $regression)
    Assert-Validation 'Passing worktree cannot hide historical regression failure' $failingRef $false 'HISTORICAL REGRESSION SENTINEL'
    Assert-Validation 'No-ref validation still passes with the restored worktree' '' $true 'All Agent Smith focused checks passed'
    Assert-Validation 'Invalid ref fails with an actionable read diagnostic' 'refs/heads/missing-ref' $false "Cannot read 'skills/agent-smith/SKILL.md' at 'refs/heads/missing-ref'"
    Write-Output 'All Agent Smith ref isolation tests passed (6 scenarios).'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
