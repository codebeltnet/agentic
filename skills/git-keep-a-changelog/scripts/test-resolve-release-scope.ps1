[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolver = Join-Path $PSScriptRoot 'resolve-release-scope.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("git-keep-a-changelog-range-{0}" -f [Guid]::NewGuid().ToString('N'))

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

function Add-TestCommit {
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter()]
        [string] $AuthorName = 'Test Author',

        [Parameter()]
        [string] $AuthorEmail = 'test-author@example.invalid'
    )

    $file = Join-Path $testRoot 'release.txt'
    Add-Content -LiteralPath $file -Value $Content
    Invoke-TestGit -Arguments @('add', 'release.txt') | Out-Null
    Invoke-TestGit -Arguments @('-c', "user.name=$AuthorName", '-c', "user.email=$AuthorEmail", 'commit', '-m', $Message) | Out-Null
    @(Invoke-TestGit -Arguments @('rev-parse', 'HEAD'))[0]
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        $Actual,

        [Parameter(Mandatory)]
        $Expected,

        [Parameter(Mandatory)]
        [string] $Because
    )

    if ($Actual -ne $Expected) {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Invoke-TestGit -Arguments @('init', '--initial-branch=main') | Out-Null

    $previousRelease = Add-TestCommit -Message 'Release 1.0.0' -Content 'previous release'
    Invoke-TestGit -Arguments @('tag', 'v1.0.0') | Out-Null
    Invoke-TestGit -Arguments @('switch', '-c', 'v1.0.1/service-update') | Out-Null
    $firstPrCommit = Add-TestCommit -Message 'Upgrade dependency' -Content 'first PR change' -AuthorName 'First Contributor' -AuthorEmail 'first@example.invalid'
    $secondPrCommit = Add-TestCommit -Message 'Adjust container reference' -Content 'second PR change' -AuthorName 'Second Contributor' -AuthorEmail 'second@example.invalid'

    Invoke-TestGit -Arguments @('update-ref', 'refs/remotes/origin/main', $previousRelease) | Out-Null
    Invoke-TestGit -Arguments @('update-ref', 'refs/remotes/origin/v1.0.1/service-update', $secondPrCommit) | Out-Null
    Invoke-TestGit -Arguments @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main') | Out-Null
    Invoke-TestGit -Arguments @('config', 'branch.v1.0.1/service-update.remote', 'origin') | Out-Null
    Invoke-TestGit -Arguments @('config', 'branch.v1.0.1/service-update.merge', 'refs/heads/v1.0.1/service-update') | Out-Null

    $scope = (& $resolver -Repository $testRoot | ConvertFrom-Json)

    Assert-Equal -Actual $scope.comparison_ref -Expected 'origin/main' -Because 'the feature tracking branch must not become its own comparison base'
    Assert-Equal -Actual $scope.merge_base -Expected $previousRelease -Because 'the previous release must be the excluded merge boundary'
    Assert-Equal -Actual $scope.excluded_boundary_commit -Expected $previousRelease -Because 'the previous release must be explicitly reported as excluded'
    Assert-Equal -Actual $scope.selected_commit_count -Expected 2 -Because 'all commits from all PR contributors must remain selected'
    Assert-Equal -Actual $scope.selected_commits[0] -Expected $firstPrCommit -Because 'the first PR contributor commit must remain in scope'
    Assert-Equal -Actual $scope.selected_commits[1] -Expected $secondPrCommit -Because 'the second PR contributor commit must remain in scope'
    Assert-Equal -Actual $scope.base_history_bleed -Expected $false -Because 'no commit already on the comparison branch may bleed into the release scope'

    if ($scope.selected_commits -contains $previousRelease) {
        throw 'Assertion failed: the tagged previous release bled into the new release scope.'
    }

    Write-Output 'PASS: branch scope excludes the tagged previous release and retains every PR commit.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove test directory outside the temp root: $resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
