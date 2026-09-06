<#!
.SYNOPSIS
    Model-free Copilot Git/cache/home lifecycle and portable transcript regressions.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')

# Import definitions only: neither adapter dispatch nor a real CLI is invoked.
foreach ($file in @('github-copilot/runner.ps1', 'bridge-execution-result.ps1', 'tests/test-runner-conformance.ps1', '../generate-eval-report.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $runnerRoot $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $file`: $errors" }
    foreach ($definition in $ast.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
            Invoke-Expression $definition.Extent.Text
        }
        if ($file -eq 'github-copilot/runner.ps1' -and $definition -is [Management.Automation.Language.AssignmentStatementAst] -and
            $definition.Left.Extent.Text -eq '$descriptor') { Invoke-Expression $definition.Extent.Text }
    }
}
$copilotAuthVariables = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
function Resolve-CopilotAuthentication { return [pscustomobject]@{ Source = 'fixture'; TokenVariable = $null; TokenValue = $null; GitHubCliTokenResolved = $false } }
function Resolve-SandboxCommand { param($Name) return $null }
function Resolve-ExternalCommand { param($Name) if ($Name -ne 'copilot') { throw "Unexpected executable lookup: $Name" }; return $fakeCommand }
function Get-CopilotPreflight {
    param($Inputs)
    return [pscustomobject]@{
        status = 'compatible'; harness = @{ name = 'GitHub Copilot CLI'; version = 'fixture' }
        protocol_observations = @{ scripted_multi_turn_same_session = @{ available = $true; flag = '--resume'; argument_style = 'equals'; parameter = '<session-id>' } }
    }
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('copilot-boundaries-workspace-' + [Guid]::NewGuid().ToString('N'))
$parentCeiling = [Environment]::GetEnvironmentVariable('GIT_CEILING_DIRECTORIES')
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    & git init --quiet $testRoot
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize outer fixture Git repository.' }
    $fakePath = Join-Path $testRoot 'fake-copilot.ps1'
    [IO.File]::WriteAllText($fakePath, @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
$ErrorActionPreference = 'Stop'
$arguments = @($RemainingArguments)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$inputText = [Console]::In.ReadToEnd()
$turn = if (@($arguments | Where-Object { $_ -like '--resume=*' }).Count) { 2 } else { 1 }
$runHome = $env:HOME
$paths = @('.cache/copilot', '.copilot', '.config', '.local', 'tmp', 'AppData')
if ($turn -eq 2) {
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath (Join-Path $runHome "$path/runtime.txt"))) { throw 'Home was cleaned between turns.' }
    }
}
foreach ($path in $paths) {
    [void][IO.Directory]::CreateDirectory((Join-Path $runHome $path))
    [IO.File]::WriteAllText((Join-Path $runHome "$path/runtime.txt"), 'runtime state')
}
[IO.File]::WriteAllText((Join-Path $runHome 'README.txt'), 'runtime changed baseline')
[IO.File]::WriteAllBytes((Join-Path $runHome 'baseline/nested.bin'), [byte[]]@(99))
$gitResult = & git rev-parse --show-toplevel 2>$null
$gitExit = $LASTEXITCODE
$record = [ordered]@{ turn = $turn; arguments = $arguments; cwd = (Get-Location).Path; ceiling = $env:GIT_CEILING_DIRECTORIES; cache = $env:COPILOT_CACHE_HOME; xdg = $env:XDG_CACHE_HOME; localappdata = $env:LOCALAPPDATA; appdata = $env:APPDATA; git_exit = $gitExit; git_root = [string]$gitResult; old_cache_exists = Test-Path -LiteralPath (Join-Path $runHome '.copilot-cache'); double_suffix_exists = Test-Path -LiteralPath (Join-Path $env:COPILOT_CACHE_HOME 'copilot') }
[IO.File]::AppendAllText((Join-Path (Get-Location).Path 'fake-log.jsonl'), (($record | ConvertTo-Json -Compress) + "`n"))
[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'task-output.txt'), 'keep repo output')
if ($inputText -eq 'timeout') { [Console]::Out.WriteLine('{"type":"session.start","data":{"sessionId":"fixture-session"}}'); [Console]::Out.Flush(); Start-Sleep -Seconds 30 }
$text = if ($turn -eq 1) { 'Confirm before generation. Δ' } else { "Generated successfully.`nExact terminal text." }
@{ type = 'session.start'; data = @{ sessionId = 'fixture-session' } } | ConvertTo-Json -Compress
@{ type = 'assistant.message'; data = @{ content = $text; model = 'fixture-model' } } | ConvertTo-Json -Compress
1..150 | ForEach-Object { '{"type":"future.event","data":{}}' }
'{"type":"other.future.event","data":{}}'
'{"type":"session.task_complete","data":{"sessionId":"fixture-session"}}'
if ($inputText -eq 'failure') { exit 7 }
'@)
    $fakeCommand = [pscustomobject]@{ FileName = (Get-Command pwsh).Source; Prefix = @('-NoProfile', '-NonInteractive', '-File', $fakePath) }
    $iteration = Join-Path $testRoot 'iteration-1'
    $interaction = @{ schema = (Get-RunnerSchemaNames).Interaction; mode = 'scripted'; turns = @(@{ role = 'user'; source = 'prompt.md' }, @{ role = 'user'; content = 'Yes, generate the key.' }) }
    $with = New-TestRun -IterationDirectory $iteration -Configuration with_skill -Interaction $interaction
    $without = New-TestRun -IterationDirectory $iteration -Configuration without_skill
    $profilePath = Join-Path $iteration 'execution-profile.json'
    Write-TestJson -Path $profilePath -Value @{ schema = (Get-RunnerSchemaNames).Profile; runner = 'github-copilot'; model = 'fixture-model'; reasoning_effort = $null; configuration_profile = 'isolated-default'; tool_profile = 'default'; timeout_seconds = 15; concurrency = 1 }
    foreach ($run in @($with, $without)) {
        [void][IO.Directory]::CreateDirectory((Join-Path $run.Root 'home/baseline/empty'))
        [IO.File]::WriteAllBytes((Join-Path $run.Root 'home/baseline/nested.bin'), [byte[]]@(0, 255, 10, 13, 42))
        [IO.File]::WriteAllBytes((Join-Path $run.Root 'home/baseline/empty.bin'), [byte[]]@())
        [void][IO.Directory]::CreateDirectory((Join-Path $run.Root 'evidence'))
        [IO.File]::WriteAllText((Join-Path $run.Root 'evidence/prepared.txt'), 'keep evidence')
    }
    $inputs = [pscustomobject]@{ Run = Resolve-RunContract -RunPath $with.Path; Profile = Resolve-ExecutionProfile -ProfilePath $profilePath }
    $baseline = Get-CopilotHomeBaseline -HomePath $inputs.Run.HomeDirectoryPath
    $baselineHash = Get-TestTreeHash -Root $inputs.Run.HomeDirectoryPath
    $result = Invoke-CopilotWithPreparedHome -Inputs $inputs -Action { Invoke-CopilotExecute -Inputs $inputs }
    Assert-Equal 'completed' $result.status 'scripted fake Copilot completes'
    Assert-Equal $baselineHash (Get-TestTreeHash -Root $inputs.Run.HomeDirectoryPath) 'prepared file bytes restored exactly after terminal turn'
    Assert-True (Test-Path -LiteralPath (Join-Path $inputs.Run.HomeDirectoryPath 'baseline/empty')) 'empty baseline directories restored'
    Assert-Equal @($baseline.Entries).Count @(Get-ChildItem -LiteralPath $inputs.Run.HomeDirectoryPath -Force -Recurse).Count 'no generated home entries survive'
    Restore-CopilotHomeBaseline -Baseline $baseline
    Assert-Equal $baselineHash (Get-TestTreeHash -Root $inputs.Run.HomeDirectoryPath) 'terminal restoration is idempotent'
    $linkPath = Join-Path $inputs.Run.HomeDirectoryPath 'runtime-link'
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $linkPath -Target $inputs.Run.WorkingDirectoryPath | Out-Null
    Restore-CopilotHomeBaseline -Baseline $baseline
    Assert-True (-not (Test-Path -LiteralPath $linkPath)) 'cleanup removes runtime links without following them'
    Assert-Equal 'keep repo output' ([IO.File]::ReadAllText((Join-Path $with.Root 'repo/task-output.txt'))) 'repo output survives'
    Assert-Equal 'keep evidence' ([IO.File]::ReadAllText((Join-Path $with.Root 'evidence/prepared.txt'))) 'prepared evidence survives'
    Assert-True (Test-Path -LiteralPath (Join-Path $with.Root 'evidence/copilot-turn-2-events.jsonl')) 'terminal capture survives'
    $records = @(Get-Content -LiteralPath (Join-Path $with.Root 'repo/fake-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal 2 $records.Count 'both turns execute with shared runtime state'
    foreach ($record in $records) {
        Assert-Equal $with.Root $record.ceiling 'exact child environment ceiling is the manifest RunRoot'
        Assert-True ($record.git_exit -ne 0) 'child git cannot discover outer/.git from non-Git staged repo'
        Assert-Equal $inputs.Run.WorkingDirectoryPath $record.cwd 'child working directory retained'
        $argsList = [string[]]$record.arguments
        Assert-Equal $inputs.Run.WorkingDirectoryPath $argsList[[Array]::IndexOf($argsList, '-C') + 1] '-C retained'
        Assert-Equal 'fixture-model' $argsList[[Array]::IndexOf($argsList, '--model') + 1] 'model lock retained on every turn'
        Assert-Equal (Join-Path $inputs.Run.HomeDirectoryPath '.cache/copilot') $record.cache 'complete Copilot cache override, no duplicate suffix'
        Assert-Equal (Join-Path $inputs.Run.HomeDirectoryPath '.cache') $record.xdg 'XDG cache root'
        Assert-True (-not $record.old_cache_exists -and -not $record.double_suffix_exists) 'no old or double-suffixed cache is created during execution'
        if ($IsWindows) {
            Assert-Equal $record.xdg $record.localappdata 'Windows cache fallback converges'
            Assert-Equal (Join-Path $inputs.Run.HomeDirectoryPath '.config') $record.appdata 'Windows config root isolated'
        }
    }
    Assert-True (@($records[1].arguments) -contains '--resume=fixture-session') 'exact session continuation retained'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $with.Root 'home/.copilot-cache'))) 'old cache tree absent'
    Assert-Equal 300 $result.evidence.event_counts['future.event'] 'event counts span every scripted invocation'
    Assert-Equal 2 @($result.warnings | Where-Object { $_ -like 'Unknown Copilot event*' }).Count 'one warning per distinct unknown type for entire arm'
    Assert-True (@($result.warnings) -contains "Unknown Copilot event 'future.event' was preserved (300 occurrences).") 'warning includes total count'
    $rawText = [IO.File]::ReadAllText((Join-Path $with.Root 'evidence/copilot-events.jsonl'))
    Assert-Equal 300 ([regex]::Matches($rawText, '"type":"future.event"').Count) 'all raw unknown events preserved'
    $inside = New-CopilotInsideEnvironment -Inputs $inputs -Environment @{}
    Assert-Equal '/run' $inside.GIT_CEILING_DIRECTORIES 'bwrap Git ceiling'
    Assert-Equal '/run/home/.cache/copilot' $inside.COPILOT_CACHE_HOME 'bwrap complete cache override'
    Assert-Equal '/run/home/.cache' $inside.XDG_CACHE_HOME 'bwrap XDG root'

    # Exercise the same real child Git process with a genuine staged repository.
    & git init --quiet (Join-Path $without.Root 'repo')
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize staged fixture Git repository.' }
    $singleInputs = [pscustomobject]@{ Run = Resolve-RunContract -RunPath $without.Path; Profile = $inputs.Profile }
    $singleBaselineHash = Get-TestTreeHash -Root $singleInputs.Run.HomeDirectoryPath
    foreach ($scenario in @('completed', 'failure', 'timeout')) {
        $singleInputs.Run.PromptBytes = [Text.Encoding]::UTF8.GetBytes($scenario)
        $singleInputs.Profile.TimeoutSeconds = if ($scenario -eq 'timeout') { 2 } else { 15 }
        $singleResult = Invoke-CopilotWithPreparedHome -Inputs $singleInputs -Action { Invoke-CopilotExecute -Inputs $singleInputs }
        $expectedStatus = if ($scenario -eq 'failure') { 'failed' } elseif ($scenario -eq 'timeout') { 'timed_out' } else { 'completed' }
        Assert-Equal $expectedStatus $singleResult.status "$scenario terminal status"
        Assert-Equal $singleBaselineHash (Get-TestTreeHash -Root $singleInputs.Run.HomeDirectoryPath) "$scenario restores prepared baseline"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $without.Root 'home/.cache'))) "$scenario removes generated cache"
        Assert-Equal 'keep repo output' ([IO.File]::ReadAllText((Join-Path $without.Root 'repo/task-output.txt'))) "$scenario preserves repo output"
        Assert-True (Test-Path -LiteralPath (Join-Path $without.Root 'evidence/copilot-events.jsonl')) "$scenario preserves capture"
    }
    $singleRecords = @(Get-Content -LiteralPath (Join-Path $without.Root 'repo/fake-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($record in $singleRecords) {
        Assert-Equal 0 $record.git_exit 'Git still discovers staged repo/.git'
        Assert-Equal ((Join-Path $without.Root 'repo').Replace('\', '/')) ($record.git_root.Replace('\', '/')) 'Git returns staged root'
        Assert-True ($record.cache -ne $records[0].cache) 'paired arms never share cache'
    }

    $transcript = Get-PortableTranscript -Raw $result -RunData $inputs.Run
    foreach ($text in @((Get-InteractionTurnText -Turn $inputs.Run.Interaction.turns[0] -RunData $inputs.Run), 'Confirm before generation. Δ', 'Yes, generate the key.', "Generated successfully.`nExact terminal text.", "Session: fixture-session`nSame session: true")) {
        Assert-True ($transcript.Contains($text)) 'portable transcript includes exact original messages and session continuity'
    }
    Assert-Equal "Generated successfully.`nExact terminal text." $result.final_response.text 'final response remains terminal assistant text only'
    Assert-Equal 'evidence/copilot-events.jsonl' $result.telemetry.transcript.value.artifact 'raw JSONL stays a separate artifact'
    Assert-True (@($result.artifacts | Where-Object path -eq 'evidence/copilot-events.jsonl').Count -eq 1) 'raw JSONL artifact is retained for output_files'
    foreach ($corruption in @('hash', 'later_hash', 'final', 'final_case', 'sequence', 'role', 'session', 'same_session', 'missing', 'duplicate', 'native', 'final_sequence')) {
        $bad = $result | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        switch ($corruption) {
            hash { $bad.evidence.interaction.turns[0].content_sha256 = '0' * 64 }
            later_hash { $bad.evidence.interaction.turns[2].content_sha256 = '0' * 64 }
            final { $bad.final_response.text = 'different terminal response' }
            final_case { $bad.final_response.text = $bad.final_response.text.ToUpperInvariant() }
            sequence { $bad.evidence.interaction.turns[0].sequence = 9 }
            role { $bad.evidence.interaction.turns[1].role = 'user' }
            session { $bad.evidence.interaction.turns[1].session_id = 'other-session' }
            same_session { $bad.evidence.interaction.same_session = 'false' }
            missing { $bad.evidence.interaction.turns = @($bad.evidence.interaction.turns | Select-Object -Skip 2) }
            duplicate { $bad.evidence.interaction.turns += $bad.evidence.interaction.turns[0] }
            native { $bad.evidence.interaction.native_turns[0].turn = 2 }
            final_sequence { $bad.evidence.interaction.final_response_sequence = 2 }
        }
        Assert-Rejected { Get-PortableTranscript -Raw $bad -RunData $inputs.Run } "transcript fails closed on $corruption corruption"
    }
    foreach ($runnerName in @('opencode', 'codex')) {
        $other = $result | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $other.runner.name = $runnerName
        $other.telemetry.transcript.value.artifact = "evidence/$runnerName-events.jsonl"
        Assert-Equal "artifact: evidence/$runnerName-events.jsonl" (Get-PortableTranscript -Raw $other -RunData $inputs.Run) "$runnerName transcript unchanged even with scripted evidence"
    }
    Assert-Equal 'artifact: evidence/copilot-events.jsonl' (Get-PortableTranscript -Raw $singleResult -RunData $singleInputs.Run) 'single-turn Copilot transcript unchanged'

    # Exercise the real frozen-evidence bridge and the existing Skill Creator projection.
    $manifest = @{ schema = 'codebeltnet/agentic/eval-package/2'; configurations = @('with_skill', 'without_skill'); execution_freeze = 'execution-freeze.json'; evals = @(@{
        eval_id = 1; eval_name = 'conformance'; directory = 'conformance'; metadata = 'conformance/eval-metadata.json'
        runs = @{
            with_skill = @{ mode = 'with_skill'; run_manifest = 'conformance/with_skill/run.json'; execution_result = 'conformance/results/with.execution-result.json'; result = 'conformance/results/with.result.json' }
            without_skill = @{ mode = 'without_skill'; run_manifest = 'conformance/without_skill/run.json'; execution_result = 'conformance/results/without.execution-result.json'; result = 'conformance/results/without.result.json' }
        }
    }) }
    Write-TestJson -Path (Join-Path $iteration 'manifest.json') -Value $manifest
    Write-TestJson -Path (Join-Path $iteration 'conformance/eval-metadata.json') -Value @{ eval_id = 1; eval_name = 'conformance'; prompt = 'fixture task'; assertions = @('fixture assertion') }
    foreach ($arm in $manifest.evals[0].runs.Values) {
        Write-TestJson -Path (Join-Path $iteration $arm.result) -Value @{ execution_status = 'unrun'; grading = @(@{ text = 'fixture assertion'; passed = $null; evidence = '' }) }
    }
    $manifest = Read-RunnerJson -Path (Join-Path $iteration 'manifest.json')
    $manifestRecords = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest)
    $state = @{ schema = 'codebeltnet/agentic/eval-orchestration-state/1'; completed = @{}; execution_freeze = $null }
    foreach ($record in $manifestRecords) {
        $raw = if ($record.Configuration -eq 'with_skill') { $result } else { $singleResult }
        Write-TestJson -Path $record.ExecutionResultPath -Value $raw
        $key = Get-FreezeArmKey -Record $record
        $state.completed[$key] = @{ worker_id = $key; eval_id = 1; configuration = $record.Configuration; status = $raw.status; evidence_validation = @{ status = 'passed'; reasons = @() } }
    }
    $statePath = Join-Path $iteration 'orchestration-state.json'
    Write-TestJson -Path $statePath -Value $state
    $freeze = New-ExecutionFreezeDocument -IterationDirectory $iteration -Manifest $manifest -Records $manifestRecords -Profile $inputs.Profile
    $freezePath = Write-ExecutionFreezeDocument -IterationDirectory $iteration -Freeze $freeze
    $state.execution_freeze = @{ schema = (Get-RunnerSchemaNames).ExecutionFreeze; path = 'execution-freeze.json'; sha256 = Get-Sha256HexFromFile -Path $freezePath }
    Write-TestJson -Path $statePath -Value $state
    foreach ($record in $manifestRecords) {
        & pwsh -NoProfile -NonInteractive -File (Join-Path $runnerRoot 'bridge-execution-result.ps1') -Run $record.RunManifestPath -ExecutionResult $record.ExecutionResultPath -Result $record.ResultPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Frozen fixture bridge failed.' }
    }
    $portable = Read-RunnerJson -Path (@($manifestRecords | Where-Object Configuration -eq 'with_skill')[0].ResultPath)
    Assert-Equal $transcript $portable.transcript 'canonical portable transcript contains the whole interaction'
    Assert-Equal $result.final_response.text $portable.output 'canonical portable output is terminal response only'
    Assert-True (@($portable.output_files) -contains 'with_skill/evidence/copilot-events.jsonl') 'canonical output_files retains raw forensic JSONL'
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $projection = New-UpstreamWorkspace -IterationPath $iteration -Manifest $manifest -ManifestRecords $manifestRecords -WorkspacePath (Join-Path $iteration '.skill-creator-report')
    $transcriptFiles = @(Get-ChildItem -LiteralPath $iteration -Recurse -Filter transcript.md | Where-Object FullName -Match 'with_skill')
    Assert-Equal 1 $transcriptFiles.Count 'Skill Creator receives one canonical with-skill transcript.md'
    Assert-Equal (($transcript -replace "`r`n", "`n" -replace "`r", "`n") + [Environment]::NewLine) ([IO.File]::ReadAllText($transcriptFiles[0].FullName)) 'Skill Creator transcript.md preserves the complete conversation using its existing newline convention'
    foreach ($scenario in @('failure', 'timeout')) {
        $failureInteraction = @{ schema = (Get-RunnerSchemaNames).Interaction; mode = 'scripted'; turns = @(@{ role = 'user'; source = 'prompt.md' }, @{ role = 'user'; content = $scenario }) }
        $failureRun = New-TestRun -IterationDirectory (Join-Path $testRoot "scripted-$scenario") -Configuration without_skill -Interaction $failureInteraction
        [void][IO.Directory]::CreateDirectory((Join-Path $failureRun.Root 'home/baseline'))
        [IO.File]::WriteAllBytes((Join-Path $failureRun.Root 'home/baseline/nested.bin'), [byte[]]@(0, 255))
        $failureInputs = [pscustomobject]@{ Run = Resolve-RunContract -RunPath $failureRun.Path; Profile = Resolve-ExecutionProfile -ProfilePath $profilePath }
        $failureInputs.Profile.TimeoutSeconds = if ($scenario -eq 'timeout') { 2 } else { 15 }
        $failureBaselineHash = Get-TestTreeHash -Root $failureInputs.Run.HomeDirectoryPath
        $failureResult = Invoke-CopilotWithPreparedHome -Inputs $failureInputs -Action { Invoke-CopilotExecute -Inputs $failureInputs }
        Assert-Equal $(if ($scenario -eq 'timeout') { 'timed_out' } else { 'failed' }) $failureResult.status "scripted $scenario is terminal"
        Assert-Equal 2 @($failureResult.evidence.interaction.native_turns).Count "scripted $scenario occurs only after shared-state continuation"
        Assert-Equal $failureBaselineHash (Get-TestTreeHash -Root $failureInputs.Run.HomeDirectoryPath) "scripted $scenario restores exact baseline"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $failureRun.Root 'home/.cache'))) "scripted $scenario leaves no runtime cache"
        Assert-True (Test-Path -LiteralPath (Join-Path $failureRun.Root 'evidence/copilot-turn-2-events.jsonl')) "scripted $scenario keeps terminal evidence"
    }
    Invoke-CopilotWithPreparedHome -Inputs $inputs -Action {
        $probeEnvironment = New-CopilotEnvironment -Inputs $inputs -WithoutAuthentication
        Assert-Equal (Join-Path $inputs.Run.HomeDirectoryPath '.cache/copilot') $probeEnvironment.COPILOT_CACHE_HOME 'help/version bootstrap uses the same complete cache root'
    }
    Assert-Equal $baselineHash (Get-TestTreeHash -Root $inputs.Run.HomeDirectoryPath) 'model-free preflight environment construction restores prepared home too'
    Assert-Equal $parentCeiling ([Environment]::GetEnvironmentVariable('GIT_CEILING_DIRECTORIES')) 'parent Git environment unchanged'
    Assert-Rejected {
        Invoke-CopilotWithPreparedHome -Inputs $inputs -Action { $script:copilotHomeCleanupSafe = $false }
    } 'unproven process termination fails closed before home deletion'
    Assert-Equal $baselineHash (Get-TestTreeHash -Root $inputs.Run.HomeDirectoryPath) 'unsafe terminal handling leaves baseline untouched'
    Write-Output 'Copilot boundary regressions: PASS (real child Git, isolated cache, terminal restoration, scripted transcript, bounded warnings; no models)'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not (Test-PathInside -BasePath ([IO.Path]::GetTempPath()) -CandidatePath $resolvedTestRoot)) { throw 'Unsafe test cleanup root.' }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
