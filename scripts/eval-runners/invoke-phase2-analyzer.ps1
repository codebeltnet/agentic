<#!
.SYNOPSIS
    Runs package-local Phase 2 grading with explicit analyzer provenance.

.DESCRIPTION
    This is the normal Phase 2 boundary after Phase 1 execution is frozen and
    bridged. It resolves deterministic validator-domain assertions before any
    analyzer worker starts, dispatches one fresh analyzer session per remaining
    semantic arm, persists analyzer evidence and progress, freezes Phase 2, and
    deterministically writes package-root grading.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [ValidateRange(1, 128)][int]$Concurrency = 16,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')
. (Join-Path $PSScriptRoot 'package-integrity.ps1')
. (Join-Path $PSScriptRoot 'fanout-process.ps1')
. (Join-Path $PSScriptRoot 'phase2-grading.ps1')

function Write-Phase2Summary {
    param([Parameter(Mandatory = $true)][object]$Value, [int]$ExitCode = 0)

    Write-RunnerJson -Value $Value -Compress -AsOutput
    if ($ExitCode -ne 0) { exit $ExitCode }
}

function Save-Phase2State {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)

    $State.updated_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow)
    Write-RunnerJsonFile -Path $Path -Value $State
}

function Resolve-AnalyzerRunner {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$AnalyzerProfile
    )

    $runnerToolsDirectory = Resolve-PackageRunnerToolsDirectory -IterationDirectory $IterationDirectory -Manifest $Manifest
    $resolverPath = Join-Path $runnerToolsDirectory 'resolve-runner.ps1'
    if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) { throw "Package-local Eval Runner resolver is missing at '$resolverPath'." }
    $resolutionOutput = & pwsh -NoProfile -NonInteractive -File $resolverPath ([string]$AnalyzerProfile.Runner) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Analyzer runner '$($AnalyzerProfile.Runner)' could not be resolved package-locally: $([string]::Join(' ', @($resolutionOutput)))" }
    $resolution = ([string]::Join([Environment]::NewLine, @($resolutionOutput | ForEach-Object { [string]$_ }))) | ConvertFrom-Json
    $runnerRelative = [string](Get-JsonProperty -Object $resolution -Name 'path' -Default '')
    $runnerPath = Resolve-ContainedPath -BasePath $runnerToolsDirectory -RelativePath $runnerRelative -FieldName 'resolved analyzer runner path' -Kind File
    $descriptor = Get-PackageRunnerDescriptorFromPath -RunnerName ([string]$AnalyzerProfile.Runner) -RunnerPath $runnerPath -RunnerToolsDirectory $runnerToolsDirectory
    if ([string](Get-JsonProperty -Object $descriptor.harness -Name 'name' -Default '') -ne [string]$AnalyzerProfile.Harness) {
        throw "Analyzer profile harness '$($AnalyzerProfile.Harness)' does not match package-local runner descriptor '$($descriptor.harness.name)'."
    }
    $delegation = Get-JsonProperty -Object $descriptor -Name 'delegation' -Default $null
    if ([string](Get-JsonProperty -Object $delegation -Name 'dispatch_owner' -Default '') -ne 'runner') {
        throw "Analyzer runner '$($AnalyzerProfile.Runner)' must provide runner-owned fresh analyzer sessions for attributable Phase 2 grading."
    }
    return [pscustomobject]@{ RunnerToolsDirectory = $runnerToolsDirectory; RunnerPath = $runnerPath; Descriptor = $descriptor; Resolution = $resolution }
}

function New-AnalyzerExecutionProfile {
    param([Parameter(Mandatory = $true)][object]$AnalyzerProfile)

    return [ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = [string]$AnalyzerProfile.Runner
        model = [string]$AnalyzerProfile.Model
        reasoning_effort = $AnalyzerProfile.ReasoningEffort
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = $TimeoutSeconds
        concurrency = $Concurrency
    }
}

