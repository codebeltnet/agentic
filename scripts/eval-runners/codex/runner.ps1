<#!
.SYNOPSIS
    Codex Eval Runner adapter.

.DESCRIPTION
    This is the only place where Codex CLI flags, CODEX_HOME handling, JSONL
    event parsing, and Codex isolation limitations are defined.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('describe', 'preflight', 'execute')]
    [string]$Command,

    [string]$Run,
    [string]$Profile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\runner-common.ps1')

$descriptor = [ordered]@{
    schema = (Get-RunnerSchemaNames).Descriptor
    protocol_version = (Get-RunnerSchemaNames).Protocol
    name = 'codex'
    version = '0.9.1'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = 'unavailable' }
    capabilities = [ordered]@{
        single_turn = 'supported'
        scripted_multi_turn_same_session = 'conditional'
        fresh_context = 'supported'
        isolated_home_config = 'supported'
        isolated_working_directory = 'supported'
        filesystem_confinement = 'conditional'
        ambient_candidate_skill_exclusion = 'supported'
        candidate_skill_exposure = 'supported'
        prompt_fidelity = 'supported'
        model_configuration_lock = 'supported'
        response_capture = 'supported'
        transcript_event_capture = 'supported'
        token_telemetry = 'conditional'
        cache_token_telemetry = 'conditional'
        tool_call_telemetry = 'supported'
        command_evidence = 'conditional'
        file_evidence = 'conditional'
        cost_telemetry = 'conditional'
        credential_child_filtering = 'supported'
        native_skill_activation_evidence = 'unsupported'
        # The app-server schema proves that a native child surface exists, not
        # what the child actually resolved or inherited. Terminal evidence is
        # required for every delegated-worker control.
        native_worker_delegation = 'conditional'
        delegated_worker_full_capability = 'conditional'
        delegated_worker_model_lock = 'conditional'
        delegated_worker_working_directory = 'conditional'
        delegated_worker_result_capture = 'conditional'
        delegated_worker_capacity_signal = 'conditional'
    }
    delegation = [ordered]@{
        dispatch_owner = 'runner'
        mode = 'native_worker'
        mechanism = 'Codex app-server native child session via thread/start and turn/start with per-worker cwd, model, and ephemeral context'
        worker_role = 'native-codex-child-session'
        full_capability = 'conditional'
        model_lock = 'conditional'
        working_directory = 'conditional'
        result_capture = 'conditional'
        capacity = 'harness_authoritative'
        nested_model_execution = $false
    }
    supported_telemetry = @('transcript_event_capture', 'token_telemetry', 'cache_token_telemetry', 'tool_call_telemetry', 'command_evidence', 'file_evidence', 'cost_telemetry')
    configuration_profiles = @('isolated-default')
    tool_profiles = @('default')
}

function Write-ProtocolError {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 2
}

function Resolve-CodexInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    return [pscustomobject]@{
        Run = Resolve-RunContract -RunPath $Run
        Profile = Resolve-ExecutionProfile -ProfilePath $Profile
    }
}

function Get-CodexAuthSource {
    $authVariables = @(Get-ProviderAuthenticationVariables -Provider 'openai')
    foreach ($name in $authVariables) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return [pscustomobject]@{ Kind = 'environment'; Name = $name; Path = $null }
        }
    }

    $configuredHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    $codexHome = if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    } else {
        $configuredHome
    }
    $authPath = Join-Path $codexHome 'auth.json'
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
        return [pscustomobject]@{ Kind = 'subscription_file'; Name = 'auth.json'; Path = (Resolve-Path -LiteralPath $authPath).Path }
    }

    return [pscustomobject]@{ Kind = 'missing'; Name = $null; Path = $null }
}

function Invoke-CodexCli {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment,
        [byte[]]$InputBytes = @(),
        [int]$TimeoutSeconds = 60
    )

    $allArguments = @($CommandInfo.Prefix) + @($Arguments)
    return Invoke-RunnerProcess -FileName $CommandInfo.FileName -ArgumentList $allArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
}

function New-CodexAuthOnlyHome {
    param([Parameter(Mandatory = $true)][object]$Auth)

    if ($Auth.Kind -ne 'subscription_file' -or [string]::IsNullOrWhiteSpace([string]$Auth.Path)) {
        throw 'Codex auth-only home requires a resolved subscription auth.json source.'
    }
    $homePath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-codex-auth-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $homePath -Force | Out-Null
    $authDestination = Join-Path $homePath 'auth.json'
    try {
        # The temporary home is intentionally created outside the prepared
        # package. It contains exactly one copied file and is removed in the
        # app-server finally block, including start/timeout failures.
        Copy-Item -LiteralPath $Auth.Path -Destination $authDestination -Force -ErrorAction Stop
        $entries = @(Get-ChildItem -LiteralPath $homePath -Force -ErrorAction Stop)
        if ($entries.Count -ne 1 -or [string]$entries[0].Name -ne 'auth.json' -or -not (Test-Path -LiteralPath $authDestination -PathType Leaf)) {
            throw 'Codex temporary subscription home was not auth-only.'
        }
        return [pscustomobject]@{
            Path = $homePath
            AuthPath = $authDestination
            AuthOnly = $true
        }
    } catch {
        if (Test-Path -LiteralPath $homePath) {
            Remove-Item -LiteralPath $homePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Assert-CodexProjectionSource {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $reparsePoint = [System.IO.FileAttributes]::ReparsePoint
    $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band $reparsePoint) -ne 0 })
    if ($links.Count -gt 0) {
        throw "Codex physical projection refuses reparse-point input '$($links[0].FullName)'."
    }
}

function Copy-CodexProjectionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    Assert-CodexProjectionSource -Path $Source
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-CodexProjectionFileSet {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
    } | Sort-Object)
}

function New-CodexExecutionProjection {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $projectionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-codex-projection-' + [Guid]::NewGuid().ToString('N'))
    $logicalRunRoot = [System.IO.Path]::GetFullPath([string]$Inputs.Run.RunRoot)
    $physicalRunRoot = [System.IO.Path]::GetFullPath($projectionRoot)
    if (Test-PathInside -BasePath $logicalRunRoot -CandidatePath $physicalRunRoot) {
        throw 'Codex physical projection unexpectedly resolved under the logical arm root.'
    }
    New-Item -ItemType Directory -Path $physicalRunRoot -Force | Out-Null
    $physicalPrompt = Join-Path $physicalRunRoot 'prompt.md'
    [System.IO.File]::WriteAllBytes($physicalPrompt, [byte[]]$Inputs.Run.PromptBytes)
    $physicalRepo = Join-Path $physicalRunRoot 'repo'
    $physicalHome = Join-Path $physicalRunRoot 'home'
    Copy-CodexProjectionDirectory -Source $Inputs.Run.WorkingDirectoryPath -Destination $physicalRepo
    Copy-CodexProjectionDirectory -Source $Inputs.Run.HomeDirectoryPath -Destination $physicalHome

    $physicalSkill = $null
    if ($Inputs.Run.CandidateSkillExposed) {
        $skillRelative = [System.IO.Path]::GetRelativePath($Inputs.Run.RunRoot, $Inputs.Run.SkillDirectoryPath)
        $physicalSkill = Join-Path $physicalRunRoot ($skillRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        Copy-CodexProjectionDirectory -Source $Inputs.Run.SkillDirectoryPath -Destination $physicalSkill
    }

    $physicalInteraction = $null
    if ($null -ne $Inputs.Run.InteractionPath) {
        $interactionRelative = [System.IO.Path]::GetRelativePath($Inputs.Run.RunRoot, $Inputs.Run.InteractionPath)
        $physicalInteraction = Join-Path $physicalRunRoot ($interactionRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $physicalInteraction) -Force | Out-Null
        Copy-Item -LiteralPath $Inputs.Run.InteractionPath -Destination $physicalInteraction -Force
        foreach ($turn in @($Inputs.Run.Interaction.turns)) {
            $source = [string](Get-JsonProperty -Object $turn -Name 'source' -Default '')
            if ([string]::IsNullOrWhiteSpace($source)) { continue }
            $logicalSource = Resolve-ContainedPath -BasePath $Inputs.Run.RunRoot -RelativePath $source -FieldName 'interaction turn source' -Kind File
            $sourceRelative = [System.IO.Path]::GetRelativePath($Inputs.Run.RunRoot, $logicalSource)
            $physicalSource = Join-Path $physicalRunRoot ($sourceRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $physicalSource) -Force | Out-Null
            Copy-Item -LiteralPath $logicalSource -Destination $physicalSource -Force
        }
    }

    $physicalRun = [pscustomobject]@{
        RunPath = $Inputs.Run.RunPath
        RunRoot = $physicalRunRoot
        Contract = $Inputs.Run.Contract
        EvalId = $Inputs.Run.EvalId
        EvalName = $Inputs.Run.EvalName
        Mode = $Inputs.Run.Mode
        PromptPath = $physicalPrompt
        PromptBytes = $Inputs.Run.PromptBytes
        PromptHash = $Inputs.Run.PromptHash
        WorkingDirectoryPath = $physicalRepo
        HomeDirectoryPath = $physicalHome
        SkillDirectoryPath = $physicalSkill
        CandidateSkillExposed = $Inputs.Run.CandidateSkillExposed
        FixtureHash = $Inputs.Run.FixtureHash
        SkillHash = $Inputs.Run.SkillHash
        InteractionPath = $physicalInteraction
        InteractionHash = $Inputs.Run.InteractionHash
        Interaction = $Inputs.Run.Interaction
    }
    return [pscustomobject]@{
        Root = $physicalRunRoot
        Run = $physicalRun
        LogicalRun = $Inputs.Run
        LogicalWorkingDirectory = $Inputs.Run.WorkingDirectoryPath
        LogicalHomeDirectory = $Inputs.Run.HomeDirectoryPath
        PhysicalWorkingDirectory = $physicalRepo
        PhysicalHomeDirectory = $physicalHome
        InitialRepositoryFiles = @(Get-CodexProjectionFileSet -Root $physicalRepo)
        Proven = $true
    }
}

function Sync-CodexProjectedRepository {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $logicalRepo = [string]$Projection.LogicalWorkingDirectory
    $physicalRepo = [string]$Projection.PhysicalWorkingDirectory
    $initialFiles = @($Projection.InitialRepositoryFiles)
    foreach ($relative in $initialFiles) {
        $physicalPath = Join-Path $physicalRepo ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $physicalPath -PathType Leaf)) {
            $logicalPath = Join-Path $logicalRepo ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $logicalPath -PathType Leaf) {
                Remove-Item -LiteralPath $logicalPath -Force
            }
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $physicalRepo -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $logicalRepo -Recurse -Force
    }
}

