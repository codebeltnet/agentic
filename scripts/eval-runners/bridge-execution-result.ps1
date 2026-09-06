<#!
.SYNOPSIS
    Bridges one normalized execution-result.json into the existing eval-result/2 shape.

.DESCRIPTION
    This bridge runs after execution and before grading. It reads no expected
    output or assertions, preserves any existing grading array, validates raw
    artifact provenance, and deliberately leaves unavailable telemetry null.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Run,

    [Parameter(Mandatory = $true)]
    [string]$ExecutionResult,

    [Parameter(Mandatory = $true)]
    [string]$Result,

    [switch]$RequireNativeDelegation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-BridgeJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $serializable = if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = $Value[$key] }
        [pscustomobject]$copy
    } else {
        $Value
    }
    Write-RunnerJsonFile -Path $Path -Value $serializable
}

function Get-CapabilityBoolean {
    param([object]$Value)

    if ([string]$Value -in @('supported', 'verified', 'true')) { return $true }
    if ([string]$Value -in @('unsupported', 'excluded', 'false')) { return $false }
    return $null
}

function Get-MetricValue {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $metric = Get-JsonProperty -Object $Result.telemetry -Name $Name -Default $null
    if ($null -eq $metric -or [string](Get-JsonProperty -Object $metric -Name 'status' -Default '') -ne 'available') {
        return $null
    }
    return Get-JsonProperty -Object $metric -Name 'value' -Default $null
}

function Get-PortableTranscript {
    param([Parameter(Mandatory = $true)][object]$Raw, [Parameter(Mandatory = $true)][object]$RunData)

    $interaction = Get-JsonProperty -Object $Raw.evidence -Name 'interaction' -Default $null
    if ([string]$Raw.runner.name -eq 'github-copilot' -and
        [string](Get-JsonProperty -Object $interaction -Name 'mode' -Default '') -eq 'scripted') {
        if ($null -eq $RunData.Interaction -or [string]$Raw.status -ne 'completed' -or
            [string]$Raw.final_response.status -ne 'available' -or
            $interaction.same_session -isnot [bool] -or -not $interaction.same_session) {
            throw 'Copilot scripted transcript requires a complete prepared interaction and terminal response.'
        }
        [void](Assert-InteractionResultEvidence -ExecutionResult $Raw -RunData $RunData)
        $sessionId = [string]$interaction.session_id
        $turns = @($interaction.turns)
        $nativeTurns = @(Get-JsonProperty -Object $interaction -Name 'native_turns' -Default @())
        $requestedTurns = @($RunData.Interaction.turns)
        if ([string]::IsNullOrWhiteSpace($sessionId) -or $nativeTurns.Count -ne $requestedTurns.Count -or
            -not [string]::Equals($sessionId, [string]$Raw.session.id, [StringComparison]::Ordinal)) {
            throw 'Copilot scripted transcript has inconsistent native turn/session evidence.'
        }
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add("# GitHub Copilot Transcript`n`nSession: $sessionId`nSame session: true")
        for ($index = 0; $index -lt $requestedTurns.Count; $index++) {
            $user = $turns[$index * 2]
            $assistant = $turns[($index * 2) + 1]
            $native = $nativeTurns[$index]
            if ([string]$user.sequence -cne [string](($index * 2) + 1) -or [string]$user.role -cne 'user' -or
                [string]$assistant.sequence -cne [string](($index * 2) + 2) -or [string]$assistant.role -cne 'assistant' -or
                $assistant.text -isnot [string]) {
                throw 'Copilot scripted transcript requires each ordered captured user/assistant pair exactly once.'
            }
            $observedIds = @($native.session_ids_observed)
            if ([int]$native.turn -ne ($index + 1) -or -not [bool]$native.terminal -or
                -not [bool]$native.terminal_assistant_response -or $observedIds.Count -ne 1 -or
                -not [string]::Equals([string]$observedIds[0], $sessionId, [StringComparison]::Ordinal) -or
                -not [string]::Equals([string]$native.session_id, $sessionId, [StringComparison]::Ordinal) -or
                -not [string]::Equals([string]$user.session_id, $sessionId, [StringComparison]::Ordinal) -or
                -not [string]::Equals([string]$assistant.session_id, $sessionId, [StringComparison]::Ordinal)) {
                throw 'Copilot scripted transcript has inconsistent ordered native capture evidence.'
            }
            if (($index -eq 0 -and [string]$native.invocation -ne 'fresh') -or
                ($index -gt 0 -and ([string]$native.invocation -ne 'explicit_session_resume' -or
                    -not [string]::Equals([string]$native.target_session_id, $sessionId, [StringComparison]::Ordinal)))) {
                throw 'Copilot scripted transcript does not prove exact session continuation.'
            }
            $userText = Get-InteractionTurnText -Turn $requestedTurns[$index] -RunData $RunData
            $hash = Get-Sha256HexFromBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($userText))
            if (-not [string]::Equals($hash, [string]$user.content_sha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Copilot scripted transcript user text does not match the captured input hash.'
            }
            $parts.Add("## Message $($user.sequence) - User`n`n$userText")
            $parts.Add("## Message $($assistant.sequence) - Assistant`n`n$($assistant.text)")
        }
        if ([string]$interaction.final_response_sequence -cne [string]$turns.Count -or
            -not [string]::Equals([string]$turns[-1].text, [string]$Raw.final_response.text, [StringComparison]::Ordinal)) {
            throw 'Copilot scripted transcript terminal assistant text does not match final_response.'
        }
        return [string]::Join("`n`n", $parts)
    }

    $metric = Get-MetricValue -Result $Raw -Name 'transcript'
    if ($null -ne $metric) {
        $artifact = [string](Get-JsonProperty -Object $metric -Name 'artifact' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($artifact)) { return "artifact: $artifact" }
    }
    return ''
}

