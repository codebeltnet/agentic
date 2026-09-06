<#!
.SYNOPSIS
    Deterministic, model-free live-observability tests for every eval runner.

.DESCRIPTION
    Proves the shared observability contract without any model, network, or
    authenticated CLI. Synthetic child processes exercise the shared process
    primitive (heartbeats, activity tracking, tee/relay, timeout diagnostics,
    secret hygiene), and one real runner-owned fan-out run over the deterministic
    fixture proves concurrent-arm attribution, the STDOUT machine contract, and
    persisted progress evidence. No test may hang: every scenario is bounded.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'runner-progress.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT: $Message (expected '$Expected', got '$Actual')" }
}

function Get-Field {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

$pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-observability-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-SyntheticChildScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Body
    )

    $path = Join-Path $testRoot ($Name + '.ps1')
    [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-SyntheticChild {
    <#
      Drives one synthetic child through the shared process primitive exactly as
      the fan-out does: Start -> Wait-AnyRunnerChild (heartbeats/relay) -> Complete
      (terminal diagnostic). Returns the child, exit code, and the parsed progress
      log so a test can assert what an operator would have seen live.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [int]$TimeoutSeconds = 30,
        [double]$HeartbeatSeconds = 0.3,
        [object]$EvalId = 1,
        [string]$Configuration = 'with_skill'
    )

    $workDirectory = Join-Path $testRoot ('work-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $stdoutPath = Join-Path $workDirectory 'result.json'
    $stderrPath = Join-Path $workDirectory 'child.stderr'
    $logPath = Join-Path $workDirectory 'progress.jsonl'
    $operatorErrorWriter = [System.IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
    $originalErrorWriter = [Console]::Error
    try {
        [Console]::SetError($operatorErrorWriter)
        $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) -WorkingDirectory $workDirectory -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -Runner 'synthetic' -WorkerId $WorkerId -EvalId $EvalId -Configuration $Configuration -Phase 'model-cli' -ProgressLogPath $logPath -HeartbeatSeconds $HeartbeatSeconds
        $running = [System.Collections.Generic.List[object]]::new()
        $running.Add([pscustomobject]@{ worker_id = $WorkerId; child = $child; Process = $child.Process })
        $index = Wait-AnyRunnerChild -Running $running
        $exitCode = Complete-RunnerChildProcess -Child $child
    } finally {
        try { [Console]::Error.Flush() } catch { }
        [Console]::SetError($originalErrorWriter)
    }
    $events = @()
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $events = @(Get-Content -LiteralPath $logPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{
        Child = $child
        ExitCode = $exitCode
        WaitIndex = $index
        Events = $events
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        LogPath = $logPath
        OperatorStderr = [string]$operatorErrorWriter.ToString()
    }
}

function New-ObservabilityFanoutPackage {
    <#
      Builds a minimal runner-owned fixture package. The fixture is a protocol
      adapter only; it never calls a model or an AI CLI. Each arm is slowed by a
      per-run marker so heartbeats fire on the real operator-facing path.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [int]$EvalCount = 2,
        [int]$Concurrency = 4,
        [int]$DelayMs = 700
    )

    $tools = Join-Path $IterationDirectory 'tools\eval-runners'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    foreach ($toolItem in @(Get-ChildItem -LiteralPath $runnerRoot -Force | Where-Object { $_.Name -ne 'tests' })) {
        Copy-Item -LiteralPath $toolItem.FullName -Destination $tools -Recurse -Force
    }
    $fixtureRunnerDirectory = Join-Path $tools 'fixture'
    New-Item -ItemType Directory -Path $fixtureRunnerDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests\fixtures\runner-owned-fixture.ps1') -Destination (Join-Path $fixtureRunnerDirectory 'runner.ps1') -Force

    [System.IO.File]::WriteAllText((Join-Path $IterationDirectory 'execution-profile.json'), (([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = $Concurrency
    } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le $EvalCount; $evalId++) {
        $evalName = 'obs-eval-{0:d2}' -f $evalId
        $evalDirectory = Join-Path $IterationDirectory $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $evalDirectory 'eval-metadata.json'), (([ordered]@{ eval_id = $evalId; eval_name = $evalName; assertions = @('fixture') } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runDirectory = Join-Path $evalDirectory $configuration
            $repoDirectory = Join-Path $runDirectory 'repo'
            $homeDirectory = Join-Path $runDirectory 'home'
            $resultDirectory = Join-Path $evalDirectory 'results'
            New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory, $resultDirectory -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repoDirectory 'input.txt'), "$evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "observability prompt $evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            # Slow each arm past the heartbeat interval so the operator path emits
            # heartbeats without any model involvement.
            [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'execute-delay-ms'), [string]$DelayMs, [System.Text.UTF8Encoding]::new($false))
            $skillDirectory = $null
            $skillHash = $null
            if ($configuration -eq 'with_skill') {
                $skillDirectory = 'skill/candidate'
                New-Item -ItemType Directory -Path (Join-Path $runDirectory 'skill\candidate') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $runDirectory 'skill\candidate\SKILL.md'), '# fixture', [System.Text.UTF8Encoding]::new($false))
                $skillHash = ('b' * 64)
            }
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'run.json'), (([ordered]@{
                schema = (Get-RunnerSchemaNames).Run
                evalId = $evalId
                evalName = $evalName
                candidateSkillName = 'candidate'
                skillName = if ($configuration -eq 'with_skill') { 'candidate' } else { $null }
                iteration = 1
                mode = $configuration
                promptFile = 'prompt.md'
                workingDirectory = 'repo'
                homeDirectory = 'home'
                skillDirectory = $skillDirectory
                freshContextRequired = $true
                filesystemIsolationRequired = $true
                isolatedHomeRequired = $true
                fixtureHash = ('a' * 64)
                skillHash = $skillHash
            } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            $resultName = if ($configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
            $executionName = if ($configuration -eq 'with_skill') { 'with-skill.execution-result.json' } else { 'without-skill.execution-result.json' }
            [System.IO.File]::WriteAllText((Join-Path $resultDirectory $resultName), (([ordered]@{ eval_id = $evalId; configuration = $configuration; execution_status = 'unrun' } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            $runs[$configuration] = [ordered]@{
                mode = $configuration
                run_manifest = "$evalName/$configuration/run.json"
                execution_result = "$evalName/results/$executionName"
                result = "$evalName/results/$resultName"
            }
        }
        $manifestEvals.Add([ordered]@{ eval_id = $evalId; eval_name = $evalName; directory = $evalName; metadata = "$evalName/eval-metadata.json"; runs = $runs })
    }

    $toolIntegrity = Get-PackageTreeIntegrity -Root $tools
    [System.IO.File]::WriteAllText((Join-Path $IterationDirectory 'manifest.json'), (([ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_selection = [ordered]@{
            harness = 'Deterministic runner-owned fixture'
            runner = 'fixture'
            model = 'fixture-model'
            preset = 'Observability fixture'
        }
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $toolIntegrity.Sha256; file_count = $toolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        evals = @($manifestEvals.ToArray())
    } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    return $IterationDirectory
}

function Invoke-ObservabilityFanout {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$EvalCount = 2,
        [int]$Concurrency = 4,
        [int]$DelayMs = 700
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [void](New-ObservabilityFanoutPackage -IterationDirectory $Root -EvalCount $EvalCount -Concurrency $Concurrency -DelayMs $DelayMs)
    $fanout = Join-Path $Root 'tools/eval-runners/invoke-runner-owned-arms.ps1'
    $stderrPath = Join-Path $Root 'phase1.stderr'
    $previousHeartbeat = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS')
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS', '0.3')
    try {
        $output = & $pwshPath -NoProfile -NonInteractive -File $fanout -IterationDirectory $Root 2>$stderrPath
        $exitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS', $previousHeartbeat)
    }
    $stdout = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    return [pscustomobject]@{
        IterationDirectory = $Root
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    [System.IO.File]::WriteAllText($Path, ((ConvertTo-Json -InputObject $Value -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Get-RelayedProgressEventsFromText {
    param([AllowEmptyString()][string]$Text)

    $sentinel = Get-RunnerProgressSentinel
    return @($Text -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith($sentinel) } | ForEach-Object {
            $payload = $_.TrimStart().Substring($sentinel.Length).TrimStart()
            try { $payload | ConvertFrom-Json -Depth 50 } catch { $null }
        } | Where-Object { $null -ne $_ })
}

function New-CodexObservabilityFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateSet('success', 'timeout')][string]$Mode = 'success',
        [int]$TimeoutSeconds = 5
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $fakeBin = Join-Path $Root 'fake-bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    $fakeCodexPath = Join-Path $fakeBin 'codex.ps1'
    [System.IO.File]::WriteAllText($fakeCodexPath, @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$arguments = @($RemainingArguments | ForEach-Object { [string]$_ })
$heartbeatMs = 150
$heartbeatOverride = [Environment]::GetEnvironmentVariable('AGENTIC_CODEX_OBS_HEARTBEAT_MS')
if (-not [string]::IsNullOrWhiteSpace($heartbeatOverride)) {
    $parsedHeartbeat = 0
    if ([int]::TryParse($heartbeatOverride, [ref]$parsedHeartbeat) -and $parsedHeartbeat -gt 0) {
        $heartbeatMs = $parsedHeartbeat
    }
}
$homeRoot = [Environment]::GetEnvironmentVariable('HOME')
$isProjectedExecution = [string](Get-Location).Path -match 'agentic-codex-projection-'
$mode = if ($isProjectedExecution -and (
    (-not [string]::IsNullOrWhiteSpace($homeRoot) -and (Test-Path -LiteralPath (Join-Path $homeRoot 'codex-observability-timeout') -PathType Leaf)) -or
    (Test-Path -LiteralPath (Join-Path (Get-Location).Path 'codex-observability-timeout') -PathType Leaf)
)) { 'timeout' } else { 'success' }

function Get-DelayMilliseconds {
    param([double]$Multiplier)

    return [int][Math]::Max(50, [Math]::Ceiling($heartbeatMs * $Multiplier))
}

function Read-AppServerMessage {
    param([switch]$AllowEndOfStream)

    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
        if ($AllowEndOfStream) { return $null }
        throw 'observability fake app-server reached EOF before the expected request'
    }
    return ($line | ConvertFrom-Json -Depth 50)
}

function Write-AppServerMessage {
    param([Parameter(Mandatory = $true)][object]$Value)

    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 50 -Compress))
    [Console]::Out.Flush()
}

function Write-CodexSchemas {
    param([Parameter(Mandatory = $true)][string]$SchemaDirectory)

    New-Item -ItemType Directory -Path $SchemaDirectory -Force | Out-Null
    foreach ($existing in @(Get-ChildItem -LiteralPath $SchemaDirectory -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $existing.FullName -Recurse -Force
    }

    $schema = 'http://json-schema.org/draft-07/schema#'
    $definitions = [ordered]@{
        AbsolutePathBuf = [ordered]@{ type = 'string' }
        LegacyAppPathString = [ordered]@{ type = 'string' }
        SandboxMode = [ordered]@{ type = 'string'; enum = @('read-only', 'workspace-write', 'danger-full-access') }
        AskForApproval = [ordered]@{ oneOf = @([ordered]@{ type = 'string'; enum = @('untrusted', 'on-request', 'never') }) }
        ReasoningEffort = [ordered]@{ type = 'string'; minLength = 1 }
        ModelRerouteReason = [ordered]@{ type = 'string'; enum = @('highRiskCyberActivity') }
        TurnStatus = [ordered]@{ type = 'string'; enum = @('inProgress', 'completed', 'failed', 'interrupted') }
        UserInput = [ordered]@{ oneOf = @([ordered]@{ type = 'object'; required = @('text', 'type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('text') }; text = [ordered]@{ type = 'string' } } }) }
        SandboxPolicy = [ordered]@{ oneOf = @(
            [ordered]@{ type = 'object'; required = @('type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('dangerFullAccess') } } }
            [ordered]@{ type = 'object'; required = @('type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('readOnly') }; networkAccess = [ordered]@{ type = 'boolean' } } }
            [ordered]@{ type = 'object'; required = @('type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('workspaceWrite') }; writableRoots = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' } }; networkAccess = [ordered]@{ type = 'boolean' } } }
        ) }
        Thread = [ordered]@{ type = 'object'; required = @('id', 'cwd', 'ephemeral', 'sessionId', 'turns'); properties = [ordered]@{ id = [ordered]@{ type = 'string' }; cwd = [ordered]@{ allOf = @([ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' }) }; ephemeral = [ordered]@{ type = 'boolean' }; sessionId = [ordered]@{ type = 'string' }; turns = [ordered]@{ type = 'array' } } }
        Turn = [ordered]@{ type = 'object'; required = @('id', 'items', 'status'); properties = [ordered]@{ id = [ordered]@{ type = 'string' }; items = [ordered]@{ type = 'array' }; status = [ordered]@{ '$ref' = '#/definitions/TurnStatus' } } }
        SkillMetadata = [ordered]@{ type = 'object'; required = @('name', 'path', 'enabled'); properties = [ordered]@{ name = [ordered]@{ type = 'string' }; path = [ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' }; enabled = [ordered]@{ type = 'boolean' }; scope = [ordered]@{ type = 'string'; enum = @('user', 'repo', 'system', 'admin') }; description = [ordered]@{ type = 'string' } } }
        SkillsListEntry = [ordered]@{ type = 'object'; required = @('cwd', 'errors', 'skills'); properties = [ordered]@{ cwd = [ordered]@{ type = 'string' }; errors = [ordered]@{ type = 'array' }; skills = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/SkillMetadata' } } } }
        Config = [ordered]@{ type = 'object'; additionalProperties = $true }
    }
    $definitions.ConfigReadParams = [ordered]@{
        '$schema' = $schema
        title = 'ConfigReadParams'
        type = 'object'
        properties = [ordered]@{
            includeLayers = [ordered]@{ type = 'boolean' }
            cwd = [ordered]@{ type = @('string', 'null') }
        }
    }
    $definitions.ConfigReadResponse = [ordered]@{
        '$schema' = $schema
        title = 'ConfigReadResponse'
        type = 'object'
        required = @('config')
        properties = [ordered]@{ config = [ordered]@{ '$ref' = '#/definitions/Config' } }
    }
    $definitions.SkillsListParams = [ordered]@{
        '$schema' = $schema
        title = 'SkillsListParams'
        type = 'object'
        properties = [ordered]@{
            cwds = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string' } }
            forceReload = [ordered]@{ type = 'boolean' }
        }
    }
    $definitions.SkillsListResponse = [ordered]@{
        '$schema' = $schema
        title = 'SkillsListResponse'
        type = 'object'
        required = @('data')
        properties = [ordered]@{ data = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/SkillsListEntry' } } }
    }
    $definitions.ThreadStartParams = [ordered]@{
        '$schema' = $schema
        title = 'ThreadStartParams'
        type = 'object'
        properties = [ordered]@{
            model = [ordered]@{ type = @('string', 'null') }
            cwd = [ordered]@{ type = @('string', 'null') }
            approvalPolicy = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/AskForApproval' }, [ordered]@{ type = 'null' }) }
            sandbox = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/SandboxMode' }, [ordered]@{ type = 'null' }) }
            ephemeral = [ordered]@{ type = @('boolean', 'null') }
        }
    }
    $definitions.ThreadStartResponse = [ordered]@{
        '$schema' = $schema
        title = 'ThreadStartResponse'
        type = 'object'
        required = @('approvalPolicy', 'approvalsReviewer', 'cwd', 'model', 'modelProvider', 'sandbox', 'thread')
        properties = [ordered]@{
            approvalPolicy = [ordered]@{ '$ref' = '#/definitions/AskForApproval' }
            cwd = [ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' }
            instructionSources = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/LegacyAppPathString' } }
            model = [ordered]@{ type = 'string' }
            sandbox = [ordered]@{ allOf = @([ordered]@{ '$ref' = '#/definitions/SandboxPolicy' }) }
            thread = [ordered]@{ '$ref' = '#/definitions/Thread' }
        }
    }
    $definitions.TurnStartParams = [ordered]@{
        '$schema' = $schema
        title = 'TurnStartParams'
        type = 'object'
        required = @('input', 'threadId')
        properties = [ordered]@{
            threadId = [ordered]@{ type = 'string' }
            input = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/UserInput' } }
            cwd = [ordered]@{ type = @('string', 'null') }
            model = [ordered]@{ type = @('string', 'null') }
            effort = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/ReasoningEffort' }, [ordered]@{ type = 'null' }) }
            approvalPolicy = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/AskForApproval' }, [ordered]@{ type = 'null' }) }
            sandboxPolicy = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/SandboxPolicy' }, [ordered]@{ type = 'null' }) }
        }
    }
    $definitions.TurnStartResponse = [ordered]@{
        '$schema' = $schema
        title = 'TurnStartResponse'
        type = 'object'
        required = @('turn')
        properties = [ordered]@{ turn = [ordered]@{ '$ref' = '#/definitions/Turn' } }
    }
    $definitions.ThreadReadParams = [ordered]@{
        '$schema' = $schema
        title = 'ThreadReadParams'
        type = 'object'
        required = @('threadId')
        properties = [ordered]@{ threadId = [ordered]@{ type = 'string' }; includeTurns = [ordered]@{ type = 'boolean' } }
    }
    $definitions.ThreadReadResponse = [ordered]@{
        '$schema' = $schema
        title = 'ThreadReadResponse'
        type = 'object'
        required = @('thread')
        properties = [ordered]@{ thread = [ordered]@{ '$ref' = '#/definitions/Thread' } }
    }
    $definitions.ModelReroutedNotification = [ordered]@{
        '$schema' = $schema
        title = 'ModelReroutedNotification'
        type = 'object'
        required = @('fromModel', 'reason', 'threadId', 'toModel', 'turnId')
        properties = [ordered]@{
            fromModel = [ordered]@{ type = 'string' }
            reason = [ordered]@{ '$ref' = '#/definitions/ModelRerouteReason' }
            threadId = [ordered]@{ type = 'string' }
            toModel = [ordered]@{ type = 'string' }
            turnId = [ordered]@{ type = 'string' }
        }
    }

    $schemaFiles = [ordered]@{
        'codex_app_server_protocol.v2.schemas.json' = [ordered]@{ '$schema' = $schema; title = 'codex_app_server_protocol.v2.schemas'; type = 'object'; definitions = $definitions }
    }
    foreach ($schemaName in @('ConfigReadParams', 'ConfigReadResponse', 'SkillsListParams', 'SkillsListResponse', 'ThreadStartParams', 'ThreadStartResponse', 'TurnStartParams', 'TurnStartResponse', 'ThreadReadParams', 'ThreadReadResponse', 'ModelReroutedNotification')) {
        $source = $definitions[$schemaName]
        $individual = [ordered]@{ '$schema' = $schema }
        foreach ($propertyName in @('title', 'type', 'properties', 'required')) {
            if ($source.Contains($propertyName)) { $individual[$propertyName] = $source[$propertyName] }
        }
        $individual.definitions = $definitions
        $schemaFiles[('v2\{0}.json' -f $schemaName)] = $individual
    }
    foreach ($schemaName in $schemaFiles.Keys) {
        $schemaPath = Join-Path $SchemaDirectory $schemaName
        New-Item -ItemType Directory -Path (Split-Path -Parent $schemaPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($schemaPath, ([string]($schemaFiles[$schemaName] | ConvertTo-Json -Depth 100)), [System.Text.UTF8Encoding]::new($false))
    }
}

if ($arguments -contains '--version') {
    Write-Output 'recorded-codex 9.9'
    exit 0
}
if ($arguments -contains '--help' -and -not ($arguments -contains 'app-server')) {
    Write-Output '--ask-for-approval never --strict-config --ephemeral --ignore-user-config --ignore-rules --json --output-last-message --sandbox danger-full-access --cd --model --config'
    exit 0
}
if ($arguments -contains 'features' -and $arguments -contains 'list') {
    Write-Output 'multi_agent stable true'
    exit 0
}
if ($arguments -contains 'app-server' -and $arguments -contains '--help') {
    Write-Output 'generate-json-schema'
    exit 0
}
if ($arguments -contains 'app-server' -and $arguments -contains 'generate-json-schema') {
    $outArgument = @($arguments | Where-Object { $_ -like '--out=*' } | Select-Object -First 1)
    if ($outArgument.Count -eq 0) { exit 2 }
    $schemaDirectory = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path ([string]$outArgument[0].Substring(6))))
    Write-CodexSchemas -SchemaDirectory $schemaDirectory
    exit 0
}
if ($arguments -contains 'app-server' -and $arguments -contains '--stdio') {
    $initialize = Read-AppServerMessage
    if ($mode -eq 'timeout') {
        Start-Sleep -Milliseconds (Get-DelayMilliseconds 20)
        exit 0
    }

    $repoAgentsPath = Join-Path (Get-Location).Path 'AGENTS.md'
    $threadId = 'obs-thread'
    $turnId = 'obs-turn'
    $threadObject = [ordered]@{
        id = $threadId
        sessionId = 'obs-session'
        ephemeral = $true
        cwd = (Get-Location).Path
        cliVersion = '9.9'
        createdAt = 1
        updatedAt = 1
        modelProvider = 'recorded-provider'
        preview = $false
        projectId = $null
        source = 'startup'
        status = [ordered]@{ type = 'idle' }
        turns = @()
    }

    Start-Sleep -Milliseconds (Get-DelayMilliseconds 3.2)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        id = $initialize.id
        result = [ordered]@{ serverInfo = [ordered]@{ name = 'observability-codex'; version = '9.9' } }
    })

    $null = Read-AppServerMessage
    $configRead = Read-AppServerMessage
    $candidateConfig = @($arguments | Where-Object { [string]$_ -like 'skills.config=*' } | Select-Object -First 1)
    $candidateName = if ($candidateConfig.Count -eq 1 -and [string]$candidateConfig[0] -match 'name="(?<name>[^"]+)"') { $Matches['name'] } else { 'candidate' }
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        id = $configRead.id
        result = [ordered]@{ config = [ordered]@{ skills = [ordered]@{ include_instructions = $false; config = @([ordered]@{ name = $candidateName; enabled = $false }) } } }
    })
    $skillsList = Read-AppServerMessage
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        id = $skillsList.id
        result = [ordered]@{ data = @([ordered]@{ cwd = (Get-Location).Path; errors = @(); skills = @([ordered]@{ name = $candidateName; path = "C:\Users\some-user\.agents\skills\$candidateName\SKILL.md"; enabled = $false; scope = 'user'; description = 'observability candidate' }) }) }
    })
    $threadStart = Read-AppServerMessage -AllowEndOfStream
    if ($null -eq $threadStart) { exit 0 }
    Start-Sleep -Milliseconds (Get-DelayMilliseconds 2.8)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        id = $threadStart.id
        result = [ordered]@{
            approvalPolicy = 'never'
            approvalsReviewer = 'user'
            cwd = (Get-Location).Path
            model = [string]$threadStart.params.model
            modelProvider = 'recorded-provider'
            sandbox = [ordered]@{ type = 'readOnly' }
            instructionSources = @($repoAgentsPath)
            thread = $threadObject
        }
    })

    $turnStart = Read-AppServerMessage
    Start-Sleep -Milliseconds (Get-DelayMilliseconds 2.4)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        id = $turnStart.id
        result = [ordered]@{ turn = [ordered]@{ id = $turnId; status = 'inProgress'; items = @() } }
    })

    Start-Sleep -Milliseconds (Get-DelayMilliseconds 0.5)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        method = 'thread/started'
        params = [ordered]@{ thread = [ordered]@{ id = $threadId } }
    })
    Start-Sleep -Milliseconds (Get-DelayMilliseconds 0.5)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        method = 'item/completed'
        params = [ordered]@{
            threadId = $threadId
            turnId = $turnId
            completedAtMs = 1
            item = [ordered]@{
                type = 'commandExecution'
                id = 'cmd-1'
                command = 'echo observability'
                commandActions = @()
                cwd = (Get-Location).Path
                status = 'completed'
                exitCode = 0
                aggregatedOutput = 'OBSERVABILITY_PROTOCOL_OUTPUT_CANARY'
            }
        }
    })
    Start-Sleep -Milliseconds (Get-DelayMilliseconds 0.5)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        method = 'item/completed'
        params = [ordered]@{
            threadId = $threadId
            turnId = $turnId
            completedAtMs = 2
            item = [ordered]@{
                type = 'agentMessage'
                id = 'message-1'
                text = 'OBSERVABILITY_MODEL_CONTENT_CANARY'
            }
        }
    })
    Start-Sleep -Milliseconds (Get-DelayMilliseconds 0.5)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        method = 'thread/tokenUsage/updated'
        params = [ordered]@{
            threadId = $threadId
            turnId = $turnId
            tokenUsage = [ordered]@{
                total = [ordered]@{ inputTokens = 2; cachedInputTokens = 0; outputTokens = 3; reasoningOutputTokens = 1; totalTokens = 6 }
                last = [ordered]@{ inputTokens = 2; cachedInputTokens = 0; outputTokens = 3; reasoningOutputTokens = 1; totalTokens = 6 }
            }
        }
    })
    Start-Sleep -Milliseconds (Get-DelayMilliseconds 0.5)
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        method = 'turn/completed'
        params = [ordered]@{
            threadId = $threadId
            turn = [ordered]@{ id = $turnId; status = 'completed'; items = @() }
        }
    })

    $threadRead = Read-AppServerMessage
    Write-AppServerMessage ([ordered]@{
        jsonrpc = '2.0'
        id = $threadRead.id
        result = [ordered]@{ thread = $threadObject }
    })
    exit 0
}

exit 0
'@, [System.Text.UTF8Encoding]::new($false))

    $runRoot = Join-Path $Root 'codex-run'
    $repoRoot = Join-Path $runRoot 'repo'
    $homeRoot = Join-Path $runRoot 'home'
    New-Item -ItemType Directory -Path $repoRoot, $homeRoot -Force | Out-Null
    if ($Mode -eq 'timeout') {
        [System.IO.File]::WriteAllText((Join-Path $homeRoot 'codex-observability-timeout'), '1', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $repoRoot 'codex-observability-timeout'), '1', [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText((Join-Path $repoRoot 'AGENTS.md'), '# codex observability repo instruction', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runRoot 'prompt.md'), 'codex observability prompt', [System.Text.UTF8Encoding]::new($false))
    $runPath = Join-Path $runRoot 'run.json'
    Write-TestJson -Path $runPath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = 99
        evalName = 'codex-observability'
        candidateSkillName = 'candidate'
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
        fixtureHash = ('c' * 64)
    })
    $profilePath = Join-Path $Root 'execution-profile.json'
    Write-TestJson -Path $profilePath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'codex'
        model = 'gpt-5.6-luna'
        reasoning_effort = 'medium'
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = $TimeoutSeconds
        concurrency = 1
    })

    $ambientCodexHome = Join-Path $Root 'ambient-codex-home'
    New-Item -ItemType Directory -Path $ambientCodexHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ambientCodexHome 'auth.json'), '{"access_token":"fixture"}', [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Root = $Root
        FakeBin = $fakeBin
        RunRoot = $runRoot
        RunPath = $runPath
        ProfilePath = $profilePath
        AmbientCodexHome = $ambientCodexHome
        RunnerStderrPath = Join-Path $Root 'runner.stderr'
    }
}

function Invoke-CodexAppServerFixture {
    param(
        [ValidateSet('success', 'timeout')][string]$Mode,
        [double]$HeartbeatSeconds = 0.15,
        [int]$TimeoutSeconds = 5
    )

    $fixture = New-CodexObservabilityFixture -Root (Join-Path $testRoot ('codex-app-server-' + $Mode + '-' + [Guid]::NewGuid().ToString('N'))) -Mode $Mode -TimeoutSeconds $TimeoutSeconds
    $runnerPath = Join-Path $runnerRoot 'codex\runner.ps1'
    $previousPath = [Environment]::GetEnvironmentVariable('PATH')
    $previousCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    $previousProgress = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS')
    $previousHeartbeat = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS')
    $previousOpenAiKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY')
    $heartbeatText = $HeartbeatSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        [Environment]::SetEnvironmentVariable('PATH', $fixture.FakeBin + [System.IO.Path]::PathSeparator + $previousPath)
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $fixture.AmbientCodexHome)
        [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null)
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS', '1')
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS', $heartbeatText)
        $output = & $pwshPath -NoProfile -NonInteractive -File $runnerPath execute -Run $fixture.RunPath -Profile $fixture.ProfilePath 2>$fixture.RunnerStderrPath
        $exitCode = $LASTEXITCODE
    } finally {
        $clock.Stop()
        [Environment]::SetEnvironmentVariable('PATH', $previousPath)
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousCodexHome)
        [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $previousOpenAiKey)
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS', $previousProgress)
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS', $previousHeartbeat)
    }

    $stdout = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    $stderr = if (Test-Path -LiteralPath $fixture.RunnerStderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($fixture.RunnerStderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    $result = if ([string]::IsNullOrWhiteSpace($stdout)) { $null } else { $stdout | ConvertFrom-Json -Depth 100 }
    $progressEvents = @(Get-RelayedProgressEventsFromText -Text $stderr)
    return [pscustomobject]@{
        Fixture = $fixture
        ExitCode = $exitCode
        ElapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
        Stdout = $stdout
        Stderr = $stderr
        Result = $result
        ProgressEvents = $progressEvents
        AppServerEvents = @($progressEvents | Where-Object { [string]$_.phase -eq 'codex-app-server' })
        RawEventsPath = Join-Path $fixture.RunRoot 'evidence\codex-app-server-events.jsonl'
        RawEventsText = if (Test-Path -LiteralPath (Join-Path $fixture.RunRoot 'evidence\codex-app-server-events.jsonl') -PathType Leaf) { [System.IO.File]::ReadAllText((Join-Path $fixture.RunRoot 'evidence\codex-app-server-events.jsonl'), [System.Text.UTF8Encoding]::new($false)) } else { '' }
        RawStderrPath = Join-Path $fixture.RunRoot 'evidence\codex-stderr.txt'
        RawStderrText = if (Test-Path -LiteralPath (Join-Path $fixture.RunRoot 'evidence\codex-stderr.txt') -PathType Leaf) { [System.IO.File]::ReadAllText((Join-Path $fixture.RunRoot 'evidence\codex-stderr.txt'), [System.Text.UTF8Encoding]::new($false)) } else { '' }
    }
}

try {
    # Pre-warm the shared activity type so its one-time JIT/compile cost is paid
    # before any timed scenario. Otherwise, under heavy machine load, that cost
    # inflates the first child's launch timestamp and compresses its heartbeat
    # window, making timing-sensitive assertions flaky.
    Initialize-RunnerActivityType

    # ------------------------------------------------------------------
    # Test 1 - quiet but alive: a healthy but silent process must still be
    # visibly alive. Heartbeats appear even though the process emits nothing.
    # ------------------------------------------------------------------
    $quietScript = New-SyntheticChildScript -Name 'quiet' -Body @'
Start-Sleep -Milliseconds 1500
[Console]::Out.Write('{"status":"completed"}')
'@
    $quiet = Invoke-SyntheticChild -ScriptPath $quietScript -WorkerId 'arm-1-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 0 $quiet.ExitCode 'quiet-but-alive child exits cleanly'
    $quietHeartbeats = @($quiet.Events | Where-Object { [string]$_.state -eq 'running' -and [string]$_.origin -eq 'parent' -and $null -ne $_.PSObject.Properties['pid'] })
    Assert-True ($quietHeartbeats.Count -ge 2) "a quiet but alive process still emits heartbeats (got $($quietHeartbeats.Count))"
    $quietElapsed = @($quiet.Events | Where-Object { $null -ne $_.PSObject.Properties['elapsedSeconds'] } | ForEach-Object { [double]$_.elapsedSeconds })
    $quietElapsedSpan = (($quietElapsed | Measure-Object -Maximum).Maximum) - (($quietElapsed | Measure-Object -Minimum).Minimum)
    Assert-True ($quietElapsedSpan -ge 0.2) "quiet progress shows elapsed runtime advancing (span=$([Math]::Round($quietElapsedSpan,3))s)"
    Assert-True (@($quiet.Events | Where-Object { [int64](Get-Field $_ 'stderrEvents' 0) -ne 0 }).Count -eq 0) 'quiet process reports zero real stderr activity'
    Assert-True (@($quiet.Events | Where-Object { [string]$_.state -eq 'completed' }).Count -eq 1) 'quiet process reports a terminal completed state'

    # ------------------------------------------------------------------
    # Test 2 - active process: periodic output is observable as live activity
    # without corrupting the captured machine result or leaking into it.
    # ------------------------------------------------------------------
    $activeScript = New-SyntheticChildScript -Name 'active' -Body @'
for ($i = 0; $i -lt 4; $i++) {
    [Console]::Error.WriteLine("chunk $i produced")
    Start-Sleep -Milliseconds 250
}
[Console]::Error.WriteLine('@@AGENTIC-PROGRESS@@ {"state":"active","phase":"model-cli","detail":"turn-1","stdoutEvents":3}')
[Console]::Out.Write('{"status":"completed"}')
'@
    $active = Invoke-SyntheticChild -ScriptPath $activeScript -WorkerId 'arm-2-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 0 $active.ExitCode 'active child exits cleanly'
    Assert-Equal '{"status":"completed"}' ((Get-Content -LiteralPath $active.StdoutPath -Raw).Trim()) 'active child result STDOUT is captured exactly, uncorrupted by activity'
    Assert-True (@($active.Events | Where-Object { [int64](Get-Field $_ 'stderrEvents' 0) -ge 1 }).Count -ge 1) 'active process real stderr activity is observable in heartbeats'
    $activeWithAge = @($active.Events | Where-Object { $null -ne $_.PSObject.Properties['lastActivitySeconds'] })
    Assert-True ($activeWithAge.Count -ge 1) 'active process reports the age of its most recent activity'
    $relayed = @($active.Events | Where-Object { [string]$_.origin -eq 'relay' })
    Assert-True ($relayed.Count -ge 1) 'structured child progress is relayed through the parent'
    Assert-Equal 'arm-2-with_skill' ([string]$relayed[0].worker) 'a relayed event is attributed to the emitting worker'
    Assert-Equal 'turn-1' ([string]$relayed[0].detail) 'a relayed event preserves the safe child-provided detail'

    # ------------------------------------------------------------------
    # Test 3 - hanging process: the watchdog must fire, terminate the child,
    # and produce a final diagnostic. There must be no indefinite hang.
    # ------------------------------------------------------------------
    $hangScript = New-SyntheticChildScript -Name 'hang' -Body @'
while ($true) { Start-Sleep -Milliseconds 150 }
'@
    $hangClock = [System.Diagnostics.Stopwatch]::StartNew()
    $hang = Invoke-SyntheticChild -ScriptPath $hangScript -WorkerId 'arm-3-with_skill' -TimeoutSeconds 2 -HeartbeatSeconds 0.3
    $hangClock.Stop()
    Assert-True ($hangClock.Elapsed.TotalSeconds -lt 15) ("hanging process reaches a terminal state promptly; elapsed={0:N2}s" -f $hangClock.Elapsed.TotalSeconds)
    Assert-True ([bool]$hang.Child.TimedOut) 'hanging process is reported as timed out'
    Assert-True ([bool]$hang.Child.TerminationObserved) 'hanging process is actually terminated'
    Assert-True ($null -eq $hang.ExitCode) 'timed-out child has no synthesized success exit code'
    $hangHeartbeats = @($hang.Events | Where-Object { [string]$_.state -eq 'running' -and [string]$_.origin -eq 'parent' })
    Assert-True ($hangHeartbeats.Count -ge 2) 'heartbeats continue while a process hangs'
    $timedOut = @($hang.Events | Where-Object { [string]$_.state -eq 'timed-out' })
    Assert-Equal 1 $timedOut.Count 'a hanging process produces exactly one timed-out diagnostic'
    Assert-True ([bool]$timedOut[0].terminationObserved) 'the timeout diagnostic records that termination was observed'
    Assert-True ($null -ne $timedOut[0].PSObject.Properties['elapsedSeconds'] -and [double]$timedOut[0].elapsedSeconds -gt 0) 'the timeout diagnostic records elapsed runtime'
    Assert-True (@($hang.Events | Where-Object { [string]$_.state -eq 'terminating' }).Count -ge 1) 'a terminating lifecycle state precedes termination'

    # ------------------------------------------------------------------
    # Test 6 - fast successful runner: observability must not disturb a normal
    # short execution or its captured result.
    # ------------------------------------------------------------------
    $fastScript = New-SyntheticChildScript -Name 'fast' -Body @'
[Console]::Out.Write('{"status":"completed"}')
'@
    $fast = Invoke-SyntheticChild -ScriptPath $fastScript -WorkerId 'arm-6-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 0 $fast.ExitCode 'fast successful child exits cleanly'
    Assert-Equal '{"status":"completed"}' ((Get-Content -LiteralPath $fast.StdoutPath -Raw).Trim()) 'fast child result is captured exactly'
    Assert-True (@($fast.Events | Where-Object { [string]$_.state -eq 'running' -and $null -ne $_.PSObject.Properties['pid'] }).Count -ge 1) 'fast child still records a launch lifecycle event'
    Assert-True (@($fast.Events | Where-Object { [string]$_.state -eq 'completed' }).Count -eq 1) 'fast child records exactly one completed state'

    # ------------------------------------------------------------------
    # Test 7 - failure diagnostics: a runner that fails after some activity must
    # yield a diagnostic identifying meaningful last-known state.
    # ------------------------------------------------------------------
    $failScript = New-SyntheticChildScript -Name 'fail' -Body @'
[Console]::Error.WriteLine('preparing request')
Start-Sleep -Milliseconds 400
[Console]::Error.WriteLine('harness aborted unexpectedly')
exit 17
'@
    $fail = Invoke-SyntheticChild -ScriptPath $failScript -WorkerId 'arm-7-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 17 $fail.ExitCode 'failing child reports its real non-zero exit code'
    $failed = @($fail.Events | Where-Object { [string]$_.state -eq 'failed' })
    Assert-Equal 1 $failed.Count 'a failing child produces exactly one failure diagnostic'
    Assert-Equal 17 ([int]$failed[0].exitCode) 'the failure diagnostic records the exit code'
    Assert-True ([int64](Get-Field $failed[0] 'stderrEvents' 0) -ge 1) 'the failure diagnostic records observed stderr activity'
    Assert-Equal 'process exited with non-zero status' ([string]$failed[0].detail) 'the failure diagnostic keeps a structured detail only'
    Assert-True ([bool](Get-Field $failed[0] 'outputDrainCompleted' $false)) 'the failure diagnostic records bounded output draining'
    $failLogText = if (Test-Path -LiteralPath $fail.LogPath -PathType Leaf) { [System.IO.File]::ReadAllText($fail.LogPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    Assert-True (-not $failLogText.Contains('harness aborted unexpectedly')) 'raw stderr text is absent from persisted progress diagnostics'
    Assert-True (-not ([string]$fail.OperatorStderr).Contains('harness aborted unexpectedly')) 'raw stderr text is absent from live operator diagnostics'
    Assert-True ((Get-Content -LiteralPath $fail.StderrPath -Raw).Contains('harness aborted unexpectedly')) 'raw stderr evidence remains available in its file'

    # ------------------------------------------------------------------
    # Test 8 - sensitive value hygiene: a recognizable secret in the process
    # environment and stderr must never surface in operator progress output.
    # ------------------------------------------------------------------
    $secret = 'topsecret-' + [Guid]::NewGuid().ToString('N')
    $oldSecret = [Environment]::GetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET')
    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET', $secret)
    try {
        $secretScript = New-SyntheticChildScript -Name 'secret' -Body @'
[Console]::Error.WriteLine('AUTH_TOKEN=' + [Environment]::GetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET'))
Start-Sleep -Milliseconds 300
exit 9
'@
        $secretRun = Invoke-SyntheticChild -ScriptPath $secretScript -WorkerId 'arm-8-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET', $oldSecret)
    }
    $secretLog = if (Test-Path -LiteralPath $secretRun.LogPath -PathType Leaf) { [System.IO.File]::ReadAllText($secretRun.LogPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    Assert-True (-not $secretLog.Contains($secret)) 'the raw secret value never appears in persisted progress output'
    Assert-True (-not ([string]$secretRun.OperatorStderr).Contains($secret)) 'the raw secret value never appears in live operator progress'
    $secretFailed = @($secretRun.Events | Where-Object { [string]$_.state -eq 'failed' })
    Assert-Equal 1 $secretFailed.Count 'the secret-bearing child still produces a failure diagnostic'
    Assert-Equal 'process exited with non-zero status' ([string]$secretFailed[0].detail) 'secret-bearing failures keep structured detail only'
    Assert-True ([bool](Test-Path -LiteralPath $secretRun.StderrPath -PathType Leaf)) 'raw child stderr evidence is still captured to its file'
    Assert-True ((Get-Content -LiteralPath $secretRun.StderrPath -Raw).Contains($secret)) 'raw child stderr evidence still retains the secret for deliberate forensic inspection'

    # ------------------------------------------------------------------
    # Tests 4 and 5 - one real runner-owned fan-out run over the deterministic
    # fixture proves concurrent-arm attribution, the STDOUT machine contract,
    # and persisted progress evidence, all on the true operator-facing path.
    # ------------------------------------------------------------------
    $fanoutResult = Invoke-ObservabilityFanout -Root (Join-Path $testRoot 'fanout') -EvalCount 2 -Concurrency 4 -DelayMs 700
    Assert-Equal 0 $fanoutResult.ExitCode 'observability fan-out completes successfully'

    # Test 5 - the STDOUT contract: exactly one machine-readable terminal JSON.
    $stdoutTrimmed = ([string]$fanoutResult.Stdout).Trim()
    $terminal = $null
    $terminal = $stdoutTrimmed | ConvertFrom-Json -Depth 100
    Assert-Equal 'phase1' ([string]$terminal.phase) 'STDOUT still carries exactly one machine-readable terminal summary'
    Assert-Equal 'completed' ([string]$terminal.status) 'the terminal summary reports completion'
    Assert-True (-not $stdoutTrimmed.Contains((Get-RunnerProgressSentinel))) 'no relay sentinel ever leaks onto STDOUT'
    Assert-True (-not ($stdoutTrimmed -match '(?m)^\[synthetic\]|(?m)^\[fixture\]')) 'no operator progress line contaminates STDOUT'
    Assert-True ($stdoutTrimmed.StartsWith('{') -and $stdoutTrimmed.EndsWith('}')) 'STDOUT is a single JSON object with no surrounding progress text'

    # Progress is also persisted for post-mortem inspection at the advertised path.
    Assert-Equal 'progress/phase1-progress.jsonl' ([string]$terminal.progress_log) 'the terminal summary advertises where progress is persisted'
    $persistedLog = Join-Path $fanoutResult.IterationDirectory ([string]$terminal.progress_log)
    Assert-True (Test-Path -LiteralPath $persistedLog -PathType Leaf) 'the persisted progress log exists at the advertised path'
    $persistedEvents = @(Get-Content -LiteralPath $persistedLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($persistedEvents.Count -ge 4) 'the persisted progress log retains events for post-mortem inspection'

    # Test 4 - concurrent-arm attribution: every progress line is attributable.
    $stderrLines = @(([string]$fanoutResult.Stderr) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $progressLines = @($stderrLines | Where-Object { $_ -match '^\[(synthetic|fixture)\]' })
    Assert-True ($progressLines.Count -ge 2) 'the concurrent fan-out emits live operator progress on STDERR'
    $unlabeled = @($progressLines | Where-Object { -not ($_ -match '\[arm-\d+-(with_skill|without_skill)\]') })
    Assert-Equal 0 $unlabeled.Count 'every operator progress line carries a resolvable worker identity'
    $workerIds = @($persistedEvents | ForEach-Object { [string]$_.worker } | Where-Object { $_ -match '^arm-\d+-' } | Sort-Object -Unique)
    Assert-True ($workerIds.Count -ge 2) "concurrent arms are individually attributable (distinct workers: $($workerIds.Count))"
    foreach ($workerId in @('arm-1-with_skill', 'arm-1-without_skill', 'arm-2-with_skill', 'arm-2-without_skill')) {
        Assert-True ($workerIds -contains $workerId) "progress is attributed to worker $workerId"
    }
    # Attribution must be exclusive: an event's fields belong to exactly its worker.
    $misattributed = @($persistedEvents | Where-Object {
            [string]$_.state -in @('running', 'active', 'completed', 'timed-out', 'failed') -and
            $null -ne $_.PSObject.Properties['configuration'] -and
            -not ([string]$_.worker).EndsWith([string]$_.configuration)
        })
    Assert-Equal 0 $misattributed.Count 'no progress event mixes one worker identity with another configuration'

    # ------------------------------------------------------------------
    # Test 9 - the shared process primitive: runner model-CLI progress is opt-in
    # via the orchestration environment, relays through STDERR, and never
    # contaminates the captured model result on STDOUT.
    # ------------------------------------------------------------------
    Assert-True ($null -eq (Get-RunnerModelProgressContext -Runner 'opencode')) 'runner model-CLI progress is silent without the orchestration flag'
    $previousFlag = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS')
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS', '1')
    try {
        $enabledContext = Get-RunnerModelProgressContext -Runner 'opencode' -Phase 'opencode-cli'
        Assert-True ($null -ne $enabledContext) 'the orchestration flag enables a runner model-CLI progress context'
        Assert-Equal 'Relayable' ([string]$enabledContext['channel']) 'runner model-CLI progress uses the relayable channel'
        Assert-Equal 'opencode' ([string]$enabledContext['runner']) 'runner model-CLI progress context carries the runner identity'
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS', $previousFlag)
    }

    $primitiveDriver = New-SyntheticChildScript -Name 'primitive-driver' -Body @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $env:AGENTIC_OBS_RUNNER_ROOT 'runner-common.ps1')
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$ctx = @{ enabled = $true; runner = 'opencode'; phase = 'opencode-cli'; channel = 'Relayable'; heartbeatSeconds = 0.3 }
$grandchild = 'Start-Sleep -Milliseconds 900; [Console]::Out.Write(''grandchild-done'')'
$r = Invoke-RunnerProcess -FileName $pwsh -ArgumentList @('-NoProfile', '-Command', $grandchild) -WorkingDirectory $env:AGENTIC_OBS_RUNNER_ROOT -TimeoutSeconds 20 -ProgressContext $ctx
[Console]::Out.Write([string]$r.Stdout)
'@
    $driverStderrPath = Join-Path $testRoot 'primitive.stderr'
    $previousRoot = [Environment]::GetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT')
    [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $runnerRoot)
    try {
        $driverOut = & $pwshPath -NoProfile -NonInteractive -File $primitiveDriver 2>$driverStderrPath
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $previousRoot)
    }
    $driverStdout = ([string]::Join('', @($driverOut | ForEach-Object { [string]$_ }))).Trim()
    $driverStderr = if (Test-Path -LiteralPath $driverStderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($driverStderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    Assert-Equal 'grandchild-done' $driverStdout 'the model result on STDOUT passes through the shared primitive uncorrupted'
    Assert-True (-not $driverStdout.Contains((Get-RunnerProgressSentinel))) 'no relayable sentinel leaks onto the shared primitive STDOUT'
    Assert-True ($driverStderr.Contains((Get-RunnerProgressSentinel))) 'the shared primitive relays model-process progress on STDERR'
    Assert-True ($driverStderr -match '"state":"running"') 'the relayed model-process progress reports a running lifecycle state'

    # ------------------------------------------------------------------
    # Test 9b - active inner model process: incremental output advances
    # stdout/stderr event and byte counters BEFORE the process completes.
    # A sleeping grandchild with one final write does NOT satisfy this test.
    # ------------------------------------------------------------------
    $activeInnerDriver = New-SyntheticChildScript -Name 'active-inner-driver' -Body @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $env:AGENTIC_OBS_RUNNER_ROOT 'runner-common.ps1')
. (Join-Path $env:AGENTIC_OBS_RUNNER_ROOT 'runner-progress.ps1')
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$ctx = @{ enabled = $true; runner = 'opencode'; phase = 'opencode-cli'; channel = 'Relayable'; heartbeatSeconds = 0.15 }
# Grandchild emits 6 stderr lines at 130ms intervals, then the final stdout result.
$grandchildBody = 'for ($i = 0; $i -lt 6; $i++) { [Console]::Error.WriteLine("event-" + $i); [System.Threading.Thread]::Sleep(130) }; [Console]::Out.Write("{""result"":""active-inner-done""}")'
$r = Invoke-RunnerProcess -FileName $pwsh -ArgumentList @('-NoProfile', '-Command', $grandchildBody) -WorkingDirectory $env:AGENTIC_OBS_RUNNER_ROOT -TimeoutSeconds 20 -ProgressContext $ctx
# Forward captured stdout verbatim so the outer driver can verify fidelity.
[Console]::Out.Write([string]$r.Stdout)
'@
    $activeInnerStderrPath = Join-Path $testRoot 'active-inner-driver.stderr'
    $previousRoot2 = [Environment]::GetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT')
    [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $runnerRoot)
    try {
        $activeInnerOut = & $pwshPath -NoProfile -NonInteractive -File $activeInnerDriver 2>$activeInnerStderrPath
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $previousRoot2)
    }
    $activeInnerStdout = ([string]::Join('', @($activeInnerOut | ForEach-Object { [string]$_ }))).Trim()
    $activeInnerStderr = if (Test-Path -LiteralPath $activeInnerStderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($activeInnerStderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    # Machine STDOUT must be the exact captured model result, uncorrupted.
    Assert-Equal '{"result":"active-inner-done"}' $activeInnerStdout 'active inner process: captured stdout passes through uncorrupted'
    Assert-True (-not $activeInnerStdout.Contains((Get-RunnerProgressSentinel))) 'active inner process: no sentinel leaks onto captured STDOUT'
    # Parse the relayed sentinel lines to verify live activity tracking.
    $sentinel = Get-RunnerProgressSentinel
    $relayedLines = @($activeInnerStderr -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith($sentinel) })
    Assert-True ($relayedLines.Count -ge 2) "active inner process: at least two relayed heartbeats (got $($relayedLines.Count))"
    $relayedEvents = @($relayedLines | ForEach-Object {
            $payload = $_.TrimStart().Substring($sentinel.Length).TrimStart()
            try { $payload | ConvertFrom-Json } catch { $null }
        } | Where-Object { $null -ne $_ })
    # Counters must advance: the last heartbeat must show more events than the first.
    $eventCounts = @($relayedEvents | Where-Object { $null -ne $_.PSObject.Properties['stderrEvents'] } | ForEach-Object { [int64]$_.stderrEvents })
    Assert-True ($eventCounts.Count -ge 2) 'active inner process: multiple heartbeats carry stderrEvents'
    $firstCount = ($eventCounts | Measure-Object -Minimum).Minimum
    $lastCount = ($eventCounts | Measure-Object -Maximum).Maximum
    Assert-True ($lastCount -gt $firstCount) "active inner process: stderrEvents increase across heartbeats (first=$firstCount last=$lastCount)"
    # Byte counters must also advance.
    $byteCounts = @($relayedEvents | Where-Object { $null -ne $_.PSObject.Properties['stderrBytes'] } | ForEach-Object { [int64]$_.stderrBytes })
    Assert-True ($byteCounts.Count -ge 2) 'active inner process: multiple heartbeats carry stderrBytes'
    Assert-True (($byteCounts | Measure-Object -Maximum).Maximum -gt ($byteCounts | Measure-Object -Minimum).Minimum) 'active inner process: stderrBytes increase across heartbeats'
    # lastActivity must appear once any real output has arrived.
    $withLastActivity = @($relayedEvents | Where-Object { $null -ne $_.PSObject.Properties['lastActivitySeconds'] })
    Assert-True ($withLastActivity.Count -ge 1) 'active inner process: lastActivity is present once real output is received'

    # ------------------------------------------------------------------
    # Test 9c - OpenCode-shaped streaming: a grandchild emitting structured
    # JSONL/event-like output (simulating OpenCode session events) advances
    # activity metadata safely without echoing model content to the operator.
    # ------------------------------------------------------------------
    $openCodeGrandchild = New-SyntheticChildScript -Name 'oc-stream-grandchild' -Body @'
$events = @(
    '{"type":"session.start","session_id":"abc123","model":"claude-3-5-haiku"}',
    '{"type":"assistant.delta","session_id":"abc123","content":"I will"}',
    '{"type":"assistant.delta","session_id":"abc123","content":"analyze"}',
    '{"type":"tool.use","tool":"read_file","path":"input.txt"}',
    '{"type":"assistant.delta","session_id":"abc123","content":"the result"}',
    '{"type":"session.complete","session_id":"abc123","cost":0.002}'
)
foreach ($ev in $events) {
    [Console]::Error.WriteLine($ev)
    [System.Threading.Thread]::Sleep(100)
}
[Console]::Out.Write('{"status":"completed","session_id":"abc123"}')
'@
    $openCodeStreamDriver = New-SyntheticChildScript -Name 'opencode-stream-driver' -Body (
'$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest' + "`n" +
'. (Join-Path $env:AGENTIC_OBS_RUNNER_ROOT "runner-common.ps1")' + "`n" +
'. (Join-Path $env:AGENTIC_OBS_RUNNER_ROOT "runner-progress.ps1")' + "`n" +
'$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source' + "`n" +
'$ctx = @{ enabled = $true; runner = "opencode"; phase = "opencode-cli"; channel = "Relayable"; heartbeatSeconds = 0.15 }' + "`n" +
('$r = Invoke-RunnerProcess -FileName $pwsh -ArgumentList @("-NoProfile", "-File", $env:AGENTIC_OBS_GRANDCHILD) -WorkingDirectory $env:AGENTIC_OBS_RUNNER_ROOT -TimeoutSeconds 20 -ProgressContext $ctx') + "`n" +
'[Console]::Out.Write([string]$r.Stdout)'
)
    $ocStreamStderrPath = Join-Path $testRoot 'oc-stream-driver.stderr'
    $previousRoot3 = [Environment]::GetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT')
    $previousGrandchild = [Environment]::GetEnvironmentVariable('AGENTIC_OBS_GRANDCHILD')
    [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $runnerRoot)
    [Environment]::SetEnvironmentVariable('AGENTIC_OBS_GRANDCHILD', $openCodeGrandchild)
    try {
        $ocStreamOut = & $pwshPath -NoProfile -NonInteractive -File $openCodeStreamDriver 2>$ocStreamStderrPath
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $previousRoot3)
        [Environment]::SetEnvironmentVariable('AGENTIC_OBS_GRANDCHILD', $previousGrandchild)
    }
    $ocStreamStdout = ([string]::Join('', @($ocStreamOut | ForEach-Object { [string]$_ }))).Trim()
    $ocStreamStderr = if (Test-Path -LiteralPath $ocStreamStderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($ocStreamStderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    Assert-Equal '{"status":"completed","session_id":"abc123"}' $ocStreamStdout 'opencode streaming: final stdout captured exactly'
    Assert-True (-not $ocStreamStdout.Contains('assistant.delta')) 'opencode streaming: model content not present on stdout'
    Assert-True (-not $ocStreamStderr.Contains('"content":"I will"')) 'opencode streaming: model delta content not echoed to operator stderr'
    Assert-True (-not $ocStreamStderr.Contains('"content":"analyze"')) 'opencode streaming: second delta not echoed to operator stderr'
    $ocRelayedLines = @($ocStreamStderr -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith($sentinel) })
    Assert-True ($ocRelayedLines.Count -ge 2) "opencode streaming: operator receives multiple heartbeats (got $($ocRelayedLines.Count))"
    $ocRelayedEvents = @($ocRelayedLines | ForEach-Object {
            $p = $_.TrimStart().Substring($sentinel.Length).TrimStart()
            try { $p | ConvertFrom-Json } catch { $null }
        } | Where-Object { $null -ne $_ })
    $ocEventCounts = @($ocRelayedEvents | Where-Object { $null -ne $_.PSObject.Properties['stderrEvents'] } | ForEach-Object { [int64]$_.stderrEvents })
    Assert-True ($ocEventCounts.Count -ge 2) 'opencode streaming: multiple heartbeats carry stderrEvents'
    Assert-True (($ocEventCounts | Measure-Object -Maximum).Maximum -gt ($ocEventCounts | Measure-Object -Minimum).Minimum) 'opencode streaming: stderrEvents advance as events are received'

    # ------------------------------------------------------------------
    # Test 9d - Codex app-server real transport: the actual Invoke-CodexAppServer
    # path must emit heartbeats while blocked waiting for protocol input, then
    # surface real protocol counters and last-activity aging without echoing
    # JSON-RPC payloads or model content to operator progress.
    # ------------------------------------------------------------------
    $codexApp = Invoke-CodexAppServerFixture -Mode 'success' -HeartbeatSeconds 0.15 -TimeoutSeconds 6
    Assert-Equal 0 $codexApp.ExitCode 'codex app-server: runner process exits cleanly'
    $codexStdout = ([string]$codexApp.Stdout).Trim()
    Assert-True ($codexStdout.StartsWith('{') -and $codexStdout.EndsWith('}')) 'codex app-server: STDOUT remains one terminal JSON object'
    Assert-True (-not $codexStdout.Contains((Get-RunnerProgressSentinel))) 'codex app-server: no progress sentinel contaminates STDOUT'
    Assert-True (-not ($codexStdout -match '(?m)^\[codex\]')) 'codex app-server: operator progress never contaminates STDOUT'
    Assert-Equal 'completed' ([string]$codexApp.Result.status) 'codex app-server: execution result completes successfully'
    Assert-Equal 'OBSERVABILITY_MODEL_CONTENT_CANARY' ([string]$codexApp.Result.final_response.text) 'codex app-server: machine output preserves the final response text'
    Assert-True ([bool](Test-Path -LiteralPath $codexApp.RawEventsPath -PathType Leaf)) 'codex app-server: raw protocol evidence is retained on disk'
    Assert-True ($codexApp.RawEventsText.Contains('OBSERVABILITY_MODEL_CONTENT_CANARY')) 'codex app-server: raw protocol evidence retains model content'
    Assert-True ($codexApp.RawEventsText.Contains('OBSERVABILITY_PROTOCOL_OUTPUT_CANARY')) 'codex app-server: raw protocol evidence retains protocol payload content'
    Assert-True (-not $codexApp.Stderr.Contains('OBSERVABILITY_MODEL_CONTENT_CANARY')) 'codex app-server: model content is not echoed to operator progress'
    Assert-True (-not $codexApp.Stderr.Contains('OBSERVABILITY_PROTOCOL_OUTPUT_CANARY')) 'codex app-server: protocol payload content is not echoed to operator progress'
    $codexAppEvents = @($codexApp.AppServerEvents)
    Assert-True ($codexAppEvents.Count -ge 6) "codex app-server: real transport emitted observable progress events (got $($codexAppEvents.Count))"
    $firstProtocolIndex = -1
    for ($eventIndex = 0; $eventIndex -lt $codexAppEvents.Count; $eventIndex++) {
        if ([int64](Get-Field $codexAppEvents[$eventIndex] 'stdoutEvents' 0) -gt 0) {
            $firstProtocolIndex = $eventIndex
            break
        }
    }
    Assert-True ($firstProtocolIndex -gt 0) 'codex app-server: at least one heartbeat occurs before the first protocol message is observed'
    $preProtocolEvents = @($codexAppEvents[0..($firstProtocolIndex - 1)])
    $quietPreProtocolHeartbeats = @($preProtocolEvents | Where-Object {
            [string]$_.state -eq 'running' -and
            [int64](Get-Field $_ 'stdoutEvents' 0) -eq 0 -and
            [int64](Get-Field $_ 'stdoutBytes' 0) -eq 0 -and
            $null -eq $_.PSObject.Properties['lastActivitySeconds'] -and
            [string]::IsNullOrWhiteSpace([string](Get-Field $_ 'detail' ''))
        })
    Assert-True ($quietPreProtocolHeartbeats.Count -ge 1) 'codex app-server: quiet heartbeats are visible before any protocol message arrives'
    $firstActivityEvent = $codexAppEvents[$firstProtocolIndex]
    $firstActivityCount = [int64](Get-Field $firstActivityEvent 'stdoutEvents' 0)
    $firstActivityBytes = [int64](Get-Field $firstActivityEvent 'stdoutBytes' 0)
    Assert-True ($firstActivityCount -gt 0 -and $firstActivityBytes -gt 0) 'codex app-server: the first observed protocol heartbeat carries non-zero event and byte counters'
    Assert-True ($null -ne $firstActivityEvent.PSObject.Properties['lastActivitySeconds']) 'codex app-server: lastActivity appears after the first real protocol message'
    $sameCounterQuietEvents = @($codexAppEvents | Where-Object {
            [int64](Get-Field $_ 'stdoutEvents' 0) -eq $firstActivityCount -and
            [int64](Get-Field $_ 'stdoutBytes' 0) -eq $firstActivityBytes -and
            $null -ne $_.PSObject.Properties['lastActivitySeconds']
        })
    Assert-True ($sameCounterQuietEvents.Count -ge 2) 'codex app-server: quiet heartbeats preserve counters after the first protocol message'
    $sameCounterAges = @($sameCounterQuietEvents | ForEach-Object { [double]$_.lastActivitySeconds })
    $sameCounterMinAge = ($sameCounterAges | Measure-Object -Minimum).Minimum
    $sameCounterMaxAge = ($sameCounterAges | Measure-Object -Maximum).Maximum
    Assert-True ($sameCounterMaxAge -gt $sameCounterMinAge) 'codex app-server: lastActivitySeconds ages during a quiet period'
    $nextActivityEvent = @($codexAppEvents | Where-Object {
            [int64](Get-Field $_ 'stdoutEvents' 0) -gt $firstActivityCount -and
            [int64](Get-Field $_ 'stdoutBytes' 0) -gt $firstActivityBytes -and
            $null -ne $_.PSObject.Properties['lastActivitySeconds']
        } | Select-Object -First 1)
    Assert-True ($nextActivityEvent.Count -eq 1) 'codex app-server: later protocol traffic advances counters again'
    Assert-True ([double]$nextActivityEvent[0].lastActivitySeconds -lt $sameCounterMaxAge) 'codex app-server: lastActivitySeconds resets after fresh protocol traffic'

    # ------------------------------------------------------------------
    # Test 9e - Codex app-server timeout: repeated quiet heartbeats must not
    # extend the total timeout. The real transport still fails closed, bounded.
    # ------------------------------------------------------------------
    $codexTimeout = Invoke-CodexAppServerFixture -Mode 'timeout' -HeartbeatSeconds 0.15 -TimeoutSeconds 2
    Assert-Equal 0 $codexTimeout.ExitCode 'codex app-server timeout: runner still returns a terminal result object'
    Assert-True ($codexTimeout.ElapsedSeconds -lt 12) ("codex app-server timeout: transport remains bounded; elapsed={0:N3}s" -f $codexTimeout.ElapsedSeconds)
    Assert-Equal 'incompatible' ([string]$codexTimeout.Result.status) 'codex app-server timeout: native evidence still fails closed after the bounded timeout'
    Assert-Equal 'native_skill_isolation_unverified' ([string]$codexTimeout.Result.exit.failure.code) 'codex app-server timeout: the failure remains structured'
    Assert-True ([string]$codexTimeout.Result.exit.failure.message -match 'Codex did not finish before timeout_seconds') 'codex app-server timeout: the failure message preserves the bounded timeout detail'
    $timeoutAppEvents = @($codexTimeout.AppServerEvents)
    Assert-True ($timeoutAppEvents.Count -ge 2) 'codex app-server timeout: quiet heartbeats occur before the timeout result'
    $timeoutQuietEvents = @($timeoutAppEvents | Where-Object {
            [int64](Get-Field $_ 'stdoutEvents' 0) -eq 0 -and
            [int64](Get-Field $_ 'stdoutBytes' 0) -eq 0 -and
            $null -eq $_.PSObject.Properties['lastActivitySeconds']
        })
    Assert-True ($timeoutQuietEvents.Count -ge 2) 'codex app-server timeout: a silent server stays externally observable without inventing activity'

    # ------------------------------------------------------------------
    # Test 10 - synchronous wait/preflight heartbeat: Complete-RunnerChildProcess
    # must emit heartbeats while waiting even when the caller is not using the
    # concurrent Wait-AnyRunnerChild loop.
    # ------------------------------------------------------------------
    $slowPreflightScript = New-SyntheticChildScript -Name 'slow-preflight' -Body @'
Start-Sleep -Milliseconds 1500
[Console]::Out.Write('{"status":"compatible"}')
'@
    $preflightStdoutPath = Join-Path $testRoot 'preflight.stdout'
    $preflightStderrPath = Join-Path $testRoot 'preflight.stderr'
    $preflightLogPath = Join-Path $testRoot 'preflight-progress.jsonl'
    $preflightChild = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $slowPreflightScript) -WorkingDirectory $testRoot -StdoutPath $preflightStdoutPath -StderrPath $preflightStderrPath -TimeoutSeconds 30 -Runner 'opencode' -WorkerId 'preflight-arm-99' -EvalId 99 -Configuration 'with_skill' -Phase 'preflight' -ProgressLogPath $preflightLogPath -HeartbeatSeconds 0.3
    # Call Complete-RunnerChildProcess directly (the synchronous preflight path),
    # without using Wait-AnyRunnerChild.
    $preflightExit = Complete-RunnerChildProcess -Child $preflightChild
    $preflightEvents = @()
    if (Test-Path -LiteralPath $preflightLogPath -PathType Leaf) {
        $preflightEvents = @(Get-Content -LiteralPath $preflightLogPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    Assert-Equal 0 $preflightExit 'synchronous preflight completes cleanly'
    $preflightHeartbeats = @($preflightEvents | Where-Object { [string]$_.state -eq 'running' -and [string]$_.origin -eq 'parent' })
    Assert-True ($preflightHeartbeats.Count -ge 2) "synchronous Complete-RunnerChildProcess emits heartbeats during wait (got $($preflightHeartbeats.Count))"
    $preflightCompleted = @($preflightEvents | Where-Object { [string]$_.state -eq 'completed' })
    Assert-Equal 1 $preflightCompleted.Count 'synchronous preflight reports exactly one completed state'

    Write-Output 'Runner observability: PASS'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