function Remove-CodexExecutionProjection {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $root = [System.IO.Path]::GetFullPath([string]$Projection.Root)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not (Test-PathInside -BasePath $tempRoot -CandidatePath $root)) {
        throw "Refusing to remove Codex projection outside the temporary directory: '$root'."
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

function Invoke-CodexAppServer {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth,
        [bool]$SupportsProviderModelFallback = $false,
        [int]$TimeoutSeconds = 900
    )

    if ($Auth.Kind -ne 'subscription_file') {
        throw 'Codex app-server subscription transport requires auth.json authentication.'
    }

    $start = [DateTime]::UtcNow
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $CommandInfo.FileName
    $psi.WorkingDirectory = $Inputs.Run.WorkingDirectoryPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @($CommandInfo.Prefix) + @('app-server', '--stdio', '-c', 'shell_environment_policy.inherit=none')) { [void]$psi.ArgumentList.Add([string]$argument) }

    $authHome = $null
    $authOnlyHomeRemoved = $false
    $parentEnvironment = $null
    $process = [System.Diagnostics.Process]::new()
    $writer = $null
    $reader = $null
    $stderrTask = $null
    $events = [System.Collections.Generic.List[string]]::new()
    $normalized = [System.Collections.Generic.List[string]]::new()
    $threadId = $null
    $threadSessionId = $null
    $turnId = $null
    $finalText = $null
    $latestUsage = $null
    $timedOut = $false
    $transportFailure = $null
    $threadReadFailure = $null
    $turnCompleted = $false
    $terminalTurn = $null
    $stderr = ''
    $actualExitCode = $null
    $processStarted = $false
    $threadStartRequest = $null
    $threadStartResponse = $null
    $turnStartRequest = $null
    $turnStartResponse = $null
    $turnStartRequests = [System.Collections.Generic.List[object]]::new()
    $turnStartResponses = [System.Collections.Generic.List[object]]::new()
    $turnRecords = [System.Collections.Generic.List[object]]::new()
    $requestedInteractionTurns = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Inputs.Run.Interaction) {
        $requestedInteractionTurns.Add([ordered]@{ role = 'user'; source = 'prompt.md'; content = $null })
    } else {
        foreach ($interactionTurn in @($Inputs.Run.Interaction.turns)) { $requestedInteractionTurns.Add($interactionTurn) }
    }
    $allTurnsCompleted = $true
    $threadReadResponse = $null
    $instructionSources = @()
    $instructionSourcesObserved = $false
    $modelReroutes = [System.Collections.Generic.List[object]]::new()

    try {
        $authHome = New-CodexAuthOnlyHome -Auth $Auth
        $parentEnvironment = New-RunnerEnvironment -Run $Inputs.Run -Additional @{ CODEX_HOME = $authHome.Path }
        $psi.Environment.Clear()
        foreach ($name in @($parentEnvironment.Keys)) { $psi.Environment[$name] = [string]$parentEnvironment[$name] }
        $process.StartInfo = $psi

        if (-not $process.Start()) { throw 'Could not start Codex app-server.' }
        $processStarted = $true
        $writer = $process.StandardInput
        $reader = $process.StandardOutput
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $writeMessage = {
            param([Parameter(Mandatory = $true)][object]$Value)
            $writer.WriteLine(($Value | ConvertTo-Json -Depth 50 -Compress))
            $writer.Flush()
        }
        $readMessage = {
            $remaining = $deadline - [DateTime]::UtcNow
            if ($remaining.TotalMilliseconds -le 0) { throw [TimeoutException]::new('Codex app-server timed out.') }
            $readTask = $reader.ReadLineAsync()
            $waitMilliseconds = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($remaining.TotalMilliseconds))
            if (-not $readTask.Wait($waitMilliseconds)) { throw [TimeoutException]::new('Codex app-server timed out.') }
            $line = $readTask.GetAwaiter().GetResult()
            if ($null -eq $line) { throw [EndOfStreamException]::new('Codex app-server closed stdout before the expected response.') }
            $events.Add($line)
            try { return ($line | ConvertFrom-Json -Depth 50) } catch { throw [FormatException]::new("Codex app-server emitted malformed JSON: $($_.Exception.Message)") }
        }
        $recordModelReroute = {
            param([Parameter(Mandatory = $true)][object]$Message)
            $reroute = Get-JsonProperty -Object $Message -Name 'params' -Default ([ordered]@{})
            $modelReroutes.Add($reroute)
            $normalized.Add(([ordered]@{ type = 'model.rerouted'; from_model = Get-JsonProperty -Object $reroute -Name 'fromModel' -Default $null; to_model = Get-JsonProperty -Object $reroute -Name 'toModel' -Default $null; reason = Get-JsonProperty -Object $reroute -Name 'reason' -Default $null } | ConvertTo-Json -Compress))
        }
        $waitForResponse = {
            param([Parameter(Mandatory = $true)][int]$ExpectedId, [Parameter(Mandatory = $true)][string]$Operation)
            while ($true) {
                $message = & $readMessage
                $messageId = Get-JsonProperty -Object $message -Name 'id' -Default $null
                $method = [string](Get-JsonProperty -Object $message -Name 'method' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($method) -and $null -ne $messageId) {
                    throw "Codex app-server requested unsupported interactive method '$method'."
                }
                if ($method -eq 'model/rerouted') {
                    & $recordModelReroute $message
                    continue
                }
                if ($null -eq $messageId -or [int]$messageId -ne $ExpectedId) { continue }
                $error = Get-JsonProperty -Object $message -Name 'error' -Default $null
                if ($null -ne $error) {
                    $errorMessage = [string](Get-JsonProperty -Object $error -Name 'message' -Default ($error | ConvertTo-Json -Depth 20 -Compress))
                    throw "Codex app-server $Operation failed: $errorMessage"
                }
                return $message
            }
        }

        $initializeRequest = 1
        & $writeMessage ([ordered]@{
            jsonrpc = '2.0'
            id = $initializeRequest
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{ name = 'codebelt-agentic-eval-runner'; title = 'Codebelt Eval Runner'; version = '0.9.1' }
                capabilities = [ordered]@{ experimentalApi = $true }
            }
        })
        $null = & $waitForResponse $initializeRequest 'initialize'
        & $writeMessage ([ordered]@{ jsonrpc = '2.0'; method = 'initialized' })

        $threadRequest = 2
        $threadStartParams = [ordered]@{
            model = $Inputs.Profile.Model
            cwd = $Inputs.Run.WorkingDirectoryPath
            approvalPolicy = 'never'
            # thread/start can persist project trust when it begins in a
            # writable sandbox. Keep the ephemeral thread read-only and
            # apply the intended workspace-write policy to the turn only.
            sandbox = 'read-only'
            ephemeral = $true
        }
        if ($SupportsProviderModelFallback) { $threadStartParams.allowProviderModelFallback = $false }
        $threadStartRequest = [ordered]@{ jsonrpc = '2.0'; id = $threadRequest; method = 'thread/start'; params = $threadStartParams }
        & $writeMessage $threadStartRequest
        $threadStartResponse = & $waitForResponse $threadRequest 'thread/start'
        $threadStartResult = Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null
        $threadMetadata = Get-JsonProperty -Object $threadStartResult -Name 'thread' -Default $null
        $threadId = [string](Get-JsonProperty -Object $threadMetadata -Name 'id' -Default '')
        $threadSessionId = [string](Get-JsonProperty -Object $threadMetadata -Name 'sessionId' -Default '')
        if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'Codex app-server thread/start returned no thread id.' }
        $instructionSourcesObserved = Test-JsonProperty -Object $threadStartResult -Name 'instructionSources'
        if ($instructionSourcesObserved) { $instructionSources = @(Get-JsonProperty -Object $threadStartResult -Name 'instructionSources' -Default @()) }

        for ($scriptedTurnIndex = 0; $scriptedTurnIndex -lt $requestedInteractionTurns.Count; $scriptedTurnIndex++) {
        $turnCompleted = $false
        $finalText = $null
        $latestUsage = $null
        $terminalTurn = $null
        $turnStartedUtc = [DateTime]::UtcNow
        $turnRequest = 3 + $scriptedTurnIndex
        $promptText = Get-InteractionTurnText -Turn $requestedInteractionTurns[$scriptedTurnIndex] -RunData $Inputs.Run
        $turnStartParams = [ordered]@{
            threadId = $threadId
            input = @([ordered]@{ type = 'text'; text = $promptText })
            cwd = $Inputs.Run.WorkingDirectoryPath
            model = $Inputs.Profile.Model
            effort = $Inputs.Profile.ReasoningEffort
            approvalPolicy = 'never'
            sandboxPolicy = [ordered]@{
                type = 'workspaceWrite'
                writableRoots = @($Inputs.Run.WorkingDirectoryPath)
                networkAccess = $true
            }
        }
        $turnStartRequest = [ordered]@{ jsonrpc = '2.0'; id = $turnRequest; method = 'turn/start'; params = $turnStartParams }
        $turnStartRequests.Add($turnStartRequest)
        & $writeMessage $turnStartRequest
        $turnStartResponse = & $waitForResponse $turnRequest 'turn/start'
        $turnStartResponses.Add($turnStartResponse)
        $turnStartResult = Get-JsonProperty -Object $turnStartResponse -Name 'result' -Default $null
        $turnId = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $turnStartResult -Name 'turn' -Default $null) -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($turnId)) { throw 'Codex app-server turn/start returned no turn id.' }

        while (-not $turnCompleted) {
            $message = & $readMessage
            $messageId = Get-JsonProperty -Object $message -Name 'id' -Default $null
            $method = [string](Get-JsonProperty -Object $message -Name 'method' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($method) -and $null -ne $messageId) {
                throw "Codex app-server requested unsupported interactive method '$method'."
            }
            switch ($method) {
                'thread/started' {
                    $normalized.Add(([ordered]@{ type = 'thread.started'; thread_id = Get-JsonProperty -Object (Get-JsonProperty -Object $message.params -Name 'thread' -Default $null) -Name 'id' -Default $null } | ConvertTo-Json -Compress))
                }
                'model/rerouted' {
                    & $recordModelReroute $message
                }
                'item/completed' {
                    $item = $message.params.item
                    $itemType = [string]$item.type
                    $normalizedType = switch ($itemType) {
                        'agentMessage' { 'agent_message' }
                        'commandExecution' { 'command_execution' }
                        'fileChange' { 'file_change' }
                        'mcpToolCall' { 'mcp_tool_call' }
                        default { $itemType }
                    }
                    $normalizedItem = [ordered]@{ type = $normalizedType; id = Get-JsonProperty -Object $item -Name 'id' -Default $null }
                    if ($itemType -eq 'agentMessage') {
                        $normalizedItem.text = [string]$item.text
                        $finalText = [string]$item.text
                    } elseif ($itemType -eq 'commandExecution') {
                        $normalizedItem.command = Get-JsonProperty -Object $item -Name 'command' -Default $null
                        $normalizedItem.exit_code = Get-JsonProperty -Object $item -Name 'exitCode' -Default $null
                        $normalizedItem.aggregated_output = Get-JsonProperty -Object $item -Name 'aggregatedOutput' -Default $null
                    } elseif ($itemType -eq 'fileChange') {
                        $normalizedItem.changes = Get-JsonProperty -Object $item -Name 'changes' -Default @()
                    } else {
                        $normalizedItem.raw = $item
                    }
                    $normalized.Add(([ordered]@{ type = 'item.completed'; item = $normalizedItem } | ConvertTo-Json -Depth 40 -Compress))
                }
                'thread/tokenUsage/updated' {
                    $latestUsage = Get-JsonProperty -Object (Get-JsonProperty -Object $message.params -Name 'tokenUsage' -Default $null) -Name 'last' -Default $null
                }
                'turn/completed' {
                    $completionParams = Get-JsonProperty -Object $message -Name 'params' -Default ([ordered]@{})
                    $terminalTurn = Get-JsonProperty -Object $completionParams -Name 'turn' -Default $null
                    $completionThreadId = [string](Get-JsonProperty -Object $completionParams -Name 'threadId' -Default '')
                    $completedTurnId = [string](Get-JsonProperty -Object $terminalTurn -Name 'id' -Default '')
                    if ($completionThreadId -ne $threadId -or $completedTurnId -ne $turnId) {
                        throw 'Codex app-server turn/completed identified an unexpected thread or turn.'
                    }
                    if ([string]::IsNullOrWhiteSpace($finalText)) {
                        $turnItems = @($terminalTurn.items)
                        for ($itemIndex = $turnItems.Count - 1; $itemIndex -ge 0; $itemIndex--) {
                            if ([string]$turnItems[$itemIndex].type -eq 'agentMessage' -and -not [string]::IsNullOrWhiteSpace([string]$turnItems[$itemIndex].text)) {
                                $finalText = [string]$turnItems[$itemIndex].text
                                break
                            }
                        }
                    }
                    if ([string]$terminalTurn.status -eq 'failed') {
                        $errorMessage = [string](Get-JsonProperty -Object $terminalTurn.error -Name 'message' -Default 'Codex turn failed.')
                        $normalized.Add(([ordered]@{ type = 'turn.failed'; error = $errorMessage } | ConvertTo-Json -Compress))
                    } elseif ([string]$terminalTurn.status -eq 'interrupted') {
                        $normalized.Add(([ordered]@{ type = 'turn.failed'; error = 'Codex turn was interrupted.' } | ConvertTo-Json -Compress))
                    } else {
                        $usage = $null
                        if ($null -ne $latestUsage) {
                            $usage = [ordered]@{
                                input_tokens = Get-JsonProperty -Object $latestUsage -Name 'inputTokens' -Default $null
                                cached_input_tokens = Get-JsonProperty -Object $latestUsage -Name 'cachedInputTokens' -Default $null
                                output_tokens = Get-JsonProperty -Object $latestUsage -Name 'outputTokens' -Default $null
                                reasoning_output_tokens = Get-JsonProperty -Object $latestUsage -Name 'reasoningOutputTokens' -Default $null
                            }
                        }
                        $normalized.Add(([ordered]@{ type = 'turn.completed'; usage = $usage } | ConvertTo-Json -Depth 20 -Compress))
                    }
                    $turnCompleted = $true
                }
                'error' {
                    $errorMessage = [string](Get-JsonProperty -Object $message.params -Name 'message' -Default 'Codex app-server emitted an error.')
                    throw $errorMessage
                }
            }
        }

        $turnRecords.Add([ordered]@{ sequence = ($scriptedTurnIndex * 2) + 1; role = 'user'; content_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($promptText)); session_id = $threadId; timestamp_utc = Format-UtcTimestamp -Value $turnStartedUtc })
        $turnRecords.Add([ordered]@{ sequence = ($scriptedTurnIndex * 2) + 2; role = 'assistant'; text = if ($null -eq $finalText) { '' } else { [string]$finalText }; session_id = $threadId; timestamp_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow) })
        if (-not $turnCompleted -or [string](Get-JsonProperty -Object $terminalTurn -Name 'status' -Default '') -ne 'completed') {
            $allTurnsCompleted = $false
            break
        }
        }

        # The installed schema exposes thread/read after completion. Use it as
        # a second observation of ephemeral identity, cwd, and session metadata
        # when the server provides the response; never reconstruct it locally.
        $threadReadRequest = 3 + $requestedInteractionTurns.Count + 1
        & $writeMessage ([ordered]@{ jsonrpc = '2.0'; id = $threadReadRequest; method = 'thread/read'; params = [ordered]@{ threadId = $threadId; includeTurns = $true } })
        try {
            $threadReadResponse = & $waitForResponse $threadReadRequest 'thread/read'
        } catch {
            $threadReadFailure = $_.Exception.Message
            $normalized.Add(([ordered]@{ type = 'thread.read.unavailable'; message = $threadReadFailure } | ConvertTo-Json -Compress))
        }
    } catch [TimeoutException] {
        $timedOut = $true
    } catch {
        $transportFailure = $_.Exception.Message
        $normalized.Add(([ordered]@{ type = 'error'; message = $transportFailure } | ConvertTo-Json -Compress))
    } finally {
        if ($null -ne $writer) { try { $writer.Close() } catch { } }
        if ($processStarted) {
            try {
                if (-not $process.HasExited -and -not $process.WaitForExit(2000)) {
                    $process.Kill($true)
                    $process.WaitForExit()
                }
                if ($process.HasExited) { $actualExitCode = $process.ExitCode }
            } catch { }
        }
        if ($null -ne $stderrTask) {
            try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = $_.Exception.Message }
        }
        $process.Dispose()
        if ($null -ne $authHome -and (Test-Path -LiteralPath $authHome.Path)) {
            Remove-Item -LiteralPath $authHome.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        $authOnlyHomeRemoved = $null -eq $authHome -or -not (Test-Path -LiteralPath $authHome.Path)
    }

    $finish = [DateTime]::UtcNow
    $exitCode = if ($timedOut) { $null } elseif ($turnCompleted -and $null -eq $transportFailure) { 0 } elseif ($null -ne $actualExitCode -and $actualExitCode -ne 0) { $actualExitCode } else { 1 }
    return [pscustomobject]@{
        Stdout = [string]::Join("`n", $normalized)
        RawStdout = [string]::Join("`n", $events)
        Stderr = $stderr
        ExitCode = $exitCode
        TimedOut = $timedOut
        StartedUtc = $start
        FinishedUtc = $finish
        DurationSeconds = [Math]::Round(($finish - $start).TotalSeconds, 3)
        FinalText = $finalText
        ThreadId = $threadId
        ThreadSessionId = $threadSessionId
        TurnId = $turnId
        TurnCompleted = $allTurnsCompleted
        LastTurnCompleted = $turnCompleted
        TerminalTurn = $terminalTurn
        ThreadStartRequest = $threadStartRequest
        ThreadStartResponse = $threadStartResponse
        TurnStartRequest = $turnStartRequest
        TurnStartResponse = $turnStartResponse
        TurnStartRequests = @($turnStartRequests.ToArray())
        TurnStartResponses = @($turnStartResponses.ToArray())
        TurnRecords = @($turnRecords.ToArray())
        RequestedTurnCount = $requestedInteractionTurns.Count
        AllTurnsCompleted = $allTurnsCompleted
        ThreadReadResponse = $threadReadResponse
        ThreadReadFailure = $threadReadFailure
        InstructionSources = @($instructionSources)
        InstructionSourcesObserved = $instructionSourcesObserved
        ModelReroutes = @($modelReroutes.ToArray())
        PromptInputSha256 = if ($turnStartRequests.Count -gt 0) { Get-Sha256HexFromBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes([string]$turnStartRequests[0].params.input[0].text)) } else { $null }
        ObservedModel = if ($null -ne $threadStartResponse) { [string](Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null) -Name 'model' -Default '') } else { '' }
        ObservedWorkingDirectory = if ($null -ne $threadStartResponse) { [string](Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null) -Name 'cwd' -Default '') } else { '' }
        ObservedEphemeral = if ($null -ne $threadStartResponse) { [bool](Get-JsonProperty -Object (Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null) -Name 'thread' -Default $null) -Name 'ephemeral' -Default $false) } else { $false }
        AuthOnlyHome = $null -ne $authHome -and [bool]$authHome.AuthOnly
        AuthOnlyHomeRemoved = $authOnlyHomeRemoved
        WorkerHome = if ($null -ne $parentEnvironment) { [string]$parentEnvironment.HOME } else { '' }
        TransportFailure = $transportFailure
    }
}

