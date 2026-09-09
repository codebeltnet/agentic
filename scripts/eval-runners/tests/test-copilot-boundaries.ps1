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
. (Join-Path $runnerRoot 'github-copilot/isolation.ps1')

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
            $definition.Left.Extent.Text -in @('$descriptor', '$copilotExcludedTools', '$copilotCandidateInstructionBoundary')) { Invoke-Expression $definition.Extent.Text }
    }
}
$copilotAuthVariables = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
function Resolve-CopilotAuthentication { return [pscustomobject]@{ Source = 'fixture'; TokenVariable = $null; TokenValue = $null; GitHubCliTokenResolved = $false; GitHubCliConfigDirectory = $null; NonInteractiveReady = $true } }
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
$probe = [ordered]@{ metadata = Test-Path ../../eval-metadata.json; paired = (Test-Path ../../with_skill) -or (Test-Path ../../without_skill); candidate = Test-Path ../skill; staged_agents = Get-Content AGENTS.md -Raw; staged_copilot = Get-Content .github/copilot-instructions.md -Raw; ambient = @() }
$cursor = Split-Path -Parent (Get-Location).Path
while ($cursor) {
    foreach ($name in @('AGENTS.md', '.github/copilot-instructions.md')) { if (Test-Path -LiteralPath (Join-Path $cursor $name)) { $probe.ambient += [IO.File]::ReadAllText((Join-Path $cursor $name)) } }
    $cursor = Split-Path -Parent $cursor
}
[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'projection-probe.json'), ($probe | ConvertTo-Json))
if ($inputText -eq 'violation') { '{"type":"tool.execution_start","data":{"toolName":"view","arguments":{"path":"../../eval-metadata.json"}}}' }
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
        [void][IO.Directory]::CreateDirectory((Join-Path $run.Root 'repo/.github'))
        [IO.File]::WriteAllText((Join-Path $run.Root 'repo/AGENTS.md'), 'STAGED_INSTRUCTIONS_CANARY')
        [IO.File]::WriteAllText((Join-Path $run.Root 'repo/.github/copilot-instructions.md'), 'STAGED_COPILOT_CANARY')
        [void][IO.Directory]::CreateDirectory((Join-Path $run.Root 'home/baseline/empty'))
        [IO.File]::WriteAllBytes((Join-Path $run.Root 'home/baseline/nested.bin'), [byte[]]@(0, 255, 10, 13, 42))
        [IO.File]::WriteAllBytes((Join-Path $run.Root 'home/baseline/empty.bin'), [byte[]]@())
        [void][IO.Directory]::CreateDirectory((Join-Path $run.Root 'evidence'))
        [IO.File]::WriteAllText((Join-Path $run.Root 'evidence/prepared.txt'), 'keep evidence')
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'AGENTS.md'), 'FORBIDDEN_SOURCE_INSTRUCTIONS_CANARY')
    [void][IO.Directory]::CreateDirectory((Join-Path $testRoot '.github'))
    [IO.File]::WriteAllText((Join-Path $testRoot '.github/copilot-instructions.md'), 'FORBIDDEN_COPILOT_CANARY')
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $with.Root) 'eval-metadata.json'), 'FORBIDDEN_GRADING_CANARY')
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
        Assert-Equal $result.evidence.execution_paths.physical_run_root $record.ceiling 'child ceiling is the physical run root'
        Assert-True (-not (Test-PathInside -BasePath $testRoot -CandidatePath $record.cwd)) 'physical cwd excludes source and package ancestry'
        Assert-True ($record.git_exit -ne 0) 'child git cannot discover outer/.git from non-Git staged repo'
        Assert-Equal $result.evidence.execution_paths.physical_working_directory $record.cwd 'child uses projected working directory'
        $argsList = [string[]]$record.arguments
        Assert-Equal $record.cwd $argsList[[Array]::IndexOf($argsList, '-C') + 1] '-C agrees with process cwd'
        Assert-Equal 'fixture-model' $argsList[[Array]::IndexOf($argsList, '--model') + 1] 'model lock retained on every turn'
        Assert-Equal (Join-Path $result.evidence.execution_paths.physical_home_directory '.cache/copilot') $record.cache 'complete Copilot cache override, no duplicate suffix'
        Assert-Equal (Join-Path $result.evidence.execution_paths.physical_home_directory '.cache') $record.xdg 'XDG cache root'
        Assert-True (-not $record.old_cache_exists -and -not $record.double_suffix_exists) 'no old or double-suffixed cache is created during execution'
        if ($IsWindows) {
            Assert-Equal $record.xdg $record.localappdata 'Windows cache fallback converges'
            Assert-Equal (Join-Path $result.evidence.execution_paths.physical_home_directory '.config') $record.appdata 'Windows config root isolated'
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
    foreach ($scenario in @('completed', 'failure', 'timeout', 'violation')) {
        $singleInputs.Run.PromptBytes = [Text.Encoding]::UTF8.GetBytes($scenario)
        $singleInputs.Profile.TimeoutSeconds = if ($scenario -eq 'timeout') { 2 } else { 15 }
        $singleResult = Invoke-CopilotWithPreparedHome -Inputs $singleInputs -Action { Invoke-CopilotExecute -Inputs $singleInputs }
        $expectedStatus = if ($scenario -eq 'violation') { 'incompatible' } elseif ($scenario -eq 'failure') { 'failed' } elseif ($scenario -eq 'timeout') { 'timed_out' } else { 'completed' }
        Assert-Equal $expectedStatus $singleResult.status "$scenario terminal status"
        [void](Assert-ExecutionResult -Result $singleResult)
        Assert-Equal $singleBaselineHash (Get-TestTreeHash -Root $singleInputs.Run.HomeDirectoryPath) "$scenario restores prepared baseline"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $without.Root 'home/.cache'))) "$scenario removes generated cache"
        Assert-Equal 'keep repo output' ([IO.File]::ReadAllText((Join-Path $without.Root 'repo/task-output.txt'))) "$scenario preserves repo output"
        Assert-True (Test-Path -LiteralPath (Join-Path $without.Root 'evidence/copilot-events.jsonl')) "$scenario preserves capture"
    }
    $singleRecords = @(Get-Content -LiteralPath (Join-Path $without.Root 'repo/fake-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($record in $singleRecords) {
        Assert-Equal 0 $record.git_exit 'Git still discovers staged repo/.git'
        Assert-Equal ($record.cwd.Replace('\', '/')) ($record.git_root.Replace('\', '/')) 'Git returns projected staged root'
        Assert-True ($record.cache -ne $records[0].cache) 'paired arms never share cache'
    }
    Assert-True $singleResult.evidence.delegation.grading_material_visible 'contradiction prevents false invisibility claim'
    $forged = $singleResult | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $forged.status = 'completed'
    $forged.evidence.delegation.paired_arm_visible = $false
    $forged.evidence.delegation.grading_material_visible = $false
    Assert-Rejected { Assert-CopilotCapturedBoundary -Raw $forged -RunData $singleInputs.Run } 'bridge rejects transcript contradiction despite false invisibility flags'
    $proof = [pscustomobject]@{ Root = 'C:/temp/projection'; PackageRoot = 'C:/source/.bot/package'; SourceRepositoryRoot = 'C:/source' }
    foreach ($path in @('../../eval-metadata.json', '../../with_skill/repo', '../../without_skill/repo', '../../results/arm.json', '../../grading.json', '../../execution-freeze.json', '../../orchestration-state.json', '../../report.html', 'C:\source\AGENTS.md')) {
        Assert-True (@(Find-CopilotBoundaryContradictions -Data @{ arguments = @{ path = $path } } -Projection $proof).Count -gt 0) "captured forbidden access rejected: $path"
    }
    Assert-Equal 0 @(Find-CopilotBoundaryContradictions -Data @{ arguments = @{ path = 'src/Widget.cs' } } -Projection $proof).Count 'ordinary staged source is allowed'

    # --- P0 native-skill isolation regressions (model-free) ---
    Assert-True (@(New-CopilotCliArguments -Inputs $singleInputs) -contains '--excluded-tools=skill') 'Copilot removes the native skill tool from the model tool set for both arms'
    # Native-skill activation detector: a candidate `skill` tool call or an inherited skill-resolution result is a breach.
    Assert-True (@(Find-CopilotNativeSkillActivation -Data @{ toolName = 'skill'; arguments = @{ skill = 'demo-skill' } } -CandidateSkillName 'demo-skill' -EventType 'tool.execution_start').Count -gt 0) 'candidate skill tool call is flagged'
    Assert-True (@(Find-CopilotNativeSkillActivation -Data @{ skill = 'demo-skill'; found = $true; skillSource = 'inherited' } -CandidateSkillName 'demo-skill' -EventType 'tool.execution_completed').Count -gt 0) 'inherited candidate skill resolution is flagged'
    Assert-Equal 0 @(Find-CopilotNativeSkillActivation -Data @{ toolName = 'view'; arguments = @{ path = '../skill/demo-skill/SKILL.md' } } -CandidateSkillName 'demo-skill' -EventType 'tool.execution_start').Count 'ordinary read of the staged candidate copy is not native activation'
    Assert-Equal 0 @(Find-CopilotNativeSkillActivation -Data @{ toolName = 'shell'; arguments = @{ command = 'echo demo-skill' } } -CandidateSkillName 'demo-skill' -EventType 'command.execute').Count 'a mere text mention of the candidate is not native activation'

    # Candidate-instruction identity proof (only the frozen instruction bytes are hashed, not the wrapper).
    $demoInstruction = "# Operating instructions`n`n## Skill: demo-skill`n`nDo the demo work."
    $demoInstructionHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($demoInstruction)))).ToLowerInvariant()
    $withPrompt = "$demoInstruction`n`n# Working environment`n`nStay in the run.`n`n# task`n`nClassify."
    $noSkillPrompt = "# Operating instructions`n`nNo special instructions.`n`n# Working environment`n`nStay in the run.`n`n# task`n`nClassify."
    $withEvidence = Get-CopilotCandidateInstructionEvidence -Inputs ([pscustomobject]@{ Run = [pscustomobject]@{ Mode = 'with_skill'; PromptBytes = [Text.Encoding]::UTF8.GetBytes($withPrompt); CandidateInstructionHash = $demoInstructionHash } })
    Assert-True $withEvidence.verified 'with_skill injected instructions hash exactly to the frozen candidate hash'
    Assert-Equal $demoInstructionHash $withEvidence.injected 'injected candidate-instruction hash equals the frozen hash'
    Assert-Equal 0 @($withEvidence.violations).Count 'a matching candidate-instruction hash yields no violation'
    $wrapperChanged = Get-CopilotCandidateInstructionEvidence -Inputs ([pscustomobject]@{ Run = [pscustomobject]@{ Mode = 'with_skill'; PromptBytes = [Text.Encoding]::UTF8.GetBytes("$demoInstruction`n`n# Working environment`n`nDifferent wrapper text entirely.`n`n# task`n`nOther."); CandidateInstructionHash = $demoInstructionHash } })
    Assert-True $wrapperChanged.verified 'unrelated prompt-wrapper changes do not invalidate the candidate identity proof'
    $mismatch = Get-CopilotCandidateInstructionEvidence -Inputs ([pscustomobject]@{ Run = [pscustomobject]@{ Mode = 'with_skill'; PromptBytes = [Text.Encoding]::UTF8.GetBytes($withPrompt); CandidateInstructionHash = ('0' * 64) } })
    Assert-True ((-not $mismatch.verified) -and @($mismatch.violations).Count -gt 0) 'a mismatched candidate-instruction hash is a violation'
    $baselineClean = Get-CopilotCandidateInstructionEvidence -Inputs ([pscustomobject]@{ Run = [pscustomobject]@{ Mode = 'without_skill'; PromptBytes = [Text.Encoding]::UTF8.GetBytes($noSkillPrompt); CandidateInstructionHash = $null } })
    Assert-True ($baselineClean.verified -and @($baselineClean.violations).Count -eq 0) 'clean baseline has no candidate injection and no hash'
    Assert-True (@((Get-CopilotCandidateInstructionEvidence -Inputs ([pscustomobject]@{ Run = [pscustomobject]@{ Mode = 'without_skill'; PromptBytes = [Text.Encoding]::UTF8.GetBytes($withPrompt); CandidateInstructionHash = $null } })).violations).Count -gt 0) 'baseline that embeds a candidate instruction section is a violation'
    Assert-True (@((Get-CopilotCandidateInstructionEvidence -Inputs ([pscustomobject]@{ Run = [pscustomobject]@{ Mode = 'without_skill'; PromptBytes = [Text.Encoding]::UTF8.GetBytes($noSkillPrompt); CandidateInstructionHash = ('a' * 64) } })).violations).Count -gt 0) 'baseline that declares a candidate hash is a violation'

    # Native-skill-catalog probe: model-free, proves candidate absence/disablement or fails closed on an enabled candidate.
    $catalogFake = Join-Path $testRoot 'catalog-fake.ps1'
    [IO.File]::WriteAllText($catalogFake, 'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$a); if ($env:FAKE_CATALOG) { Write-Output $env:FAKE_CATALOG } else { Write-Output "[]" }')
    $catalogCommand = [pscustomobject]@{ FileName = (Get-Command pwsh).Source; Prefix = @('-NoProfile', '-NonInteractive', '-File', $catalogFake) }
    function New-CatalogEnv { param([string]$Json) $env = New-RunnerProbeEnvironment; $env['FAKE_CATALOG'] = $Json; return $env }
    $absentProbe = Invoke-CopilotNativeSkillCatalogProbe -CommandInfo $catalogCommand -Environment (New-CatalogEnv '[{"name":"customize-cloud-agent","source":"builtin","enabled":true}]') -WorkingDirectory $testRoot -CandidateSkillName 'demo-skill'
    Assert-True ($absentProbe.available -and $absentProbe.proven_absent -and -not $absentProbe.candidate_present) 'catalog probe proves an absent candidate is not natively resolvable'
    $enabledProbe = Invoke-CopilotNativeSkillCatalogProbe -CommandInfo $catalogCommand -Environment (New-CatalogEnv '[{"name":"demo-skill","source":"personal","enabled":true}]') -WorkingDirectory $testRoot -CandidateSkillName 'demo-skill'
    Assert-True ($enabledProbe.available -and $enabledProbe.candidate_present -and $enabledProbe.candidate_enabled -and -not $enabledProbe.proven_absent) 'catalog probe flags an enabled ambient candidate'
    $disabledProbe = Invoke-CopilotNativeSkillCatalogProbe -CommandInfo $catalogCommand -Environment (New-CatalogEnv '[{"name":"demo-skill","source":"personal","enabled":false}]') -WorkingDirectory $testRoot -CandidateSkillName 'demo-skill'
    Assert-True ($disabledProbe.candidate_present -and -not $disabledProbe.candidate_enabled -and $disabledProbe.proven_absent) 'a disabled ambient candidate is present but cannot activate'

    # Bridge independently rejects a captured candidate native-skill activation even when runner booleans look clean.
    $activationRun = New-TestRun -IterationDirectory (Join-Path $testRoot 'native-skill-activation') -Configuration without_skill
    New-Item -ItemType Directory -Path (Join-Path $activationRun.Root 'evidence') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $activationRun.Root 'evidence/copilot-events.jsonl'), '{"type":"tool.execution_start","data":{"toolName":"skill","arguments":{"skill":"candidate"}}}' + "`n")
    $activationInputs = [pscustomobject]@{ Run = Resolve-RunContract -RunPath $activationRun.Path; Profile = Resolve-ExecutionProfile -ProfilePath $profilePath }
    $activationRaw = @{ runner = @{ name = 'github-copilot' }; status = 'completed'; evidence = @{ execution_paths = @{ projection_proven = $true; physical_run_root = (Join-Path $testRoot 'phys-activation'); source_repository_root = '' } }; artifacts = @(@{ scope = 'run'; path = 'evidence/copilot-events.jsonl' }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Assert-Rejected { Assert-CopilotCapturedBoundary -Raw $activationRaw -RunData $activationInputs.Run } 'bridge rejects a captured candidate native-skill activation'
    $warnings = [Collections.Generic.List[string]]::new()
    $checkpoint = @{ type = 'session.usage_checkpoint'; data = @{ totalPremiumRequests = 0.33; totalNanoAiu = 10; promptCacheBreakState = @(@{ models = @{ model = @{ model_call_id = 'call-1'; prompt_tokens = 100; cache_read = 70; cache_write = 20; tool_tokens = 15 } } }) } }
    $last = $checkpoint | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $last.data.totalPremiumRequests = 0.66
    $last.data.totalNanoAiu = 20
    $usage = Read-CopilotEvents -Parsed @{ Events = @($checkpoint, $last, $last); Errors = @() } -Warnings $warnings
    Assert-Equal 100 $usage.UsageInput 'repeated call snapshots are not summed'
    Assert-Equal 70 $usage.UsageCacheRead 'cache read bucket retained without duplication'
    Assert-Equal 20 $usage.UsageCacheWrite 'cache write bucket retained without duplication'
    Assert-Equal 0.66 $usage.UsageCheckpoint.totalPremiumRequests 'final cumulative premium request counter is authoritative'
    Assert-Equal 20 $usage.UsageCheckpoint.totalNanoAiu 'final cumulative nano AI units retained without currency conversion'
    Assert-True ($null -eq $usage.UsageOutput) 'unexposed output tokens remain unavailable'
    Assert-Equal 15 $usage.CheckpointCalls[0].tool_tokens 'tool schema tokens retained in native evidence only'
    $secondCall = $last | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $secondCall.data.promptCacheBreakState[0].models.model.model_call_id = 'call-2'
    $secondCall.data.promptCacheBreakState[0].models.model.prompt_tokens = 120
    $usage = Read-CopilotEvents -Parsed @{ Events = @($checkpoint, $last, $secondCall, $secondCall); Errors = @() } -Warnings $warnings
    Assert-Equal 220 $usage.UsageInput 'distinct native calls count once each'
    $usage = Read-CopilotEvents -Parsed @{ Events = @($checkpoint, @{ type = 'assistant.usage'; data = @{ inputTokens = 7; outputTokens = 3 } }); Errors = @() } -Warnings $warnings
    Assert-Equal 7 $usage.UsageInput 'native assistant usage takes precedence over cache snapshots'
    Assert-Equal 3 $usage.UsageOutput 'actual exposed output count retained'
    $savedTemp = $env:TEMP; $savedTmp = $env:TMP; $savedTmpDir = $env:TMPDIR
    try {
        $env:TEMP = $testRoot; $env:TMP = $testRoot; $env:TMPDIR = $testRoot
        Assert-Rejected { Get-CopilotProjectionPlan -Inputs $singleInputs } 'temp inside source ancestry fails closed'
    } finally { $env:TEMP = $savedTemp; $env:TMP = $savedTmp; $env:TMPDIR = $savedTmpDir }
    $runtimeLink = Join-Path $singleInputs.Run.WorkingDirectoryPath 'forbidden-link'
    New-Item -ItemType $linkType -Path $runtimeLink -Target $testRoot | Out-Null
    try { Assert-Rejected { Get-CopilotProjectionPlan -Inputs $singleInputs } 'linked projection input fails closed' }
    finally { (Get-Item -LiteralPath $runtimeLink -Force).Delete() }
    foreach ($arm in @($with, $without)) {
        $probe = Get-Content (Join-Path $arm.Root 'repo/projection-probe.json') -Raw | ConvertFrom-Json
        Assert-True (-not $probe.metadata -and -not $probe.paired) 'parent metadata and sibling arms are unreachable through projected ancestry'
        Assert-Equal 0 @($probe.ambient).Count 'source AGENTS and Copilot instructions are excluded'
        Assert-Equal 'STAGED_INSTRUCTIONS_CANARY' $probe.staged_agents 'staged AGENTS preserved identically'
        Assert-Equal 'STAGED_COPILOT_CANARY' $probe.staged_copilot 'staged Copilot instructions preserved identically'
        Assert-Equal ($arm.Root -eq $with.Root) $probe.candidate 'candidate material is only projected for with_skill'
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
    $transcriptFiles = @(Get-ChildItem -LiteralPath $iteration -Recurse -Force -Filter transcript.md | Where-Object FullName -Match 'with_skill')
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
