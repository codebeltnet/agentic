<#!
.SYNOPSIS
    OpenCode Eval Runner adapter.

.DESCRIPTION
    This is the only place where OpenCode CLI flags, project/global
    configuration handling, sandbox process setup, and JSON event parsing are
    defined.
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
    name = 'opencode'
    version = '0.9.1'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'OpenCode CLI'; version = 'unavailable' }
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
        credential_child_filtering = 'conditional'
        native_skill_activation_evidence = 'unsupported'
        # Behavioral evaluation transport is runner-owned: the runner starts
        # foreground opencode run --format json processes, captures the exact
        # fresh session id from turn 1 structured events, and uses only a
        # model-free help-proven explicit --session <id> continuation for
        # scripted turns. OpenCode's native Task/General subagent remains an
        # advertised harness capability but is NOT the benchmark transport.
        # These controls stay conditional because terminal evidence proves the
        # concrete session, model, prompt, cwd, and isolated home/config.
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
        mechanism = 'Runner-owned OpenCode CLI session (opencode run --format json): the runner starts one fresh foreground process, captures its exact non-empty session identity from structured JSON events, and uses only installed-help-proven explicit --session <session-id> continuation for scripted turns'
        worker_role = 'primary-session'
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

function Resolve-OpenCodeInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    return [pscustomobject]@{
        Run = Resolve-RunContract -RunPath $Run
        Profile = Resolve-ExecutionProfile -ProfilePath $Profile
    }
}

function Invoke-OpenCodeCli {
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

function Get-OpenCodeHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment = $null
    )

    $environment = if ($null -eq $Environment) { New-OpenCodeEnvironment -Inputs $Inputs } else { $Environment }
    return Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments @('run', '--help') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
}

function Get-OpenCodeDebugHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    return Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments @('debug', '--help') -Inputs $Inputs -Environment $Environment -TimeoutSeconds 30
}

function Get-OpenCodeDebugConfigResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    return Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments @('debug', 'config') -Inputs $Inputs -Environment $Environment -TimeoutSeconds 30
}

function Get-OpenCodeCandidateSkillName {
    param([Parameter(Mandatory = $true)][object]$Run)

    if (-not [bool]$Run.CandidateSkillExposed) { return $null }
    $skillPath = [System.IO.Path]::GetFullPath([string]$Run.SkillDirectoryPath).TrimEnd([char[]]@('\', '/'))
    $skillName = [System.IO.Path]::GetFileName($skillPath)
    if ([string]::IsNullOrWhiteSpace($skillName) -or $skillName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "OpenCode prepared candidate skill directory has an unsupported native skill name: '$skillName'."
    }
    $declaredName = [string](Get-JsonProperty -Object $Run.Contract -Name 'skillName' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($declaredName) -and $declaredName -ne $skillName) {
        throw "OpenCode prepared candidate skill name '$skillName' does not match run.json skillName '$declaredName'."
    }
    return $skillName
}

function Get-OpenCodeSkillPermissionPolicy {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    if (-not [bool]$Inputs.Run.CandidateSkillExposed) { return 'deny' }
    $skillName = Get-OpenCodeCandidateSkillName -Run $Inputs.Run
    $permission = [ordered]@{}
    $permission['*'] = 'deny'
    $permission[$skillName] = 'allow'
    return $permission
}

function Test-OpenCodePathEqual {
    param(
        [AllowEmptyString()][string]$Expected,
        [AllowEmptyString()][string]$Observed
    )

    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Observed)) { return $false }
    try {
        $expectedFull = [System.IO.Path]::GetFullPath($Expected)
        $observedFull = [System.IO.Path]::GetFullPath($Observed)
        $comparison = if ((Get-PlatformName) -eq 'windows') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        return [string]::Equals($expectedFull.TrimEnd([char[]]@('\', '/')), $observedFull.TrimEnd([char[]]@('\', '/')), $comparison)
    } catch {
        return $false
    }
}

function Get-OpenCodeHostHomeCandidates {
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('USERPROFILE', 'HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value) -and $candidates -notcontains $value) { $candidates.Add($value) }
    }
    if ((Get-PlatformName) -eq 'windows') {
        $drive = [Environment]::GetEnvironmentVariable('HOMEDRIVE')
        $path = [Environment]::GetEnvironmentVariable('HOMEPATH')
        if (-not [string]::IsNullOrWhiteSpace($drive) -and -not [string]::IsNullOrWhiteSpace($path)) {
            $combined = $drive + $path
            if ($candidates -notcontains $combined) { $candidates.Add($combined) }
        }
    }
    return @($candidates.ToArray())
}

function Get-OpenCodeRuntimeHomeObservation {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $nodeInfo = Resolve-ExternalCommand -Name 'node'
    if ($null -ne $nodeInfo) {
        try {
            $probe = Invoke-RunnerProcess -FileName $nodeInfo.FileName -ArgumentList (@($nodeInfo.Prefix) + @('-p', 'require("os").homedir()')) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -TimeoutSeconds 30
            $runtimeHomeLines = @($probe.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
            if ($probe.ExitCode -eq 0 -and -not $probe.TimedOut -and $runtimeHomeLines.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$runtimeHomeLines[0])) {
                return [pscustomobject]@{
                    Available = $true
                    Home = ([string]$runtimeHomeLines[0]).Trim()
                    Source = 'node.os.homedir'
                    Process = $probe
                    Fallback = $false
                    Reason = $null
                }
            }
            $nodeReason = "node homedir probe exited with status $($probe.ExitCode) or returned no usable path."
        } catch {
            $nodeReason = "node homedir probe failed: $($_.Exception.Message)"
        }
    } else {
        $nodeReason = 'node is unavailable on PATH.'
    }

    # OpenCode is Node-based, but an installed distribution can theoretically
    # omit a separately discoverable node executable. Its model-free debug
    # paths command is the deterministic fallback for that case.
    try {
        $paths = Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments @('debug', 'paths') -Inputs $Inputs -Environment $Environment -TimeoutSeconds 30
        $pathLine = @(([string]::Join("`n", @($paths.Stdout, $paths.Stderr))) -split "`r?`n" | Where-Object { $_ -match '(?i)^\s*home\s*:?[ \t]+(?<path>.+?)\s*$' } | Select-Object -First 1)
        if ($paths.ExitCode -eq 0 -and -not $paths.TimedOut -and $pathLine.Count -eq 1) {
            $match = [regex]::Match([string]$pathLine[0], '(?i)^\s*home\s*:?[ \t]+(?<path>.+?)\s*$')
            if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups['path'].Value)) {
                return [pscustomobject]@{
                    Available = $true
                    Home = $match.Groups['path'].Value.Trim()
                    Source = 'opencode.debug.paths'
                    Process = $paths
                    Fallback = $true
                    Reason = $null
                }
            }
        }
        $debugReason = "opencode debug paths did not return a parseable home path (exit=$($paths.ExitCode))."
    } catch {
        $debugReason = "opencode debug paths failed: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        Available = $false
        Home = $null
        Source = 'unavailable'
        Process = $null
        Fallback = $false
        Reason = "$nodeReason $debugReason"
    }
}

function Get-OpenCodeHomeIsolationObservation {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][object]$RuntimeHome
    )

    $expectedHome = [System.IO.Path]::GetFullPath([string]$Inputs.Run.HomeDirectoryPath)
    $hostHomes = @(Get-OpenCodeHostHomeCandidates)
    $runtimeMatchesExpected = [bool]$RuntimeHome.Available -and (Test-OpenCodePathEqual -Expected $expectedHome -Observed ([string]$RuntimeHome.Home))
    $runtimeMatchesHost = @($hostHomes | Where-Object { Test-OpenCodePathEqual -Expected ([string]$_) -Observed ([string]$RuntimeHome.Home) }).Count -gt 0
    $windowsProfilePartsCoherent = $true
    if ((Get-PlatformName) -eq 'windows') {
        $drive = [string](Get-JsonProperty -Object $Environment -Name 'HOMEDRIVE' -Default '')
        $path = [string](Get-JsonProperty -Object $Environment -Name 'HOMEPATH' -Default '')
        $windowsProfilePartsCoherent = -not [string]::IsNullOrWhiteSpace($drive) -and -not [string]::IsNullOrWhiteSpace($path) -and (Test-OpenCodePathEqual -Expected $expectedHome -Observed ($drive + $path))
    }
    $pathValues = @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG')
    $pathValuesInsideHome = $true
    foreach ($name in $pathValues) {
        $value = [string](Get-JsonProperty -Object $Environment -Name $name -Default '')
        if ([string]::IsNullOrWhiteSpace($value) -or -not (Test-PathInside -BasePath $expectedHome -CandidatePath $value) -and -not (Test-OpenCodePathEqual -Expected $expectedHome -Observed $value)) {
            $pathValuesInsideHome = $false
            break
        }
    }
    $nodePathAbsent = -not $Environment.Contains('NODE_PATH')
    $valid = [bool]$RuntimeHome.Available -and $runtimeMatchesExpected -and -not $runtimeMatchesHost -and $windowsProfilePartsCoherent -and $pathValuesInsideHome -and $nodePathAbsent
    $reasonParts = [System.Collections.Generic.List[string]]::new()
    if (-not [bool]$RuntimeHome.Available) { $reasonParts.Add([string]$RuntimeHome.Reason) }
    if (-not $runtimeMatchesExpected) { $reasonParts.Add("effective runtime home '$($RuntimeHome.Home)' does not match isolated home '$expectedHome'.") }
    if ($runtimeMatchesHost) { $reasonParts.Add("effective runtime home '$($RuntimeHome.Home)' matches a parent user profile/home.") }
    if (-not $windowsProfilePartsCoherent) { $reasonParts.Add('HOMEDRIVE/HOMEPATH do not resolve to the isolated home.') }
    if (-not $pathValuesInsideHome) { $reasonParts.Add('one or more OpenCode home/config environment paths escape the isolated home.') }
    if (-not $nodePathAbsent) { $reasonParts.Add('NODE_PATH is present in the OpenCode child environment.') }
    return [pscustomobject]@{
        Valid = $valid
        ExpectedHome = $expectedHome
        RuntimeHome = [string]$RuntimeHome.Home
        RuntimeHomeAvailable = [bool]$RuntimeHome.Available
        RuntimeHomeSource = [string]$RuntimeHome.Source
        RuntimeHomeMatchesExpected = $runtimeMatchesExpected
        RuntimeHomeMatchesHost = $runtimeMatchesHost
        HostHomeCandidates = $hostHomes
        WindowsProfilePartsCoherent = $windowsProfilePartsCoherent
        PathValuesInsideHome = $pathValuesInsideHome
        NodePathAbsent = $nodePathAbsent
        Environment = [ordered]@{
            HOME = [string](Get-JsonProperty -Object $Environment -Name 'HOME' -Default '')
            USERPROFILE = [string](Get-JsonProperty -Object $Environment -Name 'USERPROFILE' -Default '')
            HOMEDRIVE = [string](Get-JsonProperty -Object $Environment -Name 'HOMEDRIVE' -Default '')
            HOMEPATH = [string](Get-JsonProperty -Object $Environment -Name 'HOMEPATH' -Default '')
            APPDATA = [string](Get-JsonProperty -Object $Environment -Name 'APPDATA' -Default '')
            LOCALAPPDATA = [string](Get-JsonProperty -Object $Environment -Name 'LOCALAPPDATA' -Default '')
            XDG_CONFIG_HOME = [string](Get-JsonProperty -Object $Environment -Name 'XDG_CONFIG_HOME' -Default '')
            OPENCODE_CONFIG_DIR = [string](Get-JsonProperty -Object $Environment -Name 'OPENCODE_CONFIG_DIR' -Default '')
            OPENCODE_CONFIG = [string](Get-JsonProperty -Object $Environment -Name 'OPENCODE_CONFIG' -Default '')
            NODE_PATH_present = -not $nodePathAbsent
        }
        Reason = [string]::Join(' ', @($reasonParts.ToArray()))
    }
}

function Get-OpenCodeSkillPolicyObservation {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $configPath = [string](Get-JsonProperty -Object $Environment -Name 'OPENCODE_CONFIG' -Default '')
    $expectedPermission = Get-OpenCodeSkillPermissionPolicy -Inputs $Inputs
    $observation = [ordered]@{
        available = $false
        config_path = $configPath
        configured_permission_skill = $null
        expected_permission_skill = $expectedPermission
        permission_match = $false
        external_skill_scans_disabled = [string](Get-JsonProperty -Object $Environment -Name 'OPENCODE_DISABLE_EXTERNAL_SKILLS' -Default '') -eq '1'
        claude_code_skill_scans_disabled = [string](Get-JsonProperty -Object $Environment -Name 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS' -Default '') -eq '1'
        candidate_skill_exposed = [bool]$Inputs.Run.CandidateSkillExposed
        candidate_skill_name = Get-OpenCodeCandidateSkillName -Run $Inputs.Run
        mechanism = 'isolated home/config plus OpenCode external-skill disable flags and permission.skill'
        reason = $null
    }
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $observation.reason = 'OpenCode policy config file is missing.'
        return [pscustomobject]$observation
    }
    try {
        $config = [IO.File]::ReadAllText($configPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 50
        $permission = Get-JsonProperty -Object $config -Name 'permission' -Default $null
        $actualPermission = Get-JsonProperty -Object $permission -Name 'skill' -Default $null
        $observation.available = $true
        $observation.configured_permission_skill = $actualPermission
        $observation.permission_match = ($actualPermission | ConvertTo-Json -Depth 20 -Compress) -eq ($expectedPermission | ConvertTo-Json -Depth 20 -Compress)
        if (-not [bool]$observation.permission_match) { $observation.reason = 'OpenCode policy config permission.skill does not match the requested arm policy.' }
        elseif (-not [bool]$observation.external_skill_scans_disabled -or -not [bool]$observation.claude_code_skill_scans_disabled) { $observation.reason = 'OpenCode external skill discovery disable flags are not both enabled.' }
    } catch {
        $observation.reason = "OpenCode policy config could not be parsed: $($_.Exception.Message)"
    }
    return [pscustomobject]$observation
}

function Get-OpenCodeDebugConfigObservation {
    param(
        [Parameter(Mandatory = $true)][object]$DebugResult,
        [Parameter(Mandatory = $true)][object]$Inputs
    )

    $expectedPermission = Get-OpenCodeSkillPermissionPolicy -Inputs $Inputs
    $observation = [ordered]@{
        available = $false
        permission_skill = $null
        permission_match = $false
        output_sha256 = $null
        reason = $null
    }
    $text = [string]::Join("`n", @($DebugResult.Stdout, $DebugResult.Stderr)).Trim()
    if ($DebugResult.TimedOut -or $DebugResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        $observation.reason = "opencode debug config failed (exit=$($DebugResult.ExitCode), timed_out=$($DebugResult.TimedOut))."
        return [pscustomobject]$observation
    }
    try {
        $config = $text | ConvertFrom-Json -Depth 50
        $permission = Get-JsonProperty -Object $config -Name 'permission' -Default $null
        $actualPermission = Get-JsonProperty -Object $permission -Name 'skill' -Default $null
        $observation.available = $true
        $observation.permission_skill = $actualPermission
        $observation.permission_match = ($actualPermission | ConvertTo-Json -Depth 20 -Compress) -eq ($expectedPermission | ConvertTo-Json -Depth 20 -Compress)
        $observation.output_sha256 = Get-Sha256HexFromBytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($text))
        if (-not [bool]$observation.permission_match) { $observation.reason = 'opencode debug config did not report the exact requested permission.skill policy.' }
    } catch {
        $observation.reason = "opencode debug config returned non-JSON output: $($_.Exception.Message)"
    }
    return [pscustomobject]$observation
}

