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
    Assert-ReadyTest ([IO.Path]::EndsInDirectorySeparator([string]$environment['NUGET_PACKAGES'])) 'Isolated NUGET_PACKAGES must end with a directory separator for MSBuild SourceRoot compatibility.'
    Assert-ReadyTest (Test-PathInside -BasePath $homePath -CandidatePath ([string]$environment['NUGET_PACKAGES'])) 'Isolated NUGET_PACKAGES must stay inside the isolated run home.'
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

    # Deterministic build readiness: a restore prerequisite must stage a representative
    # SourceRoot + deterministic-build probe and exercise `dotnet build`, not only restore.
    $dotnetCommand = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $dotnetCommand) {
        . (Join-Path $PSScriptRoot '../../prepare-eval-prerequisites.ps1')
        function Write-Utf8File {
            param([string]$Path, [string]$Content)
            $dir = Split-Path -Parent $Path
            if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        }
        $targetMajor = ((& $dotnetCommand.Source --version) -split '\.')[0]
        $buildRoot = Join-Path $root 'build-readiness'
        $buildRepo = Join-Path $buildRoot 'repo'
        $buildHome = Join-Path $buildRoot 'home'
        New-Item -ItemType Directory -Path $buildRepo, $buildHome -Force | Out-Null
        $staged = Initialize-EvalPrerequisites -Requirements ([pscustomobject]@{
            executables = @('dotnet')
            restore = [pscustomobject]@{ framework = "net$targetMajor.0"; packages = @() }
        }) -RunRoot $buildRoot -CandidateName 'readiness-test'
        $probeIds = @($staged.probes | ForEach-Object { $_.id })
        Assert-ReadyTest (($probeIds -contains 'nuget-restore') -and ($probeIds -contains 'dotnet-build')) 'Restore prerequisites must emit both nuget-restore and dotnet-build readiness probes.'
        # Use an empty offline source list so deterministic validation never depends on network access.
        Write-Utf8File -Path (Join-Path $buildHome 'restore-probe/NuGet.Config') -Content '<configuration><packageSources><clear/></packageSources></configuration>'
        $buildRun = [pscustomobject]@{
            RunRoot = $buildRoot
            HomeDirectoryPath = $buildHome
            WorkingDirectoryPath = $buildRepo
            CandidateSkillName = 'readiness-test'
            Interaction = $null
            Contract = @{ candidateSkillName = 'readiness-test'; prerequisites = $staged }
        }
        $buildEnv = New-RunnerShellEnvironment -Run $buildRun
        $buildProbes = @(Get-EvalReadinessProbes -Run $buildRun)
        foreach ($item in $buildProbes) {
            $proc = Invoke-RunnerProcess -FileName $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $item.script) -WorkingDirectory $buildRepo -Environment $buildEnv -TimeoutSeconds 45
            $obs = New-EvalReadinessObservation -Probe $item -Response @{ result = @{ exitCode = $proc.ExitCode; stdout = $proc.Stdout; stderr = $proc.Stderr } }
            Assert-ReadyTest ($obs.status -eq 'ready') "Deterministic build readiness probe '$($obs.id)' failed: $($obs.diagnostic)"
        }

        # Negative regression: stripping the trailing separator from NUGET_PACKAGES must be
        # caught by both isolated-shell-environment and dotnet-build even when restore succeeds.
        foreach ($artifactDir in @('bin', 'obj')) {
            $artifactPath = Join-Path $buildHome "restore-probe/$artifactDir"
            if (Test-Path -LiteralPath $artifactPath) { Remove-Item -LiteralPath $artifactPath -Recurse -Force }
        }
        $brokenEnv = [ordered]@{}
        foreach ($key in $buildEnv.Keys) { $brokenEnv[$key] = $buildEnv[$key] }
        $brokenEnv['NUGET_PACKAGES'] = ([string]$brokenEnv['NUGET_PACKAGES']).TrimEnd('\', '/')
        $envProbe = @($buildProbes | Where-Object { $_.id -eq 'isolated-shell-environment' })[0]
        $restoreProbe = @($buildProbes | Where-Object { $_.id -eq 'nuget-restore' })[0]
        $compileProbe = @($buildProbes | Where-Object { $_.id -eq 'dotnet-build' })[0]
        $envProc = Invoke-RunnerProcess -FileName $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $envProbe.script) -WorkingDirectory $buildRepo -Environment $brokenEnv -TimeoutSeconds 15
        Assert-ReadyTest ((New-EvalReadinessObservation -Probe $envProbe -Response @{ result = @{ exitCode = $envProc.ExitCode; stdout = $envProc.Stdout; stderr = $envProc.Stderr } }).status -eq 'infrastructure_blocked') 'Environment readiness probe must fail when NUGET_PACKAGES loses its trailing separator.'
        $restoreProc = Invoke-RunnerProcess -FileName $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $restoreProbe.script) -WorkingDirectory $buildRepo -Environment $brokenEnv -TimeoutSeconds 45
        Assert-ReadyTest ((New-EvalReadinessObservation -Probe $restoreProbe -Response @{ result = @{ exitCode = $restoreProc.ExitCode; stdout = $restoreProc.Stdout; stderr = $restoreProc.Stderr } }).status -eq 'ready') 'Restore alone succeeds without catching the SourceRoot trailing-separator defect.'
        $compileProc = Invoke-RunnerProcess -FileName $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $compileProbe.script) -WorkingDirectory $buildRepo -Environment $brokenEnv -TimeoutSeconds 45
        $compileObs = New-EvalReadinessObservation -Probe $compileProbe -Response @{ result = @{ exitCode = $compileProc.ExitCode; stdout = $compileProc.Stdout; stderr = $compileProc.Stderr } }
        Assert-ReadyTest ($compileObs.status -eq 'infrastructure_blocked' -and $compileObs.diagnostic -match 'SourceRoot paths are required to end with a slash or backslash') "dotnet-build readiness probe did not surface the SourceRoot defect: $($compileObs.diagnostic)"
    }

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
