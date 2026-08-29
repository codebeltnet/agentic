<#!
.SYNOPSIS
    Shared immutable raw-evidence freeze and validation helpers.

.DESCRIPTION
    The freeze is created only after every Phase 1 arm has a terminal,
    runner-produced result.  It records the exact manifest destinations and
    hashes of those results and every raw artifact they reference.  Later
    bridge, grading, and reporting operations validate this ledger; none of
    them can replace it when a file changes.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-RunnerSchemaNames -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'runner-common.ps1')
}
if (-not (Get-Command Get-ManifestRunRecords -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'manifest-paths.ps1')
}

function Get-ExecutionFreezePath {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [string]$RelativePath = 'execution-freeze.json'
    )

    Assert-SafeRelativePath -RelativePath $RelativePath -FieldName 'execution freeze path'
    return [System.IO.Path]::GetFullPath((Join-Path ((Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path) ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
}

function Get-FreezeArmKey {
    param([Parameter(Mandatory = $true)][object]$Record)

    return ('arm-{0}-{1}' -f [int]$Record.EvalId, [string]$Record.Configuration)
}

function Resolve-FreezeArtifactPath {
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

function Get-FreezeObservedModel {
    param([Parameter(Mandatory = $true)][object]$ExecutionResult)

    $delegation = Get-JsonProperty -Object $ExecutionResult.evidence -Name 'delegation' -Default $null
    $observed = Get-JsonProperty -Object $delegation -Name 'observed_model' -Default $null
    if ($null -ne $observed -and -not [string]::IsNullOrWhiteSpace([string]$observed)) {
        return [string]$observed
    }
    $resolved = Get-JsonProperty -Object $ExecutionResult.resolved -Name 'model' -Default $null
    if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace([string]$resolved)) {
        return [string]$resolved
    }
    return $null
}

function Get-FreezeThreadId {
    param([Parameter(Mandatory = $true)][object]$ExecutionResult)

    $delegation = Get-JsonProperty -Object $ExecutionResult.evidence -Name 'delegation' -Default $null
    foreach ($name in @('thread_id', 'thread_session_id', 'session_id')) {
        $value = Get-JsonProperty -Object $delegation -Name $name -Default $null
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    return $null
}

function New-FreezeArtifactEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Artifact,
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$IterationDirectory
    )

    $path = [string](Get-JsonProperty -Object $Artifact -Name 'path' -Default '')
    $scope = [string](Get-JsonProperty -Object $Artifact -Name 'scope' -Default '')
    $fullPath = Resolve-FreezeArtifactPath -RunData $RunData -IterationDirectory $IterationDirectory -Artifact $Artifact
    $actualHash = Get-Sha256HexFromFile -Path $fullPath
    $recordedHash = [string](Get-JsonProperty -Object $Artifact -Name 'sha256' -Default '')
    if ($actualHash -ne $recordedHash) {
        throw "Execution integrity failure: raw artifact '${scope}:${path}' does not match the hash in execution-result.json."
    }
    $actualSize = [int64](Get-Item -LiteralPath $fullPath).Length
    $recordedSize = [int64](Get-JsonProperty -Object $Artifact -Name 'size' -Default -1)
    if ($actualSize -ne $recordedSize) {
        throw "Execution integrity failure: raw artifact '${scope}:${path}' does not match the size in execution-result.json."
    }

    return [ordered]@{
        scope = $scope
        path = $path
        sha256 = $actualHash
        size = $actualSize
        media_type = [string](Get-JsonProperty -Object $Artifact -Name 'media_type' -Default '')
    }
}

function Assert-FreezeTerminalLedgerEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][object]$Raw,
        [AllowNull()][object]$State
    )

    if ($null -eq $State) { return $true }
    $completed = Get-JsonProperty -Object $State -Name 'completed' -Default $null
    if ($null -eq $completed) { return $true }
    $workerId = Get-FreezeArmKey -Record $Record
    if (-not (Test-JsonProperty -Object $completed -Name $workerId)) {
        throw "Execution integrity failure: orchestration terminal ledger is missing '$workerId'."
    }
    $terminal = Get-JsonProperty -Object $completed -Name $workerId -Default $null
    if ([string](Get-JsonProperty -Object $terminal -Name 'worker_id' -Default '') -ne $workerId -or
        [int](Get-JsonProperty -Object $terminal -Name 'eval_id' -Default 0) -ne [int]$Record.EvalId -or
        [string](Get-JsonProperty -Object $terminal -Name 'configuration' -Default '') -ne [string]$Record.Configuration) {
        throw "Execution integrity failure: orchestration terminal ledger identity for '$workerId' does not match the manifest arm."
    }
    if ([string](Get-JsonProperty -Object $terminal -Name 'status' -Default '') -ne [string]$Raw.status) {
        throw "Execution integrity failure: orchestration terminal ledger status for '$workerId' does not match its frozen raw result."
    }
    $ledgerSession = [string](Get-JsonProperty -Object $terminal -Name 'worker_session_id' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($ledgerSession) -and $ledgerSession -ne [string]$Raw.session.id) {
        throw "Execution integrity failure: orchestration terminal ledger session for '$workerId' does not match its frozen raw result."
    }
    return $true
}

