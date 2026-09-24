param(
    [Parameter(Mandatory)][string]$EvidenceFile,
    [Parameter(Mandatory)][string]$BodyFile,
    [Parameter(Mandatory)][string]$Title,
    [switch]$Draft
)
. (Join-Path $PSScriptRoot 'pr-common.ps1')

try {
    $root = (Invoke-Git @('rev-parse', '--show-toplevel')).Text.Trim()
    $evidencePath = Assert-ScratchPath $EvidenceFile $root
    $bodyPath = Assert-ScratchPath $BodyFile $root
    $planPath = Join-Path (Split-Path -Parent $evidencePath) 'plan.json'
    $previewPath = Join-Path (Split-Path -Parent $evidencePath) 'preview.md'
    if (Test-Path -LiteralPath (Get-ApprovalInvalidationPath $planPath)) {
        throw 'This approval transaction is invalidated. Preserve its artifacts. Only an explicit refresh request may start preparation in a new scratch workspace.'
    }
    # A failed re-plan must not leave an earlier plan/preview looking current.
    foreach ($stalePath in @($planPath, $previewPath)) {
        if (Test-Path -LiteralPath $stalePath) { Remove-Item -LiteralPath $stalePath -Force }
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8 | ConvertFrom-Json
    $body = [System.IO.File]::ReadAllText($bodyPath, $script:Utf8)
    if (-not $Title.Trim() -or -not $body.Trim()) { throw 'PR title and body must both be nonempty.' }
    if ($body.Contains('diffhunk://')) { throw 'PR body contains a non-portable diffhunk reference.' }
    if (-not $evidence.template_path) { Assert-PrBodyStructure $body }
    Assert-PrThemeCoverage $evidence $body
    if ($Draft -and $evidence.existing_pr -and -not $evidence.existing_pr.draft) { throw 'An existing ready PR cannot be converted to draft by this workflow.' }
    $action = [string]$evidence.action
    $repository = [string]$evidence.repository
    $base = [string]$evidence.base
    $head = [string]$evidence.remote_branch
    $headRepository = [string]$evidence.head_repository
    $assignee = [string]$evidence.assignee
    $pushRequired = [bool]$evidence.push_required
    $existingPrUrl = if ($evidence.existing_pr) { [string]$evidence.existing_pr.url } else { $null }
    $commitCount = [int]$evidence.commit_count
    $changedFileCount = [int]$evidence.changed_file_count
    $assigned = $evidence.existing_pr -and @($evidence.existing_pr.assignees) -contains $evidence.assignee
    $assignmentWrite = -not $assigned
    $metadata = if (-not $evidence.existing_pr) { 'CREATE' } elseif ($evidence.existing_pr.title -cne $Title -or $evidence.existing_pr.body -cne $body) { 'UPDATE' } else { 'NONE' }
    $plannedDraft = if ($evidence.existing_pr) { [bool]$evidence.existing_pr.draft } else { [bool]$Draft }
    $writes = [System.Collections.Generic.List[string]]::new()
    if ($pushRequired) { $writes.Add("Normal push to $($evidence.head_remote)/$head") }
    if ($metadata -eq 'CREATE') { $writes.Add('Create PR with the title and complete body below') }
    if ($metadata -eq 'UPDATE') { $writes.Add('Edit PR with the title and complete body below') }
    if ($assignmentWrite) { $writes.Add("Assign $assignee") }
    $replaceBody = if ($evidence.existing_pr -and $metadata -eq 'UPDATE') { 'Yes, the entire current body' } else { 'No' }
    $titleChange = -not $evidence.existing_pr -or $evidence.existing_pr.title -cne $Title
    $bodyChange = -not $evidence.existing_pr -or $evidence.existing_pr.body -cne $body
    $plan = [ordered]@{
        schema = 'codebeltnet/git-remote-pr/plan/3'
        evidence_file = $evidencePath
        evidence_hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
        snapshot_key = Get-PrSnapshotKey $evidence
        body_file = $bodyPath
        body_hash = (Get-FileHash -LiteralPath $bodyPath -Algorithm SHA256).Hash
        title = $Title
        draft = $plannedDraft
        action = $action
        repository = $repository
        base = $base
        head = $head
        head_repository = $headRepository
        assignee = $assignee
        push_required = $pushRequired
        metadata_write = $metadata
        assignment_write = $assignmentWrite
        existing_pr_number = if ($evidence.existing_pr) { $evidence.existing_pr.number } else { $null }
        existing_pr_url = $existingPrUrl
        commit_count = $commitCount
        changed_file_count = $changedFileCount
        preview_file = $previewPath
    }
    $preview = @(
        "# $action PR preview"
        ''
        'Approval ID: {{APPROVAL_ID}}'
        ''
        "- Repository: $repository"
        "- Comparison: $base <- ${headRepository}:$head"
        "- State: $(if ($plannedDraft) { 'draft' } else { 'ready' })"
        "- Commits: $commitCount; changed files: $changedFileCount; assignee: $assignee"
        "- Push required: $pushRequired"
        "- Existing PR: $(if ($existingPrUrl) { $existingPrUrl } else { 'None' })"
        "- Replace body: $replaceBody"
        "- Changes: title=$titleChange; body=$bodyChange; assignment=$assignmentWrite"
        "- Planned writes: $(if ($writes.Count) { $writes -join '; ' } else { 'None; verify already up to date' })"
        ''
        '## Proposed title'
        ''
        $Title
        ''
        '## Proposed body'
        ''
    ) -join "`n"
    $preview += "`n" + $body + "`n`nTo approve this exact preview, reply: approve {{APPROVAL_ID}}"
    $plan.review_hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($script:Utf8.GetBytes($preview)))
    $plan.approval_id = Get-PlanApprovalId $plan
    $preview = Set-PrPreviewApprovalSlots $preview '{{APPROVAL_ID}}' $plan.approval_id
    [System.IO.File]::WriteAllText($previewPath, $preview, $script:Utf8)
    $plan.preview_hash = (Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), $script:Utf8)
    $plan | ConvertTo-Json -Depth 8
} catch {
    Write-PrFailure $_.Exception.Message
    exit 1
}
