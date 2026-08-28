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
        # Behavioral evaluation transport is runner-owned: the runner starts one
        # fresh OpenCode serve process and one session per eval execution, then
        # captures synchronous HTTP response evidence. OpenCode's native Task/General subagent
        # remains an advertised harness capability but is NOT the benchmark
        # transport. These controls stay conditional because the runner attests
        # the session it locked; the captured terminal evidence proves them.
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
        mechanism = 'Runner-owned OpenCode server session (opencode serve on 127.0.0.1): the runner starts one fresh process, captures its exact session identity from the installed OpenAPI session-create response, and sends scripted turns through synchronous HTTP message responses'
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

function Get-OpenCodeServeHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment = $null
    )

    $environment = if ($null -eq $Environment) { New-OpenCodeEnvironment -Inputs $Inputs } else { $Environment }
    return Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments @('serve', '--help') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
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
        if (-not [string]::IsNullOrWhiteSpace([string]$value) -and $values -notcontains [string]$value) { $values.Add([string]$value) }
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

function Get-OpenCodeApiProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Resolve-OpenCodeApiSchema {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][object]$Schema
    )

    $current = $Schema
    for ($depth = 0; $depth -lt 12; $depth++) {
        $reference = [string](Get-OpenCodeApiProperty -Object $current -Name '$ref' -Default '')
        if ([string]::IsNullOrWhiteSpace($reference)) { return $current }
        if (-not $reference.StartsWith('#/components/schemas/', [System.StringComparison]::Ordinal)) { return $current }
        $schemaName = [Uri]::UnescapeDataString($reference.Substring('#/components/schemas/'.Length))
        $schemas = Get-OpenCodeApiProperty -Object (Get-OpenCodeApiProperty -Object $Document -Name 'components' -Default $null) -Name 'schemas' -Default $null
        $current = Get-OpenCodeApiProperty -Object $schemas -Name $schemaName -Default $null
        if ($null -eq $current) { return $Schema }
    }
    return $current
}

function Get-OpenCodeApiSchemaBranches {
    param([Parameter(Mandatory = $true)][object]$Schema)

    $branches = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @('anyOf', 'oneOf', 'allOf')) {
        $value = Get-OpenCodeApiProperty -Object $Schema -Name $name -Default $null
        if ($null -ne $value) {
            foreach ($branch in @($value)) { $branches.Add($branch) }
        }
    }
    return @($branches.ToArray())
}

function Get-OpenCodeApiSchemaProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][object]$Schema,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $resolved = Resolve-OpenCodeApiSchema -Document $Document -Schema $Schema
    $properties = Get-OpenCodeApiProperty -Object $resolved -Name 'properties' -Default $null
    $property = Get-OpenCodeApiProperty -Object $properties -Name $Name -Default $null
    if ($null -ne $property) { return $property }
    foreach ($branch in @(Get-OpenCodeApiSchemaBranches -Schema $resolved)) {
        $property = Get-OpenCodeApiSchemaProperty -Document $Document -Schema $branch -Name $Name
        if ($null -ne $property) { return $property }
    }
    return $null
}

function Get-OpenCodeApiSchemaRequired {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][object]$Schema
    )

    $resolved = Resolve-OpenCodeApiSchema -Document $Document -Schema $Schema
    $required = Get-OpenCodeApiProperty -Object $resolved -Name 'required' -Default $null
    if ($null -ne $required) { return @($required | ForEach-Object { [string]$_ }) }
    foreach ($branch in @(Get-OpenCodeApiSchemaBranches -Schema $resolved)) {
        $branchRequired = @(Get-OpenCodeApiSchemaRequired -Document $Document -Schema $branch)
        if ($branchRequired.Count -gt 0) { return $branchRequired }
    }
    return @()
}

function Test-OpenCodeApiSchemaRequired {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][object]$Schema,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $required = @(Get-OpenCodeApiSchemaRequired -Document $Document -Schema $Schema)
    foreach ($name in $Names) {
        if ($required -notcontains $name) { return $false }
    }
    return $true
}

function Get-OpenCodeApiJsonBodySchema {
    param([Parameter(Mandatory = $true)][object]$Document, [Parameter(Mandatory = $true)][object]$Operation)

    $requestBody = Get-OpenCodeApiProperty -Object $Operation -Name 'requestBody' -Default $null
    $content = Get-OpenCodeApiProperty -Object $requestBody -Name 'content' -Default $null
    $jsonContent = Get-OpenCodeApiProperty -Object $content -Name 'application/json' -Default $null
    if ($null -eq $jsonContent) {
        foreach ($contentProperty in @($content.PSObject.Properties)) {
            if ([string]$contentProperty.Name -match '(?i)json') { $jsonContent = $contentProperty.Value; break }
        }
    }
    return Get-OpenCodeApiProperty -Object $jsonContent -Name 'schema' -Default $null
}

function Get-OpenCodeApiResponseSchema {
    param([Parameter(Mandatory = $true)][object]$Document, [Parameter(Mandatory = $true)][object]$Operation)

    $responses = Get-OpenCodeApiProperty -Object $Operation -Name 'responses' -Default $null
    foreach ($responseProperty in @($responses.PSObject.Properties | Sort-Object Name)) {
        if ([string]$responseProperty.Name -match '^2\d\d$') {
            $content = Get-OpenCodeApiProperty -Object $responseProperty.Value -Name 'content' -Default $null
            foreach ($contentProperty in @($content.PSObject.Properties)) {
                if ([string]$contentProperty.Name -match '(?i)json') {
                    return Get-OpenCodeApiProperty -Object $contentProperty.Value -Name 'schema' -Default $null
                }
            }
        }
    }
    return $null
}

function Test-OpenCodeApiTextPartsSchema {
    param([Parameter(Mandatory = $true)][object]$Document, [Parameter(Mandatory = $true)][object]$Schema)

    $resolved = Resolve-OpenCodeApiSchema -Document $Document -Schema $Schema
    $items = Get-OpenCodeApiProperty -Object $resolved -Name 'items' -Default $null
    if ($null -ne $items) {
        foreach ($candidate in @($items) + @(Get-OpenCodeApiSchemaBranches -Schema $items)) {
            $candidateResolved = Resolve-OpenCodeApiSchema -Document $Document -Schema $candidate
            $typeValues = @(Get-OpenCodeApiProperty -Object $candidateResolved -Name 'enum' -Default @())
            $candidateType = [string](Get-OpenCodeApiProperty -Object $candidateResolved -Name 'type' -Default '')
            $required = @(Get-OpenCodeApiSchemaRequired -Document $Document -Schema $candidateResolved)
            if (($candidateType -eq 'object' -or $null -ne (Get-OpenCodeApiProperty -Object $candidateResolved -Name 'properties' -Default $null)) -and
                $required -contains 'type' -and $required -contains 'text' -and ($typeValues.Count -eq 0 -or $typeValues -contains 'text')) {
                $textProperty = Get-OpenCodeApiSchemaProperty -Document $Document -Schema $candidateResolved -Name 'text'
                if ($null -ne $textProperty) { return $true }
            }
        }
    }
    return $false
}

function Test-OpenCodeApiAssistantResponseSchema {
    param([Parameter(Mandatory = $true)][object]$Document, [Parameter(Mandatory = $true)][object]$Schema)

    $resolved = Resolve-OpenCodeApiSchema -Document $Document -Schema $Schema
    $infoSchema = Get-OpenCodeApiSchemaProperty -Document $Document -Schema $resolved -Name 'info'
    $partsSchema = Get-OpenCodeApiSchemaProperty -Document $Document -Schema $resolved -Name 'parts'
    if ($null -eq $infoSchema -or $null -eq $partsSchema) { return $false }
    foreach ($infoCandidate in @($infoSchema) + @(Get-OpenCodeApiSchemaBranches -Schema $infoSchema)) {
        $assistant = Resolve-OpenCodeApiSchema -Document $Document -Schema $infoCandidate
        $role = Get-OpenCodeApiSchemaProperty -Document $Document -Schema $assistant -Name 'role'
        $roleValues = @(Get-OpenCodeApiProperty -Object $role -Name 'enum' -Default @())
        if ((Get-OpenCodeApiSchemaRequired -Document $Document -Schema $assistant) -contains 'sessionID' -and
            (Get-OpenCodeApiSchemaRequired -Document $Document -Schema $assistant) -contains 'modelID' -and
            (Get-OpenCodeApiSchemaRequired -Document $Document -Schema $assistant) -contains 'providerID' -and
            ($roleValues.Count -eq 0 -or $roleValues -contains 'assistant')) {
            return $true
        }
    }
    return $false
}

function Get-OpenCodeApiOperationById {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][ValidateSet('get', 'post')][string]$Method
    )

    $paths = Get-OpenCodeApiProperty -Object $Document -Name 'paths' -Default $null
    foreach ($pathProperty in @($paths.PSObject.Properties)) {
        $pathItem = $pathProperty.Value
        $operation = Get-OpenCodeApiProperty -Object $pathItem -Name $Method -Default $null
        if ($null -ne $operation -and [string](Get-OpenCodeApiProperty -Object $operation -Name 'operationId' -Default '') -eq $OperationId) {
            return [pscustomobject]@{ Path = [string]$pathProperty.Name; Operation = $operation }
        }
    }
    return $null
}

