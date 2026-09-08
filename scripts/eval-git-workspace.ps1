# Declarative, local-only Git scenarios. No hooks, remotes, or model calls run.
function Assert-EvalGitScenario {
    param([object]$Scenario)
    if ($Scenario -is [bool]) { return }
    if ($Scenario -isnot [pscustomobject]) { throw 'workspace.git must be a boolean or a declarative Git scenario.' }
    $allowed = @('base_branch', 'feature_branch', 'commits')
    foreach ($name in $Scenario.PSObject.Properties.Name) { if ($name -notin $allowed) { throw "Unknown workspace.git field '$name'." } }
    foreach ($name in $allowed) { if ($name -notin $Scenario.PSObject.Properties.Name) { throw "workspace.git requires '$name'." } }
    foreach ($branch in @($Scenario.base_branch, $Scenario.feature_branch)) {
        if ($branch -isnot [string] -or $branch -notmatch '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$' -or $branch.Contains('//') -or $branch.EndsWith('/')) { throw 'Invalid scenario branch name.' }
    }
    if ($Scenario.base_branch -eq $Scenario.feature_branch -or @($Scenario.commits).Count -lt 1) { throw 'Git scenario needs distinct base/feature branches and feature commits.' }
    foreach ($commit in $Scenario.commits) {
        if ([string]::IsNullOrWhiteSpace([string]$commit.message) -or $commit.files -isnot [pscustomobject]) { throw 'Each Git scenario commit requires message and files.' }
        foreach ($name in $commit.PSObject.Properties.Name) { if ($name -notin @('message', 'files')) { throw "Unknown commit field '$name'." } }
        foreach ($file in $commit.files.PSObject.Properties) {
            if ($file.Name -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$' -or $file.Name -match '(^|/)(\.\.?|\.git|bin|obj)(/|$)' -or $file.Name.EndsWith('/')) { throw "Unsafe Git scenario file '$($file.Name)'." }
            if ($null -ne $file.Value -and $file.Value -isnot [string]) { throw 'Git scenario file content must be a string or null (delete).' }
        }
    }
}

function Add-EvalGitScenario {
    param([string]$RepoDirectory, [object]$Scenario)
    Assert-EvalGitScenario -Scenario $Scenario
    if ($Scenario -is [bool]) { return }
    $identity = @('-c', 'user.name=Eval Harness', '-c', 'user.email=eval-harness@localhost', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=')
    function Invoke-ScenarioGit { param([string[]]$Arguments)
        & git @identity -C $RepoDirectory @Arguments 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Git scenario command failed: $($Arguments -join ' ')" }
    }
    $oldAuthor = $env:GIT_AUTHOR_DATE; $oldCommitter = $env:GIT_COMMITTER_DATE
    try {
        $env:GIT_AUTHOR_DATE = '2020-01-02T00:00:00Z'; $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
        Invoke-ScenarioGit -Arguments @('branch', '-m', [string]$Scenario.base_branch)
        # Local tracking refs and symbolic HEAD exercise default resolution
        # without a network remote or paths back to the package.
        Invoke-ScenarioGit -Arguments @('update-ref', "refs/remotes/origin/$($Scenario.base_branch)", 'HEAD')
        Invoke-ScenarioGit -Arguments @('symbolic-ref', 'refs/remotes/origin/HEAD', "refs/remotes/origin/$($Scenario.base_branch)")
        Invoke-ScenarioGit -Arguments @('checkout', '-b', [string]$Scenario.feature_branch, '--quiet')
        foreach ($commit in $Scenario.commits) {
            foreach ($file in $commit.files.PSObject.Properties) {
                $path = [IO.Path]::GetFullPath((Join-Path $RepoDirectory $file.Name))
                if (-not $path.StartsWith([IO.Path]::GetFullPath($RepoDirectory) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Git scenario path escaped repo.' }
                if ($null -eq $file.Value) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
                else { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path)); [IO.File]::WriteAllText($path, $file.Value, [Text.UTF8Encoding]::new($false)) }
            }
            Invoke-ScenarioGit -Arguments @('add', '-A')
            Invoke-ScenarioGit -Arguments @('commit', '--quiet', '-m', [string]$commit.message)
        }
    } finally { $env:GIT_AUTHOR_DATE = $oldAuthor; $env:GIT_COMMITTER_DATE = $oldCommitter }
}
