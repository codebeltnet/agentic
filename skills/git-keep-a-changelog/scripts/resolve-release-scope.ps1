[CmdletBinding()]
param(
    [Parameter()]
    [string] $Repository = '.',

    [Parameter()]
    [string] $BaseRef,

    [Parameter()]
    [string] $HeadRef = 'HEAD'
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

function Test-GitRef {
    param(
        [Parameter(Mandatory)]
        [string] $Ref
    )

    (Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "$Ref^{commit}") -AllowFailure).ExitCode -eq 0
}

function Resolve-DefaultBaseRef {
    $upstreamResult = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -AllowFailure
    $remoteName = $null

    if ($upstreamResult.ExitCode -eq 0 -and $upstreamResult.Lines.Count -gt 0) {
        $upstream = $upstreamResult.Lines[0]
        $separator = $upstream.IndexOf('/')
        if ($separator -gt 0) {
            $remoteName = $upstream.Substring(0, $separator)
        }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($remoteName)) {
        $remoteHead = Invoke-Git -Arguments @('symbolic-ref', '--quiet', "refs/remotes/$remoteName/HEAD") -AllowFailure
        if ($remoteHead.ExitCode -eq 0 -and $remoteHead.Lines.Count -gt 0) {
            $candidates.Add(($remoteHead.Lines[0] -replace '^refs/remotes/', ''))
        }

        $candidates.Add("$remoteName/main")
        $candidates.Add("$remoteName/master")
    }

    $originHead = Invoke-Git -Arguments @('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD') -AllowFailure
    if ($originHead.ExitCode -eq 0 -and $originHead.Lines.Count -gt 0) {
        $candidates.Add(($originHead.Lines[0] -replace '^refs/remotes/', ''))
    }

    $candidates.Add('origin/main')
    $candidates.Add('origin/master')
    $candidates.Add('main')
    $candidates.Add('master')

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-GitRef -Ref $candidate) {
            return $candidate
        }
    }

    throw 'Unable to resolve a default comparison branch. Pass -BaseRef with the PR target or release base instead of guessing.'
}

$insideWorkTree = Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree')
if ($insideWorkTree.Lines.Count -eq 0 -or $insideWorkTree.Lines[0] -ne 'true') {
    throw "Repository path is not inside a Git worktree: $Repository"
}

if (-not (Test-GitRef -Ref $HeadRef)) {
    throw "Head ref does not resolve to a commit: $HeadRef"
}

if ([string]::IsNullOrWhiteSpace($BaseRef)) {
    $BaseRef = Resolve-DefaultBaseRef
}
elseif (-not (Test-GitRef -Ref $BaseRef)) {
    throw "Base ref does not resolve to a commit: $BaseRef"
}

$baseCommit = (Invoke-Git -Arguments @('rev-parse', "$BaseRef^{commit}")).Lines[0]
$headCommit = (Invoke-Git -Arguments @('rev-parse', "$HeadRef^{commit}")).Lines[0]
$mergeBase = (Invoke-Git -Arguments @('merge-base', $HeadRef, $BaseRef)).Lines[0]
$historyRange = "$baseCommit..$headCommit"
$diffRange = "$mergeBase..$headCommit"
$selectedCommits = @((Invoke-Git -Arguments @('rev-list', '--reverse', $historyRange)).Lines)
$bleedCommits = [System.Collections.Generic.List[string]]::new()

foreach ($commit in $selectedCommits) {
    $ancestorCheck = Invoke-Git -Arguments @('merge-base', '--is-ancestor', $commit, $BaseRef) -AllowFailure
    if ($ancestorCheck.ExitCode -eq 0) {
        $bleedCommits.Add($commit)
    }
    elseif ($ancestorCheck.ExitCode -ne 1) {
        throw "Unable to verify whether selected commit $commit is already reachable from $BaseRef."
    }
}

if ($selectedCommits -contains $mergeBase -or $selectedCommits -contains $baseCommit) {
    $bleedCommits.Add($mergeBase)
}

if ($bleedCommits.Count -gt 0) {
    throw "Release scope contains commits already reachable from ${BaseRef}: $($bleedCommits -join ', ')"
}

[pscustomobject]@{
    comparison_ref = $BaseRef
    comparison_commit = $baseCommit
    head_ref = $HeadRef
    head_commit = $headCommit
    merge_base = $mergeBase
    history_range = $historyRange
    diff_range = $diffRange
    excluded_boundary_commit = $mergeBase
    selected_commit_count = $selectedCommits.Count
    selected_commits = $selectedCommits
    base_history_bleed = $false
} | ConvertTo-Json -Depth 4
