Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RunnerOwnedPhaseOnePaths {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)

    return [pscustomobject]@{
        Lock = Join-Path $IterationDirectory 'phase1-controller.lock'
        Ownership = Join-Path $IterationDirectory 'phase1-supervisor.json'
        Runtime = Join-Path $IterationDirectory 'phase1-supervisor-runtime.json'
        Result = Join-Path $IterationDirectory 'phase1-supervisor-result.json'
        FanoutInvocation = Join-Path $IterationDirectory 'phase1-fanout-invocation.json'
        Stdout = Join-Path $IterationDirectory 'phase1-supervisor.stdout.log'
        Stderr = Join-Path $IterationDirectory 'phase1-supervisor.stderr.log'
        BootstrapStdout = Join-Path $IterationDirectory 'phase1-supervisor.bootstrap.stdout.log'
        BootstrapStderr = Join-Path $IterationDirectory 'phase1-supervisor.bootstrap.stderr.log'
        OrchestrationState = Join-Path $IterationDirectory 'orchestration-state.json'
        Freeze = Join-Path $IterationDirectory 'execution-freeze.json'
    }
}

function Write-RunnerOwnedPhaseOneAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-RunnerOwnedPhaseOneProcessIdentity {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $startedUtc = $process.StartTime.ToUniversalTime()
    $executablePath = ''
    try { $executablePath = [System.IO.Path]::GetFullPath([string]$process.Path) } catch { }
    $identity = [pscustomobject]@{
        Pid = [int]$process.Id
        StartedUtc = $startedUtc
        StartedUtcText = $startedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        StartTicksUtc = $startedUtc.Ticks
        ExecutablePath = $executablePath
        ExecutableSha256 = if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { '' } else { Get-Sha256HexFromFile -Path $executablePath }
    }
    $process.Dispose()
    return $identity
}

function Assert-RunnerOwnedPhaseOneOwnershipRecord {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Ownership,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    if ([string](Get-JsonProperty -Object $Ownership -Name 'schema' -Default '') -ne 'codebeltnet/agentic/runner-owned-phase1-supervisor/1') {
        throw 'phase1-supervisor.json has an unsupported schema.'
    }
    $supervisorId = [string](Get-JsonProperty -Object $Ownership -Name 'supervisor_id' -Default '')
    if ($supervisorId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'phase1-supervisor.json has an invalid supervisor_id.' }
    $iterationIdentity = Get-JsonProperty -Object $Ownership -Name 'iteration' -Default $null
    $recordedIterationPath = [System.IO.Path]::GetFullPath([string](Get-JsonProperty -Object $iterationIdentity -Name 'path' -Default ''))
    if ($recordedIterationPath -ne [System.IO.Path]::GetFullPath($IterationDirectory)) {
        throw 'phase1-supervisor.json belongs to a different iteration directory.'
    }
    if ([string](Get-JsonProperty -Object $Ownership -Name 'manifest_sha256' -Default '') -ne (Get-Sha256HexFromFile -Path (Join-Path $IterationDirectory 'manifest.json'))) {
        throw 'manifest.json changed after Phase 1 supervisor ownership was created. Requires a fresh package.'
    }
    if ([string](Get-JsonProperty -Object $Ownership -Name 'profile_sha256' -Default '') -ne (Get-Sha256HexFromFile -Path $ProfilePath)) {
        throw 'execution-profile.json changed after Phase 1 supervisor ownership was created. Requires a fresh package.'
    }
    [void](Assert-PackageRunnerToolsIntegrity -IterationDirectory $IterationDirectory -Manifest $Manifest)
    foreach ($tool in @(
            [pscustomobject]@{ Field = 'internal_fanout'; Name = 'invoke-runner-owned-arms.ps1' },
            [pscustomobject]@{ Field = 'supervisor'; Name = 'supervise-runner-owned-phase1.ps1' },
            [pscustomobject]@{ Field = 'controller'; Name = 'control-runner-owned-phase1.ps1' }
        )) {
        $record = Get-JsonProperty -Object $Ownership -Name $tool.Field -Default $null
        $path = [string](Get-JsonProperty -Object $record -Name 'path' -Default '')
        $hash = [string](Get-JsonProperty -Object $record -Name 'sha256' -Default '')
        $expectedPath = Join-Path (Join-Path $IterationDirectory ([string]$Manifest.runner_tools)) $tool.Name
        if ([System.IO.Path]::GetFullPath($path) -ne [System.IO.Path]::GetFullPath($expectedPath) -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Sha256HexFromFile -Path $path) -ne $hash) {
            throw "Phase 1 control tool '$($tool.Name)' changed after supervisor ownership was created. Requires a fresh package."
        }
    }
    return $true
}

