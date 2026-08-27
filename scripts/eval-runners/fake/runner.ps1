<#!
.SYNOPSIS
    Deterministic Eval Runner used for protocol conformance tests.

.DESCRIPTION
    This runner never invokes a model or a provider. It records the same
    boundaries as a real runner and emits deterministic outcomes selected by
    -Scenario or AGENTIC_FAKE_SCENARIO.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('describe', 'preflight', 'execute')]
    [string]$Command,

    [string]$Run,
    [string]$Profile,

    [ValidateSet('normal', 'refusal', 'timeout', 'failure', 'incompatible', 'escape', 'unknown-event')]
    [string]$Scenario
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\runner-common.ps1')

$descriptor = [ordered]@{
    schema = (Get-RunnerSchemaNames).Descriptor
    protocol_version = (Get-RunnerSchemaNames).Protocol
    name = 'fake'
    version = '0.9.1-test'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'deterministic-fake'; version = '1' }
    capabilities = [ordered]@{
        single_turn = 'supported'
        scripted_multi_turn_same_session = 'unsupported'
        fresh_context = 'supported'
        isolated_home_config = 'supported'
        isolated_working_directory = 'supported'
        filesystem_confinement = 'supported'
        ambient_candidate_skill_exclusion = 'supported'
        candidate_skill_exposure = 'supported'
        prompt_fidelity = 'supported'
        model_configuration_lock = 'supported'
        response_capture = 'supported'
        transcript_event_capture = 'supported'
        token_telemetry = 'unsupported'
        cache_token_telemetry = 'unsupported'
        tool_call_telemetry = 'supported'
        command_evidence = 'supported'
        file_evidence = 'supported'
        cost_telemetry = 'unsupported'
        native_skill_activation_evidence = 'unsupported'
        # This runner is a deterministic compatibility fixture. It has no
        # harness-native worker surface and cannot prove a delegated child.
        native_worker_delegation = 'unsupported'
        delegated_worker_full_capability = 'unsupported'
        delegated_worker_model_lock = 'unsupported'
        delegated_worker_working_directory = 'unsupported'
        delegated_worker_result_capture = 'unsupported'
        delegated_worker_capacity_signal = 'unsupported'
    }
    delegation = [ordered]@{
        dispatch_owner = 'orchestrator'
        mode = 'unsupported'
        mechanism = 'deterministic compatibility execute fixture; no harness-native worker surface'
        worker_role = 'compatibility-fixture'
        full_capability = 'unsupported'
        model_lock = 'unsupported'
        working_directory = 'unsupported'
        result_capture = 'unsupported'
        capacity = 'unsupported'
        nested_model_execution = $false
    }
    supported_telemetry = @('transcript_event_capture', 'tool_call_telemetry', 'command_evidence', 'file_evidence')
    configuration_profiles = @('isolated-default')
    tool_profiles = @('default')
}

function Write-ProtocolError {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 2
}

function Get-FakeScenario {
    if (-not [string]::IsNullOrWhiteSpace($Scenario)) {
        return $Scenario
    }
    $fromEnvironment = [Environment]::GetEnvironmentVariable('AGENTIC_FAKE_SCENARIO')
    if ([string]::IsNullOrWhiteSpace($fromEnvironment)) {
        return 'normal'
    }
    return $fromEnvironment.ToLowerInvariant()
}

function Resolve-FakeInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    $resolvedRun = Resolve-RunContract -RunPath $Run
    $resolvedProfile = Resolve-ExecutionProfile -ProfilePath $Profile
    return [pscustomobject]@{ Run = $resolvedRun; Profile = $resolvedProfile }
}

function Get-FakePreflight {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [string]$ScenarioValue = 'normal'
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run

    if ($profile.Runner -ne 'fake') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than fake.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is fake.'))
    }

    if ($profile.ConfigurationProfile -notin @($descriptor.configuration_profiles)) {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is not supported by fake.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'configuration_profile' -Status passed -Detail $profile.ConfigurationProfile))
    }
    if ($profile.ToolProfile -notin @($descriptor.tool_profiles)) {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is not supported by fake.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'tool_profile' -Status passed -Detail $profile.ToolProfile))
    }

    $checks.Add((New-PreflightCheck -Name 'fresh_process' -Status passed -Detail 'Each fake execute command creates a new process and session id.'))
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail 'The prompt bytes are read once and recorded without transformation.'))
    $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "repo=$($run.WorkingDirectoryPath); home=$($run.HomeDirectoryPath)"))
    $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail 'Fake escape probes are rejected by the contained-path guard.'))
    $checks.Add((New-PreflightCheck -Name 'candidate_skill_boundary' -Status passed -Detail "candidate_skill_exposed=$($run.CandidateSkillExposed)"))
    if ($ScenarioValue -eq 'incompatible') {
        $reasons.Add('The deterministic incompatible scenario was requested.')
    }

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $capabilities[$capabilityName] = Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName
    }
    $capabilities['candidate_skill_exposure'] = if ($run.CandidateSkillExposed) { 'supported' } else { 'excluded' }
    if ($reasons.Count -gt 0) {
        $warnings.Add('No execute process is started for an incompatible preflight.')
    }

    return New-PreflightDocument -Descriptor $descriptor -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @('pwsh-process', 'run-directory-contained-path-guard', 'isolated-home-directory') -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
}

