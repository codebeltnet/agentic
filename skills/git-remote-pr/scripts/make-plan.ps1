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
    $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8 | ConvertFrom-Json
    $body = [System.IO.File]::ReadAllText($bodyPath, $script:Utf8)
    if (-not $Title.Trim() -or -not $body.Trim()) { throw 'PR title and body must both be nonempty.' }
    if ($body.Contains('diffhunk://')) { throw 'PR body contains a non-portable diffhunk reference.' }
    foreach ($file in $evidence.files) {
        if ([string]::IsNullOrWhiteSpace([string]$file.theme) -or -not $body.Contains([string]$file.theme)) { throw "Changed path '$($file.path)' lacks a theme represented in the body." }
    }
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
    }
    $planPath = Join-Path (Split-Path -Parent $evidencePath) 'plan.json'
    [System.IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), $script:Utf8)
    $plan | ConvertTo-Json -Depth 8
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