function Get-CodexHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [string[]]$Arguments = @('--ask-for-approval', 'never', 'exec', '--help')
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    return Invoke-CodexCli -CommandInfo $CommandInfo -Arguments $Arguments -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
}

function Get-CodexSchemaProperty {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($null -eq $Schema) { return $null }
    return Get-JsonProperty -Object (Get-JsonProperty -Object $Schema -Name 'properties' -Default $null) -Name $PropertyName -Default $null
}

function Get-CodexSchemaReference {
    param([AllowNull()][object]$Schema)

    $direct = [string](Get-JsonProperty -Object $Schema -Name '$ref' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return $direct }
    foreach ($alternative in @(Get-JsonProperty -Object $Schema -Name 'anyOf' -Default @())) {
        $reference = [string](Get-JsonProperty -Object $alternative -Name '$ref' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($reference)) { return $reference }
    }
    foreach ($alternative in @(Get-JsonProperty -Object $Schema -Name 'allOf' -Default @())) {
        $reference = [string](Get-JsonProperty -Object $alternative -Name '$ref' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($reference)) { return $reference }
    }
    return ''
}

function Test-CodexSchemaRequiredProperty {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory = $true)][string]$SchemaName
    )

    if ($null -eq $Schema) {
        [void]$Errors.Add("$SchemaName schema is missing.")
        return $null
    }
    $property = Get-CodexSchemaProperty -Schema $Schema -PropertyName $PropertyName
    if ($null -eq $property) {
        [void]$Errors.Add("$SchemaName.properties.$PropertyName is missing.")
        return $null
    }
    $required = @(Get-JsonProperty -Object $Schema -Name 'required' -Default @()) | ForEach-Object { [string]$_ }
    if ($required -notcontains $PropertyName) {
        [void]$Errors.Add("$SchemaName.required does not contain '$PropertyName'.")
    }
    return $property
}

function Get-CodexSchemaDefinition {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$DefinitionName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory = $true)][string]$SchemaName,
        [AllowNull()][object]$Definitions = $null
    )

    if ($null -ne $Definitions) {
        $definitions = $Definitions
    } elseif ($null -ne $Schema) {
        $definitions = Get-JsonProperty -Object $Schema -Name 'definitions' -Default $null
    } else {
        $definitions = $null
    }
    $definition = Get-JsonProperty -Object $definitions -Name $DefinitionName -Default $null
    if ($null -eq $definition) { [void]$Errors.Add("$SchemaName.definitions.$DefinitionName is missing.") }
    return $definition
}

function Get-CodexSchemaTypeNames {
    param([AllowNull()][object]$Schema)

    $type = Get-JsonProperty -Object $Schema -Name 'type' -Default $null
    if ($null -eq $type) { return @() }
    return @($type | ForEach-Object { [string]$_ })
}

function Test-CodexSchemaType {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$TypeName
    )

    return @(Get-CodexSchemaTypeNames -Schema $Schema) -contains $TypeName
}