function Write-FakeEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$ScenarioValue
    )

    $evidenceDirectory = Join-Path $Inputs.Run.RunRoot 'evidence'
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
    $eventsPath = Join-Path $evidenceDirectory 'fake-events.jsonl'
    $promptEvidencePath = Join-Path $evidenceDirectory 'prompt-delivery.json'
    $boundaryEvidencePath = Join-Path $evidenceDirectory 'boundary-probes.json'

    $events = [System.Collections.Generic.List[string]]::new()
    $events.Add((([ordered]@{ type = 'session.started'; session_id = $SessionId } | ConvertTo-Json -Compress)))
    $events.Add((([ordered]@{
        type = 'task.input'
        ordinal = 1
        prompt_sha256 = $Inputs.Run.PromptHash
        byte_length = $Inputs.Run.PromptBytes.Length
        first_task_input = $true
    } | ConvertTo-Json -Compress)))
    $events.Add((([ordered]@{ type = 'response.completed'; status = if ($ScenarioValue -eq 'refusal') { 'refusal' } else { 'completed' } } | ConvertTo-Json -Compress)))
    if ($ScenarioValue -eq 'unknown-event') {
        $events.Add((([ordered]@{ type = 'future.event.v99'; payload = 'ignored-by-conformance-adapter' } | ConvertTo-Json -Compress)))
    }
    [System.IO.File]::WriteAllText($eventsPath, ([string]::Join("`n", $events) + "`n"), [System.Text.UTF8Encoding]::new($false))

    [ordered]@{
        prompt_sha256 = $Inputs.Run.PromptHash
        first_task_input_sha256 = $Inputs.Run.PromptHash
        first_task_input_bytes = $Inputs.Run.PromptBytes.Length
        byte_exact = $true
        candidate_skill_exposed = $Inputs.Run.CandidateSkillExposed
        working_directory = $Inputs.Run.WorkingDirectoryPath
        home_directory = $Inputs.Run.HomeDirectoryPath
        global_rules_visible = $false
        global_memory_visible = $false
        global_plugins_visible = $false
        global_same_name_skill_visible = $false
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $promptEvidencePath -Encoding utf8NoBOM

    $boundary = [ordered]@{
        read_outside_run = [ordered]@{ attempted = $false; blocked = $true; path = '../eval-metadata.json' }
        write_outside_run = [ordered]@{ attempted = $false; blocked = $true; path = '../escape-write.txt' }
    }
    if ($ScenarioValue -eq 'escape') {
        foreach ($probe in @('read_outside_run', 'write_outside_run')) {
            $boundary[$probe].attempted = $true
            try {
                [void](Resolve-ContainedPath -BasePath $Inputs.Run.RunRoot -RelativePath ([string]$boundary[$probe].path) -FieldName $probe)
                $boundary[$probe].blocked = $false
            } catch {
                $boundary[$probe].blocked = $true
                $boundary[$probe].error = $_.Exception.Message
            }
        }
    }
    $boundary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $boundaryEvidencePath -Encoding utf8NoBOM

    return @(
        (New-ArtifactReference -Run $Inputs.Run -Path 'evidence/fake-events.jsonl' -Scope run -MediaType 'application/x-ndjson'),
        (New-ArtifactReference -Run $Inputs.Run -Path 'evidence/prompt-delivery.json' -Scope run -MediaType 'application/json'),
        (New-ArtifactReference -Run $Inputs.Run -Path 'evidence/boundary-probes.json' -Scope run -MediaType 'application/json')
    )
}