function Get-OpenCodeSkillRootObservation {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $repo = [string]$Inputs.Run.WorkingDirectoryPath
    $isolatedHome = [string]$Inputs.Run.HomeDirectoryPath
    $projectSkillRoot = Join-Path (Join-Path $repo '.opencode') 'skills'
    $projectSingularSkillRoot = Join-Path (Join-Path $repo '.opencode') 'skill'
    $globalOpenCodeSkillRoot = Join-Path (Join-Path (Join-Path $isolatedHome '.config') 'opencode') 'skills'
    $globalOpenCodeSingularSkillRoot = Join-Path (Join-Path (Join-Path $isolatedHome '.config') 'opencode') 'skill'
    $agentsSkillRoot = Join-Path (Join-Path $isolatedHome '.agents') 'skills'
    $claudeSkillRoot = Join-Path (Join-Path $isolatedHome '.claude') 'skills'
    $roots = @(
        [ordered]@{ kind = 'project'; path = $projectSkillRoot },
        [ordered]@{ kind = 'project'; path = $projectSingularSkillRoot },
        [ordered]@{ kind = 'global_opencode'; path = $globalOpenCodeSkillRoot },
        [ordered]@{ kind = 'global_opencode'; path = $globalOpenCodeSingularSkillRoot },
        [ordered]@{ kind = 'external_agents'; path = $agentsSkillRoot },
        [ordered]@{ kind = 'external_claude'; path = $claudeSkillRoot }
    )
    $skills = [System.Collections.Generic.List[object]]::new()
    $scanErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        $rootPath = [string]$root.path
        try {
            if (-not (Test-Path -LiteralPath $rootPath -PathType Container -ErrorAction Stop)) { continue }
            foreach ($directory in @(Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction Stop)) {
                $skillFile = Join-Path $directory.FullName 'SKILL.md'
                if (Test-Path -LiteralPath $skillFile -PathType Leaf -ErrorAction Stop) {
                    $skills.Add([ordered]@{ kind = [string]$root.kind; name = [string]$directory.Name; path = [string]$directory.FullName })
                }
            }
        } catch {
            $scanErrors.Add("$($root.kind) skill root '$rootPath' could not be inspected: $($_.Exception.Message)")
        }
    }
    $candidatePath = if ([bool]$Inputs.Run.CandidateSkillExposed) { [string]$Inputs.Run.SkillDirectoryPath } else { $null }
    $candidateSkills = @($skills | Where-Object { -not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-OpenCodePathEqual -Expected $candidatePath -Observed ([string]$_.path)) })
    $ambientSkills = @($skills | ForEach-Object {
            $skill = $_
            if (@($candidateSkills | Where-Object { Test-OpenCodePathEqual -Expected ([string]$_.path) -Observed ([string]$skill.path) }).Count -eq 0) { $skill }
        })
    $candidateHash = if ($candidateSkills.Count -eq 1) { Get-OpenCodeTreeHash -Root ([string]$candidateSkills[0].path) } else { $null }
    $preparedHash = if ([bool]$Inputs.Run.CandidateSkillExposed) { [string]$Inputs.Run.SkillHash } else { $null }
    $valid = if ([bool]$Inputs.Run.CandidateSkillExposed) {
        $scanErrors.Count -eq 0 -and $candidateSkills.Count -eq 1 -and $ambientSkills.Count -eq 0 -and $candidateHash -eq $preparedHash
    } else {
        $scanErrors.Count -eq 0 -and $skills.Count -eq 0
    }
    $reason = if ($valid) { $null } elseif ($scanErrors.Count -gt 0) { [string]::Join(' ', @($scanErrors.ToArray())) } elseif ([bool]$Inputs.Run.CandidateSkillExposed) { 'physical OpenCode skill roots do not contain exactly the prepared candidate and no ambient skills.' } else { 'without_skill physical OpenCode skill roots are not empty.' }
    return [pscustomobject]@{
        Valid = $valid
        CandidateSkillExposed = [bool]$Inputs.Run.CandidateSkillExposed
        CandidateSkillPath = $candidatePath
        CandidateSkillCount = $candidateSkills.Count
        CandidateSkillHash = $candidateHash
        PreparedSkillHash = $preparedHash
        AmbientSkillCount = $ambientSkills.Count
        AmbientSkills = @($ambientSkills)
        DiscoveredSkills = @($skills.ToArray())
        ScanErrors = @($scanErrors.ToArray())
        Reason = $reason
    }
}

function New-OpenCodeSkillIsolationEvidence {
    param([Parameter(Mandatory = $true)][object]$Observation)

    return [ordered]@{
        valid = [bool]$Observation.Valid
        candidate_skill_exposed = [bool]$Observation.CandidateSkillExposed
        candidate_skill_path = [string]$Observation.CandidateSkillPath
        candidate_skill_count = [int]$Observation.CandidateSkillCount
        candidate_skill_hash = [string]$Observation.CandidateSkillHash
        prepared_skill_hash = [string]$Observation.PreparedSkillHash
        ambient_skill_count = [int]$Observation.AmbientSkillCount
        ambient_skills = @($Observation.AmbientSkills)
        discovered_skills = @($Observation.DiscoveredSkills)
        scan_errors = @($Observation.ScanErrors)
        reason = [string]$Observation.Reason
    }
}

function New-OpenCodeHomeIsolationEvidence {
    param([Parameter(Mandatory = $true)][object]$Observation)

    return [ordered]@{
        valid = [bool]$Observation.Valid
        expected_home = [string]$Observation.ExpectedHome
        effective_runtime_home = [string]$Observation.RuntimeHome
        effective_runtime_home_available = [bool]$Observation.RuntimeHomeAvailable
        effective_runtime_home_source = [string]$Observation.RuntimeHomeSource
        effective_runtime_home_matches_expected = [bool]$Observation.RuntimeHomeMatchesExpected
        effective_runtime_home_matches_real_user_profile = [bool]$Observation.RuntimeHomeMatchesHost
        host_home_candidates = @($Observation.HostHomeCandidates)
        windows_profile_parts_coherent = [bool]$Observation.WindowsProfilePartsCoherent
        path_values_inside_home = [bool]$Observation.PathValuesInsideHome
        node_path_absent = [bool]$Observation.NodePathAbsent
        environment = $Observation.Environment
        reason = [string]$Observation.Reason
    }
}

function New-OpenCodeExecutionPaths {
    param(
        [Parameter(Mandatory = $true)][object]$LogicalInputs,
        [Parameter(Mandatory = $true)][object]$ExecutionInputs,
        [Parameter(Mandatory = $true)][object]$Projection,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [object]$HomeIsolation
    )

    $physicalCwdOutsideSource = $null -eq $Projection.SourceRepositoryRoot -or -not (Test-PathInside -BasePath $Projection.SourceRepositoryRoot -CandidatePath $Projection.PhysicalWorkingDirectory)
    $physicalHomeOutsideSource = $null -eq $Projection.SourceRepositoryRoot -or -not (Test-PathInside -BasePath $Projection.SourceRepositoryRoot -CandidatePath $Projection.PhysicalHomeDirectory)
    return [ordered]@{
        logical_working_directory = [string]$LogicalInputs.Run.WorkingDirectoryPath
        logical_home_directory = [string]$LogicalInputs.Run.HomeDirectoryPath
        physical_working_directory = [string]$Projection.PhysicalWorkingDirectory
        physical_home_directory = [string]$Projection.PhysicalHomeDirectory
        physical_isolated_home = [string]$Projection.PhysicalHomeDirectory
        effective_runtime_home = if ($null -eq $HomeIsolation) { $null } else { [string]$HomeIsolation.RuntimeHome }
        effective_runtime_home_source = if ($null -eq $HomeIsolation) { 'unavailable' } else { [string]$HomeIsolation.RuntimeHomeSource }
        effective_opencode_config_root = [string]$Environment['OPENCODE_CONFIG_DIR']
        physical_config_directory = [string]$Environment['OPENCODE_CONFIG_DIR']
        physical_config_file = [string]$Environment['OPENCODE_CONFIG']
        physical_run_root = [string]$Projection.Root
        physical_projection_root = [string]$Projection.Root
        physical_cwd_outside_source_repository = [bool]$physicalCwdOutsideSource
        physical_home_outside_source_repository = [bool]$physicalHomeOutsideSource
        projection_cleanup = 'pending'
    }
}

function New-OpenCodeCandidateSkillExposure {
    param(
        [Parameter(Mandatory = $true)][object]$LogicalInputs,
        [Parameter(Mandatory = $true)][object]$Projection,
        [object]$SkillIsolation
    )

    if ([bool]$LogicalInputs.Run.CandidateSkillExposed) {
        return [ordered]@{
            status = 'supported'
            logical_staged = $true
            native_discovery_root = '.opencode/skills/<name>/SKILL.md'
            candidate_skill_name = Get-OpenCodeCandidateSkillName -Run $LogicalInputs.Run
            physical_path = [string]$Projection.PhysicalSkillDirectory
            physical_tree_hash = [string]$Projection.PhysicalSkillHash
            prepared_tree_hash = [string]$LogicalInputs.Run.SkillHash
            hash_match = [string]$Projection.PhysicalSkillHash -eq [string]$LogicalInputs.Run.SkillHash
            ambient_skill_roots_hidden = $null -eq $SkillIsolation -or [int]$SkillIsolation.AmbientSkillCount -eq 0
        }
    }
    return [ordered]@{
        status = 'excluded'
        logical_staged = $false
        native_discovery_root = $null
        candidate_skill_name = $null
        physical_path = $null
        physical_tree_hash = $null
        prepared_tree_hash = $null
        hash_match = $null
        ambient_skill_roots_hidden = $null -eq $SkillIsolation -or [int]$SkillIsolation.AmbientSkillCount -eq 0
    }
}

function New-OpenCodeIsolationFailureResult {
    param(
        [Parameter(Mandatory = $true)][object]$LogicalInputs,
        [Parameter(Mandatory = $true)][object]$ExecutionDescriptor,
        [Parameter(Mandatory = $true)][object]$Preflight,
        [Parameter(Mandatory = $true)][object]$Projection,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [object]$HomeIsolation,
        [object]$PolicyObservation,
        [object]$SkillIsolation,
        [string]$PreflightSource = 'fresh_preflight',
        [string[]]$Reasons = @(),
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][datetime]$StartedUtc,
        [bool]$Resume = $false
    )

    $finished = [DateTime]::UtcNow
    $message = if ($Reasons.Count -gt 0) { [string]::Join('; ', @($Reasons)) } else { 'OpenCode isolation could not be proven before model execution.' }
    $executionPaths = New-OpenCodeExecutionPaths -LogicalInputs $LogicalInputs -ExecutionInputs $Projection.Inputs -Projection $Projection -Environment $Environment -HomeIsolation $HomeIsolation
    $evidence = [ordered]@{
        preflight = $Preflight
        preflight_source = $PreflightSource
        execution_paths = $executionPaths
        effective_home = if ($null -eq $HomeIsolation) { $null } else { New-OpenCodeHomeIsolationEvidence -Observation $HomeIsolation }
        skill_policy = $PolicyObservation
        skill_isolation = if ($null -eq $SkillIsolation) { $null } else { New-OpenCodeSkillIsolationEvidence -Observation $SkillIsolation }
        candidate_skill_exposure = New-OpenCodeCandidateSkillExposure -LogicalInputs $LogicalInputs -Projection $Projection -SkillIsolation $SkillIsolation
        resume = $Resume
        native_execution_started = $false
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            worker_session_id = $SessionId
            fresh_worker = $true
            home_config_isolated = $false
            prompt_fidelity = $false
            paired_arm_visible = $false
            grading_material_visible = $false
            nested_model_execution = $false
            model_execution_count = 0
        }
    }
    return New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $LogicalInputs.Profile -Run $LogicalInputs.Run -Status incompatible -FinalResponseReason 'isolation_incompatible' -StartedUtc $StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $StartedUtc).TotalSeconds -Failure (New-ExecutionFailure -Code 'opencode_isolation_incompatible' -Message $message) -SessionId $SessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('physical home/config/skill isolation was not proven; model execution was not started') -Warnings @('OpenCode model execution was not started because the physical home/config/skill isolation contract failed closed.') -Evidence $evidence -AttemptCount 1
}

function Remove-OpenCodeAnsiSequences {
    param([AllowEmptyString()][string]$Text)

    return [regex]::Replace($Text, "`e\[[0-?]*[ -/]*[@-~]", '')
}

function Get-OpenCodeContinuationCapability {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$HelpText)

    $cleanText = Remove-OpenCodeAnsiSequences -Text $HelpText
    $lines = @($cleanText -split "`r?`n")
    $flag = '--session'
    $flagPattern = [regex]::Escape($flag)
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = [string]$lines[$lineIndex]
        $match = [regex]::Match($line, "(?<![A-Za-z0-9_-])$flagPattern(?![A-Za-z0-9_-])", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }
        if ($line -notmatch '(?i)^\s*(?:-[A-Za-z0-9][A-Za-z0-9-]*,\s*)?--session(?:\s|=|$)') { continue }

        # OpenCode's help renderer has used all of these forms in released
        # builds: --session <session-id>, --session SESSION_ID, --session=id,
        # and the compact `-s, --session      session id to continue` form.
        # Parse the option token separately from its prose instead of making
        # angle/bracket syntax the compatibility contract.
        $remainder = $line.Substring($match.Index + $match.Length)
        $argumentStyle = 'separate'
        $parameter = $null
        $equalsMatch = [regex]::Match($remainder, '^\s*=\s*(?<value>[^\s,;]+)')
        if ($equalsMatch.Success) {
            $argumentStyle = 'equals'
            $parameter = [string]$equalsMatch.Groups['value'].Value
        } else {
            $separateMatch = [regex]::Match($remainder, '^\s+(?<value>[^\s,;]+)')
            if ($separateMatch.Success) {
                $candidateParameter = [string]$separateMatch.Groups['value'].Value
                if ($candidateParameter -notmatch '(?i)^(continue|resume|resumes|the|a|an|existing|previous|specific|target|session)$') {
                    $parameter = $candidateParameter
                }
            }
        }

        # Keep only the current option entry and nearby wrapped description
        # lines. A neighbouring --continue entry is a different option and
        # must not accidentally prove exact-session support for --session.
        $contextLines = [System.Collections.Generic.List[string]]::new()
        if ($lineIndex -gt 0 -and [string]$lines[$lineIndex - 1] -notmatch '(?<![A-Za-z0-9_-])-{1,2}[A-Za-z0-9][A-Za-z0-9-]*\b') {
            $contextLines.Add([string]$lines[$lineIndex - 1])
        }
        $contextLines.Add($line)
        $contextEnd = [Math]::Min($lines.Count - 1, $lineIndex + 3)
        for ($contextIndex = $lineIndex + 1; $contextIndex -le $contextEnd; $contextIndex++) {
            $contextLine = [string]$lines[$contextIndex]
            if ($contextLine -match '(?<![A-Za-z0-9_-])-{1,2}[A-Za-z0-9][A-Za-z0-9-]*\b') { break }
            $contextLines.Add($contextLine)
        }
        $context = [string]::Join(' ', @($contextLines.ToArray()))
        $contextWithoutFlag = $context -replace $flagPattern, ''
        $implicitContinuation = $contextWithoutFlag -match '(?i)(?:(?:continue|resume|resuming|continuation).{0,80}(?:last|most\s+recent|latest|current)|(?:last|most\s+recent|latest|current).{0,80}(?:continue|resume|resuming|continuation))'
        $freshSessionDescription = $contextWithoutFlag -match '(?i)(?:\b(?:new|fresh|create)\s+session\b|\bset\s+(?:the\s+)?session\s*(?:id|identifier)?\b|\b(?:start|create)\s+(?:a\s+)?new\s+session\b)'
        if ($implicitContinuation -or $freshSessionDescription) { continue }
        $continuationDescription = $contextWithoutFlag -match '(?i)\b(?:continue|continues|continued|continuation|resume|resumes|resumed|resuming)\b'
        $identityDescription = $contextWithoutFlag -match '(?i)(?:\bsession\s*(?:id|identifier)\b|\b(?:by|using|with|via)\s+(?:the\s+)?(?:exact\s+)?(?:session\s+)?(?:id|identifier)\b|\bidentified\s+by\s+(?:the\s+)?(?:session\s+)?(?:id|identifier)\b)'
        $normalizedParameter = if ($null -eq $parameter) { '' } else { ([string]$parameter -replace '^[<\[\{(]+|[>\]\})]+$', '') }
        $parameterIdentifiesSession = $normalizedParameter -match '(?i)^(?:session[-_ ]?id|id|identifier)$'
        if (-not $parameterIdentifiesSession -and $identityDescription -and $contextWithoutFlag -match '(?i)\bsession\s*(?:id|identifier)\b') {
            # The installed-style entry has prose rather than a separate
            # placeholder token: `session id to continue`.
            $parameter = 'session-id'
            $parameterIdentifiesSession = $true
        }
        $explicitIdentityDescription = $continuationDescription -and ($identityDescription -or $parameterIdentifiesSession)
        if (-not $explicitIdentityDescription) { continue }
        return [pscustomobject]@{
            Available = $true
            Flag = $flag
            ArgumentStyle = $argumentStyle
            Parameter = $parameter
            HelpEvidence = $context.Trim()
            Reason = $null
        }
    }
    return [pscustomobject]@{
        Available = $false
        Flag = $null
        ArgumentStyle = $null
        Parameter = $null
        HelpEvidence = $null
        Reason = 'The installed OpenCode run help did not prove --session with an explicit session id; --continue or another implicit last-session mode is not permitted.'
    }
}

function New-OpenCodeContinuationArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Capability,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    if (-not [bool]$Capability.Available -or [string]::IsNullOrWhiteSpace([string]$Capability.Flag)) {
        throw 'OpenCode exact-session continuation was requested without a proven continuation capability.'
    }
    if ([string]$Capability.ArgumentStyle -eq 'equals') {
        return @(([string]$Capability.Flag + '=' + $SessionId))
    }
    return @([string]$Capability.Flag, $SessionId)
}

