# Real package preparation with a fake model catalog; never launches a provider.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('change-impact-workspace-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($workspace)
function Assert-True($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    $catalog = Join-Path $workspace 'models.json'
    [IO.File]::WriteAllText($catalog, '{"models":[{"id":"fixture-model"}]}')
    $prompt = & (Join-Path $scriptsRoot 'prepare-skill-evals.ps1') -Skill dotnet-change-impact -Eval 9 -Runner github-copilot -Model fixture-model -ModelCatalogPath $catalog -OutputRoot $workspace -PassThru
    $package = Split-Path -Parent $prompt
    $handoff = [IO.File]::ReadAllText($prompt)
    Assert-True ($handoff.Contains('MUST read and follow the exact packaged `tools/skill-creator/agents/grader.md`')) 'Handoff must require the exact packaged grader before grading.'
    $manifest = Get-Content (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
    $heads = @(); $diffs = @(); $refs = @()
    foreach ($arm in @('with_skill', 'without_skill')) {
        $repo = Join-Path (Split-Path -Parent (Join-Path $package $manifest.evals[0].runs.$arm.run_manifest)) 'repo'
        Assert-True (Test-Path (Join-Path $repo '.git') -PathType Container) 'Eval 9 must stage a real .git repository.'
        Assert-True ((& git -C $repo branch --show-current) -eq 'feature/remove-legacy-api') 'Feature branch missing.'
        Assert-True ((& git -C $repo symbolic-ref refs/remotes/origin/HEAD --short) -eq 'origin/trunk') 'Non-main default branch fallback missing.'
        Assert-True ((& git -C $repo rev-list --count origin/HEAD..HEAD) -eq '1') 'Feature commit history missing.'
        $diff = (& git -C $repo diff origin/HEAD...HEAD) -join "`n"
        Assert-True ($diff.Contains('-    public static Widget Parse(string value)')) 'Meaningful public API removal missing.'
        Assert-True ([string]::IsNullOrWhiteSpace((& git -C $repo status --porcelain) -join '')) 'Staged repository must be clean.'
        $heads += & git -C $repo rev-parse HEAD
        $diffs += $diff
        $refs += ((& git -C $repo show-ref) -join "`n")
    }
    Assert-True ($heads[0] -ceq $heads[1] -and $diffs[0] -ceq $diffs[1] -and $refs[0] -ceq $refs[1]) 'Paired Git history, refs and diff must be identical.'
    . (Join-Path $scriptsRoot 'eval-git-workspace.ps1')
    Assert-EvalGitScenario $true
    Assert-EvalGitScenario $false
    foreach ($invalid in @('{"base_branch":"main","feature_branch":"main","commits":[]}', '{"base_branch":"main","feature_branch":"feature","commits":[{"message":"unsafe","files":{"../escape":"bad"}}]}')) {
        $rejected = $false
        try { Assert-EvalGitScenario ($invalid | ConvertFrom-Json) } catch { $rejected = $true }
        Assert-True $rejected 'Unsafe declarative scenario must be rejected.'
    }
    'PASS: eval 9 deterministic package Git history, pairing, grader handoff, boolean compatibility and unsafe-path rejection; no models.'
} finally {
    if (-not ([IO.Path]::GetFileName($workspace) -match '^change-impact-workspace-[0-9a-f]{32}$')) { throw 'Unsafe test cleanup.' }
    Remove-Item -LiteralPath $workspace -Recurse -Force
}