function Resolve-CodexSchemaSource {
    param(
        [Parameter(Mandatory = $true)][string]$SchemaDirectory,
        [Parameter(Mandatory = $true)][string[]]$RequiredNames,
        [AllowEmptyCollection()][string[]]$OptionalNames = @()
    )

    $files = @(Get-ChildItem -LiteralPath $SchemaDirectory -Recurse -File -ErrorAction Stop | Sort-Object FullName)
    $bundleCandidates = @($files | Where-Object { $_.Name -ceq 'codex_app_server_protocol.v2.schemas.json' })
    $schemaCache = @{}
    $definitions = $null
    $errors = [System.Collections.Generic.List[string]]::new()
    $missingRequired = [System.Collections.Generic.List[string]]::new()
    $missingOptional = [System.Collections.Generic.List[string]]::new()
    $sourcePath = $null
    $sourceKind = $null

    if ($bundleCandidates.Count -gt 1) {
        [void]$errors.Add("Installed Codex app-server has multiple v2 schema bundles: $([string]::Join(', ', @($bundleCandidates | ForEach-Object { $_.FullName }))).")
    } elseif ($bundleCandidates.Count -eq 1) {
        $sourcePath = [string]$bundleCandidates[0].FullName
        $sourceKind = 'aggregate_v2_bundle'
        try {
            $bundle = [System.IO.File]::ReadAllText($sourcePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
            $definitions = Get-JsonProperty -Object $bundle -Name 'definitions' -Default $null
            if ($null -eq $definitions) {
                [void]$errors.Add("Installed Codex v2 schema bundle '$sourcePath' has no definitions object.")
                foreach ($schemaName in @($RequiredNames)) { [void]$missingRequired.Add($schemaName) }
                foreach ($schemaName in @($OptionalNames)) { [void]$missingOptional.Add($schemaName) }
            } else {
                foreach ($schemaName in @($RequiredNames) + @($OptionalNames)) {
                    $definition = Get-JsonProperty -Object $definitions -Name $schemaName -Default $null
                    if ($null -eq $definition) {
                        if ($RequiredNames -contains $schemaName) { [void]$missingRequired.Add($schemaName) } else { [void]$missingOptional.Add($schemaName) }
                    } else {
                        $schemaCache[$schemaName] = $definition
                    }
                }
            }
        } catch {
            [void]$errors.Add("Installed Codex v2 schema bundle '$sourcePath' is not valid JSON: $($_.Exception.Message)")
        }
    } else {
        $sourceKind = 'recursive_individual_files'
        foreach ($schemaName in @($RequiredNames) + @($OptionalNames)) {
            $matches = @($files | Where-Object { $_.Name -ceq ("{0}.json" -f $schemaName) })
            if ($matches.Count -eq 0) {
                if ($RequiredNames -contains $schemaName) { [void]$missingRequired.Add($schemaName) } else { [void]$missingOptional.Add($schemaName) }
                continue
            }
            if ($matches.Count -gt 1) {
                [void]$errors.Add("Installed Codex app-server has multiple unambiguous schema files for '$schemaName': $([string]::Join(', ', @($matches | ForEach-Object { $_.FullName }))).")
                continue
            }
            try {
                $schemaCache[$schemaName] = [System.IO.File]::ReadAllText($matches[0].FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
                if ($null -eq $schemaCache[$schemaName]) { [void]$errors.Add("Installed app-server schema file '$($matches[0].FullName)' is empty.") }
            } catch {
                [void]$errors.Add("Installed app-server schema file '$($matches[0].FullName)' is not valid JSON: $($_.Exception.Message)")
            }
        }
    }

    if ($missingRequired.Count -gt 0) {
        $missingText = if ($missingRequired.Count -eq 1) {
            "Installed Codex app-server schema is missing required v2 schema: $($missingRequired[0])."
        } else {
            "Installed Codex app-server schemas are missing required v2 schemas: $([string]::Join(', ', @($missingRequired)))."
        }
        [void]$errors.Insert(0, $missingText)
    }
    if ($missingOptional.Count -eq 1) {
        [void]$errors.Add("Installed Codex app-server schema is missing one member of the supplemental thread/read v2 schema pair: $($missingOptional[0]).")
    }

    return [pscustomobject]@{
        Available = $errors.Count -eq 0 -and $missingRequired.Count -eq 0
        Detail = [string]::Join(' ', @($errors))
        Schemas = $schemaCache
        Definitions = $definitions
        SourcePath = $sourcePath
        SourceKind = $sourceKind
        Missing = @($missingRequired)
        SupplementalMissing = @($missingOptional)
        SupplementalAvailable = $missingOptional.Count -eq 0
    }
}

function Get-CodexNativeWorkerProbe {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    $help = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @('app-server', '--help') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
    if ($help.TimedOut -or $help.ExitCode -ne 0) {
        return [pscustomobject]@{ Available = $false; Detail = "codex app-server --help failed with exit status $($help.ExitCode)." }
    }
    $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
    if ($helpText -notmatch 'generate-json-schema') {
        return [pscustomobject]@{ Available = $false; Detail = 'The installed Codex CLI does not advertise app-server schema generation.' }
    }
    $features = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @('features', 'list') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
    if ($features.TimedOut -or $features.ExitCode -ne 0 -or ([string]::Join("`n", @($features.Stdout, $features.Stderr)) -notmatch '(?im)multi_agent\s+stable\s+true')) {
        return [pscustomobject]@{ Available = $false; Detail = 'The installed Codex CLI did not report the stable multi_agent feature required for native child workers.' }
    }

    $schemaRelativeDirectory = Join-Path ([System.IO.Path]::GetRelativePath($Inputs.Run.WorkingDirectoryPath, $Inputs.Run.HomeDirectoryPath)) 'evidence/codex-app-server-schema'
    $schemaDirectory = [System.IO.Path]::GetFullPath((Join-Path $Inputs.Run.WorkingDirectoryPath $schemaRelativeDirectory))
    New-Item -ItemType Directory -Path $schemaDirectory -Force | Out-Null
    $schemaProcess = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @('app-server', 'generate-json-schema', "--out=$schemaRelativeDirectory") -Inputs $Inputs -Environment $environment -TimeoutSeconds 60
    if ($schemaProcess.TimedOut -or $schemaProcess.ExitCode -ne 0) {
        return [pscustomobject]@{ Available = $false; Detail = "Codex app-server schema generation failed with exit status $($schemaProcess.ExitCode): $([string]::Join(' ', @($schemaProcess.Stdout, $schemaProcess.Stderr)))." }
    }
    $requiredSchemaNames = @('ThreadStartParams', 'ThreadStartResponse', 'TurnStartParams', 'TurnStartResponse', 'ModelReroutedNotification')
    $supplementalSchemaNames = @('ThreadReadParams', 'ThreadReadResponse')
    $schemaResolution = Resolve-CodexSchemaSource -SchemaDirectory $schemaDirectory -RequiredNames $requiredSchemaNames -OptionalNames $supplementalSchemaNames
    if (-not $schemaResolution.Available) {
        return [pscustomobject]@{
            Available = $false
            Detail = [string]$schemaResolution.Detail
            SupportsProviderModelFallback = $false
            SchemaDirectory = $schemaDirectory
            SchemaSource = [string]$schemaResolution.SourcePath
            SchemaSourceKind = [string]$schemaResolution.SourceKind
            MissingSchemas = @($schemaResolution.Missing)
            SupplementalMissingSchemas = @($schemaResolution.SupplementalMissing)
        }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $schemaCache = $schemaResolution.Schemas
    $schemaDefinitions = $schemaResolution.Definitions
    $missingResolved = @($requiredSchemaNames | Where-Object { $null -eq (Get-JsonProperty -Object $schemaCache -Name $_ -Default $null) })
    if ($missingResolved.Count -gt 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = if ($missingResolved.Count -eq 1) { "Installed Codex app-server schema is missing required v2 schema: $($missingResolved[0])." } else { "Installed Codex app-server schemas are missing required v2 schemas: $([string]::Join(', ', @($missingResolved)))." }
            SupportsProviderModelFallback = $false
            SchemaDirectory = $schemaDirectory
            SchemaSource = [string]$schemaResolution.SourcePath
            SchemaSourceKind = [string]$schemaResolution.SourceKind
            MissingSchemas = @($missingResolved)
            SupplementalMissingSchemas = @($schemaResolution.SupplementalMissing)
        }
    }

    $threadStartParams = $schemaCache['ThreadStartParams']
    $threadStartResponse = $schemaCache['ThreadStartResponse']
    $turnStartParams = $schemaCache['TurnStartParams']
    $turnStartResponse = $schemaCache['TurnStartResponse']
    $threadReadParams = $schemaCache['ThreadReadParams']
    $threadReadResponse = $schemaCache['ThreadReadResponse']
    $modelRerouted = $schemaCache['ModelReroutedNotification']
    $threadReadSchemaAvailable = [bool]$schemaResolution.SupplementalAvailable

    foreach ($field in @('model', 'cwd', 'approvalPolicy', 'sandbox', 'ephemeral')) {
        if ($null -eq (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName $field)) { [void]$errors.Add("ThreadStartParams.properties.$field is missing.") }
    }
    foreach ($field in @('model', 'cwd')) {
        if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName $field) -TypeName 'string')) { [void]$errors.Add("ThreadStartParams.properties.$field must include type string.") }
    }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'ephemeral') -TypeName 'boolean')) { [void]$errors.Add('ThreadStartParams.properties.ephemeral must include type boolean.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'approvalPolicy')) -ne '#/definitions/AskForApproval') { [void]$errors.Add('ThreadStartParams.approvalPolicy must reference definitions.AskForApproval.') }
    $sandboxProperty = Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'sandbox'
    $sandboxReference = Get-CodexSchemaReference -Schema $sandboxProperty
    $sandboxDefinition = if ($sandboxReference -eq '#/definitions/SandboxMode') { Get-CodexSchemaDefinition -Schema $threadStartParams -DefinitionName 'SandboxMode' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'ThreadStartParams' } else { $null }
    if ($sandboxReference -ne '#/definitions/SandboxMode' -or $null -eq $sandboxDefinition) { [void]$errors.Add('ThreadStartParams.sandbox must reference definitions.SandboxMode.') }
    $sandboxEnum = @((Get-JsonProperty -Object $sandboxDefinition -Name 'enum' -Default @()) | ForEach-Object { [string]$_ })
    $requiredSandboxModes = @('read-only', 'workspace-write', 'danger-full-access')
    foreach ($mode in $requiredSandboxModes) {
        if ($sandboxEnum -notcontains $mode) { [void]$errors.Add("ThreadStartParams.definitions.SandboxMode.enum is missing '$mode'.") }
    }
    $fallbackProperty = Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'allowProviderModelFallback'
    $supportsProviderModelFallback = $null -ne $fallbackProperty
    if ($supportsProviderModelFallback -and -not (Test-CodexSchemaType -Schema $fallbackProperty -TypeName 'boolean')) {
        [void]$errors.Add('ThreadStartParams.allowProviderModelFallback must include type boolean when installed.')
    }

    foreach ($field in @('model', 'cwd', 'thread')) { [void](Test-CodexSchemaRequiredProperty -Schema $threadStartResponse -PropertyName $field -Errors $errors -SchemaName 'ThreadStartResponse') }
    $instructionSourcesProperty = Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'instructionSources'
    if ($null -eq $instructionSourcesProperty) {
        [void]$errors.Add('ThreadStartResponse.properties.instructionSources is missing.')
    } elseif (-not (Test-CodexSchemaType -Schema $instructionSourcesProperty -TypeName 'array')) {
        [void]$errors.Add('ThreadStartResponse.instructionSources must be an array when present.')
    } elseif ((Get-CodexSchemaReference -Schema (Get-JsonProperty -Object $instructionSourcesProperty -Name 'items' -Default $null)) -ne '#/definitions/LegacyAppPathString') {
        [void]$errors.Add('ThreadStartResponse.instructionSources.items must reference definitions.LegacyAppPathString.')
    }
    $threadReference = Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'thread')
    if ($threadReference -ne '#/definitions/Thread') { [void]$errors.Add('ThreadStartResponse.thread must reference definitions.Thread.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'model') -TypeName 'string')) { [void]$errors.Add('ThreadStartResponse.model must include type string.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'cwd')) -ne '#/definitions/AbsolutePathBuf') { [void]$errors.Add('ThreadStartResponse.cwd must reference definitions.AbsolutePathBuf.') }
    $threadDefinition = Get-CodexSchemaDefinition -Schema $threadStartResponse -DefinitionName 'Thread' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'ThreadStartResponse'
    foreach ($field in @('id', 'cwd', 'ephemeral', 'sessionId')) { [void](Test-CodexSchemaRequiredProperty -Schema $threadDefinition -PropertyName $field -Errors $errors -SchemaName 'ThreadStartResponse.definitions.Thread') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'id') -TypeName 'string')) { [void]$errors.Add('ThreadStartResponse.definitions.Thread.id must include type string.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'cwd')) -ne '#/definitions/AbsolutePathBuf') { [void]$errors.Add('ThreadStartResponse.definitions.Thread.cwd must reference definitions.AbsolutePathBuf.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'ephemeral') -TypeName 'boolean')) { [void]$errors.Add('ThreadStartResponse.definitions.Thread.ephemeral must include type boolean.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'sessionId') -TypeName 'string')) { [void]$errors.Add('ThreadStartResponse.definitions.Thread.sessionId must include type string.') }

    foreach ($field in @('input', 'threadId')) { [void](Test-CodexSchemaRequiredProperty -Schema $turnStartParams -PropertyName $field -Errors $errors -SchemaName 'TurnStartParams') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName 'input') -TypeName 'array')) { [void]$errors.Add('TurnStartParams.input must be an array.') }
    if ((Get-CodexSchemaReference -Schema (Get-JsonProperty -Object (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName 'input') -Name 'items' -Default $null)) -ne '#/definitions/UserInput') { [void]$errors.Add('TurnStartParams.input.items must reference definitions.UserInput.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName 'threadId') -TypeName 'string')) { [void]$errors.Add('TurnStartParams.threadId must include type string.') }
    foreach ($field in @('cwd', 'model')) {
        if ($null -eq (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field)) { [void]$errors.Add("TurnStartParams.properties.$field is missing.") }
        elseif (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field) -TypeName 'string')) { [void]$errors.Add("TurnStartParams.properties.$field must include type string.") }
    }
    foreach ($field in @(
        [pscustomobject]@{ Name = 'effort'; Reference = '#/definitions/ReasoningEffort' }
        [pscustomobject]@{ Name = 'approvalPolicy'; Reference = '#/definitions/AskForApproval' }
        [pscustomobject]@{ Name = 'sandboxPolicy'; Reference = '#/definitions/SandboxPolicy' }
    )) {
        if ($null -eq (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field.Name)) { [void]$errors.Add("TurnStartParams.properties.$($field.Name) is missing.") }
        elseif ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field.Name)) -ne $field.Reference) { [void]$errors.Add("TurnStartParams.$($field.Name) must reference $($field.Reference.Replace('#/definitions/', 'definitions.')).") }
    }
    $sandboxPolicyDefinition = Get-CodexSchemaDefinition -Schema $turnStartParams -DefinitionName 'SandboxPolicy' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'TurnStartParams'
    $workspaceWritePolicy = @((Get-JsonProperty -Object $sandboxPolicyDefinition -Name 'oneOf' -Default @()) | Where-Object {
        $typeProperty = Get-JsonProperty -Object (Get-JsonProperty -Object $_ -Name 'properties' -Default $null) -Name 'type' -Default $null
        @((Get-JsonProperty -Object $typeProperty -Name 'enum' -Default @())) -contains 'workspaceWrite'
    }) | Select-Object -First 1
    if ($null -eq $workspaceWritePolicy) {
        [void]$errors.Add('TurnStartParams.definitions.SandboxPolicy must advertise the workspaceWrite policy used by the runner.')
    } else {
        $writableRoots = Get-JsonProperty -Object (Get-JsonProperty -Object $workspaceWritePolicy -Name 'properties' -Default $null) -Name 'writableRoots' -Default $null
        $networkAccess = Get-JsonProperty -Object (Get-JsonProperty -Object $workspaceWritePolicy -Name 'properties' -Default $null) -Name 'networkAccess' -Default $null
        if ($null -eq $writableRoots -or -not (Test-CodexSchemaType -Schema $writableRoots -TypeName 'array')) { [void]$errors.Add('TurnStartParams.definitions.SandboxPolicy.workspaceWrite.writableRoots must be an array.') }
        if ($null -eq $networkAccess -or -not (Test-CodexSchemaType -Schema $networkAccess -TypeName 'boolean')) { [void]$errors.Add('TurnStartParams.definitions.SandboxPolicy.workspaceWrite.networkAccess must be boolean.') }
    }
    $turnProperty = Test-CodexSchemaRequiredProperty -Schema $turnStartResponse -PropertyName 'turn' -Errors $errors -SchemaName 'TurnStartResponse'
    $turnReference = Get-CodexSchemaReference -Schema $turnProperty
    if ($turnReference -ne '#/definitions/Turn') { [void]$errors.Add('TurnStartResponse.turn must reference definitions.Turn.') }
    $turnDefinition = Get-CodexSchemaDefinition -Schema $turnStartResponse -DefinitionName 'Turn' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'TurnStartResponse'
    foreach ($field in @('id', 'items', 'status')) { [void](Test-CodexSchemaRequiredProperty -Schema $turnDefinition -PropertyName $field -Errors $errors -SchemaName 'TurnStartResponse.definitions.Turn') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnDefinition -PropertyName 'id') -TypeName 'string')) { [void]$errors.Add('TurnStartResponse.definitions.Turn.id must include type string.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnDefinition -PropertyName 'items') -TypeName 'array')) { [void]$errors.Add('TurnStartResponse.definitions.Turn.items must include type array.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $turnDefinition -PropertyName 'status')) -ne '#/definitions/TurnStatus') { [void]$errors.Add('TurnStartResponse.definitions.Turn.status must reference definitions.TurnStatus.') }

    if ($threadReadSchemaAvailable) {
        [void](Test-CodexSchemaRequiredProperty -Schema $threadReadParams -PropertyName 'threadId' -Errors $errors -SchemaName 'ThreadReadParams')
        if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadReadParams -PropertyName 'threadId') -TypeName 'string')) { [void]$errors.Add('ThreadReadParams.threadId must include type string.') }
        $includeTurnsProperty = Get-CodexSchemaProperty -Schema $threadReadParams -PropertyName 'includeTurns'
        if ($null -eq $includeTurnsProperty -or -not (Test-CodexSchemaType -Schema $includeTurnsProperty -TypeName 'boolean')) { [void]$errors.Add('ThreadReadParams.includeTurns must be an optional boolean.') }
        $threadReadProperty = Test-CodexSchemaRequiredProperty -Schema $threadReadResponse -PropertyName 'thread' -Errors $errors -SchemaName 'ThreadReadResponse'
        if ((Get-CodexSchemaReference -Schema $threadReadProperty) -ne '#/definitions/Thread') { [void]$errors.Add('ThreadReadResponse.thread must reference definitions.Thread.') }
    }
    foreach ($field in @('threadId', 'turnId', 'fromModel', 'toModel', 'reason')) { [void](Test-CodexSchemaRequiredProperty -Schema $modelRerouted -PropertyName $field -Errors $errors -SchemaName 'ModelReroutedNotification') }
    foreach ($field in @('threadId', 'turnId', 'fromModel', 'toModel')) {
        if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $modelRerouted -PropertyName $field) -TypeName 'string')) { [void]$errors.Add("ModelReroutedNotification.$field must include type string.") }
    }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $modelRerouted -PropertyName 'reason')) -ne '#/definitions/ModelRerouteReason') { [void]$errors.Add('ModelReroutedNotification.reason must reference definitions.ModelRerouteReason.') }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = 'Installed Codex app-server schema failed structural validation: ' + [string]::Join(' ', @($errors))
            SupportsProviderModelFallback = $supportsProviderModelFallback
            SchemaDirectory = $schemaDirectory
            SchemaSource = [string]$schemaResolution.SourcePath
            SchemaSourceKind = [string]$schemaResolution.SourceKind
            SandboxModes = @($sandboxEnum)
            ThreadReadSchemaAvailable = $threadReadSchemaAvailable
        }
    }
    $schemaDetail = if ($threadReadSchemaAvailable) {
        'Codex multi_agent is stable and the installed v2 app-server schema structurally proves the consumed thread/start, turn/start, thread/read, and model/rerouted fields.'
    } else {
        'Codex multi_agent is stable and the installed v2 app-server schema structurally proves the consumed thread/start, turn/start, and model/rerouted fields; thread/read is supplemental and not advertised.'
    }
    if ($supportsProviderModelFallback) {
        $schemaDetail += ' allowProviderModelFallback is supported and will be sent as false; reroute notifications remain fail-closed.'
    } else {
        $schemaDetail += ' allowProviderModelFallback is not exposed by the installed protocol; reroute notifications remain fail-closed.'
    }
    return [pscustomobject]@{
        Available = $true
        Detail = $schemaDetail
        SupportsProviderModelFallback = $supportsProviderModelFallback
        SchemaDirectory = $schemaDirectory
        SchemaSource = [string]$schemaResolution.SourcePath
        SchemaSourceKind = [string]$schemaResolution.SourceKind
        SandboxModes = @($sandboxEnum)
        ThreadReadSchemaAvailable = $threadReadSchemaAvailable
    }
}