function Get-OpenCodeServerApiContract {
    param([Parameter(Mandatory = $true)][object]$Document)

    $create = Get-OpenCodeApiOperationById -Document $Document -OperationId 'session.create' -Method post
    $message = Get-OpenCodeApiOperationById -Document $Document -OperationId 'session.prompt' -Method post
    $abort = Get-OpenCodeApiOperationById -Document $Document -OperationId 'session.abort' -Method post
    $dispose = Get-OpenCodeApiOperationById -Document $Document -OperationId 'instance.dispose' -Method post
    $createBody = if ($null -eq $create) { $null } else { Get-OpenCodeApiJsonBodySchema -Document $Document -Operation $create.Operation }
    $messageBody = if ($null -eq $message) { $null } else { Get-OpenCodeApiJsonBodySchema -Document $Document -Operation $message.Operation }
    $createModel = if ($null -eq $createBody) { $null } else { Get-OpenCodeApiSchemaProperty -Document $Document -Schema $createBody -Name 'model' }
    $messageModel = if ($null -eq $messageBody) { $null } else { Get-OpenCodeApiSchemaProperty -Document $Document -Schema $messageBody -Name 'model' }
    $messageParts = if ($null -eq $messageBody) { $null } else { Get-OpenCodeApiSchemaProperty -Document $Document -Schema $messageBody -Name 'parts' }
    $messageResponse = if ($null -eq $message) { $null } else { Get-OpenCodeApiResponseSchema -Document $Document -Operation $message.Operation }
    $createResponse = if ($null -eq $create) { $null } else { Get-OpenCodeApiResponseSchema -Document $Document -Operation $create.Operation }
    $messageResponseRequired = if ($null -eq $messageResponse) { @() } else { @(Get-OpenCodeApiSchemaRequired -Document $Document -Schema $messageResponse) }
    $checks = [ordered]@{
        session_create = $null -ne $create
        synchronous_message = $null -ne $message
        message_not_async = $null -ne $message -and [string]$message.Path -notmatch '(?i)async' -and [string](Get-OpenCodeApiProperty -Object $message.Operation -Name 'operationId' -Default '') -notmatch '(?i)async'
        session_message_path = $null -ne $message -and [string]$message.Path -match '\{sessionID\}'
        session_create_model = $null -ne $createModel -and (Test-OpenCodeApiSchemaRequired -Document $Document -Schema $createModel -Names @('id', 'providerID'))
        message_model = $null -ne $messageModel -and (Test-OpenCodeApiSchemaRequired -Document $Document -Schema $messageModel -Names @('providerID', 'modelID'))
        text_parts = $null -ne $messageParts -and (Test-OpenCodeApiTextPartsSchema -Document $Document -Schema $messageParts)
        assistant_response = $null -ne $messageResponse -and $messageResponseRequired -contains 'info' -and $messageResponseRequired -contains 'parts' -and (Test-OpenCodeApiAssistantResponseSchema -Document $Document -Schema $messageResponse)
        session_identity = $null -ne $createResponse -and (Get-OpenCodeApiSchemaProperty -Document $Document -Schema $createResponse -Name 'id') -ne $null -and (Get-OpenCodeApiSchemaRequired -Document $Document -Schema $createResponse) -contains 'id'
    }
    $available = @($checks.Values | Where-Object { -not [bool]$_ }).Count -eq 0
    $reason = if ($available) { $null } else { 'Installed OpenCode OpenAPI did not prove every required synchronous scripted-session operation/schema.' }
    return [pscustomobject]@{
        Available = $available
        Reason = $reason
        HealthPath = '/global/health'
        DocPath = '/doc'
        SessionCreatePath = if ($null -eq $create) { $null } else { [string]$create.Path }
        SessionMessagePath = if ($null -eq $message) { $null } else { [string]$message.Path }
        SessionAbortPath = if ($null -eq $abort) { $null } else { [string]$abort.Path }
        InstanceDisposePath = if ($null -eq $dispose) { $null } else { [string]$dispose.Path }
        SessionCreateOperation = if ($null -eq $create) { $null } else { $create.Operation }
        SessionMessageOperation = if ($null -eq $message) { $null } else { $message.Operation }
        Proof = [ordered]@{
            checks = $checks
            openapi = [string](Get-OpenCodeApiProperty -Object $Document -Name 'openapi' -Default '')
            path_count = @((Get-OpenCodeApiProperty -Object $Document -Name 'paths' -Default $null).PSObject.Properties).Count
            session_create_operation_id = if ($null -eq $create) { $null } else { [string](Get-OpenCodeApiProperty -Object $create.Operation -Name 'operationId' -Default '') }
            session_message_operation_id = if ($null -eq $message) { $null } else { [string](Get-OpenCodeApiProperty -Object $message.Operation -Name 'operationId' -Default '') }
        }
    }
}

function Get-OpenCodeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        try { $listener.Stop() } catch { }
    }
}

function Invoke-OpenCodeHttpRequest {
    param(
        [Parameter(Mandatory = $true)][object]$Server,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $started = [DateTime]::UtcNow
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::$Method, ([string]$Server.BaseUri + $Path))
    $cancellation = [System.Threading.CancellationTokenSource]::new()
    $response = $null
    $responseTask = $null
    $readTask = $null
    $bodyText = if ($null -eq $Body) { $null } else { $Body | ConvertTo-Json -Depth 100 -Compress }
    try {
        $request.Headers.Accept.ParseAdd('application/json')
        if ($null -ne $bodyText) {
            $request.Content = [System.Net.Http.StringContent]::new($bodyText, [System.Text.UTF8Encoding]::new($false), 'application/json')
        }
        $cancellation.CancelAfter([Math]::Max(1, [Math]::Min($TimeoutSeconds * 1000, [int]::MaxValue)))
        $responseTask = $Server.Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $cancellation.Token)
        $waitMilliseconds = [int][Math]::Max(1, [Math]::Min($TimeoutSeconds * 1000, [int]::MaxValue))
        if (-not $responseTask.Wait($waitMilliseconds)) {
            $cancellation.Cancel()
            $finished = [DateTime]::UtcNow
            return [pscustomobject]@{ Succeeded = $false; TimedOut = $true; StatusCode = $null; Body = ''; StartedUtc = $started; FinishedUtc = $finished; DurationSeconds = [Math]::Round(($finished - $started).TotalSeconds, 3); Method = $Method; Path = $Path; RequestBody = $bodyText; Error = 'HTTP request exceeded timeout_seconds.' }
        }
        $response = $responseTask.GetAwaiter().GetResult()
        $readTask = $response.Content.ReadAsStringAsync()
        $readMilliseconds = [int][Math]::Max(1, [Math]::Min($TimeoutSeconds * 1000, [int]::MaxValue))
        if (-not $readTask.Wait($readMilliseconds)) {
            $cancellation.Cancel()
            $finished = [DateTime]::UtcNow
            return [pscustomobject]@{ Succeeded = $false; TimedOut = $true; StatusCode = [int]$response.StatusCode; Body = ''; StartedUtc = $started; FinishedUtc = $finished; DurationSeconds = [Math]::Round(($finished - $started).TotalSeconds, 3); Method = $Method; Path = $Path; RequestBody = $bodyText; Error = 'HTTP response body exceeded timeout_seconds.' }
        }
        $responseBody = [string]$readTask.GetAwaiter().GetResult()
        $finished = [DateTime]::UtcNow
        return [pscustomobject]@{
            Succeeded = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300
            TimedOut = $false
            StatusCode = [int]$response.StatusCode
            Body = $responseBody
            StartedUtc = $started
            FinishedUtc = $finished
            DurationSeconds = [Math]::Round(($finished - $started).TotalSeconds, 3)
            Method = $Method
            Path = $Path
            RequestBody = $bodyText
            Error = if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) { $null } else { "HTTP status $([int]$response.StatusCode)." }
        }
    } catch {
        $finished = [DateTime]::UtcNow
        return [pscustomobject]@{ Succeeded = $false; TimedOut = $false; StatusCode = if ($null -eq $response) { $null } else { [int]$response.StatusCode }; Body = ''; StartedUtc = $started; FinishedUtc = $finished; DurationSeconds = [Math]::Round(($finished - $started).TotalSeconds, 3); Method = $Method; Path = $Path; RequestBody = $bodyText; Error = $_.Exception.Message }
    } finally {
        try { $response.Dispose() } catch { }
        try { $request.Dispose() } catch { }
        try { $cancellation.Dispose() } catch { }
    }
}

function Get-OpenCodeDirectoryQuery {
    param([Parameter(Mandatory = $true)][object]$Operation, [Parameter(Mandatory = $true)][string]$Directory)

    $parameters = Get-OpenCodeApiProperty -Object $Operation -Name 'parameters' -Default @()
    $directoryParameter = @($parameters | Where-Object {
        [string](Get-OpenCodeApiProperty -Object $_ -Name 'name' -Default '') -eq 'directory' -and
        [string](Get-OpenCodeApiProperty -Object $_ -Name 'in' -Default '') -eq 'query'
    })
    if ($directoryParameter.Count -eq 0) { return '' }
    return '?directory=' + [Uri]::EscapeDataString($Directory)
}

