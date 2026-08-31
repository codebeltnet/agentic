<#!
.SYNOPSIS
    Owns one durable runner-owned Phase 1 fan-out lifetime.

.DESCRIPTION
    This internal wrapper is started only by control-runner-owned-phase1.ps1.
    It stays alive until the existing fan-out process exits, captures the
    fan-out control streams in package-local files, and atomically records one
    terminal supervisor result. It does not author execution evidence,
    orchestration state, or the execution freeze itself.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [Parameter(Mandatory = $true)][string]$SupervisorId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'package-integrity.ps1')
. (Join-Path $PSScriptRoot 'phase1-control-common.ps1')

$paths = Get-RunnerOwnedPhaseOnePaths -IterationDirectory $iteration
$startedUtc = [DateTime]::UtcNow
$ownership = $null
$fanoutExitCode = $null
$fanoutSummary = $null
$failure = ''

try {
    $ownership = $null
    $ownershipDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $ownershipDeadline) {
        if (Test-Path -LiteralPath $paths.Ownership -PathType Leaf) {
            $candidate = $null
            try { $candidate = Read-RunnerJson -Path $paths.Ownership } catch { }
            if ($null -ne $candidate -and [string](Get-JsonProperty -Object $candidate -Name 'supervisor_id' -Default '') -eq $SupervisorId -and [int](Get-JsonProperty -Object $candidate -Name 'pid' -Default 0) -eq $PID) {
                $ownershipState = Get-RunnerOwnedPhaseOneOwnershipState -Ownership $candidate
                if ($ownershipState -eq 'failed') { throw (Get-RunnerOwnedPhaseOneOwnershipFailure -Ownership $candidate) }
                if ($ownershipState -eq 'committed') {
                    $ownership = $candidate
                    break
                }
            }
        }
        Start-Sleep -Milliseconds 25
    }
    if ($null -eq $ownership) { throw 'The controller did not publish the complete Phase 1 supervisor ownership record.' }

    $manifestPath = Join-Path $iteration 'manifest.json'
    $manifest = Read-RunnerJson -Path $manifestPath
    $profilePath = Resolve-ContainedPath -BasePath $iteration -RelativePath ([string]$manifest.execution_profile) -FieldName 'execution_profile' -Kind File
    [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $iteration -Ownership $ownership -Manifest $manifest -ProfilePath $profilePath)
    $identity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId $PID
    if ($identity.StartTicksUtc -ne [int64]$ownership.process_start_ticks_utc) { throw 'The running supervisor process identity does not match its ownership record.' }

    Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Runtime -Value ([ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-phase1-supervisor-runtime/1'
        supervisor_id = $SupervisorId
        pid = $PID
        process_started_utc = [string]$ownership.process_started_utc
        process_start_ticks_utc = [int64]$ownership.process_start_ticks_utc
        started_utc = $startedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        heartbeat_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        phase = 'preflight'
    })

    if (Test-Path -LiteralPath $paths.FanoutInvocation -PathType Leaf) {
        throw 'The durable Phase 1 supervisor refuses a second internal fan-out invocation.'
    }
    Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.FanoutInvocation -Value ([ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-phase1-fanout-invocation/1'
        supervisor_id = $SupervisorId
        supervisor_pid = $PID
        started_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        invocation_count = 1
        fanout_path = [string]$ownership.internal_fanout.path
        fanout_sha256 = [string]$ownership.internal_fanout.sha256
    })

    [Environment]::SetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_ID', $SupervisorId)
    [Environment]::SetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_PID', [string]$PID)
    [Environment]::SetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_START_TICKS', [string]$ownership.process_start_ticks_utc)
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    & $pwshPath -NoProfile -NonInteractive -File ([string]$ownership.internal_fanout.path) -IterationDirectory $iteration -SupervisorId $SupervisorId 1> $paths.Stdout 2> $paths.Stderr
    $fanoutExitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $paths.Stdout -PathType Leaf) {
        $fanoutText = [System.IO.File]::ReadAllText($paths.Stdout, [System.Text.UTF8Encoding]::new($false))
        if (-not [string]::IsNullOrWhiteSpace($fanoutText)) { $fanoutSummary = $fanoutText | ConvertFrom-Json -Depth 100 }
    }
    if ($null -eq $fanoutSummary) { throw 'Runner-owned fan-out did not produce its machine-readable Phase 1 summary.' }
} catch {
    $failure = $_.Exception.Message
} finally {
    $finishedUtc = [DateTime]::UtcNow
    $resultStatus = if ([string]::IsNullOrWhiteSpace($failure) -and $null -ne $fanoutExitCode -and [int]$fanoutExitCode -eq 0 -and $null -ne $fanoutSummary -and [string](Get-JsonProperty -Object $fanoutSummary -Name 'status' -Default '') -eq 'completed') { 'completed' } else { 'failed' }
    $result = [ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-phase1-supervisor-result/1'
        supervisor_id = $SupervisorId
        supervisor_pid = $PID
        process_started_utc = if ($null -ne $ownership) { [string]$ownership.process_started_utc } else { $null }
        process_start_ticks_utc = if ($null -ne $ownership) { [int64]$ownership.process_start_ticks_utc } else { 0 }
        started_utc = $startedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        finished_utc = $finishedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        status = $resultStatus
        fanout_invocation_count = if (Test-Path -LiteralPath $paths.FanoutInvocation -PathType Leaf) { 1 } else { 0 }
        fanout_exit_code = $fanoutExitCode
        fanout_path = if ($null -ne $ownership) { [string]$ownership.internal_fanout.path } else { Join-Path $PSScriptRoot 'invoke-runner-owned-arms.ps1' }
        fanout_sha256 = if ($null -ne $ownership) { [string]$ownership.internal_fanout.sha256 } else { $null }
        stdout_path = [System.IO.Path]::GetRelativePath($iteration, $paths.Stdout).Replace('\', '/')
        stderr_path = [System.IO.Path]::GetRelativePath($iteration, $paths.Stderr).Replace('\', '/')
        final_result_path = [System.IO.Path]::GetRelativePath($iteration, $paths.Result).Replace('\', '/')
        fanout_summary = $fanoutSummary
        error = if ([string]::IsNullOrWhiteSpace($failure)) { $null } else { $failure }
    }
    Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Result -Value $result
}

exit $(if ((Read-RunnerJson -Path $paths.Result).status -eq 'completed') { 0 } else { 2 })