function New-AnalyzerPrompt {
    param(
        [Parameter(Mandatory = $true)][object]$Bundle,
        [Parameter(Mandatory = $true)][string]$GraderContract
    )

    $bundleJson = ConvertTo-RunnerJson -Value $Bundle -Depth 100
    return @"
# Phase 2 semantic analyzer

You are grading exactly one evaluation arm. Use the grader contract below and the input bundle below. Return only JSON. Do not inspect any repository, paired arm, sibling eval, previous grade, native skill, plugin, MCP server, or global configuration.

## Response schema

Return this exact JSON shape:

````json
{
  "schema": "codebeltnet/agentic/eval-analyzer-fragment/1",
  "eval_id": $($Bundle.eval_id),
  "configuration": "$($Bundle.configuration)",
  "grading": [
    {
      "assertion_index": 0,
      "passed": true,
      "reason": "Specific explanation tied to the cited frozen evidence.",
      "evidence_refs": [
        {
          "artifact": "$($Bundle.canonical_result)",
          "domain": "output",
          "start_line": 1,
          "end_line": 1,
          "quote": "verbatim text from those lines"
        }
      ]
    }
  ]
}
````

Rules:
- Grade only the assertion indexes listed in the input bundle.
- Use output-domain refs only for output assertions and transcript-domain refs only for transcript assertions.
- Cite only artifacts listed in this one-arm bundle.
- A quote, when present, must be verbatim from the cited lines or event.
- Do not cite the paired arm or any sibling eval.
- Do not retry, ask for another model, or broaden the task.

## Packaged grader contract

````markdown
$GraderContract
````

## Input bundle

````json
$bundleJson
````
"@
}

function New-AnalyzerRunBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Phase2Root,
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $true)][object]$AnalyzerProfile,
        [Parameter(Mandatory = $true)][string]$AnalyzerExecutionProfilePath,
        [Parameter(Mandatory = $true)][string]$GraderContractText
    )

    $workerId = [string]$Worker.worker_id
    $runRoot = Join-Path (Join-Path $Phase2Root 'work') $workerId
    $repoRoot = Join-Path $runRoot 'repo'
    $homeRoot = Join-Path $runRoot 'home'
    New-Item -ItemType Directory -Path $repoRoot, $homeRoot -Force | Out-Null
    $canonical = Read-RunnerJson -Path $Worker.record.ResultPath
    $output = [string](Get-JsonProperty -Object $canonical -Name 'output' -Default '')
    $outputLines = @(Get-ArmOutputLines -Output $output)
    $lineRecords = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $outputLines.Count; $index++) {
        $lineRecords.Add([ordered]@{ line = $index + 1; text = [string]$outputLines[$index] })
    }
    $metadata = Read-RunnerJson -Path $Worker.record.MetadataPath
    $bundle = [ordered]@{
        schema = 'codebeltnet/agentic/eval-analyzer-input/1'
        worker_id = $workerId
        eval_id = [int]$Worker.eval_id
        eval_name = [string]$Worker.eval_name
        configuration = [string]$Worker.configuration
        analyzer_profile_sha256 = [string]$AnalyzerProfile.Hash
        expected_output = [string](Get-JsonProperty -Object $metadata -Name 'expected_output' -Default '')
        canonical_result = [string]$Worker.record.ResultRelative
        canonical_result_sha256 = Get-Sha256HexFromFile -Path $Worker.record.ResultPath
        frozen_output = [ordered]@{
            artifact = [string]$Worker.record.ResultRelative
            lines = @($lineRecords.ToArray())
        }
        allowed_artifacts = @(([string]$Worker.record.ResultRelative) + @((Get-JsonProperty -Object $canonical -Name 'output_files' -Default @()) | ForEach-Object { [string]$_ }))
        assertions = @($Worker.assertions | ForEach-Object {
            [ordered]@{
                assertion_index = [int]$_.assertion_index
                assertion = [string]$_.assertion
                evidence_domain = [string]$_.evidence_domain
            }
        })
    }
    $bundlePath = Join-Path $repoRoot 'input-bundle.json'
    Write-RunnerJsonFile -Path $bundlePath -Value $bundle
    $graderPath = Join-Path $repoRoot 'grader.md'
    [System.IO.File]::WriteAllText($graderPath, $GraderContractText, [System.Text.UTF8Encoding]::new($false))
    $bundleHash = Get-Sha256HexFromFile -Path $bundlePath
    $prompt = New-AnalyzerPrompt -Bundle $bundle -GraderContract $GraderContractText
    [System.IO.File]::WriteAllText((Join-Path $runRoot 'prompt.md'), $prompt, [System.Text.UTF8Encoding]::new($false))
    $run = [ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = [int]$Worker.eval_id
        evalName = ('phase2-{0}' -f [string]$Worker.eval_name)
        candidateSkillName = 'phase2-analyzer'
        skillName = $null
        iteration = 1
        mode = 'without_skill'
        promptFile = 'prompt.md'
        workingDirectory = 'repo'
        homeDirectory = 'home'
        skillDirectory = $null
        freshContextRequired = $true
        filesystemIsolationRequired = $true
        isolatedHomeRequired = $true
        gitWorkspace = $false
        inputFiles = @('input-bundle.json', 'grader.md')
        fixtureHash = Get-JsonFingerprint -Object $bundle
        skillHash = $null
        candidateInstructionHash = $null
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
    $runPath = Join-Path $runRoot 'run.json'
    Write-RunnerJsonFile -Path $runPath -Value $run
    return [pscustomobject]@{
        WorkerId = $workerId
        RunRoot = $runRoot
        RunPath = $runPath
        BundlePath = $bundlePath
        BundleHash = $bundleHash
        PromptPath = Join-Path $runRoot 'prompt.md'
        AnalyzerExecutionProfilePath = $AnalyzerExecutionProfilePath
    }
}

