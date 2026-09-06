<#!
.SYNOPSIS
    Deterministic frozen-evidence, grading-isolation, and finalization tests.

.DESCRIPTION
    Builds a package around the repository's model-free runner fixture. The
    fixture produces six native terminal results, including one scripted
    interaction case. This suite deliberately simulates the latest Copilot
    failure by writing grading into a raw execution result after Phase 1 and
    verifies that no later bridge or finalizer can bless or repair it.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repositoryRoot = (Resolve-Path (Join-Path $runnerRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'orchestration.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')

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

    Write-RunnerJsonFile -Path $Path -Value $Value
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

    $output = & pwsh -NoProfile -NonInteractive -File $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    }
}

function Invoke-ForegroundPhaseOne {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$IterationDirectory)

    # STDOUT is the machine protocol; STDERR is live observability. Capture them
    # separately so relayed heartbeats never contaminate the terminal JSON.
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('phase1-stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    try {
        $output = & pwsh -NoProfile -NonInteractive -File $Path -IterationDirectory $IterationDirectory 2>$stderrPath
        $exitCode = $LASTEXITCODE
        $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $document = $text | ConvertFrom-Json -Depth 100
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Stderr = $stderr; Document = $document }
}

function Assert-ToolPasses {
    param([Parameter(Mandatory = $true)][object]$Invocation, [Parameter(Mandatory = $true)][string]$Description)
    if ([int]$Invocation.ExitCode -ne 0) { throw "ASSERT: $Description failed: $($Invocation.Text)" }
}

function Assert-ToolFails {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$ExpectedText = ''
    )
    if ([int]$Invocation.ExitCode -eq 0) { throw "ASSERT: $Description unexpectedly passed: $($Invocation.Text)" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedText)) { Assert-Contains -Text $Invocation.Text -Expected $ExpectedText -Message $Description }
}

function New-TestRun {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][int]$EvalId,
        [Parameter(Mandatory = $true)][string]$EvalName,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [object]$Interaction = $null
    )

    $evalDirectory = Join-Path $IterationDirectory $EvalName
    $runDirectory = Join-Path $evalDirectory $Configuration
    $repoDirectory = Join-Path $runDirectory 'repo'
    $homeDirectory = Join-Path $runDirectory 'home'
    New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'execute-delay-ms'), '0', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "deterministic fixture prompt for $EvalName/$Configuration`n", [System.Text.UTF8Encoding]::new($false))

    $skillDirectory = $null
    if ($Configuration -eq 'with_skill') {
        $skillDirectory = Join-Path $runDirectory 'skill/test-skill'
        New-Item -ItemType Directory -Path $skillDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillDirectory 'SKILL.md'), '# deterministic fixture skill`n', [System.Text.UTF8Encoding]::new($false))
    }

    $interactionFile = $null
    $interactionHash = $null
    if ($null -ne $Interaction) {
        $interactionFile = Join-Path $runDirectory 'interaction.json'
        Write-TestJson -Path $interactionFile -Value $Interaction
        $interactionHash = Get-Sha256HexFromFile -Path $interactionFile
    }

    $run = [ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = $EvalId
        evalName = $EvalName
        skillName = if ($Configuration -eq 'with_skill') { 'test-skill' } else { $null }
        iteration = 1
        mode = $Configuration
        promptFile = 'prompt.md'
        workingDirectory = 'repo'
        homeDirectory = 'home'
        skillDirectory = if ($Configuration -eq 'with_skill') { 'skill/test-skill' } else { $null }
        freshContextRequired = $true
        filesystemIsolationRequired = $true
        isolatedHomeRequired = $true
        gitWorkspace = $false
        inputFiles = @()
        fixtureHash = ('a' * 64)
        skillHash = if ($Configuration -eq 'with_skill') { ('b' * 64) } else { $null }
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
    if ($null -ne $interactionFile) {
        $run.interactionFile = 'interaction.json'
        $run.interactionHash = $interactionHash
    }
    Write-TestJson -Path (Join-Path $runDirectory 'run.json') -Value $run

    return [pscustomobject]@{
        Directory = $runDirectory
        RunPath = Join-Path $runDirectory 'run.json'
        InteractionPath = $interactionFile
    }
}

