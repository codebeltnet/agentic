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
    if ($Command -eq 'preflight') {
        Write-FixtureEvent -Kind 'preflight'
        if (Test-Path -LiteralPath (Join-Path $inputs.Run.HomeDirectoryPath 'preflight-incompatible') -PathType Leaf) {
            Write-RunnerJson -Value (New-PreflightDocument -Descriptor $descriptor -Profile $inputs.Profile -Run $inputs.Run -Compatible $false -Reasons @("fixture preflight rejected $($inputs.Run.EvalName)/$($inputs.Run.Mode)") -ResolvedCapabilities $descriptor.capabilities -Mechanisms @('deterministic fixture')) -AsOutput
            exit 0
        }
        Write-RunnerJson -Value (New-PreflightDocument -Descriptor $descriptor -Profile $inputs.Profile -Run $inputs.Run -Compatible $true -ResolvedCapabilities $descriptor.capabilities -Mechanisms @('deterministic fixture')) -AsOutput
        exit 0
    }
    Write-FixtureEvent -Kind 'execute'
    Start-Sleep -Milliseconds 250
    $capabilities = [ordered]@{}
    foreach ($propertyName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) { $capabilities[$propertyName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $propertyName) }
    $sessionId = ('fixture-session-' + [Guid]::NewGuid().ToString('N'))
    $evidence = [ordered]@{
        capture = [ordered]@{ source = 'harness_native_transport'; terminal = $true; worker_authored = $false }
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = 'deterministic-runner-owned-fixture'
            worker_session_id = $sessionId
            observed_model = [string]$inputs.Profile.Model
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
    }
    $result = New-ExecutionResult -Descriptor $descriptor -Profile $inputs.Profile -Run $inputs.Run -Status completed -FinalResponse 'deterministic fixture response' -StartedUtc ([DateTime]::UtcNow.AddMilliseconds(-250).ToString('o')) -FinishedUtc ([DateTime]::UtcNow.ToString('o')) -DurationSeconds 0.25 -ExitStatus ([Nullable[int]]0) -SessionId $sessionId -IsolationCapabilities $capabilities -IsolationMechanisms @('deterministic runner-owned fixture') -Telemetry ([ordered]@{ transcript = New-UnavailableMetric -Reason 'fixture transcript not required for queue test'; tokens = New-UnavailableMetric -Reason 'fixture'; tool_calls = New-AvailableMetric -Value 0; cost = New-UnavailableMetric -Reason 'fixture' }) -Evidence $evidence -AttemptCount 1
    [void](Assert-ExecutionResult -Result $result)
    Write-RunnerJson -Value $result -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