function Invoke-AnalyzerPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][object]$Bundle,
        [Parameter(Mandatory = $true)][string]$ProgressLogPath
    )

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-phase2-preflight-' + [Guid]::NewGuid().ToString('N') + '.stdout')
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-phase2-preflight-' + [Guid]::NewGuid().ToString('N') + '.stderr')
    $child = $null
    try {
        $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
        $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $RunnerPath, 'preflight', '-Run', $Bundle.RunPath, '-Profile', $Bundle.AnalyzerExecutionProfilePath) -WorkingDirectory (Split-Path -Parent $Bundle.RunPath) -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds (Get-RunnerPreflightTimeoutSeconds) -Runner 'phase2' -WorkerId $Bundle.WorkerId -EvalId $null -Configuration 'analyzer' -Phase 'preflight' -ProgressLogPath $ProgressLogPath
        $exitCode = Complete-RunnerChildProcess -Child $child
        $child = $null
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
        $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 100 }
        return [pscustomobject]@{ ExitCode = $exitCode; Result = $result; Stdout = $stdout; Bundle = $Bundle }
    } finally {
        if ($null -ne $child) { try { [void](Complete-RunnerChildProcess -Child $child -TimeoutSeconds 1) } catch { } }
        foreach ($path in @($stdoutPath, $stderrPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertFrom-AnalyzerResponse {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Analyzer returned an empty response.' }
    try {
        return $Text | ConvertFrom-Json -Depth 100
    } catch {
        throw "Analyzer returned malformed JSON: $($_.Exception.Message)"
    }
}

function Confirm-AnalyzerFragment {
    param(
        [Parameter(Mandatory = $true)][object]$Fragment,
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $true)][object]$Canonical
    )

    if ([string](Get-JsonProperty -Object $Fragment -Name 'schema' -Default '') -ne 'codebeltnet/agentic/eval-analyzer-fragment/1') { throw 'Analyzer fragment has an unsupported schema.' }
    if ([int](Get-JsonProperty -Object $Fragment -Name 'eval_id' -Default 0) -ne [int]$Worker.eval_id -or [string](Get-JsonProperty -Object $Fragment -Name 'configuration' -Default '') -ne [string]$Worker.configuration) {
        throw 'Analyzer fragment does not match the requested eval arm.'
    }
    $grades = @(Get-JsonProperty -Object $Fragment -Name 'grading' -Default @())
    $expectedByIndex = @{}
    foreach ($assertion in @($Worker.assertions)) { $expectedByIndex[[int]$assertion.assertion_index] = $assertion }
    if ($grades.Count -ne @($Worker.assertions).Count) { throw 'Analyzer fragment grade cardinality does not match unresolved semantic assertions.' }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($grade in $grades) {
        $index = [int](Get-JsonProperty -Object $grade -Name 'assertion_index' -Default -1)
        if (-not $expectedByIndex.ContainsKey($index)) { throw "Analyzer fragment includes unexpected assertion_index '$index'." }
        $expected = $expectedByIndex[$index]
        if ((Get-JsonProperty -Object $grade -Name 'passed' -Default $null) -isnot [bool]) { throw 'Analyzer fragment passed must be boolean.' }
        $reason = [string](Get-JsonProperty -Object $grade -Name 'reason' -Default '')
        if ([string]::IsNullOrWhiteSpace($reason)) { throw 'Analyzer fragment reason must be non-empty.' }
        $refs = @(Get-JsonProperty -Object $grade -Name 'evidence_refs' -Default @())
        $entry = ConvertTo-GradingEntry -Expected $expected -Passed ([bool]$grade.passed) -Reason $reason -EvidenceRefs $refs -Source 'analyzer' -Evidence $reason
        [void](Test-GradeEvidenceReference -Grade $entry -Expected $expected -Canonical $Canonical)
        $entries.Add($entry)
    }
    return @($entries.ToArray())
}

function Get-ObservedAnalyzerModel {
    param([Parameter(Mandatory = $true)][object]$Raw)

    $delegation = Get-JsonProperty -Object (Get-JsonProperty -Object $Raw -Name 'evidence' -Default $null) -Name 'delegation' -Default $null
    $observed = [string](Get-JsonProperty -Object $delegation -Name 'observed_model' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($observed)) { return $observed }
    $resolved = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $Raw -Name 'resolved' -Default $null) -Name 'model' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }
    return ''
}

