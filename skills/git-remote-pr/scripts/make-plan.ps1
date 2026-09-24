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
    # A failed re-plan must not leave an earlier plan/preview looking current.
    foreach ($stalePath in @($planPath, $previewPath)) {
        if (Test-Path -LiteralPath $stalePath) { Remove-Item -LiteralPath $stalePath -Force }
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8 | ConvertFrom-Json
    $body = [System.IO.File]::ReadAllText($bodyPath, $script:Utf8)
    if (-not $Title.Trim() -or -not $body.Trim()) { throw 'PR title and body must both be nonempty.' }
    if ($body.Contains('diffhunk://')) { throw 'PR body contains a non-portable diffhunk reference.' }
    Assert-PrThemeCoverage $evidence $body
    if ($Draft -and $evidence.existing_pr -and -not $evidence.existing_pr.draft) { throw 'An existing ready PR cannot be converted to draft by this workflow.' }
    $assigned = $evidence.existing_pr -and @($evidence.existing_pr.assignees) -contains $evidence.assignee
    $metadata = if (-not $evidence.existing_pr) { 'CREATE' } elseif ($evidence.existing_pr.title -cne $Title -or $evidence.existing_pr.body -cne $body) { 'UPDATE' } else { 'NONE' }
    $plannedDraft = if ($evidence.existing_pr) { [bool]$evidence.existing_pr.draft } else { [bool]$Draft }
    $plan = [ordered]@{
        schema = 'codebeltnet/git-remote-pr/plan/1'
        evidence_file = $evidencePath
        evidence_hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
        snapshot_key = Get-PrSnapshotKey $evidence
        body_file = $bodyPath
        body_hash = (Get-FileHash -LiteralPath $bodyPath -Algorithm SHA256).Hash
        title = $Title
        draft = $plannedDraft
        approval_key = Get-PlanApprovalKey $Title $plannedDraft
        action = $evidence.action
        repository = $evidence.repository
        base = $evidence.base
        head = $evidence.remote_branch
        head_repository = $evidence.head_repository
        assignee = $evidence.assignee
        push_required = [bool]$evidence.push_required
        metadata_write = $metadata
        assignment_write = -not $assigned
        existing_pr_url = if ($evidence.existing_pr) { $evidence.existing_pr.url } else { $null }
        commit_count = $evidence.commit_count
        changed_file_count = $evidence.changed_file_count
        preview_file = $previewPath
    }
    $writes = [System.Collections.Generic.List[string]]::new()
    if ($plan.push_required) { $writes.Add("Normal push to $($evidence.head_remote)/$($plan.head)") }
    if ($metadata -eq 'CREATE') { $writes.Add('Create PR with the title and complete body below') }
    if ($metadata -eq 'UPDATE') { $writes.Add('Edit PR with the title and complete body below') }
    if ($plan.assignment_write) { $writes.Add("Assign $($plan.assignee)") }
    $replaceBody = if ($evidence.existing_pr -and $metadata -eq 'UPDATE') { 'Yes, the entire current body' } else { 'No' }
    $titleChange = -not $evidence.existing_pr -or $evidence.existing_pr.title -cne $Title
    $bodyChange = -not $evidence.existing_pr -or $evidence.existing_pr.body -cne $body
    $preview = @(
        "# $($plan.action) PR preview"
        ''
        "- Repository: $($plan.repository)"
        "- Comparison: $($plan.base) <- $($plan.head_repository):$($plan.head)"
        "- State: $(if ($plannedDraft) { 'draft' } else { 'ready' })"
        "- Commits: $($plan.commit_count); changed files: $($plan.changed_file_count); assignee: $($plan.assignee)"
        "- Push required: $($plan.push_required)"
        "- Existing PR: $(if ($plan.existing_pr_url) { $plan.existing_pr_url } else { 'None' })"
        "- Replace body: $replaceBody"
        "- Changes: title=$titleChange; body=$bodyChange; assignment=$($plan.assignment_write)"
        "- Planned writes: $(if ($writes.Count) { $writes -join '; ' } else { 'None; verify already up to date' })"
        ''
        '## Proposed title'
        ''
        $Title
        ''
        '## Proposed body'
        ''
    ) -join "`n"
    [System.IO.File]::WriteAllText($previewPath, ($preview + "`n" + $body), $script:Utf8)
    [System.IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), $script:Utf8)
    $plan | ConvertTo-Json -Depth 8
} catch {
    Write-PrFailure $_.Exception.Message
    exit 1
}