function Get-OrchestrationCompletedEntries {
    param([AllowNull()][object]$State)

    if ($null -eq $State) { return @() }
    $completed = Get-JsonProperty -Object $State -Name 'completed' -Default $null
    if ($null -eq $completed) { return @() }

    return @((Get-JsonPropertyNames -Object $completed | Sort-Object) | ForEach-Object {
        $entry = Get-JsonProperty -Object $completed -Name ([string]$_) -Default $null
        if ($null -ne $entry) { $entry }
    })
}

function Test-FanoutPhase1Success {
    param([Parameter(Mandatory = $true)][object]$Aggregate)

    return (
        [int](Get-JsonProperty -Object $Aggregate -Name 'terminal_count' -Default 0) -eq [int](Get-JsonProperty -Object $Aggregate -Name 'expected_count' -Default 0) -and
        [int](Get-JsonProperty -Object $Aggregate -Name 'completed_count' -Default 0) -eq [int](Get-JsonProperty -Object $Aggregate -Name 'expected_count' -Default 0) -and
        [int](Get-JsonProperty -Object $Aggregate -Name 'failed_count' -Default 0) -eq 0 -and
        [int](Get-JsonProperty -Object $Aggregate -Name 'timed_out_count' -Default 0) -eq 0 -and
        [int](Get-JsonProperty -Object $Aggregate -Name 'cancelled_count' -Default 0) -eq 0 -and
        [int](Get-JsonProperty -Object $Aggregate -Name 'incompatible_count' -Default 0) -eq 0 -and
        [int](Get-JsonProperty -Object $Aggregate -Name 'evidence_validation_failed_count' -Default 0) -eq 0
    )
}

function Get-FanoutPhase1Aggregate {
    param(
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [AllowNull()][object]$State
    )

    $entries = @(Get-OrchestrationCompletedEntries -State $State)
    $aggregate = [ordered]@{
        expected_count = $ExpectedCount
        terminal_count = $entries.Count
        completed_count = @($entries | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'completed' }).Count
        failed_count = @($entries | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'failed' }).Count
        timed_out_count = @($entries | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'timed_out' }).Count
        cancelled_count = @($entries | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'cancelled' }).Count
        incompatible_count = @($entries | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'incompatible' }).Count
        evidence_validation_failed_count = @($entries | Where-Object {
                [string](Get-JsonProperty -Object (Get-JsonProperty -Object $_ -Name 'evidence_validation' -Default $null) -Name 'status' -Default '') -ne 'passed'
            }).Count
    }
    $aggregate.status = if (Test-FanoutPhase1Success -Aggregate $aggregate) { 'completed' } else { 'failed' }
    return $aggregate
}

function Format-FanoutPhase1Aggregate {
    param([Parameter(Mandatory = $true)][object]$Aggregate)

    $orderedFields = @(
        'expected_count',
        'terminal_count',
        'completed_count',
        'failed_count',
        'timed_out_count',
        'cancelled_count',
        'incompatible_count',
        'evidence_validation_failed_count'
    )
    return [string]::Join(', ', @($orderedFields | ForEach-Object {
                "$_=$(Get-JsonProperty -Object $Aggregate -Name $_ -Default 0)"
            }))
}