function Invoke-FakeExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $scenarioValue = Get-FakeScenario
    if ($scenarioValue -notin @('normal', 'refusal', 'timeout', 'failure', 'incompatible', 'escape', 'unknown-event')) {
        throw "Unsupported fake scenario '$scenarioValue'."
    }

    $preflight = Get-FakePreflight -Inputs $Inputs -ScenarioValue $scenarioValue
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $warnings = [System.Collections.Generic.List[string]]::new()
    $deviations = [System.Collections.Generic.List[string]]::new()

    if ($preflight.status -eq 'incompatible') {
        $finished = [DateTime]::UtcNow
        $incompatibilityMessage = [string]::Join('; ', @($preflight.reasons))
        if ([string]::IsNullOrWhiteSpace($incompatibilityMessage)) {
            $incompatibilityMessage = "Fake preflight reported incompatible without a reason (profile_runner=$($Inputs.Profile.Runner); configuration_profile=$($Inputs.Profile.ConfigurationProfile); tool_profile=$($Inputs.Profile.ToolProfile); scenario=$scenarioValue)."
        }
        return New-ExecutionResult -Descriptor $descriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $incompatibilityMessage) -SessionId $sessionId -IsolationCapabilities ([ordered]@{ fresh_context = 'supported'; isolated_home_config = 'supported'; isolated_working_directory = 'supported'; filesystem_confinement = 'supported'; candidate_skill_exposure = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' } }) -IsolationMechanisms @('pwsh-process', 'run-directory-contained-path-guard', 'isolated-home-directory') -CompatibilityDeviations @($deviations) -Evidence ([ordered]@{ preflight = $preflight }) -AttemptCount 1
    }

    $artifacts = @(Write-FakeEvidence -Inputs $Inputs -SessionId $sessionId -ScenarioValue $scenarioValue)
    if ($scenarioValue -eq 'unknown-event') {
        $warnings.Add('Unknown fake event future.event.v99 was preserved as an explicit warning.')
    }

    $status = 'completed'
    $finalResponse = 'Deterministic fake runner completed the blind eval arm.'
    $finalReason = $null
    $exitStatus = [Nullable[int]]0
    $failure = $null
    if ($scenarioValue -eq 'refusal') {
        $finalResponse = 'I cannot complete this request.'
        $warnings.Add('The harness returned a refusal; it was normalized as a completed response, not retried.')
    } elseif ($scenarioValue -eq 'timeout') {
        $status = 'timed_out'
        $finalResponse = $null
        $finalReason = 'fake_timeout'
        $exitStatus = $null
        $failure = New-ExecutionFailure -Code 'timed_out' -Message 'The deterministic fake exceeded its configured execution window.'
    } elseif ($scenarioValue -eq 'failure') {
        $status = 'failed'
        $finalResponse = $null
        $finalReason = 'harness_failure'
        $exitStatus = [Nullable[int]]17
        $failure = New-ExecutionFailure -Code 'fake_harness_failure' -Message 'The deterministic fake reported a harness failure.'
    }

    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/fake-events.jsonl'; complete = $true })
        tokens = New-UnavailableMetric -Reason 'fake_harness_does_not_expose_usage'
        tool_calls = New-AvailableMetric -Value 0
        cost = New-UnavailableMetric -Reason 'fake_harness_does_not_expose_cost'
    }
    $finished = [DateTime]::UtcNow
    return New-ExecutionResult -Descriptor $descriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalResponse -FinalResponseReason $finalReason -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionId -IsolationCapabilities ([ordered]@{ fresh_context = 'supported'; isolated_home_config = 'supported'; isolated_working_directory = 'supported'; filesystem_confinement = 'supported'; ambient_candidate_skill_exclusion = 'supported'; candidate_skill_exposure = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' }; prompt_fidelity = 'supported'; model_configuration_lock = 'supported'; response_capture = 'supported' }) -IsolationMechanisms @('pwsh-process', 'run-directory-contained-path-guard', 'isolated-home-directory') -Telemetry $telemetry -Artifacts $artifacts -Warnings @($warnings) -CompatibilityDeviations @($deviations) -Evidence ([ordered]@{ scenario = $scenarioValue; prompt_first_input = $true; resume = $false; preflight = $preflight }) -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' {
            Write-RunnerJson -Value $descriptor -AsOutput
        }
        'preflight' {
            $inputs = Resolve-FakeInputs
            $preflight = Get-FakePreflight -Inputs $inputs -ScenarioValue (Get-FakeScenario)
            Write-RunnerJson -Value $preflight -AsOutput
        }
        'execute' {
            $inputs = Resolve-FakeInputs
            [void](Assert-PhaseOneEvidenceWritable -Run $inputs.Run)
            $result = Invoke-FakeExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 2
}
