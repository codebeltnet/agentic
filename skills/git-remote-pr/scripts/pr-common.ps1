$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $script:Utf8
[Console]::OutputEncoding = $script:Utf8
$OutputEncoding = $script:Utf8
$PSNativeCommandUseErrorActionPreference = $false
$env:GIT_TERMINAL_PROMPT = '0'
$env:GH_PROMPT_DISABLED = '1'

function Write-PrFailure { param([string]$Message)
    # Some noninteractive hosts only surface stdout. Keep failure visible there,
    # preserve stderr for CLI callers, and let the entry point exit nonzero.
    [Console]::Out.WriteLine("ERROR: $Message")
    [Console]::Error.WriteLine($Message)
}

function Assert-PrBodyStructure { param([string]$Body)
    $hasOpening = $false
    $openingEnded = $false
    $theme = $null
    $hasBullet = $false
    foreach ($line in ($Body -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($hasOpening) { $openingEnded = $true }
            continue
        }
        if ($line -match '^\*\*(?<theme>[^*]+):\*\*\s*$' -and $Matches.theme.Trim()) {
            if (-not $hasOpening) { throw 'PR body structure: exactly one opening prose paragraph is required before the first theme.' }
            if ($theme -and -not $hasBullet) { throw "PR body structure: theme '$theme' needs at least one dash bullet." }
            $theme = $Matches.theme.Trim()
            $hasBullet = $false
            continue
        }
        if ($line -match '^\s*(?:#{1,6}\s|\*\*|__)') { throw 'PR body structure: thematic headings must use **<Reviewer theme>:**.' }
        if ($theme) {
            if ($line -notmatch '^-\s+\S') { throw "PR body structure: only dash bullets are allowed beneath '$theme'; prose paragraphs are not allowed." }
            $hasBullet = $true
        } else {
            if ($openingEnded -or $line -match '^\s*(?:[-+*]\s|\d+[.)]\s|>|`{3}|~{3}|\|)' -or $line -match '^(?:\t| {4})') {
                throw 'PR body structure: exactly one opening prose paragraph is required before the first theme.'
            }
            $hasOpening = $true
        }
    }
    if (-not $hasOpening) { throw 'PR body structure: an opening prose paragraph is required.' }
    if (-not $theme) { throw 'PR body structure: at least one thematic heading is required.' }
    if (-not $hasBullet) { throw "PR body structure: theme '$theme' needs at least one dash bullet." }
    if ($theme -match '^(?:changes?\s+summary|summary(?:\s+of\s+changes)?|conclusion)$') {
        throw "PR body structure: redundant final summary section '$theme' is not allowed."
    }
}