function Assert-FanoutPhase1Success {
    param(
        [Parameter(Mandatory = $true)][object]$Aggregate,
        [string]$MessagePrefix = 'Phase 1'
    )

    if (-not (Test-FanoutPhase1Success -Aggregate $Aggregate)) {
        throw "$MessagePrefix completion gate failed: $(Format-FanoutPhase1Aggregate -Aggregate $Aggregate)."
    }
    return $true
}

function New-ExecutionFreezeDocument {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][object]$Profile
    )

    $iterationPath = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $manifestRecords = @(Get-ManifestRunRecords -IterationDirectory $iterationPath -Manifest $Manifest)
    if ($manifestRecords.Count -ne $Records.Count) {
        throw "Execution freeze received $($Records.Count) records, but manifest.json declares $($manifestRecords.Count) arms."
    }

    $statePath = Join-Path $iterationPath 'orchestration-state.json'
    $state = if (Test-Path -LiteralPath $statePath -PathType Leaf) { Read-RunnerJson -Path $statePath } else { $null }
    $orchestrationStateHash = if ($null -eq $state) {
        $null
    } else {
        # The state receives the freeze reference only after this document is
        # written. Hash every other state field now so the terminal ledger and
        # concurrency evidence cannot be hand-edited after Phase 1.
        Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $state -PropertyName 'execution_freeze')
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($manifestRecords | Sort-Object EvalId, Configuration)) {
        $executionPath = [string]$record.ExecutionResultPath
        if (-not (Test-Path -LiteralPath $executionPath -PathType Leaf)) {
            throw "Execution freeze cannot be created because '$($record.ExecutionResultRelative)' is missing."
        }
        $runData = Resolve-RunContract -RunPath $record.RunManifestPath
        $raw = Read-RunnerJson -Path $executionPath
        [void](Assert-ExecutionResult -Result $raw)
        if ([int]$raw.run.eval_id -ne [int]$record.EvalId -or
            [string]$raw.run.eval_name -ne [string]$record.EvalName -or
            [string]$raw.run.configuration -ne [string]$record.Configuration) {
            throw "Execution integrity failure: '$($record.ExecutionResultRelative)' does not identify its exact manifest arm."
        }
        if ([string]$raw.input.prompt_sha256 -ne [string]$runData.PromptHash -or
            [string]$raw.input.run_json_sha256 -ne (Get-Sha256HexFromFile -Path $runData.RunPath) -or
            [string]$raw.input.profile_sha256 -ne [string]$Profile.Hash) {
            throw "Execution integrity failure: '$($record.ExecutionResultRelative)' has an input hash that does not match its prepared run or profile."
        }
        [void](Assert-InteractionResultEvidence -ExecutionResult $raw -RunData $runData)
        [void](Assert-FreezeTerminalLedgerEntry -Record $record -Raw $raw -State $state)

        $artifacts = [System.Collections.Generic.List[object]]::new()
        foreach ($artifact in @($raw.artifacts | Sort-Object @{ Expression = { [string]$_.scope } }, @{ Expression = { [string]$_.path } })) {
            $artifacts.Add((New-FreezeArtifactEntry -Artifact $artifact -RunData $runData -IterationDirectory $iterationPath))
        }
        $runner = Get-JsonProperty -Object $raw -Name 'runner' -Default $null
        $harness = Get-JsonProperty -Object $raw -Name 'harness' -Default $null
        $entries.Add([ordered]@{
            worker_id = Get-FreezeArmKey -Record $record
            eval_id = [int]$record.EvalId
            eval_name = [string]$record.EvalName
            configuration = [string]$record.Configuration
            run_id = [string]$raw.run_id
            run_manifest = [string]$record.RunManifestRelative
            execution_result = [string]$record.ExecutionResultRelative
            execution_result_sha256 = Get-Sha256HexFromFile -Path $executionPath
            raw_artifacts = @($artifacts.ToArray())
            runner = [ordered]@{ name = [string]$runner.name; version = [string]$runner.version }
            harness = [ordered]@{ name = [string]$harness.name; version = [string]$harness.version }
            requested_model = [string](Get-JsonProperty -Object $raw.requested -Name 'model' -Default '')
            observed_model = Get-FreezeObservedModel -ExecutionResult $raw
            resolved_model = Get-JsonProperty -Object $raw.resolved -Name 'model' -Default $null
            session_id = [string]$raw.session.id
            thread_id = Get-FreezeThreadId -ExecutionResult $raw
            terminal_status = [string]$raw.status
            finished_utc = [string]$raw.finished_utc
        })
    }

    $schemas = Get-RunnerSchemaNames
    return [ordered]@{
        schema = $schemas.ExecutionFreeze
        version = 1
        generated_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow)
        manifest_schema = [string](Get-JsonProperty -Object $Manifest -Name 'schema' -Default '')
        profile_sha256 = [string]$Profile.Hash
        runner = [string]$Profile.Runner
        model = [string]$Profile.Model
        orchestration_state_sha256 = $orchestrationStateHash
        executions = @($entries.ToArray())
    }
}

