[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('describe', 'preflight', 'execute')][string]$Command,
    [string]$Run,
    [string]$Profile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\runner-common.ps1')

$descriptor = [ordered]@{
    schema = (Get-RunnerSchemaNames).Descriptor
    protocol_version = (Get-RunnerSchemaNames).Protocol
    name = 'fixture'
    version = 'test'
    platforms = @('windows')
    harness = [ordered]@{ name = 'deterministic runner-owned fixture'; version = 'test' }
    capabilities = [ordered]@{
        single_turn = 'supported'
        scripted_multi_turn_same_session = 'supported'
        fresh_context = 'supported'
        isolated_home_config = 'supported'
        isolated_working_directory = 'supported'
        filesystem_confinement = 'unsupported'
        ambient_candidate_skill_exclusion = 'supported'
        candidate_skill_exposure = 'supported'
        prompt_fidelity = 'supported'
        model_configuration_lock = 'supported'
        response_capture = 'supported'
        native_worker_delegation = 'supported'
        delegated_worker_full_capability = 'supported'
        delegated_worker_model_lock = 'supported'
        delegated_worker_working_directory = 'supported'
        delegated_worker_result_capture = 'supported'
        delegated_worker_capacity_signal = 'supported'
    }
    delegation = [ordered]@{
        dispatch_owner = 'runner'
        mode = 'native_worker'
        mechanism = 'deterministic-runner-owned-fixture'
        worker_role = 'fixture-worker'
        full_capability = 'supported'
        model_lock = 'supported'
        working_directory = 'supported'
        result_capture = 'supported'
        capacity = 'supported'
        nested_model_execution = $false
    }
    supported_telemetry = @()
    configuration_profiles = @('isolated-default')
    tool_profiles = @('default')
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    if ($Command -eq 'describe') { Write-RunnerJson -Value $descriptor -AsOutput; exit 0 }
    $inputs = [pscustomobject]@{ Run = Resolve-RunContract -RunPath $Run; Profile = Resolve-ExecutionProfile -ProfilePath $Profile }
    function Write-FixtureEvent {
        param([Parameter(Mandatory = $true)][string]$Kind)

        $logPath = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG')
        if ([string]::IsNullOrWhiteSpace($logPath)) { return }
        $mutex = [Threading.Mutex]::new($false, 'agentic-runner-owned-fixture-event-log')
        try {
            [void]$mutex.WaitOne()
            $event = [ordered]@{
                kind = $Kind
                eval_id = [int]$inputs.Run.EvalId
                eval_name = [string]$inputs.Run.EvalName
                configuration = [string]$inputs.Run.Mode
                utc = [DateTime]::UtcNow.ToString('o')
            }
            [IO.File]::AppendAllText($logPath, (($event | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        } finally {
            try { [void]$mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
    }

    function Get-FixtureTerminalStatus {
        $statusPath = Join-Path $inputs.Run.HomeDirectoryPath 'terminal-status'
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
            return 'completed'
        }

        $status = ([System.IO.File]::ReadAllText($statusPath, [Text.UTF8Encoding]::new($false))).Trim()
        if ($status -notin @('completed', 'failed', 'timed_out', 'cancelled')) {
            throw "Unsupported fixture terminal status '$status'."
        }
        return $status
    }

    function Test-FixtureEvidenceValidationFailure {
        return (Test-Path -LiteralPath (Join-Path $inputs.Run.HomeDirectoryPath 'evidence-validation-failed') -PathType Leaf)
    }

    function Get-ExtraTranscriptArtifacts {
        $markerPath = Join-Path $inputs.Run.HomeDirectoryPath 'extra-transcript-artifacts'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            return @()
        }
        return @(
            [ordered]@{
                Path = 'evidence/a/events.jsonl'
                Content = @('{"type":"assistant.terminal","content":"artifact-a exact frozen quote"}')
                MediaType = 'application/x-ndjson; charset=utf-8'
            }
            [ordered]@{
                Path = 'evidence/b/events.jsonl'
                Content = @('{"type":"assistant.terminal","content":"artifact-b exact frozen quote"}')
                MediaType = 'application/x-ndjson; charset=utf-8'
            }
            [ordered]@{
                Path = 'evidence/logs/transcript.txt'
                Content = @('alpha frozen transcript line', 'beta frozen transcript line')
                MediaType = 'text/plain; charset=utf-8'
            }
        )
    }

    if ($Command -eq 'preflight') {
        Write-FixtureEvent -Kind 'preflight'
        if (Test-Path -LiteralPath (Join-Path $inputs.Run.HomeDirectoryPath 'preflight-incompatible') -PathType Leaf) {
            $preflightCapabilities = [ordered]@{}
            foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) { $preflightCapabilities[$capabilityName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName) }
            $preflightReason = "fixture preflight rejected $($inputs.Run.EvalName)/$($inputs.Run.Mode)"
            if ($null -ne $inputs.Run.Interaction) {
                $preflightCapabilities.scripted_multi_turn_same_session = 'unsupported'
                $preflightReason += ': scripted interaction capability unsupported'
            }
            Write-RunnerJson -Value (New-PreflightDocument -Descriptor $descriptor -Profile $inputs.Profile -Run $inputs.Run -Compatible $false -Reasons @($preflightReason) -ResolvedCapabilities $preflightCapabilities -Mechanisms @('deterministic fixture')) -AsOutput
            exit 0
        }
        Write-RunnerJson -Value (New-PreflightDocument -Descriptor $descriptor -Profile $inputs.Profile -Run $inputs.Run -Compatible $true -ResolvedCapabilities $descriptor.capabilities -Mechanisms @('deterministic fixture')) -AsOutput
        exit 0
    }
    # Refuse a second execution before any transport event or raw artifact can
    # be created after Phase 1 has been frozen.
    [void](Assert-PhaseOneEvidenceWritable -Run $inputs.Run)
    $executeStartUtc = [DateTime]::UtcNow
    Write-FixtureEvent -Kind 'execute'
    # An optional per-run marker lets a test make one arm deliberately slow so
    # the fan-out's capacity refill can be observed: a fast sibling must free its
    # slot and let the next pending arm start without waiting for the slow arm.
    $delayMs = 250
    $delayMarker = Join-Path $inputs.Run.HomeDirectoryPath 'execute-delay-ms'
    if (Test-Path -LiteralPath $delayMarker -PathType Leaf) {
        $parsedDelay = 0
        if ([int]::TryParse((([System.IO.File]::ReadAllText($delayMarker, [Text.UTF8Encoding]::new($false))).Trim()), [ref]$parsedDelay) -and $parsedDelay -ge 0) { $delayMs = $parsedDelay }
    }
    Start-Sleep -Milliseconds $delayMs
    $executeFinishUtc = [DateTime]::UtcNow
    $capabilities = [ordered]@{}
    foreach ($propertyName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) { $capabilities[$propertyName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $propertyName) }
    if ([string]$inputs.Run.Mode -eq 'without_skill') { $capabilities.candidate_skill_exposure = 'excluded' }
    $sessionId = ('fixture-session-' + [Guid]::NewGuid().ToString('N'))
    $terminalStatus = Get-FixtureTerminalStatus
    $turnRecords = [System.Collections.Generic.List[object]]::new()
    $fixtureFinalResponse = 'deterministic fixture response'
    if ($null -ne $inputs.Run.Interaction) {
        $requestedTurns = @($inputs.Run.Interaction.turns)
        for ($turnIndex = 0; $turnIndex -lt $requestedTurns.Count; $turnIndex++) {
            $turnText = Get-InteractionTurnText -Turn $requestedTurns[$turnIndex] -RunData $inputs.Run
            $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 1; role = 'user'; content_sha256 = Get-Sha256HexFromBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($turnText)); session_id = $sessionId; timestamp_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow) })
            $assistantText = if ($turnIndex -eq 0) { 'fixture confirmation required' } else { 'fixture protected operation completed after confirmation' }
            $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 2; role = 'assistant'; text = $assistantText; session_id = $sessionId; timestamp_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow) })
            $fixtureFinalResponse = $assistantText
        }
    }
    # Deterministic validation can request stable worker metrics without
    # changing the normal fixture behavior. These values are injected before
    # the Phase 1 freeze, never by grading or report code.
    $finalResponseOverride = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_FINAL_RESPONSE')
    if (-not [string]::IsNullOrWhiteSpace($finalResponseOverride)) {
        $fixtureFinalResponse = $finalResponseOverride
        if ($turnRecords.Count -gt 0) {
            $lastTurn = $turnRecords[$turnRecords.Count - 1]
            if ($lastTurn -is [System.Collections.IDictionary]) {
                $lastTurn['text'] = $finalResponseOverride
            } else {
                Add-Member -InputObject $lastTurn -MemberType NoteProperty -Name text -Value $finalResponseOverride -Force
            }
        }
    }
    $phase2BundlePath = Join-Path $inputs.Run.WorkingDirectoryPath 'input-bundle.json'
    if (Test-Path -LiteralPath $phase2BundlePath -PathType Leaf) {
        $bundle = Read-RunnerJson -Path $phase2BundlePath
        $fragmentGrades = [System.Collections.Generic.List[object]]::new()
        foreach ($assertion in @(Get-JsonProperty -Object $bundle -Name 'assertions' -Default @())) {
            $assertionIndex = [int](Get-JsonProperty -Object $assertion -Name 'assertion_index' -Default 0)
            $domain = [string](Get-JsonProperty -Object $assertion -Name 'evidence_domain' -Default 'output')
            $artifact = [string](Get-JsonProperty -Object $bundle -Name 'canonical_result' -Default '')
            $evidenceRef = $null
            if ($domain -eq 'transcript') {
                $transcripts = @(Get-JsonProperty -Object $bundle -Name 'frozen_transcripts' -Default @())
                $eventTranscript = @($transcripts | Where-Object { Test-JsonProperty -Object $_ -Name 'events' } | Select-Object -First 1)
                if ($eventTranscript.Count -eq 1) {
                    $event = @(Get-JsonProperty -Object $eventTranscript[0] -Name 'events' -Default @() | Select-Object -First 1)
                    if ($event.Count -ne 1) { throw 'Phase 2 fixture expected one frozen transcript event.' }
                    $evidenceRef = [ordered]@{
                        artifact = [string](Get-JsonProperty -Object $eventTranscript[0] -Name 'artifact' -Default '')
                        domain = 'transcript'
                        event_index = [int](Get-JsonProperty -Object $event[0] -Name 'event_index' -Default 0)
                        quote = [string](Get-JsonProperty -Object $event[0] -Name 'source_text' -Default (Get-JsonProperty -Object $event[0] -Name 'content' -Default ''))
                    }
                } else {
                    $lineTranscript = @($transcripts | Where-Object { Test-JsonProperty -Object $_ -Name 'lines' } | Select-Object -First 1)
                    if ($lineTranscript.Count -ne 1) { throw 'Phase 2 fixture expected frozen transcript evidence for transcript-domain grading.' }
                    $lines = @(Get-JsonProperty -Object $lineTranscript[0] -Name 'lines' -Default @() | Select-Object -First 2)
                    if ($lines.Count -lt 1) { throw 'Phase 2 fixture expected at least one frozen transcript line.' }
                    $quote = [string]::Join("`n", @($lines | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'text' -Default '') }))
                    $evidenceRef = [ordered]@{
                        artifact = [string](Get-JsonProperty -Object $lineTranscript[0] -Name 'artifact' -Default '')
                        domain = 'transcript'
                        start_line = [int](Get-JsonProperty -Object $lines[0] -Name 'line' -Default 1)
                        end_line = [int](Get-JsonProperty -Object $lines[$lines.Count - 1] -Name 'line' -Default 1)
                        quote = $quote
                    }
                }
            } else {
                $line = @(Get-JsonProperty -Object (Get-JsonProperty -Object $bundle -Name 'frozen_output' -Default $null) -Name 'lines' -Default @() | Select-Object -First 1)
                $lineNumber = if ($line.Count -eq 1) { [int](Get-JsonProperty -Object $line[0] -Name 'line' -Default 1) } else { 1 }
                $quote = if ($line.Count -eq 1) { [string](Get-JsonProperty -Object $line[0] -Name 'text' -Default 'deterministic fixture response') } else { 'deterministic fixture response' }
                $evidenceRef = [ordered]@{
                    artifact = $artifact
                    domain = $domain
                    start_line = $lineNumber
                    end_line = $lineNumber
                    quote = $quote
                }
            }
            $fragmentGrades.Add([ordered]@{
                assertion_index = $assertionIndex
                passed = $true
                reason = "The deterministic analyzer fixture cites frozen one-arm output for assertion $assertionIndex."
                evidence_refs = @($evidenceRef)
            })
        }
        $fixtureFinalResponse = ConvertTo-RunnerJson -Value ([ordered]@{
            schema = 'codebeltnet/agentic/eval-analyzer-fragment/1'
            eval_id = [int](Get-JsonProperty -Object $bundle -Name 'eval_id' -Default 0)
            configuration = [string](Get-JsonProperty -Object $bundle -Name 'configuration' -Default '')
            grading = @($fragmentGrades.ToArray())
        }) -Compress
    }
    $durationSeconds = [Math]::Round(($executeFinishUtc - $executeStartUtc).TotalSeconds, 3)
    $durationOverride = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_DURATION_SECONDS')
    $parsedDuration = 0.0
    if (-not [string]::IsNullOrWhiteSpace($durationOverride) -and [double]::TryParse($durationOverride, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedDuration) -and $parsedDuration -ge 0) {
        $durationSeconds = $parsedDuration
    }
    $fixtureTelemetryTokens = New-UnavailableMetric -Reason 'fixture'
    $fixtureTelemetryToolCalls = New-AvailableMetric -Value 0
    if ([Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_METRICS') -eq '1') {
        $fixtureTelemetryTokens = New-AvailableMetric -Value ([ordered]@{
            input_tokens = 27
            output_tokens = 123
            total_tokens = 123
            cached_input_tokens = 456
            cache_write_tokens = 78
        })
        $fixtureTelemetryToolCalls = New-AvailableMetric -Value 2
    }
    $eventsPath = Join-Path $inputs.Run.RunRoot 'evidence/fixture-events.jsonl'
    New-Item -ItemType Directory -Path (Split-Path -Parent $eventsPath) -Force | Out-Null
    $eventLines = [System.Collections.Generic.List[string]]::new()
    if ($turnRecords.Count -gt 0) {
        $eventSequence = 0
        foreach ($turn in @($turnRecords.ToArray())) {
            if ([string]$turn.role -eq 'assistant' -and [int]$turn.sequence -eq 4) {
                # The confirmation fixture models the protected operation as a
                # transport event between the second user dispatch and its
                # terminal response. It can therefore prove the operation did
                # not happen in the first turn without consulting model text.
                $eventSequence++
                $eventLines.Add(([ordered]@{
                    type = 'protected.operation'
                    sequence = $eventSequence
                    turn_sequence = [int]$turn.sequence
                    session_id = [string]$turn.session_id
                    timestamp_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow)
                } | ConvertTo-Json -Compress))
            }
            $eventSequence++
            $eventLines.Add(([ordered]@{
                type = if ([string]$turn.role -eq 'user') { 'user.dispatched' } else { 'assistant.terminal' }
                sequence = $eventSequence
                turn_sequence = [int]$turn.sequence
                session_id = [string]$turn.session_id
                timestamp_utc = [string]$turn.timestamp_utc
            } | ConvertTo-Json -Compress))
        }
    } else {
        $eventLines.Add(([ordered]@{ type = 'assistant.terminal'; sequence = 1; session_id = $sessionId; timestamp_utc = Format-UtcTimestamp -Value $executeFinishUtc } | ConvertTo-Json -Compress))
    }
    [IO.File]::WriteAllText($eventsPath, ([string]::Join("`n", $eventLines) + "`n"), [Text.UTF8Encoding]::new($false))
    $eventsArtifact = New-ArtifactReference -Run $inputs.Run -Path 'evidence/fixture-events.jsonl' -Scope run -MediaType 'application/x-ndjson; charset=utf-8'
    $artifactReferences = [System.Collections.Generic.List[object]]::new()
    $artifactReferences.Add($eventsArtifact)
    foreach ($extra in @(Get-ExtraTranscriptArtifacts)) {
        $artifactPath = Join-Path $inputs.Run.RunRoot (([string]$extra.Path) -replace '/', [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $artifactPath) -Force | Out-Null
        [IO.File]::WriteAllText($artifactPath, ([string]::Join("`n", @($extra.Content)) + "`n"), [Text.UTF8Encoding]::new($false))
        $artifactReferences.Add((New-ArtifactReference -Run $inputs.Run -Path ([string]$extra.Path) -Scope run -MediaType ([string]$extra.MediaType)))
    }
    $evidence = [ordered]@{
        capture = [ordered]@{ source = 'harness_native_transport'; terminal = $true; worker_authored = $false }
        commands = @(
            [ordered]@{ type = 'command_execution'; command = 'git branch --show-current'; status = 'completed'; exit_code = 0 }
            [ordered]@{ type = 'command_execution'; command = 'git symbolic-ref refs/remotes/origin/HEAD --short'; status = 'completed'; exit_code = 0 }
            [ordered]@{ type = 'command_execution'; command = 'git log origin/HEAD..HEAD --oneline'; status = 'completed'; exit_code = 0 }
            [ordered]@{ type = 'command_execution'; command = 'git diff origin/HEAD...HEAD'; status = 'completed'; exit_code = 0 }
        )
        files_written = @()
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = 'deterministic-runner-owned-fixture'
            worker_session_id = $sessionId
            observed_model = if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_OBSERVED_MODEL'))) { [string]$inputs.Profile.Model } else { [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_OBSERVED_MODEL') }
            observed_working_directory = [string]$inputs.Run.WorkingDirectoryPath
            observed_home = [string]$inputs.Run.HomeDirectoryPath
            fresh_worker = $true
            home_config_isolated = $true
            prompt_fidelity = $true
            prompt_sha256 = [string]$inputs.Run.PromptHash
            terminal_result_capture = $true
            paired_arm_visible = $false
            grading_material_visible = $false
            nested_model_execution = $false
            model_execution_count = 1
        }
        turns = if ($turnRecords.Count -gt 0) { @($turnRecords.ToArray()) } else { $null }
    }
    if (Test-FixtureEvidenceValidationFailure) {
        $evidence.delegation.prompt_fidelity = $false
    }
    if ($turnRecords.Count -gt 0 -and $terminalStatus -eq 'completed') {
        $evidence.interaction = [ordered]@{ schema = (Get-RunnerSchemaNames).Interaction; mode = 'scripted'; same_session = $true; session_id = $sessionId; turns = @($turnRecords.ToArray()); final_response_sequence = $turnRecords.Count }
    }
    $finalResponse = if ($terminalStatus -eq 'completed') { $fixtureFinalResponse } else { $null }
    $finalResponseReason = switch ($terminalStatus) {
        'failed' { 'fixture_failure' }
        'timed_out' { 'fixture_timeout' }
        'cancelled' { 'fixture_cancelled' }
        default { $null }
    }
    $exitStatus = switch ($terminalStatus) {
        'completed' { [Nullable[int]]0 }
        'failed' { [Nullable[int]]17 }
        'cancelled' { [Nullable[int]]130 }
        default { $null }
    }
    $failure = switch ($terminalStatus) {
        'failed' { New-ExecutionFailure -Code 'fixture_harness_failure' -Message 'The deterministic runner-owned fixture reported a harness failure.' }
        'timed_out' { New-ExecutionFailure -Code 'timed_out' -Message 'The deterministic runner-owned fixture exceeded its execution window.' }
        'cancelled' { New-ExecutionFailure -Code 'cancelled' -Message 'The deterministic runner-owned fixture was cancelled before completion.' }
        default { $null }
    }
    $result = New-ExecutionResult -Descriptor $descriptor -Profile $inputs.Profile -Run $inputs.Run -Status $terminalStatus -FinalResponse $finalResponse -FinalResponseReason $finalResponseReason -StartedUtc ($executeStartUtc.ToString('o')) -FinishedUtc ($executeFinishUtc.ToString('o')) -DurationSeconds $durationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionId -IsolationCapabilities $capabilities -IsolationMechanisms @('deterministic runner-owned fixture') -Telemetry ([ordered]@{ transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/fixture-events.jsonl'; complete = $true }); tokens = $fixtureTelemetryTokens; tool_calls = $fixtureTelemetryToolCalls; cost = New-UnavailableMetric -Reason 'fixture' }) -Artifacts @($artifactReferences.ToArray()) -Evidence $evidence -AttemptCount 1
    [void](Assert-ExecutionResult -Result $result)
    Write-RunnerJson -Value $result -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
