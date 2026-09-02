<#!
.SYNOPSIS
    Deterministic Phase 1 aggregate fail-closed regressions.

.DESCRIPTION
    Exercises the real runner-owned Phase 1 path with mixed terminal outcomes
    and with completed raw results whose evidence validation fails. MODEL-FREE.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -cne [string]$Actual) {
        throw "ASSERT: $Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)
    if ($Text.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "ASSERT: $Message (missing '$Expected')"
    }
}

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Read-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
}

function Invoke-TestTool {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & pwsh -NoProfile -File $Path @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    }
}

function Invoke-ForegroundPhaseOne {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$IterationDirectory)

    # STDOUT is the machine protocol; STDERR is live observability. Capture them
    # separately so relayed heartbeats never contaminate the terminal JSON.
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('phase1-stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    try {
        $output = & pwsh -NoProfile -File $Path -IterationDirectory $IterationDirectory 2>$stderrPath
        $exitCode = $LASTEXITCODE
        $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $document = $text | ConvertFrom-Json -Depth 100
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Stderr = $stderr; Document = $document }
}

function Assert-ToolFails {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$ExpectedText = ''
    )

    if ([int]$Invocation.ExitCode -eq 0) {
        throw "ASSERT: $Description unexpectedly passed: $($Invocation.Text)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedText)) {
        Assert-Contains -Text $Invocation.Text -Expected $ExpectedText -Message $Description
    }
}

function New-TestRun {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][int]$EvalId,
        [Parameter(Mandatory = $true)][string]$EvalName
    )

    $runDirectory = Join-Path (Join-Path $IterationDirectory $EvalName) 'with_skill'
    $repoDirectory = Join-Path $runDirectory 'repo'
    $homeDirectory = Join-Path $runDirectory 'home'
    $skillDirectory = Join-Path $runDirectory 'skill/test-skill'
    New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory, $skillDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'execute-delay-ms'), '0', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $skillDirectory 'SKILL.md'), '# deterministic fixture skill`n', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "phase1 aggregate prompt for $EvalName/with_skill`n", [System.Text.UTF8Encoding]::new($false))

    $run = [ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = $EvalId
        evalName = $EvalName
        skillName = 'test-skill'
        iteration = 1
        mode = 'with_skill'
        promptFile = 'prompt.md'
        workingDirectory = 'repo'
        homeDirectory = 'home'
        skillDirectory = 'skill/test-skill'
        freshContextRequired = $true
        filesystemIsolationRequired = $true
        isolatedHomeRequired = $true
        gitWorkspace = $false
        inputFiles = @()
        fixtureHash = ('a' * 64)
        skillHash = ('b' * 64)
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
    Write-TestJson -Path (Join-Path $runDirectory 'run.json') -Value $run

    return [pscustomobject]@{
        RunDirectory = $runDirectory
        HomeDirectory = $homeDirectory
    }
}

function New-ReportFixtureScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $scriptText = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$IterationDirectory, [switch]$RequireComplete)
$ErrorActionPreference = 'Stop'
foreach ($file in @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
    [System.IO.File]::WriteAllText((Join-Path $IterationDirectory $file), "unexpected report artifact: $file`n", [System.Text.UTF8Encoding]::new($false))
}
'@
    [System.IO.File]::WriteAllText($Path, $scriptText, [System.Text.UTF8Encoding]::new($false))
}