function Test-RunnerOwnedPhaseOneSupervisorAlive {
    param([Parameter(Mandatory = $true)][object]$Ownership)

    $pidValue = [int](Get-JsonProperty -Object $Ownership -Name 'pid' -Default 0)
    if ($pidValue -lt 1) { throw 'phase1-supervisor.json does not contain a valid supervisor PID.' }
    try {
        $identity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId $pidValue
    } catch {
        return $false
    }
    $expectedTicks = [int64](Get-JsonProperty -Object $Ownership -Name 'process_start_ticks_utc' -Default 0)
    if ($identity.StartTicksUtc -ne $expectedTicks) {
        throw "Supervisor PID $pidValue is alive but its process start identity differs; refusing PID reuse. Requires a fresh package."
    }
    $expectedExecutable = [string](Get-JsonProperty -Object $Ownership -Name 'process_executable' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($expectedExecutable) -and $identity.ExecutablePath -ne $expectedExecutable) {
        throw "Supervisor PID $pidValue is alive but its executable identity differs. Requires a fresh package."
    }
    $expectedExecutableHash = [string](Get-JsonProperty -Object $Ownership -Name 'process_executable_sha256' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($expectedExecutableHash) -and $identity.ExecutableSha256 -ne $expectedExecutableHash) {
        throw "Supervisor PID $pidValue is alive but its executable hash differs. Requires a fresh package."
    }
    return $true
}

function Assert-RunnerOwnedFanoutAuthorization {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [AllowNull()][AllowEmptyString()][string]$SupervisorId
    )

    if ([string]::IsNullOrWhiteSpace($SupervisorId)) { throw 'Direct runner-owned fan-out invocation is forbidden. Use control-runner-owned-phase1.ps1.' }
    $paths = Get-RunnerOwnedPhaseOnePaths -IterationDirectory $IterationDirectory
    if (-not (Test-Path -LiteralPath $paths.Ownership -PathType Leaf) -or -not (Test-Path -LiteralPath $paths.Runtime -PathType Leaf)) {
        throw 'Runner-owned fan-out requires a valid durable Phase 1 supervisor ownership/runtime record. Use control-runner-owned-phase1.ps1.'
    }
    $ownership = Read-RunnerJson -Path $paths.Ownership
    $runtime = Read-RunnerJson -Path $paths.Runtime
    if ([string](Get-JsonProperty -Object $runtime -Name 'schema' -Default '') -ne 'codebeltnet/agentic/runner-owned-phase1-supervisor-runtime/1') {
        throw 'Runner-owned fan-out requires a valid Phase 1 supervisor runtime record.'
    }
    if ([string]$ownership.supervisor_id -ne $SupervisorId -or [string]$runtime.supervisor_id -ne $SupervisorId) {
        throw 'Runner-owned fan-out supervisor identity does not match the durable ownership record.'
    }
    if ([int]$runtime.pid -ne [int]$ownership.pid -or [int64]$runtime.process_start_ticks_utc -ne [int64]$ownership.process_start_ticks_utc) {
        throw 'Runner-owned fan-out runtime process identity does not match the durable ownership record.'
    }
    $manifestPath = Join-Path $IterationDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Runner-owned fan-out requires manifest.json.' }
    $manifest = Read-RunnerJson -Path $manifestPath
    $profileRelativePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_profile' -Default 'execution-profile.json')
    Assert-SafeRelativePath -RelativePath $profileRelativePath -FieldName 'manifest.execution_profile'
    [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $IterationDirectory -Ownership $ownership -Manifest $manifest -ProfilePath (Join-Path $IterationDirectory $profileRelativePath))
    $environmentId = [Environment]::GetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_ID')
    $environmentPid = [Environment]::GetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_PID')
    $environmentStartTicks = [Environment]::GetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_START_TICKS')
    if ($environmentId -ne $SupervisorId -or $environmentPid -ne [string]$ownership.pid -or $environmentStartTicks -ne [string]$ownership.process_start_ticks_utc) {
        throw 'Runner-owned fan-out was not launched by its recorded durable Phase 1 supervisor.'
    }
    if (-not (Test-RunnerOwnedPhaseOneSupervisorAlive -Ownership $ownership)) {
        throw 'The recorded durable Phase 1 supervisor is not alive; runner-owned fan-out cannot start.'
    }
    return $true
}