function Start-OpenCodeServer {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][string]$Platform,
        [object]$SandboxInfo,
        [string]$ExpectedVersion = '',
        [int]$StartupTimeoutSeconds = 20,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $port = Get-OpenCodeLoopbackPort
    $serveArguments = @('serve', '--hostname', '127.0.0.1', '--port', [string]$port)
    $hardFilesystem = $null -ne $SandboxInfo -and $Platform -in @('linux', 'macos')
    $fileName = [string]$CommandInfo.FileName
    $arguments = @($CommandInfo.Prefix) + @($serveArguments)
    $workingDirectory = [string]$Inputs.Run.WorkingDirectoryPath
    if ($Platform -eq 'linux' -and $hardFilesystem) {
        $arguments = @(Get-LinuxSandboxArguments -Inputs $Inputs -CommandInfo $CommandInfo -Environment $Environment) + @($serveArguments)
        $fileName = [string]$SandboxInfo.FileName
    } elseif ($Platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosSandboxProfile -Inputs $Inputs -CommandInfo $CommandInfo
        $arguments = @('-f', $sandboxProfile, '--', $CommandInfo.FileName) + @($CommandInfo.Prefix) + @($serveArguments)
        $fileName = [string]$SandboxInfo.FileName
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $StdoutPath), (Split-Path -Parent $StderrPath) -Force | Out-Null
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.Environment.Clear()
    foreach ($key in $Environment.Keys) { $startInfo.Environment[$key] = [string]$Environment[$key] }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stdoutStream = [System.IO.File]::Open($StdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stderrStream = [System.IO.File]::Open($StderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stdoutTask = $null
    $stderrTask = $null
    $server = $null
    try {
        if (-not $process.Start()) { throw 'Could not start the owned OpenCode serve process.' }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(1, [Math]::Min(30, $StartupTimeoutSeconds)))
        $server = [pscustomobject]@{
            Process = $process
            Client = $client
            BaseUri = "http://127.0.0.1:$port"
            Port = $port
            StdoutPath = $StdoutPath
            StderrPath = $StderrPath
            StdoutStream = $stdoutStream
            StderrStream = $stderrStream
            StdoutTask = $stdoutTask
            StderrTask = $stderrTask
            Contract = $null
            HealthResponse = $null
            DocResponse = $null
            Version = $null
            Shutdown = $false
        }
        $healthResponse = $null
        $startupDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $StartupTimeoutSeconds))
        while ([DateTime]::UtcNow -lt $startupDeadline) {
            if ($process.HasExited) { throw 'Owned OpenCode serve process exited before loopback health became ready.' }
            $candidate = Invoke-OpenCodeHttpRequest -Server $server -Method GET -Path '/global/health' -TimeoutSeconds 1
            if ($candidate.Succeeded) {
                try {
                    $health = $candidate.Body | ConvertFrom-Json -Depth 20
                    if ([bool](Get-OpenCodeApiProperty -Object $health -Name 'healthy' -Default $false)) { $healthResponse = $candidate; break }
                } catch { }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($null -eq $healthResponse) { throw 'Owned OpenCode serve process did not expose healthy loopback health before the startup deadline.' }
        $health = $healthResponse.Body | ConvertFrom-Json -Depth 20
        $observedVersion = [string](Get-OpenCodeApiProperty -Object $health -Name 'version' -Default '')
        if ([string]::IsNullOrWhiteSpace($observedVersion)) { throw 'OpenCode loopback health did not expose a version.' }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $ExpectedVersion -ne 'unavailable' -and $observedVersion -ne $ExpectedVersion) {
            throw "OpenCode loopback health version '$observedVersion' does not match preflight version '$ExpectedVersion'."
        }
        $docResponse = Invoke-OpenCodeHttpRequest -Server $server -Method GET -Path '/doc' -TimeoutSeconds 5
        if (-not $docResponse.Succeeded -or [string]::IsNullOrWhiteSpace($docResponse.Body)) { throw "OpenCode loopback OpenAPI document request failed: $($docResponse.Error)" }
        $document = $docResponse.Body | ConvertFrom-Json -Depth 100
        $contract = Get-OpenCodeServerApiContract -Document $document
        if (-not [bool]$contract.Available) { throw [string]$contract.Reason }
        $server.HealthResponse = $healthResponse
        $server.DocResponse = $docResponse
        $server.Contract = $contract
        $server.Version = $observedVersion
        return $server
    } catch {
        if ($null -ne $server) { Stop-OpenCodeServer -Server $server }
        else {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                }
            } catch { }
            foreach ($task in @($stdoutTask, $stderrTask)) {
                if ($null -ne $task) { [void](Wait-RunnerTaskBounded -Task $task -TimeoutMilliseconds 5000) }
            }
            try { $stdoutStream.Flush() } catch { }
            try { $stderrStream.Flush() } catch { }
            try { $stdoutStream.Dispose() } catch { }
            try { $stderrStream.Dispose() } catch { }
            try { $process.Dispose() } catch { }
        }
        throw
    }
}

function Stop-OpenCodeServer {
    param([object]$Server)

    if ($null -eq $Server -or [bool]$Server.Shutdown) { return }
    $Server.Shutdown = $true
    try {
        $disposePath = [string](Get-OpenCodeApiProperty -Object $Server.Contract -Name 'InstanceDisposePath' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($disposePath)) { [void](Invoke-OpenCodeHttpRequest -Server $Server -Method POST -Path $disposePath -TimeoutSeconds 1) }
    } catch { }
    try { if (-not $Server.Process.HasExited) { [void]$Server.Process.WaitForExit(1000) } } catch { }
    try {
        if (-not $Server.Process.HasExited) {
            $Server.Process.Kill($true)
            if (-not $Server.Process.HasExited) { [void]$Server.Process.WaitForExit(5000) }
        }
    } catch { }
    $drainDeadline = [DateTime]::UtcNow.AddSeconds(5)
    foreach ($entry in @(
            [pscustomobject]@{ Task = $Server.StdoutTask; Stream = $Server.StdoutStream },
            [pscustomobject]@{ Task = $Server.StderrTask; Stream = $Server.StderrStream }
        )) {
        try {
            $remaining = [int][Math]::Max(1, [Math]::Min(5000, ($drainDeadline - [DateTime]::UtcNow).TotalMilliseconds))
            if (-not $entry.Task.IsCompleted) { [void]$entry.Task.Wait($remaining) }
        } catch { }
        try { $entry.Stream.Flush() } catch { }
        try { $entry.Stream.Dispose() } catch { }
    }
    try { $Server.Client.Dispose() } catch { }
    try { $Server.Process.Dispose() } catch { }
}

function Get-OpenCodeRequestedModel {
    param([Parameter(Mandatory = $true)][string]$Model)

    $provider = Get-OpenCodeModelProvider -Model $Model
    if ([string]::IsNullOrWhiteSpace($provider)) { throw "OpenCode scripted server transport requires a provider/model selector in 'provider/model' form; '$Model' is not parseable." }
    $modelId = $Model.Substring($provider.Length + 1)
    if ([string]::IsNullOrWhiteSpace($modelId)) { throw "OpenCode scripted server transport requires a non-empty model id in '$Model'." }
    return [ordered]@{ id = $modelId; providerID = $provider; modelID = $modelId }
}

