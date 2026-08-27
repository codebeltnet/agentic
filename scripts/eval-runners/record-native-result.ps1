<#!
.SYNOPSIS
    Records a native worker terminal envelope as the runner-owned raw result.

.DESCRIPTION
    This command is deterministic. It never starts a harness or a model. The
    external orchestrator uses it after a harness-native worker has finished so
    that the selected package runner, rather than the orchestrator, owns the
    eval-execution-result/1 serialization boundary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Runner,
    [Parameter(Mandatory = $true)][string]$Run,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$NativeResult,
    [Parameter(Mandatory = $true)][string]$Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'runner-common.ps1')

function ConvertTo-StringDictionary {
    param([Parameter(Mandatory = $true)][object]$Value)

    $result = [ordered]@{}
    foreach ($name in @(Get-JsonPropertyNames -Object $Value)) {
        $result[[string]$name] = [string](Get-JsonProperty -Object $Value -Name ([string]$name) -Default '')
    }
    return $result
}

function Assert-NativeResultEnvelope {
    param(
        [Parameter(Mandatory = $true)][object]$Native,
        [Parameter(Mandatory = $true)][object]$RunData
    )

    if ([string]$Native.schema -ne 'codebeltnet/agentic/eval-native-worker-result/1') {
        throw "Native worker result must declare 'codebeltnet/agentic/eval-native-worker-result/1'."
    }

    foreach ($field in @('run_id', 'session', 'status', 'run', 'final_response', 'timing', 'exit', 'isolation', 'telemetry', 'evidence', 'capture', 'artifacts', 'warnings', 'compatibility_deviations', 'attempt_count')) {
        if (-not (Test-JsonProperty -Object $Native -Name $field)) {
            throw "Native worker result is missing '$field'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Native.run_id)) {
        throw 'Native worker result run_id must be non-empty.'
    }
    if ([string]$Native.status -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
        throw "Native worker result status '$($Native.status)' is unsupported."
    }
    if ([int]$Native.attempt_count -ne 1) {
        throw 'Native worker result attempt_count must be exactly 1.'
    }

    $runIdentity = $Native.run
    if ([int]$runIdentity.eval_id -ne [int]$RunData.EvalId -or
        [string]$runIdentity.eval_name -ne [string]$RunData.EvalName -or
        [string]$runIdentity.configuration -ne [string]$RunData.Mode) {
        throw 'Native worker result run identity does not match run.json.'
    }

    $session = $Native.session
    if ([string]::IsNullOrWhiteSpace([string]$session.id) -or
        -not [bool]$session.fresh -or [bool]$session.resumed) {
        throw 'Native worker result must identify a fresh, non-resumed session.'
    }

    $response = $Native.final_response
    if ([string]$response.status -eq 'available') {
        if (-not (Test-JsonProperty -Object $response -Name 'text')) {
            throw 'Available native worker responses must contain text.'
        }
    } elseif ([string]$response.status -eq 'unavailable') {
        if ([string]::IsNullOrWhiteSpace([string]$response.reason)) {
            throw 'Unavailable native worker responses must contain a reason.'
        }
    } else {
        throw "Native worker final_response status '$($response.status)' is unsupported."
    }

    $timing = $Native.timing
    foreach ($field in @('started_utc', 'finished_utc', 'duration_seconds')) {
        if (-not (Test-JsonProperty -Object $timing -Name $field)) {
            throw "Native worker result timing.$field must be present."
        }
    }
    try {
        $started = [DateTime]::Parse([string]$timing.started_utc).ToUniversalTime()
        $finished = [DateTime]::Parse([string]$timing.finished_utc).ToUniversalTime()
    } catch {
        throw "Native worker result timing timestamps are invalid: $($_.Exception.Message)"
    }
    if ($finished -lt $started -or [double]$timing.duration_seconds -lt 0) {
        throw 'Native worker result timing must be ordered and non-negative.'
    }

    $exit = $Native.exit
    if (-not (Test-JsonProperty -Object $exit -Name 'status')) {
        throw 'Native worker result exit.status must be present and numeric or null.'
    }
    $exitStatus = Get-JsonProperty -Object $exit -Name 'status' -Default $null
    if ($null -ne $exitStatus -and -not ($exitStatus -is [byte] -or $exitStatus -is [sbyte] -or $exitStatus -is [int16] -or $exitStatus -is [uint16] -or $exitStatus -is [int32] -or $exitStatus -is [uint32] -or $exitStatus -is [int64] -or $exitStatus -is [uint64])) {
        throw 'Native worker result exit.status must be a JSON number or null.'
    }

    $isolation = $Native.isolation
    if (-not (Test-JsonProperty -Object $isolation -Name 'capabilities') -or
        -not (Test-JsonProperty -Object $isolation -Name 'mechanisms')) {
        throw 'Native worker result isolation must declare capabilities and mechanisms.'
    }
    if (@(Get-JsonProperty -Object $isolation -Name 'mechanisms' -Default @()).Count -eq 0) {
        throw 'Native worker result isolation.mechanisms must not be empty.'
    }
    if (-not (Test-JsonProperty -Object $Native.evidence -Name 'delegation')) {
        throw 'Native worker result evidence.delegation must be present.'
    }
    $capture = $Native.capture
    if ([string]$capture.source -ne 'harness_native_transport' -or
        -not [bool]$capture.terminal -or [bool]$capture.worker_authored) {
        throw 'Native worker result capture must come from the terminal harness-native transport; the worker may not author the envelope.'
    }
    if (@($Native.artifacts).Count -lt 1) {
        throw 'Native worker result must record at least one artifact, including terminal evidence.'
    }
}

try {
    $runData = Resolve-RunContract -RunPath $Run
    [void](Assert-PhaseOneEvidenceWritable -Run $runData)
    $profileData = Resolve-ExecutionProfile -ProfilePath $Profile
    if ([string]$profileData.Runner -ne $Runner) {
        throw "Selected runner '$Runner' does not match execution-profile.json runner '$($profileData.Runner)'."
    }

    $iterationDirectory = Split-Path -Parent (Split-Path -Parent $runData.RunRoot)
    $nativePath = (Resolve-Path -LiteralPath $NativeResult -ErrorAction Stop).Path
    $outputPath = [System.IO.Path]::GetFullPath($Output, (Get-Location).Path)
    if (-not (Test-PathInside -BasePath $iterationDirectory -CandidatePath $nativePath)) {
        throw 'Native worker result input must remain inside the prepared iteration package.'
    }
    if (-not (Test-PathInside -BasePath $iterationDirectory -CandidatePath $outputPath)) {
        throw 'Recorded execution result output must remain inside the prepared iteration package.'
    }
    $outputDirectory = Split-Path -Parent $outputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Recorded execution result directory '$outputDirectory' does not exist."
    }

    $native = Read-RunnerJson -Path $nativePath
    Assert-NativeResultEnvelope -Native $native -RunData $runData
    $descriptor = Get-PackageRunnerDescriptor -RunnerName $Runner

    $capabilities = ConvertTo-StringDictionary -Value $native.isolation.capabilities
    $response = $native.final_response
    $finalText = if ([string]$response.status -eq 'available') { [string]$response.text } else { $null }
    $finalReason = if ([string]$response.status -eq 'unavailable') { [string]$response.reason } else { $null }
    $exitStatusValue = Get-JsonProperty -Object $native.exit -Name 'status' -Default $null
    $exitStatus = if ($null -eq $exitStatusValue) { $null } else { [int]$exitStatusValue }
    $resolvedConfiguration = Get-JsonProperty -Object $native -Name 'resolved' -Default $null
    $evidence = Get-JsonProperty -Object $native -Name 'evidence' -Default ([ordered]@{})
    if ($evidence -is [System.Collections.IDictionary]) {
        $evidence['capture'] = $native.capture
    } else {
        Add-Member -InputObject $evidence -MemberType NoteProperty -Name capture -Value $native.capture -Force
    }
    $result = New-ExecutionResult `
        -Descriptor $descriptor `
        -Profile $profileData `
        -Run $runData `
        -Status ([string]$native.status) `
        -FinalResponse $finalText `
        -FinalResponseReason $finalReason `
        -StartedUtc ([string]$native.timing.started_utc) `
        -FinishedUtc ([string]$native.timing.finished_utc) `
        -DurationSeconds ([double]$native.timing.duration_seconds) `
        -ExitStatus $exitStatus `
        -Failure (Get-JsonProperty -Object $native.exit -Name 'failure' -Default $null) `
        -SessionId ([string]$native.session.id) `
        -IsolationCapabilities $capabilities `
        -IsolationMechanisms @((Get-JsonProperty -Object $native.isolation -Name 'mechanisms' -Default @())) `
        -ResolvedConfiguration $resolvedConfiguration `
        -Telemetry (Get-JsonProperty -Object $native -Name 'telemetry' -Default $null) `
        -Artifacts @((Get-JsonProperty -Object $native -Name 'artifacts' -Default @())) `
        -Warnings @((Get-JsonProperty -Object $native -Name 'warnings' -Default @())) `
        -CompatibilityDeviations @((Get-JsonProperty -Object $native -Name 'compatibility_deviations' -Default @())) `
        -Evidence $evidence `
        -AttemptCount 1
    $result.run_id = [string]$native.run_id

    [void](Assert-ExecutionResult -Result $result)
    if ([string]$result.status -ne 'incompatible') {
        $terminalValidation = Test-NativeWorkerTerminalEvidence `
            -ExecutionEvidence $result `
            -Run $runData `
            -RequestedModel ([string]$profileData.Model) `
            -ExpectedWorkerSessionId ([string]$native.session.id) `
            -ExpectedRunner $Runner `
            -ExpectedMechanism ([string]$descriptor.delegation.mechanism)
        if (-not $terminalValidation.Valid) {
            throw "Native worker terminal evidence is incompatible: $([string]::Join(', ', @($terminalValidation.Failures)))."
        }
        Assert-NativeTerminalCaptureArtifact -ExecutionResult $result
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($outputPath, ((ConvertTo-Json -InputObject $result -Depth 100) + [Environment]::NewLine), $utf8NoBom)
    $relativeOutput = [System.IO.Path]::GetRelativePath($iterationDirectory, $outputPath).Replace('\', '/')
    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-native-worker-record/1'
        runner = $Runner
        execution_result = $relativeOutput
        execution_status = $result.status
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