function New-AnalyzerResult {
    param(
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $true)][object]$Bundle,
        [Parameter(Mandatory = $true)][object]$Raw,
        [Parameter(Mandatory = $true)][object]$AnalyzerProfile,
        [Parameter(Mandatory = $true)][string]$RawRelative,
        [Parameter(Mandatory = $true)][string]$FragmentRelative,
        [Parameter(Mandatory = $true)][object[]]$Grades,
        [string]$Status = 'completed',
        [string]$Failure = ''
    )

    $delegation = Get-JsonProperty -Object (Get-JsonProperty -Object $Raw -Name 'evidence' -Default $null) -Name 'delegation' -Default $null
    $tokens = Get-JsonProperty -Object (Get-JsonProperty -Object $Raw -Name 'telemetry' -Default $null) -Name 'tokens' -Default $null
    $toolCalls = Get-JsonProperty -Object (Get-JsonProperty -Object $Raw -Name 'telemetry' -Default $null) -Name 'tool_calls' -Default $null
    $cost = Get-JsonProperty -Object (Get-JsonProperty -Object $Raw -Name 'telemetry' -Default $null) -Name 'cost' -Default $null
    $rawPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $RawRelative -FieldName 'analyzer raw execution result' -Kind File -RequireExists
    $fragmentPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $FragmentRelative -FieldName 'analyzer grading fragment' -Kind File -RequireExists
    return [ordered]@{
        schema = $script:AnalyzerResultSchema
        worker_id = [string]$Worker.worker_id
        eval_id = [int]$Worker.eval_id
        eval_name = [string]$Worker.eval_name
        configuration = [string]$Worker.configuration
        analyzer_profile_sha256 = [string]$AnalyzerProfile.Hash
        requested_runner = [string]$AnalyzerProfile.Runner
        requested_model = [string]$AnalyzerProfile.Model
        requested_reasoning_effort = $AnalyzerProfile.ReasoningEffort
        resolved_runner = [string](Get-JsonProperty -Object $Raw.runner -Name 'name' -Default '')
        resolved_model = [string](Get-JsonProperty -Object $Raw.requested -Name 'model' -Default '')
        observed_model = Get-ObservedAnalyzerModel -Raw $Raw
        harness_name = [string](Get-JsonProperty -Object $Raw.harness -Name 'name' -Default '')
        harness_version = [string](Get-JsonProperty -Object $Raw.harness -Name 'version' -Default '')
        session_id = [string](Get-JsonProperty -Object $delegation -Name 'worker_session_id' -Default (Get-JsonProperty -Object $Raw.session -Name 'id' -Default ''))
        started_utc = [string](Get-JsonProperty -Object $Raw -Name 'started_utc' -Default '')
        finished_utc = [string](Get-JsonProperty -Object $Raw -Name 'finished_utc' -Default '')
        duration_ms = [int64]([double](Get-JsonProperty -Object $Raw -Name 'duration_seconds' -Default 0) * 1000)
        terminal_status = $Status
        failure = $Failure
        input_bundle_sha256 = [string]$Bundle.BundleHash
        grader_contract_sha256 = Get-Sha256HexFromFile -Path (Join-Path (Split-Path -Parent $Bundle.BundlePath) 'grader.md')
        assertions_sha256 = Get-JsonFingerprint -Object @($Worker.assertions)
        raw_execution_result = $RawRelative
        raw_execution_result_sha256 = Get-Sha256HexFromFile -Path $rawPath
        grading_fragment = $FragmentRelative
        grading_fragment_sha256 = Get-Sha256HexFromFile -Path $fragmentPath
        parsed_grading = @($Grades)
        input_tokens = Get-JsonProperty -Object (Get-JsonProperty -Object $tokens -Name 'value' -Default $null) -Name 'input_tokens' -Default $null
        output_tokens = Get-JsonProperty -Object (Get-JsonProperty -Object $tokens -Name 'value' -Default $null) -Name 'output_tokens' -Default $null
        cache_read_tokens = Get-JsonProperty -Object (Get-JsonProperty -Object $tokens -Name 'value' -Default $null) -Name 'cached_input_tokens' -Default $null
        cache_write_tokens = Get-JsonProperty -Object (Get-JsonProperty -Object $tokens -Name 'value' -Default $null) -Name 'cache_write_tokens' -Default $null
        total_tokens = Get-JsonProperty -Object (Get-JsonProperty -Object $tokens -Name 'value' -Default $null) -Name 'total_tokens' -Default $null
        cost = Get-JsonProperty -Object $cost -Name 'value' -Default $null
        tool_calls = Get-JsonProperty -Object $toolCalls -Name 'value' -Default $null
        attempt_count = 1
    }
}

