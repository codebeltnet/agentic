[CmdletBinding()]
param(
    [Parameter()]
    [string] $Repository = '.',

    [Parameter(Mandatory)]
    [string] $BaseCommit,

    [Parameter()]
    [string] $HeadCommit = 'HEAD',

    [Parameter(Mandatory)]
    [string] $EntityPath,

    [Parameter()]
    [switch] $IncludeWorktree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter()]
        [switch] $AllowFailure
    )

    $output = @(& git -C $Repository @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "git $($Arguments -join ' ') failed with exit code ${exitCode}: $detail"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Lines = @($output | ForEach-Object { $_.ToString() })
    }
}

function Resolve-Commit {
    param(
        [Parameter(Mandatory)]
        [string] $Ref
    )

    $result = Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "$Ref^{commit}") -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Lines.Count -eq 0) {
        throw "Git ref does not resolve to a commit: $Ref"
    }

    $result.Lines[0]
}

function Test-CommitPath {
    param(
        [Parameter(Mandatory)]
        [string] $Commit,

        [Parameter(Mandatory)]
        [string] $Path
    )

    (Invoke-Git -Arguments @('cat-file', '-e', "${Commit}:$Path") -AllowFailure).ExitCode -eq 0
}

$repositoryRoot = (Invoke-Git -Arguments @('rev-parse', '--show-toplevel')).Lines[0]
$normalizedPath = $EntityPath.Replace('\', '/').Trim('/')
$pathSegments = @($normalizedPath -split '/')

if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [IO.Path]::IsPathRooted($EntityPath) -or $pathSegments -contains '..') {
    throw "EntityPath must be a non-empty repository-relative path without parent traversal: $EntityPath"
}

$resolvedBase = Resolve-Commit -Ref $BaseCommit
$resolvedHead = Resolve-Commit -Ref $HeadCommit
$baseExists = Test-CommitPath -Commit $resolvedBase -Path $normalizedPath
$headExists = Test-CommitPath -Commit $resolvedHead -Path $normalizedPath
$finalExists = $headExists
$hasDelta = $false

if ($IncludeWorktree) {
    $worktreePath = Join-Path $repositoryRoot ($normalizedPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $finalExists = Test-Path -LiteralPath $worktreePath
}

if ($baseExists -and $finalExists) {
    $committedDiff = Invoke-Git -Arguments @('diff', '--quiet', $resolvedBase, $resolvedHead, '--', $normalizedPath) -AllowFailure
    if ($committedDiff.ExitCode -notin @(0, 1)) {
        throw "Unable to compare entity path between base and HEAD: $normalizedPath"
    }

    $hasDelta = $committedDiff.ExitCode -eq 1

    if ($IncludeWorktree -and -not $hasDelta) {
        $worktreeDiff = Invoke-Git -Arguments @('diff', '--quiet', $resolvedHead, '--', $normalizedPath) -AllowFailure
        if ($worktreeDiff.ExitCode -notin @(0, 1)) {
            throw "Unable to compare pending entity path against HEAD: $normalizedPath"
        }

        $untracked = Invoke-Git -Arguments @('ls-files', '--others', '--exclude-standard', '--', $normalizedPath)
        $hasDelta = $worktreeDiff.ExitCode -eq 1 -or $untracked.Lines.Count -gt 0
    }
}

$classification = if (-not $baseExists -and $finalExists) {
    'Added'
}
elseif ($baseExists -and -not $finalExists) {
    'Removed'
}
elseif ($baseExists -and $finalExists -and $hasDelta) {
    'Changed'
}
else {
    'Unchanged'
}

[pscustomobject]@{
    entity_path = $normalizedPath
    base_commit = $resolvedBase
    head_commit = $resolvedHead
    include_worktree = [bool] $IncludeWorktree
    base_exists = $baseExists
    final_exists = $finalExists
    classification = $classification
} | ConvertTo-Json