function New-TestGradingDocument {
    param([Parameter(Mandatory = $true)][object[]]$Records)

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($Records | Sort-Object EvalId, Configuration)) {
        $metadata = Read-TestJson -Path $record.MetadataPath
        $assertions = @($metadata.assertions)
        for ($index = 0; $index -lt $assertions.Count; $index++) {
            $entries.Add([ordered]@{
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                assertion_index = $index
                assertion = [string]$assertions[$index]
                passed = $true
                evidence = 'deterministic grading-isolation fixture evidence'
            })
        }
    }
    return [ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = @($entries.ToArray()) }
}

function Remove-TestReportArtifacts {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)
    foreach ($relative in @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
        $path = Join-Path $IterationDirectory $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
}

function New-ProblematicProtocolString {
    return [string]::Concat('prefix:', [char]0x1A, [char]0x00, [char]0x09, [char]0x0D, [char]0x0A, [char]0x22, [char]0x5C, ':suffix')
}

function Assert-ProblematicProtocolString {
    param([Parameter(Mandatory = $true)][string]$Value)

    foreach ($codePoint in @(0x1A, 0x00, 0x09, 0x0D, 0x0A, 0x22, 0x5C)) {
        Assert-True ($Value.IndexOf([char]$codePoint) -ge 0) ("problematic protocol string contains literal 0x{0:X2}" -f $codePoint)
    }
}

function Get-StrictJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$PropertyPath
    )

    $json = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    $document = [System.Text.Json.JsonDocument]::Parse($json)
    try {
        $element = $document.RootElement
        foreach ($segment in $PropertyPath) {
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                $element = $element[[int]$segment]
            } else {
                $element = $element.GetProperty($segment)
            }
        }
        return $element.GetString()
    } finally {
        $document.Dispose()
    }
}

function Assert-StrictJsonRoundTrip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$PropertyPath,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actual = Get-StrictJsonString -Path $Path -PropertyPath $PropertyPath
    if ($Expected -cne $actual) {
        throw "ASSERT: $Message did not round-trip through strict JSON parsing"
    }
}

function Assert-ProtocolJsonSerializationRoundTrip {
    param([Parameter(Mandatory = $true)][string]$Root)

    $problematic = New-ProblematicProtocolString
    Assert-ProblematicProtocolString -Value $problematic
    $jsonPath = Join-Path $Root 'strict-json\protocol-owned-artifact.json'
    Write-RunnerJsonFile -Path $jsonPath -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-protocol-json-roundtrip-test/1'
        payload = [ordered]@{
            text = $problematic
            diagnostics = @([ordered]@{ message = $problematic })
        }
    })
    Assert-StrictJsonRoundTrip -Path $jsonPath -PropertyPath @('payload', 'text') -Expected $problematic -Message 'protocol-owned JSON string with control characters'
    Assert-StrictJsonRoundTrip -Path $jsonPath -PropertyPath @('payload', 'diagnostics', '0', 'message') -Expected $problematic -Message 'nested protocol-owned JSON diagnostic string with control characters'
}