function Get-RootGradingMetadata {
    param([Parameter(Mandatory = $true)][object]$AnalyzerProfile)

    return [ordered]@{
        schema = 'codebeltnet/agentic/eval-grading-metadata/1'
        generated_by = 'phase2-controller'
        analyzer_runner = [string]$AnalyzerProfile.Runner
        analyzer_model = [string]$AnalyzerProfile.Model
        analyzer_reasoning_effort = $AnalyzerProfile.ReasoningEffort
        analyzer_profile_sha256 = [string]$AnalyzerProfile.Hash
        phase2_state = 'phase2-state.json'
        grading_freeze = 'grading-freeze.json'
    }
}

try {
    $manifestPath = Join-Path $iteration 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'manifest.json is missing.' }
    $manifest = Read-RunnerJson -Path $manifestPath
    [void](Assert-PackageRunnerToolsIntegrity -IterationDirectory $iteration -Manifest $manifest)
    $executionIdentity = Assert-PackageRunnerIdentity -IterationDirectory $iteration -Manifest $manifest
    $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    [void](Assert-FanoutPhase1Success -Aggregate $freezeValidation.Aggregate -MessagePrefix 'Phase 2 Phase 1')
    $bridgePath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath ([string]$manifest.runner_tools + '/bridge-manifest-results.ps1') -FieldName 'manifest bridge' -Kind File -RequireExists
    $bridgeArgs = @('-IterationDirectory', $iteration, '-RequireComplete', '-RequireParallelDispatch')
    if ([string](Get-JsonProperty -Object $executionIdentity.Descriptor.delegation -Name 'dispatch_owner' -Default '') -eq 'runner') { $bridgeArgs += '-RequireNativeDelegation' }
    $bridgeOutput = & pwsh -NoProfile -NonInteractive -File $bridgePath @bridgeArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Manifest bridge failed before Phase 2: $([string]::Join(' ', @($bridgeOutput)))" }

    $statePath = Join-Path $iteration 'phase2-state.json'
    $freezePath = Join-Path $iteration 'grading-freeze.json'
    if (Test-Path -LiteralPath $freezePath -PathType Leaf) {
        $validatedFreeze = Assert-GradingFreeze -IterationDirectory $iteration
        Write-Phase2Summary -Value ([ordered]@{
            schema = 'codebeltnet/agentic/eval-phase2-summary/1'
            status = 'already_frozen'
            analyzer_profile_sha256 = [string]$validatedFreeze.Analyzer.Hash
            grading_freeze = 'grading-freeze.json'
            grading = [string](Get-JsonProperty -Object $manifest -Name 'grading' -Default 'grading.json')
        })
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        throw 'Phase 2 state already exists without a valid grading freeze; refusing to duplicate analyzer work. Use a fresh package iteration.'
    }

    $analyzerProfile = Resolve-AnalyzerProfile -IterationDirectory $iteration -Manifest $manifest
    $analyzerRunner = Resolve-AnalyzerRunner -IterationDirectory $iteration -Manifest $manifest -AnalyzerProfile $analyzerProfile
    $phase2Root = Join-Path $iteration 'phase2'
    $validatorRoot = Join-Path $phase2Root 'validators'
    $resultRoot = Join-Path $phase2Root 'results'
    $fragmentRoot = Join-Path $phase2Root 'fragments'
    $progressRoot = Join-Path $iteration 'progress'
    New-Item -ItemType Directory -Path $phase2Root, $validatorRoot, $resultRoot, $fragmentRoot, $progressRoot -Force | Out-Null
    $progressLogPath = Join-Path $progressRoot 'phase2-progress.jsonl'

    $analyzerExecutionProfilePath = Join-Path $phase2Root 'analyzer-execution-profile.json'
    Write-RunnerJsonFile -Path $analyzerExecutionProfilePath -Value (New-AnalyzerExecutionProfile -AnalyzerProfile $analyzerProfile)
    $analyzerExecutionProfile = Resolve-ExecutionProfile -ProfilePath $analyzerExecutionProfilePath
    $graderContractPath = Get-GraderContractPath -IterationDirectory $iteration
    $graderContractText = [System.IO.File]::ReadAllText($graderContractPath, [System.Text.UTF8Encoding]::new($false))
    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest | Sort-Object EvalId, Configuration)
    $semanticWorkers = [System.Collections.Generic.List[object]]::new()
    $validatorEntries = [System.Collections.Generic.List[object]]::new()
    $grades = [System.Collections.Generic.List[object]]::new()

    foreach ($record in $records) {
        $canonical = Read-RunnerJson -Path $record.ResultPath
        $semanticAssertions = [System.Collections.Generic.List[object]]::new()
        $assertionIndex = 0
        foreach ($assertion in @(Get-EvalMetadataAssertionObjects -Record $record)) {
            $expected = [ordered]@{
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                assertion_index = $assertionIndex
                assertion = [string]$assertion.assertion
                evidence_domain = [string]$assertion.evidence_domain
                validator = Get-JsonProperty -Object $assertion -Name 'validator' -Default $null
                record = $record
            }
            if ([string]$assertion.evidence_domain -eq 'validator') {
                $validatorResult = Invoke-GradingValidatorRule -Rule ([string]$assertion.validator) -Canonical $canonical -Record $record
                $validatorRelative = ('phase2/validators/{0}-{1}-{2}.json' -f [int]$record.EvalId, [string]$record.Configuration, $assertionIndex)
                $validatorPath = Join-Path $iteration ($validatorRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                Write-RunnerJsonFile -Path $validatorPath -Value $validatorResult
                $validatorEntries.Add([ordered]@{
                    path = $validatorRelative
                    sha256 = Get-Sha256HexFromFile -Path $validatorPath
                    status = if ([bool]$validatorResult.passed) { 'passed' } else { 'failed' }
                    rule = [string]$assertion.validator
                    eval_id = [int]$record.EvalId
                    configuration = [string]$record.Configuration
                    assertion_index = $assertionIndex
                })
                $grades.Add((ConvertTo-GradingEntry -Expected $expected -Passed ([bool]$validatorResult.passed) -Reason ([string]$validatorResult.reason) -EvidenceRefs @($validatorResult.evidence_refs) -Source 'validator' -Evidence ([string]$validatorResult.reason)))
            } else {
                $semanticAssertions.Add($expected)
            }
            $assertionIndex++
        }
        if ($semanticAssertions.Count -gt 0) {
            $semanticWorkers.Add([ordered]@{
                worker_id = Get-ArmKey -EvalId ([int]$record.EvalId) -Configuration ([string]$record.Configuration)
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                record = $record
                assertions = @($semanticAssertions.ToArray())
            })
        }
    }

    $state = [ordered]@{
        schema = $script:Phase2Schema
        analyzer_profile_sha256 = [string]$analyzerProfile.Hash
        analyzer_runner = [string]$analyzerProfile.Runner
        analyzer_model = [string]$analyzerProfile.Model
        expected_worker_ids = @($semanticWorkers | ForEach-Object { [string]$_.worker_id })
        pending = @($semanticWorkers | ForEach-Object { [string]$_.worker_id })
        active = [ordered]@{}
        completed = [ordered]@{}
        started_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow)
        updated_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow)
        concurrency = $Concurrency
        validator_results = @($validatorEntries.ToArray())
        analyzer_results = @()
        grading_freeze = $null
        status = 'running'
    }
    Save-Phase2State -Path $statePath -State $state

    $bundles = @{}
    foreach ($worker in @($semanticWorkers)) {
        $bundle = New-AnalyzerRunBundle -Phase2Root $phase2Root -Worker $worker -AnalyzerProfile $analyzerProfile -AnalyzerExecutionProfilePath $analyzerExecutionProfile.Path -GraderContractText $graderContractText
        $bundles[$worker.worker_id] = $bundle
    }

    $preflightFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($worker in @($semanticWorkers)) {
        $preflight = Invoke-AnalyzerPreflight -RunnerPath $analyzerRunner.RunnerPath -Bundle $bundles[$worker.worker_id] -ProgressLogPath $progressLogPath
        if ([int]$preflight.ExitCode -ne 0 -or $null -eq $preflight.Result -or [string](Get-JsonProperty -Object $preflight.Result -Name 'status' -Default '') -ne 'compatible') {
            $preflightFailures.Add([string]$worker.worker_id)
        }
    }
    if ($preflightFailures.Count -gt 0) {
        $state.status = 'failed'
        Save-Phase2State -Path $statePath -State $state
        throw "Phase 2 analyzer preflight failed before execution for: $($preflightFailures -join ', ')."
    }

    $executorSessions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in @($freezeValidation.Freeze.executions)) {
        $session = [string](Get-JsonProperty -Object $entry -Name 'worker_session_id' -Default (Get-JsonProperty -Object $entry -Name 'thread_id' -Default ''))
        if (-not [string]::IsNullOrWhiteSpace($session)) { [void]$executorSessions.Add($session) }
    }

    $running = [System.Collections.Generic.List[object]]::new()
    $completedAnalyzerEntries = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $workersById = @{}
    foreach ($worker in @($semanticWorkers)) { $workersById[[string]$worker.worker_id] = $worker }

    while (@($state.pending).Count -gt 0 -or $running.Count -gt 0) {
        while (@($state.pending).Count -gt 0 -and $running.Count -lt $Concurrency) {
            $workerId = [string]@($state.pending)[0]
            $state.pending = @(@($state.pending) | Where-Object { [string]$_ -ne $workerId })
            $state.active[$workerId] = [ordered]@{ worker_id = $workerId; accepted_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow); attempt_count = 1 }
            Save-Phase2State -Path $statePath -State $state
            $bundle = $bundles[$workerId]
            $rawRelative = "phase2/results/$workerId.execution-result.json"
            $stderrRelative = "phase2/results/$workerId.stderr.txt"
            $rawPath = Join-Path $iteration ($rawRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $stderrPath = Join-Path $iteration ($stderrRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
            $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $analyzerRunner.RunnerPath, 'execute', '-Run', $bundle.RunPath, '-Profile', $analyzerExecutionProfile.Path) -WorkingDirectory (Split-Path -Parent $bundle.RunPath) -StdoutPath $rawPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -Runner ([string]$analyzerProfile.Runner) -WorkerId $workerId -EvalId $workersById[$workerId].eval_id -Configuration $workersById[$workerId].configuration -Phase 'phase2-analyzer' -ProgressLogPath $progressLogPath
            $running.Add([pscustomobject]@{ worker_id = $workerId; child = $child; Process = $child.Process; raw_relative = $rawRelative; stderr_relative = $stderrRelative; bundle = $bundle })
            [Console]::Error.WriteLine(("Phase 2: {0}/{1} analyzer workers terminal; active: {2}; analyzer: {3}/{4}" -f @($state.completed.Keys).Count, @($state.expected_worker_ids).Count, $workerId, [string]$analyzerProfile.Runner, [string]$analyzerProfile.Model))
        }
        if ($running.Count -eq 0) { break }
        $completedIndex = Wait-AnyRunnerChild -Running $running
        $item = $running[$completedIndex]
        $running.RemoveAt($completedIndex)
        $exitCode = Complete-RunnerChildProcess -Child $item.child
        $workerId = [string]$item.worker_id
        $worker = $workersById[$workerId]
        $rawPath = Join-Path $iteration ([string]$item.raw_relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $terminalStatus = 'completed'
        $terminalFailure = ''
        $workerGrades = @()
        try {
            if ($null -eq $exitCode -or [int]$exitCode -ne 0) { throw "Analyzer runner exited with code '$exitCode'." }
            $raw = Read-RunnerJson -Path $rawPath
            [void](Assert-ExecutionResult -Result $raw)
            [void](Assert-NativeWorkerTerminalEvidence -ExecutionEvidence $raw -Run (Resolve-RunContract -RunPath $item.bundle.RunPath) -RequestedModel ([string]$analyzerProfile.Model) -ExpectedRunner ([string]$analyzerProfile.Runner) -ExpectedMechanism ([string]$analyzerRunner.Descriptor.delegation.mechanism))
            if ([string]$raw.status -ne 'completed') { throw "Analyzer runner terminal status '$($raw.status)' is not completed." }
            $observedModel = Get-ObservedAnalyzerModel -Raw $raw
            if ([string]::IsNullOrWhiteSpace($observedModel) -or $observedModel -ne [string]$analyzerProfile.Model) { throw "Analyzer observed model '$observedModel' does not match requested '$($analyzerProfile.Model)'." }
            $sessionId = [string](Get-JsonProperty -Object $raw.session -Name 'id' -Default '')
            if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'Analyzer result did not expose a session id.' }
            if ($executorSessions.Contains($sessionId)) { throw 'Analyzer session reused an executor session identity.' }
            if (@($completedAnalyzerEntries | Where-Object { [string]$_.session_id -eq $sessionId }).Count -gt 0) { throw 'Analyzer worker session was reused across arms.' }
            $responseText = [string](Get-JsonProperty -Object $raw.final_response -Name 'text' -Default '')
            $fragment = ConvertFrom-AnalyzerResponse -Text $responseText
            $canonical = Read-RunnerJson -Path $worker.record.ResultPath
            $workerGrades = @(Confirm-AnalyzerFragment -Fragment $fragment -Worker $worker -Canonical $canonical)
            $fragmentRelative = "phase2/fragments/$workerId.grading-fragment.json"
            $fragmentPath = Join-Path $iteration ($fragmentRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            Write-RunnerJsonFile -Path $fragmentPath -Value $fragment
            foreach ($grade in $workerGrades) { $grades.Add($grade) }
            $analyzerResult = New-AnalyzerResult -Worker $worker -Bundle $item.bundle -Raw $raw -AnalyzerProfile $analyzerProfile -RawRelative ([string]$item.raw_relative) -FragmentRelative $fragmentRelative -Grades $workerGrades
            $resultRelative = "phase2/results/$workerId.analyzer-result.json"
            $resultPath = Join-Path $iteration ($resultRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            Write-RunnerJsonFile -Path $resultPath -Value $analyzerResult
            $completedAnalyzerEntries.Add([ordered]@{ path = $resultRelative; sha256 = Get-Sha256HexFromFile -Path $resultPath; status = 'completed'; worker_id = $workerId; session_id = $sessionId })
            $state.completed[$workerId] = [ordered]@{ worker_id = $workerId; status = 'completed'; analyzer_result = $resultRelative; analyzer_result_sha256 = Get-Sha256HexFromFile -Path $resultPath; terminal_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow); worker_session_id = $sessionId; attempt_count = 1 }
        } catch {
            $terminalStatus = 'failed'
            $terminalFailure = $_.Exception.Message
            $failed.Add("$workerId`: $terminalFailure")
            $state.completed[$workerId] = [ordered]@{ worker_id = $workerId; status = 'failed'; terminal_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow); failure = $terminalFailure; attempt_count = 1 }
        } finally {
            if ($state.active.Contains($workerId)) { $state.active.Remove($workerId) }
            $state.analyzer_results = @($completedAnalyzerEntries.ToArray())
            if ($terminalStatus -eq 'failed') { $state.status = 'failed' }
            Save-Phase2State -Path $statePath -State $state
            [Console]::Error.WriteLine(("Phase 2: {0}/{1} analyzer workers terminal; active: {2}; analyzer: {3}/{4}" -f @($state.completed.Keys).Count, @($state.expected_worker_ids).Count, ([string]::Join(',', @($state.active.Keys))), [string]$analyzerProfile.Runner, [string]$analyzerProfile.Model))
        }
    }

    if ($failed.Count -gt 0) {
        Write-Phase2Summary -Value ([ordered]@{
            schema = 'codebeltnet/agentic/eval-phase2-summary/1'
            status = 'failed'
            analyzer_profile_sha256 = [string]$analyzerProfile.Hash
            validator_results = @($validatorEntries).Count
            analyzer_workers = @($semanticWorkers).Count
            failed = @($failed.ToArray())
            phase2_state = 'phase2-state.json'
        }) -ExitCode 2
    }

    $rootMetadata = Get-RootGradingMetadata -AnalyzerProfile $analyzerProfile
    $rootGrading = New-RootGradingDocument -Grades @($grades.ToArray()) -Metadata $rootMetadata
    $gradingRelative = [string](Get-JsonProperty -Object $manifest -Name 'grading' -Default 'grading.json')
    $gradingPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $gradingRelative -FieldName 'grading path' -Kind File
    Write-RunnerJsonFile -Path $gradingPath -Value $rootGrading
    $state.analyzer_results = @($completedAnalyzerEntries.ToArray())
    $state.status = 'completed'
    Save-Phase2State -Path $statePath -State $state
    $freeze = New-GradingFreezeDocument -IterationDirectory $iteration -Manifest $manifest -State $state -Grades @($grades.ToArray()) -Metadata $rootMetadata
    Write-RunnerJsonFile -Path $freezePath -Value $freeze
    $state.grading_freeze = [ordered]@{ path = 'grading-freeze.json'; sha256 = Get-Sha256HexFromFile -Path $freezePath }
    Write-RunnerJsonFile -Path $statePath -Value $state
    [void](Assert-GradingFreeze -IterationDirectory $iteration -GradingPath $gradingRelative)
    Write-Phase2Summary -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-phase2-summary/1'
        status = 'completed'
        analyzer_profile_sha256 = [string]$analyzerProfile.Hash
        validator_results = @($validatorEntries).Count
        analyzer_workers = @($semanticWorkers).Count
        grading = $gradingRelative
        grading_sha256 = Get-Sha256HexFromFile -Path $gradingPath
        grading_freeze = 'grading-freeze.json'
        phase2_state = 'phase2-state.json'
        progress_log = 'progress/phase2-progress.jsonl'
    })
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
