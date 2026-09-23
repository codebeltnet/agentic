param(
    [string]$OutputDirectory,
    [string]$Repository,
    [string]$Base
)
. (Join-Path $PSScriptRoot 'pr-common.ps1')

try {
    $inside = Invoke-Git @('rev-parse', '--is-inside-work-tree')
    if ($inside.Text.Trim() -ne 'true') { throw 'The current directory is not a Git working repository.' }
    $root = (Invoke-Git @('rev-parse', '--show-toplevel')).Text.Trim()
    $branch = (Invoke-Git @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowFailure)
    if ($branch.Code -ne 0 -or -not $branch.Text.Trim()) { throw 'Detached HEAD cannot be used as a PR head.' }
    $branch = $branch.Text.Trim()
    $dirty = (Invoke-Git @('status', '--porcelain=v1', '--untracked-files=all')).Text
    if ($dirty) { throw "Working tree contains uncommitted or untracked files. Commit them in a separate workflow before opening or updating a PR. No files were staged, committed, stashed, or discarded.`n$dirty" }
    $headSha = (Invoke-Git @('rev-parse', 'HEAD')).Text.Trim()
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("git-remote-pr-" + [guid]::NewGuid().ToString('N')) }
    $OutputDirectory = Assert-ScratchPath $OutputDirectory $root
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    Invoke-Gh @('auth', 'status') | Out-Null
    $viewer = Get-GhJson 'user'
    if (-not $viewer.login) { throw 'GitHub authentication did not return an account. Run gh auth login.' }

    $remoteNames = @((Invoke-Git @('remote')).Text -split "`n" | Where-Object { $_ })
    $remoteRepos = @{}
    foreach ($name in $remoteNames) {
        $url = (Invoke-Git @('config', '--get', "remote.$name.url")).Text.Trim()
        $parsed = Get-RemoteRepo $url
        if ($parsed) { $remoteRepos[$name] = $parsed }
    }
    $upstreamRemote = (Invoke-Git @('config', '--get', "branch.$branch.remote") -AllowFailure).Text.Trim()
    $mergeRef = (Invoke-Git @('config', '--get', "branch.$branch.merge") -AllowFailure).Text.Trim()
    $remoteBranch = if ($mergeRef -match '^refs/heads/(.+)$') { $Matches[1] } else { $branch }
    $headRemote = if ($upstreamRemote -and $remoteRepos.ContainsKey($upstreamRemote)) { $upstreamRemote } elseif ($remoteRepos.ContainsKey('origin')) { 'origin' } else { $remoteRepos.Keys | Sort-Object | Select-Object -First 1 }
    if (-not $headRemote) { throw 'No GitHub remote is configured for the current branch.' }
    $headRepo = $remoteRepos[$headRemote]
    $headMeta = Get-GhJson "repos/$headRepo"
    if (-not $headMeta.full_name) { throw "Cannot resolve GitHub head repository $headRepo." }
    if ($headMeta.permissions -and $headMeta.permissions.push -eq $false) { throw "Authenticated account $($viewer.login) cannot push to $headRepo." }
    $parentRepo = if ($headMeta.PSObject.Properties.Name -contains 'parent' -and $headMeta.parent) { [string]$headMeta.parent.full_name } else { $null }
    if (-not $Repository -and $headMeta.fork -and -not $parentRepo) { throw "Fork parent for $headRepo is ambiguous. Supply the canonical base repository with -Repository owner/repo." }
    $baseRepo = if ($Repository) { $Repository } elseif ($headMeta.fork) { $parentRepo } else { $headRepo }
    $baseMeta = Get-GhJson "repos/$baseRepo"
    if (-not $baseMeta.full_name) { throw "Cannot resolve GitHub base repository $baseRepo." }
    if ($baseMeta.permissions -and $baseMeta.permissions.pull -eq $false) { throw "Authenticated account $($viewer.login) cannot read $baseRepo or create a PR against it." }
    $baseRepo = [string]$baseMeta.full_name
    $baseBranch = if ($Base) { $Base } else { [string]$baseMeta.default_branch }
    if (-not $baseBranch) { throw 'GitHub did not identify the repository default branch. Supply an explicit base branch.' }
    if ($baseRepo -eq $headRepo -and $baseBranch -eq $remoteBranch) { throw 'The current branch is the resolved base branch.' }
    $assignable = Invoke-Gh @('api', "repos/$baseRepo/assignees/$($viewer.login)") -AllowFailure
    if ($assignable.Code -ne 0) { throw "Authenticated account $($viewer.login) is not assignable in $baseRepo. GitHub assignee preflight failed: $($assignable.Text)" }

    $baseRemote = $remoteRepos.Keys | Where-Object { $remoteRepos[$_] -eq $baseRepo } | Sort-Object | Select-Object -First 1
    if (-not $baseRemote) { $baseRemote = "https://github.com/$baseRepo.git" }
    Invoke-Git @('fetch', '--no-tags', $baseRemote, "refs/heads/$baseBranch") | Out-Null
    $baseSha = (Invoke-Git @('rev-parse', 'FETCH_HEAD')).Text.Trim()
    $mergeBase = (Invoke-Git @('merge-base', $baseSha, $headSha)).Text.Trim()
    $commitsRaw = (Invoke-Git @('log', '--reverse', '--format=%H%x00%B%x1e', "$mergeBase..$headSha")).Text
    $commits = @($commitsRaw -split [char]0x1e | Where-Object { $_.Trim() } | ForEach-Object {
        $entry = $_.Trim("`r", "`n") -split [char]0, 2
        [pscustomobject]@{ sha = $entry[0]; message = if ($entry.Count -gt 1) { $entry[1].TrimEnd() } else { '' } }
    })
    $names = (Invoke-Git @('diff', '--name-status', '-z', '-M', $mergeBase, $headSha)).Text
    $parts = $names -split [char]0
    $files = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $parts.Count -and $parts[$index];) {
        $status = $parts[$index++].Trim()
        if ($status -match '^[RC]') {
            $oldPath = $parts[$index++]
            $path = $parts[$index++]
        } else {
            $oldPath = $null
            $path = $parts[$index++]
        }
        $files.Add([pscustomobject]@{ status = $status; path = $path; old_path = $oldPath; binary = $false; additions = $null; deletions = $null; theme = $null })
    }
    if ($files.Count -eq 0) { throw "The $baseBranch...$remoteBranch comparison has no changed files. No PR will be written." }
    $stats = (Invoke-Git @('diff', '--numstat', '-z', '-M', $mergeBase, $headSha)).Text -split [char]0
    for ($index = 0; $index -lt $stats.Count -and $stats[$index];) {
        $record = $stats[$index++] -split "`t", 3
        if ($record.Count -lt 3) { throw 'Cannot parse Git diff --numstat output.' }
        $path = $record[2]
        if (-not $path) { $index++; $path = $stats[$index++] }
        foreach ($file in $files) {
            if ($file.path -ceq $path) {
                $file.binary = $record[0] -eq '-'
                if (-not $file.binary) { $file.additions = [int]$record[0]; $file.deletions = [int]$record[1] }
                break
            }
        }
    }
    $patch = (Invoke-Git @('diff', '--binary', '--no-ext-diff', '--full-index', '-M', $mergeBase, $headSha)).Text
    [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'final.patch'), $patch, $script:Utf8)

    $remoteSha = Get-RemoteSha $headRemote $remoteBranch
    if ($remoteSha -and $remoteSha -ne $headSha) {
        Invoke-Git @('fetch', '--no-tags', $headRemote, "refs/heads/$remoteBranch") | Out-Null
        $remoteCommit = (Invoke-Git @('rev-parse', 'FETCH_HEAD')).Text.Trim()
        if ($remoteCommit -ne $remoteSha -or (Invoke-Git @('merge-base', '--is-ancestor', $remoteCommit, $headSha) -AllowFailure).Code -ne 0) {
            throw "Remote branch $headRemote/$remoteBranch has diverged or is not a fast-forward ancestor of local HEAD. Resolve it separately; this skill never force pushes."
        }
    }
    $prs = @(Get-Pages "repos/$baseRepo/pulls?state=open&per_page=100")
    $matches = @($prs | Where-Object { $_.base.ref -ceq $baseBranch -and $_.head.ref -ceq $remoteBranch -and $_.head.repo.full_name -ieq $headRepo })
    if ($matches.Count -gt 1) { throw 'Multiple matching open PRs exist; resolve the ambiguity before writing.' }
    $existing = if ($matches.Count -eq 1) { $matches[0] } else { $null }
    $templatePaths = @((Invoke-Git @('ls-tree', '-r', '--name-only', $baseSha)).Text -split "`n" | Where-Object { $_ -match '^(?:\.github/|docs/)?(?i:pull_request_template)(?:/.*|\.md)$' })
    $defaultPaths = @('.github/PULL_REQUEST_TEMPLATE.md', '.github/pull_request_template.md', 'PULL_REQUEST_TEMPLATE.md', 'docs/PULL_REQUEST_TEMPLATE.md', 'docs/pull_request_template.md')
    $templatePath = $defaultPaths | Where-Object { $templatePaths -ccontains $_ } | Select-Object -First 1
    if (-not $templatePath -and $templatePaths.Count -eq 1) { $templatePath = $templatePaths[0] }
    if (-not $templatePath -and $templatePaths.Count -gt 1) { throw "Multiple PR templates exist without a default: $($templatePaths -join ', '). Ask which PR type to use." }
    if ($templatePath) {
        $template = (Invoke-Git @('show', "${baseSha}:$templatePath")).Text
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'template.md'), $template, $script:Utf8)
    }
    $evidence = [ordered]@{
        schema = 'codebeltnet/git-remote-pr/evidence/1'; repository = $baseRepo; head_repository = $headRepo
        head_remote = $headRemote; remote_branch = $remoteBranch; base = $baseBranch; head = $branch
        base_sha = $baseSha; head_sha = $headSha; remote_sha = $remoteSha; merge_base = $mergeBase
        push_required = $remoteSha -ne $headSha; assignee = [string]$viewer.login
        title = Get-PrTitle $remoteBranch; action = if ($existing) { 'UPDATE' } else { 'CREATE' }
        existing_pr = if ($existing) { [ordered]@{ number = $existing.number; url = $existing.html_url; state = $existing.state; title = $existing.title; body = $existing.body; draft = $existing.draft; head_sha = $existing.head.sha; base_sha = $existing.base.sha; assignees = @($existing.assignees | ForEach-Object { $_.login }) } } else { $null }
        template_path = $templatePath; commits = $commits; files = $files.ToArray()
        commit_count = $commits.Count; changed_file_count = $files.Count
    }
    $evidencePath = Join-Path $OutputDirectory 'evidence.json'
    [System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 20), $script:Utf8)
    [pscustomobject]@{ evidence = $evidencePath; patch = (Join-Path $OutputDirectory 'final.patch'); template = if ($templatePath) { Join-Path $OutputDirectory 'template.md' } else { $null }; action = $evidence.action; title = $evidence.title; commit_count = $evidence.commit_count; changed_file_count = $evidence.changed_file_count } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine($_.Exception.Message + "`n" + $_.ScriptStackTrace)
    exit 1
}
