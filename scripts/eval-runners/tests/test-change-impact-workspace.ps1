# Real package preparation with a fake model catalog; never launches a provider.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $scriptsRoot 'eval-runners\runner-common.ps1')
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('change-impact-workspace-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($workspace)
function Assert-True($Condition, $Message) { if (-not $Condition) { throw $Message } }
$tokens = $null
$parseErrors = $null
$codexAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'eval-runners\codex\runner.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Codex runner did not parse for sanitized PATH projection.' }
foreach ($functionName in @('Join-CodexTargetPath', 'Get-CodexSanitizedShellPath')) {
    $definition = @($codexAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))
    if ($definition.Count -ne 1) { throw "Codex function '$functionName' was not found." }
    Invoke-Expression $definition[0].Extent.Text
}
function New-SanitizedGitEnvironment {
    param([Parameter(Mandatory = $true)][object]$GitCommand)
    $gitDirectory = Split-Path -Parent ([string]$GitCommand.Source)
    $platform = Get-PlatformName
    $environment = [ordered]@{ PATH = Get-CodexSanitizedShellPath -Platform $platform -GitDirectory $gitDirectory }
    if ($platform -eq 'windows') {
        $windowsRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) { $windowsRoot = 'C:\Windows' }
        $environment.SystemRoot = $windowsRoot
        $environment.ComSpec = Join-Path (Join-Path $windowsRoot 'System32') 'cmd.exe'
        $environment.PATHEXT = '.COM;.EXE;.BAT;.CMD'
    }
    return $environment
}
function Invoke-SanitizedGit {
    param(
        [Parameter(Mandatory = $true)][object]$GitCommand,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $process = Invoke-RunnerProcess -FileName ([IO.Path]::GetFileName([string]$GitCommand.Source)) -ArgumentList (@('-C', $Repo) + $Arguments) -WorkingDirectory $Repo -Environment $Environment -TimeoutSeconds 30
    if ($process.TimedOut -or $process.ExitCode -ne 0) { throw "sanitized git $([string]::Join(' ', $Arguments)) failed: $($process.Stderr)" }
    return @($process.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
try {
    $catalog = Join-Path $workspace 'models.json'
    [IO.File]::WriteAllText($catalog, '{"models":[{"id":"fixture-model"}]}')
    $analyzerCatalog = Join-Path $workspace 'analyzer-models.json'
    [IO.File]::WriteAllText($analyzerCatalog, '{"models":[{"id":"claude-haiku-4.5"}]}')
    $prompt = & (Join-Path $scriptsRoot 'prepare-skill-evals.ps1') -Skill dotnet-change-impact -Eval 9 -Runner github-copilot -Model fixture-model -ModelCatalogPath $catalog -AnalyzerModelCatalogPath $analyzerCatalog -OutputRoot $workspace -PassThru
    $package = Split-Path -Parent $prompt
    $handoff = [IO.File]::ReadAllText($prompt)
    Assert-True ($handoff.Contains('invoke-phase2-analyzer.ps1') -and $handoff.Contains('The Phase 2 controller, not this outer orchestrator')) 'Handoff must delegate grading to the package-local Phase 2 controller.'
    $manifest = Get-Content (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
    $heads = @(); $diffs = @(); $refs = @()
    $gitCommand = Resolve-ExternalCommand -Name 'git'
    Assert-True ($null -ne $gitCommand) 'git must resolve for the sanitized Codex git-workspace projection.'
    $sanitizedGitEnvironment = New-SanitizedGitEnvironment -GitCommand $gitCommand
    foreach ($arm in @('with_skill', 'without_skill')) {
        $repo = Join-Path (Split-Path -Parent (Join-Path $package $manifest.evals[0].runs.$arm.run_manifest)) 'repo'
        Assert-True (Test-Path (Join-Path $repo '.git') -PathType Container) 'Eval 9 must stage a real .git repository.'
        Assert-True ((Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('branch', '--show-current')) -eq 'feature/remove-legacy-api') 'Feature branch missing under sanitized PATH.'
        Assert-True ((Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('symbolic-ref', 'refs/remotes/origin/HEAD', '--short')) -eq 'origin/trunk') 'Non-main default branch fallback missing under sanitized PATH.'
        Assert-True ((Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('rev-list', '--count', 'origin/HEAD..HEAD')) -eq '1') 'Feature commit history missing under sanitized PATH.'
        $diff = (Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('diff', 'origin/HEAD...HEAD')) -join "`n"
        Assert-True ($diff.Contains('-    public static Widget Parse(string value)')) 'Meaningful public API removal missing.'
        Assert-True ([string]::IsNullOrWhiteSpace((Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('status', '--porcelain')) -join '')) 'Staged repository must be clean under sanitized PATH.'
        $heads += Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('rev-parse', 'HEAD')
        $diffs += $diff
        $refs += ((Invoke-SanitizedGit -GitCommand $gitCommand -Environment $sanitizedGitEnvironment -Repo $repo -Arguments @('show-ref')) -join "`n")
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