function Invoke-OpenCodeTurnProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][string]$Platform,
        [object]$SandboxInfo,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$InputBytes,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $hardFilesystem = $null -ne $SandboxInfo -and $Platform -in @('linux', 'macos')
    if ($Platform -eq 'linux' -and $hardFilesystem) {
        $sandboxArguments = Get-LinuxSandboxArguments -Inputs $Inputs -CommandInfo $CommandInfo -Environment $Environment
        return Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($Arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
    }
    if ($Platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosSandboxProfile -Inputs $Inputs -CommandInfo $CommandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $CommandInfo.FileName) + @($CommandInfo.Prefix) + $Arguments
        return Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
    }
    return Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments $Arguments -Inputs $Inputs -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
}

function Invoke-OpenCodeScriptedExecute {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Preflight,
        [Parameter(Mandatory = $true)][object]$ExecutionDescriptor,
        [string]$PreflightSource = 'fresh_preflight'
    )

    $started = [DateTime]::UtcNow
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $protocol = Get-JsonProperty -Object $Preflight -Name 'protocol_observations' -Default $null
    $continuationObservation = Get-JsonProperty -Object $protocol -Name 'scripted_multi_turn_same_session' -Default $null
    $continuationCapability = [pscustomobject]@{
        Available = [bool](Get-JsonProperty -Object $continuationObservation -Name 'available' -Default $false)
        Flag = Get-JsonProperty -Object $continuationObservation -Name 'flag' -Default $null
        ArgumentStyle = Get-JsonProperty -Object $continuationObservation -Name 'argument_style' -Default $null
        Parameter = Get-JsonProperty -Object $continuationObservation -Name 'parameter' -Default $null
    }
    if ($null -eq $commandInfo -or -not [bool]$continuationCapability.Available) {
        $finished = [DateTime]::UtcNow
        $fallbackSessionId = [Guid]::NewGuid().ToString('D')
        $failureMessage = [string](Get-JsonProperty -Object $continuationObservation -Name 'reason' -Default 'OpenCode exact-session continuation was not proven by installed help.')
        return New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $failureMessage) -SessionId $fallbackSessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $Preflight; resume = $false }) -AttemptCount 1
    }

    $projection = $null
    $result = $null
    try {
    $projection = New-OpenCodeExecutionProjection -Inputs $Inputs
    $executionInputs = $projection.Inputs
    $environment = New-OpenCodeEnvironment -Inputs $executionInputs
    $runtimeHomeObservation = Get-OpenCodeRuntimeHomeObservation -CommandInfo $commandInfo -Inputs $executionInputs -Environment $environment
    $homeIsolationObservation = Get-OpenCodeHomeIsolationObservation -Inputs $executionInputs -Environment $environment -RuntimeHome $runtimeHomeObservation
    $policyObservation = Get-OpenCodeSkillPolicyObservation -Inputs $executionInputs -Environment $environment
    $skillIsolationObservation = Get-OpenCodeSkillRootObservation -Inputs $executionInputs
    $isolationReasons = [System.Collections.Generic.List[string]]::new()
    if (-not [bool]$homeIsolationObservation.Valid) { $isolationReasons.Add([string]$homeIsolationObservation.Reason) }
    if (-not [bool]$policyObservation.permission_match -or -not [bool]$policyObservation.external_skill_scans_disabled -or -not [bool]$policyObservation.claude_code_skill_scans_disabled) { $isolationReasons.Add([string]$policyObservation.reason) }
    if (-not [bool]$skillIsolationObservation.Valid) { $isolationReasons.Add([string]$skillIsolationObservation.Reason) }
    if ($isolationReasons.Count -gt 0) {
        $result = New-OpenCodeIsolationFailureResult -LogicalInputs $Inputs -ExecutionDescriptor $ExecutionDescriptor -Preflight $Preflight -Projection $projection -Environment $environment -HomeIsolation $homeIsolationObservation -PolicyObservation $policyObservation -SkillIsolation $skillIsolationObservation -PreflightSource $PreflightSource -Reasons @($isolationReasons.ToArray()) -SessionId ([Guid]::NewGuid().ToString('D')) -StartedUtc $started -Resume $false
        return $result
    }
    $requestedTurns = @($Inputs.Run.Interaction.turns)
    $baseArguments = New-OpenCodeCliArguments -Inputs $executionInputs -VisiblePlatform $visiblePlatform
    $turnRecords = [System.Collections.Generic.List[object]]::new()
    $nativeTurns = [System.Collections.Generic.List[object]]::new()
    $rawStdout = [System.Collections.Generic.List[string]]::new()
    $rawStderr = [System.Collections.Generic.List[string]]::new()
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $nativeFailures = [System.Collections.Generic.List[string]]::new()
    $eventCounts = @{}
    $observedModels = [System.Collections.Generic.List[string]]::new()
    $usageBuckets = [ordered]@{}
    $toolCalls = 0
    $capturedSessionId = $null
    $finalText = $null
    $firstProcess = $null
    $lastProcess = $null
    $status = 'completed'
    $failureCode = $null
    $failureMessage = $null
    $turnTimingRecords = [System.Collections.Generic.List[object]]::new()
    $futureCanary = Get-OpenCodeFutureTurnCanary -Run $Inputs.Run
    $interactionSourcePhysicalPaths = @(Get-OpenCodeInteractionSourcePhysicalPaths -Inputs $Inputs -Projection $projection)
    $interactionJsonPhysicalPaths = @(Get-OpenCodeInteractionJsonPhysicalPaths -Inputs $Inputs -Projection $projection)
    $interactionPhysicalPresent = @($interactionJsonPhysicalPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
    $futureSourcePhysicalPresent = @($interactionSourcePhysicalPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
    $canaryInProjectionBeforeTurn1 = Test-OpenCodeCanaryInTree -Root $projection.Root -Canary $futureCanary
    $canaryInEnvironment = @($environment.GetEnumerator() | Where-Object { [string]$_.Value -like "*$futureCanary*" }).Count -gt 0
    $turnOneInputContainsFutureCanary = $false
    $turnOneArgumentsContainFutureCanary = $false
    $turnTwoSentAfterTurnOneTerminal = $false

    for ($turnIndex = 0; $turnIndex -lt $requestedTurns.Count; $turnIndex++) {
        $turnText = Get-InteractionTurnText -Turn $requestedTurns[$turnIndex] -RunData $Inputs.Run
        $arguments = @($baseArguments)
        $targetSessionId = $null
        if ($turnIndex -gt 0) {
            $targetSessionId = $capturedSessionId
            if ([string]::IsNullOrWhiteSpace($targetSessionId)) {
                $nativeFailures.Add('session_id_unobservable')
                $status = 'incompatible'
                $failureCode = 'native_interaction_incompatible'
                $failureMessage = 'OpenCode turn 1 did not expose an exact session id, so no continuation invocation was started.'
                break
            }
            $arguments = @($arguments) + @(New-OpenCodeContinuationArguments -Capability $continuationCapability -SessionId $targetSessionId)
        }
        if ($turnIndex -eq 0) {
            $turnOneInputContainsFutureCanary = [string]$turnText -like "*$futureCanary*"
            $turnOneArgumentsContainFutureCanary = @($arguments | Where-Object { [string]$_ -like "*$futureCanary*" }).Count -gt 0
        }

        try {
            $turnInputBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($turnText)
            $process = Invoke-OpenCodeTurnProcess -Inputs $executionInputs -CommandInfo $commandInfo -Arguments $arguments -Environment $environment -Platform $platform -SandboxInfo $sandboxInfo -InputBytes $turnInputBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
        } catch {
            $nativeFailures.Add('transport_failure')
            $status = 'failed'
            $failureCode = 'opencode_failure'
            $failureMessage = $_.Exception.Message
            break
        }
        if ($null -eq $firstProcess) { $firstProcess = $process }
        $lastProcess = $process
        $rawStdout.Add([string]$process.Stdout)
        $rawStderr.Add([string]$process.Stderr)
        $turnNumber = $turnIndex + 1
        $turnArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath ("evidence/opencode-turn-{0}-events.jsonl" -f $turnNumber) -Text ([string]$process.Stdout)
        $turnStderrArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath ("evidence/opencode-turn-{0}-stderr.txt" -f $turnNumber) -Text ([string]$process.Stderr)
        $artifacts.Add($turnArtifact)
        $artifacts.Add($turnStderrArtifact)
        $parsed = if ([string]::IsNullOrEmpty([string]$process.Stdout)) { [pscustomobject]@{ Events = @(); Errors = @() } } else { ConvertFrom-JsonLines -Text $process.Stdout }
        foreach ($parseError in @($parsed.Errors)) { $warnings.Add("OpenCode turn $turnNumber event parse error: $parseError") }
        $parsedEvents = Read-OpenCodeScriptedTurn -Parsed $parsed -Warnings $warnings
        $turnTiming = [ordered]@{
            turn = $turnNumber
            invocation = if ($turnIndex -eq 0) { 'fresh' } else { 'explicit_session_resume' }
            process_duration_seconds = [double]$process.DurationSeconds
            cli_startup_and_execution_duration_seconds = [double]$process.DurationSeconds
        }
        if ($null -ne $parsedEvents.EventTiming) {
            $turnTiming.event_timing = $parsedEvents.EventTiming
        }
        $turnTimingRecords.Add($turnTiming)
        foreach ($eventName in $parsedEvents.EventCounts.Keys) {
            if ($eventCounts.ContainsKey($eventName)) { $eventCounts[$eventName] += [int]$parsedEvents.EventCounts[$eventName] } else { $eventCounts[$eventName] = [int]$parsedEvents.EventCounts[$eventName] }
        }
        $toolCalls += [int]$parsedEvents.ToolCalls
        foreach ($modelName in @($parsedEvents.ObservedModels)) {
            if ($observedModels -notcontains $modelName) { $observedModels.Add($modelName) }
        }
        foreach ($usageName in $parsedEvents.UsageBuckets.Keys) {
            $usageBuckets[$usageName] = Add-OpenCodeNullableInt64 -Current (Get-JsonProperty -Object $usageBuckets -Name $usageName -Default $null) -Value $parsedEvents.UsageBuckets[$usageName]
        }

        $sessionIds = @($parsedEvents.SessionIds)
        $observedSessionId = if ($sessionIds.Count -eq 1) { [string]$sessionIds[0] } else { $null }
        $nativeTurn = [ordered]@{
            turn = $turnNumber
            invocation = if ($turnIndex -eq 0) { 'fresh' } else { 'explicit_session_resume' }
            arguments = @($arguments)
            requested_model = [string]$Inputs.Profile.Model
            observed_models = @($parsedEvents.ObservedModels)
            model_source = if (@($parsedEvents.ObservedModels).Count -gt 0) { 'structured_event' } else { 'cli_argument' }
            session_ids_observed = @($sessionIds)
            session_id = $observedSessionId
            target_session_id = $targetSessionId
            target_session_match = if ($turnIndex -eq 0) { $null } else { $observedSessionId -eq $targetSessionId }
            terminal_assistant_response = -not [string]::IsNullOrWhiteSpace([string]$parsedEvents.FinalText)
            terminal_event_observed = [bool]$parsedEvents.TerminalEventObserved
            structured_event_count = [int]$parsedEvents.StructuredEventCount
            structured_parse_errors = [int]$parsedEvents.ParseErrorCount
            structured_output = 'json'
            working_directory = [string]$executionInputs.Run.WorkingDirectoryPath
            home = [string]$executionInputs.Run.HomeDirectoryPath
            effective_runtime_home = [string]$homeIsolationObservation.RuntimeHome
            effective_runtime_home_source = [string]$homeIsolationObservation.RuntimeHomeSource
            config_directory = [string]$environment['OPENCODE_CONFIG_DIR']
            config_file = [string]$environment['OPENCODE_CONFIG']
            skill_policy = $policyObservation.configured_permission_skill
            candidate_skill_exposed = [bool]$executionInputs.Run.CandidateSkillExposed
            process_duration_seconds = [double]$process.DurationSeconds
            cli_startup_and_execution_duration_seconds = [double]$process.DurationSeconds
            started_utc = Format-UtcTimestamp -Value $process.StartedUtc
            finished_utc = Format-UtcTimestamp -Value $process.FinishedUtc
            event_timestamps = @($parsedEvents.EventTimestamps)
            exit_code = $process.ExitCode
            terminal = -not $process.TimedOut -and $process.ExitCode -eq 0
        }
        if ($null -ne $parsedEvents.EventTiming) {
            $nativeTurn.event_timing = $parsedEvents.EventTiming
        }
        $nativeTurns.Add($nativeTurn)
        if ($turnIndex -eq 1 -and $nativeTurns.Count -ge 2) {
            $turnTwoSentAfterTurnOneTerminal = [DateTime]::Compare([DateTime]$nativeTurns[0].finished_utc, [DateTime]$nativeTurn.started_utc) -le 0
        }

        $turnProblem = $null
        if ($process.TimedOut) { $turnProblem = 'turn_timeout'; $status = 'timed_out'; $failureCode = 'timed_out'; $failureMessage = 'OpenCode did not finish before timeout_seconds.' }
        elseif ($process.ExitCode -ne 0 -or $null -ne $parsedEvents.FailureMessage) { $turnProblem = 'turn_failed'; $status = 'failed'; $failureCode = 'opencode_failure'; $failureMessage = if ($null -ne $parsedEvents.FailureMessage) { [string]$parsedEvents.FailureMessage } else { "OpenCode exited with status $($process.ExitCode)." } }
        elseif ($parsedEvents.ParseErrorCount -gt 0) { $turnProblem = 'structured_event_parse'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "OpenCode turn $turnNumber did not produce a complete structured event stream." }
        elseif ($sessionIds.Count -ne 1) { $turnProblem = 'session_id_unobservable'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "OpenCode turn $turnNumber did not expose exactly one session id in structured events." }
        elseif ($turnIndex -gt 0 -and $observedSessionId -ne $targetSessionId) { $turnProblem = 'session_identity_mismatch'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "OpenCode turn $turnNumber returned session '$observedSessionId' instead of the exact resumed session '$targetSessionId'." }
        elseif ([string]::IsNullOrWhiteSpace([string]$parsedEvents.FinalText) -or -not [bool]$parsedEvents.TerminalEventObserved) { $turnProblem = 'terminal_turn_status'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "OpenCode turn $turnNumber did not provide a terminal structured assistant response before continuation." }
        elseif (@($parsedEvents.ObservedModels | Where-Object { [string]$_ -ne [string]$Inputs.Profile.Model }).Count -gt 0) { $turnProblem = 'requested_model'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "OpenCode turn $turnNumber reported a model different from the requested model '$($Inputs.Profile.Model)'." }
        if ($null -ne $turnProblem) {
            $nativeFailures.Add($turnProblem)
            break
        }
        if ($turnIndex -eq 0) { $capturedSessionId = $observedSessionId }
        $finalText = [string]$parsedEvents.FinalText
        $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 1; role = 'user'; content_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($turnText)); session_id = $capturedSessionId; timestamp_utc = Format-UtcTimestamp -Value $process.StartedUtc })
        $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 2; role = 'assistant'; text = $finalText; session_id = $capturedSessionId; timestamp_utc = Format-UtcTimestamp -Value $process.FinishedUtc })
    }

    if ($null -eq $firstProcess) { $firstProcess = [pscustomobject]@{ StartedUtc = $started; FinishedUtc = [DateTime]::UtcNow; DurationSeconds = ([DateTime]::UtcNow - $started).TotalSeconds; ExitCode = $null; TimedOut = $false } }
    if ($null -eq $lastProcess) { $lastProcess = $firstProcess }
    $combinedStdout = [string]::Join('', @($rawStdout.ToArray()))
    $combinedStderr = [string]::Join('', @($rawStderr.ToArray()))
    if (-not [string]::IsNullOrEmpty($combinedStdout) -and -not $combinedStdout.EndsWith("`n", [StringComparison]::Ordinal)) { $combinedStdout += [Environment]::NewLine }
    if (-not [string]::IsNullOrEmpty($combinedStderr) -and -not $combinedStderr.EndsWith("`n", [StringComparison]::Ordinal)) { $combinedStderr += [Environment]::NewLine }
    $stdoutArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-events.jsonl' -Text $combinedStdout
    $stderrArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-stderr.txt' -Text $combinedStderr
    $artifacts.Add($stdoutArtifact)
    $artifacts.Add($stderrArtifact)
    if ($nativeFailures.Count -eq 0 -and $turnRecords.Count -ne ($requestedTurns.Count * 2)) {
        $nativeFailures.Add('turn_order')
        $status = 'incompatible'
        $failureCode = 'native_interaction_incompatible'
        $failureMessage = 'OpenCode scripted interaction did not complete every ordered user/assistant turn.'
    }
    if ($status -eq 'completed' -and $nativeFailures.Count -gt 0) { $status = 'incompatible' }
    if ([string]::IsNullOrWhiteSpace($capturedSessionId)) { $capturedSessionId = [Guid]::NewGuid().ToString('D') }
    $finished = $lastProcess.FinishedUtc
    $durationSeconds = [Math]::Round(($finished - $firstProcess.StartedUtc).TotalSeconds, 3)
    $nativeCliProcessTotalSeconds = [Math]::Round(([double](@($turnTimingRecords | ForEach-Object { [double]$_.process_duration_seconds } | Measure-Object -Sum).Sum)), 3)
    $tokenMetric = if ($usageBuckets.Count -eq 0) { New-UnavailableMetric -Reason 'opencode_did_not_expose_usage' } else { New-AvailableMetric -Value $usageBuckets }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/opencode-events.jsonl'; complete = $nativeFailures.Count -eq 0 })
        tokens = $tokenMetric
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = if ($usageBuckets.Contains('cost')) { New-AvailableMetric -Value $usageBuckets['cost'] } else { New-UnavailableMetric -Reason 'opencode_did_not_expose_cost' }
    }
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $credentialNames = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    $credentialEvidence = [ordered]@{
        model_provider = $modelProvider
        provider_environment_variables = $credentialNames
        unrelated_environment_excluded = $true
        child_tool_visibility = 'provider_credential_may_be_visible_to_native_child_tools; no supported child filter is exposed'
        value_observed = $false
    }
    $observedModel = if ($observedModels.Count -eq 0) { [string]$Inputs.Profile.Model } else { [string]$observedModels[$observedModels.Count - 1] }
    $transcriptArtifactPath = 'evidence/opencode-events.jsonl'
    $transcriptArtifact = @($artifacts | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'path' -Default '') -eq $transcriptArtifactPath } | Select-Object -First 1)
    $terminalCapture = $nativeFailures.Count -eq 0 -and $turnRecords.Count -eq ($requestedTurns.Count * 2) -and $rawStdout.Count -eq $requestedTurns.Count
    $executionPaths = New-OpenCodeExecutionPaths -LogicalInputs $Inputs -ExecutionInputs $executionInputs -Projection $projection -Environment $environment -HomeIsolation $homeIsolationObservation
    $candidateSkillExposure = New-OpenCodeCandidateSkillExposure -LogicalInputs $Inputs -Projection $projection -SkillIsolation $skillIsolationObservation
    $interactionEvidence = [ordered]@{
        schema = (Get-RunnerSchemaNames).Interaction
        mode = 'scripted'
        same_session = [bool]$terminalCapture
        session_id = $capturedSessionId
        turns = @($turnRecords.ToArray())
        final_response_sequence = @($turnRecords).Count
        transport = 'opencode-run-explicit-session-continuation'
        exact_session_flag = [string]$continuationCapability.Flag
        implicit_continuation = $false
        native_turns = @($nativeTurns.ToArray())
        structured_transcript_complete = [bool]$terminalCapture
        working_directory = [string]$projection.PhysicalWorkingDirectory
        isolated_home = [string]$projection.PhysicalHomeDirectory
        logical_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
        logical_isolated_home = [string]$Inputs.Run.HomeDirectoryPath
        config_directory = [string]$environment['OPENCODE_CONFIG_DIR']
        config_file = [string]$environment['OPENCODE_CONFIG']
        model = [string]$Inputs.Profile.Model
    }
    $evidence = [ordered]@{
        execution_paths = $executionPaths
        event_counts = $eventCounts
        observed_model = $observedModel
        observed_models = @($observedModels.ToArray())
        prompt_delivery = 'stdin'
        prompt_first_input = $true
        resume = $true
        exact_session_continuation = [ordered]@{
            flag = [string]$continuationCapability.Flag
            argument_style = [string]$continuationCapability.ArgumentStyle
            exact_session_id = $capturedSessionId
            implicit_last_session = $false
            turns_started_after_prior_terminal = [bool]$turnTwoSentAfterTurnOneTerminal
        }
        stdout_exit_codes = @($nativeTurns.ToArray() | ForEach-Object { Get-JsonProperty -Object $_ -Name 'exit_code' -Default $null })
        model_argument = [string]$Inputs.Profile.Model
        sandbox = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
        project_configuration = 'repository_owned_project_config_preserved'
        disable_project_config_environment = $false
        credential = $credentialEvidence
        interaction = $interactionEvidence
        future_turn_secrecy = [ordered]@{
            stable_canary = $futureCanary
            interaction_json_projected = [bool]$interactionPhysicalPresent
            future_source_files_projected = [bool]$futureSourcePhysicalPresent
            canary_in_physical_projection = [bool]$canaryInProjectionBeforeTurn1
            canary_in_environment = [bool]$canaryInEnvironment
            canary_in_arguments = [bool]$turnOneArgumentsContainFutureCanary
            turn_1_input_contains_future_canary = [bool]$turnOneInputContainsFutureCanary
            turn_2_sent_only_after_turn_1_terminal_completed = [bool]$turnTwoSentAfterTurnOneTerminal
        }
        candidate_skill_exposure = $candidateSkillExposure
        effective_home = New-OpenCodeHomeIsolationEvidence -Observation $homeIsolationObservation
        skill_policy = $policyObservation
        skill_isolation = New-OpenCodeSkillIsolationEvidence -Observation $skillIsolationObservation
        ambient_skill_policy = [ordered]@{
            mechanism = [string]$policyObservation.mechanism
            permission_skill = $policyObservation.configured_permission_skill
            external_skill_scans_disabled = [bool]$policyObservation.external_skill_scans_disabled
            claude_code_skill_scans_disabled = [bool]$policyObservation.claude_code_skill_scans_disabled
            ambient_skill_roots_hidden = [int]$skillIsolationObservation.AmbientSkillCount -eq 0
            candidate_skill_exposed = [bool]$executionInputs.Run.CandidateSkillExposed
            candidate_skill_physical_path = if ([bool]$executionInputs.Run.CandidateSkillExposed) { [string]$projection.PhysicalSkillDirectory } else { $null }
        }
        timing = [ordered]@{
            preflight = Get-JsonProperty -Object $Preflight -Name 'timing' -Default $null
            preflight_source = $PreflightSource
            projection_setup_duration_seconds = [double]$projection.SetupDurationSeconds
            native_cli_process_total_seconds = $nativeCliProcessTotalSeconds
            turns = @($turnTimingRecords.ToArray())
            total_runner_execution_seconds = [double]$durationSeconds
        }
        capture = [ordered]@{
            source = 'harness_native_transport'
            terminal = [bool]$terminalCapture
            worker_authored = $false
            artifact = $transcriptArtifactPath
            sha256 = if ($transcriptArtifact.Count -eq 1) { [string](Get-JsonProperty -Object $transcriptArtifact[0] -Name 'sha256' -Default $null) } else { $null }
            complete_structured_transcript = [bool]$terminalCapture
            turn_artifacts = @($nativeTurns.ToArray() | ForEach-Object { "evidence/opencode-turn-$(Get-JsonProperty -Object $_ -Name 'turn' -Default 0)-events.jsonl" })
        }
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = [string]$descriptor.delegation.mechanism
            worker_session_id = $capturedSessionId
            observed_model = $observedModel
            observed_working_directory = [string]$projection.PhysicalWorkingDirectory
            observed_home = [string]$projection.PhysicalHomeDirectory
            effective_runtime_home = [string]$homeIsolationObservation.RuntimeHome
            effective_opencode_config_root = [string]$environment['OPENCODE_CONFIG_DIR']
            fresh_worker = $true
            home_config_isolated = $true
            prompt_fidelity = $true
            prompt_sha256 = [string]$Inputs.Run.PromptHash
            terminal_result_capture = [bool]$terminalCapture
            paired_arm_visible = $false
            grading_material_visible = $false
            nested_model_execution = $false
            model_execution_count = 1
            same_session_continuation = [bool]$terminalCapture
            continuation_flag = [string]$continuationCapability.Flag
            continuation_session_id = $capturedSessionId
        }
        native_worker_evidence_failures = @($nativeFailures | Select-Object -Unique)
    }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('runner-owned fresh OpenCode process for turn 1', 'opencode run --format json structured event capture', 'prompt on stdin', '--model on every turn', '--dir on every turn', 'isolated OPENCODE_CONFIG_DIR and OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'coherent Windows HOME/USERPROFILE/HOMEDRIVE/HOMEPATH', 'OPENCODE_DISABLE_EXTERNAL_SKILLS=1', 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1', 'permission.skill arm policy', 'same isolated environment on every turn', 'repository-owned project configuration preserved', 'no implicit last-session continuation')) { $mechanisms.Add($mechanism) }
    $mechanisms.Add(("explicit OpenCode {0} <session-id> continuation selected from installed help" -f $continuationCapability.Flag))
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    if (-not $hardFilesystem) { $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $failureCodeValue = if ([string]::IsNullOrWhiteSpace($failureCode)) { 'native_interaction_incompatible' } else { $failureCode }
    $failureMessageValue = if ([string]::IsNullOrWhiteSpace($failureMessage)) { 'OpenCode scripted interaction failed closed.' } else { $failureMessage }
    $failure = if ($nativeFailures.Count -eq 0) { $null } else { New-ExecutionFailure -Code $failureCodeValue -Message $failureMessageValue }
    $exitStatus = if ($status -eq 'completed') { [Nullable[int]]0 } else { $null }
    $resultFinalResponse = if ($status -eq 'completed') { $finalText } else { $null }
    $resultFinalResponseReason = if ($status -eq 'completed') { $null } else { 'native_interaction_incompatible' }
    $result = New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $resultFinalResponse -FinalResponseReason $resultFinalResponseReason -StartedUtc $firstProcess.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $durationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $capturedSessionId -IsolationCapabilities (Get-OpenCodeCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem -ContinuationCapability $continuationCapability) -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'OpenCode accepted the requested model selector and configuration; scripted turns retained the exact requested model on every invocation.'; observations = [ordered]@{ model = $Inputs.Profile.Model; observed_models = @($observedModels.ToArray()); continuation_flag = $continuationCapability.Flag } }) -Telemetry $telemetry -Artifacts @($artifacts.ToArray()) -Warnings @($warnings.ToArray()) -Evidence $evidence -AttemptCount 1
    if ($status -eq 'completed') { [void](Assert-InteractionResultEvidence -ExecutionResult $result -RunData $Inputs.Run) }
    return $result
    } finally {
        if ($null -ne $projection) {
            try {
                Remove-OpenCodeProjectedCandidateSkill -Projection $projection
                Sync-OpenCodeProjectedRepository -Projection $projection
            } finally {
                Remove-OpenCodeExecutionProjection -Projection $projection
                if ($null -ne $result -and $null -ne $result.evidence -and $null -ne $result.evidence.execution_paths) {
                    $result.evidence.execution_paths.projection_cleanup = 'removed'
                }
                if ($null -ne $result -and $null -ne $result.evidence -and $null -ne $result.evidence.timing) {
                    $cleanupFinished = [DateTime]::UtcNow
                    $result.evidence.timing.projection_cleanup_duration_seconds = [Math]::Round(($cleanupFinished - $finished).TotalSeconds, 3)
                    $result.evidence.timing.total_runner_execution_seconds = [Math]::Round(($cleanupFinished - $started).TotalSeconds, 3)
                }
            }
        }
    }
}