function Assert-ExecutionResultSerializationRoundTrip {
    param([Parameter(Mandatory = $true)][string]$Root)

    $problematic = New-ProblematicProtocolString
    Assert-ProblematicProtocolString -Value $problematic
    $executionRoot = Join-Path $Root 'strict-json\execution-result-path'
    New-Item -ItemType Directory -Path $executionRoot -Force | Out-Null
    $runJson = Join-Path $executionRoot 'run.json'
    $promptPath = Join-Path $executionRoot 'prompt.md'
    $childScript = Join-Path $executionRoot 'write-execution-result.ps1'
    $executionResultPath = Join-Path $executionRoot 'model-output.execution-result.json'
    $stderrPath = Join-Path $executionRoot 'model-output.stderr.txt'
    [System.IO.File]::WriteAllText($runJson, '{}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($promptPath, 'strict JSON production path prompt', [System.Text.UTF8Encoding]::new($false))
    $childScriptText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CommonPath,
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunPath,
    [Parameter(Mandatory = $true)][string]$PromptHash
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $CommonPath
$problematic = [string]::Concat('prefix:', [char]0x1A, [char]0x00, [char]0x09, [char]0x0D, [char]0x0A, [char]0x22, [char]0x5C, ':suffix')
$hash = '0000000000000000000000000000000000000000000000000000000000000000'
$descriptor = [ordered]@{ name = 'strict-json-fixture'; version = '1'; harness = [ordered]@{ name = 'strict-json-fixture'; version = '1' } }
$profile = [pscustomobject]@{ Model = 'fixture-model'; ReasoningEffort = ''; ConfigurationProfile = 'isolated-default'; ToolProfile = 'default'; TimeoutSeconds = 1; Hash = $hash }
$run = [pscustomobject]@{ EvalId = 1; EvalName = 'strict-json'; Mode = 'with_skill'; PromptHash = $PromptHash; RunPath = $RunPath; RunRoot = $RunRoot; CandidateSkillExposed = $false }
$result = New-ExecutionResult -Descriptor $descriptor -Profile $profile -Run $run -Status completed -FinalResponse $problematic -StartedUtc ([DateTime]::UtcNow.ToString('o')) -FinishedUtc ([DateTime]::UtcNow.ToString('o')) -DurationSeconds 0 -ExitStatus 0 -Failure $null -SessionId 'strict-json-session' -IsolationCapabilities ([ordered]@{ fresh_context = 'supported'; isolated_home_config = 'supported'; isolated_working_directory = 'supported'; ambient_candidate_skill_exclusion = 'supported'; candidate_skill_exposure = 'excluded'; prompt_fidelity = 'supported'; model_configuration_lock = 'supported'; response_capture = 'supported'; filesystem_confinement = 'unsupported' }) -IsolationMechanisms @('strict-json-production-path') -Warnings @($problematic) -Evidence ([ordered]@{ diagnostic = $problematic }) -AttemptCount 1
Write-RunnerJson -Value $result -AsOutput
'@
    [System.IO.File]::WriteAllText($childScript, $childScriptText, [System.Text.UTF8Encoding]::new($false))
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $childScript, '-CommonPath', (Join-Path $runnerRoot 'runner-common.ps1'), '-RunRoot', $executionRoot, '-RunPath', $runJson, '-PromptHash', (Get-Sha256HexFromFile -Path $promptPath)) -WorkingDirectory $executionRoot -StdoutPath $executionResultPath -StderrPath $stderrPath -TimeoutSeconds 30
    $exitCode = Complete-RunnerChildProcess -Child $child
    Assert-Equal 0 $exitCode 'execution-result child writer exits successfully'
    Assert-StrictJsonRoundTrip -Path $executionResultPath -PropertyPath @('final_response', 'text') -Expected $problematic -Message 'execution-result final response with control characters'
    Assert-StrictJsonRoundTrip -Path $executionResultPath -PropertyPath @('warnings', '0') -Expected $problematic -Message 'execution-result warning with control characters'
    Assert-StrictJsonRoundTrip -Path $executionResultPath -PropertyPath @('evidence', 'diagnostic') -Expected $problematic -Message 'execution-result evidence with control characters'
}

function Get-TestFileHashSnapshot {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $snapshot = @{}
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        $snapshot[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Sha256HexFromFile -Path $path } else { '<missing>' }
    }
    return $snapshot
}

function Assert-TestFileHashSnapshot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    foreach ($path in @($Expected.Keys)) {
        $actual = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Sha256HexFromFile -Path $path } else { '<missing>' }
        Assert-Equal $Expected[$path] $actual "$Message preserves $path"
    }
}

function Get-GradingValidationSideEffectPaths {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $Records) {
        $paths.Add([string]$record.ExecutionResultPath)
        $paths.Add([string]$record.ResultPath)
    }
    foreach ($relative in @('orchestration-state.json', 'execution-freeze.json', 'report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
        $paths.Add((Join-Path $IterationDirectory $relative))
    }
    return @($paths.ToArray())
}

