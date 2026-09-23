#!/usr/bin/env pwsh
# Focused deterministic content and recovery regressions. Does not execute model-backed evals.
[CmdletBinding()]
param([string]$Ref)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$skillPath = 'skills/agent-smith'
$checks = 0

function Read-RepositoryText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        return [System.IO.File]::ReadAllText((Join-Path $repoRoot $Path))
    }
    $content = & git -C $repoRoot show "${Ref}:$Path"
    if ($LASTEXITCODE -ne 0) { throw "Cannot read '$Path' at '$Ref' (exit $LASTEXITCODE)." }
    return $content -join "`n"
}

function Assert-Contains {
    param([string]$Name, [string]$Content, [string]$Needle)
    if (-not $Content.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "$Name is missing required guidance: $Needle"
    }
    $script:checks++
}

$skill = Read-RepositoryText "$skillPath/SKILL.md"
$reference = Read-RepositoryText "$skillPath/references/dotnet-editorconfig-conformance.md"
$skillAuthoring = Read-RepositoryText "$skillPath/references/skill-authoring.md"
$automation = Read-RepositoryText "$skillPath/references/automation.md"
$core = Read-RepositoryText "$skillPath/references/core-principles.md"
$api = Read-RepositoryText "$skillPath/references/api-design-and-compatibility.md"
$delivery = Read-RepositoryText "$skillPath/references/delivery-and-repositories.md"
$agentic = Read-RepositoryText "$skillPath/references/agentic-engineering.md"
$evals = Read-RepositoryText "$skillPath/evals/evals.json"
$repair = Read-RepositoryText "$skillPath/scripts/repair-roslyn-multiproject-artifacts.ps1"
$repairTests = Read-RepositoryText "$skillPath/scripts/test-repair-roslyn-multiproject-artifacts.ps1"

# Mandatory routing remains in the entry point; procedures live in the loaded references.
Assert-Contains 'SKILL.md' $skill 'read `references/skill-authoring.md` before recommending changes or editing'
Assert-Contains 'SKILL.md' $skill 'read both `references/dotnet.md` and `references/dotnet-editorconfig-conformance.md` before the first formatter command'
Assert-Contains 'SKILL.md' $skill 'If one cannot be loaded, fail with its path'
foreach ($name in @('automation', 'agentic-engineering', 'core-principles')) {
    Assert-Contains 'SKILL.md' $skill "references/$name.md"
}
if ($skill -match '--severity|--verify-no-changes|whole-document-namespace-conversion|repair-roslyn-multiproject-artifacts\.ps1') {
    throw 'Specialized conformance commands and recovery mechanics must stay behind reference routing.'
}
if (($skill -split '\s+').Count -ge 5000) { throw 'SKILL.md must remain below 5,000 words.' }

$orderedPolicy = @(
    '1. Explicit task constraints.',
    '2. Local repository policy, established conventions, and observed repository evidence.',
    '3. Engineering operating defaults.',
    '4. Generic ecosystem convention.'
)
$profile = [regex]::Match($skill, '(?ms)^## Engineering operating profile\r?\n(?<body>.*?)(?=^## |\z)').Groups['body'].Value
$actualPolicy = @([regex]::Matches($profile, '(?m)^\d+\..*$') | ForEach-Object { $_.Value.TrimEnd() })
if (($actualPolicy -join "`n") -cne ($orderedPolicy -join "`n")) {
    throw 'Operating profile must contain exactly the four declared precedence levels in order.'
}
$checks++
foreach ($value in @('Consistency', 'Quality', 'Vigilance', 'Due diligence')) {
    Assert-Contains 'SKILL.md' $skill "**${value}:**"
}
Assert-Contains 'SKILL.md' $skill 'Be concise, precise, natural, and technically defensible.'
Assert-Contains 'SKILL.md' $skill 'those local conventions take precedence'
Assert-Contains 'core-principles.md' $core 'Never manufacture success.'
foreach ($state in @('Unsupported', 'Unvalidated', 'Skipped', 'Failed', 'Successful')) {
    Assert-Contains 'core-principles.md' $core "| $state |"
}
Assert-Contains 'core-principles.md' $core 'Propagate non-zero failures'
Assert-Contains 'core-principles.md' $core 'Never silently skip required validation'

