[CmdletBinding()]
param([string]$NativeCodex, [string]$PreparedPackage, [int[]]$Eval = @())

. (Join-Path $PSScriptRoot '../runner-common.ps1')

function Assert-ReadyTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('agentic-readiness-test-' + [Guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
$homePath = Join-Path $root 'home'
New-Item -ItemType Directory -Path $repo, $homePath -Force | Out-Null
$previousToken = $env:OPENAI_API_KEY
$previousNodePath = $env:NODE_PATH
try {
    $env:OPENAI_API_KEY = 'readiness-test-sentinel'
    $env:NODE_PATH = Join-Path $root 'ambient-modules'
    $run = [pscustomobject]@{
        RunRoot = $root
        HomeDirectoryPath = $homePath
        WorkingDirectoryPath = $repo
        CandidateSkillName = 'readiness-test'
        Interaction = $null
        Contract = @{
            candidateSkillName = 'readiness-test'
            prerequisites = @{
                executables = @('pwsh')
                probes = @(@{ id = 'pwsh-version'; command = @('pwsh', '-NoProfile', '--version'); outputPattern = '^PowerShell 7\.' })
            }
        }
    }
    $environment = New-RunnerShellEnvironment -Run $run
    $parent = New-RunnerEnvironment -Run $run -AuthenticationVariables @('OPENAI_API_KEY')
    Assert-ReadyTest ($parent.OPENAI_API_KEY -eq 'readiness-test-sentinel' -and -not $environment.Contains('OPENAI_API_KEY')) 'Credentials belong to the transport parent only.'
    Assert-ReadyTest (-not $environment.Contains('NODE_PATH')) 'Ambient Node configuration entered the shell environment.'
    $shell = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    foreach ($probe in Get-EvalReadinessProbes -Run $run) {
        $process = Invoke-RunnerProcess -FileName $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $probe.script) -WorkingDirectory $repo -Environment $environment -TimeoutSeconds 15
        $result = New-EvalReadinessObservation -Probe $probe -Response @{ result = @{ exitCode = $process.ExitCode; stdout = $process.Stdout; stderr = $process.Stderr } }
        Assert-ReadyTest ($result.status -eq 'ready') "$($result.id) failed: $($result.diagnostic)"
    }
    $probe = @(Get-EvalReadinessProbes -Run $run)[1]
    $failed = New-EvalReadinessObservation -Probe $probe -Response @{ result = @{ exitCode = 127; stderr = 'Missing tool' } }
    $mismatch = New-EvalReadinessObservation -Probe $probe -Response @{ result = @{ exitCode = 0; stdout = 'PowerShell 6.0' } }
    $unavailable = New-EvalReadinessObservation -Probe $probe -Response @{ error = @{ code = -32601 } }
    Assert-ReadyTest ($failed.status -eq 'infrastructure_blocked' -and $failed.exit_code -eq 127 -and $failed.command[0] -eq 'pwsh' -and $failed.diagnostic -eq 'Missing tool') 'Readiness failure lost its diagnostic or executed command.'
    Assert-ReadyTest ($mismatch.status -eq 'infrastructure_blocked' -and $unavailable.status -eq 'infrastructure_blocked') 'Version mismatches and unsupported transports must block readiness.'

    $dependency = Join-Path $root 'dependencies/helper'
    New-Item -ItemType Directory -Path (Join-Path $dependency 'references') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dependency 'references/a.md') -Value 'Used on demand'
    Set-Content -LiteralPath (Join-Path $dependency 'references/b.md') -Value 'Unrelated'
    $run.Contract.prerequisites.skills = @(@{ path = 'dependencies/helper'; sha256 = Get-EvalDependencyTreeHash -Root $dependency })
    Assert-EvalStagedDependencies -RunRoot $root -Contract $run.Contract
    $reads = @(Get-ObservedSkillReferenceReads -SkillRoot $dependency -Commands @(
        @{ command = 'Get-ChildItem ../dependencies/helper/references/b.md'; exit_code = 0; output_bytes = 10 }
        @{ command = "Get-Content '../dependencies/helper/references/a.md'"; exit_code = 0; output_bytes = 14 }
        @{ command = 'cat ../dependencies/helper/references/b.md'; exit_code = 1; output_bytes = 20 }
        @{ command = 'cat ../dependencies/helper/references/b.md'; exit_code = 0; output_bytes = 0 }
    ))
    Assert-ReadyTest ($reads.Count -eq 1 -and $reads[0] -eq 'references/a.md') 'Only successful named reference reads should be counted.'
    Add-Content -LiteralPath (Join-Path $dependency 'references/a.md') -Value 'Modified'
    $rejected = try { Assert-EvalStagedDependencies -RunRoot $root -Contract $run.Contract; $false } catch { $_.Exception.Message -like '*hash mismatch*' }
    Assert-ReadyTest $rejected 'A modified complementary dependency was accepted.'

    if ($NativeCodex) {
        $scriptAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../codex/runner.ps1'), [ref]$null, [ref]$null)
        foreach ($node in $scriptAst.FindAll({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            . ([scriptblock]::Create($node.Extent.Text))
        }
        $native = [pscustomobject]@{ FileName = (Resolve-Path -LiteralPath $NativeCodex).Path; Prefix = @() }
        $cases = @($run)
        if ($PreparedPackage) {
            $manifest = Read-RunnerJson -Path (Join-Path $PreparedPackage 'manifest.json')
            foreach ($entry in $manifest.evals) {
                if ($Eval.Count -gt 0 -and $entry.eval_id -notin $Eval) { continue }
                $with = Resolve-RunContract -RunPath (Join-Path $PreparedPackage $entry.runs.with_skill.run_manifest)
                $without = Resolve-RunContract -RunPath (Join-Path $PreparedPackage $entry.runs.without_skill.run_manifest)
                Assert-ReadyTest ($with.FixtureHash -eq $without.FixtureHash) "Eval $($with.EvalId) fixture hashes diverged."
                $withPrerequisites = Get-JsonProperty -Object $with.Contract -Name 'prerequisites'
                $withoutPrerequisites = Get-JsonProperty -Object $without.Contract -Name 'prerequisites'
                Assert-ReadyTest ((Get-JsonFingerprint -Object @{ prerequisites = $withPrerequisites }) -eq (Get-JsonFingerprint -Object @{ prerequisites = $withoutPrerequisites })) "Eval $($with.EvalId) prerequisites diverged."
                Assert-ReadyTest ([Text.Encoding]::UTF8.GetString($with.PromptBytes) -notmatch '## Skill resource:') "Eval $($with.EvalId) received inline references in entry-point mode."
                $cases += @($with, $without)
            }
        }
        foreach ($case in $cases) {
            $projection = if (Test-JsonProperty -Object $case -Name 'PromptBytes') { New-CodexExecutionProjection -Inputs @{ Run = $case } } else { $null }
            $physical = if ($null -ne $projection) { $projection.Run } else { $case }
            $nativeHome = Join-Path $physical.HomeDirectoryPath 'native-test-parent'
            New-Item -ItemType Directory -Path $nativeHome -Force | Out-Null
            try {
                $nativeParent = New-RunnerEnvironment -Run $physical -AuthenticationVariables @('OPENAI_API_KEY') -Additional @{ CODEX_HOME = $nativeHome }
                $observation = Invoke-CodexAppServer -ReadinessOnly -CommandInfo $native -Inputs @{ Run = $physical } -Auth @{ Kind = 'subscription_file' } -AuthHome @{ Path = $nativeHome; AuthOnly = $true } -ParentEnvironment $nativeParent -TimeoutSeconds 85
                Assert-ReadyTest ($observation.Readiness.Count -gt 0) "App Server produced no readiness evidence. $(Get-JsonProperty -Object $observation -Name 'TransportFailure')"
                foreach ($check in $observation.Readiness) {
                    Assert-ReadyTest ($check.status -eq 'ready') "Native $($check.id) failed: $($check.diagnostic)"
                }
                Write-Output ('Native command/exec passed: ' + (@($observation.Readiness | ForEach-Object id) -join ', '))
            } finally {
                if ($null -ne $projection) { Remove-CodexExecutionProjection -Projection $projection }
            }
        }
    }
    Write-Output 'Evaluation readiness regression: PASS'
} finally {
    $env:OPENAI_API_KEY = $previousToken
    $env:NODE_PATH = $previousNodePath
    if ((Test-Path -LiteralPath $root) -and (Test-PathInside -BasePath ([IO.Path]::GetTempPath()) -CandidatePath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