function Invoke-OpenCodeServerPreflightProbe {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string]$Platform,
        [object]$SandboxInfo,
        [string]$ExpectedVersion = ''
    )

    $probeProjection = $null
    $probeServer = $null
    $probeStarted = [DateTime]::UtcNow
    try {
        $probeProjection = New-OpenCodeExecutionProjection -Inputs $Inputs
        $probeEnvironment = New-OpenCodeEnvironment -Inputs $probeProjection.Inputs
        $probeServer = Start-OpenCodeServer -CommandInfo $CommandInfo -Inputs $probeProjection.Inputs -Environment $probeEnvironment -Platform $Platform -SandboxInfo $SandboxInfo -ExpectedVersion $ExpectedVersion -StartupTimeoutSeconds 20 -StdoutPath (Join-Path $probeProjection.Root 'opencode-server-preflight-stdout.txt') -StderrPath (Join-Path $probeProjection.Root 'opencode-server-preflight-stderr.txt')
        $finished = [DateTime]::UtcNow
        return [pscustomobject]@{
            Available = $true
            Version = [string]$probeServer.Version
            Contract = $probeServer.Contract
            HealthResponse = $probeServer.HealthResponse
            DocResponse = $probeServer.DocResponse
            DurationSeconds = [Math]::Round(($finished - $probeStarted).TotalSeconds, 3)
            Reason = $null
        }
    } catch {
        $finished = [DateTime]::UtcNow
        return [pscustomobject]@{
            Available = $false
            Version = $null
            Contract = $null
            HealthResponse = $null
            DocResponse = $null
            DurationSeconds = [Math]::Round(($finished - $probeStarted).TotalSeconds, 3)
            Reason = $_.Exception.Message
        }
    } finally {
        if ($null -ne $probeServer) { Stop-OpenCodeServer -Server $probeServer }
        if ($null -ne $probeProjection) {
            try { Remove-OpenCodeProjectedCandidateSkill -Projection $probeProjection } catch { }
            try { Remove-OpenCodeExecutionProjection -Projection $probeProjection } catch { }
        }
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
    $serveHelp = $null
    $debugHelp = $null
    $debugConfig = $null
    $runtimeHomeObservation = $null
    $homeIsolationObservation = $null
    $policyObservation = $null
    $debugConfigObservation = $null
    $openCodeEnvironment = $null
    $continuationCapability = [pscustomobject]@{
        Available = $false
        Transport = 'opencode-server-synchronous-http'
        Version = $null
        Contract = $null
        Proof = $null
        Reason = 'OpenCode synchronous server transport was not probed because the installed serve surface was unavailable.'
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
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The OpenCode executable is unavailable, so synchronous server transport cannot be proven before execution.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible: the OpenCode executable is unavailable and no model-free server probe can run.')
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
            } else {
                $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
                foreach ($flag in @('--format', '--dir', '--model', '--auto')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed OpenCode CLI does not advertise required flag '$flag'.")
                    }
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
            }
            if ($null -ne $run.Interaction) {
                $serveHelp = Get-OpenCodeServeHelpResult -CommandInfo $commandInfo -Inputs $Inputs -Environment $openCodeEnvironment
                $serveHelpText = [string]::Join("`n", @($serveHelp.Stdout, $serveHelp.Stderr))
                $serveHelpUsable = -not $serveHelp.TimedOut -and $serveHelp.ExitCode -eq 0 -and $serveHelpText -match '(?i)--hostname' -and $serveHelpText -match '(?i)--port'
                if (-not $serveHelpUsable) {
                    $continuationCapability.Reason = "OpenCode serve --help did not prove loopback hostname/port controls (exit=$($serveHelp.ExitCode), timed_out=$($serveHelp.TimedOut))."
                    $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $continuationCapability.Reason))
                    $reasons.Add('scripted_multi_turn_same_session is incompatible: ' + $continuationCapability.Reason)
                } else {
                    $serverProbe = Invoke-OpenCodeServerPreflightProbe -Inputs $Inputs -CommandInfo $commandInfo -Platform $platform -SandboxInfo $sandboxInfo -ExpectedVersion ([string]$versionObservation.Version)
                    if ([bool]$serverProbe.Available) {
                        $continuationCapability.Available = $true
                        $continuationCapability.Version = [string]$serverProbe.Version
                        $continuationCapability.Contract = $serverProbe.Contract
                        $continuationCapability.Proof = $serverProbe.Contract.Proof
                        $continuationCapability.Reason = $null
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status passed -Detail ("Model-free OpenCode serve probe proved one loopback server, exact session creation, synchronous message POST at {0}, explicit model selection, text parts, assistant response identity, and bounded API discovery." -f $serverProbe.Contract.SessionMessagePath)))
                    } else {
                        $continuationCapability.Reason = 'OpenCode model-free loopback server/API probe failed: ' + [string]$serverProbe.Reason
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $continuationCapability.Reason))
                        $reasons.Add('scripted_multi_turn_same_session is incompatible: ' + $continuationCapability.Reason)
                    }
                }
            }
        } catch {
            $reasons.Add("Could not inspect OpenCode CLI capabilities: $($_.Exception.Message)")
            if ($null -ne $run.Interaction -and @($checks | Where-Object { $_.name -eq 'scripted_multi_turn_same_session' }).Count -eq 0) {
                $continuationCapability.Reason = 'OpenCode capability inspection failed before synchronous server transport could be proven.'
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
        'The adapter starts one new loopback opencode serve process, creates one fresh session, and sends every scripted turn synchronously to that exact session.'
    }
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail $freshSessionDetail))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter isolates global/user configuration roots, disables external skill discovery, and deliberately preserves repository-owned project configuration; OPENCODE_DISABLE_PROJECT_CONFIG is not used.'))
    $promptFidelityDetail = if ($null -eq $run.Interaction) {
        'The exact prompt bytes are sent on stdin as the first and only task input.'
    } else {
        'The parent runner reads all scripted inputs into memory, projects none of the interaction sidecar/source files, and sends only the current UTF-8 text part in each synchronous HTTP request.'
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
    foreach ($mechanism in @('runner-owned fresh OpenCode server/session per eval execution', 'opencode serve on 127.0.0.1', 'installed OpenAPI /global/health and /doc model-free probe', 'synchronous session message HTTP response as turn terminal boundary', 'native Task/General subagent available as a separate harness capability, not the transport', 'deterministic runner-owned concurrent fan-out', '--auto for single-turn CLI transport', 'isolated OPENCODE_CONFIG_DIR', 'isolated OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'coherent Windows HOME/USERPROFILE/HOMEDRIVE/HOMEPATH', 'OPENCODE_DISABLE_EXTERNAL_SKILLS=1', 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1', 'permission.skill arm policy', 'repository-owned project configuration preserved', 'parent-memory scripted turn inputs')) { $mechanisms.Add($mechanism) }
    if ($null -ne $run.Interaction -and $continuationCapability.Available) {
        $mechanisms.Add('exact session id retained for every synchronous HTTP turn')
        $mechanisms.Add('exact requested provider/model supplied on every turn')
        $mechanisms.Add('no CLI session continuation, SSE idle, or session.status dependency')
    } else {
        $mechanisms.Add('no scripted server session')
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
    if ($null -ne $serveHelp) {
        $preflightTiming.serve_help_probe_duration_seconds = [double]$serveHelp.DurationSeconds
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
            transport = [string]$continuationCapability.Transport
            server_version = [string]$continuationCapability.Version
            api_paths = if ($null -eq $continuationCapability.Contract) { $null } else { [ordered]@{ health = [string]$continuationCapability.Contract.HealthPath; doc = [string]$continuationCapability.Contract.DocPath; session_create = [string]$continuationCapability.Contract.SessionCreatePath; session_message = [string]$continuationCapability.Contract.SessionMessagePath; session_abort = [string]$continuationCapability.Contract.SessionAbortPath; instance_dispose = [string]$continuationCapability.Contract.InstanceDisposePath } }
            api_proof = $continuationCapability.Proof
            reason = $continuationCapability.Reason
            structured_output = 'synchronous HTTP JSON response'
            session_identity_source = 'session create response and assistant response info.sessionID'
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

function Get-OpenCodeAssistantResponseObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [Parameter(Mandatory = $true)][string]$ExpectedModel
    )

    try { $payload = $Body | ConvertFrom-Json -Depth 100 } catch { return [pscustomobject]@{ Valid = $false; Reason = "OpenCode synchronous message response was not valid JSON: $($_.Exception.Message)" } }
    $info = Get-OpenCodeApiProperty -Object $payload -Name 'info' -Default $null
    $parts = @(Get-OpenCodeApiProperty -Object $payload -Name 'parts' -Default @())
    if ($null -eq $info -or $parts.Count -eq 0) { return [pscustomobject]@{ Valid = $false; Reason = 'OpenCode synchronous message response did not contain info and parts.' } }
    $role = [string](Get-OpenCodeApiProperty -Object $info -Name 'role' -Default '')
    $sessionId = [string](Get-OpenCodeApiProperty -Object $info -Name 'sessionID' -Default '')
    $providerId = [string](Get-OpenCodeApiProperty -Object $info -Name 'providerID' -Default '')
    $modelId = [string](Get-OpenCodeApiProperty -Object $info -Name 'modelID' -Default '')
    if ($role -ne 'assistant') { return [pscustomobject]@{ Valid = $false; Reason = "OpenCode synchronous message response role '$role' was not assistant." } }
    if ([string]::IsNullOrWhiteSpace($sessionId) -or $sessionId -ne $ExpectedSessionId) { return [pscustomobject]@{ Valid = $false; Reason = "OpenCode synchronous message response returned session '$sessionId' instead of '$ExpectedSessionId'." } }
    if ([string]::IsNullOrWhiteSpace($providerId) -or [string]::IsNullOrWhiteSpace($modelId)) { return [pscustomobject]@{ Valid = $false; Reason = 'OpenCode synchronous assistant response did not expose providerID and modelID.' } }
    $observedModel = "$providerId/$modelId"
    if ($observedModel -ne $ExpectedModel) { return [pscustomobject]@{ Valid = $false; Reason = "OpenCode synchronous assistant response selected '$observedModel' instead of requested '$ExpectedModel'." } }
    $textParts = [System.Collections.Generic.List[string]]::new()
    $toolCalls = 0
    foreach ($part in $parts) {
        $partType = [string](Get-OpenCodeApiProperty -Object $part -Name 'type' -Default '')
        if ($partType -eq 'text') {
            $text = [string](Get-OpenCodeApiProperty -Object $part -Name 'text' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($text)) { $textParts.Add($text) }
        } elseif ($partType -match '(?i)tool') {
            $toolCalls++
        }
    }
    $assistantText = if ($textParts.Count -eq 0) { '' } else { [string]::Join('', @($textParts.ToArray())) }
    if ([string]::IsNullOrWhiteSpace($assistantText)) { return [pscustomobject]@{ Valid = $false; Reason = 'OpenCode synchronous assistant response did not contain a non-empty text part.' } }
    $tokens = Get-OpenCodeApiProperty -Object $info -Name 'tokens' -Default $null
    $usage = [ordered]@{}
    foreach ($mapping in @(
            [pscustomobject]@{ Source = 'input'; Target = 'input' },
            [pscustomobject]@{ Source = 'output'; Target = 'output' },
            [pscustomobject]@{ Source = 'reasoning'; Target = 'reasoning' }
        )) {
        $value = Get-OpenCodeApiProperty -Object $tokens -Name $mapping.Source -Default $null
        if ($null -ne $value) { $usage[$mapping.Target] = $value }
    }
    $cache = Get-OpenCodeApiProperty -Object $tokens -Name 'cache' -Default $null
    foreach ($mapping in @(
            [pscustomobject]@{ Source = 'read'; Target = 'cache_read' },
            [pscustomobject]@{ Source = 'write'; Target = 'cache_write' }
        )) {
        $value = Get-OpenCodeApiProperty -Object $cache -Name $mapping.Source -Default $null
        if ($null -ne $value) { $usage[$mapping.Target] = $value }
    }
    $cost = Get-OpenCodeApiProperty -Object $info -Name 'cost' -Default $null
    return [pscustomobject]@{
        Valid = $true
        Reason = $null
        Payload = $payload
        Info = $info
        Parts = $parts
        SessionId = $sessionId
        MessageId = [string](Get-OpenCodeApiProperty -Object $info -Name 'id' -Default '')
        ObservedModel = $observedModel
        AssistantText = $assistantText
        ToolCalls = $toolCalls
        Usage = $usage
        Cost = $cost
    }
}

function New-OpenCodeHttpEvidenceRecord {
    param(
        [Parameter(Mandatory = $true)][object]$Response,
        [Parameter(Mandatory = $true)][int]$Sequence,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    return [ordered]@{
        sequence = $Sequence
        kind = $Kind
        method = [string]$Response.Method
        path = [string]$Response.Path
        request_body_sha256 = if ([string]::IsNullOrEmpty([string]$Response.RequestBody)) { $null } else { Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$Response.RequestBody)) }
        response_status = $Response.StatusCode
        succeeded = [bool]$Response.Succeeded
        timed_out = [bool]$Response.TimedOut
        response_body_sha256 = if ([string]::IsNullOrEmpty([string]$Response.Body)) { $null } else { Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$Response.Body)) }
        http_started_utc = Format-UtcTimestamp -Value $Response.StartedUtc
        http_finished_utc = Format-UtcTimestamp -Value $Response.FinishedUtc
        duration_seconds = [double]$Response.DurationSeconds
        error = [string]$Response.Error
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