Assert-Contains 'api-design-and-compatibility.md' $api "Design the contract from the consumer's required capability"
Assert-Contains 'api-design-and-compatibility.md' $api 'Interface Segregation'
Assert-Contains 'api-design-and-compatibility.md' $api 'field, property, endpoint, member, event, configuration option, and serialized element'
Assert-Contains 'api-design-and-compatibility.md' $api 'Uniform Interface'
Assert-Contains 'api-design-and-compatibility.md' $api 'Do not insist on HATEOAS for every HTTP API.'
Assert-Contains 'api-design-and-compatibility.md' $api '`202 Accepted` with a status resource'
Assert-Contains 'delivery-and-repositories.md' $delivery '| Responsibility | Package | Application |'
Assert-Contains 'delivery-and-repositories.md' $delivery 'never compile or rebuild the product'
Assert-Contains 'delivery-and-repositories.md' $delivery 'scaled trunk-based development'
Assert-Contains 'delivery-and-repositories.md' $delivery 'Do not invent a universal OS matrix'
Assert-Contains 'delivery-and-repositories.md' $delivery 'Follow shared tooling and configuration that the repository actually uses.'
Assert-Contains 'delivery-and-repositories.md' $delivery 'If local repository policy requires Windows and Linux'
Assert-Contains 'automation.md' $automation '1. Use a simple native command'
Assert-Contains 'automation.md' $automation '2. Use PowerShell 7'
Assert-Contains 'automation.md' $automation '3. Use C#/.NET'
Assert-Contains 'automation.md' $automation 'Reuse or determinism alone does not require rewriting a small, sound script.'
Assert-Contains 'automation.md' $automation 'Microsoft''s official .NET support policy'
Assert-Contains 'agentic-engineering.md' $agentic 'Model selection is an engineering decision, not a personal preference.'
foreach ($requirement in @('Lightweight/mechanical', 'Versatile/implementation-oriented', 'Powerful/deep-reasoning', 'bounded concurrency', 'shared mutations', 'deterministic aggregation', 'Propagate cancellation', 'rate limits', 'elapsed time', 'total cost', 'error rate', 'result quality')) {
    Assert-Contains 'agentic-engineering.md' $agentic $requirement
}
Assert-Contains 'agentic-engineering.md' $agentic 'do not create more agents merely to obtain more opinions'
Assert-Contains 'skill-authoring.md' $skillAuthoring 'Batch independent retrieval through one multi-call request where the tool supports it.'
Assert-Contains 'skill-authoring.md' $skillAuthoring 'Load `automation.md`'
Assert-Contains 'skill-authoring.md' $skillAuthoring '## Required authoring feedback'
Assert-Contains 'skill-authoring.md' $skillAuthoring 'Editing a skill does not authorize model-backed runs'
Assert-Contains 'skill-authoring.md' $skillAuthoring 'Optimizing skill descriptions'
Assert-Contains 'skill-authoring.md' $skillAuthoring 'Evaluating skill output quality'

# Preserve the prior conformance/recovery checks at their authoritative location.
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference 'dotnet format style "<solution-or-project>"'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference '`dotnet format` defaults to severity `warn`'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference 'Every invocation must also state the resolved `--severity` explicitly.'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference '--verify-no-changes'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference 'carry it through discovery, investigation, recovery retries, and final verification without omission'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference 'Never invoke it in mutating mode.'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference 'Directory application is all-or-nothing at preflight'
Assert-Contains 'dotnet-editorconfig-conformance.md' $reference "git grep -n -F 'Unmerged change from project'"
Assert-Contains 'evals.json' $evals 'finish fixing all IDE0161 findings in MultiTargeted.sln'
Assert-Contains 'evals.json' $evals 'fetches twelve independent service endpoints sequentially'
Assert-Contains 'repair script' $repair 'function Test-LinePrefix'
Assert-Contains 'repair script' $repair "pattern = 'whole-document-namespace-conversion'"
Assert-Contains 'repair script' $repair "pattern = 'unrecognized'"
Assert-Contains 'repair script' $repair '$Apply -and -not $hasUnsafeArtifact'
Assert-Contains 'repair tests' $repairTests 'Directory apply partially repaired a file despite an unsafe sibling artifact.'
Assert-Contains 'repair tests' $repairTests 'An unsupported localized artifact should fail closed.'