function Initialize-PhaseOneFailurePackage {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][hashtable]$StatusesByEvalId,
        [int[]]$EvidenceFailureEvalIds = @()
    )

    $packageTools = Join-Path $IterationDirectory 'tools/eval-runners'
    New-Item -ItemType Directory -Path $packageTools -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $runnerRoot -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $packageTools -Recurse -Force
    }
    $fixtureDirectory = Join-Path $packageTools 'fixture'
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests/fixtures/runner-owned-fixture.ps1') -Destination (Join-Path $fixtureDirectory 'runner.ps1') -Force
    New-ReportFixtureScript -Path (Join-Path $IterationDirectory 'tools/test-report.ps1')

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le 4; $evalId++) {
        $evalName = 'phase1-eval-{0:d2}' -f $evalId
        $evalDirectory = Join-Path $IterationDirectory $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        Write-TestJson -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value ([ordered]@{
            schema = 'codebeltnet/agentic/eval-metadata/1'
            eval_id = $evalId
            eval_name = $evalName
            prompt = "fixture prompt $evalId"
            expected_output = 'fixture output'
            assertions = @('deterministic fixture assertion')
        })

        $run = New-TestRun -IterationDirectory $IterationDirectory -EvalId $evalId -EvalName $evalName
        $status = if ($StatusesByEvalId.ContainsKey($evalId)) { [string]$StatusesByEvalId[$evalId] } else { 'completed' }
        if ($status -ne 'completed') {
            [System.IO.File]::WriteAllText((Join-Path $run.HomeDirectory 'terminal-status'), $status, [System.Text.UTF8Encoding]::new($false))
        }
        if ($EvidenceFailureEvalIds -contains $evalId) {
            [System.IO.File]::WriteAllText((Join-Path $run.HomeDirectory 'evidence-validation-failed'), 'fixture', [System.Text.UTF8Encoding]::new($false))
        }

        $resultsDirectory = Join-Path $evalDirectory 'results'
        New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
        Write-TestJson -Path (Join-Path $resultsDirectory 'with_skill.result.json') -Value ([ordered]@{
            schema = (Get-RunnerSchemaNames).PortableResult
            eval_id = $evalId
            eval_name = $evalName
            configuration = 'with_skill'
            execution_status = 'unrun'
            grading = @([ordered]@{ text = 'deterministic fixture assertion'; passed = $null; evidence = '' })
        })

        $manifestEvals.Add([ordered]@{
            eval_id = $evalId
            eval_name = $evalName
            directory = $evalName
            metadata = "$evalName/eval-metadata.json"
            runs = [ordered]@{
                with_skill = [ordered]@{
                    mode = 'with_skill'
                    run_manifest = "$evalName/with_skill/run.json"
                    execution_result = "$evalName/results/with_skill.execution-result.json"
                    result = "$evalName/results/with_skill.result.json"
                }
            }
        })
    }

    $toolIntegrity = Get-PackageTreeIntegrity -Root $packageTools
    Write-TestJson -Path (Join-Path $IterationDirectory 'manifest.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        skill_name = 'phase1-aggregate-fixture'
        iteration = 1
        configurations = @('with_skill')
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $toolIntegrity.Sha256; file_count = $toolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        grading = 'grading.json'
        report = [ordered]@{ tool = 'tools/test-report.ps1' }
        evals = @($manifestEvals.ToArray())
    })
    Write-TestJson -Path (Join-Path $IterationDirectory 'execution-profile.json') -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 60
        concurrency = 4
    })

    return [pscustomobject]@{
        IterationDirectory = $IterationDirectory
        FanoutScript = Join-Path $packageTools 'invoke-runner-owned-arms.ps1'
        BridgeScript = Join-Path $packageTools 'bridge-manifest-results.ps1'
        FinalizerScript = Join-Path $packageTools 'finalize-eval-package.ps1'
        LogPath = Join-Path $IterationDirectory 'runner-events.jsonl'
        Records = @(Get-ManifestRunRecords -IterationDirectory $IterationDirectory -Manifest (Read-TestJson -Path (Join-Path $IterationDirectory 'manifest.json')) | Sort-Object EvalId, Configuration)
    }
}

function Assert-Counts {
    param(
        [Parameter(Mandatory = $true)][object]$Source,
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][string]$MessagePrefix
    )

    foreach ($name in @(
            'expected_count',
            'terminal_count',
            'completed_count',
            'failed_count',
            'timed_out_count',
            'cancelled_count',
            'incompatible_count',
            'evidence_validation_failed_count'
        )) {
        Assert-Equal $Expected[$name] (Get-JsonProperty -Object $Source -Name $name -Default $null) "$MessagePrefix $name"
    }
}

function Assert-ArmSummaryShape {
    param([Parameter(Mandatory = $true)][object]$Summary, [Parameter(Mandatory = $true)][string]$ScenarioName)

    foreach ($arm in @($Summary.arms)) {
        foreach ($field in @('worker_id', 'eval_id', 'configuration', 'status', 'worker_session_id', 'evidence_validation')) {
            Assert-True (Test-JsonProperty -Object $arm -Name $field) "$ScenarioName arm summary contains $field"
        }
        $evidenceValidation = Get-JsonProperty -Object $arm -Name 'evidence_validation' -Default $null
        Assert-True (Test-JsonProperty -Object $evidenceValidation -Name 'status') "$ScenarioName arm summary contains evidence_validation.status"
        Assert-True (Test-JsonProperty -Object $evidenceValidation -Name 'reasons') "$ScenarioName arm summary contains evidence_validation.reasons"
    }
}

function Assert-CanonicalResultsRemainUnrun {
    param([Parameter(Mandatory = $true)][object[]]$Records, [Parameter(Mandatory = $true)][string]$ScenarioName)

    foreach ($record in $Records) {
        $result = Read-TestJson -Path $record.ResultPath
        Assert-Equal 'unrun' ([string](Get-JsonProperty -Object $result -Name 'execution_status' -Default '')) "$ScenarioName keeps $($record.ResultRelative) unbridged"
    }
}