function Invoke-OpenCodeScriptedExecute {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Preflight,
        [Parameter(Mandatory = $true)][object]$ExecutionDescriptor,
        [string]$PreflightSource = 'fresh_preflight'
    )

    $started = [DateTime]::UtcNow
    $requestedTurns = @($Inputs.Run.Interaction.turns)
    $turnTexts = [System.Collections.Generic.List[string]]::new()
    $fallbackSessionId = [Guid]::NewGuid().ToString('D')
    $protocol = Get-JsonProperty -Object $Preflight -Name 'protocol_observations' -Default $null
    $serverObservation = Get-JsonProperty -Object $protocol -Name 'scripted_multi_turn_same_session' -Default $null
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $preflightAvailable = [bool](Get-JsonProperty -Object $serverObservation -Name 'available' -Default $false)
    if ($null -eq $commandInfo -or -not $preflightAvailable) {
        $reason = [string](Get-JsonProperty -Object $serverObservation -Name 'reason' -Default 'OpenCode synchronous server transport was not proven by preflight.')
        return New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc ([DateTime]::UtcNow).ToString('o') -DurationSeconds (([DateTime]::UtcNow - $started).TotalSeconds) -Failure (New-ExecutionFailure -Code 'incompatible' -Message $reason) -SessionId $fallbackSessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $Preflight; preflight_source = $PreflightSource; resume = $false; transport = 'opencode-server-synchronous-http' }) -AttemptCount 1
    }

    try {
        # Read every source/content value while the runner still owns the
        # logical run. None of these files is copied into the physical server
        # projection, so a future turn cannot be discovered by OpenCode.
        foreach ($turn in $requestedTurns) { $turnTexts.Add([string](Get-InteractionTurnText -Turn $turn -RunData $Inputs.Run)) }
    } catch {
        $finished = [DateTime]::UtcNow
        return New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'interaction_input_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $_.Exception.Message) -SessionId $fallbackSessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('interaction inputs were not readable before server startup') -Evidence ([ordered]@{ preflight = $Preflight; preflight_source = $PreflightSource; resume = $false; transport = 'opencode-server-synchronous-http' }) -AttemptCount 1
    }

    $requestedModelObject = $null
    try { $requestedModelObject = Get-OpenCodeRequestedModel -Model ([string]$Inputs.Profile.Model) } catch {
        $finished = [DateTime]::UtcNow
        return New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'model_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $_.Exception.Message) -SessionId $fallbackSessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('provider/model selector was not parseable for the installed OpenAPI model schema') -Evidence ([ordered]@{ preflight = $Preflight; preflight_source = $PreflightSource; resume = $false; transport = 'opencode-server-synchronous-http' }) -AttemptCount 1
    }

    $projection = $null
    $server = $null
    $executionInputs = $null
    $environment = [ordered]@{}
    $runtimeHomeObservation = $null
    $homeIsolationObservation = $null
    $policyObservation = $null
    $skillIsolationObservation = $null
    $serverCapability = [pscustomobject]@{ Available = $true }
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $turnRecords = [System.Collections.Generic.List[object]]::new()
    $nativeTurns = [System.Collections.Generic.List[object]]::new()
    $turnTimingRecords = [System.Collections.Generic.List[object]]::new()
    $httpRecords = [System.Collections.Generic.List[object]]::new()
    $responseArtifactPaths = [System.Collections.Generic.List[string]]::new()
    $observedModels = [System.Collections.Generic.List[string]]::new()
    $usageBuckets = [ordered]@{}
    $toolCalls = 0
    $costValue = $null
    $capturedSessionId = $null
    $finalText = $null
    $status = 'completed'
    $failureCode = $null
    $failureMessage = $null
    $nativeFailures = [System.Collections.Generic.List[string]]::new()
    $futureCanary = Get-OpenCodeFutureTurnCanary -Run $Inputs.Run
    $interactionSourcePhysicalPaths = @()
    $interactionJsonPhysicalPaths = @()
    $serverArguments = @()
    $interactionPhysicalPresent = $false
    $futureSourcePhysicalPresent = $false
    $canaryInProjection = $false
    $canaryInEnvironment = $false
    $canaryInArguments = $false

    try {
        $projection = New-OpenCodeExecutionProjection -Inputs $Inputs
        $executionInputs = $projection.Inputs
        $interactionSourcePhysicalPaths = @(Get-OpenCodeInteractionSourcePhysicalPaths -Inputs $Inputs -Projection $projection)
        $interactionJsonPhysicalPaths = @(Get-OpenCodeInteractionJsonPhysicalPaths -Inputs $Inputs -Projection $projection)
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
            $status = 'incompatible'
            $failureCode = 'opencode_isolation_incompatible'
            $failureMessage = [string]::Join('; ', @($isolationReasons.ToArray()))
            $nativeFailures.Add('isolation_incompatible')
        } else {
            $serverStdoutPath = Join-Path $Inputs.Run.RunRoot 'evidence/opencode-server-stdout.txt'
            $serverStderrPath = Join-Path $Inputs.Run.RunRoot 'evidence/opencode-server-stderr.txt'
            $server = Start-OpenCodeServer -CommandInfo $commandInfo -Inputs $executionInputs -Environment $environment -Platform $platform -SandboxInfo $sandboxInfo -ExpectedVersion ([string](Get-JsonProperty -Object $Preflight.harness -Name 'version' -Default '')) -StartupTimeoutSeconds 20 -StdoutPath $serverStdoutPath -StderrPath $serverStderrPath
            $serverArguments = @('serve', '--hostname', '127.0.0.1', '--port', [string]$server.Port)

            $healthArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-server-health.json' -Text ([string]$server.HealthResponse.Body)
            $docArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-openapi.json' -Text ([string]$server.DocResponse.Body)
            $responseArtifactPaths.Add('evidence/opencode-server-health.json')
            $responseArtifactPaths.Add('evidence/opencode-openapi.json')
            $httpRecords.Add((New-OpenCodeHttpEvidenceRecord -Response $server.HealthResponse -Sequence 1 -Kind 'health'))
            $httpRecords.Add((New-OpenCodeHttpEvidenceRecord -Response $server.DocResponse -Sequence 2 -Kind 'openapi'))

            $createPath = [string]$server.Contract.SessionCreatePath
            $createPath += Get-OpenCodeDirectoryQuery -Operation $server.Contract.SessionCreateOperation -Directory ([string]$executionInputs.Run.WorkingDirectoryPath)
            $createBody = [ordered]@{ model = [ordered]@{ id = [string]$requestedModelObject.id; providerID = [string]$requestedModelObject.providerID } }
            $createResponse = Invoke-OpenCodeHttpRequest -Server $server -Method POST -Path $createPath -Body $createBody -TimeoutSeconds ([int]$Inputs.Profile.TimeoutSeconds)
            $createArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-session-create.json' -Text ([string]$createResponse.Body)
            $responseArtifactPaths.Add('evidence/opencode-session-create.json')
            $httpRecords.Add((New-OpenCodeHttpEvidenceRecord -Response $createResponse -Sequence 3 -Kind 'session_create'))
            if ($createResponse.TimedOut) {
                $status = 'timed_out'; $failureCode = 'timed_out'; $failureMessage = 'OpenCode session creation exceeded timeout_seconds.'; $nativeFailures.Add('session_create_timeout')
            } elseif (-not $createResponse.Succeeded) {
                $status = 'failed'; $failureCode = 'opencode_failure'; $failureMessage = "OpenCode session creation failed: $($createResponse.Error)"; $nativeFailures.Add('session_create_failed')
            } else {
                try { $createdSession = $createResponse.Body | ConvertFrom-Json -Depth 100 } catch { $createdSession = $null }
                $capturedSessionId = [string](Get-OpenCodeApiProperty -Object $createdSession -Name 'id' -Default '')
                if ([string]::IsNullOrWhiteSpace($capturedSessionId) -or $capturedSessionId -notmatch '^ses') {
                    $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = 'OpenCode session creation did not return a valid exact session id.'; $nativeFailures.Add('session_id_unobservable')
                } else {
                    $createdModel = Get-OpenCodeApiProperty -Object $createdSession -Name 'model' -Default $null
                    if ($null -ne $createdModel) {
                        $createdProvider = [string](Get-OpenCodeApiProperty -Object $createdModel -Name 'providerID' -Default '')
                        $createdModelId = [string](Get-OpenCodeApiProperty -Object $createdModel -Name 'id' -Default '')
                        if ("$createdProvider/$createdModelId" -ne [string]$Inputs.Profile.Model) {
                            $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "OpenCode session creation selected '$createdProvider/$createdModelId' instead of requested '$($Inputs.Profile.Model)'."; $nativeFailures.Add('session_model_mismatch')
                        }
                    }
                }
            }

            for ($turnIndex = 0; $turnIndex -lt $turnTexts.Count -and $status -eq 'completed'; $turnIndex++) {
                $turnNumber = $turnIndex + 1
                $messagePath = ([string]$server.Contract.SessionMessagePath).Replace('{sessionID}', [Uri]::EscapeDataString($capturedSessionId))
                $messagePath += Get-OpenCodeDirectoryQuery -Operation $server.Contract.SessionMessageOperation -Directory ([string]$executionInputs.Run.WorkingDirectoryPath)
                $messageBody = [ordered]@{
                    model = [ordered]@{ providerID = [string]$requestedModelObject.providerID; modelID = [string]$requestedModelObject.modelID }
                    parts = @([ordered]@{ type = 'text'; text = [string]$turnTexts[$turnIndex] })
                }
                $messageResponse = Invoke-OpenCodeHttpRequest -Server $server -Method POST -Path $messagePath -Body $messageBody -TimeoutSeconds ([int]$Inputs.Profile.TimeoutSeconds)
                $turnResponsePath = "evidence/opencode-turn-$turnNumber-response.json"
                [void](Write-OpenCodeCapture -RunData $Inputs -RelativePath $turnResponsePath -Text ([string]$messageResponse.Body))
                $responseArtifactPaths.Add($turnResponsePath)
                $httpRecords.Add((New-OpenCodeHttpEvidenceRecord -Response $messageResponse -Sequence ($turnNumber + 3) -Kind ("turn_$turnNumber")))
                $turnObservation = if ($messageResponse.Succeeded) { Get-OpenCodeAssistantResponseObservation -Body ([string]$messageResponse.Body) -ExpectedSessionId $capturedSessionId -ExpectedModel ([string]$Inputs.Profile.Model) } else { [pscustomobject]@{ Valid = $false; Reason = "OpenCode turn $turnNumber failed: $($messageResponse.Error)" } }
                $nativeTurn = [ordered]@{
                    turn = $turnNumber
                    sequence = ($turnNumber * 2)
                    transport = 'synchronous_http'
                    method = 'POST'
                    path = $messagePath
                    user_content_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$turnTexts[$turnIndex]))
                    requested_model = [string]$Inputs.Profile.Model
                    requested_provider = [string]$requestedModelObject.providerID
                    requested_model_id = [string]$requestedModelObject.modelID
                    exact_session_id = $capturedSessionId
                    http_status = $messageResponse.StatusCode
                    http_started_utc = Format-UtcTimestamp -Value $messageResponse.StartedUtc
                    http_finished_utc = Format-UtcTimestamp -Value $messageResponse.FinishedUtc
                    duration_seconds = [double]$messageResponse.DurationSeconds
                    response_artifact = $turnResponsePath
                    request_contains_future_canary = [string]$messageResponse.RequestBody -like "*$futureCanary*"
                    response_message_id = if ($null -eq $turnObservation -or -not [bool]$turnObservation.Valid) { $null } else { [string]$turnObservation.MessageId }
                    observed_model = if ($null -eq $turnObservation -or -not [bool]$turnObservation.Valid) { $null } else { [string]$turnObservation.ObservedModel }
                    session_id = if ($null -eq $turnObservation) { $null } else { [string](Get-JsonProperty -Object $turnObservation -Name 'SessionId' -Default $null) }
                    session_id_match = $null -ne $turnObservation -and [bool]$turnObservation.Valid
                    terminal_http_response = [bool]$messageResponse.Succeeded -and $null -ne $turnObservation -and [bool]$turnObservation.Valid
                }
                if ($null -ne $turnObservation -and [bool]$turnObservation.Valid) {
                    $nativeTurn.assistant_text = [string]$turnObservation.AssistantText
                    $nativeTurn.tool_calls = [int]$turnObservation.ToolCalls
                    if ($turnObservation.Usage.Count -gt 0) { $nativeTurn.tokens = $turnObservation.Usage }
                    if ($null -ne $turnObservation.Cost) { $nativeTurn.cost = $turnObservation.Cost }
                    $nativeTurns.Add($nativeTurn)
                    $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 1; role = 'user'; content_sha256 = [string]$nativeTurn.user_content_sha256; session_id = $capturedSessionId; timestamp_utc = Format-UtcTimestamp -Value $messageResponse.StartedUtc })
                    $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 2; role = 'assistant'; text = [string]$turnObservation.AssistantText; session_id = $capturedSessionId; timestamp_utc = Format-UtcTimestamp -Value $messageResponse.FinishedUtc })
                    $turnTimingRecords.Add([ordered]@{ turn = $turnNumber; invocation = if ($turnIndex -eq 0) { 'fresh_session_http' } else { 'same_session_http' }; http_duration_seconds = [double]$messageResponse.DurationSeconds; http_started_utc = Format-UtcTimestamp -Value $messageResponse.StartedUtc; http_finished_utc = Format-UtcTimestamp -Value $messageResponse.FinishedUtc })
                    if ($observedModels -notcontains [string]$turnObservation.ObservedModel) { $observedModels.Add([string]$turnObservation.ObservedModel) }
                    $toolCalls += [int]$turnObservation.ToolCalls
                    foreach ($usageName in $turnObservation.Usage.Keys) { $usageBuckets[$usageName] = if ($usageBuckets.Contains($usageName)) { [int64]$usageBuckets[$usageName] + [int64]$turnObservation.Usage[$usageName] } else { [int64]$turnObservation.Usage[$usageName] } }
                    if ($null -ne $turnObservation.Cost) { $costValue = if ($null -eq $costValue) { [double]$turnObservation.Cost } else { [double]$costValue + [double]$turnObservation.Cost } }
                    $finalText = [string]$turnObservation.AssistantText
                } else {
                    $nativeTurns.Add($nativeTurn)
                    $nativeFailures.Add("turn_${turnNumber}_response")
                    if ($messageResponse.TimedOut) {
                        $status = 'timed_out'; $failureCode = 'timed_out'; $failureMessage = "OpenCode turn $turnNumber exceeded timeout_seconds."
                    } elseif (-not $messageResponse.Succeeded) {
                        $status = 'failed'; $failureCode = 'opencode_failure'; $failureMessage = [string]$turnObservation.Reason
                    } else {
                        $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = [string]$turnObservation.Reason
                        if ([string]$turnObservation.Reason -match '(?i)session') { $nativeFailures.Add('session_identity_mismatch') }
                        elseif ([string]$turnObservation.Reason -match '(?i)model') { $nativeFailures.Add('model_identity_mismatch') }
                        else { $nativeFailures.Add('terminal_response_invalid') }
                    }
                    if ($messageResponse.TimedOut -and -not [string]::IsNullOrWhiteSpace($capturedSessionId) -and -not [string]::IsNullOrWhiteSpace([string]$server.Contract.SessionAbortPath)) {
                        $abortPath = ([string]$server.Contract.SessionAbortPath).Replace('{sessionID}', [Uri]::EscapeDataString($capturedSessionId))
                        $abortResponse = Invoke-OpenCodeHttpRequest -Server $server -Method POST -Path $abortPath -TimeoutSeconds 1
                        $httpRecords.Add((New-OpenCodeHttpEvidenceRecord -Response $abortResponse -Sequence ($turnNumber + 100) -Kind ("turn_$turnNumber-abort")))
                    }
                }
            }
        }
    } catch {
        if ($status -eq 'completed') { $status = 'failed'; $failureCode = 'opencode_failure'; $failureMessage = $_.Exception.Message; $nativeFailures.Add('transport_failure') }
    } finally {
        if ($null -ne $server) { Stop-OpenCodeServer -Server $server }
        if ($null -ne $projection) {
            $projection.RuntimeCreatedRepositoryFiles = @(Get-OpenCodeProjectionFileSet -Root $projection.PhysicalWorkingDirectory | Where-Object { $projection.InitialRepositoryFiles -notcontains $_ })
            $interactionPhysicalPresent = @($interactionJsonPhysicalPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
            $futureSourcePhysicalPresent = @($interactionSourcePhysicalPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
            $canaryInProjection = @((Get-ChildItem -LiteralPath $projection.Root -Recurse -Force -File -ErrorAction SilentlyContinue) | Where-Object { $_.Name -like "*$futureCanary*" }).Count -gt 0
            try { Remove-OpenCodeProjectedCandidateSkill -Projection $projection } catch { }
            Sync-OpenCodeProjectedRepository -Projection $projection
            Remove-OpenCodeExecutionProjection -Projection $projection
        }
    }

    $finished = [DateTime]::UtcNow
    $serverStdoutArtifact = if (Test-Path -LiteralPath (Join-Path $Inputs.Run.RunRoot 'evidence/opencode-server-stdout.txt') -PathType Leaf) { New-ArtifactReference -Run $Inputs.Run -Path 'evidence/opencode-server-stdout.txt' -Scope run -MediaType 'text/plain; charset=utf-8' } else { $null }
    $serverStderrArtifact = if (Test-Path -LiteralPath (Join-Path $Inputs.Run.RunRoot 'evidence/opencode-server-stderr.txt') -PathType Leaf) { New-ArtifactReference -Run $Inputs.Run -Path 'evidence/opencode-server-stderr.txt' -Scope run -MediaType 'text/plain; charset=utf-8' } else { $null }
    if ($null -ne $serverStdoutArtifact) { $responseArtifactPaths.Add('evidence/opencode-server-stdout.txt') }
    if ($null -ne $serverStderrArtifact) { $responseArtifactPaths.Add('evidence/opencode-server-stderr.txt') }
    $httpTranscriptPath = 'evidence/opencode-http-transcript.json'
    $httpTranscriptText = (($httpRecords.ToArray() | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
    $httpTranscriptArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath $httpTranscriptPath -Text $httpTranscriptText
    $artifacts = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @('evidence/opencode-server-health.json', 'evidence/opencode-openapi.json', 'evidence/opencode-session-create.json') + @($responseArtifactPaths.ToArray()) | Select-Object -Unique) {
        $fullPath = Join-Path $Inputs.Run.RunRoot ($path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $artifacts.Add((New-ArtifactReference -Run $Inputs.Run -Path $path -Scope run -MediaType (Get-MediaType -Path $path))) }
    }
    $artifacts.Add($httpTranscriptArtifact)
    $canaryInEnvironment = @($environment.GetEnumerator() | Where-Object { [string]$_.Value -like "*$futureCanary*" }).Count -gt 0
    $canaryInArguments = @($serverArguments | Where-Object { [string]$_ -like "*$futureCanary*" }).Count -gt 0
    $terminalCapture = $status -eq 'completed' -and $nativeFailures.Count -eq 0 -and $turnRecords.Count -eq ($requestedTurns.Count * 2) -and $nativeTurns.Count -eq $requestedTurns.Count
    if ($status -eq 'completed' -and -not $terminalCapture) { $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = 'OpenCode synchronous interaction did not complete every ordered user/assistant turn.'; $nativeFailures.Add('turn_order') }
    if ([string]::IsNullOrWhiteSpace($capturedSessionId)) { $capturedSessionId = $fallbackSessionId }
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $credentialNames = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    $credentialEvidence = [ordered]@{ model_provider = $modelProvider; provider_environment_variables = $credentialNames; unrelated_environment_excluded = $true; child_tool_visibility = 'provider_credential_may_be_visible_to_native_child_tools; no supported child filter is exposed'; value_observed = $false }
    $interactionEvidence = [ordered]@{
        schema = (Get-RunnerSchemaNames).Interaction
        mode = 'scripted'
        same_session = [bool]$terminalCapture
        session_id = $capturedSessionId
        turns = @($turnRecords.ToArray())
        final_response_sequence = $turnRecords.Count
        transport = 'opencode-server-synchronous-http'
        server_version = if ($null -eq $serverObservation) { $null } else { [string](Get-JsonProperty -Object $serverObservation -Name 'server_version' -Default '') }
        api_paths = if ($null -eq $serverObservation) { $null } else { Get-JsonProperty -Object $serverObservation -Name 'api_paths' -Default $null }
        exact_session_id = $capturedSessionId
        exact_model_every_turn = [bool](@($nativeTurns | Where-Object { [string]$_.requested_model -ne [string]$Inputs.Profile.Model }).Count -eq 0)
        implicit_continuation = $false
        sse_dependency = $false
        session_status_dependency = $false
        native_turns = @($nativeTurns.ToArray())
        structured_transcript_complete = [bool]$terminalCapture
        working_directory = if ($null -eq $projection) { $null } else { [string]$projection.PhysicalWorkingDirectory }
        isolated_home = if ($null -eq $projection) { $null } else { [string]$projection.PhysicalHomeDirectory }
        logical_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
        logical_isolated_home = [string]$Inputs.Run.HomeDirectoryPath
        config_directory = [string](Get-JsonProperty -Object $environment -Name 'OPENCODE_CONFIG_DIR' -Default '')
        config_file = [string](Get-JsonProperty -Object $environment -Name 'OPENCODE_CONFIG' -Default '')
        model = [string]$Inputs.Profile.Model
    }
    $executionPaths = if ($null -eq $projection) { [ordered]@{} } else { New-OpenCodeExecutionPaths -LogicalInputs $Inputs -ExecutionInputs $executionInputs -Projection $projection -Environment $environment -HomeIsolation $homeIsolationObservation }
    $candidateExposure = if ($null -eq $projection) { [ordered]@{} } else { New-OpenCodeCandidateSkillExposure -LogicalInputs $Inputs -Projection $projection -SkillIsolation $skillIsolationObservation }
    $evidence = [ordered]@{
        execution_paths = $executionPaths
        event_counts = [ordered]@{ synchronous_http_responses = $httpRecords.Count; assistant_responses = $nativeTurns.Count }
        observed_model = if ($observedModels.Count -eq 0) { $null } else { [string]$observedModels[$observedModels.Count - 1] }
        observed_models = @($observedModels.ToArray())
        prompt_delivery = 'HTTP text parts from parent-memory turn values'
        prompt_first_input = $true
        resume = $false
        server = [ordered]@{ transport = 'opencode serve'; bind = '127.0.0.1'; port = if ($null -eq $server) { $null } else { $server.Port }; arguments = $serverArguments; health_artifact = 'evidence/opencode-server-health.json'; openapi_artifact = 'evidence/opencode-openapi.json'; stdout_artifact = 'evidence/opencode-server-stdout.txt'; stderr_artifact = 'evidence/opencode-server-stderr.txt'; version = if ($null -eq $serverObservation) { $null } else { [string](Get-JsonProperty -Object $serverObservation -Name 'server_version' -Default '') } }
        session_create_artifact = 'evidence/opencode-session-create.json'
        interaction = $interactionEvidence
        future_turn_secrecy = [ordered]@{ stable_canary = $futureCanary; parent_read_all_inputs_before_server = $true; interaction_json_projected = [bool]$interactionPhysicalPresent; future_source_files_projected = [bool]$futureSourcePhysicalPresent; canary_in_physical_projection = [bool]$canaryInProjection; canary_in_environment = [bool]$canaryInEnvironment; canary_in_server_arguments = [bool]$canaryInArguments; turn_1_request_contains_future_canary = @($nativeTurns | Where-Object { [int]$_.turn -eq 1 -and [bool]$_.request_contains_future_canary }).Count -gt 0; turn_2_sent_only_after_turn_1_http_completed = @($nativeTurns | Where-Object { [int]$_.turn -eq 2 }).Count -eq 1 -and @($nativeTurns | Where-Object { [int]$_.turn -eq 1 }).Count -eq 1 }
        candidate_skill_exposure = $candidateExposure
        effective_home = if ($null -eq $homeIsolationObservation) { $null } else { New-OpenCodeHomeIsolationEvidence -Observation $homeIsolationObservation }
        skill_policy = $policyObservation
        skill_isolation = if ($null -eq $skillIsolationObservation) { $null } else { New-OpenCodeSkillIsolationEvidence -Observation $skillIsolationObservation }
        ambient_skill_policy = [ordered]@{ mechanism = if ($null -eq $policyObservation) { $null } else { [string]$policyObservation.mechanism }; permission_skill = if ($null -eq $policyObservation) { $null } else { $policyObservation.configured_permission_skill }; external_skill_scans_disabled = if ($null -eq $policyObservation) { $false } else { [bool]$policyObservation.external_skill_scans_disabled }; claude_code_skill_scans_disabled = if ($null -eq $policyObservation) { $false } else { [bool]$policyObservation.claude_code_skill_scans_disabled }; ambient_skill_roots_hidden = $null -eq $skillIsolationObservation -or [int]$skillIsolationObservation.AmbientSkillCount -eq 0; candidate_skill_exposed = [bool]$Inputs.Run.CandidateSkillExposed }
        credential = $credentialEvidence
        timing = [ordered]@{ preflight = Get-JsonProperty -Object $Preflight -Name 'timing' -Default $null; preflight_source = $PreflightSource; projection_setup_duration_seconds = if ($null -eq $projection) { 0 } else { [double]$projection.SetupDurationSeconds }; turns = @($turnTimingRecords.ToArray()); total_runner_execution_seconds = [Math]::Round(($finished - $started).TotalSeconds, 3) }
        capture = [ordered]@{ source = 'harness_native_transport'; terminal = [bool]$terminalCapture; worker_authored = $false; artifact = $httpTranscriptPath; sha256 = [string]$httpTranscriptArtifact.sha256; complete_structured_transcript = [bool]$terminalCapture; turn_artifacts = @($nativeTurns.ToArray() | ForEach-Object { "evidence/opencode-turn-$(Get-JsonProperty -Object $_ -Name 'turn' -Default 0)-response.json" }); raw_http_artifacts = @($responseArtifactPaths.ToArray() | Select-Object -Unique) }
        delegation = [ordered]@{ dispatch_owner = 'runner'; mechanism = [string]$descriptor.delegation.mechanism; worker_session_id = $capturedSessionId; observed_model = if ($observedModels.Count -eq 0) { [string]$Inputs.Profile.Model } else { [string]$observedModels[$observedModels.Count - 1] }; observed_working_directory = if ($null -eq $projection) { $null } else { [string]$projection.PhysicalWorkingDirectory }; observed_home = if ($null -eq $projection) { $null } else { [string]$projection.PhysicalHomeDirectory }; effective_runtime_home = if ($null -eq $homeIsolationObservation) { $null } else { [string]$homeIsolationObservation.RuntimeHome }; effective_opencode_config_root = [string](Get-JsonProperty -Object $environment -Name 'OPENCODE_CONFIG_DIR' -Default ''); fresh_worker = $true; home_config_isolated = $true; prompt_fidelity = $true; prompt_sha256 = [string]$Inputs.Run.PromptHash; terminal_result_capture = [bool]$terminalCapture; paired_arm_visible = $false; grading_material_visible = $false; nested_model_execution = $false; model_execution_count = 1; same_session_continuation = [bool]$terminalCapture; continuation_transport = 'synchronous_http'; continuation_session_id = $capturedSessionId }
        native_worker_evidence_failures = @($nativeFailures | Select-Object -Unique)
    }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('runner-owned fresh opencode serve process per eval execution', 'loopback-only 127.0.0.1 binding', 'installed /global/health and /doc model-free probe', 'one exact session created through installed OpenAPI', 'synchronous POST session message response is terminal', 'exact provider/model supplied on every turn', 'server transport bypasses CLI continuation and event-idle completion', 'parent-memory scripted inputs; interaction sidecar/source files not projected', 'isolated OPENCODE_CONFIG_DIR', 'isolated OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'coherent Windows HOME/USERPROFILE/HOMEDRIVE/HOMEPATH', 'OPENCODE_DISABLE_EXTERNAL_SKILLS=1', 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1', 'permission.skill arm policy', 'repository-owned project configuration preserved', 'deterministic runner-owned concurrent fan-out')) { $mechanisms.Add($mechanism) }
    $sandboxForEvidence = if ($hardFilesystem) { [string]$sandboxInfo.Source } else { 'unavailable' }
    if ($sandboxForEvidence -eq 'unavailable') { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    $capabilities = Get-OpenCodeCapabilityMap -Inputs $Inputs -HardFilesystemConfinement ($sandboxForEvidence -ne 'unavailable') -ContinuationCapability $serverCapability
    $failureCodeValue = if ([string]::IsNullOrWhiteSpace($failureCode)) { 'native_interaction_incompatible' } else { $failureCode }
    $failureMessageValue = if ([string]::IsNullOrWhiteSpace($failureMessage)) { 'OpenCode scripted server interaction failed closed.' } else { $failureMessage }
    $failure = if ($nativeFailures.Count -eq 0) { $null } else { New-ExecutionFailure -Code $failureCodeValue -Message $failureMessageValue }
    $finalResponseValue = if ($status -eq 'completed') { $finalText } else { $null }
    $finalResponseReasonValue = if ($status -eq 'completed') { $null } else { 'native_interaction_incompatible' }
    $exitStatusValue = if ($status -eq 'completed') { [Nullable[int]]0 } else { $null }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = $httpTranscriptPath; complete = [bool]$terminalCapture })
        tokens = if ($usageBuckets.Count -eq 0) { New-UnavailableMetric -Reason 'opencode_did_not_expose_usage' } else { New-AvailableMetric -Value $usageBuckets }
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = if ($null -eq $costValue) { New-UnavailableMetric -Reason 'opencode_did_not_expose_cost' } else { New-AvailableMetric -Value $costValue }
    }
    $result = New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalResponseValue -FinalResponseReason $finalResponseReasonValue -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -ExitStatus $exitStatusValue -Failure $failure -SessionId $capturedSessionId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms.ToArray()) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'OpenCode synchronous server transport supplied the exact requested provider/model on every turn; backend resolution remains harness-reported telemetry.'; observations = [ordered]@{ model = $Inputs.Profile.Model; observed_models = @($observedModels.ToArray()); transport = 'opencode-server-synchronous-http' } }) -Telemetry $telemetry -Artifacts @($artifacts.ToArray()) -Warnings @() -Evidence $evidence -AttemptCount 1
    if ($status -eq 'completed') { [void](Assert-InteractionResultEvidence -ExecutionResult $result -RunData $Inputs.Run) }
    return $result
}