function Resolve-SandboxCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Resolve-ExternalCommand -Name $Name
}

function Get-CodexDescriptor {
    $copy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $copy[$key] = $descriptor[$key] }
    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $version = 'unavailable'
    if ($null -ne $commandInfo) {
        $observation = Get-ExternalCommandVersion -CommandInfo $commandInfo
        $version = [string]$observation.Version
    }
    $copy.harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = $version }
    return $copy
}

function New-CodexCliArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][string]$LastResponsePath,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform = (Get-PlatformName)
    )

    $directoryArgument = Get-SandboxVisiblePath -HostPath $Inputs.Run.WorkingDirectoryPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $outputArgument = Get-SandboxVisiblePath -HostPath $LastResponsePath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--ask-for-approval', 'never', 'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check', '--json', '--color', 'never', '--cd', $directoryArgument, '--model', $Inputs.Profile.Model, '--sandbox', 'workspace-write', '--config', 'shell_environment_policy.inherit=none', '--output-last-message', $outputArgument)) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments.Add('-c')
        $arguments.Add("model_reasoning_effort=$($Inputs.Profile.ReasoningEffort)")
    }
    $arguments.Add('-')
    return @($arguments)
}

function Get-CodexCapabilityMap {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [bool]$HardFilesystemConfinement = $false,
        [bool]$NativeWorkerAvailable = $true,
        [string]$AuthKind = ''
    )

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $capabilities[$capabilityName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName)
    }
    $capabilities['filesystem_confinement'] = if ($HardFilesystemConfinement) { 'supported' } else { 'unsupported' }
    $capabilities['candidate_skill_exposure'] = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' }
    foreach ($name in @('native_worker_delegation', 'delegated_worker_full_capability', 'delegated_worker_model_lock', 'delegated_worker_working_directory', 'delegated_worker_result_capture', 'delegated_worker_capacity_signal')) {
        # The app-server probe proves that the native surface is available;
        # only the child terminal evidence can prove the selected controls.
        $capabilities[$name] = if ($NativeWorkerAvailable) { 'conditional' } else { 'unsupported' }
    }
    $capabilities['scripted_multi_turn_same_session'] = if ($Inputs.Run.Interaction -eq $null) {
        'conditional'
    } elseif ($AuthKind -ne 'subscription_file' -or -not $NativeWorkerAvailable) {
        'unsupported'
    } else {
        'supported'
    }
    return $capabilities
}