function Assert-NoPhaseTwoArtifacts {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory, [Parameter(Mandatory = $true)][string]$ScenarioName)

    foreach ($relative in @('grading.json', 'report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $IterationDirectory $relative) -PathType Leaf)) "$ScenarioName does not produce $relative"
    }
}

function Assert-NoRetries {
    param([Parameter(Mandatory = $true)][string]$LogPath, [Parameter(Mandatory = $true)][int]$ExpectedArmCount, [Parameter(Mandatory = $true)][string]$ScenarioName)

    $events = @(Get-Content -LiteralPath $LogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal ($ExpectedArmCount * 2) $events.Count "$ScenarioName records one preflight and one execute event per arm"
    Assert-Equal $ExpectedArmCount @($events | Where-Object { $_.kind -eq 'preflight' }).Count "$ScenarioName records one preflight per arm"
    Assert-Equal $ExpectedArmCount @($events | Where-Object { $_.kind -eq 'execute' }).Count "$ScenarioName records one execute per arm"

    foreach ($evalId in 1..$ExpectedArmCount) {
        $executeEvents = @($events | Where-Object { $_.kind -eq 'execute' -and [int]$_.eval_id -eq $evalId -and [string]$_.configuration -eq 'with_skill' })
        Assert-Equal 1 $executeEvents.Count "$ScenarioName does not retry eval $evalId"
    }
}

function Assert-LedgerMatchesFrozenStatuses {
    param([Parameter(Mandatory = $true)][object]$FreezeValidation, [Parameter(Mandatory = $true)][string]$ScenarioName)

    foreach ($entry in @($FreezeValidation.Freeze.executions)) {
        $terminal = Get-JsonProperty -Object (Get-JsonProperty -Object $FreezeValidation.State -Name 'completed' -Default $null) -Name ([string]$entry.worker_id) -Default $null
        Assert-Equal ([string]$entry.terminal_status) ([string](Get-JsonProperty -Object $terminal -Name 'status' -Default '')) "$ScenarioName preserves frozen ledger status for $($entry.worker_id)"
    }
}

function Invoke-PhaseOneFailureScenario {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioName,
        [Parameter(Mandatory = $true)][hashtable]$StatusesByEvalId,
        [int[]]$EvidenceFailureEvalIds = @(),
        [Parameter(Mandatory = $true)][hashtable]$ExpectedCounts,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFrozenStatuses,
        [scriptblock]$AdditionalAssertions = $null
    )

    $iterationDirectory = Join-Path $testRoot $ScenarioName
    $package = Initialize-PhaseOneFailurePackage -IterationDirectory $iterationDirectory -StatusesByEvalId $StatusesByEvalId -EvidenceFailureEvalIds $EvidenceFailureEvalIds
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $package.LogPath)

    $fanout = Invoke-ForegroundPhaseOne -Path $package.FanoutScript -IterationDirectory $iterationDirectory
    Assert-Equal 2 $fanout.ExitCode "$ScenarioName Phase 1 exits non-zero"
    $summary = $fanout.Document
    Assert-Equal 'phase1' ([string](Get-JsonProperty -Object $summary -Name 'phase' -Default '')) "$ScenarioName summary identifies Phase 1"
    Assert-Equal 'failed' ([string](Get-JsonProperty -Object $summary -Name 'status' -Default '')) "$ScenarioName summary is non-success"
    Assert-Counts -Source $summary -Expected $ExpectedCounts -MessagePrefix "$ScenarioName summary"
    Assert-ArmSummaryShape -Summary $summary -ScenarioName $ScenarioName
    Assert-True (Test-Path -LiteralPath (Join-Path $iterationDirectory 'execution-freeze.json') -PathType Leaf) "$ScenarioName writes execution-freeze.json before failing"
    $summaryFreeze = Get-JsonProperty -Object $summary -Name 'execution_freeze' -Default $null
    Assert-True (Test-JsonProperty -Object $summaryFreeze -Name 'path') "$ScenarioName summary reports execution_freeze.path"
    Assert-True (Test-JsonProperty -Object $summaryFreeze -Name 'sha256') "$ScenarioName summary reports execution_freeze.sha256"

    $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iterationDirectory -RequireOrchestrationState
    Assert-True (-not [bool]$freezeValidation.PhaseOneSuccess) "$ScenarioName frozen aggregate remains non-success"
    Assert-Counts -Source $freezeValidation.Aggregate -Expected $ExpectedCounts -MessagePrefix "$ScenarioName frozen aggregate"
    Assert-Equal ([string]::Join(',', $ExpectedFrozenStatuses)) ([string]::Join(',', @($freezeValidation.Freeze.executions | ForEach-Object { [string]$_.terminal_status }))) "$ScenarioName freeze preserves exact raw terminal statuses"
    Assert-LedgerMatchesFrozenStatuses -FreezeValidation $freezeValidation -ScenarioName $ScenarioName
    Assert-CanonicalResultsRemainUnrun -Records $package.Records -ScenarioName $ScenarioName
    Assert-NoPhaseTwoArtifacts -IterationDirectory $iterationDirectory -ScenarioName $ScenarioName

    $bridge = Invoke-TestTool -Path $package.BridgeScript -Arguments @('-IterationDirectory', $iterationDirectory, '-RequireComplete', '-RequireParallelDispatch', '-RequireNativeDelegation')
    Assert-ToolFails -Invocation $bridge -Description "$ScenarioName complete bridge is blocked" -ExpectedText 'completion gate failed'
    Assert-CanonicalResultsRemainUnrun -Records $package.Records -ScenarioName $ScenarioName

    $finalizer = Invoke-TestTool -Path $package.FinalizerScript -Arguments @('-IterationDirectory', $iterationDirectory)
    Assert-ToolFails -Invocation $finalizer -Description "$ScenarioName finalizer is blocked" -ExpectedText 'Manifest bridge failed'
    Assert-NoPhaseTwoArtifacts -IterationDirectory $iterationDirectory -ScenarioName $ScenarioName

    if ($null -ne $AdditionalAssertions) {
        & $AdditionalAssertions $summary $freezeValidation $package
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-phase1-aggregate-' + [Guid]::NewGuid().ToString('N'))
$oldFixtureLogPath = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG')
try {
    Invoke-PhaseOneFailureScenario `
        -ScenarioName 'mixed-terminal' `
        -StatusesByEvalId @{ 1 = 'completed'; 2 = 'timed_out'; 3 = 'failed'; 4 = 'completed' } `
        -ExpectedCounts @{
            expected_count = 4
            terminal_count = 4
            completed_count = 2
            failed_count = 1
            timed_out_count = 1
            cancelled_count = 0
            incompatible_count = 0
            evidence_validation_failed_count = 0
        } `
        -ExpectedFrozenStatuses @('completed', 'timed_out', 'failed', 'completed') `
        -AdditionalAssertions {
            param($Summary, $FreezeValidation, $Package)

            Assert-NoRetries -LogPath $Package.LogPath -ExpectedArmCount 4 -ScenarioName 'mixed-terminal'
            foreach ($workerId in @('arm-1-with_skill', 'arm-2-with_skill', 'arm-3-with_skill', 'arm-4-with_skill')) {
                $terminal = Get-JsonProperty -Object (Get-JsonProperty -Object $FreezeValidation.State -Name 'completed' -Default $null) -Name $workerId -Default $null
                $evidenceValidation = Get-JsonProperty -Object $terminal -Name 'evidence_validation' -Default $null
                Assert-Equal 'passed' ([string](Get-JsonProperty -Object $evidenceValidation -Name 'status' -Default '')) "mixed-terminal keeps honest evidence_validation for $workerId"
            }
        }

    Invoke-PhaseOneFailureScenario `
        -ScenarioName 'completed-with-evidence-failure' `
        -StatusesByEvalId @{ 1 = 'completed'; 2 = 'completed'; 3 = 'completed'; 4 = 'completed' } `
        -EvidenceFailureEvalIds @(3) `
        -ExpectedCounts @{
            expected_count = 4
            terminal_count = 4
            completed_count = 4
            failed_count = 0
            timed_out_count = 0
            cancelled_count = 0
            incompatible_count = 0
            evidence_validation_failed_count = 1
        } `
        -ExpectedFrozenStatuses @('completed', 'completed', 'completed', 'completed') `
        -AdditionalAssertions {
            param($Summary, $FreezeValidation, $Package)

            $failedTerminal = Get-JsonProperty -Object (Get-JsonProperty -Object $FreezeValidation.State -Name 'completed' -Default $null) -Name 'arm-3-with_skill' -Default $null
            $failedEvidence = Get-JsonProperty -Object $failedTerminal -Name 'evidence_validation' -Default $null
            Assert-Equal 'completed' ([string](Get-JsonProperty -Object $failedTerminal -Name 'status' -Default '')) 'evidence-failure scenario keeps the raw completed status'
            Assert-Equal 'failed' ([string](Get-JsonProperty -Object $failedEvidence -Name 'status' -Default '')) 'evidence-failure scenario records failed evidence validation'
            Assert-Contains -Text ([string]::Join(', ', @((Get-JsonProperty -Object $failedEvidence -Name 'reasons' -Default @()) | ForEach-Object { [string]$_ }))) -Expected 'prompt_fidelity' -Message 'evidence-failure scenario preserves the validation reason'
        }

    Write-Output 'Phase 1 aggregate regressions: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $oldFixtureLogPath)
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
