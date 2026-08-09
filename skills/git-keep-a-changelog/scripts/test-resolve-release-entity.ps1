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

    Set-TestFile -RelativePath 'skills/pending/SKILL.md' -Content 'pending'
    Assert-Classification -EntityPath 'skills/pending' -Expected 'Unchanged'
    Assert-Classification -EntityPath 'skills/pending' -Expected 'Added' -IncludeWorktree

    Write-Output 'PASS: release entities are classified from deterministic base and final-state existence.'
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