function Get-NormalizedTotalTokens {
    param([object]$Tokens)

    function Test-TokenCount {
        param([object]$Value)
        return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) -and
            $Value -ge 0 -and -not [double]::IsInfinity([double]$Value) -and -not [double]::IsNaN([double]$Value)
    }

    if ($null -eq $Tokens) { return $null }
    $total = Get-JsonProperty -Object $Tokens -Name 'total_tokens' -Default $null
    if (Test-TokenCount $total) { return $total }
    $inputCount = Get-JsonProperty -Object $Tokens -Name 'input_tokens' -Default $null
    $outputCount = Get-JsonProperty -Object $Tokens -Name 'output_tokens' -Default $null
    if ((Test-TokenCount $inputCount) -and (Test-TokenCount $outputCount)) {
        # Cache reads and reasoning are subsets of these buckets, not additional tokens.
        $total = $inputCount + $outputCount
        if (Test-TokenCount $total) { return $total }
    }
    return $null
}

function Get-ArtifactPath {
    param(
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Artifact
    )

    $path = [string](Get-JsonProperty -Object $Artifact -Name 'path' -Default '')
    $scope = [string](Get-JsonProperty -Object $Artifact -Name 'scope' -Default '')
    if ($scope -eq 'run') {
        return Resolve-ContainedPath -BasePath $RunData.RunRoot -RelativePath $path -FieldName 'execution-result artifact.path' -Kind File
    }
    if ($scope -eq 'package') {
        return Resolve-ContainedPath -BasePath $IterationDirectory -RelativePath $path -FieldName 'execution-result package artifact.path' -Kind File
    }
    throw "Unsupported execution-result artifact scope '$scope'."
}

function Get-ResultRelativeArtifactPath {
    param(
        [Parameter(Mandatory = $true)][string]$EvalDirectory,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $relative = [System.IO.Path]::GetRelativePath($EvalDirectory, $FullPath).Replace('\', '/')
    Assert-SafeRelativePath -RelativePath $relative -FieldName 'result.output_files'
    return $relative
}

function Get-ExistingGrading {
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath
    )

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "Manifest-declared result stub '$ResultPath' does not exist; the bridge will not create a new grading-less result file."
    }

    $existing = Read-RunnerJson -Path $ResultPath
    if (-not (Test-JsonProperty -Object $existing -Name 'grading')) {
        throw "Manifest-declared result stub '$ResultPath' is missing its grading array."
    }
    return @(Get-JsonProperty -Object $existing -Name 'grading' -Default @())
}

