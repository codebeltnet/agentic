$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pr-common.ps1')
$passes = 0
$valid = "This pull request improves review preparation. It preserves approval boundaries.`n`n**Workflow safety:**`n`n- Adds a reviewable plan.`n`n**Documentation:**`n`n- Clarifies approval."
$accepted = @(
    $valid
    $valid.Replace("`n", "`r`n")
    "`nThis pull request updates guidance.`n`n**Authoring conventions:**`n`n- Clarifies formatting.`n"
    "This pull request updates guidance.`nIt also covers examples.`n`n**Guidance:**`n`n- Adds examples."
    # Sentence, section, and bullet counts are guidance, not validation quotas.
    ($valid + "`n- Adds another outcome.`n- Covers another concern.`n- Includes another guarantee.")
    ($valid + ((1..7 | ForEach-Object { "`n`n**Concern ${_}:**`n`n- Updates behavior." }) -join ''))
    # Subjective quality and inventories belong to evals, not this shape validator.
    "Release v1 introduces helpers.`n`n**Implementation:**`n`n- Adds a.ps1, b.ps1, and c.ps1."
)
foreach ($body in $accepted) {
    Assert-PrBodyStructure $body
    $passes++
}
$rejected = @(
    @{ name = 'empty'; body = ''; error = 'opening prose paragraph' }
    @{ name = 'no opening'; body = "**Workflow:**`n`n- Adds behavior."; error = 'opening prose paragraph' }
    @{ name = 'bullet opening'; body = "- Opening inventory.`n`n**Workflow:**`n`n- Adds behavior."; error = 'opening prose paragraph' }
    @{ name = 'no themes'; body = 'This pull request improves review.'; error = 'thematic heading' }
    @{ name = 'multiple opening paragraphs'; body = "First paragraph.`n`nSecond paragraph.`n`n**Workflow:**`n`n- Adds behavior."; error = 'exactly one opening' }
    @{ name = 'ATX heading'; body = "Opening.`n`n## Workflow`n`n- Adds behavior."; error = 'headings must use' }
    @{ name = 'missing colon'; body = $valid.Replace('**Workflow safety:**', '**Workflow safety**'); error = 'headings must use' }
    @{ name = 'colon outside bold'; body = $valid.Replace('**Workflow safety:**', '**Workflow safety**:'); error = 'headings must use' }
    @{ name = 'alternate bold'; body = $valid.Replace('**Workflow safety:**', '__Workflow safety:__'); error = 'headings must use' }
    @{ name = 'empty heading'; body = $valid.Replace('**Workflow safety:**', '**:**'); error = 'headings must use' }
    @{ name = 'paragraph-only section'; body = $valid.Replace('- Adds a reviewable plan.', 'Adds a reviewable plan.'); error = 'only dash bullets' }
    @{ name = 'paragraph after bullet'; body = $valid.Replace('- Adds a reviewable plan.', "- Adds a reviewable plan.`n`nMore explanation."); error = 'only dash bullets' }
    @{ name = 'indented prose'; body = $valid.Replace('- Adds a reviewable plan.', "- Adds a reviewable plan.`n`n  More explanation."); error = 'only dash bullets' }
    @{ name = 'empty middle section'; body = $valid.Replace('- Adds a reviewable plan.', ''); error = 'needs at least one dash bullet' }
    @{ name = 'empty final section'; body = $valid + "`n`n**Assets:**"; error = 'needs at least one dash bullet' }
    @{ name = 'empty bullet'; body = $valid.Replace('- Adds a reviewable plan.', '- '); error = 'only dash bullets' }
    @{ name = 'asterisk bullet'; body = $valid.Replace('- Adds a reviewable plan.', '* Adds a reviewable plan.'); error = 'only dash bullets' }
    @{ name = 'numbered list'; body = $valid.Replace('- Adds a reviewable plan.', '1. Adds a reviewable plan.'); error = 'only dash bullets' }
    @{ name = 'final prose'; body = $valid + "`n`nIn summary, this improves review."; error = 'only dash bullets' }
    @{ name = 'changes summary'; body = $valid + "`n`n**Changes Summary:**`n`n- Repeats outcomes."; error = 'redundant final summary' }
    @{ name = 'summary of changes'; body = $valid + "`n`n**Summary of changes:**`n`n- Repeats outcomes."; error = 'redundant final summary' }
    @{ name = 'conclusion'; body = $valid + "`n`n**Conclusion:**`n`n- Repeats outcomes."; error = 'redundant final summary' }
)
foreach ($case in $rejected) {
    $message = $null
    try { Assert-PrBodyStructure $case.body } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $case.error) { throw "Body structure regression '$($case.name)': expected '$($case.error)', got '$message'." }
    $passes++
}
Write-Output "PASS: $passes PR body structure assertions."