function Write-ExecutionFreezeDocument {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Freeze,
        [string]$RelativePath = 'execution-freeze.json'
    )

    $freezePath = Get-ExecutionFreezePath -IterationDirectory $IterationDirectory -RelativePath $RelativePath
    if (Test-Path -LiteralPath $freezePath -PathType Leaf) {
        throw "Execution freeze already exists at '$freezePath'; a second freeze would re-bless a new raw-evidence state."
    }
    $schemas = Get-RunnerSchemaNames
    if ([string]$Freeze.schema -ne $schemas.ExecutionFreeze -or [int]$Freeze.version -ne 1) {
        throw 'Execution freeze has an unsupported schema or version.'
    }
    [System.IO.File]::WriteAllText($freezePath, (($Freeze | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    return $freezePath
}

function Get-FreezeEntryMap {
    param([Parameter(Mandatory = $true)][object]$Freeze)

    $map = @{}
    $previousEvalId = -1
    $previousConfiguration = ''
    foreach ($entry in @($Freeze.executions)) {
        $evalId = [int](Get-JsonProperty -Object $entry -Name 'eval_id' -Default 0)
        $configuration = [string](Get-JsonProperty -Object $entry -Name 'configuration' -Default '')
        $key = "$evalId|$configuration"
        if ($map.ContainsKey($key)) { throw "Execution freeze contains duplicate arm '$key'." }
        if ($evalId -lt $previousEvalId -or ($evalId -eq $previousEvalId -and [string]::CompareOrdinal($previousConfiguration, $configuration) -gt 0)) {
            throw 'Execution freeze executions must be in deterministic eval_id/configuration order.'
        }
        $previousEvalId = $evalId
        $previousConfiguration = $configuration
        $map[$key] = $entry
    }
    return $map
}

function Assert-ExecutionFreeze {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [string]$RelativePath = 'execution-freeze.json',
        [switch]$RequireOrchestrationState
    )

    $iterationPath = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $manifestPath = Join-Path $iterationPath 'manifest.json'
    $profilePath = Join-Path $iterationPath 'execution-profile.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Execution integrity failure: manifest.json is missing.' }
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw 'Execution integrity failure: execution-profile.json is missing.' }
    $manifest = Read-RunnerJson -Path $manifestPath
    $declaredFreezePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_freeze' -Default '')
    if ([string]::IsNullOrWhiteSpace($declaredFreezePath)) { throw 'Execution integrity failure: manifest.json does not declare execution_freeze.' }
    if ($declaredFreezePath -ne $RelativePath) {
        throw "Execution integrity failure: requested freeze path '$RelativePath' does not match manifest.execution_freeze '$declaredFreezePath'."
    }
    $profile = Resolve-ExecutionProfile -ProfilePath $profilePath
    $freezePath = Get-ExecutionFreezePath -IterationDirectory $iterationPath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $freezePath -PathType Leaf)) {
        throw "Execution integrity failure: frozen raw evidence is missing at '$RelativePath'; Phase 1 must be rerun."
    }
    $freeze = Read-RunnerJson -Path $freezePath
    $schemas = Get-RunnerSchemaNames
    if ([string]$freeze.schema -ne $schemas.ExecutionFreeze -or [int]$freeze.version -ne 1) {
        throw 'Execution integrity failure: execution-freeze.json has an unsupported schema or version.'
    }
    if ([string]$freeze.manifest_schema -ne [string](Get-JsonProperty -Object $manifest -Name 'schema' -Default '') -or
        [string]$freeze.profile_sha256 -ne [string]$profile.Hash -or [string]$freeze.runner -ne [string]$profile.Runner -or [string]$freeze.model -ne [string]$profile.Model) {
        throw 'Execution integrity failure: execution-freeze.json does not match the selected execution profile.'
    }

    $statePath = Join-Path $iterationPath 'orchestration-state.json'
    $state = $null
    if ($RequireOrchestrationState -and -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Execution integrity failure: orchestration-state.json is missing; the Phase 1 terminal ledger is incomplete.'
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Read-RunnerJson -Path $statePath
        $freezeRef = Get-JsonProperty -Object $state -Name 'execution_freeze' -Default $null
        if ($null -eq $freezeRef) {
            throw 'Execution integrity failure: orchestration-state.json does not reference execution-freeze.json.'
        }
        $declaredPath = [string](Get-JsonProperty -Object $freezeRef -Name 'path' -Default '')
        $declaredHash = [string](Get-JsonProperty -Object $freezeRef -Name 'sha256' -Default '')
        if ($declaredPath -ne $RelativePath -or $declaredHash -ne (Get-Sha256HexFromFile -Path $freezePath)) {
            throw 'Execution integrity failure: execution-freeze.json does not match the immutable orchestration-state reference.'
        }
        $frozenStateHash = [string](Get-JsonProperty -Object $freeze -Name 'orchestration_state_sha256' -Default '')
        if (-not (Test-Sha256 -Value $frozenStateHash)) {
            throw 'Execution integrity failure: execution-freeze.json is missing the orchestration-state integrity hash.'
        }
        $currentStateHash = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $state -PropertyName 'execution_freeze')
        if ($currentStateHash -ne $frozenStateHash) {
            throw 'Execution integrity failure: orchestration-state.json changed after the Phase 1 freeze; requires fresh Phase 1 execution.'
        }
    }

    $records = @(Get-ManifestRunRecords -IterationDirectory $iterationPath -Manifest $manifest | Sort-Object EvalId, Configuration)
    $entryMap = Get-FreezeEntryMap -Freeze $freeze
    if ($entryMap.Count -ne $records.Count) {
        throw "Execution integrity failure: frozen arm count $($entryMap.Count) does not match manifest arm count $($records.Count)."
    }
    foreach ($record in $records) {
        $key = "$($record.EvalId)|$($record.Configuration)"
        if (-not $entryMap.ContainsKey($key)) {
            throw "Execution integrity failure: execution-freeze.json is missing manifest arm '$($record.EvalName)/$($record.Configuration)'."
        }
        $entry = $entryMap[$key]
        $workerId = Get-FreezeArmKey -Record $record
        foreach ($field in @('worker_id', 'eval_id', 'eval_name', 'configuration', 'run_manifest', 'execution_result', 'execution_result_sha256', 'runner', 'harness', 'requested_model', 'session_id', 'terminal_status', 'finished_utc')) {
            if (-not (Test-JsonProperty -Object $entry -Name $field)) { throw "Execution integrity failure: frozen arm '$workerId' is missing '$field'." }
        }
        if ([string]$entry.worker_id -ne $workerId -or [int]$entry.eval_id -ne [int]$record.EvalId -or
            [string]$entry.eval_name -ne [string]$record.EvalName -or [string]$entry.configuration -ne [string]$record.Configuration -or
            [string]$entry.run_manifest -ne [string]$record.RunManifestRelative -or [string]$entry.execution_result -ne [string]$record.ExecutionResultRelative) {
            throw "Execution integrity failure: frozen worker identity for '$workerId' does not match manifest-declared paths."
        }

        $runData = Resolve-RunContract -RunPath $record.RunManifestPath
        $executionPath = Resolve-ManifestDeclaredPath -IterationDirectory $iterationPath -RelativePath $record.ExecutionResultRelative -FieldName "$workerId.execution_result" -Kind File -RequireExists
        $currentHash = Get-Sha256HexFromFile -Path $executionPath
        if ($currentHash -ne [string]$entry.execution_result_sha256) {
            throw "Execution integrity failure: frozen raw execution result changed for $workerId (expected $($entry.execution_result_sha256), found $currentHash); requires fresh Phase 1 execution."
        }
        $raw = Read-RunnerJson -Path $executionPath
        [void](Assert-ExecutionResult -Result $raw)
        [void](Assert-InteractionResultEvidence -ExecutionResult $raw -RunData $runData)
        [void](Assert-FreezeTerminalLedgerEntry -Record $record -Raw $raw -State $state)
        if ([string](Get-JsonProperty -Object $entry.runner -Name 'name' -Default '') -ne [string]$raw.runner.name -or
            [string](Get-JsonProperty -Object $entry.runner -Name 'version' -Default '') -ne [string]$raw.runner.version -or
            [string](Get-JsonProperty -Object $entry.harness -Name 'name' -Default '') -ne [string]$raw.harness.name -or
            [string](Get-JsonProperty -Object $entry.harness -Name 'version' -Default '') -ne [string]$raw.harness.version -or
            [string]$entry.requested_model -ne [string]$raw.requested.model -or
            [string]$entry.observed_model -ne [string](Get-FreezeObservedModel -ExecutionResult $raw) -or
            [string]$entry.resolved_model -ne [string](Get-JsonProperty -Object $raw.resolved -Name 'model' -Default $null) -or
            [string]$entry.thread_id -ne [string](Get-FreezeThreadId -ExecutionResult $raw)) {
            throw "Execution integrity failure: frozen transport identity changed for $workerId; requires fresh Phase 1 execution."
        }
        if ([string]$raw.run_id -ne [string]$entry.run_id -or [string]$raw.session.id -ne [string]$entry.session_id -or
            [string]$raw.finished_utc -ne [string]$entry.finished_utc -or [string]$raw.status -ne [string]$entry.terminal_status) {
            throw "Execution integrity failure: frozen terminal identity changed for $workerId; requires fresh Phase 1 execution."
        }
        $artifactMap = @{}
        foreach ($artifact in @($entry.raw_artifacts)) {
            $artifactKey = "$(Get-JsonProperty -Object $artifact -Name 'scope' -Default '')|$(Get-JsonProperty -Object $artifact -Name 'path' -Default '')"
            if ($artifactMap.ContainsKey($artifactKey)) { throw "Execution integrity failure: frozen arm '$workerId' contains duplicate raw artifact '$artifactKey'." }
            $artifactMap[$artifactKey] = $artifact
        }
        $currentArtifacts = @($raw.artifacts)
        if ($artifactMap.Count -ne $currentArtifacts.Count) {
            throw "Execution integrity failure: raw artifact references changed for $workerId; requires fresh Phase 1 execution."
        }
        foreach ($artifact in $currentArtifacts) {
            $artifactKey = "$(Get-JsonProperty -Object $artifact -Name 'scope' -Default '')|$(Get-JsonProperty -Object $artifact -Name 'path' -Default '')"
            if (-not $artifactMap.ContainsKey($artifactKey)) { throw "Execution integrity failure: raw artifact references changed for $workerId; requires fresh Phase 1 execution." }
            $frozenArtifact = $artifactMap[$artifactKey]
            $fullPath = Resolve-FreezeArtifactPath -RunData $runData -IterationDirectory $iterationPath -Artifact $artifact
            $currentArtifactHash = Get-Sha256HexFromFile -Path $fullPath
            if ($currentArtifactHash -ne [string]$frozenArtifact.sha256) {
                throw "Execution integrity failure: frozen raw artifact changed for $workerId at '$($artifact.path)' (expected $($frozenArtifact.sha256), found $currentArtifactHash); requires fresh Phase 1 execution."
            }
            if ($currentArtifactHash -ne [string]$artifact.sha256 -or [int64](Get-Item -LiteralPath $fullPath).Length -ne [int64]$frozenArtifact.size) {
                throw "Execution integrity failure: raw artifact record changed for $workerId at '$($artifact.path)'; requires fresh Phase 1 execution."
            }
        }
    }
    $aggregate = if ($null -eq $state) {
        $null
    } else {
        Get-FanoutPhase1Aggregate -ExpectedCount $records.Count -State $state
    }

    return [pscustomobject]@{
        Path = $freezePath
        Freeze = $freeze
        Manifest = $manifest
        Profile = $profile
        Records = $records
        State = $state
        Aggregate = $aggregate
        PhaseOneSuccess = if ($null -eq $aggregate) { $null } else { Test-FanoutPhase1Success -Aggregate $aggregate }
    }
}