function Get-OpenCodeEventSessionIds {
    param([Parameter(Mandatory = $true)][object]$Event)

    $part = Get-JsonProperty -Object $Event -Name 'part' -Default $null
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @(
            (Get-JsonProperty -Object $Event -Name 'sessionID' -Default $null),
            (Get-JsonProperty -Object $Event -Name 'sessionId' -Default $null),
            (Get-JsonProperty -Object $Event -Name 'session_id' -Default $null),
            (Get-JsonProperty -Object $part -Name 'sessionID' -Default $null),
            (Get-JsonProperty -Object $part -Name 'sessionId' -Default $null),
            (Get-JsonProperty -Object $part -Name 'session_id' -Default $null)
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value) -and $values -notcontains [string]$value) { $values.Add([string]$value) }
    }
    return @($values.ToArray())
}

function Get-OpenCodeEventModels {
    param([Parameter(Mandatory = $true)][object]$Event)

    $part = Get-JsonProperty -Object $Event -Name 'part' -Default $null
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($source in @($Event, $part)) {
        $provider = [string](Get-JsonProperty -Object $source -Name 'providerID' -Default (Get-JsonProperty -Object $source -Name 'providerId' -Default (Get-JsonProperty -Object $source -Name 'provider_id' -Default '')))
        $modelId = [string](Get-JsonProperty -Object $source -Name 'modelID' -Default (Get-JsonProperty -Object $source -Name 'modelId' -Default (Get-JsonProperty -Object $source -Name 'model_id' -Default '')))
        if (-not [string]::IsNullOrWhiteSpace($provider) -and -not [string]::IsNullOrWhiteSpace($modelId)) {
            $combined = "$provider/$modelId"
            if ($values -notcontains $combined) { $values.Add($combined) }
        }
    }
    foreach ($value in @(
            (Get-JsonProperty -Object $Event -Name 'model' -Default $null),
            (Get-JsonProperty -Object $Event -Name 'modelID' -Default $null),
            (Get-JsonProperty -Object $Event -Name 'modelId' -Default $null),
            (Get-JsonProperty -Object $Event -Name 'model_id' -Default $null),
            (Get-JsonProperty -Object $part -Name 'model' -Default $null),
            (Get-JsonProperty -Object $part -Name 'modelID' -Default $null),
            (Get-JsonProperty -Object $part -Name 'modelId' -Default $null),
            (Get-JsonProperty -Object $part -Name 'model_id' -Default $null)
        )) {
        $modelValue = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($modelValue) -and $values -notcontains $modelValue -and @($values | Where-Object { [string]$_ -like "*/$modelValue" }).Count -eq 0) { $values.Add($modelValue) }
    }
    return @($values.ToArray())
}

function Get-OpenCodeAuthVariable {
    param([Parameter(Mandatory = $true)][string]$Provider)

    $variables = @(Get-ProviderAuthenticationVariables -Provider $Provider)
    foreach ($name in $variables) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return $name
        }
    }
    return $null
}

function Get-OpenCodeModelProvider {
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model) -or $Model -notmatch '/') {
        return $null
    }
    $parts = $Model.Split([char[]]@('/'), 2, [System.StringSplitOptions]::None)
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        return $null
    }
    return $parts[0]
}

function Resolve-SandboxCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Resolve-ExternalCommand -Name $Name
}

function Get-OpenCodeDescriptor {
    $copy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $copy[$key] = $descriptor[$key] }
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $version = 'unavailable'
    if ($null -ne $commandInfo) {
        $observation = Get-ExternalCommandVersion -CommandInfo $commandInfo
        $version = [string]$observation.Version
    }
    $copy.harness = [ordered]@{ name = 'OpenCode CLI'; version = $version }
    return $copy
}

function New-OpenCodeCliArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform = (Get-PlatformName)
    )
    $directoryArgument = Get-SandboxVisiblePath -HostPath $Inputs.Run.WorkingDirectoryPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('run', '--format', 'json', '--dir', $directoryArgument, '--model', $Inputs.Profile.Model, '--auto')) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments.Add('--variant')
        $arguments.Add([string]$Inputs.Profile.ReasoningEffort)
    }
    return @($arguments)
}

function Get-OpenCodeSourceRepositoryRoot {
    param([Parameter(Mandatory = $true)][string]$RunRoot)

    # Prepared packages normally live below the source checkout, so discover
    # that checkout from the logical run first. The adapter fallback protects
    # the same invariant when a package is relocated outside the checkout:
    # the runner itself still identifies the repository whose ancestry must not
    # become an OpenCode execution root.
    foreach ($startPath in @($RunRoot, $PSScriptRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$startPath)) { continue }
        $current = [System.IO.Path]::GetFullPath([string]$startPath)
        while ($true) {
            $gitMarker = Join-Path $current '.git'
            if (Test-Path -LiteralPath $gitMarker) {
                return $current
            }
            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [System.StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            $current = $parent
        }
    }
    return $null
}

function Get-OpenCodeProjectionBaseDirectory {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $sourceRepositoryRoot = Get-OpenCodeSourceRepositoryRoot -RunRoot $Inputs.Run.RunRoot
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()))
    foreach ($specialFolder in @([System.Environment+SpecialFolder]::LocalApplicationData, [System.Environment+SpecialFolder]::CommonApplicationData)) {
        $path = [Environment]::GetFolderPath($specialFolder)
        if (-not [string]::IsNullOrWhiteSpace($path)) { $candidates.Add([System.IO.Path]::GetFullPath($path)) }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($null -ne $sourceRepositoryRoot -and (Test-PathInside -BasePath $sourceRepositoryRoot -CandidatePath $candidate)) {
            continue
        }
        if (Test-PathInside -BasePath $Inputs.Run.RunRoot -CandidatePath $candidate) {
            continue
        }
        return [pscustomobject]@{
            Path = $candidate
            SourceRepositoryRoot = $sourceRepositoryRoot
        }
    }

    throw 'OpenCode could not select a physical projection parent outside the prepared run and its source-repository ancestry.'
}