function Assert-PrThemeCoverage { param($Evidence, [string]$Body)
    $coverageErrors = [System.Collections.Generic.List[string]]::new()
    $unassigned = @($Evidence.files | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.theme) })
    if ($unassigned.Count) { $coverageErrors.Add("Unassigned paths: $($unassigned.path -join ', '). Assign a reviewer theme to each path.") }
    foreach ($group in @($Evidence.files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.theme) } | Group-Object theme)) {
        if (-not $Body.Contains($group.Name.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $coverageErrors.Add("Missing theme '$($group.Name)' ($($group.Count) paths: $($group.Group.path -join ', ')). Use this phrase in a heading or bullet, or correct the coverage map.")
        }
    }
    if ($coverageErrors.Count) { throw ("Theme coverage failed (case-insensitive literal matching; Markdown heading punctuation may surround the phrase):`n" + ($coverageErrors -join "`n")) }
}

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
function Test-EquivalentBranchNames { param([string]$LocalBranch, [string]$RemoteBranch)
    if ([string]::IsNullOrWhiteSpace($LocalBranch) -or [string]::IsNullOrWhiteSpace($RemoteBranch)) { return $false }
    return $LocalBranch -ceq $RemoteBranch
}
function Set-PrPreviewApprovalSlots { param([string]$Preview, [string]$ExpectedId, [string]$ReplacementId)
    # Only the generated third line and final line are slots. Never normalize
    # matching text in the proposed title/body, even if it looks like a field.
    $lines = $Preview.Split("`n")
    if ($lines.Length -lt 4 -or $lines[2] -cne "Approval ID: $ExpectedId" -or $lines[-1] -cne "To approve this exact preview, reply: approve $ExpectedId") {
        throw 'Prepared preview approval-ID slots are invalid.'
    }
    $lines[2] = "Approval ID: $ReplacementId"
    $lines[-1] = "To approve this exact preview, reply: approve $ReplacementId"
    return $lines -join "`n"
}
function Get-PlanApprovalId { param($Plan)
    # Fixed property order and JSON types form the canonical write intent.
    # Artifact paths scope the transaction to its workspace, including refreshes
    # with identical content. review_hash binds the complete normalized preview;
    # preview_hash checks the final artifact independently to avoid a cycle.
    $fields = [ordered]@{}
    foreach ($name in @('schema', 'snapshot_key', 'evidence_file', 'evidence_hash', 'body_file', 'body_hash', 'preview_file', 'repository', 'action', 'base', 'head_repository', 'head', 'title', 'draft', 'assignee', 'push_required', 'metadata_write', 'assignment_write', 'existing_pr_number', 'existing_pr_url', 'commit_count', 'changed_file_count')) {
        $fields[$name] = $Plan.$name
    }
    $fields['review_hash'] = $Plan.review_hash
    $bytes = $script:Utf8.GetBytes(($fields | ConvertTo-Json -Depth 8 -Compress))
    return 'APR-' + [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 12)
}
function Get-ApprovalInvalidationPath { param([string]$PlanFile)
    return Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($PlanFile))) 'approval-invalidated.json'
}
function Stop-PrApproval { param([string]$PlanFile, [string]$ApprovalId, [string]$Reason, [bool]$WritesStarted = $false)
    $message = "Approval $ApprovalId was invalidated because material state changed after the preview.`n$Reason"
    $message += if ($WritesStarted) { "`nRemote writes may have occurred; see the partial-state diagnostic." } else { "`nNo remote writes were performed." }
    $message += "`nExecution left evidence.json, body.md, plan.json, and preview.md unchanged.`nIf this change is intentional, ask me to refresh the PR preview."
    $marker = [ordered]@{ approval_id = $ApprovalId; reason = $Reason }
    [System.IO.File]::WriteAllText((Get-ApprovalInvalidationPath $PlanFile), ($marker | ConvertTo-Json -Depth 4), $script:Utf8)
    throw $message
}
function Get-PrDriftDiagnostic { param($Approved, $Current)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(@{ label = 'Approved'; value = $Approved }, @{ label = 'Current'; value = $Current })) {
        $value = $entry.value
        $lines.Add("$($entry.label) snapshot:")
        $lines.Add("- HEAD: $($value.head_sha)")
        $lines.Add("- Base: $($value.base) ($($value.base_sha))")
        $lines.Add("- Commits: $($value.commit_count)")
        $lines.Add("- Changed files: $($value.changed_file_count)")
    }
    foreach ($name in @('repository', 'head_repository', 'head', 'head_remote', 'remote_branch', 'remote_sha', 'merge_base', 'assignee', 'template_path')) {
        $before = ConvertTo-Json -InputObject $Approved.$name -Depth 8 -Compress
        $after = ConvertTo-Json -InputObject $Current.$name -Depth 8 -Compress
        if ($before -cne $after) { $lines.Add("- ${name}: $before -> $after") }
    }
    if ([bool]$Approved.existing_pr -ne [bool]$Current.existing_pr) {
        $lines.Add("- Existing PR present: $([bool]$Approved.existing_pr) -> $([bool]$Current.existing_pr)")
    } elseif ($Approved.existing_pr) {
        foreach ($name in @('number', 'url', 'state', 'title', 'draft', 'head_sha', 'base_sha', 'assignees')) {
            $before = ConvertTo-Json -InputObject $Approved.existing_pr.$name -Depth 4 -Compress
            $after = ConvertTo-Json -InputObject $Current.existing_pr.$name -Depth 4 -Compress
            if ($before -cne $after) { $lines.Add("- PR ${name}: $before -> $after") }
        }
        if ($Approved.existing_pr.body -cne $Current.existing_pr.body) { $lines.Add('- PR body: complete body differs from the approved snapshot.') }
    }
    return $lines -join "`n"
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
