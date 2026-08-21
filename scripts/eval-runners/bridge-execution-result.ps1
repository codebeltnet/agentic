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
    [string]$Result
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'runner-common.ps1')

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
    [System.IO.File]::WriteAllText($Path, ((ConvertTo-Json -InputObject $serializable -Depth 100) + [Environment]::NewLine), $utf8NoBom)
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
    param([Parameter(Mandatory = $true)][string]$ResultPath)

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        return @()
    }
    try {
        $existing = Read-RunnerJson -Path $ResultPath
        return @(Get-JsonProperty -Object $existing -Name 'grading' -Default @())
    } catch {
        return @()
    }
}

try {
    $runData = Resolve-RunContract -RunPath $Run
    $runPath = $runData.RunPath
    $runDirectory = $runData.RunRoot
    $evalDirectory = Split-Path -Parent $runDirectory
    $iterationDirectory = Split-Path -Parent $evalDirectory
    $executionPath = (Resolve-Path -LiteralPath $ExecutionResult -ErrorAction Stop).Path
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

    $finalStatus = [string]$raw.final_response.status
    $output = if ($finalStatus -eq 'available') { [string]$raw.final_response.text } else { '' }
    $transcript = ''
    $transcriptMetricObject = Get-JsonProperty -Object $raw.telemetry -Name 'transcript' -Default $null
    $transcriptMetric = Get-MetricValue -Result $raw -Name 'transcript'
    if ($null -ne $transcriptMetric) {
        $transcriptArtifact = [string](Get-JsonProperty -Object $transcriptMetric -Name 'artifact' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($transcriptArtifact)) {
            $transcript = "artifact: $transcriptArtifact"
        }
    }
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

    $existingGrading = @(Get-ExistingGrading -ResultPath $resultPath)
    $caps = Get-JsonProperty -Object $raw.isolation -Name 'capabilities' -Default ([ordered]@{})
    $requestedModel = [string](Get-JsonProperty -Object $raw.requested -Name 'model' -Default '')
    $requestedProvider = [string](Get-JsonProperty -Object $raw.requested -Name 'provider' -Default '')
    $resolvedModelValue = Get-JsonProperty -Object $raw.resolved -Name 'model' -Default $null
    $resolvedProviderValue = Get-JsonProperty -Object $raw.resolved -Name 'provider' -Default $null
    $resolvedModel = if ($null -eq $resolvedModelValue) { '' } else { [string]$resolvedModelValue }
    $resolvedProvider = if ($null -eq $resolvedProviderValue) { '' } else { [string]$resolvedProviderValue }
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
        provider = if ([string]::IsNullOrWhiteSpace($resolvedProvider)) { $requestedProvider } else { $resolvedProvider }
        requested_model = $requestedModel
        requested_provider = $requestedProvider
        resolved_model = $resolvedModel
        resolved_provider = $resolvedProvider
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
        total_tokens = if ($null -ne $tokenValue) { Get-JsonProperty -Object $tokenValue -Name 'total_tokens' -Default $null } else { $null }
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
        grading = @($existingGrading)
        notes = [string]::Join("`n", @($notes))
    }
    Write-BridgeJson -Path $resultPath -Value $portableResult
    Write-RunnerJson -Value ([ordered]@{ schema = 'codebeltnet/agentic/eval-result-bridge/1'; result = [System.IO.Path]::GetRelativePath($iterationDirectory, $resultPath).Replace('\', '/'); execution_status = $raw.status }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