# Check the whole reference graph and prose, not only the changed file list.
$paths = if ([string]::IsNullOrWhiteSpace($Ref)) {
    Get-ChildItem -LiteralPath (Join-Path $repoRoot $skillPath) -Recurse -File |
        Where-Object Extension -eq '.md' |
        ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/') }
} else {
    $listed = & git -C $repoRoot ls-tree -r --name-only $Ref -- $skillPath
    if ($LASTEXITCODE -ne 0) { throw "Cannot enumerate skill at '$Ref'." }
    $listed | Where-Object { $_.EndsWith('.md') }
}
foreach ($path in $paths) {
    $text = Read-RepositoryText $path
    if ($text -match '(?i)\brepository[- ]famil(?:y|ies)\b|\bfamily (?:conventions?|policy|defaults?|workflow|membership|template)\b') {
        throw "Removed policy-layer terminology remains in $path."
    }
    $checks++
    if ($text.Contains([char]0x2014) -or $text -match '(?m)^\s*\*\s|Sacrifice grammar|Prefer clear fragments') {
        throw "Outdated writing convention in $path."
    }
    foreach ($match in [regex]::Matches($text, '`(?<path>(?:references/)?[a-z][a-z0-9-]*\.md)`')) {
        $relative = $match.Groups['path'].Value
        # Root repository artifacts such as AGENTS.md are excluded by this lowercase pattern.
        $parent = ($path -replace '/[^/]+$', '')
        $null = Read-RepositoryText "$parent/$relative"
        $checks++
    }
}
foreach ($path in $paths | Where-Object { $_ -like '*/references/*' }) {
    $relative = $path.Substring($skillPath.Length + 1)
    Assert-Contains 'SKILL.md reference routing' $skill $relative
}

$cases = ($evals | ConvertFrom-Json).evals
if ($evals -match '(?i)\brepository[- ]famil(?:y|ies)\b|\bfamily (?:conventions?|policy|defaults?|workflow|membership|template)\b') {
    throw 'Eval scenarios must exercise local repository evidence directly.'
}
$checks++
Assert-Contains 'eval 20' ($cases | Where-Object id -eq 20).prompt "AGENTS.md requires release tooling and tests on Windows and Linux"
Assert-Contains 'eval 20' (($cases | Where-Object id -eq 20).expectations -join "`n") "shared workflow configuration as the basis"
Assert-Contains 'eval 30' ($cases | Where-Object id -eq 30).prompt 'nothing in the current repository adopts that template or its conventions'
Assert-Contains 'eval 30' (($cases | Where-Object id -eq 30).expectations -join "`n") 'similar naming is not local evidence'
if ($cases.Count -ne 34 -or @($cases.id | Sort-Object -Unique).Count -ne 34) {
    throw 'Expected 14 preserved regression cases plus 20 judgement scenarios with unique IDs.'
}
foreach ($id in 1..34) {
    $case = @($cases | Where-Object id -eq $id)
    if ($case.Count -ne 1 -or [string]::IsNullOrWhiteSpace($case[0].prompt) -or [string]::IsNullOrWhiteSpace($case[0].expected_output) -or @($case[0].expectations).Count -lt 3) {
        throw "Eval $id must have a prompt, expected outcome, and at least three decision assertions."
    }
    $checks++
}

& pwsh -NoProfile -NonInteractive -File (Join-Path $repoRoot "$skillPath/scripts/test-repair-roslyn-multiproject-artifacts.ps1")
if ($LASTEXITCODE -ne 0) { throw "Roslyn artifact recovery regressions failed (exit $LASTEXITCODE)." }
Write-Output "All Agent Smith focused checks passed ($checks content/schema checks plus Roslyn recovery regressions)."