function Get-OpenCodeProjectionPlan {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $base = Get-OpenCodeProjectionBaseDirectory -Inputs $Inputs
    $root = [System.IO.Path]::GetFullPath((Join-Path $base.Path ('agentic-opencode-projection-' + [Guid]::NewGuid().ToString('N'))))
    if ($null -ne $base.SourceRepositoryRoot -and (Test-PathInside -BasePath $base.SourceRepositoryRoot -CandidatePath $root)) {
        throw 'OpenCode physical projection unexpectedly resolved under the source repository ancestry.'
    }
    if (Test-PathInside -BasePath $Inputs.Run.RunRoot -CandidatePath $root) {
        throw 'OpenCode physical projection unexpectedly resolved under the logical arm root.'
    }
    return [pscustomobject]@{
        Root = $root
        Parent = $base.Path
        SourceRepositoryRoot = $base.SourceRepositoryRoot
    }
}

function Assert-OpenCodeProjectionSource {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $reparsePoint = [System.IO.FileAttributes]::ReparsePoint
    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($rootItem.Attributes -band $reparsePoint) -ne 0) {
        throw "OpenCode physical projection refuses reparse-point input '$Path'."
    }
    $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band $reparsePoint) -ne 0 })
    if ($links.Count -gt 0) {
        throw "OpenCode physical projection refuses reparse-point input '$($links[0].FullName)'."
    }
}