function Invoke-OpenCodeScriptedExecuteLegacy {
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
    $requestedTurns = @($executionInputs.Run.Interaction.turns)
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

    for ($turnIndex = 0; $turnIndex -lt $requestedTurns.Count; $turnIndex++) {
        $turnText = Get-InteractionTurnText -Turn $requestedTurns[$turnIndex] -RunData $executionInputs.Run
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
            turns_started_after_prior_terminal = $true
        }
        stdout_exit_codes = @($nativeTurns.ToArray() | ForEach-Object { Get-JsonProperty -Object $_ -Name 'exit_code' -Default $null })
        model_argument = [string]$Inputs.Profile.Model
        sandbox = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
        project_configuration = 'repository_owned_project_config_preserved'
        disable_project_config_environment = $false
        credential = $credentialEvidence
        interaction = $interactionEvidence
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
    $eventTimestamps = [System.Collections.Generic.List[string]]::new()
    $eventCounts = @{}
    $toolCalls = 0
    $commands = [System.Collections.Generic.List[object]]::new()
    $usageBuckets = [ordered]@{}
    $failureMessage = $null
    foreach ($event in @($parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $warnings.Add('OpenCode emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
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
            'step_start' { }
            'reasoning' { }
            default { $warnings.Add("Unknown OpenCode event '$eventType' was preserved as a warning.") }
        }
    }
    $finalText = if ($finalTextParts.Count -gt 0) { [string]::Join('', $finalTextParts) } else { $null }
    $eventTiming = Get-OpenCodeEventTiming -Timestamps @($eventTimestamps.ToArray())
    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'; $reason = 'opencode_timeout'; $failure = New-ExecutionFailure -Code 'timed_out' -Message 'OpenCode did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $failureMessage) {
        $status = 'failed'; $reason = 'opencode_failure'; $failure = New-ExecutionFailure -Code 'opencode_failure' -Message ([string]$failureMessage)
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
    $terminalCapture = (-not $process.TimedOut) -and (-not [string]::IsNullOrWhiteSpace([string]$process.Stdout))
    $executionPaths = New-OpenCodeExecutionPaths -LogicalInputs $Inputs -ExecutionInputs $executionInputs -Projection $projection -Environment $environment -HomeIsolation $homeIsolationObservation
    $candidateSkillExposure = New-OpenCodeCandidateSkillExposure -LogicalInputs $Inputs -Projection $projection -SkillIsolation $skillIsolationObservation
    $evidence = [ordered]@{
        execution_paths = $executionPaths
        event_counts = $eventCounts
        commands = @($commands)
        prompt_first_input = $true
        resume = $false
        model_argument = $model
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
            observed_model = [string]$model
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