function Get-CodexPreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $platform = Get-PlatformName
    $sandboxName = switch ($platform) {
        'linux' { 'bwrap' }
        'macos' { 'sandbox-exec' }
        default { $null }
    }
    $sandboxInfo = if ([string]::IsNullOrWhiteSpace([string]$sandboxName)) { $null } else { Resolve-SandboxCommand -Name $sandboxName }
    $versionObservation = $null
    $nativeWorkerObservation = $null

    if ($profile.Runner -ne 'codex') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than codex.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is codex.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('Codex requires a model in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail $profile.Model))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by codex.")
    }
    if ($profile.ToolProfile -ne 'default') {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by codex.")
    }

    if ($null -eq $commandInfo) {
        $reasons.Add('The Codex CLI executable is not available on PATH.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment (New-RunnerEnvironment -Run $run) -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The Codex CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'codex --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }

            $globalHelp = Get-CodexHelpResult -CommandInfo $commandInfo -Inputs $Inputs -Arguments @('--help')
            $help = Get-CodexHelpResult -CommandInfo $commandInfo -Inputs $Inputs
            if ($globalHelp.TimedOut -or $globalHelp.ExitCode -ne 0) {
                $reasons.Add("Codex --help failed with exit status $($globalHelp.ExitCode).")
            }
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $reasons.Add("Codex --ask-for-approval never exec --help failed with exit status $($help.ExitCode).")
            } else {
                $helpText = [string]::Join("`n", @($globalHelp.Stdout, $globalHelp.Stderr, $help.Stdout, $help.Stderr))
                foreach ($flag in @('--ask-for-approval', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--json', '--output-last-message', '--sandbox', '--cd', '--model', '--config')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed Codex CLI does not advertise required flag '$flag'.")
                    }
                }
                $visiblePlatform = if ($platform -eq 'linux' -and $null -ne $sandboxInfo) { 'linux' } else { $platform }
                $constructed = New-CodexCliArguments -Inputs $Inputs -LastResponsePath (Join-Path $run.RunRoot 'evidence/codex-final.txt') -VisiblePlatform $visiblePlatform
                if (@($constructed) -contains '--approve-for-me') {
                    $reasons.Add('The constructed Codex invocation must not combine --approve-for-me with explicit --sandbox selection.')
                }
                $sandboxIndex = [Array]::IndexOf([string[]]$constructed, '--sandbox')
                $approvalIndex = [Array]::IndexOf([string[]]$constructed, '--ask-for-approval')
                $execIndex = [Array]::IndexOf([string[]]$constructed, 'exec')
                if ($approvalIndex -lt 0 -or $execIndex -lt 0 -or $approvalIndex -gt $execIndex -or $sandboxIndex -lt 0) {
                    $reasons.Add('The constructed Codex invocation must set --ask-for-approval never before exec and retain --sandbox workspace-write.')
                }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'Codex accepts the constructed noninteractive invocation: --ask-for-approval never, exec, --sandbox workspace-write, ephemeral JSON output, and isolated configuration controls.'))
                }
            }
            $nativeWorkerObservation = Get-CodexNativeWorkerProbe -CommandInfo $commandInfo -Inputs $Inputs
            if ($nativeWorkerObservation.Available) {
                $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status passed -Detail ($nativeWorkerObservation.Detail + ' This proves API readiness only; the actual child remains conditional until terminal evidence.')))
                $warnings.Add('Codex app-server native-worker controls remain conditional until terminal evidence proves the actual child model, cwd, HOME/config, fresh identity, prompt, exclusions, and terminal capture.')
            } else {
                $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status unavailable -Detail $nativeWorkerObservation.Detail))
                $reasons.Add($nativeWorkerObservation.Detail)
            }
        } catch {
            $reasons.Add("Could not inspect Codex CLI capabilities: $($_.Exception.Message)")
        }
    }

    $auth = Get-CodexAuthSource
    if ($auth.Kind -eq 'missing') {
        $reasons.Add('Neither a narrow Codex provider API-key environment variable nor subscription auth.json is available.')
    } elseif ($auth.Kind -eq 'subscription_file') {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail 'Codex app-server uses a fresh temporary auth-only CODEX_HOME containing only a copied auth.json; the source home and all ambient Codex configuration remain outside the worker.'))
    } else {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail "Authentication is available through the narrow $($auth.Name) environment variable; the child shell policy is set to inherit=none."))
    }

    if ($null -ne $run.Interaction) {
        if ($auth.Kind -ne 'subscription_file') {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The Codex API-key compatibility transport is one-shot and cannot continue the same app-server thread.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible for the Codex API-key compatibility transport; same-session scripted turns require the native app-server thread/start + repeated turn/start surface.')
        } elseif ($null -eq $nativeWorkerObservation -or -not $nativeWorkerObservation.Available) {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The installed Codex app-server schema did not prove thread/start plus repeatable turn/start on one thread.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible: model-free Codex app-server schema probing did not prove same-thread continuation before execution.')
        } else {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status passed -Detail 'Codex app-server reuses the fresh thread/start identity for every deterministic user turn and dispatches the next turn/start only after the prior turn reaches terminal state.'))
        }
    }

    if ($auth.Kind -eq 'subscription_file') {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail 'The subscription app-server transport uses a temporary auth-only home but is not wrapped by the external run-only sandbox. Codex workspace-write remains enabled for the turn.'))
        $warnings.Add('Subscription execution uses pragmatic isolation. The adapter does not claim that an external filesystem sandbox protects the app-server transport.')
    } elseif ($null -eq $sandboxName) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status not_applicable -Detail "Platform '$platform' has no configured external hard-confinement mechanism; pragmatic isolation remains available."))
        $warnings.Add("Platform '$platform' has no external hard filesystem confinement in this adapter; execution will report pragmatic isolation.")
    } elseif ($null -eq $sandboxInfo) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail "External '$sandboxName' is unavailable; pragmatic isolation remains available."))
        $warnings.Add("External '$sandboxName' was unavailable; execution will report pragmatic isolation.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $sandboxName confines Codex to the staged run and required system runtime paths; Codex sandbox=workspace-write remains enabled inside it."))
    }

    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The selected transport starts an ephemeral thread and never supplies a resume, continue, or existing session identifier.'))
    if ($auth.Kind -eq 'subscription_file') {
        $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The app-server parent receives a filtered environment plus a temporary auth-only CODEX_HOME. Child shell inheritance is disabled with shell_environment_policy.inherit=none, and the runner validates instructionSources against the staged arm root.'))
        $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "thread/start and turn/start set cwd to $($run.WorkingDirectoryPath); HOME and USERPROFILE remain staged under $($run.HomeDirectoryPath)."))
        $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only auth.json is copied into a temporary auth-only CODEX_HOME and it is removed in finally; config.toml, skills, agents, sessions, memories, plugins, MCP configuration, and AGENTS.md are not copied. This does not claim hard filesystem confinement where none is available.'))
    } else {
        $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The compatibility transport uses an isolated CODEX_HOME plus --ignore-user-config and --ignore-rules; unrelated inherited environment variables are removed.'))
        $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "--cd $($run.WorkingDirectoryPath); CODEX_HOME under $($run.HomeDirectoryPath)"))
        $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only the selected provider API-key variable is passed to Codex; auth files are not copied into the worker HOME.'))
    }

    $hardConfinement = $auth.Kind -eq 'environment' -and $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-CodexCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement -NativeWorkerAvailable ($null -ne $nativeWorkerObservation -and $nativeWorkerObservation.Available) -AuthKind $auth.Kind
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    if ($auth.Kind -eq 'subscription_file') {
        foreach ($mechanism in @('native app-server initialize + thread/start + turn/start', 'temporary auth-only subscription CODEX_HOME', 'ephemeral thread', 'thread/read after turn completion', 'instructionSources validation', 'model/rerouted fail-closed', 'approvalPolicy=never', 'sandboxPolicy=workspaceWrite', 'shell_environment_policy.inherit=none', 'filtered parent process environment', 'prompt in turn/start input')) { $mechanisms.Add($mechanism) }
        if ($null -ne $run.Interaction) { $mechanisms.Add('same-thread repeated turn/start for scripted interaction') } else { $mechanisms.Add('no session continuation') }
    } else {
        foreach ($mechanism in @('--ask-for-approval never', 'codex exec --ephemeral compatibility transport', '--ignore-user-config', '--ignore-rules', '--sandbox workspace-write', 'shell_environment_policy.inherit=none', 'isolated CODEX_HOME', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    }
    if ($hardConfinement) { $mechanisms.Add("external $sandboxName filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    $document = New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
    if ($null -ne $nativeWorkerObservation -and $nativeWorkerObservation.Available) {
        $document.protocol_observations = [ordered]@{
            schema_directory = [string]$nativeWorkerObservation.SchemaDirectory
            schema_source = [string]$nativeWorkerObservation.SchemaSource
            schema_source_kind = [string]$nativeWorkerObservation.SchemaSourceKind
            sandbox_modes = @($nativeWorkerObservation.SandboxModes)
            allow_provider_model_fallback = [bool]$nativeWorkerObservation.SupportsProviderModelFallback
            thread_read_schema_available = [bool]$nativeWorkerObservation.ThreadReadSchemaAvailable
        }
    }
    return $document
}

function New-CodexEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth
    )

    $codexHome = Join-Path $Inputs.Run.HomeDirectoryPath '.codex'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $environment = New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables @(Get-ProviderAuthenticationVariables -Provider 'openai') -Additional @{ CODEX_HOME = $codexHome }
    if ($Auth.Kind -eq 'environment') { return $environment }
    return $environment
}

function Get-LinuxCodexSandboxArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--die-with-parent', '--new-session', '--unshare-pid')) { $args.Add($argument) }
    foreach ($path in @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/lib64', '/libexec', '/etc', '/opt')) {
        if (Test-Path -LiteralPath $path) {
            $args.Add('--ro-bind'); $args.Add($path); $args.Add($path)
        }
    }
    $args.Add('--proc'); $args.Add('/proc')
    $args.Add('--dev'); $args.Add('/dev')
    $args.Add('--tmpfs'); $args.Add('/tmp')
    $args.Add('--bind'); $args.Add($Inputs.Run.RunRoot); $args.Add('/run')
    $commandSource = [string]$CommandInfo.Source
    $commandDirectory = Split-Path -Parent $commandSource
    if (-not ($commandSource.StartsWith('/usr/', [System.StringComparison]::Ordinal) -or $commandSource.StartsWith('/bin/', [System.StringComparison]::Ordinal) -or $commandSource.StartsWith('/opt/', [System.StringComparison]::Ordinal))) {
        if (Test-Path -LiteralPath $commandDirectory -PathType Container) {
            $args.Add('--ro-bind'); $args.Add($commandDirectory); $args.Add($commandDirectory)
        }
    }
    $args.Add('--chdir'); $args.Add('/run/repo')
    $insideEnvironment = [ordered]@{
        HOME = '/run/home'
        USERPROFILE = '/run/home'
        XDG_CONFIG_HOME = '/run/home/.config'
        XDG_DATA_HOME = '/run/home/.local/share'
        XDG_CACHE_HOME = '/run/home/.cache'
        TEMP = '/run/home/tmp'
        TMP = '/run/home/tmp'
        CODEX_HOME = '/run/home/.codex'
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    foreach ($authName in @(Get-ProviderAuthenticationVariables -Provider 'openai')) {
        if ($Environment.Contains($authName) -and -not [string]::IsNullOrWhiteSpace([string]$Environment[$authName])) {
            $insideEnvironment[$authName] = [string]$Environment[$authName]
        }
    }
    foreach ($key in @($insideEnvironment.Keys)) {
        $args.Add('--setenv'); $args.Add($key); $args.Add([string]$insideEnvironment[$key])
    }
    $args.Add('--')
    $args.Add($CommandInfo.FileName)
    foreach ($prefix in @($CommandInfo.Prefix)) { $args.Add($prefix) }
    return @($args)
}

function New-CodexMacosSandboxProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo
    )

    $profilePath = Join-Path $Inputs.Run.HomeDirectoryPath 'codex-sandbox.sb'
    $runRoot = $Inputs.Run.RunRoot.Replace('\', '/')
    $commandDirectory = (Split-Path -Parent ([string]$CommandInfo.Source)).Replace('\', '/')
    $readRoots = @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/libexec', '/System', '/Library', '/opt', '/private/var/db', $commandDirectory)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('(version 1)')
    $lines.Add('(deny default)')
    $lines.Add('(allow process*)')
    $lines.Add('(allow network*)')
    foreach ($root in $readRoots | Sort-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            $escapedRoot = $root.Replace('\', '/').Replace('"', '\"')
            $lines.Add(('(allow file-read* (subpath "{0}"))' -f $escapedRoot))
        }
    }
    $escapedRunRoot = $runRoot.Replace('"', '\"')
    $lines.Add(('(allow file-read* (subpath "{0}"))' -f $escapedRunRoot))
    $lines.Add(('(allow file-write* (subpath "{0}"))' -f $escapedRunRoot))
    $lines.Add('(allow file-read* (subpath "/dev"))')
    $lines.Add('(allow file-write* (subpath "/dev/null"))')
    [System.IO.File]::WriteAllText($profilePath, ([string]::Join("`n", $lines) + "`n"), [System.Text.UTF8Encoding]::new($false))
    return $profilePath
}

function Write-CodexCapture {
    param(
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $path = Join-Path $RunData.Run.RunRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    return New-ArtifactReference -Run $RunData.Run -Path $RelativePath -Scope run -MediaType (Get-MediaType -Path $RelativePath)
}

function Invoke-CodexProjectedTransport {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth,
        [Parameter(Mandatory = $true)][object]$Platform,
        [object]$SandboxInfo = $null,
        [Parameter(Mandatory = $true)][bool]$HardFilesystem,
        [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform,
        [Parameter(Mandatory = $true)][string]$LastResponseRelativePath,
        [bool]$SupportsProviderModelFallback = $false
    )

    $projection = New-CodexExecutionProjection -Inputs $Inputs
    $executionInputs = [pscustomobject]@{ Run = $projection.Run; Profile = $Inputs.Profile }
    $process = $null
    $projectedFinalResponse = $null
    try {
        $physicalLastResponsePath = Join-Path $projection.Root ($LastResponseRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $physicalLastResponsePath) -Force | Out-Null
        $environment = if ($Auth.Kind -eq 'environment') { New-CodexEnvironment -Inputs $executionInputs -Auth $Auth } else { $null }
        $arguments = New-CodexCliArguments -Inputs $executionInputs -LastResponsePath $physicalLastResponsePath -VisiblePlatform $VisiblePlatform
        if ($Auth.Kind -eq 'subscription_file') {
            $process = Invoke-CodexAppServer -CommandInfo $CommandInfo -Inputs $executionInputs -Auth $Auth -SupportsProviderModelFallback $SupportsProviderModelFallback -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
        } elseif ($Platform -eq 'linux' -and $HardFilesystem) {
            $sandboxArguments = Get-LinuxCodexSandboxArguments -Inputs $executionInputs -CommandInfo $CommandInfo -Environment $environment
            $process = Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $executionInputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
        } elseif ($Platform -eq 'macos' -and $HardFilesystem) {
            $sandboxProfile = New-CodexMacosSandboxProfile -Inputs $executionInputs -CommandInfo $CommandInfo
            $sandboxArguments = @('-f', $sandboxProfile, '--', $CommandInfo.FileName) + @($CommandInfo.Prefix) + @($arguments)
            $process = Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $executionInputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
        } else {
            $process = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments $arguments -Inputs $executionInputs -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
        }
        if (Test-Path -LiteralPath $physicalLastResponsePath -PathType Leaf) {
            $projectedFinalResponse = [System.IO.File]::ReadAllText($physicalLastResponsePath, [System.Text.UTF8Encoding]::new($false))
            $logicalLastResponsePath = Join-Path $Inputs.Run.RunRoot ($LastResponseRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $logicalLastResponsePath) -Force | Out-Null
            [System.IO.File]::WriteAllText($logicalLastResponsePath, $projectedFinalResponse, [System.Text.UTF8Encoding]::new($false))
        }
        return [pscustomobject]@{
            Process = $process
            ProjectedFinalResponse = $projectedFinalResponse
            ExecutionPaths = [ordered]@{
                projection = 'physical_temp_outside_logical_package'
                logical_run_root = [string]$Inputs.Run.RunRoot
                logical_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
                logical_home_directory = [string]$Inputs.Run.HomeDirectoryPath
                physical_run_root = [string]$projection.Root
                physical_working_directory = [string]$projection.PhysicalWorkingDirectory
                physical_home_directory = [string]$projection.PhysicalHomeDirectory
            }
            PhysicalProjectionProven = [bool]$projection.Proven
        }
    } finally {
        try { Sync-CodexProjectedRepository -Projection $projection } finally { Remove-CodexExecutionProjection -Projection $projection }
    }
}

function Invoke-CodexExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-CodexPreflight -Inputs $Inputs
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $executionDescriptor = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $executionDescriptor[$key] = $descriptor[$key] }
    $executionDescriptor.harness = $preflight.harness
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        $failureText = [string]::Join('; ', @($preflight.reasons))
        return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $failureText) -SessionId $sessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight; resume = $false }) -AttemptCount 1
    }

    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $auth = Get-CodexAuthSource
    $lastResponsePath = 'evidence/codex-final.txt'
    New-Item -ItemType Directory -Path (Join-Path $Inputs.Run.RunRoot 'evidence') -Force | Out-Null
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $auth.Kind -eq 'environment' -and $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $protocolObservations = Get-JsonProperty -Object $preflight -Name 'protocol_observations' -Default $null
    $supportsProviderModelFallback = [bool](Get-JsonProperty -Object $protocolObservations -Name 'allow_provider_model_fallback' -Default $false)
    $transport = Invoke-CodexProjectedTransport -CommandInfo $commandInfo -Inputs $Inputs -Auth $auth -Platform $platform -SandboxInfo $sandboxInfo -HardFilesystem $hardFilesystem -VisiblePlatform $visiblePlatform -LastResponseRelativePath $lastResponsePath -SupportsProviderModelFallback $supportsProviderModelFallback
    $process = $transport.Process
    $stdoutArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact)
    $artifacts.Add($stderrArtifact)
    $transcriptArtifactPath = 'evidence/codex-events.jsonl'
    if ($auth.Kind -eq 'subscription_file') {
        $rawStdoutArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-app-server-events.jsonl' -Text $process.RawStdout
        $artifacts.Add($rawStdoutArtifact)
        $transcriptArtifactPath = 'evidence/codex-app-server-events.jsonl'
    }

    $parsed = ConvertFrom-JsonLines -Text $process.Stdout
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("Codex event parse error: $parseError") }
    $finalText = if ($auth.Kind -eq 'subscription_file') { $process.FinalText } else { $transport.ProjectedFinalResponse }
    if ([string]::IsNullOrWhiteSpace($finalText) -and $null -ne $transport.ProjectedFinalResponse) { $finalText = $transport.ProjectedFinalResponse }
    $threadId = if ($auth.Kind -eq 'subscription_file') { $process.ThreadId } else { $null }
    $turnId = if ($auth.Kind -eq 'subscription_file') { $process.TurnId } else { $null }
    $turnFailure = $null
    $usage = $null
    $toolCalls = 0
    $commands = [System.Collections.Generic.List[object]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $eventCounts = @{}
    foreach ($event in @($parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $warnings.Add('Codex emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        switch ($eventType) {
            'thread.started' { $threadId = [string](Get-JsonProperty -Object $event -Name 'thread_id' -Default '') }
            'item.completed' {
                $item = Get-JsonProperty -Object $event -Name 'item' -Default $null
                $itemType = [string](Get-JsonProperty -Object $item -Name 'type' -Default '')
                if ($itemType -eq 'agent_message') {
                    $candidate = [string](Get-JsonProperty -Object $item -Name 'text' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $finalText = $candidate }
                } elseif ($itemType -in @('command_execution', 'mcp_tool_call', 'file_change')) {
                    $toolCalls++
                    if ($itemType -eq 'command_execution') {
                        $commands.Add([ordered]@{ type = $itemType; command = Get-JsonProperty -Object $item -Name 'command'; exit_code = Get-JsonProperty -Object $item -Name 'exit_code' })
                    } else {
                        $files.Add([ordered]@{ type = $itemType; item = $item })
                    }
                }
            }
            'turn.completed' {
                $usage = Get-JsonProperty -Object $event -Name 'usage' -Default $null
            }
            'turn.failed' { $turnFailure = Get-JsonProperty -Object $event -Name 'error' -Default 'Codex turn failed.' }
            'error' { $turnFailure = Get-JsonProperty -Object $event -Name 'message' -Default 'Codex emitted an error.' }
            { $_ -in @('turn.started', 'item.started', 'item.updated') } { }
            default { $warnings.Add("Unknown Codex event '$eventType' was preserved as a warning.") }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -PathType Leaf) {
        $lastArtifact = New-ArtifactReference -Run $Inputs.Run -Path $lastResponsePath -Scope run -MediaType 'text/plain; charset=utf-8'
        $artifacts.Add($lastArtifact)
        if ([string]::IsNullOrWhiteSpace($finalText)) {
            $finalText = [System.IO.File]::ReadAllText((Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)), [System.Text.UTF8Encoding]::new($false))
        }
    }
    $terminalCaptureComplete = if ($auth.Kind -eq 'subscription_file') {
        [bool]$process.TurnCompleted
    } else {
        @($parsed.Events | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'type' -Default '') -eq 'turn.completed' }).Count -gt 0
    }

    $nativeEvidenceFailures = [System.Collections.Generic.List[string]]::new()
    $observedModel = if ($auth.Kind -eq 'subscription_file') { [string]$process.ObservedModel } else { '' }
    $observedWorkingDirectory = if ($auth.Kind -eq 'subscription_file') { [string]$process.ObservedWorkingDirectory } else { '' }
    $promptFidelity = $auth.Kind -eq 'subscription_file' -and [string]$process.PromptInputSha256 -eq [string]$Inputs.Run.PromptHash
    $unexpectedInstructionSources = [System.Collections.Generic.List[string]]::new()
    $invalidInstructionSources = [System.Collections.Generic.List[string]]::new()
    $threadReadObservation = 'not_applicable'
    $instructionSourceProof = if ($auth.Kind -eq 'subscription_file') { 'physical_projection_boundary' } else { 'compatibility_transport' }
    $instructionSourcesUnobserved = $false
    $authHomeProven = $true
    $terminalTurnProven = $true
    $modelRerouteObserved = $false
    $threadReadMetadataFailure = $false
    if ($auth.Kind -eq 'subscription_file') {
        # instructionSources is an optional response observation. A missing
        # array is acceptable here because the physical projection is outside
        # the source-repository ancestor chain and is the independent proof of
        # the ambient instruction boundary. Without that proof, absence stays
        # fail-closed.
        $instructionSourcesUnobserved = -not [bool]$process.InstructionSourcesObserved -and -not [bool]$transport.PhysicalProjectionProven
        foreach ($source in @($process.InstructionSources)) {
            $sourcePath = [string]$source
            if ([string]::IsNullOrWhiteSpace($sourcePath)) {
                $invalidInstructionSources.Add($sourcePath)
            } elseif (-not (Test-PathInside -BasePath ([string]$transport.ExecutionPaths.physical_run_root) -CandidatePath $sourcePath)) {
                $unexpectedInstructionSources.Add($sourcePath)
            }
        }
        $authHomeProven = [bool]$process.AuthOnlyHome -and [bool]$process.AuthOnlyHomeRemoved
        $terminalTurnProven = [string](Get-JsonProperty -Object $process.TerminalTurn -Name 'status' -Default '') -eq 'completed'
        $modelRerouteObserved = @($process.ModelReroutes).Count -gt 0
        $threadReadThread = if ($null -ne $process.ThreadReadResponse) { Get-JsonProperty -Object (Get-JsonProperty -Object $process.ThreadReadResponse -Name 'result' -Default $null) -Name 'thread' -Default $null } else { $null }
        if ($null -ne $threadReadThread) {
            $threadReadObservation = 'observed'
            if ([string](Get-JsonProperty -Object $threadReadThread -Name 'id' -Default '') -ne [string]$process.ThreadId -or
                -not [bool](Get-JsonProperty -Object $threadReadThread -Name 'ephemeral' -Default $false) -or
                -not (Test-ExactObservedPath -Expected ([string]$transport.ExecutionPaths.physical_working_directory) -Observed ([string](Get-JsonProperty -Object $threadReadThread -Name 'cwd' -Default '')))) {
                $threadReadMetadataFailure = $true
            }
        } elseif ($null -ne $process.ThreadReadFailure -or $null -eq $process.ThreadReadResponse) {
            $threadReadObservation = 'unavailable_optional'
            $warnings.Add('Codex thread/read is supplemental and was unavailable; thread/start and turn/completed remain the mandatory terminal proof.')
        } else {
            # A response was returned but did not satisfy the installed
            # ThreadReadResponse shape. The thread/read observation is
            # supplemental, but a present response with a missing required
            # thread object is a protocol violation rather than an optional
            # absence.
            $threadReadObservation = 'malformed'
            $threadReadMetadataFailure = $true
        }
    }

    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'
        $reason = 'codex_timeout'
        $failure = New-ExecutionFailure -Code 'timed_out' -Message 'Codex did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $turnFailure) {
        $status = 'failed'
        $reason = 'codex_failure'
        $failureMessage = if ($null -ne $turnFailure) { [string]$turnFailure } elseif (-not [string]::IsNullOrWhiteSpace($process.Stderr)) { $process.Stderr.Trim() } else { "Codex exited with status $($process.ExitCode)." }
        $failure = New-ExecutionFailure -Code 'codex_failure' -Message $failureMessage
    } elseif ([string]::IsNullOrWhiteSpace($finalText)) {
        $warnings.Add('Codex exited successfully without a final agent message.')
        $reason = 'codex_did_not_return_final_response'
    }
    $tokenMetric = if ($null -eq $usage) {
        New-UnavailableMetric -Reason 'codex_did_not_expose_turn_usage'
    } else {
        $usageValue = [ordered]@{}
        foreach ($name in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
            $value = Get-JsonProperty -Object $usage -Name $name -Default $null
            if ($null -ne $value) { $usageValue[$name] = $value }
        }
        if ($usageValue.Count -eq 0) { New-UnavailableMetric -Reason 'codex_usage_event_had_no_supported_buckets' } else { New-AvailableMetric -Value $usageValue }
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = $transcriptArtifactPath; complete = $terminalCaptureComplete })
        tokens = $tokenMetric
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = New-UnavailableMetric -Reason 'codex_runner_does_not_estimate_cost'
    }
    $finished = [DateTime]::UtcNow
    $sessionResultId = if ([string]::IsNullOrWhiteSpace($threadId)) { $sessionId } else { $threadId }
    $capabilities = Get-CodexCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem -NativeWorkerAvailable ($auth.Kind -eq 'subscription_file') -AuthKind $auth.Kind
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    if ($auth.Kind -eq 'subscription_file') {
        foreach ($mechanism in @('native app-server initialize + thread/start + turn/start', 'temporary auth-only subscription CODEX_HOME', 'ephemeral thread', 'thread/read after turn completion', 'instructionSources validation', 'model/rerouted fail-closed', 'approvalPolicy=never', 'sandboxPolicy=workspaceWrite', 'shell_environment_policy.inherit=none', 'filtered parent process environment', 'prompt in turn/start input')) { $mechanisms.Add($mechanism) }
        $continuationMechanism = if ($null -ne $Inputs.Run.Interaction) { 'same-thread repeated turn/start for scripted interaction' } else { 'no session continuation' }
        $mechanisms.Add($continuationMechanism)
    } else {
        foreach ($mechanism in @('--ask-for-approval never', 'codex exec --ephemeral', '--ignore-user-config', '--ignore-rules', '--sandbox workspace-write', 'shell_environment_policy.inherit=none', 'isolated CODEX_HOME', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    }
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    if (-not $hardFilesystem) { $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $sandboxEvidence = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
    $credentialEvidence = [ordered]@{
        source = $auth.Kind
        provider_environment_variable = $auth.Name
        unrelated_environment_excluded = $true
        child_tool_visibility = 'codex_shell_environment_policy_inherit_none'
        value_observed = $false
        auth_only_home = if ($auth.Kind -eq 'subscription_file') { [bool]$process.AuthOnlyHome } else { $false }
        auth_only_home_removed = if ($auth.Kind -eq 'subscription_file') { [bool]$process.AuthOnlyHomeRemoved } else { $true }
        ambient_codex_configuration_copied = $false
    }
    $outputLastMessageArgument = if ($auth.Kind -eq 'subscription_file') { $null } else { Get-SandboxVisiblePath -HostPath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -RunRoot $Inputs.Run.RunRoot -Platform $visiblePlatform }
    $evidence = [ordered]@{
        thread_id = $threadId
        thread_session_id = if ($auth.Kind -eq 'subscription_file') { $process.ThreadSessionId } else { $null }
        turn_id = $turnId
        execution_paths = $transport.ExecutionPaths
        event_counts = $eventCounts
        commands = @($commands)
        files = @($files)
        prompt_first_input = if ($auth.Kind -eq 'subscription_file') { $promptFidelity } else { $true }
        resume = $false
        stdout_exit_code = $process.ExitCode
        sandbox = $sandboxEvidence
        output_last_message_argument = $outputLastMessageArgument
        credential = $credentialEvidence
    }
    if ($null -ne $Inputs.Run.Interaction) { $evidence.turns = @($process.TurnRecords) }
    if ($auth.Kind -eq 'subscription_file') {
        $rawArtifact = @($artifacts | Where-Object { [string]$_.path -eq $transcriptArtifactPath } | Select-Object -First 1)
        $evidence.capture = [ordered]@{
            source = 'harness_native_transport'
            terminal = [bool]$process.TurnCompleted
            worker_authored = $false
            artifact = $transcriptArtifactPath
            sha256 = if ($rawArtifact.Count -eq 1) { [string]$rawArtifact[0].sha256 } else { $null }
        }
        $evidence.delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = [string]$descriptor.delegation.mechanism
            worker_session_id = $sessionResultId
            observed_model = $observedModel
            observed_working_directory = $observedWorkingDirectory
            observed_home = [string]$process.WorkerHome
            fresh_worker = [bool]$process.ObservedEphemeral -and -not [string]::IsNullOrWhiteSpace([string]$process.ThreadId)
            home_config_isolated = [bool]$process.AuthOnlyHome -and [bool]$process.AuthOnlyHomeRemoved
            prompt_fidelity = $promptFidelity
            prompt_sha256 = $Inputs.Run.PromptHash
            terminal_result_capture = [bool]$process.TurnCompleted -and -not [string]::IsNullOrWhiteSpace([string]$process.RawStdout)
            paired_arm_visible = $false
            grading_material_visible = $false
            nested_model_execution = $false
            model_execution_count = 1
            thread_id = $threadId
            thread_session_id = $process.ThreadSessionId
            turn_id = $turnId
            instruction_sources_observed = [bool]$process.InstructionSourcesObserved
            instruction_source_proof = $instructionSourceProof
            instruction_sources = @($process.InstructionSources)
            invalid_instruction_sources = @($invalidInstructionSources.ToArray())
            unexpected_instruction_sources = @($unexpectedInstructionSources.ToArray())
            requested_runtime_workspace_roots = @($transport.ExecutionPaths.physical_working_directory)
            logical_runtime_workspace_roots = @($Inputs.Run.WorkingDirectoryPath)
            thread_read_observed = $null -ne $process.ThreadReadResponse
            thread_read_observation = $threadReadObservation
            model_reroutes = @($process.ModelReroutes)
            same_session_continuation = if ($null -ne $Inputs.Run.Interaction) { [bool]$process.AllTurnsCompleted } else { $null }
        }
        if ($null -ne $Inputs.Run.Interaction) {
            $evidence.interaction = [ordered]@{
                schema = (Get-RunnerSchemaNames).Interaction
                mode = 'scripted'
                same_session = [bool]$process.AllTurnsCompleted
                session_id = $sessionResultId
                turns = @($process.TurnRecords)
                final_response_sequence = @($process.TurnRecords).Count
                turn_start_requests = @($process.TurnStartRequests)
                turn_start_responses = @($process.TurnStartResponses)
            }
        }
        $threadStartResultEvidence = Get-JsonProperty -Object $process.ThreadStartResponse -Name 'result' -Default ([ordered]@{})
        $threadReadThreadEvidence = if ($null -ne $process.ThreadReadResponse) { Get-JsonProperty -Object (Get-JsonProperty -Object $process.ThreadReadResponse -Name 'result' -Default $null) -Name 'thread' -Default $null } else { $null }
        $turnCompletionEvidence = if ($null -ne $process.TerminalTurn) { [ordered]@{ thread_id = $process.ThreadId; turn_id = $process.TurnId; status = Get-JsonProperty -Object $process.TerminalTurn -Name 'status' -Default $null } } else { $null }
        $evidence.app_server = [ordered]@{
            thread_start_request = $process.ThreadStartRequest
            thread_start_response = $process.ThreadStartResponse
            turn_start_request = $process.TurnStartRequest
            turn_start_response = $process.TurnStartResponse
            thread_start = [ordered]@{
                requested_model = $Inputs.Profile.Model
                requested_cwd = $transport.ExecutionPaths.physical_working_directory
                requested_ephemeral = $true
                requested_sandbox = 'read-only'
                requested_allow_provider_model_fallback = if ($supportsProviderModelFallback) { $false } else { $null }
                observed_model = Get-JsonProperty -Object $threadStartResultEvidence -Name 'model' -Default $null
                observed_cwd = Get-JsonProperty -Object $threadStartResultEvidence -Name 'cwd' -Default $null
                observed_ephemeral = Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResultEvidence -Name 'thread' -Default $null) -Name 'ephemeral' -Default $null
                observed_sandbox = Get-JsonProperty -Object $threadStartResultEvidence -Name 'sandbox' -Default $null
                instruction_sources = @($process.InstructionSources)
            }
            turn_start = [ordered]@{
                thread_id = $process.ThreadId
                requested_model = $Inputs.Profile.Model
                requested_cwd = $transport.ExecutionPaths.physical_working_directory
                requested_effort = $Inputs.Profile.ReasoningEffort
                requested_sandbox_policy = Get-JsonProperty -Object (Get-JsonProperty -Object $process.TurnStartRequest -Name 'params' -Default $null) -Name 'sandboxPolicy' -Default $null
                prompt_sha256 = $process.PromptInputSha256
            }
            turn_starts = @($process.TurnStartRequests | ForEach-Object {
                [ordered]@{
                    thread_id = Get-JsonProperty -Object $_.params -Name 'threadId' -Default $null
                    requested_model = Get-JsonProperty -Object $_.params -Name 'model' -Default $null
                    requested_cwd = Get-JsonProperty -Object $_.params -Name 'cwd' -Default $null
                    prompt_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$_.params.input[0].text))
                }
            })
            terminal_turn = $turnCompletionEvidence
            thread_read = [ordered]@{
                request = [ordered]@{ threadId = $process.ThreadId; includeTurns = $true }
                response = if ($null -eq $threadReadThreadEvidence) { $null } else { [ordered]@{ id = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'id' -Default $null; session_id = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'sessionId' -Default $null; cwd = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'cwd' -Default $null; ephemeral = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'ephemeral' -Default $null } }
                failure = $process.ThreadReadFailure
                observation = $threadReadObservation
            }
            model_rerouted = @($process.ModelReroutes)
        }
    }

    if ($auth.Kind -eq 'subscription_file') {
        # Run the common portable validator over the same evidence object that
        # the Codex-specific checks use. This is the single terminal decision:
        # additional Codex failures are merged with, never hidden from, the
        # portable result and orchestration state.
        $commonPreview = [ordered]@{
            status = $status
            session = [ordered]@{ id = $sessionResultId; fresh = [bool]$process.ObservedEphemeral -and -not [string]::IsNullOrWhiteSpace([string]$process.ThreadId); resumed = $false }
            run = [ordered]@{ eval_id = $Inputs.Run.EvalId; eval_name = $Inputs.Run.EvalName; configuration = $Inputs.Run.Mode }
            requested = [ordered]@{ model = $Inputs.Profile.Model }
            runner = [ordered]@{ name = 'codex' }
            evidence = $evidence
        }
        $commonValidation = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $commonPreview -Run $Inputs.Run -RequestedModel ([string]$Inputs.Profile.Model) -ExpectedWorkerSessionId $sessionResultId -ExpectedRunner 'codex' -ExpectedMechanism ([string]$descriptor.delegation.mechanism)
        foreach ($failureName in @($commonValidation.Failures)) {
            if ($nativeEvidenceFailures -notcontains [string]$failureName) { $nativeEvidenceFailures.Add([string]$failureName) }
        }
        # These checks are genuinely Codex-specific. The portable validator
        # above owns model/cwd/home/freshness/prompt/terminal acceptance; this
        # layer contributes only app-server protocol and transport invariants.
        if ($instructionSourcesUnobserved) { $nativeEvidenceFailures.Add('instruction_sources_unobserved') }
        if ($invalidInstructionSources.Count -gt 0) { $nativeEvidenceFailures.Add('invalid_instruction_sources') }
        if ($unexpectedInstructionSources.Count -gt 0) { $nativeEvidenceFailures.Add('unexpected_instruction_sources') }
        if (-not $authHomeProven) { $nativeEvidenceFailures.Add('isolated_auth_home') }
        if (-not $terminalTurnProven) { $nativeEvidenceFailures.Add('terminal_turn_status') }
        if ($modelRerouteObserved) { $nativeEvidenceFailures.Add('model_rerouted') }
        if ($threadReadMetadataFailure) { $nativeEvidenceFailures.Add('thread_read_metadata') }
        $uniqueNativeEvidenceFailures = @($nativeEvidenceFailures | Select-Object -Unique)
        $nativeEvidenceFailures = [System.Collections.Generic.List[string]]::new()
        foreach ($failureName in $uniqueNativeEvidenceFailures) { $nativeEvidenceFailures.Add([string]$failureName) }
        if ($nativeEvidenceFailures.Count -gt 0) {
            $status = 'incompatible'
            $reason = 'codex_native_evidence_incompatible'
            $baseFailureMessage = if ($null -ne $failure) { [string]$failure.message } elseif (-not [string]::IsNullOrWhiteSpace([string]$process.TransportFailure)) { [string]$process.TransportFailure } else { 'Codex app-server terminal evidence was not accepted.' }
            $failure = New-ExecutionFailure -Code 'native_evidence_incompatible' -Message ("Codex app-server evidence failed closed: {0}. Transport detail: {1}" -f ([string]::Join(', ', @($nativeEvidenceFailures)), $baseFailureMessage))
            $exitStatus = $null
        }
        $evidence.native_worker_evidence_failures = @($nativeEvidenceFailures.ToArray())
    }
    return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionResultId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'Codex accepted the requested model and configuration but did not expose concrete backend resolution.'; observations = [ordered]@{ model = $Inputs.Profile.Model; reasoning_effort = $Inputs.Profile.ReasoningEffort } }) -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence $evidence -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-CodexDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-CodexInputs
            Write-RunnerJson -Value (Get-CodexPreflight -Inputs $inputs) -AsOutput
        }
        'execute' {
            $inputs = Resolve-CodexInputs
            [void](Assert-PhaseOneEvidenceWritable -Run $inputs.Run)
            $result = Invoke-CodexExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