function Copy-OpenCodeProjectionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$ExcludeRelativePaths = @()
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    Assert-OpenCodeProjectionSource -Path $Source
    $excluded = @($ExcludeRelativePaths | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') } | Where-Object { $_ })
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        $relative = [System.IO.Path]::GetRelativePath($Source, $item.FullName).Replace('\', '/')
        $isExcluded = @($excluded | Where-Object {
            $_ -eq $relative -or $relative.StartsWith($_ + '/', [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($isExcluded) { continue }
        $destinationPath = Join-Path $Destination ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ($item.PSIsContainer) {
            Copy-OpenCodeProjectionDirectory -Source $item.FullName -Destination $destinationPath -ExcludeRelativePaths @($excluded | ForEach-Object {
                if ($_.StartsWith($relative + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $_.Substring($relative.Length + 1) }
            })
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Force
        }
    }
}

function Get-OpenCodeProjectionFileSet {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
    } | Sort-Object)
}

function Get-OpenCodeTreeHash {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $segments = $relative.Split('/')
        if ($relative.StartsWith('evals/', [System.StringComparison]::OrdinalIgnoreCase) -or
            @($segments | Where-Object { $_ -in @('bin', 'obj', '__pycache__') }).Count -gt 0) {
            continue
        }
        $entries.Add("$relative`:$((Get-Sha256HexFromFile -Path $file.FullName))")
    }
    $joined = [string]::Join("`n", @($entries | Sort-Object))
    return Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($joined))
}

function New-OpenCodeExecutionProjection {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $projectionStarted = [DateTime]::UtcNow
    $plan = Get-OpenCodeProjectionPlan -Inputs $Inputs
    New-Item -ItemType Directory -Path $plan.Root -Force | Out-Null
    try {
        $physicalPrompt = Join-Path $plan.Root 'prompt.md'
        [System.IO.File]::WriteAllBytes($physicalPrompt, [byte[]]$Inputs.Run.PromptBytes)
        $physicalRepo = Join-Path $plan.Root 'repo'
        $physicalHome = Join-Path $plan.Root 'home'

        # Scripted interaction inputs are parent-owned data. They are read into
        # memory by the runner immediately before execution and are never made
        # part of the physical OpenCode filesystem projection. This prevents a
        # later turn (or its source file) from being discovered early.
        $excludedRepositoryFiles = [System.Collections.Generic.List[string]]::new()
        $excludedHomeFiles = [System.Collections.Generic.List[string]]::new()
        $excludedLogicalInteractionFiles = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $Inputs.Run.InteractionPath) {
            $excludedLogicalInteractionFiles.Add([string]$Inputs.Run.InteractionPath)
        }
        if ($null -ne $Inputs.Run.Interaction) {
            foreach ($turn in @($Inputs.Run.Interaction.turns)) {
                $source = [string](Get-JsonProperty -Object $turn -Name 'source' -Default '')
                if ([string]::IsNullOrWhiteSpace($source)) { continue }
                $excludedLogicalInteractionFiles.Add((Resolve-ContainedPath -BasePath $Inputs.Run.RunRoot -RelativePath $source -FieldName 'interaction turn source' -Kind File))
            }
        }
        foreach ($logicalInteractionFile in @($excludedLogicalInteractionFiles.ToArray() | Select-Object -Unique)) {
            if (Test-PathInside -BasePath $Inputs.Run.WorkingDirectoryPath -CandidatePath $logicalInteractionFile) {
                $excludedRepositoryFiles.Add([System.IO.Path]::GetRelativePath($Inputs.Run.WorkingDirectoryPath, $logicalInteractionFile).Replace('\', '/'))
            } elseif (Test-PathInside -BasePath $Inputs.Run.HomeDirectoryPath -CandidatePath $logicalInteractionFile) {
                $excludedHomeFiles.Add([System.IO.Path]::GetRelativePath($Inputs.Run.HomeDirectoryPath, $logicalInteractionFile).Replace('\', '/'))
            }
        }
        Copy-OpenCodeProjectionDirectory -Source $Inputs.Run.WorkingDirectoryPath -Destination $physicalRepo -ExcludeRelativePaths @($excludedRepositoryFiles.ToArray())
        Copy-OpenCodeProjectionDirectory -Source $Inputs.Run.HomeDirectoryPath -Destination $physicalHome -ExcludeRelativePaths @($excludedHomeFiles.ToArray())

        $physicalSkill = $null
        $physicalSkillHash = $null
        $runnerInjectedRepositoryFiles = [System.Collections.Generic.List[string]]::new()
        if ($Inputs.Run.CandidateSkillExposed) {
            $skillName = Get-OpenCodeCandidateSkillName -Run $Inputs.Run
            # OpenCode's installed native discovery surface is the project-local
            # .opencode/skills/<name>/SKILL.md root. The source is still the
            # prepared run's staged skill directory; only the projection target
            # changes so the candidate is discoverable by OpenCode itself.
            $physicalSkill = Join-Path (Join-Path (Join-Path $physicalRepo '.opencode') 'skills') $skillName
            if (Test-Path -LiteralPath $physicalSkill) {
                throw "OpenCode physical repository already contains a native candidate skill at '$physicalSkill'."
            }
            Copy-OpenCodeProjectionDirectory -Source $Inputs.Run.SkillDirectoryPath -Destination $physicalSkill
            $physicalSkillHash = Get-OpenCodeTreeHash -Root $physicalSkill
            if ($physicalSkillHash -ne [string]$Inputs.Run.SkillHash) {
                throw 'OpenCode physical candidate skill hash does not match the prepared run manifest.'
            }
            foreach ($relative in @(Get-OpenCodeProjectionFileSet -Root $physicalSkill)) {
                $runnerInjectedRepositoryFiles.Add(('.opencode/skills/{0}' -f $skillName) + '/' + $relative)
            }
        }

        $physicalRun = [pscustomobject]@{
            RunPath = $Inputs.Run.RunPath
            RunRoot = $plan.Root
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
            InteractionPath = $null
            InteractionHash = $Inputs.Run.InteractionHash
            Interaction = $Inputs.Run.Interaction
        }
        $projectionFinished = [DateTime]::UtcNow
        return [pscustomobject]@{
            Root = $plan.Root
            Parent = $plan.Parent
            SourceRepositoryRoot = $plan.SourceRepositoryRoot
            Run = $physicalRun
            Inputs = [pscustomobject]@{ Run = $physicalRun; Profile = $Inputs.Profile }
            LogicalRun = $Inputs.Run
            LogicalWorkingDirectory = $Inputs.Run.WorkingDirectoryPath
            LogicalHomeDirectory = $Inputs.Run.HomeDirectoryPath
            PhysicalWorkingDirectory = $physicalRepo
            PhysicalHomeDirectory = $physicalHome
            PhysicalSkillDirectory = $physicalSkill
            PhysicalSkillHash = $physicalSkillHash
            LogicalRepositoryFiles = @(Get-OpenCodeProjectionFileSet -Root $Inputs.Run.WorkingDirectoryPath)
            LogicalRepositoryHash = Get-OpenCodeTreeHash -Root $Inputs.Run.WorkingDirectoryPath
            ExcludedRepositoryFiles = @($excludedRepositoryFiles.ToArray())
            ExcludedHomeFiles = @($excludedHomeFiles.ToArray())
            InitialRepositoryFiles = @(Get-OpenCodeProjectionFileSet -Root $physicalRepo)
            InitialRepositoryHash = Get-OpenCodeTreeHash -Root $physicalRepo
            RunnerInjectedRepositoryFiles = @($runnerInjectedRepositoryFiles.ToArray())
            RuntimeCreatedRepositoryFiles = @()
            SetupStartedUtc = $projectionStarted
            SetupFinishedUtc = $projectionFinished
            SetupDurationSeconds = [Math]::Round(($projectionFinished - $projectionStarted).TotalSeconds, 3)
            Proven = $true
        }
    } catch {
        if (Test-Path -LiteralPath $plan.Root) { Remove-Item -LiteralPath $plan.Root -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Sync-OpenCodeProjectedRepository {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $logicalRepo = [string]$Projection.LogicalWorkingDirectory
    $physicalRepo = [string]$Projection.PhysicalWorkingDirectory
    Assert-OpenCodeProjectionSource -Path $physicalRepo
    $initialLogical = @($Projection.LogicalRepositoryFiles | ForEach-Object { ([string]$_).Replace('\', '/') })
    $excluded = @($Projection.ExcludedRepositoryFiles | ForEach-Object { ([string]$_).Replace('\', '/') })
    $injected = @($Projection.RunnerInjectedRepositoryFiles | ForEach-Object { ([string]$_).Replace('\', '/') })

    $isExcluded = {
        param([string]$Relative)
        @($excluded | Where-Object { $_ -eq $Relative }).Count -gt 0
    }
    $isInjected = {
        param([string]$Relative)
        @($injected | Where-Object { $_ -eq $Relative -or $Relative.StartsWith($_ + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    }
    $isKnownRuntimeOnly = {
        param([string]$Relative)
        if ($Relative.StartsWith('.opencode/node_modules/', [System.StringComparison]::OrdinalIgnoreCase) -and $initialLogical -notcontains $Relative) { return $true }
        if ($Relative -eq '.opencode/.gitignore' -and $initialLogical -notcontains $Relative) { return $true }
        return $false
    }
    $copyFile = {
        param([string]$Relative)
        $normalized = $Relative.Replace('\', '/')
        if ((& $isExcluded $normalized) -or (& $isInjected $normalized) -or (& $isKnownRuntimeOnly $normalized)) { return }
        $physicalPath = Join-Path $physicalRepo ($normalized -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $physicalPath -PathType Leaf)) { return }
        $logicalPath = Join-Path $logicalRepo ($normalized -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $logicalPath) -Force | Out-Null
        Copy-Item -LiteralPath $physicalPath -Destination $logicalPath -Force
    }

    # Deletes are limited to the original logical repository set. Interaction
    # source files are deliberately excluded from the physical projection and
    # therefore can never be treated as task deletions.
    foreach ($relative in $initialLogical) {
        if (& $isExcluded $relative) { continue }
        $physicalPath = Join-Path $physicalRepo ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $physicalPath -PathType Leaf)) {
            $logicalPath = Join-Path $logicalRepo ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $logicalPath -PathType Leaf) { Remove-Item -LiteralPath $logicalPath -Force }
        }
    }

    # Copy both changed original files and newly created task outputs. Candidate
    # skill files and known OpenCode runtime-only files are never copied back.
    foreach ($relative in @(Get-OpenCodeProjectionFileSet -Root $physicalRepo)) {
        & $copyFile $relative
    }
}

function Remove-OpenCodeProjectedCandidateSkill {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $candidatePath = [string]$Projection.PhysicalSkillDirectory
    if ([string]::IsNullOrWhiteSpace($candidatePath)) { return }
    $physicalRepo = [System.IO.Path]::GetFullPath([string]$Projection.PhysicalWorkingDirectory)
    $candidateFull = [System.IO.Path]::GetFullPath($candidatePath)
    if (-not (Test-PathInside -BasePath $physicalRepo -CandidatePath $candidateFull)) {
        throw "Refusing to remove an OpenCode projected candidate skill outside the physical repository: '$candidateFull'."
    }
    $relative = [System.IO.Path]::GetRelativePath($physicalRepo, $candidateFull).Replace('\', '/')
    if ($relative -notmatch '(?i)^\.opencode/skills/[^/]+$') {
        throw "Refusing to remove an OpenCode projected candidate skill outside the native project skill root: '$relative'."
    }
    if (Test-Path -LiteralPath $candidateFull) { Remove-Item -LiteralPath $candidateFull -Recurse -Force }
    $nativeSkillsRoot = Split-Path -Parent $candidateFull
    $nativeProjectRoot = Split-Path -Parent $nativeSkillsRoot
    foreach ($emptyRoot in @($nativeSkillsRoot, $nativeProjectRoot)) {
        if ((Test-Path -LiteralPath $emptyRoot -PathType Container) -and @((Get-ChildItem -LiteralPath $emptyRoot -Force -ErrorAction SilentlyContinue)).Count -eq 0) {
            Remove-Item -LiteralPath $emptyRoot -Force
        }
    }
}

function Remove-OpenCodeExecutionProjection {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $root = [System.IO.Path]::GetFullPath([string]$Projection.Root)
    $parent = [System.IO.Path]::GetFullPath([string]$Projection.Parent)
    if (-not (Test-PathInside -BasePath $parent -CandidatePath $root) -or
        [System.IO.Path]::GetFileName($root) -notmatch '^agentic-opencode-projection-[0-9a-f-]+$') {
        throw "Refusing to remove an OpenCode projection outside its validated temporary parent: '$root'."
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

function Get-OpenCodeCommandFingerprint {
    param([Parameter(Mandatory = $true)][object]$CommandInfo)

    try {
        $source = (Resolve-Path -LiteralPath ([string]$CommandInfo.Source) -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $null }
        return [ordered]@{
            source = $source
            sha256 = Get-Sha256HexFromFile -Path $source
        }
    } catch {
        return $null
    }
}

function Get-OpenCodePreflightCacheIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo
    )

    $commandFingerprint = Get-OpenCodeCommandFingerprint -CommandInfo $CommandInfo
    if ($null -eq $commandFingerprint) { return $null }
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $authVariables = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    $adapterPath = Join-Path $PSScriptRoot 'runner.ps1'
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) { return $null }
    $identity = [ordered]@{
        run_path = [System.IO.Path]::GetFullPath($Inputs.Run.RunPath)
        run_json_sha256 = Get-Sha256HexFromFile -Path $Inputs.Run.RunPath
        profile_path = [System.IO.Path]::GetFullPath($Inputs.Profile.Path)
        profile_sha256 = [string]$Inputs.Profile.Hash
        command_source = [string]$commandFingerprint.source
        command_sha256 = [string]$commandFingerprint.sha256
        adapter_sha256 = Get-Sha256HexFromFile -Path $adapterPath
        auth_variables = @($authVariables | Sort-Object -Unique)
        auth_present = @($authVariables | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) } | Sort-Object -Unique)
    }
    $keyText = $identity | ConvertTo-Json -Depth 20 -Compress
    $key = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($keyText))
    $base = Get-OpenCodeProjectionBaseDirectory -Inputs $Inputs
    $cacheRoot = Join-Path $base.Path 'agentic-opencode-preflight-cache'
    return [pscustomobject]@{
        Identity = $identity
        Key = $key
        Path = Join-Path $cacheRoot ($key + '.json')
        Root = $cacheRoot
    }
}

function Save-OpenCodePreflightObservation {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Preflight
    )

    if ([string]$Preflight.status -ne 'compatible') { return $null }
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    if ($null -eq $commandInfo) { return $null }
    $identity = Get-OpenCodePreflightCacheIdentity -Inputs $Inputs -CommandInfo $commandInfo
    if ($null -eq $identity) { return $null }
    New-Item -ItemType Directory -Path $identity.Root -Force | Out-Null
    $record = [ordered]@{
        schema = 'codebeltnet/agentic/opencode-preflight-observation/1'
        created_utc = [DateTime]::UtcNow.ToString('o')
        identity = $identity.Identity
        harness_version = [string](Get-JsonProperty -Object $Preflight.harness -Name 'version' -Default 'unavailable')
        preflight = $Preflight
    }
    [System.IO.File]::WriteAllText($identity.Path, (($record | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    return $identity.Path
}

function Get-OpenCodeCachedPreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    if ($null -eq $commandInfo) { return [pscustomobject]@{ Hit = $false; Preflight = $null; CachePath = $null; Source = 'fresh_preflight' } }
    $identity = Get-OpenCodePreflightCacheIdentity -Inputs $Inputs -CommandInfo $commandInfo
    if ($null -eq $identity -or -not (Test-Path -LiteralPath $identity.Path -PathType Leaf)) {
        return [pscustomobject]@{ Hit = $false; Preflight = $null; CachePath = if ($null -eq $identity) { $null } else { $identity.Path }; Source = 'fresh_preflight' }
    }
    try {
        $record = Read-RunnerJson -Path $identity.Path
        $created = [DateTime]::Parse([string]$record.created_utc).ToUniversalTime()
        if (([DateTime]::UtcNow - $created).TotalSeconds -gt 1800) { throw 'cached OpenCode preflight observation expired.' }
        foreach ($name in @($identity.Identity.Keys)) {
            $expected = $identity.Identity[$name]
            $actual = Get-JsonProperty -Object $record.identity -Name $name -Default $null
            if (($expected | ConvertTo-Json -Depth 20 -Compress) -ne ($actual | ConvertTo-Json -Depth 20 -Compress)) {
                throw "cached OpenCode preflight identity mismatch for '$name'."
            }
        }
        $preflight = Get-JsonProperty -Object $record -Name 'preflight' -Default $null
        if ($null -eq $preflight -or [string]$preflight.status -ne 'compatible') { throw 'cached OpenCode preflight was not compatible.' }
        return [pscustomobject]@{ Hit = $true; Preflight = $preflight; CachePath = $identity.Path; Source = 'authoritative_cached_preflight' }
    } catch {
        return [pscustomobject]@{ Hit = $false; Preflight = $null; CachePath = $identity.Path; Source = 'fresh_preflight' }
    }
}

function Remove-OpenCodePreflightCache {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Get-OpenCodeEventTiming {
    param([AllowEmptyCollection()][string[]]$Timestamps = @())

    $parsed = [System.Collections.Generic.List[DateTimeOffset]]::new()
    foreach ($timestamp in @($Timestamps)) {
        $value = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$value)) {
            $parsed.Add($value)
        }
    }
    if ($parsed.Count -eq 0) { return $null }
    $first = ($parsed | Measure-Object -Property UtcDateTime -Minimum).Minimum
    $last = ($parsed | Measure-Object -Property UtcDateTime -Maximum).Maximum
    return [ordered]@{
        first_event_utc = ([DateTime]$first).ToUniversalTime().ToString('o')
        last_event_utc = ([DateTime]$last).ToUniversalTime().ToString('o')
        structured_event_span_seconds = [Math]::Max(0, [Math]::Round(([DateTime]$last - [DateTime]$first).TotalSeconds, 3))
    }
}

function Get-OpenCodeCapabilityMap {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [bool]$HardFilesystemConfinement = $false,
        [object]$ContinuationCapability = $null
    )

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $capabilities[$capabilityName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName)
    }
    $capabilities['filesystem_confinement'] = if ($HardFilesystemConfinement) { 'supported' } else { 'unsupported' }
    $capabilities['candidate_skill_exposure'] = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' }
    $capabilities['scripted_multi_turn_same_session'] = if ($null -eq $Inputs.Run.Interaction) {
        'conditional'
    } elseif ($null -ne $ContinuationCapability -and [bool]$ContinuationCapability.Available) {
        'supported'
    } else {
        'unsupported'
    }
    return $capabilities
}

function Get-OpenCodePreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflightStarted = [DateTime]::UtcNow
    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $platform = Get-PlatformName
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $versionObservation = $null
    $help = $null
    $debugHelp = $null
    $debugConfig = $null
    $runtimeHomeObservation = $null
    $homeIsolationObservation = $null
    $policyObservation = $null
    $debugConfigObservation = $null
    $openCodeEnvironment = $null
    $continuationCapability = [pscustomobject]@{
        Available = $false
        Flag = $null
        ArgumentStyle = $null
        Parameter = $null
        HelpEvidence = $null
        Reason = 'OpenCode exact-session continuation was not probed because no scripted interaction is present.'
    }
    $projectionPlan = $null
    try {
        $projectionPlan = Get-OpenCodeProjectionPlan -Inputs $Inputs
        $checks.Add((New-PreflightCheck -Name 'physical_projection' -Status passed -Detail 'Behavioral OpenCode execution will use one physical projection outside the prepared run and its source-repository ancestry.'))
    } catch {
        $reasons.Add("OpenCode physical projection is unavailable: $($_.Exception.Message)")
        $checks.Add((New-PreflightCheck -Name 'physical_projection' -Status failed -Detail 'The adapter could not prove a physical execution root outside the source-repository ancestry.'))
    }

    if ($profile.Runner -ne 'opencode') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than opencode.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is opencode.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('OpenCode requires a model in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail $profile.Model))
    }
    if ([int]$profile.Concurrency -lt 2) {
        $checks.Add((New-PreflightCheck -Name 'parallel_dispatch' -Status failed -Detail 'OpenCode native-worker evaluations require at least two concurrent worker slots; a serial execution profile is not supported.'))
        $reasons.Add('OpenCode native-worker evaluations require execution-profile.json concurrency >= 2. Sequential dispatch is incompatible unless the external harness reports a capacity limit during orchestration.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'parallel_dispatch' -Status passed -Detail "OpenCode native-worker evaluations require bounded concurrent dispatch; requested slots=$($profile.Concurrency)."))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by opencode.")
    }
    if ($profile.ToolProfile -ne 'default') {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by opencode.")
    }
    if ($null -eq $commandInfo) {
        $reasons.Add('The OpenCode CLI executable is not available on PATH.')
        if ($null -ne $run.Interaction) {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The OpenCode executable is unavailable, so exact-session continuation cannot be proven before execution.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible: the OpenCode executable is unavailable and no model-free run --help probe can run.')
        }
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            # Build the exact child environment once. Every model-free probe
            # and every later OpenCode turn uses this same isolation policy.
            $openCodeEnvironment = New-OpenCodeEnvironment -Inputs $Inputs
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment $openCodeEnvironment -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The OpenCode CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'opencode --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }
            $runtimeHomeObservation = Get-OpenCodeRuntimeHomeObservation -CommandInfo $commandInfo -Inputs $Inputs -Environment $openCodeEnvironment
            $homeIsolationObservation = Get-OpenCodeHomeIsolationObservation -Inputs $Inputs -Environment $openCodeEnvironment -RuntimeHome $runtimeHomeObservation
            if ([bool]$homeIsolationObservation.Valid) {
                $checks.Add((New-PreflightCheck -Name 'effective_home' -Status passed -Detail ("Node/OpenCode resolved home '{0}' from the isolated child environment." -f $homeIsolationObservation.RuntimeHome)))
            } else {
                $checks.Add((New-PreflightCheck -Name 'effective_home' -Status failed -Detail $homeIsolationObservation.Reason))
                $reasons.Add('OpenCode effective-home isolation is incompatible: ' + $homeIsolationObservation.Reason)
            }
            $policyObservation = Get-OpenCodeSkillPolicyObservation -Inputs $Inputs -Environment $openCodeEnvironment
            if ([bool]$policyObservation.permission_match -and [bool]$policyObservation.external_skill_scans_disabled -and [bool]$policyObservation.claude_code_skill_scans_disabled) {
                $checks.Add((New-PreflightCheck -Name 'skill_isolation_policy' -Status passed -Detail 'OpenCode permission.skill and external-skill disable flags match the requested arm.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'skill_isolation_policy' -Status failed -Detail ([string]$policyObservation.reason)))
                $reasons.Add('OpenCode skill-isolation policy is incompatible: ' + [string]$policyObservation.reason)
            }
            $help = Get-OpenCodeHelpResult -CommandInfo $commandInfo -Inputs $Inputs -Environment $openCodeEnvironment
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $helpFailureReason = "OpenCode run --help failed with exit status $($help.ExitCode); single-turn CLI controls cannot be proven."
                $reasons.Add($helpFailureReason)
                if ($null -ne $run.Interaction) {
                    $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $helpFailureReason))
                    $reasons.Add('scripted_multi_turn_same_session is incompatible: exact-session continuation cannot be proven without run --help.')
                }
            } else {
                $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
                foreach ($flag in @('--format', '--dir', '--model', '--auto')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed OpenCode CLI does not advertise required flag '$flag'.")
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$profile.ReasoningEffort) -and $helpText -notmatch [regex]::Escape('--variant')) {
                    $reasons.Add("execution-profile.json requests reasoning_effort '$($profile.ReasoningEffort)', but the installed OpenCode CLI does not advertise --variant.")
                }
                $visiblePlatform = if ($platform -eq 'linux' -and $null -ne $sandboxInfo) { 'linux' } else { $platform }
                $constructed = New-OpenCodeCliArguments -Inputs $Inputs -VisiblePlatform $visiblePlatform
                foreach ($forbidden in @('--pure', '--continue', '--session')) {
                    if (@($constructed) -contains $forbidden) { $reasons.Add("The constructed OpenCode invocation must not use session or project-suppression option '$forbidden'.") }
                }
                $debugHelp = Get-OpenCodeDebugHelpResult -CommandInfo $commandInfo -Inputs $Inputs -Environment $openCodeEnvironment
                $debugHelpText = [string]::Join("`n", @($debugHelp.Stdout, $debugHelp.Stderr))
                $debugConfigAdvertised = -not $debugHelp.TimedOut -and $debugHelp.ExitCode -eq 0 -and $debugHelpText -match '(?i)(^|\s)config(\s|$)'
                if ($debugConfigAdvertised) {
                    $debugConfig = Get-OpenCodeDebugConfigResult -CommandInfo $commandInfo -Inputs $Inputs -Environment $openCodeEnvironment
                    $debugConfigObservation = Get-OpenCodeDebugConfigObservation -DebugResult $debugConfig -Inputs $Inputs
                    if (-not [bool]$debugConfigObservation.available -or -not [bool]$debugConfigObservation.permission_match) {
                        $checks.Add((New-PreflightCheck -Name 'skill_permission_debug' -Status failed -Detail ([string]$debugConfigObservation.reason)))
                        $reasons.Add('Installed OpenCode advertises debug config, but its effective permission.skill policy was not proven: ' + [string]$debugConfigObservation.reason)
                    } else {
                        $checks.Add((New-PreflightCheck -Name 'skill_permission_debug' -Status passed -Detail 'Installed OpenCode debug config reports the exact permission.skill policy for this arm.'))
                    }
                } else {
                    $checks.Add((New-PreflightCheck -Name 'skill_permission_debug' -Status not_applicable -Detail 'Installed OpenCode does not advertise a model-free debug config command; filesystem/home isolation remains authoritative.'))
                }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'OpenCode run advertises noninteractive, model, directory, and structured-output controls; the adapter intentionally does not use --pure.'))
                }
                if ($null -ne $run.Interaction) {
                    $continuationProbe = Get-OpenCodeContinuationCapability -HelpText $helpText
                    $continuationCapability = $continuationProbe
                    if ([bool]$continuationProbe.Available) {
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status passed -Detail ("OpenCode run --help proves explicit exact-session continuation through {0} {1}; resumed invocations retain --format json, --model, --dir, --auto, and the isolated environment." -f $continuationProbe.Flag, $continuationProbe.Parameter)))
                    } else {
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $continuationCapability.Reason))
                        $reasons.Add('scripted_multi_turn_same_session is incompatible: ' + $continuationCapability.Reason)
                    }
                }
            }
        } catch {
            $reasons.Add("Could not inspect OpenCode CLI capabilities: $($_.Exception.Message)")
            if ($null -ne $run.Interaction -and @($checks | Where-Object { $_.name -eq 'scripted_multi_turn_same_session' }).Count -eq 0) {
                $continuationCapability.Reason = 'OpenCode capability inspection failed before exact-session continuation could be proven.'
                $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $continuationCapability.Reason))
            }
        }
    }

    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$profile.Model)
    $authVariable = if ([string]::IsNullOrWhiteSpace($modelProvider)) { $null } else { Get-OpenCodeAuthVariable -Provider $modelProvider }
    $knownAuthVariables = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    if ($knownAuthVariables.Count -eq 0) {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status not_applicable -Detail 'No runner-known provider API-key environment variable is required for this OpenCode model selector.'))
    } elseif ([string]::IsNullOrWhiteSpace($authVariable)) {
        $reasons.Add("No narrow provider authentication environment variable is available for model provider '$modelProvider'. OpenCode global auth profiles are not copied into an eval run.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail "Provider credential will be passed only as $authVariable."))
    }

    if ($platform -notin @('linux', 'macos')) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status not_applicable -Detail "Platform '$platform' has no configured external hard-confinement mechanism; pragmatic isolation remains available."))
        $warnings.Add("Platform '$platform' has no external hard filesystem confinement in this adapter; execution will report pragmatic isolation.")
    } elseif ($null -eq $sandboxInfo) {
        $sandboxName = if ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail "External '$sandboxName' is unavailable; pragmatic isolation remains available."))
        $warnings.Add("External '$sandboxName' was unavailable; execution will report pragmatic isolation.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $($sandboxInfo.Source) sandbox confines the process to the staged run and required system runtime paths."))
    }
    $freshSessionDetail = if ($null -eq $run.Interaction) {
        'The adapter starts one new opencode run process and supplies no resume, continue, or session id.'
    } else {
        'The adapter starts one new opencode run process for turn 1, captures its exact session id from structured events, and resumes scripted turns only with the explicit --session <session-id> flag proven by installed help.'
    }
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail $freshSessionDetail))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter isolates global/user configuration roots, disables external skill discovery, and deliberately preserves repository-owned project configuration; OPENCODE_DISABLE_PROJECT_CONFIG is not used.'))
    $promptFidelityDetail = if ($null -eq $run.Interaction) {
        'The exact prompt bytes are sent on stdin as the first and only task input.'
    } else {
        'The parent runner reads scripted inputs outside the worker-visible projection, projects none of the interaction sidecar/source files, and sends only the current UTF-8 user turn through stdin for each opencode run invocation.'
    }
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail $promptFidelityDetail))
    $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status unavailable -Detail 'Behavioral eval transport is the runner-owned direct OpenCode session; preflight cannot yet observe that session''s resolved model, cwd, HOME/config, fresh identity, prompt, exclusions, or terminal capture, so those controls stay conditional until execute captures the session''s terminal evidence. OpenCode''s native Task/General subagent (and read-only Explore/Scout) remain separate advertised capabilities and are not the transport.'))
    $warnings.Add('OpenCode runner-owned session controls are conditional. Execution must capture the session''s own terminal evidence (model, cwd, isolated OPENCODE_CONFIG_DIR/HOME, fresh session, prompt hash, transcript); the native Task/General subagent is a harness capability, not the benchmark transport.')
    $warnings.Add('OpenCode does not expose a supported child-tool environment filter in this CLI contract; the runner removes unrelated inherited variables but cannot independently prove that the selected provider credential is hidden from every OpenCode-launched tool.')

    $hardConfinement = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-OpenCodeCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement -ContinuationCapability $continuationCapability
    if ($platform -eq 'macos') {
        $warnings.Add('macOS sandbox-exec is deprecated by Apple but is used only when present; a future runner revision may replace it with an equivalent supported mechanism.')
    }
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'OpenCode CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('runner-owned fresh OpenCode CLI session per eval execution', 'opencode run --format json terminal event capture', 'native Task/General subagent available as a separate harness capability, not the transport', 'deterministic runner-owned concurrent fan-out', '--auto', 'isolated OPENCODE_CONFIG_DIR', 'isolated OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'coherent Windows HOME/USERPROFILE/HOMEDRIVE/HOMEPATH', 'OPENCODE_DISABLE_EXTERNAL_SKILLS=1', 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1', 'permission.skill arm policy', 'repository-owned project configuration preserved', 'stdin scripted turn inputs')) { $mechanisms.Add($mechanism) }
    if ($null -ne $run.Interaction -and $continuationCapability.Available) {
        $mechanisms.Add('exact session id captured from turn 1 structured events')
        $mechanisms.Add('explicit --session continuation selected from installed help')
        $mechanisms.Add('exact requested provider/model supplied on every turn')
        $mechanisms.Add('no --continue, implicit last-session, daemon, SSE idle, or session.status dependency')
    } else {
        $mechanisms.Add('no scripted continuation')
    }
    if ($hardConfinement) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    $document = New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
    $preflightFinished = [DateTime]::UtcNow
    $preflightTiming = [ordered]@{
        total_duration_seconds = [Math]::Round(($preflightFinished - $preflightStarted).TotalSeconds, 3)
        probe_count = 0
    }
    if ($null -ne $versionObservation -and $null -ne $versionObservation.Process) {
        $preflightTiming.version_probe_duration_seconds = [double]$versionObservation.Process.DurationSeconds
        $preflightTiming.probe_count++
    }
    if ($null -ne $help) {
        $preflightTiming.help_probe_duration_seconds = [double]$help.DurationSeconds
        $preflightTiming.probe_count++
    }
    if ($null -ne $runtimeHomeObservation -and $null -ne $runtimeHomeObservation.Process) {
        $preflightTiming.effective_home_probe_duration_seconds = [double]$runtimeHomeObservation.Process.DurationSeconds
        $preflightTiming.probe_count++
    }
    if ($null -ne $debugHelp) {
        $preflightTiming.debug_help_probe_duration_seconds = [double]$debugHelp.DurationSeconds
        $preflightTiming.probe_count++
    }
    if ($null -ne $debugConfig) {
        $preflightTiming.debug_config_probe_duration_seconds = [double]$debugConfig.DurationSeconds
        $preflightTiming.probe_count++
    }
    $document.timing = $preflightTiming
    $document.protocol_observations = [ordered]@{
        effective_home = [ordered]@{
            logical_home = [string]$run.HomeDirectoryPath
            physical_isolated_home = [string]$run.HomeDirectoryPath
            effective_runtime_home = if ($null -eq $homeIsolationObservation) { $null } else { [string]$homeIsolationObservation.RuntimeHome }
            effective_runtime_home_source = if ($null -eq $homeIsolationObservation) { 'unavailable' } else { [string]$homeIsolationObservation.RuntimeHomeSource }
            expected_isolated_home = if ($null -eq $homeIsolationObservation) { [string]$run.HomeDirectoryPath } else { [string]$homeIsolationObservation.ExpectedHome }
            matches_isolated_home = if ($null -eq $homeIsolationObservation) { $false } else { [bool]$homeIsolationObservation.RuntimeHomeMatchesExpected }
            matches_real_user_profile = if ($null -eq $homeIsolationObservation) { $false } else { [bool]$homeIsolationObservation.RuntimeHomeMatchesHost }
            windows_profile_parts_coherent = if ($null -eq $homeIsolationObservation) { $false } else { [bool]$homeIsolationObservation.WindowsProfilePartsCoherent }
            host_home_candidates = if ($null -eq $homeIsolationObservation) { @() } else { @($homeIsolationObservation.HostHomeCandidates) }
            environment = if ($null -eq $homeIsolationObservation) { $null } else { $homeIsolationObservation.Environment }
            valid = if ($null -eq $homeIsolationObservation) { $false } else { [bool]$homeIsolationObservation.Valid }
            reason = if ($null -eq $homeIsolationObservation) { 'OpenCode effective-home probe did not run.' } else { [string]$homeIsolationObservation.Reason }
        }
        skill_isolation = [ordered]@{
            candidate_skill_exposed = [bool]$run.CandidateSkillExposed
            candidate_skill_name = if ([bool]$run.CandidateSkillExposed) { Get-OpenCodeCandidateSkillName -Run $run } else { $null }
            candidate_skill_physical_path = $null
            ambient_skill_roots_hidden = $true
            permission_skill = if ($null -eq $policyObservation) { $null } else { $policyObservation.configured_permission_skill }
            expected_permission_skill = if ($null -eq $policyObservation) { Get-OpenCodeSkillPermissionPolicy -Inputs $Inputs } else { $policyObservation.expected_permission_skill }
            permission_match = if ($null -eq $policyObservation) { $false } else { [bool]$policyObservation.permission_match }
            permission_layer = if ($null -eq $debugConfigObservation) { 'unavailable' } elseif ([bool]$debugConfigObservation.available -and [bool]$debugConfigObservation.permission_match) { 'supported_and_verified' } else { 'unavailable_or_unverified' }
            external_skill_scans_disabled = if ($null -eq $policyObservation) { $false } else { [bool]$policyObservation.external_skill_scans_disabled }
            claude_code_skill_scans_disabled = if ($null -eq $policyObservation) { $false } else { [bool]$policyObservation.claude_code_skill_scans_disabled }
            mechanism = if ($null -eq $policyObservation) { 'isolated physical home/config boundary' } else { [string]$policyObservation.mechanism }
            debug_config = $debugConfigObservation
        }
        scripted_multi_turn_same_session = [ordered]@{
            available = [bool]$continuationCapability.Available
            transport = 'opencode-run-explicit-session-continuation'
            flag = [string]$continuationCapability.Flag
            argument_style = [string]$continuationCapability.ArgumentStyle
            parameter = [string]$continuationCapability.Parameter
            help_evidence = [string]$continuationCapability.HelpEvidence
            reason = $continuationCapability.Reason
            structured_output = 'opencode run --format json'
            session_identity_source = 'turn 1 structured JSON events'
            exact_session_required = $true
            implicit_continuation = $false
            sse_dependency = $false
            session_status_dependency = $false
        }
    }
    return $document
}

