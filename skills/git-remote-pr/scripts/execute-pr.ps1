param(
    [Parameter(Mandatory)][string]$PlanFile,
    [string]$ApprovalId,
    [switch]$Approved
)
. (Join-Path $PSScriptRoot 'pr-common.ps1')

$approvalMatched = $false
$writesStarted = $false
trap {
    $message = $_.Exception.Message
    if ($approvalMatched -and -not (Test-Path -LiteralPath (Get-ApprovalInvalidationPath $PlanFile))) {
        try { Stop-PrApproval $PlanFile $ApprovalId $message } catch { $message = $_.Exception.Message }
    }
    Write-PrFailure $message
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ApprovalId)) { throw 'An exact approval ID is required: -ApprovalId APR-... from the presented preview. -Approved alone and generic conversational approval do not authorize execution.' }
if (-not (Test-Path -LiteralPath $PlanFile -PathType Leaf)) { throw 'Prepared plan file is missing.' }
$plan = Get-Content -LiteralPath $PlanFile -Raw -Encoding utf8 | ConvertFrom-Json
$storedId = $plan.PSObject.Properties['approval_id']
if (-not $storedId -or $ApprovalId -cne [string]$storedId.Value) {
    throw 'Approval ID does not match this prepared plan. Use only the exact approval phrase from the existing preview; do not regenerate it.'
}
$root = (Invoke-Git @('rev-parse', '--show-toplevel')).Text.Trim()
$null = Assert-ScratchPath $PlanFile $root
if (Test-Path -LiteralPath (Get-ApprovalInvalidationPath $PlanFile)) {
    throw "Approval $ApprovalId is already invalidated. No remote writes were performed. Only an explicit refresh request may start a new approval transaction in a new scratch workspace."
}
$approvalMatched = $true
if ((Get-PlanApprovalId $plan) -cne $ApprovalId) { throw 'Prepared write intent changed after the preview; the approval ID no longer matches.' }
$Title = [string]$plan.title
if ([string]::IsNullOrWhiteSpace($Title)) { throw 'Prepared title is empty.' }
if ($plan.draft -isnot [bool]) { throw 'Prepared draft state is invalid.' }
$Draft = [bool]$plan.draft
$EvidenceFile = [string]$plan.evidence_file
$BodyFile = [string]$plan.body_file
$PreviewFile = [string]$plan.preview_file
$previewHash = $plan.PSObject.Properties['preview_hash']
if ([string]::IsNullOrWhiteSpace($PreviewFile)) { throw 'Prepared preview file is missing.' }
if (-not $previewHash -or [string]::IsNullOrWhiteSpace([string]$previewHash.Value)) {
    throw 'Prepared preview binding is missing.'
}
$PreviewHash = [string]$previewHash.Value
if (-not (Test-Path -LiteralPath $EvidenceFile -PathType Leaf)) { throw 'Prepared evidence file is missing.' }
if (-not (Test-Path -LiteralPath $BodyFile -PathType Leaf)) { throw 'Prepared body file is missing.' }
$expected = Get-Content -LiteralPath $EvidenceFile -Raw -Encoding utf8 | ConvertFrom-Json
$body = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyFile).Path, $script:Utf8)
if (-not $body.Trim()) { throw 'PR description is empty.' }
if ($body.Contains('diffhunk://')) { throw 'PR description contains non-portable diffhunk references.' }
Assert-PrThemeCoverage $expected $body
$null = Assert-ScratchPath $EvidenceFile $root
$null = Assert-ScratchPath $BodyFile $root
$null = Assert-ScratchPath $PreviewFile $root
if (-not (Test-Path -LiteralPath $PreviewFile -PathType Leaf)) { throw 'Prepared preview file is missing.' }
if ((Get-FileHash -LiteralPath $PreviewFile -Algorithm SHA256).Hash -cne $PreviewHash) {
    throw 'Prepared preview changed after planning.'
}
if ((Get-FileHash -LiteralPath $EvidenceFile -Algorithm SHA256).Hash -cne $plan.evidence_hash -or (Get-FileHash -LiteralPath $BodyFile -Algorithm SHA256).Hash -cne $plan.body_hash -or (Get-PrSnapshotKey $expected) -cne $plan.snapshot_key) {
    throw 'Prepared body or evidence changed after the preview.'
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("git-remote-pr-recheck-" + [guid]::NewGuid().ToString('N'))
$number = $null
$url = $null
$pushDone = $false
try {
    $args = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'prepare-pr.ps1'), '-OutputDirectory', $work, '-Repository', $expected.repository, '-Base', $expected.base)
    $prepared = Invoke-Tool pwsh $args
    $freshPath = (ConvertFrom-Json -InputObject $prepared.Text).evidence
    $fresh = Get-Content -LiteralPath $freshPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ((Get-PrSnapshotKey $expected) -cne (Get-PrSnapshotKey $fresh)) {
        Stop-PrApproval $PlanFile $ApprovalId (Get-PrDriftDiagnostic $expected $fresh)
    }
    if ($Draft -and $expected.existing_pr -and -not $expected.existing_pr.draft) { throw 'An existing ready PR cannot be converted to draft by this workflow.' }
    if ($fresh.push_required) {
        $writesStarted = $true
        Invoke-Git @('push', $fresh.head_remote, "HEAD:refs/heads/$($fresh.remote_branch)") | Out-Null
        $pushDone = $true
    }
    $remoteSha = Get-RemoteSha $fresh.head_remote $fresh.remote_branch
    if ($remoteSha -cne $fresh.head_sha) { throw "Remote head verification failed: expected $($fresh.head_sha), got $remoteSha." }
    $afterPath = Join-Path ([System.IO.Path]::GetTempPath()) ("git-remote-pr-after-" + [guid]::NewGuid().ToString('N'))
    try {
        $afterResult = Invoke-Tool pwsh @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'prepare-pr.ps1'), '-OutputDirectory', $afterPath, '-Repository', $expected.repository, '-Base', $expected.base)
        $after = Get-Content -LiteralPath ((ConvertFrom-Json -InputObject $afterResult.Text).evidence) -Raw -Encoding utf8 | ConvertFrom-Json
        if ($after.head_sha -cne $fresh.head_sha -or $after.base_sha -cne $fresh.base_sha -or $after.merge_base -cne $fresh.merge_base -or $after.changed_file_count -ne $fresh.changed_file_count) {
            throw 'The effective comparison changed after push. Stop before writing PR metadata.'
        }
        for ($i = 0; $i -lt $fresh.files.Count; $i++) {
            if ($after.files[$i].path -cne $fresh.files[$i].path -or $after.files[$i].status -cne $fresh.files[$i].status) { throw 'The effective comparison changed after push.' }
        }
        if ([bool]$after.existing_pr -ne [bool]$fresh.existing_pr) {
            throw 'PR state changed after push. Stop before metadata writes.'
        }
        if ($fresh.existing_pr -and ($after.existing_pr.number -ne $fresh.existing_pr.number -or $after.existing_pr.title -cne $fresh.existing_pr.title -or $after.existing_pr.body -cne $fresh.existing_pr.body -or $after.existing_pr.draft -ne $fresh.existing_pr.draft -or $after.existing_pr.head_sha -cne $fresh.head_sha -or (@($after.existing_pr.assignees) -join ',') -cne (@($fresh.existing_pr.assignees) -join ','))) {
            throw 'PR state changed after push. Stop before metadata writes.'
        }
    } finally {
        if (Test-Path -LiteralPath $afterPath) { Remove-Item -LiteralPath $afterPath -Recurse -Force }
    }

    $hasAssignee = $fresh.existing_pr -and @($fresh.existing_pr.assignees) -contains $fresh.assignee
    $metadataChanged = -not $fresh.existing_pr -or $fresh.existing_pr.title -cne $Title -or $fresh.existing_pr.body -cne $body
    if ($fresh.existing_pr) {
        $number = [int]$fresh.existing_pr.number
        $url = [string]$fresh.existing_pr.url
        if ($metadataChanged) {
            $writesStarted = $true
            Invoke-Gh @('pr', 'edit', [string]$number, '--repo', $fresh.repository, '--title', $Title, '--body-file', $BodyFile) | Out-Null
        }
        $result = if ($metadataChanged -or $pushDone -or -not $hasAssignee) { 'updated' } else { 'already up to date' }
    } else {
        $createArgs = @('pr', 'create', '--repo', $fresh.repository, '--base', $fresh.base, '--head', "$($fresh.head_repository.Split('/')[0]):$($fresh.remote_branch)", '--title', $Title, '--body-file', $BodyFile)
        if ($Draft) { $createArgs += '--draft' }
        $writesStarted = $true
        $created = Invoke-Gh $createArgs
        $url = $created.Text.Trim()
        if ($url -notmatch '/pull/(\d+)$') { throw "PR creation returned an unexpected URL: $url" }
        $number = [int]$Matches[1]
        $result = 'created'
    }
    if (-not $hasAssignee) {
        $writesStarted = $true
        Invoke-Gh @('pr', 'edit', [string]$number, '--repo', $fresh.repository, '--add-assignee', $fresh.assignee) | Out-Null
    }

    $pr = Get-GhJson "repos/$($fresh.repository)/pulls/$number"
    if ($pr.base.ref -cne $fresh.base -or $pr.head.ref -cne $fresh.remote_branch -or $pr.head.repo.full_name -ine $fresh.head_repository) { throw 'Post-write verification: PR base or head differs from the intended branch pair.' }
    if ($pr.title -cne $Title -or $pr.body -cne $body) { throw 'Post-write verification: persisted title or complete body differs from the prepared content.' }
    $expectedDraft = if ($fresh.existing_pr) { [bool]$fresh.existing_pr.draft } else { [bool]$Draft }
    if ([bool]$pr.draft -ne $expectedDraft) { throw 'Post-write verification: PR draft/ready state differs from the plan.' }
    if ($pr.head.sha -cne $fresh.head_sha) { throw 'Post-write verification: GitHub PR head SHA differs from local HEAD.' }
    $issue = Get-GhJson "repos/$($fresh.repository)/issues/$number"
    if (@($issue.assignees | ForEach-Object { $_.login }) -notcontains $fresh.assignee) { throw "Post-write verification: $($fresh.assignee) is not assigned." }
    $prFiles = @(Get-Pages "repos/$($fresh.repository)/pulls/$number/files?per_page=100")
    if ($prFiles.Count -ne $fresh.files.Count) { throw "Post-write verification: GitHub lists $($prFiles.Count) files, but local base...head lists $($fresh.files.Count)." }
    $statusMap = @{ A = 'added'; M = 'modified'; D = 'removed'; R = 'renamed'; C = 'copied'; T = 'changed' }
    foreach ($file in $fresh.files) {
        $match = @($prFiles | Where-Object { $_.filename -ceq $file.path })
        if ($match.Count -ne 1) { throw "Post-write verification: changed path '$($file.path)' is missing or duplicated on GitHub." }
        $kind = $file.status.Substring(0, 1)
        if ($statusMap.ContainsKey($kind) -and $match[0].status -cne $statusMap[$kind]) { throw "Post-write verification: status differs for '$($file.path)'." }
        if ($kind -eq 'R' -and $match[0].previous_filename -cne $file.old_path) { throw "Post-write verification: rename source differs for '$($file.path)'." }
    }
    [pscustomobject]@{ result = $result; url = $url; title = $Title; base = $fresh.base; head = $fresh.remote_branch; assignee = $fresh.assignee; commit_count = $fresh.commit_count; changed_file_count = $fresh.changed_file_count } | ConvertTo-Json -Compress
} catch {
    $message = $_.Exception.Message
    if (-not (Test-Path -LiteralPath (Get-ApprovalInvalidationPath $PlanFile))) {
        try { Stop-PrApproval $PlanFile $ApprovalId $message $writesStarted } catch { $message = $_.Exception.Message }
    }
    $partial = if ($url) { "PR URL: $url. " } elseif ($pushDone) { 'Branch push succeeded. ' } else { '' }
    Write-PrFailure ($partial + $message)
    exit 1
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
