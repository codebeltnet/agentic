[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolver = Join-Path $PSScriptRoot 'resolve-release-entity.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("git-keep-a-changelog-entity-{0}" -f [Guid]::NewGuid().ToString('N'))

function Invoke-TestGit {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = @(& git -C $testRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    @($output | ForEach-Object { $_.ToString() })
}

function Set-TestFile {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,

        [Parameter(Mandatory)]
        [string] $Content
    )

    $path = Join-Path $testRoot $RelativePath
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-Content -LiteralPath $path -Value $Content -Encoding utf8NoBOM
}

function Add-TestCommit {
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    Invoke-TestGit -Arguments @('add', '--all') | Out-Null
    Invoke-TestGit -Arguments @('-c', 'user.name=Test Author', '-c', 'user.email=test-author@example.invalid', 'commit', '-m', $Message) | Out-Null
}

function Assert-Classification {
    param(
        [Parameter(Mandatory)]
        [string] $EntityPath,

        [Parameter(Mandatory)]
        [string] $Expected,

        [Parameter()]
        [switch] $IncludeWorktree
    )

    $parameters = @{
        Repository = $testRoot
        BaseCommit = $script:baseCommit
        HeadCommit = 'HEAD'
        EntityPath = $EntityPath
    }
    if ($IncludeWorktree) {
        $parameters.IncludeWorktree = $true
    }

    $result = (& $resolver @parameters | ConvertFrom-Json)
    if ($result.classification -ne $Expected) {
        throw "Assertion failed for '$EntityPath'. Expected '$Expected', got '$($result.classification)'."
    }
}

function Assert-Section {
    param(
        [string] $EntityPath,
        [string] $Section,
        [bool] $Allowed,
        [switch] $IncludeWorktree
    )

    $arguments = @('-NoProfile', '-NonInteractive', '-File', $resolver,
        '-Repository', $testRoot, '-BaseCommit', $script:baseCommit,
        '-EntityPath', $EntityPath, '-Section', $Section)
    if ($IncludeWorktree) { $arguments += '-IncludeWorktree' }
    $output = @(& pwsh @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($Allowed) {
        if ($exitCode -ne 0) { throw "Expected $Section for ${EntityPath}: $output" }
        $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        if ($Section -notin $result.allowed_sections) { throw "Missing allowed section $Section." }
    }
    elseif ($exitCode -eq 0 -or ($output -join ' ') -notmatch 'section .+ is invalid') {
        throw "Expected section rejection for $EntityPath / $Section; exit ${exitCode}: $output"
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Invoke-TestGit -Arguments @('init', '--initial-branch=main') | Out-Null

    Set-TestFile -RelativePath 'skills/existing/SKILL.md' -Content 'existing v1'
    Set-TestFile -RelativePath 'skills/legacy/SKILL.md' -Content 'legacy'
    Set-TestFile -RelativePath 'README.md' -Content 'catalog'
    Add-TestCommit -Message 'base release'
    $script:baseCommit = @(Invoke-TestGit -Arguments @('rev-parse', 'HEAD'))[0]

    Invoke-TestGit -Arguments @('switch', '-c', 'v2.0.0/entity-classification') | Out-Null
    Set-TestFile -RelativePath 'skills/dotnet-test/SKILL.md' -Content 'initial'
    Add-TestCommit -Message 'introduce dotnet-test'
    Set-TestFile -RelativePath 'skills/dotnet-test/references/testing.md' -Content 'refined'
    Add-TestCommit -Message 'refine dotnet-test'
    Set-TestFile -RelativePath 'skills/existing/SKILL.md' -Content 'existing v2'
    [IO.File]::Delete((Join-Path $testRoot 'skills/legacy/SKILL.md'))
    Add-TestCommit -Message 'change existing and remove legacy'

    Assert-Classification -EntityPath 'skills/dotnet-test' -Expected 'Added'
    Assert-Classification -EntityPath 'skills/existing' -Expected 'Changed'
    Assert-Classification -EntityPath 'skills/legacy' -Expected 'Removed'
    Assert-Classification -EntityPath 'README.md' -Expected 'Unchanged'

    # Simulate an earlier changelog invocation, then more commits on the same branch.
    Assert-Section -EntityPath 'skills/dotnet-test' -Section Added -Allowed $true
    Set-TestFile -RelativePath 'CHANGELOG.md' -Content "## [2.0.0]`n`n### Added`n`n- New dotnet-test capability."
    Add-TestCommit -Message 'record unreleased draft'
    Set-TestFile -RelativePath 'skills/dotnet-test/references/testing.md' -Content 'scoped properties, XML decoding, conflict routing, encoding fixes'
    Add-TestCommit -Message 'fix and harden new capability after draft'
    Assert-Section -EntityPath 'skills/dotnet-test' -Section Added -Allowed $true
    Assert-Section -EntityPath 'skills/dotnet-test' -Section Changed -Allowed $false
    Assert-Section -EntityPath 'skills/dotnet-test' -Section Fixed -Allowed $false
    Assert-Section -EntityPath 'skills/existing' -Section Changed -Allowed $true
    Assert-Section -EntityPath 'skills/existing' -Section Fixed -Allowed $true
    Assert-Section -EntityPath 'skills/existing' -Section Added -Allowed $false
    Assert-Section -EntityPath 'skills/legacy' -Section Removed -Allowed $true
    Assert-Section -EntityPath 'README.md' -Section Changed -Allowed $false

    Set-TestFile -RelativePath 'skills/pending/SKILL.md' -Content 'pending'
    Assert-Classification -EntityPath 'skills/pending' -Expected 'Unchanged'
    Assert-Classification -EntityPath 'skills/pending' -Expected 'Added' -IncludeWorktree
    Assert-Section -EntityPath 'skills/pending' -Section Added -Allowed $true -IncludeWorktree
    Assert-Section -EntityPath 'skills/pending' -Section Fixed -Allowed $false -IncludeWorktree

    Write-Output 'PASS: release entities are classified from deterministic base and final-state existence.'
    Write-Output 'PASS: repeated draft runs reject Changed and Fixed for new unreleased capabilities while preserving existing-capability sections.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove test directory outside the temp root: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