function Copy-TestGradingDocument {
    param([Parameter(Mandatory = $true)][object]$Document)

    return ConvertTo-RunnerJson -Value $Document -Depth 100 | ConvertFrom-Json -Depth 100
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-integrity-finalization-' + [Guid]::NewGuid().ToString('N'))
$oldReportMode = [Environment]::GetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE')
try {
    Assert-ProtocolJsonSerializationRoundTrip -Root $testRoot
    Assert-ExecutionResultSerializationRoundTrip -Root $testRoot

    $iteration = Join-Path $testRoot 'iteration-1'
    $packageTools = Join-Path $iteration 'tools/eval-runners'
    New-Item -ItemType Directory -Path $packageTools -Force | Out-Null

    # The package receives the same runner tree a prepared package would carry;
    # the selected fixture is deterministic and never calls a model.
    foreach ($item in @(Get-ChildItem -LiteralPath $runnerRoot -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $packageTools -Recurse -Force
    }
    $fixtureDirectory = Join-Path $packageTools 'fixture'
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests/fixtures/runner-owned-fixture.ps1') -Destination (Join-Path $fixtureDirectory 'runner.ps1') -Force

    $reportScript = Join-Path $iteration 'tools/test-report.ps1'
    $reportScriptText = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$IterationDirectory, [switch]$RequireComplete)
$ErrorActionPreference = 'Stop'
$mode = [Environment]::GetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE')
if ($mode -eq 'failure') { throw 'deterministic report fixture failure' }
$files = @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')
$count = if ($mode -eq 'missing') { 3 } else { 4 }
for ($index = 0; $index -lt $count; $index++) {
    $path = Join-Path $IterationDirectory $files[$index]
    $content = if ($files[$index] -eq 'benchmark.json') { '{"schema":"deterministic-report-fixture/1","status":"completed"}' } else { "deterministic report fixture: $($files[$index])`n" }
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}
'@
    [System.IO.File]::WriteAllText($reportScript, $reportScriptText, [System.Text.UTF8Encoding]::new($false))

    $interaction = [ordered]@{
        schema = (Get-RunnerSchemaNames).Interaction
        mode = 'scripted'
        turns = @(
            [ordered]@{ role = 'user'; source = 'prompt.md' }
            [ordered]@{ role = 'user'; content = 'Yes, proceed.' }
        )
    }

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le 3; $evalId++) {
        $evalName = if ($evalId -eq 2) { 'dotnet-strong-name-signing-confirmation' } else { 'integrity-eval-{0:d2}' -f $evalId }
        $evalDirectory = Join-Path $iteration $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        $assertion = if ($evalId -eq 2) { 'the protected operation is absent before confirmation and occurs only after the same-session confirmation turn' } else { 'the deterministic terminal response is captured' }
        Write-TestJson -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value ([ordered]@{
            schema = 'codebeltnet/agentic/eval-metadata/1'
            eval_id = $evalId
            eval_name = $evalName
            prompt = "fixture prompt $evalId"
            expected_output = 'fixture output'
            assertions = @($assertion)
        })
        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $interactionForRun = if ($evalId -eq 2) { $interaction } else { $null }
            $run = New-TestRun -IterationDirectory $iteration -EvalId $evalId -EvalName $evalName -Configuration $configuration -Interaction $interactionForRun
            $resultName = "$configuration.result.json"
            $executionName = "$configuration.execution-result.json"
            Write-TestJson -Path (Join-Path $evalDirectory "results/$resultName") -Value ([ordered]@{
                schema = (Get-RunnerSchemaNames).PortableResult
                eval_id = $evalId
                eval_name = $evalName
                configuration = $configuration
                execution_status = 'unrun'
                grading = @([ordered]@{ text = $assertion; passed = $null; evidence = '' })
            })
            $runs[$configuration] = [ordered]@{
                mode = $configuration
                run_manifest = "$evalName/$configuration/run.json"
                execution_result = "$evalName/results/$executionName"
                result = "$evalName/results/$resultName"
            }
        }
        $manifestEvals.Add([ordered]@{
            eval_id = $evalId
            eval_name = $evalName
            directory = $evalName
            metadata = "$evalName/eval-metadata.json"
            runs = $runs
        })
    }

    $toolIntegrity = Get-PackageTreeIntegrity -Root $packageTools
    $manifest = [ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_selection = [ordered]@{ harness = 'Deterministic runner-owned fixture'; runner = 'fixture'; model = 'fixture-model'; preset = 'Integrity fixture' }
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $toolIntegrity.Sha256; file_count = $toolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        grading = 'grading.json'
        report = [ordered]@{ tool = 'tools/test-report.ps1' }
        evals = @($manifestEvals.ToArray())
    }
    $profile = [ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 60
        concurrency = 3
    }
    Write-TestJson -Path (Join-Path $iteration 'manifest.json') -Value $manifest
    Write-TestJson -Path (Join-Path $iteration 'execution-profile.json') -Value $profile

    $fanoutScript = Join-Path $packageTools 'invoke-runner-owned-arms.ps1'
    $fanout = Invoke-ForegroundPhaseOne -Path $fanoutScript -IterationDirectory $iteration
    Assert-ToolPasses -Invocation $fanout -Description 'runner-owned fixture Phase 1'
    $fanoutSummary = $fanout.Document
    Assert-Equal 'completed' $fanoutSummary.status 'six deterministic fixture arms complete'
    Assert-Equal 6 $fanoutSummary.execution_count 'six raw execution results are registered'
    Assert-True (Test-Path -LiteralPath (Join-Path $iteration 'execution-freeze.json') -PathType Leaf) 'Phase 1 writes an execution freeze'

    $freeze = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    Assert-Equal 6 @($freeze.Freeze.executions).Count 'execution freeze contains all six arms'
    Assert-Equal 'arm-1-with_skill' $freeze.Freeze.executions[0].worker_id 'freeze ordering is deterministic'
    Assert-Equal 'arm-3-without_skill' $freeze.Freeze.executions[5].worker_id 'freeze ordering includes the final arm'
    Assert-True (Test-Sha256 -Value ([string]$freeze.Freeze.orchestration_state_sha256)) 'freeze anchors the terminal orchestration ledger'

    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest (Read-TestJson -Path (Join-Path $iteration 'manifest.json')) | Sort-Object EvalId, Configuration)
    $rawBeforeSecondPhase = @{}
    foreach ($record in $records) { $rawBeforeSecondPhase[$record.ExecutionResultPath] = Get-Sha256HexFromFile -Path $record.ExecutionResultPath }
    $secondPhaseOne = Invoke-TestTool -Path (Join-Path $packageTools 'fixture/runner.ps1') -Arguments @('execute', '-Run', $records[0].RunManifestPath, '-Profile', (Join-Path $iteration 'execution-profile.json'))
    Assert-ToolFails -Invocation $secondPhaseOne -Description 'runner refuses execution after the raw-evidence freeze' -ExpectedText 'already frozen'
    foreach ($record in $records) { Assert-Equal $rawBeforeSecondPhase[$record.ExecutionResultPath] (Get-Sha256HexFromFile -Path $record.ExecutionResultPath) 'post-freeze runner refusal leaves raw evidence unchanged' }
    foreach ($record in $records) {
        $raw = Read-TestJson -Path $record.ExecutionResultPath
        [void](Assert-ExecutionResult -Result $raw)
        if ($record.EvalId -eq 2) {
            [void](Assert-InteractionResultEvidence -ExecutionResult $raw -RunData (Resolve-RunContract -RunPath $record.RunManifestPath))
            $turns = @($raw.evidence.interaction.turns)
            Assert-Equal 4 $turns.Count 'strong-name confirmation fixture preserves two user/assistant pairs'
            Assert-Equal ([string]$turns[0].session_id) ([string]$turns[3].session_id) 'scripted fixture preserves one session identity'
            $eventPath = Join-Path (Split-Path -Parent $record.RunManifestPath) 'evidence/fixture-events.jsonl'
            $events = @(Get-Content -LiteralPath $eventPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal 5 $events.Count 'strong-name confirmation fixture records the protected operation event'
            Assert-Equal 'user.dispatched' $events[0].type 'first scripted event is the user dispatch'
            Assert-Equal 'assistant.terminal' $events[1].type 'second scripted event is the first assistant terminal response'
            Assert-Equal 'user.dispatched' $events[2].type 'follow-up dispatch waits for first terminal response'
            Assert-Equal 'protected.operation' $events[3].type 'protected operation occurs after the confirmation dispatch'
            Assert-Equal 'assistant.terminal' $events[4].type 'final scripted event is the second assistant terminal response'
            Assert-True ([int]$events[3].sequence -gt [int]$events[2].sequence) 'protected operation follows the confirmation user turn'
            Assert-True ((@($events | Where-Object { $_.type -eq 'protected.operation' -and [int]$_.sequence -le [int]$events[2].sequence }).Count) -eq 0) 'protected operation evidence cannot appear before confirmation'
        }
    }

    $bridgeScript = Join-Path $packageTools 'bridge-manifest-results.ps1'
    $bridgeArguments = @('-IterationDirectory', $iteration, '-RequireComplete', '-RequireParallelDispatch')
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'initial frozen manifest bridge'
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'unchanged idempotent manifest bridge'

    $statePath = Join-Path $iteration 'orchestration-state.json'
    $stateBytes = [System.IO.File]::ReadAllBytes($statePath)
    $tamperedState = Read-TestJson -Path $statePath
    $tamperedState.max_observed_active = 1
    Write-TestJson -Path $statePath -Value $tamperedState
    $tamperedStateBridge = Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments
    Assert-ToolFails -Invocation $tamperedStateBridge -Description 'bridge rejects post-freeze orchestration-state mutation' -ExpectedText 'orchestration-state.json changed'
    [System.IO.File]::WriteAllBytes($statePath, $stateBytes)
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'bridge passes after exact orchestration-state restoration'

    $selectedRecord = $records[0]
    $selectedRawBytes = [System.IO.File]::ReadAllBytes($selectedRecord.ExecutionResultPath)
    $selectedRawHash = Get-Sha256HexFromFile -Path $selectedRecord.ExecutionResultPath
    $selectedRaw = Read-TestJson -Path $selectedRecord.ExecutionResultPath
    $selectedRaw | Add-Member -NotePropertyName grading -NotePropertyValue @([ordered]@{ passed = $true })
    Write-TestJson -Path $selectedRecord.ExecutionResultPath -Value $selectedRaw
    $corruptedBridge = Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments
    Assert-ToolFails -Invocation $corruptedBridge -Description 'bridge rejects raw grading mutation' -ExpectedText 'Execution integrity failure'
    Assert-Contains -Text $corruptedBridge.Text -Expected 'requires fresh Phase 1 execution' -Message 'raw mutation requires fresh Phase 1 execution'
    $freezeAfterRawMutation = Read-TestJson -Path (Join-Path $iteration 'execution-freeze.json')
    Assert-Equal $selectedRawHash (Get-JsonProperty -Object $freezeAfterRawMutation.executions[0] -Name 'execution_result_sha256') 'freeze hash is not re-blessed after raw mutation'
    [System.IO.File]::WriteAllBytes($selectedRecord.ExecutionResultPath, $selectedRawBytes)
    Assert-Equal $selectedRawHash (Get-Sha256HexFromFile -Path $selectedRecord.ExecutionResultPath) 'exact raw bytes are restored'
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'bridge passes after exact raw restoration'

    $artifactPath = Join-Path (Split-Path -Parent $selectedRecord.RunManifestPath) 'evidence/fixture-events.jsonl'
    $artifactBytes = [System.IO.File]::ReadAllBytes($artifactPath)
    [System.IO.File]::WriteAllBytes($artifactPath, $artifactBytes + [byte[]](0x20))
    $corruptedArtifactBridge = Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments
    Assert-ToolFails -Invocation $corruptedArtifactBridge -Description 'bridge rejects referenced artifact mutation' -ExpectedText 'Execution integrity failure'
    [System.IO.File]::WriteAllBytes($artifactPath, $artifactBytes)
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'bridge passes after exact artifact restoration'

    $gradingPath = Join-Path $iteration 'grading.json'
    $validGrading = New-TestGradingDocument -Records $records
    $validationScript = Join-Path $packageTools 'validate-eval-grading.ps1'
    $validationArguments = @('-IterationDirectory', $iteration, '-GradingPath', 'grading.json')
    $validationSideEffectPaths = Get-GradingValidationSideEffectPaths -IterationDirectory $iteration -Records $records
    $validationSnapshot = Get-TestFileHashSnapshot -Paths $validationSideEffectPaths

    $skeleton = Invoke-TestTool -Path $validationScript -Arguments @('-ShowSkeleton')
    Assert-ToolPasses -Invocation $skeleton -Description 'grading skeleton emission'
    $skeletonDocument = $skeleton.Text | ConvertFrom-Json -Depth 100
    Assert-Equal (Get-RunnerSchemaNames).Grading ([string]$skeletonDocument.schema) 'grading skeleton uses the authoritative grading schema'
    Assert-Equal 0 @($skeletonDocument.grading).Count 'grading skeleton exposes an empty grading array'
    Assert-Equal 'schema,grading' ([string]::Join(',', @($skeletonDocument.PSObject.Properties.Name))) 'grading skeleton exposes only the grading envelope'
    Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'grading skeleton emission'

    [System.IO.File]::WriteAllText($gradingPath, '{', [System.Text.UTF8Encoding]::new($false))
    $malformedValidation = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
    Assert-ToolFails -Invocation $malformedValidation -Description 'malformed grading JSON validation'
    Assert-True (-not [string]::IsNullOrWhiteSpace($malformedValidation.Text)) 'malformed grading validation emits a diagnostic'
    $malformedValidationAgain = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
    Assert-ToolFails -Invocation $malformedValidationAgain -Description 'repeated malformed grading JSON validation'
    Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'repeated invalid grading validation'

    Write-TestJson -Path $gradingPath -Value ([ordered]@{ grading = @() })
    Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'missing grading schema validation' -ExpectedText 'must declare'
    Write-TestJson -Path $gradingPath -Value ([ordered]@{ schema = 'wrong/schema'; grading = @() })
    Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'wrong grading schema validation' -ExpectedText 'must declare'
    Write-TestJson -Path $gradingPath -Value ([ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = [ordered]@{} })
    Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'wrong grading envelope validation' -ExpectedText 'grading must be an array'
    $invalidEntry = Copy-TestGradingDocument -Document $validGrading
    $invalidEntry.grading[0].passed = 'yes'
    Write-TestJson -Path $gradingPath -Value $invalidEntry
    Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'invalid grading entry validation' -ExpectedText 'passed must be a boolean'
    Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'invalid grading validation'

    Write-TestJson -Path $gradingPath -Value $validGrading
    $validValidation = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
    Assert-ToolPasses -Invocation $validValidation -Description 'valid grading validation'
    $validValidationAgain = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
    Assert-ToolPasses -Invocation $validValidationAgain -Description 'repeated valid grading validation'
    Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'repeated valid grading validation'

    $invalidDirectFinalizer = Copy-TestGradingDocument -Document $validGrading
    $invalidDirectFinalizer.grading[0].evidence = 123
    Write-TestJson -Path $gradingPath -Value $invalidDirectFinalizer
    $finalizerScript = Join-Path $packageTools 'finalize-eval-package.ps1'
    $finalizerArguments = @('-IterationDirectory', $iteration, '-GradingPath', 'grading.json')
    $directInvalidFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
    Assert-ToolFails -Invocation $directInvalidFinalizer -Description 'finalizer performs its own grading validation' -ExpectedText 'evidence must be a string'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $iteration 'report.html') -PathType Leaf)) 'invalid direct finalizer produces no report'

    Write-TestJson -Path $gradingPath -Value $validGrading
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'valid grading validation before application'
    $canonicalBeforeGrading = @{}
    foreach ($record in $records) { $canonicalBeforeGrading[$record.ResultPath] = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object (Read-TestJson -Path $record.ResultPath) -PropertyName 'grading') }
    $applyScript = Join-Path $packageTools 'apply-eval-grading.ps1'
    $applyArguments = @('-IterationDirectory', $iteration, '-GradingPath', 'grading.json')
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $applyScript -Arguments $applyArguments) -Description 'allowed grading-only artifact application'
    foreach ($record in $records) {
        $canonical = Read-TestJson -Path $record.ResultPath
        Assert-Equal $canonicalBeforeGrading[$record.ResultPath] (Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $canonical -PropertyName 'grading')) 'grading application leaves canonical non-grading fields unchanged'
    }

    $invalidGrading = [ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = @($validGrading.grading); output = 'raw output is forbidden here' }
    Write-TestJson -Path $gradingPath -Value $invalidGrading
    $invalidApply = Invoke-TestTool -Path $applyScript -Arguments $applyArguments
    Assert-ToolFails -Invocation $invalidApply -Description 'grading artifact with raw output is rejected' -ExpectedText 'unsupported field'

    $forbiddenGradingFields = @('model', 'harness', 'execution_result_sha256', 'session_id', 'telemetry')
    foreach ($forbiddenField in $forbiddenGradingFields) {
        $forbiddenEntries = @($validGrading.grading | ForEach-Object {
            $copy = [ordered]@{}
            foreach ($name in @('eval_id', 'eval_name', 'configuration', 'assertion_index', 'assertion', 'passed', 'evidence')) {
                $copy[$name] = Get-JsonProperty -Object $_ -Name $name
            }
            $copy[$forbiddenField] = 'forbidden'
            $copy
        })
        Write-TestJson -Path $gradingPath -Value ([ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = $forbiddenEntries })
        $forbiddenApply = Invoke-TestTool -Path $applyScript -Arguments $applyArguments
        Assert-ToolFails -Invocation $forbiddenApply -Description "grading artifact with $forbiddenField is rejected" -ExpectedText 'unsupported field'
    }
    Write-TestJson -Path $gradingPath -Value $validGrading

    $canonicalPath = $records[0].ResultPath
    $canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
    $tamperedCanonical = Read-TestJson -Path $canonicalPath
    $tamperedCanonical.output = 'manual canonical tampering'
    Write-TestJson -Path $canonicalPath -Value $tamperedCanonical
    $canonicalTamperFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
    Assert-ToolFails -Invocation $canonicalTamperFinalizer -Description 'finalizer rejects canonical non-grading mutation' -ExpectedText 'Execution integrity failure'
    Remove-TestReportArtifacts -IterationDirectory $iteration
    [System.IO.File]::WriteAllBytes($canonicalPath, $canonicalBytes)

    $canonicalApplyTamperBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
    $canonicalApplyTamper = Read-TestJson -Path $canonicalPath
    $canonicalApplyTamper.output = 'direct application tampering'
    Write-TestJson -Path $canonicalPath -Value $canonicalApplyTamper
    $canonicalApplyTamperResult = Invoke-TestTool -Path $applyScript -Arguments $applyArguments
    Assert-ToolFails -Invocation $canonicalApplyTamperResult -Description 'grading application rejects canonical non-grading mutation before applying' -ExpectedText 'Execution integrity failure'
    [System.IO.File]::WriteAllBytes($canonicalPath, $canonicalApplyTamperBytes)

    # Exact reproduction of the latest Copilot mistake: grading is written to
    # execution-result.json after a valid bridge. The finalizer must fail closed
    # and must not repair the bytes or create report artifacts.
    $copilotMistakeBytes = [System.IO.File]::ReadAllBytes($selectedRecord.ExecutionResultPath)
    $copilotMistakeRaw = Read-TestJson -Path $selectedRecord.ExecutionResultPath
    $copilotMistakeRaw | Add-Member -NotePropertyName grading -NotePropertyValue @([ordered]@{ text = 'wrong location' })
    Write-TestJson -Path $selectedRecord.ExecutionResultPath -Value $copilotMistakeRaw
    Remove-TestReportArtifacts -IterationDirectory $iteration
    $copilotMistakeFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
    Assert-ToolFails -Invocation $copilotMistakeFinalizer -Description 'finalizer rejects Copilot raw-result grading mistake' -ExpectedText 'Execution integrity failure'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $iteration 'report.html') -PathType Leaf)) 'corrupted package produces no report'
    [System.IO.File]::WriteAllBytes($selectedRecord.ExecutionResultPath, $copilotMistakeBytes)
    Assert-Equal $selectedRawHash (Get-Sha256HexFromFile -Path $selectedRecord.ExecutionResultPath) 'Copilot mistake restoration returns exact frozen bytes'

    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', 'missing')
    Remove-TestReportArtifacts -IterationDirectory $iteration
    $missingReportFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
    Assert-ToolFails -Invocation $missingReportFinalizer -Description 'finalizer rejects missing report artifact'
    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', 'failure')
    Remove-TestReportArtifacts -IterationDirectory $iteration
    $failedReportFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
    Assert-ToolFails -Invocation $failedReportFinalizer -Description 'finalizer rejects report generator failure' -ExpectedText 'Report generation failed'

    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', '')
    Remove-TestReportArtifacts -IterationDirectory $iteration
    Write-TestJson -Path $gradingPath -Value $validGrading
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'correctly validated grading before finalization'
    $successfulFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
    Assert-ToolPasses -Invocation $successfulFinalizer -Description 'deterministic finalizer success'
    $finalSummary = $successfulFinalizer.Text | ConvertFrom-Json -Depth 100 | Select-Object -Last 1
    Assert-Equal 'completed' $finalSummary.status 'finalizer returns machine-readable completed status'
    foreach ($relative in @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
        $artifact = Join-Path $iteration $relative
        Assert-True (Test-Path -LiteralPath $artifact -PathType Leaf) "finalizer creates $relative"
        Assert-True ((Get-Item -LiteralPath $artifact).Length -gt 0) "$relative is non-empty"
    }

    Write-Output 'Eval package integrity and finalization: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', $oldReportMode)
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