function New-OpenCodeEnvironment {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    # OpenCode 1.18.x resolves its native global config and skills below
    # XDG_CONFIG_HOME/opencode. Keep that root inside the physical per-run
    # home so HOME, USERPROFILE, and the Windows profile-part variables all
    # identify the same boundary.
    $configDirectory = Join-Path (Join-Path $Inputs.Run.HomeDirectoryPath '.config') 'opencode'
    $appDataDirectory = Join-Path $Inputs.Run.HomeDirectoryPath 'appdata'
    $localAppDataDirectory = Join-Path $Inputs.Run.HomeDirectoryPath 'localappdata'
    foreach ($directory in @($appDataDirectory, $localAppDataDirectory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $configPath = Join-Path $configDirectory 'opencode.json'
    $skillPermission = Get-OpenCodeSkillPermissionPolicy -Inputs $Inputs
    $config = [ordered]@{
        '$schema' = 'https://opencode.ai/config.json'
        permission = [ordered]@{ skill = $skillPermission }
    }
    [System.IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $authVariables = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    $environment = New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables $authVariables -Additional @{
        APPDATA = $appDataDirectory
        LOCALAPPDATA = $localAppDataDirectory
        OPENCODE_CONFIG_DIR = $configDirectory
        OPENCODE_CONFIG = $configPath
        OPENCODE_DISABLE_AUTOUPDATE = '1'
        OPENCODE_DISABLE_EXTERNAL_SKILLS = '1'
        OPENCODE_DISABLE_CLAUDE_CODE_SKILLS = '1'
    }
    # New-RunnerEnvironment intentionally has a broad cross-runner whitelist
    # for compatibility. OpenCode must not inherit NODE_PATH: it can redirect
    # the Node module graph into the user's ambient installation.
    [void]$environment.Remove('NODE_PATH')
    if ((Get-PlatformName) -eq 'windows') {
        $isolatedHomeFull = [System.IO.Path]::GetFullPath([string]$Inputs.Run.HomeDirectoryPath)
        $root = [System.IO.Path]::GetPathRoot($isolatedHomeFull)
        if ([string]::IsNullOrWhiteSpace($root)) { throw "OpenCode isolated home '$isolatedHomeFull' has no Windows path root." }
        $homePart = $isolatedHomeFull.Substring($root.Length).TrimStart([char[]]@('\', '/'))
        $environment['HOMEDRIVE'] = $root.TrimEnd([char[]]@('\', '/'))
        $environment['HOMEPATH'] = '\' + $homePart
    }
    return $environment
}

function Get-LinuxSandboxArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--die-with-parent', '--new-session', '--unshare-pid')) { $args.Add($argument) }
    foreach ($path in @('/usr', '/bin', '/lib', '/lib64', '/etc', '/opt')) {
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
        APPDATA = '/run/home/appdata'
        LOCALAPPDATA = '/run/home/localappdata'
        OPENCODE_CONFIG_DIR = '/run/home/.config/opencode'
        OPENCODE_CONFIG = '/run/home/.config/opencode/opencode.json'
        OPENCODE_DISABLE_AUTOUPDATE = [string]$Environment['OPENCODE_DISABLE_AUTOUPDATE']
        OPENCODE_DISABLE_EXTERNAL_SKILLS = [string]$Environment['OPENCODE_DISABLE_EXTERNAL_SKILLS']
        OPENCODE_DISABLE_CLAUDE_CODE_SKILLS = [string]$Environment['OPENCODE_DISABLE_CLAUDE_CODE_SKILLS']
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $authVariables = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    foreach ($authName in $authVariables) {
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

function New-MacosSandboxProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo
    )

    $profilePath = Join-Path $Inputs.Run.HomeDirectoryPath 'opencode-sandbox.sb'
    $runRoot = $Inputs.Run.RunRoot.Replace('\', '/')
    $commandDirectory = (Split-Path -Parent ([string]$CommandInfo.Source)).Replace('\', '/')
    $systemReadRoots = @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/libexec', '/System', '/Library', '/opt', '/private/var/db', $commandDirectory)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('(version 1)')
    $lines.Add('(deny default)')
    $lines.Add('(allow process*)')
    $lines.Add('(allow network*)')
    foreach ($root in $systemReadRoots | Sort-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            $escapedRoot = $root.Replace('"', '\"')
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

function Write-OpenCodeCapture {
    param(
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $path = Join-Path $RunData.Run.RunRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    return New-ArtifactReference -Run $RunData.Run -Path $RelativePath -Scope run -MediaType (Get-MediaType -Path $RelativePath)
}

function Add-OpenCodeNullableInt64 {
    param([object]$Current, [object]$Value)

    if ($null -eq $Value) { return $Current }
    if ($null -eq $Current) { return [int64]$Value }
    return ([int64]$Current + [int64]$Value)
}

function Read-OpenCodeScriptedTurn {
    param(
        [Parameter(Mandatory = $true)][object]$Parsed,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Warnings
    )

    $finalTextParts = [System.Collections.Generic.List[string]]::new()
    $sessionIds = [System.Collections.Generic.List[string]]::new()
    $observedModels = [System.Collections.Generic.List[string]]::new()
    $eventTimestamps = [System.Collections.Generic.List[string]]::new()
    $eventCounts = @{}
    $usageBuckets = [ordered]@{}
    $toolCalls = 0
    $failureMessage = $null
    $terminalEventObserved = $false
    foreach ($event in @($Parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $Warnings.Add('OpenCode emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        foreach ($sessionId in @(Get-OpenCodeEventSessionIds -Event $event)) {
            if ($sessionIds -notcontains $sessionId) { $sessionIds.Add($sessionId) }
        }
        foreach ($modelName in @(Get-OpenCodeEventModels -Event $event)) {
            if ($observedModels -notcontains $modelName) { $observedModels.Add($modelName) }
        }
        foreach ($timestamp in @(
                (Get-JsonProperty -Object $event -Name 'timestamp' -Default $null),
                (Get-JsonProperty -Object $event -Name 'timestamp_utc' -Default $null)
            )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$timestamp) -and $eventTimestamps -notcontains [string]$timestamp) { $eventTimestamps.Add([string]$timestamp) }
        }
        $part = Get-JsonProperty -Object $event -Name 'part' -Default $null
        switch ($eventType) {
            'text' {
                $text = Get-JsonProperty -Object $event -Name 'text' -Default (Get-JsonProperty -Object $part -Name 'text' -Default '')
                if (-not [string]::IsNullOrWhiteSpace([string]$text)) { $finalTextParts.Add([string]$text) }
            }
            'step_finish' {
                $terminalEventObserved = $true
                $tokens = Get-JsonProperty -Object $part -Name 'tokens' -Default (Get-JsonProperty -Object $event -Name 'tokens' -Default $null)
                if ($null -ne $tokens) {
                    foreach ($name in @('input', 'output', 'reasoning', 'cache_read', 'cache_write')) {
                        $value = Get-JsonProperty -Object $tokens -Name $name -Default $null
                        if ($null -ne $value) { $usageBuckets[$name] = Add-OpenCodeNullableInt64 -Current (Get-JsonProperty -Object $usageBuckets -Name $name -Default $null) -Value $value }
                    }
                }
                $costValue = Get-JsonProperty -Object $part -Name 'cost' -Default (Get-JsonProperty -Object $event -Name 'cost' -Default $null)
                if ($null -ne $costValue) { $usageBuckets['cost'] = Add-OpenCodeNullableInt64 -Current (Get-JsonProperty -Object $usageBuckets -Name 'cost' -Default $null) -Value $costValue }
            }
            'tool_use' { $toolCalls++ }
            'error' { $failureMessage = [string](Get-JsonProperty -Object $event -Name 'message' -Default (Get-JsonProperty -Object $part -Name 'message' -Default 'OpenCode emitted an error.')) }
            { $_ -in @('session.completed', 'run.completed', 'done') } { $terminalEventObserved = $true }
            'step_start' { }
            'reasoning' { }
            default { $Warnings.Add("Unknown OpenCode event '$eventType' was preserved as a warning.") }
        }
    }
    return [pscustomobject]@{
        FinalText = if ($finalTextParts.Count -gt 0) { [string]::Join('', $finalTextParts) } else { $null }
        SessionIds = @($sessionIds.ToArray())
        ObservedModels = @($observedModels.ToArray())
        EventTimestamps = @($eventTimestamps.ToArray())
        EventTiming = Get-OpenCodeEventTiming -Timestamps @($eventTimestamps.ToArray())
        EventCounts = $eventCounts
        UsageBuckets = $usageBuckets
        ToolCalls = $toolCalls
        FailureMessage = $failureMessage
        TerminalEventObserved = $terminalEventObserved
        StructuredEventCount = @($Parsed.Events).Count
        ParseErrorCount = @($Parsed.Errors).Count
    }
}

function Get-OpenCodeInteractionSourcePhysicalPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Projection
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($turn in @($Inputs.Run.Interaction.turns)) {
        $source = [string](Get-JsonProperty -Object $turn -Name 'source' -Default '')
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        $logicalSource = Resolve-ContainedPath -BasePath $Inputs.Run.RunRoot -RelativePath $source -FieldName 'interaction turn source' -Kind File
        if (Test-PathInside -BasePath $Inputs.Run.WorkingDirectoryPath -CandidatePath $logicalSource) {
            $relative = [System.IO.Path]::GetRelativePath($Inputs.Run.WorkingDirectoryPath, $logicalSource)
            $paths.Add((Join-Path $Projection.PhysicalWorkingDirectory ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
        } elseif (Test-PathInside -BasePath $Inputs.Run.HomeDirectoryPath -CandidatePath $logicalSource) {
            $relative = [System.IO.Path]::GetRelativePath($Inputs.Run.HomeDirectoryPath, $logicalSource)
            $paths.Add((Join-Path $Projection.PhysicalHomeDirectory ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
        }
    }
    return @($paths.ToArray() | Select-Object -Unique)
}

function Get-OpenCodeInteractionJsonPhysicalPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Projection
    )

    if ($null -eq $Inputs.Run.InteractionPath) { return @() }
    $paths = [System.Collections.Generic.List[string]]::new()
    if (Test-PathInside -BasePath $Inputs.Run.WorkingDirectoryPath -CandidatePath $Inputs.Run.InteractionPath) {
        $relative = [System.IO.Path]::GetRelativePath($Inputs.Run.WorkingDirectoryPath, $Inputs.Run.InteractionPath)
        $paths.Add((Join-Path $Projection.PhysicalWorkingDirectory ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    } elseif (Test-PathInside -BasePath $Inputs.Run.HomeDirectoryPath -CandidatePath $Inputs.Run.InteractionPath) {
        $relative = [System.IO.Path]::GetRelativePath($Inputs.Run.HomeDirectoryPath, $Inputs.Run.InteractionPath)
        $paths.Add((Join-Path $Projection.PhysicalHomeDirectory ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    }
    return @($paths.ToArray() | Select-Object -Unique)
}

function Get-OpenCodeFutureTurnCanary {
    param([Parameter(Mandatory = $true)][object]$Run)

    $seed = [string]$Run.InteractionHash
    if ([string]::IsNullOrWhiteSpace($seed)) { $seed = Get-Sha256HexFromFile -Path $Run.InteractionPath }
    return 'CODEBELT_FUTURE_TURN_CANARY_' + $seed.Substring(0, [Math]::Min(16, $seed.Length)).ToUpperInvariant()
}

function Test-OpenCodeCanaryInTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Canary
    )

    if ([string]::IsNullOrWhiteSpace($Canary) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -like "*$Canary*") { return $true }
        try {
            if ([System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false)).Contains($Canary)) { return $true }
        } catch { }
    }
    return $false
}

function Invoke-OpenCodeExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflightCache = $null
    try {
    $preflightCache = Get-OpenCodeCachedPreflight -Inputs $Inputs
    $preflightSource = [string]$preflightCache.Source
    $preflight = if ([bool]$preflightCache.Hit) { $preflightCache.Preflight } else { Get-OpenCodePreflight -Inputs $Inputs }
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $executionDescriptor = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $executionDescriptor[$key] = $descriptor[$key] }
    $executionDescriptor.harness = $preflight.harness
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message ([string]::Join('; ', @($preflight.reasons)))) -SessionId $sessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight; preflight_source = $preflightSource; resume = $false }) -AttemptCount 1
    }

    if ($null -ne $Inputs.Run.Interaction) {
        return Invoke-OpenCodeScriptedExecute -Inputs $Inputs -Preflight $preflight -ExecutionDescriptor $executionDescriptor -PreflightSource $preflightSource
    }

    $projection = $null
    $singleResult = $null
    try {
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $projection = New-OpenCodeExecutionProjection -Inputs $Inputs
    $executionInputs = $projection.Inputs
    $environment = New-OpenCodeEnvironment -Inputs $executionInputs
    $runtimeHomeObservation = Get-OpenCodeRuntimeHomeObservation -CommandInfo $commandInfo -Inputs $executionInputs -Environment $environment
    $homeIsolationObservation = Get-OpenCodeHomeIsolationObservation -Inputs $executionInputs -Environment $environment -RuntimeHome $runtimeHomeObservation
    $policyObservation = Get-OpenCodeSkillPolicyObservation -Inputs $executionInputs -Environment $environment
    $skillIsolationObservation = Get-OpenCodeSkillRootObservation -Inputs $executionInputs
    $isolationReasons = [System.Collections.Generic.List[string]]::new()
    if (-not [bool]$homeIsolationObservation.Valid) { $isolationReasons.Add([string]$homeIsolationObservation.Reason) }
    if (-not [bool]$policyObservation.permission_match -or -not [bool]$policyObservation.external_skill_scans_disabled -or -not [bool]$policyObservation.claude_code_skill_scans_disabled) { $isolationReasons.Add([string]$policyObservation.reason) }
    if (-not [bool]$skillIsolationObservation.Valid) { $isolationReasons.Add([string]$skillIsolationObservation.Reason) }
    if ($isolationReasons.Count -gt 0) {
        $singleResult = New-OpenCodeIsolationFailureResult -LogicalInputs $Inputs -ExecutionDescriptor $executionDescriptor -Preflight $preflight -Projection $projection -Environment $environment -HomeIsolation $homeIsolationObservation -PolicyObservation $policyObservation -SkillIsolation $skillIsolationObservation -PreflightSource $preflightSource -Reasons @($isolationReasons.ToArray()) -SessionId $sessionId -StartedUtc $started -Resume $false
        return $singleResult
    }
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $model = [string]$Inputs.Profile.Model
    $arguments = New-OpenCodeCliArguments -Inputs $executionInputs -VisiblePlatform $visiblePlatform

    if ($platform -eq 'linux' -and $hardFilesystem) {
        $sandboxArguments = Get-LinuxSandboxArguments -Inputs $executionInputs -CommandInfo $commandInfo -Environment $environment
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $executionInputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $executionInputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } elseif ($platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosSandboxProfile -Inputs $executionInputs -CommandInfo $commandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $commandInfo.FileName) + @($commandInfo.Prefix) + $arguments
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $executionInputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $executionInputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } else {
        $process = Invoke-OpenCodeCli -CommandInfo $commandInfo -Arguments $arguments -Inputs $executionInputs -Environment $environment -InputBytes $executionInputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    }

    $stdoutArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact); $artifacts.Add($stderrArtifact)
    $parsed = ConvertFrom-JsonLines -Text $process.Stdout
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("OpenCode event parse error: $parseError") }
    $finalTextParts = [System.Collections.Generic.List[string]]::new()
    $sessionIds = [System.Collections.Generic.List[string]]::new()
    $observedModels = [System.Collections.Generic.List[string]]::new()
    $eventTimestamps = [System.Collections.Generic.List[string]]::new()
    $eventCounts = @{}
    $toolCalls = 0
    $commands = [System.Collections.Generic.List[object]]::new()
    $usageBuckets = [ordered]@{}
    $failureMessage = $null
    $terminalEventObserved = $false
    foreach ($event in @($parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $warnings.Add('OpenCode emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        foreach ($eventSessionId in @(Get-OpenCodeEventSessionIds -Event $event)) {
            if ($sessionIds -notcontains $eventSessionId) { $sessionIds.Add($eventSessionId) }
        }
        foreach ($eventModel in @(Get-OpenCodeEventModels -Event $event)) {
            if ($observedModels -notcontains $eventModel) { $observedModels.Add($eventModel) }
        }
        foreach ($timestamp in @(
                (Get-JsonProperty -Object $event -Name 'timestamp' -Default $null),
                (Get-JsonProperty -Object $event -Name 'timestamp_utc' -Default $null)
            )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$timestamp) -and $eventTimestamps -notcontains [string]$timestamp) { $eventTimestamps.Add([string]$timestamp) }
        }
        $part = Get-JsonProperty -Object $event -Name 'part' -Default $null
        switch ($eventType) {
            'text' {
                $text = Get-JsonProperty -Object $event -Name 'text' -Default (Get-JsonProperty -Object $part -Name 'text' -Default '')
                if (-not [string]::IsNullOrWhiteSpace([string]$text)) { $finalTextParts.Add([string]$text) }
            }
            'step_finish' {
                $terminalEventObserved = $true
                $tokens = Get-JsonProperty -Object $part -Name 'tokens' -Default (Get-JsonProperty -Object $event -Name 'tokens' -Default $null)
                if ($null -ne $tokens) {
                    foreach ($name in @('input', 'output', 'reasoning', 'cache_read', 'cache_write')) {
                        $value = Get-JsonProperty -Object $tokens -Name $name -Default $null
                        if ($null -ne $value) { $usageBuckets[$name] = $value }
                    }
                }
                $costValue = Get-JsonProperty -Object $part -Name 'cost' -Default (Get-JsonProperty -Object $event -Name 'cost' -Default $null)
                if ($null -ne $costValue) { $usageBuckets['cost'] = $costValue }
            }
            'tool_use' {
                $toolCalls++
                $toolName = Get-JsonProperty -Object $part -Name 'tool' -Default (Get-JsonProperty -Object $event -Name 'tool' -Default '')
                $commands.Add([ordered]@{ tool = [string]$toolName })
            }
            'error' {
                $failureMessage = [string](Get-JsonProperty -Object $event -Name 'message' -Default (Get-JsonProperty -Object $part -Name 'message' -Default 'OpenCode emitted an error.'))
            }
            { $_ -in @('session.completed', 'run.completed', 'done') } { $terminalEventObserved = $true }
            'step_start' { }
            'reasoning' { }
            default { $warnings.Add("Unknown OpenCode event '$eventType' was preserved as a warning.") }
        }
    }
    $finalText = if ($finalTextParts.Count -gt 0) { [string]::Join('', $finalTextParts) } else { $null }
    $observedSessionIds = @($sessionIds.ToArray())
    $exactSessionId = if ($observedSessionIds.Count -eq 1) { [string]$observedSessionIds[0] } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($exactSessionId)) { $sessionId = $exactSessionId }
    $eventTiming = Get-OpenCodeEventTiming -Timestamps @($eventTimestamps.ToArray())
    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'; $reason = 'opencode_timeout'; $failure = New-ExecutionFailure -Code 'timed_out' -Message 'OpenCode did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $failureMessage) {
        $status = 'failed'; $reason = 'opencode_failure'; $failure = New-ExecutionFailure -Code 'opencode_failure' -Message ([string]$failureMessage)
    } elseif (@($parsed.Errors).Count -gt 0) {
        $status = 'incompatible'; $reason = 'native_interaction_incompatible'; $failure = New-ExecutionFailure -Code 'native_interaction_incompatible' -Message 'OpenCode single-turn execution did not produce a complete structured JSON event stream.'
    } elseif ($observedSessionIds.Count -ne 1) {
        $status = 'incompatible'; $reason = 'native_interaction_incompatible'; $failure = New-ExecutionFailure -Code 'native_interaction_incompatible' -Message 'OpenCode single-turn execution did not expose exactly one non-empty session id in structured events.'
    } elseif (@($observedModels | Where-Object { [string]$_ -ne [string]$Inputs.Profile.Model }).Count -gt 0) {
        $status = 'incompatible'; $reason = 'native_interaction_incompatible'; $failure = New-ExecutionFailure -Code 'native_interaction_incompatible' -Message "OpenCode single-turn execution reported a model different from the requested model '$($Inputs.Profile.Model)'."
    } elseif (-not [bool]$terminalEventObserved) {
        $status = 'incompatible'; $reason = 'native_interaction_incompatible'; $failure = New-ExecutionFailure -Code 'native_interaction_incompatible' -Message 'OpenCode single-turn execution did not emit a terminal structured event.'
    } elseif ([string]::IsNullOrWhiteSpace($finalText)) {
        $reason = 'opencode_did_not_return_final_response'; $warnings.Add('OpenCode exited successfully without a text response.')
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/opencode-events.jsonl'; complete = $true })
        tokens = if ($usageBuckets.Count -eq 0) { New-UnavailableMetric -Reason 'opencode_did_not_expose_usage' } else { New-AvailableMetric -Value $usageBuckets }
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = if ($usageBuckets.Contains('cost')) { New-AvailableMetric -Value $usageBuckets['cost'] } else { New-UnavailableMetric -Reason 'opencode_did_not_expose_cost' }
    }
    $capabilities = Get-OpenCodeCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('opencode run --format json', '--auto', 'isolated OPENCODE_CONFIG_DIR', 'isolated OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'repository-owned project configuration preserved', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement'); $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $sandboxEvidence = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $credentialNames = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    $credentialEvidence = [ordered]@{
        model_provider = $modelProvider
        provider_environment_variables = $credentialNames
        unrelated_environment_excluded = $true
        child_tool_visibility = 'provider_credential_may_be_visible_to_native_child_tools; no supported child filter is exposed'
        value_observed = $false
    }
    # Runner-owned terminal evidence for the direct OpenCode session. The runner
    # controlled the fresh session, its model lock, working directory, isolated
    # OPENCODE_CONFIG_DIR/HOME, and stdin prompt, and captured the session's own
    # structured event transcript. This is transport-owned evidence, never
    # orchestrator-authored.
    $transcriptArtifactPath = 'evidence/opencode-events.jsonl'
    $transcriptArtifact = @($artifacts | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'path' -Default '') -eq $transcriptArtifactPath } | Select-Object -First 1)
    $terminalCapture = $status -eq 'completed' -and $observedSessionIds.Count -eq 1 -and (-not $process.TimedOut) -and (-not [string]::IsNullOrWhiteSpace([string]$process.Stdout)) -and [bool]$terminalEventObserved
    $executionPaths = New-OpenCodeExecutionPaths -LogicalInputs $Inputs -ExecutionInputs $executionInputs -Projection $projection -Environment $environment -HomeIsolation $homeIsolationObservation
    $candidateSkillExposure = New-OpenCodeCandidateSkillExposure -LogicalInputs $Inputs -Projection $projection -SkillIsolation $skillIsolationObservation
    $evidence = [ordered]@{
        execution_paths = $executionPaths
        event_counts = $eventCounts
        commands = @($commands)
        observed_session_ids = @($observedSessionIds)
        prompt_first_input = $true
        resume = $false
        model_argument = $model
        observed_model = if ($observedModels.Count -eq 0) { [string]$model } else { [string]$observedModels[$observedModels.Count - 1] }
        observed_models = @($observedModels.ToArray())
        sandbox = $sandboxEvidence
        project_configuration = 'repository_owned_project_config_preserved'
        disable_project_config_environment = $false
        credential = $credentialEvidence
        candidate_skill_exposure = $candidateSkillExposure
        effective_home = New-OpenCodeHomeIsolationEvidence -Observation $homeIsolationObservation
        skill_policy = $policyObservation
        skill_isolation = New-OpenCodeSkillIsolationEvidence -Observation $skillIsolationObservation
        ambient_skill_policy = [ordered]@{
            mechanism = [string]$policyObservation.mechanism
            permission_skill = $policyObservation.configured_permission_skill
            external_skill_scans_disabled = [bool]$policyObservation.external_skill_scans_disabled
            claude_code_skill_scans_disabled = [bool]$policyObservation.claude_code_skill_scans_disabled
            ambient_skill_roots_hidden = [int]$skillIsolationObservation.AmbientSkillCount -eq 0
            candidate_skill_exposed = [bool]$executionInputs.Run.CandidateSkillExposed
            candidate_skill_physical_path = if ([bool]$executionInputs.Run.CandidateSkillExposed) { [string]$projection.PhysicalSkillDirectory } else { $null }
        }
        timing = [ordered]@{
            preflight = Get-JsonProperty -Object $preflight -Name 'timing' -Default $null
            preflight_source = $preflightSource
            projection_setup_duration_seconds = [double]$projection.SetupDurationSeconds
            native_cli_process_total_seconds = [double]$process.DurationSeconds
            turns = @([ordered]@{
                turn = 1
                invocation = 'fresh'
                process_duration_seconds = [double]$process.DurationSeconds
                cli_startup_and_execution_duration_seconds = [double]$process.DurationSeconds
            })
            total_runner_execution_seconds = [double]$process.DurationSeconds
        }
        capture = [ordered]@{
            source = 'harness_native_transport'
            terminal = [bool]$terminalCapture
            worker_authored = $false
            artifact = $transcriptArtifactPath
            sha256 = if ($transcriptArtifact.Count -eq 1) { [string](Get-JsonProperty -Object $transcriptArtifact[0] -Name 'sha256' -Default $null) } else { $null }
        }
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = [string]$descriptor.delegation.mechanism
            worker_session_id = $sessionId
            observed_model = if ($observedModels.Count -eq 0) { [string]$model } else { [string]$observedModels[$observedModels.Count - 1] }
            observed_working_directory = [string]$projection.PhysicalWorkingDirectory
            observed_home = [string]$projection.PhysicalHomeDirectory
            effective_runtime_home = [string]$homeIsolationObservation.RuntimeHome
            effective_opencode_config_root = [string]$environment['OPENCODE_CONFIG_DIR']
            fresh_worker = $true
            home_config_isolated = $true
            prompt_fidelity = $true
            prompt_sha256 = [string]$Inputs.Run.PromptHash
            terminal_result_capture = [bool]$terminalCapture
            paired_arm_visible = $false
            grading_material_visible = $false
            nested_model_execution = $false
            model_execution_count = 1
        }
    }
    if ($null -ne $eventTiming) {
        $evidence.timing.turns[0].event_timing = $eventTiming
    }
    $singleResult = New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $process.FinishedUtc.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'OpenCode accepted the requested runner-native model selector and configuration but did not expose concrete backend resolution.'; observations = [ordered]@{ model = $Inputs.Profile.Model; reasoning_effort = $Inputs.Profile.ReasoningEffort } }) -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence $evidence -AttemptCount 1
    return $singleResult
    } finally {
        if ($null -ne $projection) {
            try {
                Remove-OpenCodeProjectedCandidateSkill -Projection $projection
                Sync-OpenCodeProjectedRepository -Projection $projection
            } finally {
                Remove-OpenCodeExecutionProjection -Projection $projection
                if ($null -ne $singleResult -and $null -ne $singleResult.evidence -and $null -ne $singleResult.evidence.execution_paths) {
                    $singleResult.evidence.execution_paths.projection_cleanup = 'removed'
                }
                if ($null -ne $singleResult -and $null -ne $singleResult.evidence -and $null -ne $singleResult.evidence.timing) {
                    $cleanupFinished = [DateTime]::UtcNow
                    $singleResult.evidence.timing.projection_cleanup_duration_seconds = [Math]::Round(($cleanupFinished - $process.FinishedUtc).TotalSeconds, 3)
                    $singleResult.evidence.timing.total_runner_execution_seconds = [Math]::Round(($cleanupFinished - $started).TotalSeconds, 3)
                }
            }
        }
    }
    } finally {
        $cachePath = if ($null -eq $preflightCache) { $null } else { [string]$preflightCache.CachePath }
        Remove-OpenCodePreflightCache -Path $cachePath
    }
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-OpenCodeDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-OpenCodeInputs
            $preflight = Get-OpenCodePreflight -Inputs $inputs
            try { [void](Save-OpenCodePreflightObservation -Inputs $inputs -Preflight $preflight) } catch { }
            Write-RunnerJson -Value $preflight -AsOutput
        }
        'execute' {
            $inputs = Resolve-OpenCodeInputs
            [void](Assert-PhaseOneEvidenceWritable -Run $inputs.Run)
            $result = Invoke-OpenCodeExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