try {
    $runData = Resolve-RunContract -RunPath $Run
    $runPath = $runData.RunPath
    $runDirectory = $runData.RunRoot
    $evalDirectory = Split-Path -Parent $runDirectory
    $iterationDirectory = Split-Path -Parent $evalDirectory
    # The bridge is a validator of frozen evidence, never an authority that
    # can bless a new raw hash. This call intentionally covers every manifest
    # arm before this one-arm operation can write a canonical result.
    [void](Assert-ExecutionFreeze -IterationDirectory $iterationDirectory -RequireOrchestrationState)
    $executionPath = (Resolve-Path -LiteralPath $ExecutionResult -ErrorAction Stop).Path
    $executionResultHash = Get-Sha256HexFromFile -Path $executionPath
    $resultPath = [System.IO.Path]::GetFullPath($Result, (Get-Location).Path)
    if (-not (Test-PathInside -BasePath $iterationDirectory -CandidatePath $executionPath)) {
        throw 'execution-result.json must remain inside the prepared iteration package.'
    }
    if (-not (Test-PathInside -BasePath $iterationDirectory -CandidatePath $resultPath)) {
        throw 'eval-result output must remain inside the prepared iteration package.'
    }

    $raw = Read-RunnerJson -Path $executionPath
    [void](Assert-ExecutionResult -Result $raw)
    if ([string]$raw.input.prompt_sha256 -ne $runData.PromptHash) {
        throw 'execution-result input.prompt_sha256 does not match prompt.md.'
    }
    if ([string]$raw.input.run_json_sha256 -ne (Get-Sha256HexFromFile -Path $runPath)) {
        throw 'execution-result input.run_json_sha256 does not match run.json.'
    }
    $profilePath = Join-Path $iterationDirectory 'execution-profile.json'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw 'Runner-aware package is missing execution-profile.json.'
    }
    $profile = Resolve-ExecutionProfile -ProfilePath $profilePath
    if ([string]$raw.input.profile_sha256 -ne $profile.Hash) {
        throw 'execution-result input.profile_sha256 does not match execution-profile.json.'
    }
    $rawRunnerName = [string](Get-JsonProperty -Object $raw.runner -Name 'name' -Default '')
    if ($rawRunnerName -ne [string]$profile.Profile.runner) {
        throw "execution-result runner '$rawRunnerName' does not match selected runner '$($profile.Profile.runner)'."
    }
    if ([int]$raw.run.eval_id -ne $runData.EvalId -or [string]$raw.run.configuration -ne $runData.Mode) {
        throw 'execution-result run identity does not match run.json.'
    }

    $artifactPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($artifact in @($raw.artifacts)) {
        $full = Get-ArtifactPath -RunData $runData -IterationDirectory $iterationDirectory -Artifact $artifact
        $expectedHash = [string](Get-JsonProperty -Object $artifact -Name 'sha256' -Default '')
        if ((Get-Sha256HexFromFile -Path $full) -ne $expectedHash) {
            throw "Artifact '$($artifact.path)' has a hash that does not match the recorded execution evidence."
        }
        $expectedSize = [int64](Get-JsonProperty -Object $artifact -Name 'size' -Default -1)
        if ((Get-Item -LiteralPath $full).Length -ne $expectedSize) {
            throw "Artifact '$($artifact.path)' has a size that does not match the recorded execution evidence."
        }
        $artifactPaths.Add((Get-ResultRelativeArtifactPath -EvalDirectory $evalDirectory -FullPath $full))
    }

    if ($RequireNativeDelegation) {
        if ([string]$raw.status -eq 'incompatible') {
            throw 'An incompatible native-worker arm is diagnostic only and cannot be bridged into a gradeable canonical result.'
        }
        $runnerDescriptor = Get-PackageRunnerDescriptor -RunnerName ([string]$profile.Profile.runner)
        [void](Assert-NativeWorkerTerminalEvidence `
            -ExecutionEvidence $raw `
            -Run $runData `
            -RequestedModel ([string]$profile.Profile.Model) `
            -ExpectedRunner ([string]$profile.Profile.runner) `
            -ExpectedMechanism ([string]$runnerDescriptor.delegation.mechanism))
        Assert-NativeTerminalCaptureArtifact -ExecutionResult $raw
    }

    $finalStatus = [string]$raw.final_response.status
    $output = if ($finalStatus -eq 'available') { [string]$raw.final_response.text } else { '' }
    $transcript = Get-PortableTranscript -Raw $raw -RunData $runData
    $transcriptMetricObject = Get-JsonProperty -Object $raw.telemetry -Name 'transcript' -Default $null
    $toolCallsValue = Get-MetricValue -Result $raw -Name 'tool_calls'
    $costValue = Get-MetricValue -Result $raw -Name 'cost'
    $tokenValue = Get-MetricValue -Result $raw -Name 'tokens'
    $evidence = Get-JsonProperty -Object $raw -Name 'evidence' -Default ([ordered]@{})
    $commands = @(Get-JsonProperty -Object $evidence -Name 'commands' -Default @())
    $files = @(Get-JsonProperty -Object $evidence -Name 'files' -Default @())
    $warnings = @((Get-JsonProperty -Object $raw -Name 'warnings' -Default @()) + (Get-JsonProperty -Object $raw -Name 'compatibility_deviations' -Default @()))
    $notes = [System.Collections.Generic.List[string]]::new()
    $notes.Add("execution_status=$($raw.status)")
    if ($finalStatus -eq 'unavailable') { $notes.Add("final_response_unavailable=$($raw.final_response.reason)") }
    foreach ($warning in $warnings) { if (-not [string]::IsNullOrWhiteSpace([string]$warning)) { $notes.Add([string]$warning) } }

    $existingCanonical = Read-RunnerJson -Path $resultPath
    $existingGrading = @(Get-ExistingGrading -ResultPath $resultPath)
    $caps = Get-JsonProperty -Object $raw.isolation -Name 'capabilities' -Default ([ordered]@{})
    $requestedModel = [string](Get-JsonProperty -Object $raw.requested -Name 'model' -Default '')
    $resolvedModelValue = Get-JsonProperty -Object $raw.resolved -Name 'model' -Default $null
    $resolvedModel = if ($null -eq $resolvedModelValue) { '' } else { [string]$resolvedModelValue }
    $resolutionStatus = [string](Get-JsonProperty -Object $raw.resolved -Name 'status' -Default 'unavailable')
    $resolutionReason = [string](Get-JsonProperty -Object $raw.resolved -Name 'reason' -Default '')
    $notes.Add("configuration_resolution=$resolutionStatus")
    $portableResult = [ordered]@{
        schema = (Get-RunnerSchemaNames).PortableResult
        skill_name = if ($runData.Mode -eq 'with_skill') { [string](Get-JsonProperty -Object $runData.Contract -Name 'skillName' -Default '') } else { '' }
        iteration = [int](Get-JsonProperty -Object $runData.Contract -Name 'iteration' -Default 0)
        eval_id = $runData.EvalId
        eval_name = $runData.EvalName
        configuration = $runData.Mode
        model = if ([string]::IsNullOrWhiteSpace($resolvedModel)) { $requestedModel } else { $resolvedModel }
        requested_model = $requestedModel
        resolved_model = $resolvedModel
        configuration_resolution_status = $resolutionStatus
        configuration_resolution_reason = $resolutionReason
        harness = "$(Get-JsonProperty -Object $raw.harness -Name 'name' -Default 'unknown') $(Get-JsonProperty -Object $raw.harness -Name 'version' -Default '')".Trim()
        executed_utc = [string]$raw.finished_utc
        output = $output
        output_files = @($artifactPaths | Sort-Object -Unique)
        transcript = $transcript
        shell_commands = @($commands)
        files_read = @(Get-JsonProperty -Object $evidence -Name 'files_read' -Default @())
        files_written = @(Get-JsonProperty -Object $evidence -Name 'files_written' -Default @())
        stdout = if (@($artifactPaths | Where-Object { $_ -match 'events\.jsonl$' }).Count -gt 0) { 'artifact: events.jsonl' } else { '' }
        stderr = if (@($artifactPaths | Where-Object { $_ -match 'stderr\.txt$' }).Count -gt 0) { 'artifact: stderr.txt' } else { '' }
        exit_status = Get-JsonProperty -Object $raw.exit -Name 'status' -Default $null
        duration_seconds = [double]$raw.duration_seconds
        total_tokens = Get-NormalizedTotalTokens -Tokens $tokenValue
        tool_calls = $toolCallsValue
        turns = Get-JsonProperty -Object $evidence -Name 'turns' -Default $null
        base_input_tokens = if ($null -ne $tokenValue) { Get-JsonProperty -Object $tokenValue -Name 'input_tokens' -Default (Get-JsonProperty -Object $tokenValue -Name 'input' -Default $null) } else { $null }
        output_tokens = if ($null -ne $tokenValue) { Get-JsonProperty -Object $tokenValue -Name 'output_tokens' -Default (Get-JsonProperty -Object $tokenValue -Name 'output' -Default $null) } else { $null }
        cache_read_tokens = if ($null -ne $tokenValue) { Get-JsonProperty -Object $tokenValue -Name 'cached_input_tokens' -Default (Get-JsonProperty -Object $tokenValue -Name 'cache_read' -Default $null) } else { $null }
        cache_write_tokens = if ($null -ne $tokenValue) { Get-JsonProperty -Object $tokenValue -Name 'cache_write_tokens' -Default (Get-JsonProperty -Object $tokenValue -Name 'cache_write' -Default $null) } else { $null }
        cache_write_1h_tokens = $null
        estimated_cost_usd = $costValue
        model_effort = [string](Get-JsonProperty -Object $raw.resolved -Name 'reasoning_effort' -Default '')
        isolation = [ordered]@{
            level = Get-JsonProperty -Object $raw.isolation -Name 'level' -Default 'unsupported'
            status = Get-JsonProperty -Object $raw.isolation -Name 'status' -Default 'unverified'
            hard_filesystem_confinement = Get-JsonProperty -Object $raw.isolation -Name 'hard_filesystem_confinement' -Default $false
            mechanisms = @(Get-JsonProperty -Object $raw.isolation -Name 'mechanisms' -Default @())
            fresh_context = Get-CapabilityBoolean (Get-JsonProperty -Object $caps -Name 'fresh_context' -Default $null)
            isolated_home = Get-CapabilityBoolean (Get-JsonProperty -Object $caps -Name 'isolated_home_config' -Default $null)
            isolated_cwd = Get-CapabilityBoolean (Get-JsonProperty -Object $caps -Name 'isolated_working_directory' -Default $null)
            filesystem_sandbox = Get-CapabilityBoolean (Get-JsonProperty -Object $caps -Name 'filesystem_confinement' -Default $null)
            candidate_skill_exposed = Get-CapabilityBoolean (Get-JsonProperty -Object $caps -Name 'candidate_skill_exposure' -Default $null)
            transcript_captured = if ($null -ne $transcriptMetricObject) { [string](Get-JsonProperty -Object $transcriptMetricObject -Name 'status' -Default '') -eq 'available' } else { $null }
        }
         execution_status = [string]$raw.status
         execution_run_id = [string]$raw.run_id
         execution_result_file = [System.IO.Path]::GetRelativePath($evalDirectory, $executionPath).Replace('\', '/')
         execution_result_sha256 = $executionResultHash
         grading = @($existingGrading)
         notes = [string]::Join("`n", @($notes))
     }

    # Re-bridging is idempotent only for the exact frozen raw result. Existing
    # grading is preserved, but canonical non-grading fields are never repaired
    # or accepted from an external writer.
    $existingRawHash = [string](Get-JsonProperty -Object $existingCanonical -Name 'execution_result_sha256' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($existingRawHash) -and $existingRawHash -ne $executionResultHash) {
        throw "Execution integrity failure: canonical result '$Result' refers to a different raw execution hash; refusing repair."
    }
    if (-not [string]::IsNullOrWhiteSpace($existingRawHash)) {
        $expectedFingerprint = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $portableResult -PropertyName 'grading')
        $actualFingerprint = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $existingCanonical -PropertyName 'grading')
        if ($actualFingerprint -ne $expectedFingerprint) {
            throw "Execution integrity failure: canonical non-grading fields changed for '$Result'; refusing repair."
        }
    } elseif ([string](Get-JsonProperty -Object $existingCanonical -Name 'execution_status' -Default '') -ne 'unrun') {
        throw "Execution integrity failure: canonical result '$Result' is neither a prepared stub nor the frozen bridged result; refusing repair."
    }
    Write-BridgeJson -Path $resultPath -Value $portableResult
    Write-RunnerJson -Value ([ordered]@{ schema = 'codebeltnet/agentic/eval-result-bridge/1'; result = [System.IO.Path]::GetRelativePath($iterationDirectory, $resultPath).Replace('\', '/'); execution_status = $raw.status }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
