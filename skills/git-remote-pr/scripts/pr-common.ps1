$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $script:Utf8
[Console]::OutputEncoding = $script:Utf8
$OutputEncoding = $script:Utf8
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'
$env:GH_PROMPT_DISABLED = '1'

function Invoke-Tool {
    param([string]$Name, [string[]]$Arguments, [switch]$AllowFailure)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "Required command '$Name' is unavailable. Install it and retry." }
    $lines = @(& $command.Source @Arguments 2>&1)
    $code = $LASTEXITCODE
    $output = ($lines | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "$Name $($Arguments[0]) failed (exit $code): $output"
    }
    return [pscustomobject]@{ Code = $code; Text = $output }
}

function Invoke-Git { param([string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-Tool git $Arguments -AllowFailure:$AllowFailure
}
function Invoke-Gh { param([string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-Tool gh $Arguments -AllowFailure:$AllowFailure
}
function Get-GhJson { param([string]$Endpoint)
    $result = Invoke-Gh @('api', $Endpoint)
    if (-not $result.Text) { return $null }
    return ConvertFrom-Json -InputObject $result.Text
}
function Get-RemoteRepo { param([string]$Url)
    if ($Url -match '^(?:https?://|ssh://git@)github\.com[:/](?<repo>[^/]+/[^/]+?)(?:\.git)?/?$') { return $Matches.repo }
    if ($Url -match '^git@github\.com:(?<repo>[^/]+/[^/]+?)(?:\.git)?$') { return $Matches.repo }
    return $null
}
function Get-PrTitle { param([string]$Branch)
    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'Head branch is empty.' }
    $title = $Branch.Replace('-', ' ').Replace('_', ' ')
    return $title.Substring(0, 1).ToUpperInvariant() + $title.Substring(1)
}
function Normalize-BranchSegment { param([string]$Segment)
    if ($null -eq $Segment) { return '' }
    return ([regex]::Replace($Segment.Trim(), '[-_]+', '-')).Trim('-')
}
function Test-EquivalentBranchNames { param([string]$LocalBranch, [string]$RemoteBranch)
    if ([string]::IsNullOrWhiteSpace($LocalBranch) -or [string]::IsNullOrWhiteSpace($RemoteBranch)) { return $false }
    if ($LocalBranch -ceq $RemoteBranch) { return $true }
    $localSegments = $LocalBranch -split '/'
    $remoteSegments = $RemoteBranch -split '/'
    if ($localSegments.Count -ne $remoteSegments.Count) { return $false }
    for ($index = 0; $index -lt $localSegments.Count; $index++) {
        if ((Normalize-BranchSegment $localSegments[$index]) -cne (Normalize-BranchSegment $remoteSegments[$index])) { return $false }
    }
    return $true
}
function Assert-ScratchPath { param([string]$Path, [string]$RepoRoot)
    $target = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char[]]@('/', '\'))
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($target.Equals($root, $comparison) -or $target.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        $relative = [System.IO.Path]::GetRelativePath($root, $target).Replace('\', '/')
        if (-not $relative.StartsWith('.bot/', [System.StringComparison]::Ordinal)) { throw 'PR scratch output must be outside the repository or beneath ignored .bot/.' }
        $ignored = Invoke-Git @('check-ignore', '-q', '.bot/__git_remote_pr_probe__') -AllowFailure
        if ($ignored.Code -ne 0) { throw '.bot/ is not ignored; choose an operating-system temporary directory.' }
    }
    return $target
}
function Get-Pages { param([string]$Endpoint)
    $response = Invoke-Gh @('api', '--paginate', '--slurp', $Endpoint)
    $pages = ConvertFrom-Json -InputObject $response.Text
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) { foreach ($item in $page) { $items.Add($item) } }
    return $items.ToArray()
}
function Get-RemoteSha { param([string]$Remote, [string]$Branch)
    $result = Invoke-Git @('ls-remote', '--heads', $Remote, "refs/heads/$Branch")
    if ([string]::IsNullOrWhiteSpace($result.Text)) { return $null }
    $match = [regex]::Match($result.Text, '^([0-9a-f]{40,64})\s+refs/heads/')
    if (-not $match.Success) { throw "Cannot parse remote head for $Remote/$Branch." }
    return $match.Groups[1].Value
}
function Get-PrSnapshotKey { param($Evidence)
    $pr = $Evidence.existing_pr
    $fields = [ordered]@{
        repo = $Evidence.repository; head_repo = $Evidence.head_repository
        base = $Evidence.base; head = $Evidence.head
        head_remote = $Evidence.head_remote; remote_branch = $Evidence.remote_branch
        assignee = $Evidence.assignee; template_path = $Evidence.template_path
        base_sha = $Evidence.base_sha; head_sha = $Evidence.head_sha
        remote_sha = $Evidence.remote_sha; merge_base = $Evidence.merge_base
        pr_number = if ($pr) { $pr.number } else { $null }; pr_state = if ($pr) { $pr.state } else { $null }
        pr_head_sha = if ($pr) { $pr.head_sha } else { $null }; pr_base_sha = if ($pr) { $pr.base_sha } else { $null }
        pr_title = if ($pr) { $pr.title } else { $null }; pr_body = if ($pr) { $pr.body } else { $null }
        pr_draft = if ($pr) { $pr.draft } else { $null }
        pr_assignees = if ($pr) { @($pr.assignees) } else { @() }
        paths = @($Evidence.files | ForEach-Object { "$($_.status):$($_.old_path):$($_.path)" })
    }
    $bytes = $script:Utf8.GetBytes(($fields | ConvertTo-Json -Depth 8 -Compress))
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}
