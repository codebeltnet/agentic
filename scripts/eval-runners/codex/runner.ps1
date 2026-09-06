<#!
.SYNOPSIS
    Codex Eval Runner adapter.

.DESCRIPTION
    This is the only place where Codex CLI flags, CODEX_HOME handling, JSONL
    event parsing, and Codex isolation limitations are defined.
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
    name = 'codex'
    version = '0.9.1'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = 'unavailable' }
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
        credential_child_filtering = 'supported'
        native_skill_activation_evidence = 'unsupported'
        # The app-server schema proves that a native child surface exists, not
        # what the child actually resolved or inherited. Terminal evidence is
        # required for every delegated-worker control.
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
        mechanism = 'Codex app-server native child session via thread/start and turn/start with per-worker cwd, model, and ephemeral context'
        worker_role = 'native-codex-child-session'
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

function Resolve-CodexInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    return [pscustomobject]@{
        Run = Resolve-RunContract -RunPath $Run
        Profile = Resolve-ExecutionProfile -ProfilePath $Profile
    }
}

function Get-CodexAuthSource {
    $authVariables = @(Get-ProviderAuthenticationVariables -Provider 'openai')
    foreach ($name in $authVariables) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return [pscustomobject]@{ Kind = 'environment'; Name = $name; Path = $null }
        }
    }

    $configuredHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    $codexHome = if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    } else {
        $configuredHome
    }
    $authPath = Join-Path $codexHome 'auth.json'
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
        return [pscustomobject]@{ Kind = 'subscription_file'; Name = 'auth.json'; Path = (Resolve-Path -LiteralPath $authPath).Path }
    }

    return [pscustomobject]@{ Kind = 'missing'; Name = $null; Path = $null }
}

function Invoke-CodexCli {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment,
        [byte[]]$InputBytes = @(),
        [int]$TimeoutSeconds = 60
    )

    $allArguments = @($CommandInfo.Prefix) + @($Arguments)
    return Invoke-RunnerProcess -FileName $CommandInfo.FileName -ArgumentList $allArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds -ProgressContext (Get-RunnerModelProgressContext -Runner 'codex' -Phase 'codex-cli')
}

function New-CodexAuthOnlyHome {
    param([Parameter(Mandatory = $true)][object]$Auth)

    if ($Auth.Kind -ne 'subscription_file' -or [string]::IsNullOrWhiteSpace([string]$Auth.Path)) {
        throw 'Codex auth-only home requires a resolved subscription auth.json source.'
    }
    $homePath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-codex-auth-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $homePath -Force | Out-Null
    $authDestination = Join-Path $homePath 'auth.json'
    try {
        # The temporary home is intentionally created outside the prepared
        # package. It contains exactly one copied file and is removed in the
        # app-server finally block, including start/timeout failures.
        Copy-Item -LiteralPath $Auth.Path -Destination $authDestination -Force -ErrorAction Stop
        $entries = @(Get-ChildItem -LiteralPath $homePath -Force -ErrorAction Stop)
        if ($entries.Count -ne 1 -or [string]$entries[0].Name -ne 'auth.json' -or -not (Test-Path -LiteralPath $authDestination -PathType Leaf)) {
            throw 'Codex temporary subscription home was not auth-only.'
        }
        return [pscustomobject]@{
            Path = $homePath
            AuthPath = $authDestination
            AuthOnly = $true
        }
    } catch {
        if (Test-Path -LiteralPath $homePath) {
            Remove-Item -LiteralPath $homePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Assert-CodexCandidateSkillName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$CandidateSkillName)

    if ([string]::IsNullOrWhiteSpace($CandidateSkillName)) {
        throw 'Codex native skill isolation requires run.json candidateSkillName.'
    }
    if ($CandidateSkillName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Codex native skill selector '$CandidateSkillName' is not supported by this runner."
    }
    return $CandidateSkillName
}

function Get-CodexSkillSessionConfigValues {
    param([Parameter(Mandatory = $true)][string]$CandidateSkillName)

    $candidate = Assert-CodexCandidateSkillName -CandidateSkillName $CandidateSkillName
    return @(
        'skills.include_instructions=false',
        ('skills.config=[{{name="{0}",enabled=false}}]' -f $candidate)
    )
}

function Add-CodexSessionConfigArguments {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory = $true)][string]$CandidateSkillName,
        [string]$SwitchName = '-c',
        [switch]$IncludeShellEnvironmentPolicy
    )

    if ($IncludeShellEnvironmentPolicy) {
        $Arguments.Add($SwitchName)
        $Arguments.Add('shell_environment_policy.inherit=none')
    }
    foreach ($value in @(Get-CodexSkillSessionConfigValues -CandidateSkillName $CandidateSkillName)) {
        $Arguments.Add($SwitchName)
        $Arguments.Add($value)
    }
}

function ConvertTo-CodexComparablePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = [string]$Path
    try { $value = [System.IO.Path]::GetFullPath($value) } catch { }
    $value = $value.Replace('/', '\')
    if ($IsWindows) { $value = $value.ToLowerInvariant() }
    return $value.TrimEnd('\')
}

function ConvertTo-CodexComparableText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = ([string]$Text).Replace('/', '\')
    if ($IsWindows) { return $value.ToLowerInvariant() }
    return $value
}

function Get-CodexAmbientSkillRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $normalized = ConvertTo-CodexComparablePath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    $extension = [System.IO.Path]::GetExtension($normalized)
    if (-not [string]::IsNullOrWhiteSpace($extension)) {
        try { return ConvertTo-CodexComparablePath -Path (Split-Path -Parent $normalized) } catch { return $normalized }
    }
    return $normalized
}

function Test-CodexTextReferencesRoot {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $normalizedText = ConvertTo-CodexComparableText -Text $Text
    $normalizedRoot = ConvertTo-CodexComparablePath -Path $Root
    if ([string]::IsNullOrWhiteSpace($normalizedRoot)) { return $false }
    return $normalizedText.Contains($normalizedRoot)
}

function Test-CodexPathInsideComparableRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $rootComparable = ConvertTo-CodexComparablePath -Path $Root
    $candidateComparable = ConvertTo-CodexComparablePath -Path $Candidate
    if ([string]::IsNullOrWhiteSpace($rootComparable) -or [string]::IsNullOrWhiteSpace($candidateComparable)) { return $false }
    return $candidateComparable -eq $rootComparable -or $candidateComparable.StartsWith($rootComparable + '\', [StringComparison]::Ordinal)
}

function Test-CodexPromptInputSuppressesNativeSkills {
    param(
        [Parameter(Mandatory = $true)][string]$PromptInputJson,
        [Parameter(Mandatory = $true)][string]$CandidateSkillName
    )

    $candidate = Assert-CodexCandidateSkillName -CandidateSkillName $CandidateSkillName
    $text = [string]$PromptInputJson
    if ($text -match [regex]::Escape($candidate)) { return $false }
    if ($text -match '(?i)available[- ]skills|<available_skills>|skills/list') { return $false }
    return $true
}

function New-CodexNativeSkillIsolationObservation {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateSkillName,
        [Parameter(Mandatory = $true)][string]$Transport,
        [AllowNull()][object]$ConfigReadRequest = $null,
        [AllowNull()][object]$ConfigReadResponse = $null,
        [AllowNull()][object]$SkillsListRequest = $null,
        [AllowNull()][object]$SkillsListResponse = $null,
        [AllowNull()][string]$PromptInputJson = $null,
        [AllowNull()][string]$PromptInputMethod = $null
    )

    $candidate = Assert-CodexCandidateSkillName -CandidateSkillName $CandidateSkillName
    $failures = [System.Collections.Generic.List[string]]::new()
    $skillsConfig = Get-JsonProperty -Object (Get-JsonProperty -Object (Get-JsonProperty -Object $ConfigReadResponse -Name 'result' -Default $null) -Name 'config' -Default $null) -Name 'skills' -Default $null
    $includeEffective = Get-JsonProperty -Object $skillsConfig -Name 'include_instructions' -Default $null
    $configEntries = @(Get-JsonProperty -Object $skillsConfig -Name 'config' -Default @())
    $disableEntries = @($configEntries | Where-Object {
        [string](Get-JsonProperty -Object $_ -Name 'name' -Default '') -eq $candidate -and
        $null -ne (Get-JsonProperty -Object $_ -Name 'enabled' -Default $null) -and
        -not [bool](Get-JsonProperty -Object $_ -Name 'enabled' -Default $true)
    })

    if ($includeEffective -ne $false) {
        [void]$failures.Add('native_skill_catalog_injection_unverified')
    }
    if ($disableEntries.Count -lt 1) {
        [void]$failures.Add('native_candidate_skill_disable_unverified')
    }

    $skillsListData = @(Get-JsonProperty -Object (Get-JsonProperty -Object $SkillsListResponse -Name 'result' -Default $null) -Name 'data' -Default @())
    if ($skillsListData.Count -eq 0) {
        [void]$failures.Add('native_skills_list_unavailable')
    }
    $skillEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $skillsListData) {
        foreach ($skill in @(Get-JsonProperty -Object $entry -Name 'skills' -Default @())) {
            [void]$skillEntries.Add($skill)
        }
    }
    $candidateMatches = @($skillEntries | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'name' -Default '') -eq $candidate })
    $candidateState = if ($candidateMatches.Count -eq 0) {
        'absent'
    } elseif (@($candidateMatches | Where-Object { [bool](Get-JsonProperty -Object $_ -Name 'enabled' -Default $true) }).Count -gt 0) {
        'enabled'
    } else {
        'disabled'
    }
    if ($candidateState -eq 'enabled') {
        [void]$failures.Add('native_candidate_skill_still_enabled')
    }

    $candidateMatchEvidence = @($candidateMatches | ForEach-Object {
        [ordered]@{
            name = Get-JsonProperty -Object $_ -Name 'name' -Default $null
            path = Get-JsonProperty -Object $_ -Name 'path' -Default $null
            enabled = Get-JsonProperty -Object $_ -Name 'enabled' -Default $null
            scope = Get-JsonProperty -Object $_ -Name 'scope' -Default $null
        }
    })
    if (@($candidateMatchEvidence | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.path) }).Count -gt 0) {
        [void]$failures.Add('native_skills_list_missing_candidate_path')
    }

    $ambientPaths = @($skillEntries |
        ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'path' -Default '') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)

    if (-not [string]::IsNullOrWhiteSpace($PromptInputJson) -and -not (Test-CodexPromptInputSuppressesNativeSkills -PromptInputJson $PromptInputJson -CandidateSkillName $candidate)) {
        [void]$failures.Add('native_skill_catalog_prompt_input_unverified')
    }

    $evidence = [ordered]@{
        candidate_skill_name = $candidate
        transport = $Transport
        include_instructions_requested = $false
        include_instructions_effective = $includeEffective
        include_instructions_verification_method = 'config/read'
        candidate_disable_selector = [ordered]@{ name = $candidate; enabled = $false; source = 'session -c skills.config' }
        candidate_disable_effective = $disableEntries.Count -gt 0
        skills_list_method = 'skills/list'
        force_reload = [bool](Get-JsonProperty -Object (Get-JsonProperty -Object $SkillsListRequest -Name 'params' -Default $null) -Name 'forceReload' -Default $false)
        candidate_matches_count = $candidateMatches.Count
        candidate_state = $candidateState
        candidate_matches = @($candidateMatchEvidence)
        all_candidate_matches_disabled = if ($candidateMatches.Count -eq 0) { $null } else { $candidateState -eq 'disabled' }
        ambient_skill_paths_observed = @($ambientPaths)
        runtime_access_observation = 'unavailable'
        ambient_skill_accesses_detected = @()
        config_read_request = $ConfigReadRequest
        config_read_response = $ConfigReadResponse
        skills_list_request = $SkillsListRequest
        skills_list_response = $SkillsListResponse
        prompt_input_verification_method = $PromptInputMethod
        prompt_input_catalog_suppressed = if ([string]::IsNullOrWhiteSpace($PromptInputJson)) { $null } else { Test-CodexPromptInputSuppressesNativeSkills -PromptInputJson $PromptInputJson -CandidateSkillName $candidate }
        failures = @()
    }
    if (-not [bool]$evidence.force_reload) {
        [void]$failures.Add('native_skills_list_force_reload_missing')
    }
    $evidence.failures = @($failures | Select-Object -Unique)

    return [pscustomobject]@{
        Evidence = $evidence
        Failures = @($evidence.failures)
        Verified = @($evidence.failures).Count -eq 0
    }
}

function Update-CodexNativeSkillRuntimeAccessEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$NativeSkillIsolation,
        [AllowEmptyCollection()][object[]]$Commands = @(),
        [AllowEmptyCollection()][object[]]$Files = @(),
        [AllowNull()][string]$AllowedStagedSkillRoot = $null
    )

    $evidence = Get-JsonProperty -Object $NativeSkillIsolation -Name 'Evidence' -Default $NativeSkillIsolation
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($failure in @(Get-JsonProperty -Object $evidence -Name 'failures' -Default @())) { [void]$failures.Add([string]$failure) }
    $accesses = [System.Collections.Generic.List[object]]::new()
    $ambientRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(Get-JsonProperty -Object $evidence -Name 'ambient_skill_paths_observed' -Default @())) {
        $root = Get-CodexAmbientSkillRoot -Path ([string]$path)
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($AllowedStagedSkillRoot) -and (Test-CodexPathInsideComparableRoot -Root $AllowedStagedSkillRoot -Candidate $root)) { continue }
        if ($ambientRoots -notcontains $root) { [void]$ambientRoots.Add($root) }
    }

    $pathEvidenceUnavailable = $false
    foreach ($command in @($Commands)) {
        $commandText = [string](Get-JsonProperty -Object $command -Name 'command' -Default '')
        if ([string]::IsNullOrWhiteSpace($commandText)) {
            $pathEvidenceUnavailable = $true
            continue
        }
        foreach ($root in @($ambientRoots)) {
            if (Test-CodexTextReferencesRoot -Text $commandText -Root $root) {
                [void]$accesses.Add([ordered]@{
                    evidence_type = 'command'
                    root = $root
                    command = $commandText
                    status = Get-JsonProperty -Object $command -Name 'status' -Default $null
                    exit_code = Get-JsonProperty -Object $command -Name 'exit_code' -Default $null
                })
            }
        }
    }

    foreach ($file in @($Files)) {
        $itemType = [string](Get-JsonProperty -Object $file -Name 'type' -Default '')
        if ($itemType -eq 'mcp_tool_call') {
            $pathEvidenceUnavailable = $true
            continue
        }
        $changes = @(Get-JsonProperty -Object (Get-JsonProperty -Object $file -Name 'item' -Default $file) -Name 'changes' -Default @())
        foreach ($change in $changes) {
            $changePath = [string](Get-JsonProperty -Object $change -Name 'path' -Default '')
            if ([string]::IsNullOrWhiteSpace($changePath)) {
                $pathEvidenceUnavailable = $true
                continue
            }
            foreach ($root in @($ambientRoots)) {
                if (Test-CodexTextReferencesRoot -Text $changePath -Root $root) {
                    [void]$accesses.Add([ordered]@{
                        evidence_type = 'file_change'
                        root = $root
                        path = $changePath
                        status = Get-JsonProperty -Object $file -Name 'status' -Default $null
                    })
                }
            }
        }
    }

    $runtimeObservation = if ($pathEvidenceUnavailable) { 'unavailable' } else { 'supported' }
    if ($pathEvidenceUnavailable) { [void]$failures.Add('runtime_ambient_skill_access_observation_unavailable') }
    if ($accesses.Count -gt 0) { [void]$failures.Add('ambient_skill_access_detected') }

    if ($evidence -is [System.Collections.IDictionary]) {
        $evidence['runtime_access_observation'] = $runtimeObservation
        $evidence['ambient_skill_accesses_detected'] = @($accesses.ToArray())
        $evidence['ambient_skill_roots_observed'] = @($ambientRoots.ToArray())
        $evidence['failures'] = @($failures | Select-Object -Unique)
    } else {
        Add-Member -InputObject $evidence -MemberType NoteProperty -Name runtime_access_observation -Value $runtimeObservation -Force
        Add-Member -InputObject $evidence -MemberType NoteProperty -Name ambient_skill_accesses_detected -Value @($accesses.ToArray()) -Force
        Add-Member -InputObject $evidence -MemberType NoteProperty -Name ambient_skill_roots_observed -Value @($ambientRoots.ToArray()) -Force
        Add-Member -InputObject $evidence -MemberType NoteProperty -Name failures -Value @($failures | Select-Object -Unique) -Force
    }

    return [pscustomobject]@{
        Evidence = $evidence
        Failures = @(Get-JsonProperty -Object $evidence -Name 'failures' -Default @())
        Verified = @(Get-JsonProperty -Object $evidence -Name 'failures' -Default @()).Count -eq 0
    }
}

function Set-CodexNativeSkillIsolationProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($Evidence -is [System.Collections.IDictionary]) {
        $Evidence[$Name] = $Value
    } else {
        Add-Member -InputObject $Evidence -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Add-CodexNativeSkillIsolationFailure {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Failure
    )

    $failures = @(@(Get-JsonProperty -Object $Evidence -Name 'failures' -Default @()) + @($Failure) | Select-Object -Unique)
    Set-CodexNativeSkillIsolationProperty -Evidence $Evidence -Name 'failures' -Value $failures
}

function Assert-CodexProjectionSource {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $reparsePoint = [System.IO.FileAttributes]::ReparsePoint
    $links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band $reparsePoint) -ne 0 })
    if ($links.Count -gt 0) {
        throw "Codex physical projection refuses reparse-point input '$($links[0].FullName)'."
    }
}

function Copy-CodexProjectionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    Assert-CodexProjectionSource -Path $Source
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-CodexProjectionFileSet {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
    } | Sort-Object)
}

function New-CodexExecutionProjection {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $projectionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-codex-projection-' + [Guid]::NewGuid().ToString('N'))
    $logicalRunRoot = [System.IO.Path]::GetFullPath([string]$Inputs.Run.RunRoot)
    $physicalRunRoot = [System.IO.Path]::GetFullPath($projectionRoot)
    if (Test-PathInside -BasePath $logicalRunRoot -CandidatePath $physicalRunRoot) {
        throw 'Codex physical projection unexpectedly resolved under the logical arm root.'
    }
    New-Item -ItemType Directory -Path $physicalRunRoot -Force | Out-Null
    $physicalPrompt = Join-Path $physicalRunRoot 'prompt.md'
    [System.IO.File]::WriteAllBytes($physicalPrompt, [byte[]]$Inputs.Run.PromptBytes)
    $physicalRepo = Join-Path $physicalRunRoot 'repo'
    $physicalHome = Join-Path $physicalRunRoot 'home'
    Copy-CodexProjectionDirectory -Source $Inputs.Run.WorkingDirectoryPath -Destination $physicalRepo
    Copy-CodexProjectionDirectory -Source $Inputs.Run.HomeDirectoryPath -Destination $physicalHome

    $physicalSkill = $null
    if ($Inputs.Run.CandidateSkillExposed) {
        $skillRelative = [System.IO.Path]::GetRelativePath($Inputs.Run.RunRoot, $Inputs.Run.SkillDirectoryPath)
        $physicalSkill = Join-Path $physicalRunRoot ($skillRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        Copy-CodexProjectionDirectory -Source $Inputs.Run.SkillDirectoryPath -Destination $physicalSkill
    }

    $physicalInteraction = $null
    if ($null -ne $Inputs.Run.InteractionPath) {
        $interactionRelative = [System.IO.Path]::GetRelativePath($Inputs.Run.RunRoot, $Inputs.Run.InteractionPath)
        $physicalInteraction = Join-Path $physicalRunRoot ($interactionRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $physicalInteraction) -Force | Out-Null
        Copy-Item -LiteralPath $Inputs.Run.InteractionPath -Destination $physicalInteraction -Force
        foreach ($turn in @($Inputs.Run.Interaction.turns)) {
            $source = [string](Get-JsonProperty -Object $turn -Name 'source' -Default '')
            if ([string]::IsNullOrWhiteSpace($source)) { continue }
            $logicalSource = Resolve-ContainedPath -BasePath $Inputs.Run.RunRoot -RelativePath $source -FieldName 'interaction turn source' -Kind File
            $sourceRelative = [System.IO.Path]::GetRelativePath($Inputs.Run.RunRoot, $logicalSource)
            $physicalSource = Join-Path $physicalRunRoot ($sourceRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $physicalSource) -Force | Out-Null
            Copy-Item -LiteralPath $logicalSource -Destination $physicalSource -Force
        }
    }

    $physicalRun = [pscustomobject]@{
        RunPath = $Inputs.Run.RunPath
        RunRoot = $physicalRunRoot
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
        CandidateSkillName = $Inputs.Run.CandidateSkillName
        FixtureHash = $Inputs.Run.FixtureHash
        SkillHash = $Inputs.Run.SkillHash
        InteractionPath = $physicalInteraction
        InteractionHash = $Inputs.Run.InteractionHash
        Interaction = $Inputs.Run.Interaction
    }
    return [pscustomobject]@{
        Root = $physicalRunRoot
        Run = $physicalRun
        LogicalRun = $Inputs.Run
        LogicalWorkingDirectory = $Inputs.Run.WorkingDirectoryPath
        LogicalHomeDirectory = $Inputs.Run.HomeDirectoryPath
        PhysicalWorkingDirectory = $physicalRepo
        PhysicalHomeDirectory = $physicalHome
        PhysicalSkillDirectory = $physicalSkill
        InitialRepositoryFiles = @(Get-CodexProjectionFileSet -Root $physicalRepo)
        Proven = $true
    }
}

function Sync-CodexProjectedRepository {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $logicalRepo = [string]$Projection.LogicalWorkingDirectory
    $physicalRepo = [string]$Projection.PhysicalWorkingDirectory
    $initialFiles = @($Projection.InitialRepositoryFiles)
    foreach ($relative in $initialFiles) {
        $physicalPath = Join-Path $physicalRepo ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $physicalPath -PathType Leaf)) {
            $logicalPath = Join-Path $logicalRepo ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $logicalPath -PathType Leaf) {
                Remove-Item -LiteralPath $logicalPath -Force
            }
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $physicalRepo -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $logicalRepo -Recurse -Force
    }
}

function Remove-CodexExecutionProjection {
    param([Parameter(Mandatory = $true)][object]$Projection)

    $root = [System.IO.Path]::GetFullPath([string]$Projection.Root)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not (Test-PathInside -BasePath $tempRoot -CandidatePath $root)) {
        throw "Refusing to remove Codex projection outside the temporary directory: '$root'."
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

function Invoke-CodexAppServer {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth,
        [bool]$SupportsProviderModelFallback = $false,
        [int]$TimeoutSeconds = 900,
        [hashtable]$ProgressContext = $null
    )

    if ($Auth.Kind -ne 'subscription_file') {
        throw 'Codex app-server subscription transport requires auth.json authentication.'
    }

    $start = [DateTime]::UtcNow
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $CommandInfo.FileName
    $psi.WorkingDirectory = $Inputs.Run.WorkingDirectoryPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $appServerArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($CommandInfo.Prefix) + @('app-server', '--strict-config', '--stdio')) { $appServerArguments.Add([string]$argument) }
    Add-CodexSessionConfigArguments -Arguments $appServerArguments -CandidateSkillName $Inputs.Run.CandidateSkillName -IncludeShellEnvironmentPolicy
    foreach ($argument in @($appServerArguments)) { [void]$psi.ArgumentList.Add([string]$argument) }

    # Shared progress context for the app-server protocol exchange. When the
    # orchestration environment enables progress (AGENTIC_RUNNER_PROGRESS), the
    # exchange emits periodic heartbeats carrying safe protocol activity metadata
    # (event count, byte count, elapsed, remaining timeout) so an operator can
    # distinguish an app-server that is producing protocol traffic from one that
    # is merely alive. Never exposes JSON-RPC content or model response text.
    $appProgressEnabled = $false
    $appProgressRunner = 'codex'
    $appProgressWorker = ''
    $appProgressPhase = 'codex-app-server'
    $appProgressChannel = 'Relayable'
    $appProgressLog = ''
    $appHeartbeatSeconds = Get-RunnerHeartbeatIntervalSeconds
    if ($null -ne $ProgressContext) {
        $appProgressEnabled = if ($ProgressContext.ContainsKey('enabled')) { [bool]$ProgressContext['enabled'] } else { $true }
        if ($ProgressContext.ContainsKey('runner')) { $appProgressRunner = [string]$ProgressContext['runner'] }
        if ($ProgressContext.ContainsKey('worker')) { $appProgressWorker = [string]$ProgressContext['worker'] }
        if ($ProgressContext.ContainsKey('phase') -and -not [string]::IsNullOrWhiteSpace([string]$ProgressContext['phase'])) { $appProgressPhase = [string]$ProgressContext['phase'] }
        if ($ProgressContext.ContainsKey('channel') -and -not [string]::IsNullOrWhiteSpace([string]$ProgressContext['channel'])) { $appProgressChannel = [string]$ProgressContext['channel'] }
        if ($ProgressContext.ContainsKey('logPath')) { $appProgressLog = [string]$ProgressContext['logPath'] }
        if ($ProgressContext.ContainsKey('heartbeatSeconds')) {
            $hb = 0.0
            if ([double]::TryParse([string]$ProgressContext['heartbeatSeconds'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$hb) -and $hb -gt 0) { $appHeartbeatSeconds = $hb }
        }
    }
    # Mutable protocol activity counters shared across the readMessage scriptblock
    # and the heartbeat emitter. Stored in a hashtable so scriptblock closures can
    # write back through the same reference.
    $appState = @{
        protocolEvents = 0
        protocolBytes = [long]0
        lastProtocolActivityUtc = $null
        lastHeartbeatUtc = $start
        processPid = $null
    }
    $emitAppServerProgress = {
        param([string]$State, [string]$Detail)
        if (-not $appProgressEnabled) { return }
        $now = [DateTime]::UtcNow
        $elapsedSeconds = [Math]::Max(0.0, ($now - $start).TotalSeconds)
        $remainingSeconds = [Math]::Max(0.0, ($deadline - $now).TotalSeconds)
        $fields = @{
            runner = $appProgressRunner
            state = $State
            origin = 'child'
            phase = $appProgressPhase
            elapsed = Format-RunnerElapsed -Seconds $elapsedSeconds
            elapsedSeconds = [Math]::Round($elapsedSeconds, 3)
            timeoutRemaining = Format-RunnerElapsed -Seconds $remainingSeconds
            timeoutRemainingSeconds = [Math]::Round($remainingSeconds, 3)
            stdoutEvents = $appState.protocolEvents
            stdoutBytes = $appState.protocolBytes
        }
        if (-not [string]::IsNullOrWhiteSpace($appProgressWorker)) { $fields.worker = $appProgressWorker }
        if ($null -ne $appState.processPid) { $fields.pid = $appState.processPid }
        if ($null -ne $appState.lastProtocolActivityUtc) {
            $lastActivitySeconds = [Math]::Max(0.0, ($now - [DateTime]$appState.lastProtocolActivityUtc).TotalSeconds)
            $fields.lastActivity = Format-RunnerElapsed -Seconds $lastActivitySeconds
            $fields.lastActivitySeconds = [Math]::Round($lastActivitySeconds, 3)
        }
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $fields.detail = $Detail }
        Write-RunnerProgress -Fields $fields -LogPath $appProgressLog -Channel $appProgressChannel
        $appState.lastHeartbeatUtc = $now
    }
    $tickAppServerHeartbeat = {
        if (-not $appProgressEnabled) { return }
        if (([DateTime]::UtcNow - $appState.lastHeartbeatUtc).TotalSeconds -ge $appHeartbeatSeconds) {
            & $emitAppServerProgress 'running' $null
        }
    }

    $authHome = $null
    $authOnlyHomeRemoved = $false
    $parentEnvironment = $null
    $process = [System.Diagnostics.Process]::new()
    $writer = $null
    $reader = $null
    $stderrTask = $null
    $events = [System.Collections.Generic.List[string]]::new()
    $normalized = [System.Collections.Generic.List[string]]::new()
    $threadId = $null
    $threadSessionId = $null
    $turnId = $null
    $finalText = $null
    $latestUsage = $null
    $timedOut = $false
    $transportFailure = $null
    $threadReadFailure = $null
    $turnCompleted = $false
    $terminalTurn = $null
    $stderr = ''
    $actualExitCode = $null
    $processStarted = $false
    $threadStartRequest = $null
    $threadStartResponse = $null
    $configReadRequest = $null
    $configReadResponse = $null
    $skillsListRequest = $null
    $skillsListResponse = $null
    $nativeSkillIsolation = $null
    $turnStartRequest = $null
    $turnStartResponse = $null
    $turnStartRequests = [System.Collections.Generic.List[object]]::new()
    $turnStartResponses = [System.Collections.Generic.List[object]]::new()
    $turnRecords = [System.Collections.Generic.List[object]]::new()
    $requestedInteractionTurns = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Inputs.Run.Interaction) {
        $requestedInteractionTurns.Add([ordered]@{ role = 'user'; source = 'prompt.md'; content = $null })
    } else {
        foreach ($interactionTurn in @($Inputs.Run.Interaction.turns)) { $requestedInteractionTurns.Add($interactionTurn) }
    }
    $allTurnsCompleted = $true
    $threadReadResponse = $null
    $instructionSources = @()
    $instructionSourcesObserved = $false
    $modelReroutes = [System.Collections.Generic.List[object]]::new()

    try {
        $authHome = New-CodexAuthOnlyHome -Auth $Auth
        $parentEnvironment = New-RunnerEnvironment -Run $Inputs.Run -Additional @{ CODEX_HOME = $authHome.Path }
        $psi.Environment.Clear()
        foreach ($name in @($parentEnvironment.Keys)) { $psi.Environment[$name] = [string]$parentEnvironment[$name] }
        $process.StartInfo = $psi

        if (-not $process.Start()) { throw 'Could not start Codex app-server.' }
        $processStarted = $true
        $appState.processPid = try { [int]$process.Id } catch { $null }
        $writer = $process.StandardInput
        $reader = $process.StandardOutput
        $stderrTask = $process.StandardError.ReadToEndAsync()
        & $emitAppServerProgress 'running' 'codex app-server launched'

        $writeMessage = {
            param([Parameter(Mandatory = $true)][object]$Value)
            $writer.WriteLine(($Value | ConvertTo-Json -Depth 50 -Compress))
            $writer.Flush()
        }
        $utf8NoBomForAppServer = [System.Text.UTF8Encoding]::new($false)
        $readMessage = {
            $readTask = $reader.ReadLineAsync()
            if ($appProgressEnabled) {
                $heartbeatSliceMilliseconds = [int][Math]::Max(50, [Math]::Min(5000, [Math]::Ceiling($appHeartbeatSeconds * 1000)))
                while (-not $readTask.IsCompleted) {
                    $remainingTotal = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
                    if ($remainingTotal -le 0) { throw [TimeoutException]::new('Codex app-server timed out.') }
                    $waitMilliseconds = [int][Math]::Max(1, [Math]::Min($heartbeatSliceMilliseconds, [Math]::Ceiling($remainingTotal)))
                    if (Wait-RunnerTaskBounded -Task $readTask -TimeoutMilliseconds $waitMilliseconds) { break }
                    & $tickAppServerHeartbeat
                }
            } else {
                $remaining = $deadline - [DateTime]::UtcNow
                if ($remaining.TotalMilliseconds -le 0) { throw [TimeoutException]::new('Codex app-server timed out.') }
                $waitMilliseconds = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($remaining.TotalMilliseconds))
                if (-not $readTask.Wait($waitMilliseconds)) { throw [TimeoutException]::new('Codex app-server timed out.') }
            }
            $line = $readTask.GetAwaiter().GetResult()
            if ($null -eq $line) { throw [EndOfStreamException]::new('Codex app-server closed stdout before the expected response.') }
            $events.Add($line)
            # Update shared protocol activity counters. The line text is the
            # complete JSON-RPC message; its byte length is safe activity metadata.
            $appState.protocolEvents++
            $appState.protocolBytes += [long]$utf8NoBomForAppServer.GetByteCount($line)
            $appState.lastProtocolActivityUtc = [DateTime]::UtcNow
            try { return ($line | ConvertFrom-Json -Depth 50) } catch { throw [FormatException]::new("Codex app-server emitted malformed JSON: $($_.Exception.Message)") }
        }
        $recordModelReroute = {
            param([Parameter(Mandatory = $true)][object]$Message)
            $reroute = Get-JsonProperty -Object $Message -Name 'params' -Default ([ordered]@{})
            $modelReroutes.Add($reroute)
            $normalized.Add(([ordered]@{ type = 'model.rerouted'; from_model = Get-JsonProperty -Object $reroute -Name 'fromModel' -Default $null; to_model = Get-JsonProperty -Object $reroute -Name 'toModel' -Default $null; reason = Get-JsonProperty -Object $reroute -Name 'reason' -Default $null } | ConvertTo-Json -Compress))
        }
        $waitForResponse = {
            param([Parameter(Mandatory = $true)][int]$ExpectedId, [Parameter(Mandatory = $true)][string]$Operation)
            while ($true) {
                $message = & $readMessage
                $messageId = Get-JsonProperty -Object $message -Name 'id' -Default $null
                $method = [string](Get-JsonProperty -Object $message -Name 'method' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($method) -and $null -ne $messageId) {
                    throw "Codex app-server requested unsupported interactive method '$method'."
                }
                if ($method -eq 'model/rerouted') {
                    & $recordModelReroute $message
                    continue
                }
                if ($null -eq $messageId -or [int]$messageId -ne $ExpectedId) { continue }
                $error = Get-JsonProperty -Object $message -Name 'error' -Default $null
                if ($null -ne $error) {
                    $errorMessage = [string](Get-JsonProperty -Object $error -Name 'message' -Default ($error | ConvertTo-Json -Depth 20 -Compress))
                    throw "Codex app-server $Operation failed: $errorMessage"
                }
                return $message
            }
        }

        $initializeRequest = 1
        & $writeMessage ([ordered]@{
            jsonrpc = '2.0'
            id = $initializeRequest
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{ name = 'codebelt-agentic-eval-runner'; title = 'Codebelt Eval Runner'; version = '0.9.1' }
                capabilities = [ordered]@{ experimentalApi = $true }
            }
        })
        $null = & $waitForResponse $initializeRequest 'initialize'
        & $writeMessage ([ordered]@{ jsonrpc = '2.0'; method = 'initialized' })

        $configReadRequestId = 2
        $configReadRequest = [ordered]@{
            jsonrpc = '2.0'
            id = $configReadRequestId
            method = 'config/read'
            params = [ordered]@{
                includeLayers = $false
                cwd = $Inputs.Run.WorkingDirectoryPath
            }
        }
        & $writeMessage $configReadRequest
        $configReadResponse = & $waitForResponse $configReadRequestId 'config/read'

        $skillsListRequestId = 3
        $skillsListRequest = [ordered]@{
            jsonrpc = '2.0'
            id = $skillsListRequestId
            method = 'skills/list'
            params = [ordered]@{
                cwds = @($Inputs.Run.WorkingDirectoryPath)
                forceReload = $true
            }
        }
        & $writeMessage $skillsListRequest
        $skillsListResponse = & $waitForResponse $skillsListRequestId 'skills/list'
        $nativeSkillIsolation = New-CodexNativeSkillIsolationObservation -CandidateSkillName $Inputs.Run.CandidateSkillName -Transport 'app-server' -ConfigReadRequest $configReadRequest -ConfigReadResponse $configReadResponse -SkillsListRequest $skillsListRequest -SkillsListResponse $skillsListResponse
        if (-not [bool]$nativeSkillIsolation.Verified) {
            throw "Codex native skill isolation failed before model turn: $([string]::Join(', ', @($nativeSkillIsolation.Failures)))."
        }

        $threadRequest = 4
        $threadStartParams = [ordered]@{
            model = $Inputs.Profile.Model
            cwd = $Inputs.Run.WorkingDirectoryPath
            approvalPolicy = 'never'
            # thread/start can persist project trust when it begins with
            # elevated permission. Keep the ephemeral thread read-only and
            # apply full operational permission to the turn only.
            sandbox = 'read-only'
            ephemeral = $true
        }
        if ($SupportsProviderModelFallback) { $threadStartParams.allowProviderModelFallback = $false }
        $threadStartRequest = [ordered]@{ jsonrpc = '2.0'; id = $threadRequest; method = 'thread/start'; params = $threadStartParams }
        & $writeMessage $threadStartRequest
        $threadStartResponse = & $waitForResponse $threadRequest 'thread/start'
        $threadStartResult = Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null
        $threadMetadata = Get-JsonProperty -Object $threadStartResult -Name 'thread' -Default $null
        $threadId = [string](Get-JsonProperty -Object $threadMetadata -Name 'id' -Default '')
        $threadSessionId = [string](Get-JsonProperty -Object $threadMetadata -Name 'sessionId' -Default '')
        if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'Codex app-server thread/start returned no thread id.' }
        $instructionSourcesObserved = Test-JsonProperty -Object $threadStartResult -Name 'instructionSources'
        if ($instructionSourcesObserved) { $instructionSources = @(Get-JsonProperty -Object $threadStartResult -Name 'instructionSources' -Default @()) }

        for ($scriptedTurnIndex = 0; $scriptedTurnIndex -lt $requestedInteractionTurns.Count; $scriptedTurnIndex++) {
        $turnCompleted = $false
        $finalText = $null
        $latestUsage = $null
        $terminalTurn = $null
        $turnStartedUtc = [DateTime]::UtcNow
        $turnRequest = 5 + $scriptedTurnIndex
        $promptText = Get-InteractionTurnText -Turn $requestedInteractionTurns[$scriptedTurnIndex] -RunData $Inputs.Run
        $turnStartParams = [ordered]@{
            threadId = $threadId
            input = @([ordered]@{ type = 'text'; text = $promptText })
            cwd = $Inputs.Run.WorkingDirectoryPath
            model = $Inputs.Profile.Model
            effort = $Inputs.Profile.ReasoningEffort
            approvalPolicy = 'never'
            sandboxPolicy = [ordered]@{
                type = 'dangerFullAccess'
            }
        }
        $turnStartRequest = [ordered]@{ jsonrpc = '2.0'; id = $turnRequest; method = 'turn/start'; params = $turnStartParams }
        $turnStartRequests.Add($turnStartRequest)
        & $writeMessage $turnStartRequest
        $turnStartResponse = & $waitForResponse $turnRequest 'turn/start'
        $turnStartResponses.Add($turnStartResponse)
        $turnStartResult = Get-JsonProperty -Object $turnStartResponse -Name 'result' -Default $null
        $turnId = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $turnStartResult -Name 'turn' -Default $null) -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($turnId)) { throw 'Codex app-server turn/start returned no turn id.' }

        while (-not $turnCompleted) {
            $message = & $readMessage
            $messageId = Get-JsonProperty -Object $message -Name 'id' -Default $null
            $method = [string](Get-JsonProperty -Object $message -Name 'method' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($method) -and $null -ne $messageId) {
                throw "Codex app-server requested unsupported interactive method '$method'."
            }
            switch ($method) {
                'thread/started' {
                    $normalized.Add(([ordered]@{ type = 'thread.started'; thread_id = Get-JsonProperty -Object (Get-JsonProperty -Object $message.params -Name 'thread' -Default $null) -Name 'id' -Default $null } | ConvertTo-Json -Compress))
                }
                'model/rerouted' {
                    & $recordModelReroute $message
                }
                'item/completed' {
                    $item = $message.params.item
                    $itemType = [string]$item.type
                    $normalizedType = switch ($itemType) {
                        'agentMessage' { 'agent_message' }
                        'commandExecution' { 'command_execution' }
                        'fileChange' { 'file_change' }
                        'mcpToolCall' { 'mcp_tool_call' }
                        default { $itemType }
                    }
                    $normalizedItem = [ordered]@{ type = $normalizedType; id = Get-JsonProperty -Object $item -Name 'id' -Default $null }
                    $itemStatus = Get-JsonProperty -Object $item -Name 'status' -Default $null
                    if ($null -ne $itemStatus) { $normalizedItem.status = $itemStatus }
                    $itemError = Get-JsonProperty -Object $item -Name 'error' -Default $null
                    if ($null -ne $itemError) { $normalizedItem.error = $itemError }
                    if ($itemType -eq 'agentMessage') {
                        $normalizedItem.text = [string]$item.text
                        $finalText = [string]$item.text
                    } elseif ($itemType -eq 'commandExecution') {
                        $normalizedItem.command = Get-JsonProperty -Object $item -Name 'command' -Default $null
                        $normalizedItem.exit_code = Get-JsonProperty -Object $item -Name 'exitCode' -Default $null
                        $normalizedItem.aggregated_output = Get-JsonProperty -Object $item -Name 'aggregatedOutput' -Default $null
                    } elseif ($itemType -eq 'fileChange') {
                        $normalizedItem.changes = Get-JsonProperty -Object $item -Name 'changes' -Default @()
                    } else {
                        $normalizedItem.raw = $item
                    }
                    $normalized.Add(([ordered]@{ type = 'item.completed'; item = $normalizedItem } | ConvertTo-Json -Depth 40 -Compress))
                }
                'thread/tokenUsage/updated' {
                    $latestUsage = Get-JsonProperty -Object (Get-JsonProperty -Object $message.params -Name 'tokenUsage' -Default $null) -Name 'last' -Default $null
                }
                'turn/completed' {
                    $completionParams = Get-JsonProperty -Object $message -Name 'params' -Default ([ordered]@{})
                    $terminalTurn = Get-JsonProperty -Object $completionParams -Name 'turn' -Default $null
                    $completionThreadId = [string](Get-JsonProperty -Object $completionParams -Name 'threadId' -Default '')
                    $completedTurnId = [string](Get-JsonProperty -Object $terminalTurn -Name 'id' -Default '')
                    if ($completionThreadId -ne $threadId -or $completedTurnId -ne $turnId) {
                        throw 'Codex app-server turn/completed identified an unexpected thread or turn.'
                    }
                    if ([string]::IsNullOrWhiteSpace($finalText)) {
                        $turnItems = @($terminalTurn.items)
                        for ($itemIndex = $turnItems.Count - 1; $itemIndex -ge 0; $itemIndex--) {
                            if ([string]$turnItems[$itemIndex].type -eq 'agentMessage' -and -not [string]::IsNullOrWhiteSpace([string]$turnItems[$itemIndex].text)) {
                                $finalText = [string]$turnItems[$itemIndex].text
                                break
                            }
                        }
                    }
                    if ([string]$terminalTurn.status -eq 'failed') {
                        $errorMessage = [string](Get-JsonProperty -Object $terminalTurn.error -Name 'message' -Default 'Codex turn failed.')
                        $normalized.Add(([ordered]@{ type = 'turn.failed'; error = $errorMessage } | ConvertTo-Json -Compress))
                    } elseif ([string]$terminalTurn.status -eq 'interrupted') {
                        $normalized.Add(([ordered]@{ type = 'turn.failed'; error = 'Codex turn was interrupted.' } | ConvertTo-Json -Compress))
                    } else {
                        $usage = $null
                        if ($null -ne $latestUsage) {
                            $usage = [ordered]@{
                                input_tokens = Get-JsonProperty -Object $latestUsage -Name 'inputTokens' -Default $null
                                cached_input_tokens = Get-JsonProperty -Object $latestUsage -Name 'cachedInputTokens' -Default $null
                                output_tokens = Get-JsonProperty -Object $latestUsage -Name 'outputTokens' -Default $null
                                reasoning_output_tokens = Get-JsonProperty -Object $latestUsage -Name 'reasoningOutputTokens' -Default $null
                            }
                        }
                        $normalized.Add(([ordered]@{ type = 'turn.completed'; usage = $usage } | ConvertTo-Json -Depth 20 -Compress))
                    }
                    $turnCompleted = $true
                }
                'error' {
                    $errorMessage = [string](Get-JsonProperty -Object $message.params -Name 'message' -Default 'Codex app-server emitted an error.')
                    throw $errorMessage
                }
            }
        }

        $turnRecords.Add([ordered]@{ sequence = ($scriptedTurnIndex * 2) + 1; role = 'user'; content_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($promptText)); session_id = $threadId; timestamp_utc = Format-UtcTimestamp -Value $turnStartedUtc })
        $turnRecords.Add([ordered]@{ sequence = ($scriptedTurnIndex * 2) + 2; role = 'assistant'; text = if ($null -eq $finalText) { '' } else { [string]$finalText }; session_id = $threadId; timestamp_utc = Format-UtcTimestamp -Value ([DateTime]::UtcNow) })
        if (-not $turnCompleted -or [string](Get-JsonProperty -Object $terminalTurn -Name 'status' -Default '') -ne 'completed') {
            $allTurnsCompleted = $false
            break
        }
        }

        # The installed schema exposes thread/read after completion. Use it as
        # a second observation of ephemeral identity, cwd, and session metadata
        # when the server provides the response; never reconstruct it locally.
        $threadReadRequest = 5 + $requestedInteractionTurns.Count
        & $writeMessage ([ordered]@{ jsonrpc = '2.0'; id = $threadReadRequest; method = 'thread/read'; params = [ordered]@{ threadId = $threadId; includeTurns = $true } })
        try {
            $threadReadResponse = & $waitForResponse $threadReadRequest 'thread/read'
        } catch {
            $threadReadFailure = $_.Exception.Message
            $normalized.Add(([ordered]@{ type = 'thread.read.unavailable'; message = $threadReadFailure } | ConvertTo-Json -Compress))
        }
    } catch [TimeoutException] {
        $timedOut = $true
    } catch {
        $transportFailure = $_.Exception.Message
        $normalized.Add(([ordered]@{ type = 'error'; message = $transportFailure } | ConvertTo-Json -Compress))
    } finally {
        if ($null -ne $writer) { try { $writer.Close() } catch { } }
        if ($processStarted) {
            try {
                if (-not $process.HasExited -and -not $process.WaitForExit(2000)) {
                    $process.Kill($true)
                    # Never use an unbounded wait in cleanup. A broken child
                    # or inherited pipe must not hold the runner forever.
                    if (-not $process.HasExited) { [void]$process.WaitForExit(5000) }
                }
                if ($process.HasExited) { $actualExitCode = $process.ExitCode }
            } catch { }
        }
        if ($null -ne $stderrTask) {
            try {
                # A descendant that inherits stderr can keep this task open
                # after the app-server has been terminated. Drain only within
                # the shared finite cleanup grace; never turn cleanup into an
                # unbounded GetResult() wait.
                if (Wait-RunnerTaskBounded -Task $stderrTask -TimeoutMilliseconds 5000) {
                    $stderr = [string]$stderrTask.GetAwaiter().GetResult()
                } else {
                    $stderr = 'Codex app-server stderr drain exceeded bounded cleanup grace.'
                }
            } catch { $stderr = $_.Exception.Message }
        }
        $process.Dispose()
        if ($null -ne $authHome -and (Test-Path -LiteralPath $authHome.Path)) {
            Remove-Item -LiteralPath $authHome.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        $authOnlyHomeRemoved = $null -eq $authHome -or -not (Test-Path -LiteralPath $authHome.Path)
    }

    $finish = [DateTime]::UtcNow
    $exitCode = if ($timedOut) { $null } elseif ($turnCompleted -and $null -eq $transportFailure) { 0 } elseif ($null -ne $actualExitCode -and $actualExitCode -ne 0) { $actualExitCode } else { 1 }
    return [pscustomobject]@{
        Stdout = [string]::Join("`n", $normalized)
        RawStdout = [string]::Join("`n", $events)
        Stderr = $stderr
        ExitCode = $exitCode
        TimedOut = $timedOut
        StartedUtc = $start
        FinishedUtc = $finish
        DurationSeconds = [Math]::Round(($finish - $start).TotalSeconds, 3)
        FinalText = $finalText
        ThreadId = $threadId
        ThreadSessionId = $threadSessionId
        TurnId = $turnId
        TurnCompleted = $allTurnsCompleted
        LastTurnCompleted = $turnCompleted
        TerminalTurn = $terminalTurn
        ThreadStartRequest = $threadStartRequest
        ThreadStartResponse = $threadStartResponse
        TurnStartRequest = $turnStartRequest
        TurnStartResponse = $turnStartResponse
        TurnStartRequests = @($turnStartRequests.ToArray())
        TurnStartResponses = @($turnStartResponses.ToArray())
        TurnRecords = @($turnRecords.ToArray())
        RequestedTurnCount = $requestedInteractionTurns.Count
        AllTurnsCompleted = $allTurnsCompleted
        ThreadReadResponse = $threadReadResponse
        ThreadReadFailure = $threadReadFailure
        ConfigReadRequest = $configReadRequest
        ConfigReadResponse = $configReadResponse
        SkillsListRequest = $skillsListRequest
        SkillsListResponse = $skillsListResponse
        NativeSkillIsolation = $nativeSkillIsolation
        InstructionSources = @($instructionSources)
        InstructionSourcesObserved = $instructionSourcesObserved
        ModelReroutes = @($modelReroutes.ToArray())
        PromptInputSha256 = if ($turnStartRequests.Count -gt 0) { Get-Sha256HexFromBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes([string]$turnStartRequests[0].params.input[0].text)) } else { $null }
        ObservedModel = if ($null -ne $threadStartResponse) { [string](Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null) -Name 'model' -Default '') } else { '' }
        ObservedWorkingDirectory = if ($null -ne $threadStartResponse) { [string](Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null) -Name 'cwd' -Default '') } else { '' }
        ObservedEphemeral = if ($null -ne $threadStartResponse) { [bool](Get-JsonProperty -Object (Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResponse -Name 'result' -Default $null) -Name 'thread' -Default $null) -Name 'ephemeral' -Default $false) } else { $false }
        AuthOnlyHome = $null -ne $authHome -and [bool]$authHome.AuthOnly
        AuthOnlyHomeRemoved = $authOnlyHomeRemoved
        WorkerHome = if ($null -ne $parentEnvironment) { [string]$parentEnvironment.HOME } else { '' }
        TransportFailure = $transportFailure
    }
}

function Get-CodexHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [string[]]$Arguments = @('--ask-for-approval', 'never', 'exec', '--help')
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    return Invoke-CodexCli -CommandInfo $CommandInfo -Arguments $Arguments -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
}

function Get-CodexSchemaProperty {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($null -eq $Schema) { return $null }
    return Get-JsonProperty -Object (Get-JsonProperty -Object $Schema -Name 'properties' -Default $null) -Name $PropertyName -Default $null
}

function Get-CodexSchemaReference {
    param([AllowNull()][object]$Schema)

    $direct = [string](Get-JsonProperty -Object $Schema -Name '$ref' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return $direct }
    foreach ($alternative in @(Get-JsonProperty -Object $Schema -Name 'anyOf' -Default @())) {
        $reference = [string](Get-JsonProperty -Object $alternative -Name '$ref' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($reference)) { return $reference }
    }
    foreach ($alternative in @(Get-JsonProperty -Object $Schema -Name 'allOf' -Default @())) {
        $reference = [string](Get-JsonProperty -Object $alternative -Name '$ref' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($reference)) { return $reference }
    }
    return ''
}

function Test-CodexSchemaRequiredProperty {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory = $true)][string]$SchemaName
    )

    if ($null -eq $Schema) {
        [void]$Errors.Add("$SchemaName schema is missing.")
        return $null
    }
    $property = Get-CodexSchemaProperty -Schema $Schema -PropertyName $PropertyName
    if ($null -eq $property) {
        [void]$Errors.Add("$SchemaName.properties.$PropertyName is missing.")
        return $null
    }
    $required = @(Get-JsonProperty -Object $Schema -Name 'required' -Default @()) | ForEach-Object { [string]$_ }
    if ($required -notcontains $PropertyName) {
        [void]$Errors.Add("$SchemaName.required does not contain '$PropertyName'.")
    }
    return $property
}

function Get-CodexSchemaDefinition {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$DefinitionName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory = $true)][string]$SchemaName,
        [AllowNull()][object]$Definitions = $null
    )

    if ($null -ne $Definitions) {
        $definitions = $Definitions
    } elseif ($null -ne $Schema) {
        $definitions = Get-JsonProperty -Object $Schema -Name 'definitions' -Default $null
    } else {
        $definitions = $null
    }
    $definition = Get-JsonProperty -Object $definitions -Name $DefinitionName -Default $null
    if ($null -eq $definition) { [void]$Errors.Add("$SchemaName.definitions.$DefinitionName is missing.") }
    return $definition
}

function Get-CodexSchemaTypeNames {
    param([AllowNull()][object]$Schema)

    $type = Get-JsonProperty -Object $Schema -Name 'type' -Default $null
    if ($null -eq $type) { return @() }
    return @($type | ForEach-Object { [string]$_ })
}

function Test-CodexSchemaType {
    param(
        [AllowNull()][object]$Schema,
        [Parameter(Mandatory = $true)][string]$TypeName
    )

    return @(Get-CodexSchemaTypeNames -Schema $Schema) -contains $TypeName
}

function Resolve-CodexSchemaSource {
    param(
        [Parameter(Mandatory = $true)][string]$SchemaDirectory,
        [Parameter(Mandatory = $true)][string[]]$RequiredNames,
        [AllowEmptyCollection()][string[]]$OptionalNames = @()
    )

    $files = @(Get-ChildItem -LiteralPath $SchemaDirectory -Recurse -File -ErrorAction Stop | Sort-Object FullName)
    $bundleCandidates = @($files | Where-Object { $_.Name -ceq 'codex_app_server_protocol.v2.schemas.json' })
    $schemaCache = @{}
    $definitions = $null
    $errors = [System.Collections.Generic.List[string]]::new()
    $missingRequired = [System.Collections.Generic.List[string]]::new()
    $missingOptional = [System.Collections.Generic.List[string]]::new()
    $sourcePath = $null
    $sourceKind = $null

    if ($bundleCandidates.Count -gt 1) {
        [void]$errors.Add("Installed Codex app-server has multiple v2 schema bundles: $([string]::Join(', ', @($bundleCandidates | ForEach-Object { $_.FullName }))).")
    } elseif ($bundleCandidates.Count -eq 1) {
        $sourcePath = [string]$bundleCandidates[0].FullName
        $sourceKind = 'aggregate_v2_bundle'
        try {
            $bundle = [System.IO.File]::ReadAllText($sourcePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
            $definitions = Get-JsonProperty -Object $bundle -Name 'definitions' -Default $null
            if ($null -eq $definitions) {
                [void]$errors.Add("Installed Codex v2 schema bundle '$sourcePath' has no definitions object.")
                foreach ($schemaName in @($RequiredNames)) { [void]$missingRequired.Add($schemaName) }
                foreach ($schemaName in @($OptionalNames)) { [void]$missingOptional.Add($schemaName) }
            } else {
                foreach ($schemaName in @($RequiredNames) + @($OptionalNames)) {
                    $definition = Get-JsonProperty -Object $definitions -Name $schemaName -Default $null
                    if ($null -eq $definition) {
                        if ($RequiredNames -contains $schemaName) { [void]$missingRequired.Add($schemaName) } else { [void]$missingOptional.Add($schemaName) }
                    } else {
                        $schemaCache[$schemaName] = $definition
                    }
                }
            }
        } catch {
            [void]$errors.Add("Installed Codex v2 schema bundle '$sourcePath' is not valid JSON: $($_.Exception.Message)")
        }
    } else {
        $sourceKind = 'recursive_individual_files'
        foreach ($schemaName in @($RequiredNames) + @($OptionalNames)) {
            $matches = @($files | Where-Object { $_.Name -ceq ("{0}.json" -f $schemaName) })
            if ($matches.Count -eq 0) {
                if ($RequiredNames -contains $schemaName) { [void]$missingRequired.Add($schemaName) } else { [void]$missingOptional.Add($schemaName) }
                continue
            }
            if ($matches.Count -gt 1) {
                [void]$errors.Add("Installed Codex app-server has multiple unambiguous schema files for '$schemaName': $([string]::Join(', ', @($matches | ForEach-Object { $_.FullName }))).")
                continue
            }
            try {
                $schemaCache[$schemaName] = [System.IO.File]::ReadAllText($matches[0].FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
                if ($null -eq $schemaCache[$schemaName]) { [void]$errors.Add("Installed app-server schema file '$($matches[0].FullName)' is empty.") }
            } catch {
                [void]$errors.Add("Installed app-server schema file '$($matches[0].FullName)' is not valid JSON: $($_.Exception.Message)")
            }
        }
    }

    if ($missingRequired.Count -gt 0) {
        $missingText = if ($missingRequired.Count -eq 1) {
            "Installed Codex app-server schema is missing required v2 schema: $($missingRequired[0])."
        } else {
            "Installed Codex app-server schemas are missing required v2 schemas: $([string]::Join(', ', @($missingRequired)))."
        }
        [void]$errors.Insert(0, $missingText)
    }
    if ($missingOptional.Count -eq 1) {
        [void]$errors.Add("Installed Codex app-server schema is missing one member of the supplemental thread/read v2 schema pair: $($missingOptional[0]).")
    }

    return [pscustomobject]@{
        Available = $errors.Count -eq 0 -and $missingRequired.Count -eq 0
        Detail = [string]::Join(' ', @($errors))
        Schemas = $schemaCache
        Definitions = $definitions
        SourcePath = $sourcePath
        SourceKind = $sourceKind
        Missing = @($missingRequired)
        SupplementalMissing = @($missingOptional)
        SupplementalAvailable = $missingOptional.Count -eq 0
    }
}

function Get-CodexNativeWorkerProbe {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    $help = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @('app-server', '--help') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
    if ($help.TimedOut -or $help.ExitCode -ne 0) {
        return [pscustomobject]@{ Available = $false; Detail = "codex app-server --help failed with exit status $($help.ExitCode)." }
    }
    $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
    if ($helpText -notmatch 'generate-json-schema') {
        return [pscustomobject]@{ Available = $false; Detail = 'The installed Codex CLI does not advertise app-server schema generation.' }
    }
    $features = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @('features', 'list') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
    if ($features.TimedOut -or $features.ExitCode -ne 0 -or ([string]::Join("`n", @($features.Stdout, $features.Stderr)) -notmatch '(?im)multi_agent\s+stable\s+true')) {
        return [pscustomobject]@{ Available = $false; Detail = 'The installed Codex CLI did not report the stable multi_agent feature required for native child workers.' }
    }

    $schemaRelativeDirectory = Join-Path ([System.IO.Path]::GetRelativePath($Inputs.Run.WorkingDirectoryPath, $Inputs.Run.HomeDirectoryPath)) 'evidence/codex-app-server-schema'
    $schemaDirectory = [System.IO.Path]::GetFullPath((Join-Path $Inputs.Run.WorkingDirectoryPath $schemaRelativeDirectory))
    New-Item -ItemType Directory -Path $schemaDirectory -Force | Out-Null
    $schemaProcess = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @('app-server', 'generate-json-schema', "--out=$schemaRelativeDirectory") -Inputs $Inputs -Environment $environment -TimeoutSeconds 60
    if ($schemaProcess.TimedOut -or $schemaProcess.ExitCode -ne 0) {
        return [pscustomobject]@{ Available = $false; Detail = "Codex app-server schema generation failed with exit status $($schemaProcess.ExitCode): $([string]::Join(' ', @($schemaProcess.Stdout, $schemaProcess.Stderr)))." }
    }
    $requiredSchemaNames = @('ConfigReadParams', 'ConfigReadResponse', 'SkillsListParams', 'SkillsListResponse', 'ThreadStartParams', 'ThreadStartResponse', 'TurnStartParams', 'TurnStartResponse', 'ModelReroutedNotification')
    $supplementalSchemaNames = @('ThreadReadParams', 'ThreadReadResponse')
    $schemaResolution = Resolve-CodexSchemaSource -SchemaDirectory $schemaDirectory -RequiredNames $requiredSchemaNames -OptionalNames $supplementalSchemaNames
    if (-not $schemaResolution.Available) {
        return [pscustomobject]@{
            Available = $false
            Detail = [string]$schemaResolution.Detail
            SupportsProviderModelFallback = $false
            SchemaDirectory = $schemaDirectory
            SchemaSource = [string]$schemaResolution.SourcePath
            SchemaSourceKind = [string]$schemaResolution.SourceKind
            MissingSchemas = @($schemaResolution.Missing)
            SupplementalMissingSchemas = @($schemaResolution.SupplementalMissing)
        }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $schemaCache = $schemaResolution.Schemas
    $schemaDefinitions = $schemaResolution.Definitions
    $missingResolved = @($requiredSchemaNames | Where-Object { $null -eq (Get-JsonProperty -Object $schemaCache -Name $_ -Default $null) })
    if ($missingResolved.Count -gt 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = if ($missingResolved.Count -eq 1) { "Installed Codex app-server schema is missing required v2 schema: $($missingResolved[0])." } else { "Installed Codex app-server schemas are missing required v2 schemas: $([string]::Join(', ', @($missingResolved)))." }
            SupportsProviderModelFallback = $false
            SchemaDirectory = $schemaDirectory
            SchemaSource = [string]$schemaResolution.SourcePath
            SchemaSourceKind = [string]$schemaResolution.SourceKind
            MissingSchemas = @($missingResolved)
            SupplementalMissingSchemas = @($schemaResolution.SupplementalMissing)
        }
    }

    $threadStartParams = $schemaCache['ThreadStartParams']
    $threadStartResponse = $schemaCache['ThreadStartResponse']
    $turnStartParams = $schemaCache['TurnStartParams']
    $turnStartResponse = $schemaCache['TurnStartResponse']
    $configReadParams = $schemaCache['ConfigReadParams']
    $configReadResponse = $schemaCache['ConfigReadResponse']
    $skillsListParams = $schemaCache['SkillsListParams']
    $skillsListResponse = $schemaCache['SkillsListResponse']
    $threadReadParams = $schemaCache['ThreadReadParams']
    $threadReadResponse = $schemaCache['ThreadReadResponse']
    $modelRerouted = $schemaCache['ModelReroutedNotification']
    $threadReadSchemaAvailable = [bool]$schemaResolution.SupplementalAvailable

    $configReadCwd = Get-CodexSchemaProperty -Schema $configReadParams -PropertyName 'cwd'
    if ($null -eq $configReadCwd -or -not (Test-CodexSchemaType -Schema $configReadCwd -TypeName 'string')) { [void]$errors.Add('ConfigReadParams.properties.cwd must include type string.') }
    $configReadIncludeLayers = Get-CodexSchemaProperty -Schema $configReadParams -PropertyName 'includeLayers'
    if ($null -eq $configReadIncludeLayers -or -not (Test-CodexSchemaType -Schema $configReadIncludeLayers -TypeName 'boolean')) { [void]$errors.Add('ConfigReadParams.properties.includeLayers must include type boolean.') }
    [void](Test-CodexSchemaRequiredProperty -Schema $configReadResponse -PropertyName 'config' -Errors $errors -SchemaName 'ConfigReadResponse')

    $skillsListCwds = Get-CodexSchemaProperty -Schema $skillsListParams -PropertyName 'cwds'
    if ($null -eq $skillsListCwds -or -not (Test-CodexSchemaType -Schema $skillsListCwds -TypeName 'array')) { [void]$errors.Add('SkillsListParams.properties.cwds must include type array.') }
    $skillsListForceReload = Get-CodexSchemaProperty -Schema $skillsListParams -PropertyName 'forceReload'
    if ($null -eq $skillsListForceReload -or -not (Test-CodexSchemaType -Schema $skillsListForceReload -TypeName 'boolean')) { [void]$errors.Add('SkillsListParams.properties.forceReload must include type boolean.') }
    $skillsListData = Test-CodexSchemaRequiredProperty -Schema $skillsListResponse -PropertyName 'data' -Errors $errors -SchemaName 'SkillsListResponse'
    if (-not (Test-CodexSchemaType -Schema $skillsListData -TypeName 'array')) { [void]$errors.Add('SkillsListResponse.properties.data must include type array.') }
    $skillsListEntry = Get-CodexSchemaDefinition -Schema $skillsListResponse -DefinitionName 'SkillsListEntry' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'SkillsListResponse'
    $skillMetadata = Get-CodexSchemaDefinition -Schema $skillsListResponse -DefinitionName 'SkillMetadata' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'SkillsListResponse'
    [void](Test-CodexSchemaRequiredProperty -Schema $skillsListEntry -PropertyName 'skills' -Errors $errors -SchemaName 'SkillsListResponse.definitions.SkillsListEntry')
    foreach ($field in @('name', 'path', 'enabled')) { [void](Test-CodexSchemaRequiredProperty -Schema $skillMetadata -PropertyName $field -Errors $errors -SchemaName 'SkillsListResponse.definitions.SkillMetadata') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $skillMetadata -PropertyName 'name') -TypeName 'string')) { [void]$errors.Add('SkillMetadata.name must include type string.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $skillMetadata -PropertyName 'enabled') -TypeName 'boolean')) { [void]$errors.Add('SkillMetadata.enabled must include type boolean.') }

    foreach ($field in @('model', 'cwd', 'approvalPolicy', 'sandbox', 'ephemeral')) {
        if ($null -eq (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName $field)) { [void]$errors.Add("ThreadStartParams.properties.$field is missing.") }
    }
    foreach ($field in @('model', 'cwd')) {
        if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName $field) -TypeName 'string')) { [void]$errors.Add("ThreadStartParams.properties.$field must include type string.") }
    }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'ephemeral') -TypeName 'boolean')) { [void]$errors.Add('ThreadStartParams.properties.ephemeral must include type boolean.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'approvalPolicy')) -ne '#/definitions/AskForApproval') { [void]$errors.Add('ThreadStartParams.approvalPolicy must reference definitions.AskForApproval.') }
    $sandboxProperty = Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'sandbox'
    $sandboxReference = Get-CodexSchemaReference -Schema $sandboxProperty
    $sandboxDefinition = if ($sandboxReference -eq '#/definitions/SandboxMode') { Get-CodexSchemaDefinition -Schema $threadStartParams -DefinitionName 'SandboxMode' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'ThreadStartParams' } else { $null }
    if ($sandboxReference -ne '#/definitions/SandboxMode' -or $null -eq $sandboxDefinition) { [void]$errors.Add('ThreadStartParams.sandbox must reference definitions.SandboxMode.') }
    $sandboxEnum = @((Get-JsonProperty -Object $sandboxDefinition -Name 'enum' -Default @()) | ForEach-Object { [string]$_ })
    $requiredSandboxModes = @('read-only', 'workspace-write', 'danger-full-access')
    foreach ($mode in $requiredSandboxModes) {
        if ($sandboxEnum -notcontains $mode) { [void]$errors.Add("ThreadStartParams.definitions.SandboxMode.enum is missing '$mode'.") }
    }
    $fallbackProperty = Get-CodexSchemaProperty -Schema $threadStartParams -PropertyName 'allowProviderModelFallback'
    $supportsProviderModelFallback = $null -ne $fallbackProperty
    if ($supportsProviderModelFallback -and -not (Test-CodexSchemaType -Schema $fallbackProperty -TypeName 'boolean')) {
        [void]$errors.Add('ThreadStartParams.allowProviderModelFallback must include type boolean when installed.')
    }

    foreach ($field in @('model', 'cwd', 'thread')) { [void](Test-CodexSchemaRequiredProperty -Schema $threadStartResponse -PropertyName $field -Errors $errors -SchemaName 'ThreadStartResponse') }
    $instructionSourcesProperty = Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'instructionSources'
    if ($null -eq $instructionSourcesProperty) {
        [void]$errors.Add('ThreadStartResponse.properties.instructionSources is missing.')
    } elseif (-not (Test-CodexSchemaType -Schema $instructionSourcesProperty -TypeName 'array')) {
        [void]$errors.Add('ThreadStartResponse.instructionSources must be an array when present.')
    } elseif ((Get-CodexSchemaReference -Schema (Get-JsonProperty -Object $instructionSourcesProperty -Name 'items' -Default $null)) -ne '#/definitions/LegacyAppPathString') {
        [void]$errors.Add('ThreadStartResponse.instructionSources.items must reference definitions.LegacyAppPathString.')
    }
    $threadReference = Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'thread')
    if ($threadReference -ne '#/definitions/Thread') { [void]$errors.Add('ThreadStartResponse.thread must reference definitions.Thread.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'model') -TypeName 'string')) { [void]$errors.Add('ThreadStartResponse.model must include type string.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadStartResponse -PropertyName 'cwd')) -ne '#/definitions/AbsolutePathBuf') { [void]$errors.Add('ThreadStartResponse.cwd must reference definitions.AbsolutePathBuf.') }
    $threadDefinition = Get-CodexSchemaDefinition -Schema $threadStartResponse -DefinitionName 'Thread' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'ThreadStartResponse'
    foreach ($field in @('id', 'cwd', 'ephemeral', 'sessionId')) { [void](Test-CodexSchemaRequiredProperty -Schema $threadDefinition -PropertyName $field -Errors $errors -SchemaName 'ThreadStartResponse.definitions.Thread') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'id') -TypeName 'string')) { [void]$errors.Add('ThreadStartResponse.definitions.Thread.id must include type string.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'cwd')) -ne '#/definitions/AbsolutePathBuf') { [void]$errors.Add('ThreadStartResponse.definitions.Thread.cwd must reference definitions.AbsolutePathBuf.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'ephemeral') -TypeName 'boolean')) { [void]$errors.Add('ThreadStartResponse.definitions.Thread.ephemeral must include type boolean.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadDefinition -PropertyName 'sessionId') -TypeName 'string')) { [void]$errors.Add('ThreadStartResponse.definitions.Thread.sessionId must include type string.') }

    foreach ($field in @('input', 'threadId')) { [void](Test-CodexSchemaRequiredProperty -Schema $turnStartParams -PropertyName $field -Errors $errors -SchemaName 'TurnStartParams') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName 'input') -TypeName 'array')) { [void]$errors.Add('TurnStartParams.input must be an array.') }
    if ((Get-CodexSchemaReference -Schema (Get-JsonProperty -Object (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName 'input') -Name 'items' -Default $null)) -ne '#/definitions/UserInput') { [void]$errors.Add('TurnStartParams.input.items must reference definitions.UserInput.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName 'threadId') -TypeName 'string')) { [void]$errors.Add('TurnStartParams.threadId must include type string.') }
    foreach ($field in @('cwd', 'model')) {
        if ($null -eq (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field)) { [void]$errors.Add("TurnStartParams.properties.$field is missing.") }
        elseif (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field) -TypeName 'string')) { [void]$errors.Add("TurnStartParams.properties.$field must include type string.") }
    }
    foreach ($field in @(
        [pscustomobject]@{ Name = 'effort'; Reference = '#/definitions/ReasoningEffort' }
        [pscustomobject]@{ Name = 'approvalPolicy'; Reference = '#/definitions/AskForApproval' }
        [pscustomobject]@{ Name = 'sandboxPolicy'; Reference = '#/definitions/SandboxPolicy' }
    )) {
        if ($null -eq (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field.Name)) { [void]$errors.Add("TurnStartParams.properties.$($field.Name) is missing.") }
        elseif ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $turnStartParams -PropertyName $field.Name)) -ne $field.Reference) { [void]$errors.Add("TurnStartParams.$($field.Name) must reference $($field.Reference.Replace('#/definitions/', 'definitions.')).") }
    }
    $sandboxPolicyDefinition = Get-CodexSchemaDefinition -Schema $turnStartParams -DefinitionName 'SandboxPolicy' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'TurnStartParams'
    $dangerFullAccessPolicy = @((Get-JsonProperty -Object $sandboxPolicyDefinition -Name 'oneOf' -Default @()) | Where-Object {
        $typeProperty = Get-JsonProperty -Object (Get-JsonProperty -Object $_ -Name 'properties' -Default $null) -Name 'type' -Default $null
        @((Get-JsonProperty -Object $typeProperty -Name 'enum' -Default @())) -contains 'dangerFullAccess'
    }) | Select-Object -First 1
    if ($null -eq $dangerFullAccessPolicy) {
        [void]$errors.Add('TurnStartParams.definitions.SandboxPolicy must advertise the dangerFullAccess policy used by the runner.')
    }
    $turnProperty = Test-CodexSchemaRequiredProperty -Schema $turnStartResponse -PropertyName 'turn' -Errors $errors -SchemaName 'TurnStartResponse'
    $turnReference = Get-CodexSchemaReference -Schema $turnProperty
    if ($turnReference -ne '#/definitions/Turn') { [void]$errors.Add('TurnStartResponse.turn must reference definitions.Turn.') }
    $turnDefinition = Get-CodexSchemaDefinition -Schema $turnStartResponse -DefinitionName 'Turn' -Definitions $schemaDefinitions -Errors $errors -SchemaName 'TurnStartResponse'
    foreach ($field in @('id', 'items', 'status')) { [void](Test-CodexSchemaRequiredProperty -Schema $turnDefinition -PropertyName $field -Errors $errors -SchemaName 'TurnStartResponse.definitions.Turn') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnDefinition -PropertyName 'id') -TypeName 'string')) { [void]$errors.Add('TurnStartResponse.definitions.Turn.id must include type string.') }
    if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $turnDefinition -PropertyName 'items') -TypeName 'array')) { [void]$errors.Add('TurnStartResponse.definitions.Turn.items must include type array.') }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $turnDefinition -PropertyName 'status')) -ne '#/definitions/TurnStatus') { [void]$errors.Add('TurnStartResponse.definitions.Turn.status must reference definitions.TurnStatus.') }

    if ($threadReadSchemaAvailable) {
        [void](Test-CodexSchemaRequiredProperty -Schema $threadReadParams -PropertyName 'threadId' -Errors $errors -SchemaName 'ThreadReadParams')
        if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $threadReadParams -PropertyName 'threadId') -TypeName 'string')) { [void]$errors.Add('ThreadReadParams.threadId must include type string.') }
        $includeTurnsProperty = Get-CodexSchemaProperty -Schema $threadReadParams -PropertyName 'includeTurns'
        if ($null -eq $includeTurnsProperty -or -not (Test-CodexSchemaType -Schema $includeTurnsProperty -TypeName 'boolean')) { [void]$errors.Add('ThreadReadParams.includeTurns must be an optional boolean.') }
        $threadReadProperty = Test-CodexSchemaRequiredProperty -Schema $threadReadResponse -PropertyName 'thread' -Errors $errors -SchemaName 'ThreadReadResponse'
        if ((Get-CodexSchemaReference -Schema $threadReadProperty) -ne '#/definitions/Thread') { [void]$errors.Add('ThreadReadResponse.thread must reference definitions.Thread.') }
    }
    foreach ($field in @('threadId', 'turnId', 'fromModel', 'toModel', 'reason')) { [void](Test-CodexSchemaRequiredProperty -Schema $modelRerouted -PropertyName $field -Errors $errors -SchemaName 'ModelReroutedNotification') }
    foreach ($field in @('threadId', 'turnId', 'fromModel', 'toModel')) {
        if (-not (Test-CodexSchemaType -Schema (Get-CodexSchemaProperty -Schema $modelRerouted -PropertyName $field) -TypeName 'string')) { [void]$errors.Add("ModelReroutedNotification.$field must include type string.") }
    }
    if ((Get-CodexSchemaReference -Schema (Get-CodexSchemaProperty -Schema $modelRerouted -PropertyName 'reason')) -ne '#/definitions/ModelRerouteReason') { [void]$errors.Add('ModelReroutedNotification.reason must reference definitions.ModelRerouteReason.') }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = 'Installed Codex app-server schema failed structural validation: ' + [string]::Join(' ', @($errors))
            SupportsProviderModelFallback = $supportsProviderModelFallback
            SchemaDirectory = $schemaDirectory
            SchemaSource = [string]$schemaResolution.SourcePath
            SchemaSourceKind = [string]$schemaResolution.SourceKind
            SandboxModes = @($sandboxEnum)
            ThreadReadSchemaAvailable = $threadReadSchemaAvailable
        }
    }
    $schemaDetail = if ($threadReadSchemaAvailable) {
        'Codex multi_agent is stable and the installed v2 app-server schema structurally proves the consumed config/read, skills/list, thread/start, turn/start, thread/read, and model/rerouted fields.'
    } else {
        'Codex multi_agent is stable and the installed v2 app-server schema structurally proves the consumed config/read, skills/list, thread/start, turn/start, and model/rerouted fields; thread/read is supplemental and not advertised.'
    }
    if ($supportsProviderModelFallback) {
        $schemaDetail += ' allowProviderModelFallback is supported and will be sent as false; reroute notifications remain fail-closed.'
    } else {
        $schemaDetail += ' allowProviderModelFallback is not exposed by the installed protocol; reroute notifications remain fail-closed.'
    }
    return [pscustomobject]@{
        Available = $true
        Detail = $schemaDetail
        SupportsProviderModelFallback = $supportsProviderModelFallback
        SchemaDirectory = $schemaDirectory
        SchemaSource = [string]$schemaResolution.SourcePath
        SchemaSourceKind = [string]$schemaResolution.SourceKind
        SandboxModes = @($sandboxEnum)
        ThreadReadSchemaAvailable = $threadReadSchemaAvailable
    }
}

function Invoke-CodexNativeSkillConfigProbe {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment = $null,
        [string]$Transport = 'preflight',
        [int]$TimeoutSeconds = 30
    )

    $environmentToUse = if ($null -eq $Environment) { New-RunnerEnvironment -Run $Inputs.Run } else { $Environment }
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('app-server', '--strict-config', '--stdio')) { $arguments.Add($argument) }
    Add-CodexSessionConfigArguments -Arguments $arguments -CandidateSkillName $Inputs.Run.CandidateSkillName -IncludeShellEnvironmentPolicy
    $requests = @(
        [ordered]@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = [ordered]@{ clientInfo = [ordered]@{ name = 'codebelt-agentic-eval-runner'; title = 'Codebelt Eval Runner'; version = '0.9.1' }; capabilities = [ordered]@{ experimentalApi = $true } } }
        [ordered]@{ jsonrpc = '2.0'; method = 'initialized' }
        [ordered]@{ jsonrpc = '2.0'; id = 2; method = 'config/read'; params = [ordered]@{ includeLayers = $false; cwd = $Inputs.Run.WorkingDirectoryPath } }
        [ordered]@{ jsonrpc = '2.0'; id = 3; method = 'skills/list'; params = [ordered]@{ cwds = @($Inputs.Run.WorkingDirectoryPath); forceReload = $true } }
    )
    $requestText = [string]::Join("`n", @($requests | ForEach-Object { ConvertTo-RunnerJson -Value $_ -Depth 50 -Compress })) + "`n"
    $process = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @($arguments) -Inputs $Inputs -Environment $environmentToUse -InputBytes ([System.Text.UTF8Encoding]::new($false).GetBytes($requestText)) -TimeoutSeconds $TimeoutSeconds
    if ($process.TimedOut -or $process.ExitCode -ne 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = "Codex app-server strict native-skill config probe failed with exit status $($process.ExitCode): $([string]::Join(' ', @($process.Stdout, $process.Stderr)))."
            Evidence = [ordered]@{ failures = @('native_skill_config_probe_failed') }
            Failures = @('native_skill_config_probe_failed')
        }
    }

    $parsedMessages = ConvertFrom-JsonLines -Text ([string]$process.Stdout)
    if (@($parsedMessages.Errors).Count -gt 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = "Codex app-server strict native-skill config probe emitted malformed JSON: $([string]::Join(', ', @($parsedMessages.Errors)))."
            Evidence = [ordered]@{ failures = @('native_skill_config_probe_malformed_json') }
            Failures = @('native_skill_config_probe_malformed_json')
        }
    }
    $messages = @($parsedMessages.Events)
    $configReadResponse = @($messages | Where-Object { $null -ne (Get-JsonProperty -Object $_ -Name 'id' -Default $null) -and [int](Get-JsonProperty -Object $_ -Name 'id' -Default 0) -eq 2 } | Select-Object -First 1)
    $skillsListResponse = @($messages | Where-Object { $null -ne (Get-JsonProperty -Object $_ -Name 'id' -Default $null) -and [int](Get-JsonProperty -Object $_ -Name 'id' -Default 0) -eq 3 } | Select-Object -First 1)
    if ($configReadResponse.Count -ne 1 -or $skillsListResponse.Count -ne 1) {
        return [pscustomobject]@{
            Available = $false
            Detail = 'Codex app-server strict native-skill config probe did not return both config/read and skills/list responses.'
            Evidence = [ordered]@{ failures = @('native_skill_config_probe_missing_response') }
            Failures = @('native_skill_config_probe_missing_response')
        }
    }

    $configReadRequest = $requests[2]
    $skillsListRequest = $requests[3]
    $observation = New-CodexNativeSkillIsolationObservation -CandidateSkillName $Inputs.Run.CandidateSkillName -Transport $Transport -ConfigReadRequest $configReadRequest -ConfigReadResponse $configReadResponse[0] -SkillsListRequest $skillsListRequest -SkillsListResponse $skillsListResponse[0]
    return [pscustomobject]@{
        Available = [bool]$observation.Verified
        Detail = if ([bool]$observation.Verified) { 'Installed Codex accepted the session-level native skill controls and proved skills.include_instructions=false through config/read plus candidate state through skills/list.' } else { "Installed Codex native skill config probe failed: $([string]::Join(', ', @($observation.Failures)))." }
        Evidence = $observation.Evidence
        Failures = @($observation.Failures)
    }
}

function Invoke-CodexPromptInputNativeSkillProbe {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [int]$TimeoutSeconds = 30
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('debug')
    $arguments.Add('prompt-input')
    Add-CodexSessionConfigArguments -Arguments $arguments -CandidateSkillName $Inputs.Run.CandidateSkillName
    $arguments.Add('model-free native skill suppression probe')
    $process = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments @($arguments) -Inputs $Inputs -Environment $Environment -TimeoutSeconds $TimeoutSeconds
    if ($process.TimedOut -or $process.ExitCode -ne 0) {
        return [pscustomobject]@{
            Available = $false
            Detail = "Codex debug prompt-input native-skill probe failed with exit status $($process.ExitCode): $([string]::Join(' ', @($process.Stdout, $process.Stderr)))."
            PromptInput = ''
        }
    }
    $suppressed = Test-CodexPromptInputSuppressesNativeSkills -PromptInputJson ([string]$process.Stdout) -CandidateSkillName $Inputs.Run.CandidateSkillName
    return [pscustomobject]@{
        Available = $suppressed
        Detail = if ($suppressed) { 'Codex debug prompt-input showed no model-visible native skill catalog or candidate skill instructions with the session controls applied.' } else { 'Codex debug prompt-input still exposed native skill catalog or candidate skill instructions.' }
        PromptInput = [string]$process.Stdout
    }
}

function Resolve-SandboxCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Resolve-ExternalCommand -Name $Name
}

function Get-CodexDescriptor {
    $copy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $copy[$key] = $descriptor[$key] }
    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $version = 'unavailable'
    if ($null -ne $commandInfo) {
        $observation = Get-ExternalCommandVersion -CommandInfo $commandInfo
        $version = [string]$observation.Version
    }
    $copy.harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = $version }
    return $copy
}

function New-CodexCliArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][string]$LastResponsePath,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform = (Get-PlatformName)
    )

    $directoryArgument = Get-SandboxVisiblePath -HostPath $Inputs.Run.WorkingDirectoryPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $outputArgument = Get-SandboxVisiblePath -HostPath $LastResponsePath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--ask-for-approval', 'never', 'exec', '--strict-config', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check', '--json', '--color', 'never', '--cd', $directoryArgument, '--model', $Inputs.Profile.Model, '--sandbox', 'danger-full-access', '--config', 'shell_environment_policy.inherit=none')) {
        $arguments.Add([string]$argument)
    }
    Add-CodexSessionConfigArguments -Arguments $arguments -CandidateSkillName $Inputs.Run.CandidateSkillName -SwitchName '--config'
    foreach ($argument in @('--output-last-message', $outputArgument)) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments.Add('-c')
        $arguments.Add("model_reasoning_effort=$($Inputs.Profile.ReasoningEffort)")
    }
    $arguments.Add('-')
    return @($arguments)
}

function ConvertTo-CodexToolSignalText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return [string]$Value }
    try { return ($Value | ConvertTo-Json -Depth 20 -Compress) } catch { return [string]$Value }
}

function Test-CodexPolicyBlockedToolSignal {
    param([Parameter(Mandatory = $true)][object]$Item)

    $status = ([string](Get-JsonProperty -Object $Item -Name 'status' -Default '')).ToLowerInvariant()
    $error = Get-JsonProperty -Object $Item -Name 'error' -Default $null
    $errorCode = ([string](Get-JsonProperty -Object $error -Name 'code' -Default '')).ToLowerInvariant()
    $signalParts = @(
            ConvertTo-CodexToolSignalText -Value (Get-JsonProperty -Object $Item -Name 'aggregated_output' -Default $null)
            ConvertTo-CodexToolSignalText -Value (Get-JsonProperty -Object $Item -Name 'output' -Default $null)
            ConvertTo-CodexToolSignalText -Value (Get-JsonProperty -Object $error -Name 'message' -Default $null)
            ConvertTo-CodexToolSignalText -Value (Get-JsonProperty -Object $Item -Name 'reason' -Default $null)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $signalText = if ($null -eq $signalParts) { '' } else { [string]::Join("`n", [string[]]@($signalParts)) }

    if ($status -in @('blocked', 'denied', 'rejected', 'policy_blocked', 'policyblocked')) { return $true }
    if ($errorCode -match '^(blocked[_-]?by[_-]?policy|policy[_-]?blocked|sandbox[_-]?blocked|read[_-]?only|readonly)$') { return $true }
    return $signalText -match '(?im)\bblocked by policy\b'
}

function Get-CodexBehavioralCapabilityFailure {
    param([Parameter(Mandatory = $true)][object]$Item)

    $itemType = [string](Get-JsonProperty -Object $Item -Name 'type' -Default '')
    if ($itemType -notin @('command_execution', 'file_change', 'mcp_tool_call')) { return $null }
    if (-not (Test-CodexPolicyBlockedToolSignal -Item $Item)) { return $null }

    return [ordered]@{
        code = 'workspace_operation_blocked_by_policy'
        signal = 'structured_tool_result'
        item_type = $itemType
        item_id = Get-JsonProperty -Object $Item -Name 'id' -Default $null
        status = Get-JsonProperty -Object $Item -Name 'status' -Default $null
        exit_code = Get-JsonProperty -Object $Item -Name 'exit_code' -Default $null
        command = Get-JsonProperty -Object $Item -Name 'command' -Default $null
    }
}

function Get-CodexStderrPolicyRejections {
    param([AllowNull()][string]$StderrText)

    # Detects Codex runtime/tool-router policy-rejection signals from STDERR.
    # Covers the iteration-12 failure shape where the app-server turn completes
    # but runtime-level tool executions are rejected below the protocol layer,
    # producing no structured commandExecution items in the event stream.
    # Requires codex_core provenance PLUS an execution-failure pattern AND a
    # policy indicator on the same line; bare 'blocked by policy' without
    # runtime provenance is not sufficient.
    $result = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($StderrText)) { return $result }

    foreach ($line in ($StderrText -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch 'codex_core') { continue }
        $hasExecFailure = $line -match '(?i)exec_command.{0,80}fail' -or $line -match 'CreateProcess'
        if (-not $hasExecFailure) { continue }
        $hasPolicyIndicator = $line -match 'Rejected\s*\(' -or $line -match '(?i)\bblocked\s+by\s+policy\b'
        if (-not $hasPolicyIndicator) { continue }

        [void]$result.Add([ordered]@{
            code   = 'workspace_operation_blocked_by_policy'
            signal = 'runtime_stderr'
            source = 'codex_core_tools_router'
        })
    }
    return $result
}

function Get-CodexCapabilityMap {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [bool]$HardFilesystemConfinement = $false,
        [bool]$NativeWorkerAvailable = $true,
        [string]$AuthKind = ''
    )

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $capabilities[$capabilityName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName)
    }
    $capabilities['filesystem_confinement'] = if ($HardFilesystemConfinement) { 'supported' } else { 'unsupported' }
    $capabilities['candidate_skill_exposure'] = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' }
    foreach ($name in @('native_worker_delegation', 'delegated_worker_full_capability', 'delegated_worker_model_lock', 'delegated_worker_working_directory', 'delegated_worker_result_capture', 'delegated_worker_capacity_signal')) {
        # The app-server probe proves that the native surface is available;
        # only the child terminal evidence can prove the selected controls.
        $capabilities[$name] = if ($NativeWorkerAvailable) { 'conditional' } else { 'unsupported' }
    }
    $capabilities['scripted_multi_turn_same_session'] = if ($Inputs.Run.Interaction -eq $null) {
        'conditional'
    } elseif ($AuthKind -ne 'subscription_file' -or -not $NativeWorkerAvailable) {
        'unsupported'
    } else {
        'supported'
    }
    return $capabilities
}

function Get-CodexPreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $platform = Get-PlatformName
    $sandboxName = switch ($platform) {
        'linux' { 'bwrap' }
        'macos' { 'sandbox-exec' }
        default { $null }
    }
    $sandboxInfo = if ([string]::IsNullOrWhiteSpace([string]$sandboxName)) { $null } else { Resolve-SandboxCommand -Name $sandboxName }
    $versionObservation = $null
    $nativeWorkerObservation = $null
    $nativeSkillConfigObservation = $null

    if ($profile.Runner -ne 'codex') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than codex.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is codex.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('Codex requires a model in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail $profile.Model))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by codex.")
    }
    if ($profile.ToolProfile -ne 'default') {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by codex.")
    }

    if ($null -eq $commandInfo) {
        $reasons.Add('The Codex CLI executable is not available on PATH.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment (New-RunnerEnvironment -Run $run) -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The Codex CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'codex --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }

            $globalHelp = Get-CodexHelpResult -CommandInfo $commandInfo -Inputs $Inputs -Arguments @('--help')
            $help = Get-CodexHelpResult -CommandInfo $commandInfo -Inputs $Inputs
            if ($globalHelp.TimedOut -or $globalHelp.ExitCode -ne 0) {
                $reasons.Add("Codex --help failed with exit status $($globalHelp.ExitCode).")
            }
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $reasons.Add("Codex --ask-for-approval never exec --help failed with exit status $($help.ExitCode).")
            } else {
                $helpText = [string]::Join("`n", @($globalHelp.Stdout, $globalHelp.Stderr, $help.Stdout, $help.Stderr))
                foreach ($flag in @('--ask-for-approval', '--strict-config', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--json', '--output-last-message', '--sandbox', '--cd', '--model', '--config')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed Codex CLI does not advertise required flag '$flag'.")
                    }
                }
                if ($helpText -notmatch [regex]::Escape('danger-full-access')) {
                    $reasons.Add("The installed Codex CLI does not advertise the required unrestricted sandbox mode 'danger-full-access'.")
                }
                $visiblePlatform = if ($platform -eq 'linux' -and $null -ne $sandboxInfo) { 'linux' } else { $platform }
                $constructed = New-CodexCliArguments -Inputs $Inputs -LastResponsePath (Join-Path $run.RunRoot 'evidence/codex-final.txt') -VisiblePlatform $visiblePlatform
                if (@($constructed) -contains '--approve-for-me') {
                    $reasons.Add('The constructed Codex invocation must not combine --approve-for-me with explicit --sandbox selection.')
                }
                $sandboxIndex = [Array]::IndexOf([string[]]$constructed, '--sandbox')
                $approvalIndex = [Array]::IndexOf([string[]]$constructed, '--ask-for-approval')
                $execIndex = [Array]::IndexOf([string[]]$constructed, 'exec')
                if ($approvalIndex -lt 0 -or $execIndex -lt 0 -or $approvalIndex -gt $execIndex -or $sandboxIndex -lt 0 -or $sandboxIndex + 1 -ge $constructed.Count -or $constructed[$sandboxIndex + 1] -ne 'danger-full-access') {
                    $reasons.Add('The constructed Codex invocation must set --ask-for-approval never before exec and retain --sandbox danger-full-access.')
                }
                foreach ($requiredConfig in @(Get-CodexSkillSessionConfigValues -CandidateSkillName $run.CandidateSkillName)) {
                    if (@($constructed | Where-Object { [string]$_ -eq $requiredConfig }).Count -ne 1) {
                        $reasons.Add("The constructed Codex invocation must include session config '$requiredConfig'.")
                    }
                }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'Codex accepts the constructed noninteractive invocation: --ask-for-approval never, exec, --strict-config, --sandbox danger-full-access, ephemeral JSON output, and session native-skill controls.'))
                }
            }
            $nativeWorkerObservation = Get-CodexNativeWorkerProbe -CommandInfo $commandInfo -Inputs $Inputs
            if ($nativeWorkerObservation.Available) {
                $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status passed -Detail ($nativeWorkerObservation.Detail + ' This proves API readiness only; the actual child remains conditional until terminal evidence.')))
                $warnings.Add('Codex app-server native-worker controls remain conditional until terminal evidence proves the actual child model, cwd, HOME/config, fresh identity, prompt, exclusions, and terminal capture.')
            } else {
                $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status unavailable -Detail $nativeWorkerObservation.Detail))
                $reasons.Add($nativeWorkerObservation.Detail)
            }
            $nativeSkillConfigObservation = Invoke-CodexNativeSkillConfigProbe -CommandInfo $commandInfo -Inputs $Inputs -Transport 'preflight'
            if ($nativeSkillConfigObservation.Available) {
                $checks.Add((New-PreflightCheck -Name 'native_skill_isolation_controls' -Status passed -Detail $nativeSkillConfigObservation.Detail))
            } else {
                $checks.Add((New-PreflightCheck -Name 'native_skill_isolation_controls' -Status failed -Detail $nativeSkillConfigObservation.Detail))
                $reasons.Add($nativeSkillConfigObservation.Detail)
            }
        } catch {
            $reasons.Add("Could not inspect Codex CLI capabilities: $($_.Exception.Message)")
        }
    }

    $auth = Get-CodexAuthSource
    if ($auth.Kind -eq 'missing') {
        $reasons.Add('Neither a narrow Codex provider API-key environment variable nor subscription auth.json is available.')
    } elseif ($auth.Kind -eq 'subscription_file') {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail 'Codex app-server uses a fresh temporary auth-only CODEX_HOME containing only a copied auth.json; the source home and all ambient Codex configuration remain outside the worker.'))
    } else {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail "Authentication is available through the narrow $($auth.Name) environment variable; the child shell policy is set to inherit=none."))
    }

    if ($null -ne $run.Interaction) {
        if ($auth.Kind -ne 'subscription_file') {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The Codex API-key compatibility transport is one-shot and cannot continue the same app-server thread.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible for the Codex API-key compatibility transport; same-session scripted turns require the native app-server thread/start + repeated turn/start surface.')
        } elseif ($null -eq $nativeWorkerObservation -or -not $nativeWorkerObservation.Available) {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The installed Codex app-server schema did not prove thread/start plus repeatable turn/start on one thread.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible: model-free Codex app-server schema probing did not prove same-thread continuation before execution.')
        } else {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status passed -Detail 'Codex app-server reuses the fresh thread/start identity for every deterministic user turn and dispatches the next turn/start only after the prior turn reaches terminal state.'))
        }
    }

    if ($auth.Kind -eq 'subscription_file') {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail 'The subscription app-server transport uses a temporary auth-only home but is not wrapped by an external run-only sandbox. Codex receives full operational permission inside the eval boundary.'))
        $warnings.Add('Subscription execution uses pragmatic isolation. The adapter does not claim that an external filesystem sandbox protects the app-server transport.')
    } elseif ($null -eq $sandboxName) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status not_applicable -Detail "Platform '$platform' has no configured external hard-confinement mechanism; pragmatic isolation remains available."))
        $warnings.Add("Platform '$platform' has no external hard filesystem confinement in this adapter; execution will report pragmatic isolation.")
    } elseif ($null -eq $sandboxInfo) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail "External '$sandboxName' is unavailable; pragmatic isolation remains available."))
        $warnings.Add("External '$sandboxName' was unavailable; execution will report pragmatic isolation.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $sandboxName confines Codex to the staged run and required system runtime paths; Codex sandbox=danger-full-access remains enabled inside it."))
    }

    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The selected transport starts an ephemeral thread and never supplies a resume, continue, or existing session identifier.'))
    if ($auth.Kind -eq 'subscription_file') {
        $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The app-server parent receives a filtered environment plus a temporary auth-only CODEX_HOME. Child shell inheritance is disabled with shell_environment_policy.inherit=none. Native skill isolation is proven separately through session skill controls, config/read, skills/list, and runtime access evidence.'))
        $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "thread/start and turn/start set cwd to $($run.WorkingDirectoryPath); HOME and USERPROFILE remain staged under $($run.HomeDirectoryPath)."))
        $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only auth.json is copied into a temporary auth-only CODEX_HOME and it is removed in finally; config.toml, skills, agents, sessions, memories, plugins, MCP configuration, and AGENTS.md are not copied. This does not claim hard filesystem confinement where none is available.'))
    } else {
        $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The compatibility transport uses an isolated CODEX_HOME plus --ignore-user-config and --ignore-rules; unrelated inherited environment variables are removed.'))
        $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "--cd $($run.WorkingDirectoryPath); CODEX_HOME under $($run.HomeDirectoryPath)"))
        $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only the selected provider API-key variable is passed to Codex; auth files are not copied into the worker HOME.'))
    }

    $hardConfinement = $auth.Kind -eq 'environment' -and $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-CodexCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement -NativeWorkerAvailable ($null -ne $nativeWorkerObservation -and $nativeWorkerObservation.Available) -AuthKind $auth.Kind
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    if ($auth.Kind -eq 'subscription_file') {
        foreach ($mechanism in @('native app-server initialize + config/read + skills/list + thread/start + turn/start', 'session skills.include_instructions=false', 'session skills.config candidate disable', 'pre-turn skills/list candidate-state verification', 'temporary auth-only subscription CODEX_HOME', 'ephemeral thread', 'thread/read after turn completion', 'instructionSources validation', 'model/rerouted fail-closed', 'approvalPolicy=never', 'sandboxPolicy=dangerFullAccess', 'shell_environment_policy.inherit=none', 'filtered parent process environment', 'prompt in turn/start input')) { $mechanisms.Add($mechanism) }
        if ($null -ne $run.Interaction) { $mechanisms.Add('same-thread repeated turn/start for scripted interaction') } else { $mechanisms.Add('no session continuation') }
    } else {
        foreach ($mechanism in @('--ask-for-approval never', 'codex exec --ephemeral compatibility transport', '--strict-config', '--ignore-user-config', '--ignore-rules', '--sandbox danger-full-access', 'shell_environment_policy.inherit=none', 'session skills.include_instructions=false', 'session skills.config candidate disable', 'pre-turn debug prompt-input native-skill suppression proof', 'pre-turn skills/list candidate-state verification', 'isolated CODEX_HOME', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    }
    if ($hardConfinement) { $mechanisms.Add("external $sandboxName filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    $document = New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
    if ($null -ne $nativeWorkerObservation -and $nativeWorkerObservation.Available) {
        $document.protocol_observations = [ordered]@{
            schema_directory = [string]$nativeWorkerObservation.SchemaDirectory
            schema_source = [string]$nativeWorkerObservation.SchemaSource
            schema_source_kind = [string]$nativeWorkerObservation.SchemaSourceKind
            sandbox_modes = @($nativeWorkerObservation.SandboxModes)
            allow_provider_model_fallback = [bool]$nativeWorkerObservation.SupportsProviderModelFallback
            thread_read_schema_available = [bool]$nativeWorkerObservation.ThreadReadSchemaAvailable
        }
    }
    if ($null -ne $nativeSkillConfigObservation) {
        $document.native_skill_isolation = $nativeSkillConfigObservation.Evidence
    }
    return $document
}

function New-CodexEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth
    )

    $codexHome = Join-Path $Inputs.Run.HomeDirectoryPath '.codex'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $environment = New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables @(Get-ProviderAuthenticationVariables -Provider 'openai') -Additional @{ CODEX_HOME = $codexHome }
    if ($Auth.Kind -eq 'environment') { return $environment }
    return $environment
}

function Get-LinuxCodexSandboxArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--die-with-parent', '--new-session', '--unshare-pid')) { $args.Add($argument) }
    foreach ($path in @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/lib64', '/libexec', '/etc', '/opt')) {
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
        CODEX_HOME = '/run/home/.codex'
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    foreach ($authName in @(Get-ProviderAuthenticationVariables -Provider 'openai')) {
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

function New-CodexMacosSandboxProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo
    )

    $profilePath = Join-Path $Inputs.Run.HomeDirectoryPath 'codex-sandbox.sb'
    $runRoot = $Inputs.Run.RunRoot.Replace('\', '/')
    $commandDirectory = (Split-Path -Parent ([string]$CommandInfo.Source)).Replace('\', '/')
    $readRoots = @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/libexec', '/System', '/Library', '/opt', '/private/var/db', $commandDirectory)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('(version 1)')
    $lines.Add('(deny default)')
    $lines.Add('(allow process*)')
    $lines.Add('(allow network*)')
    foreach ($root in $readRoots | Sort-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            $escapedRoot = $root.Replace('\', '/').Replace('"', '\"')
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

function Write-CodexCapture {
    param(
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $path = Join-Path $RunData.Run.RunRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    return New-ArtifactReference -Run $RunData.Run -Path $RelativePath -Scope run -MediaType (Get-MediaType -Path $RelativePath)
}

function New-CodexBlockedProcessObservation {
    param(
        [Parameter(Mandatory = $true)][DateTime]$StartedUtc,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $finished = [DateTime]::UtcNow
    return [pscustomobject]@{
        Stdout = ([ordered]@{ type = 'error'; message = $FailureMessage } | ConvertTo-Json -Compress)
        RawStdout = ''
        Stderr = ''
        ExitCode = 1
        TimedOut = $false
        StartedUtc = $StartedUtc
        FinishedUtc = $finished
        DurationSeconds = [Math]::Round(($finished - $StartedUtc).TotalSeconds, 3)
        TransportFailure = $FailureMessage
    }
}

function Invoke-CodexProjectedTransport {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth,
        [Parameter(Mandatory = $true)][object]$Platform,
        [object]$SandboxInfo = $null,
        [Parameter(Mandatory = $true)][bool]$HardFilesystem,
        [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform,
        [Parameter(Mandatory = $true)][string]$LastResponseRelativePath,
        [bool]$SupportsProviderModelFallback = $false
    )

    $projection = New-CodexExecutionProjection -Inputs $Inputs
    $executionInputs = [pscustomobject]@{ Run = $projection.Run; Profile = $Inputs.Profile }
    $process = $null
    $projectedFinalResponse = $null
    $nativeSkillIsolation = $null
    try {
        $physicalLastResponsePath = Join-Path $projection.Root ($LastResponseRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $physicalLastResponsePath) -Force | Out-Null
        $environment = if ($Auth.Kind -eq 'environment') { New-CodexEnvironment -Inputs $executionInputs -Auth $Auth } else { $null }
        $arguments = New-CodexCliArguments -Inputs $executionInputs -LastResponsePath $physicalLastResponsePath -VisiblePlatform $VisiblePlatform
        if ($Auth.Kind -eq 'subscription_file') {
            $process = Invoke-CodexAppServer -CommandInfo $CommandInfo -Inputs $executionInputs -Auth $Auth -SupportsProviderModelFallback $SupportsProviderModelFallback -TimeoutSeconds $Inputs.Profile.TimeoutSeconds -ProgressContext (Get-RunnerModelProgressContext -Runner 'codex' -Phase 'codex-app-server')
            $nativeSkillIsolation = Get-JsonProperty -Object $process -Name 'NativeSkillIsolation' -Default $null
        } elseif ($Platform -eq 'linux' -and $HardFilesystem) {
            $nativeSkillIsolation = (Invoke-CodexNativeSkillConfigProbe -CommandInfo $CommandInfo -Inputs $executionInputs -Environment $environment -Transport 'cli-compatibility').Evidence
            $promptProbe = Invoke-CodexPromptInputNativeSkillProbe -CommandInfo $CommandInfo -Inputs $executionInputs -Environment $environment
            if ($null -ne $nativeSkillIsolation) {
                Set-CodexNativeSkillIsolationProperty -Evidence $nativeSkillIsolation -Name 'prompt_input_verification_method' -Value 'debug prompt-input'
                Set-CodexNativeSkillIsolationProperty -Evidence $nativeSkillIsolation -Name 'prompt_input_catalog_suppressed' -Value ([bool]$promptProbe.Available)
                if (-not [bool]$promptProbe.Available) { Add-CodexNativeSkillIsolationFailure -Evidence $nativeSkillIsolation -Failure 'native_skill_catalog_prompt_input_unverified' }
            }
            if ($null -eq $nativeSkillIsolation -or @($nativeSkillIsolation.failures).Count -gt 0) {
                $process = New-CodexBlockedProcessObservation -StartedUtc ([DateTime]::UtcNow) -FailureMessage 'Codex CLI native skill suppression was not proven before model execution.'
            } else {
            $sandboxArguments = Get-LinuxCodexSandboxArguments -Inputs $executionInputs -CommandInfo $CommandInfo -Environment $environment
            $process = Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $executionInputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds -ProgressContext (Get-RunnerModelProgressContext -Runner 'codex' -Phase 'codex-cli')
            }
        } elseif ($Platform -eq 'macos' -and $HardFilesystem) {
            $nativeSkillIsolation = (Invoke-CodexNativeSkillConfigProbe -CommandInfo $CommandInfo -Inputs $executionInputs -Environment $environment -Transport 'cli-compatibility').Evidence
            $promptProbe = Invoke-CodexPromptInputNativeSkillProbe -CommandInfo $CommandInfo -Inputs $executionInputs -Environment $environment
            if ($null -ne $nativeSkillIsolation) {
                Set-CodexNativeSkillIsolationProperty -Evidence $nativeSkillIsolation -Name 'prompt_input_verification_method' -Value 'debug prompt-input'
                Set-CodexNativeSkillIsolationProperty -Evidence $nativeSkillIsolation -Name 'prompt_input_catalog_suppressed' -Value ([bool]$promptProbe.Available)
                if (-not [bool]$promptProbe.Available) { Add-CodexNativeSkillIsolationFailure -Evidence $nativeSkillIsolation -Failure 'native_skill_catalog_prompt_input_unverified' }
            }
            if ($null -eq $nativeSkillIsolation -or @($nativeSkillIsolation.failures).Count -gt 0) {
                $process = New-CodexBlockedProcessObservation -StartedUtc ([DateTime]::UtcNow) -FailureMessage 'Codex CLI native skill suppression was not proven before model execution.'
            } else {
            $sandboxProfile = New-CodexMacosSandboxProfile -Inputs $executionInputs -CommandInfo $CommandInfo
            $sandboxArguments = @('-f', $sandboxProfile, '--', $CommandInfo.FileName) + @($CommandInfo.Prefix) + @($arguments)
            $process = Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $executionInputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds -ProgressContext (Get-RunnerModelProgressContext -Runner 'codex' -Phase 'codex-cli')
            }
        } else {
            $nativeSkillIsolation = (Invoke-CodexNativeSkillConfigProbe -CommandInfo $CommandInfo -Inputs $executionInputs -Environment $environment -Transport 'cli-compatibility').Evidence
            $promptProbe = Invoke-CodexPromptInputNativeSkillProbe -CommandInfo $CommandInfo -Inputs $executionInputs -Environment $environment
            if ($null -ne $nativeSkillIsolation) {
                Set-CodexNativeSkillIsolationProperty -Evidence $nativeSkillIsolation -Name 'prompt_input_verification_method' -Value 'debug prompt-input'
                Set-CodexNativeSkillIsolationProperty -Evidence $nativeSkillIsolation -Name 'prompt_input_catalog_suppressed' -Value ([bool]$promptProbe.Available)
                if (-not [bool]$promptProbe.Available) { Add-CodexNativeSkillIsolationFailure -Evidence $nativeSkillIsolation -Failure 'native_skill_catalog_prompt_input_unverified' }
            }
            if ($null -eq $nativeSkillIsolation -or @($nativeSkillIsolation.failures).Count -gt 0) {
                $process = New-CodexBlockedProcessObservation -StartedUtc ([DateTime]::UtcNow) -FailureMessage 'Codex CLI native skill suppression was not proven before model execution.'
            } else {
            $process = Invoke-CodexCli -CommandInfo $CommandInfo -Arguments $arguments -Inputs $executionInputs -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
            }
        }
        if (Test-Path -LiteralPath $physicalLastResponsePath -PathType Leaf) {
            $projectedFinalResponse = [System.IO.File]::ReadAllText($physicalLastResponsePath, [System.Text.UTF8Encoding]::new($false))
            $logicalLastResponsePath = Join-Path $Inputs.Run.RunRoot ($LastResponseRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $logicalLastResponsePath) -Force | Out-Null
            [System.IO.File]::WriteAllText($logicalLastResponsePath, $projectedFinalResponse, [System.Text.UTF8Encoding]::new($false))
        }
        return [pscustomobject]@{
            Process = $process
            ProjectedFinalResponse = $projectedFinalResponse
            ExecutionPaths = [ordered]@{
                projection = 'physical_temp_outside_logical_package'
                logical_run_root = [string]$Inputs.Run.RunRoot
                logical_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
                logical_home_directory = [string]$Inputs.Run.HomeDirectoryPath
                physical_run_root = [string]$projection.Root
                physical_working_directory = [string]$projection.PhysicalWorkingDirectory
                physical_home_directory = [string]$projection.PhysicalHomeDirectory
                physical_skill_directory = [string]$projection.PhysicalSkillDirectory
            }
            PhysicalProjectionProven = [bool]$projection.Proven
            NativeSkillIsolation = $nativeSkillIsolation
        }
    } finally {
        try { Sync-CodexProjectedRepository -Projection $projection } finally { Remove-CodexExecutionProjection -Projection $projection }
    }
}

function Invoke-CodexExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-CodexPreflight -Inputs $Inputs
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $executionDescriptor = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $executionDescriptor[$key] = $descriptor[$key] }
    $executionDescriptor.harness = $preflight.harness
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        $failureText = [string]::Join('; ', @($preflight.reasons))
        return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $failureText) -SessionId $sessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight; resume = $false }) -AttemptCount 1
    }

    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $auth = Get-CodexAuthSource
    $lastResponsePath = 'evidence/codex-final.txt'
    New-Item -ItemType Directory -Path (Join-Path $Inputs.Run.RunRoot 'evidence') -Force | Out-Null
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $auth.Kind -eq 'environment' -and $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $protocolObservations = Get-JsonProperty -Object $preflight -Name 'protocol_observations' -Default $null
    $supportsProviderModelFallback = [bool](Get-JsonProperty -Object $protocolObservations -Name 'allow_provider_model_fallback' -Default $false)
    $transport = Invoke-CodexProjectedTransport -CommandInfo $commandInfo -Inputs $Inputs -Auth $auth -Platform $platform -SandboxInfo $sandboxInfo -HardFilesystem $hardFilesystem -VisiblePlatform $visiblePlatform -LastResponseRelativePath $lastResponsePath -SupportsProviderModelFallback $supportsProviderModelFallback
    $process = $transport.Process
    $stdoutArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact)
    $artifacts.Add($stderrArtifact)
    $transcriptArtifactPath = 'evidence/codex-events.jsonl'
    if ($auth.Kind -eq 'subscription_file') {
        $rawStdoutArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-app-server-events.jsonl' -Text $process.RawStdout
        $artifacts.Add($rawStdoutArtifact)
        $transcriptArtifactPath = 'evidence/codex-app-server-events.jsonl'
    }

    $parsed = ConvertFrom-JsonLines -Text $process.Stdout
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("Codex event parse error: $parseError") }
    $finalText = if ($auth.Kind -eq 'subscription_file') { $process.FinalText } else { $transport.ProjectedFinalResponse }
    if ([string]::IsNullOrWhiteSpace($finalText) -and $null -ne $transport.ProjectedFinalResponse) { $finalText = $transport.ProjectedFinalResponse }
    $threadId = if ($auth.Kind -eq 'subscription_file') { $process.ThreadId } else { $null }
    $turnId = if ($auth.Kind -eq 'subscription_file') { $process.TurnId } else { $null }
    $turnFailure = $null
    $usage = $null
    $toolCalls = 0
    $commands = [System.Collections.Generic.List[object]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $behavioralCapabilityFailures = [System.Collections.Generic.List[object]]::new()
    $eventCounts = @{}
    foreach ($event in @($parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $warnings.Add('Codex emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        switch ($eventType) {
            'thread.started' { $threadId = [string](Get-JsonProperty -Object $event -Name 'thread_id' -Default '') }
            'item.completed' {
                $item = Get-JsonProperty -Object $event -Name 'item' -Default $null
                $itemType = [string](Get-JsonProperty -Object $item -Name 'type' -Default '')
                if ($itemType -eq 'agent_message') {
                    $candidate = [string](Get-JsonProperty -Object $item -Name 'text' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $finalText = $candidate }
                } elseif ($itemType -in @('command_execution', 'mcp_tool_call', 'file_change')) {
                    $toolCalls++
                    if ($itemType -eq 'command_execution') {
                        $commands.Add([ordered]@{
                                type = $itemType
                                command = Get-JsonProperty -Object $item -Name 'command'
                                status = Get-JsonProperty -Object $item -Name 'status' -Default $null
                                exit_code = Get-JsonProperty -Object $item -Name 'exit_code'
                            })
                    } else {
                        $files.Add([ordered]@{ type = $itemType; status = Get-JsonProperty -Object $item -Name 'status' -Default $null; item = $item })
                    }
                    $behavioralFailure = Get-CodexBehavioralCapabilityFailure -Item $item
                    if ($null -ne $behavioralFailure) {
                        $behavioralCapabilityFailures.Add($behavioralFailure)
                    }
                }
            }
            'turn.completed' {
                $usage = Get-JsonProperty -Object $event -Name 'usage' -Default $null
            }
            'turn.failed' { $turnFailure = Get-JsonProperty -Object $event -Name 'error' -Default 'Codex turn failed.' }
            'error' { $turnFailure = Get-JsonProperty -Object $event -Name 'message' -Default 'Codex emitted an error.' }
            { $_ -in @('turn.started', 'item.started', 'item.updated') } { }
            default { $warnings.Add("Unknown Codex event '$eventType' was preserved as a warning.") }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -PathType Leaf) {
        $lastArtifact = New-ArtifactReference -Run $Inputs.Run -Path $lastResponsePath -Scope run -MediaType 'text/plain; charset=utf-8'
        $artifacts.Add($lastArtifact)
        if ([string]::IsNullOrWhiteSpace($finalText)) {
            $finalText = [System.IO.File]::ReadAllText((Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)), [System.Text.UTF8Encoding]::new($false))
        }
    }
    $terminalCaptureComplete = if ($auth.Kind -eq 'subscription_file') {
        [bool]$process.TurnCompleted
    } else {
        @($parsed.Events | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'type' -Default '') -eq 'turn.completed' }).Count -gt 0
    }
    $nativeSkillIsolation = Get-JsonProperty -Object $transport -Name 'NativeSkillIsolation' -Default (Get-JsonProperty -Object $process -Name 'NativeSkillIsolation' -Default $null)
    if ($null -ne $nativeSkillIsolation) {
        $nativeSkillRuntimeObservation = Update-CodexNativeSkillRuntimeAccessEvidence -NativeSkillIsolation $nativeSkillIsolation -Commands @($commands) -Files @($files) -AllowedStagedSkillRoot ([string]$transport.ExecutionPaths.physical_skill_directory)
        $nativeSkillIsolation = $nativeSkillRuntimeObservation.Evidence
    }

    $nativeEvidenceFailures = [System.Collections.Generic.List[string]]::new()
    $observedModel = if ($auth.Kind -eq 'subscription_file') { [string]$process.ObservedModel } else { '' }
    $observedWorkingDirectory = if ($auth.Kind -eq 'subscription_file') { [string]$process.ObservedWorkingDirectory } else { '' }
    $promptFidelity = $auth.Kind -eq 'subscription_file' -and [string]$process.PromptInputSha256 -eq [string]$Inputs.Run.PromptHash
    $unexpectedInstructionSources = [System.Collections.Generic.List[string]]::new()
    $invalidInstructionSources = [System.Collections.Generic.List[string]]::new()
    $threadReadObservation = 'not_applicable'
    $instructionSourceProof = if ($auth.Kind -eq 'subscription_file') { 'physical_projection_boundary' } else { 'compatibility_transport' }
    $instructionSourcesUnobserved = $false
    $authHomeProven = $true
    $terminalTurnProven = $true
    $modelRerouteObserved = $false
    $threadReadMetadataFailure = $false
    $ambientCandidateSkillExclusionUnverified = $false
    if ($auth.Kind -eq 'subscription_file') {
        # instructionSources is an optional response observation. A missing
        # array is acceptable here because the physical projection is outside
        # the source-repository ancestor chain and is the independent proof of
        # the ambient instruction boundary. Without that proof, absence stays
        # fail-closed.
        $instructionSourcesUnobserved = -not [bool]$process.InstructionSourcesObserved -and -not [bool]$transport.PhysicalProjectionProven
        foreach ($source in @($process.InstructionSources)) {
            $sourcePath = [string]$source
            if ([string]::IsNullOrWhiteSpace($sourcePath)) {
                $invalidInstructionSources.Add($sourcePath)
            } elseif (-not (Test-PathInside -BasePath ([string]$transport.ExecutionPaths.physical_run_root) -CandidatePath $sourcePath)) {
                $unexpectedInstructionSources.Add($sourcePath)
            }
        }
        $authHomeProven = [bool]$process.AuthOnlyHome -and [bool]$process.AuthOnlyHomeRemoved
        $terminalTurnProven = [string](Get-JsonProperty -Object $process.TerminalTurn -Name 'status' -Default '') -eq 'completed'
        $modelRerouteObserved = @($process.ModelReroutes).Count -gt 0
        $threadReadThread = if ($null -ne $process.ThreadReadResponse) { Get-JsonProperty -Object (Get-JsonProperty -Object $process.ThreadReadResponse -Name 'result' -Default $null) -Name 'thread' -Default $null } else { $null }
        if ($null -ne $threadReadThread) {
            $threadReadObservation = 'observed'
            if ([string](Get-JsonProperty -Object $threadReadThread -Name 'id' -Default '') -ne [string]$process.ThreadId -or
                -not [bool](Get-JsonProperty -Object $threadReadThread -Name 'ephemeral' -Default $false) -or
                -not (Test-ExactObservedPath -Expected ([string]$transport.ExecutionPaths.physical_working_directory) -Observed ([string](Get-JsonProperty -Object $threadReadThread -Name 'cwd' -Default '')))) {
                $threadReadMetadataFailure = $true
            }
        } elseif ($null -ne $process.ThreadReadFailure -or $null -eq $process.ThreadReadResponse) {
            $threadReadObservation = 'unavailable_optional'
            $warnings.Add('Codex thread/read is supplemental and was unavailable; thread/start and turn/completed remain the mandatory terminal proof.')
        } else {
            # A response was returned but did not satisfy the installed
            # ThreadReadResponse shape. The thread/read observation is
            # supplemental, but a present response with a missing required
            # thread object is a protocol violation rather than an optional
            # absence.
            $threadReadObservation = 'malformed'
            $threadReadMetadataFailure = $true
        }
    }

    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'
        $reason = 'codex_timeout'
        $failure = New-ExecutionFailure -Code 'timed_out' -Message 'Codex did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $turnFailure) {
        $status = 'failed'
        $reason = 'codex_failure'
        $failureMessage = if ($null -ne $turnFailure) { [string]$turnFailure } elseif (-not [string]::IsNullOrWhiteSpace($process.Stderr)) { $process.Stderr.Trim() } else { "Codex exited with status $($process.ExitCode)." }
        $failure = New-ExecutionFailure -Code 'codex_failure' -Message $failureMessage
    } elseif ([string]::IsNullOrWhiteSpace($finalText)) {
        $warnings.Add('Codex exited successfully without a final agent message.')
        $reason = 'codex_did_not_return_final_response'
    }
    # Positive evidence that the execution substrate is usable.
    $successfulWorkspaceOps = @($commands | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'completed' }).Count +
                              @($files   | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'completed' }).Count
    # Detect Codex runtime STDERR policy rejections (iteration-12 shape). The
    # app-server turn may complete while the runtime tool-router rejects every
    # execution attempt before it reaches the protocol layer, emitting no
    # structured commandExecution items. Classify as an operational-permission
    # incompatibility only when no successful workspace operation was observed;
    # an outside-workspace isolation denial in an otherwise working environment
    # must not be misclassified.
    $stderrPolicyRejections = @(Get-CodexStderrPolicyRejections -StderrText $process.Stderr)
    $stderrIndicatesOperationalPermissionFailure = $stderrPolicyRejections.Count -gt 0 -and $successfulWorkspaceOps -eq 0
    $behavioralCapabilityFailureNames = [System.Collections.Generic.List[string]]::new()
    if (($behavioralCapabilityFailures.Count -gt 0 -or $stderrIndicatesOperationalPermissionFailure) -and -not $process.TimedOut) {
        $status = 'incompatible'
        $reason = 'codex_operational_permission_incompatible'
        $failure = if ($behavioralCapabilityFailures.Count -gt 0) {
            New-ExecutionFailure -Code 'harness_operational_permission_incompatible' -Message ("Codex structured tool results show ordinary engineering operations were rejected even though unrestricted operational permission was requested: {0}." -f ([string]::Join(', ', @($behavioralCapabilityFailures | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'code' -Default 'workspace_operation_blocked_by_policy') } | Select-Object -Unique))))
        } else {
            New-ExecutionFailure -Code 'harness_operational_permission_incompatible' -Message ("Codex runtime indicates ordinary engineering operations were rejected even though unrestricted operational permission was requested: {0} rejection(s) observed." -f $stderrPolicyRejections.Count)
        }
        $exitStatus = $null
        $behavioralCapabilityFailureNames.Add('workspace_operation_blocked_by_policy')
    }
    $tokenMetric = if ($null -eq $usage) {
        New-UnavailableMetric -Reason 'codex_did_not_expose_turn_usage'
    } else {
        $usageValue = [ordered]@{}
        foreach ($name in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
            $value = Get-JsonProperty -Object $usage -Name $name -Default $null
            if ($null -ne $value) { $usageValue[$name] = $value }
        }
        if ($usageValue.Count -eq 0) { New-UnavailableMetric -Reason 'codex_usage_event_had_no_supported_buckets' } else { New-AvailableMetric -Value $usageValue }
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = $transcriptArtifactPath; complete = $terminalCaptureComplete })
        tokens = $tokenMetric
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = New-UnavailableMetric -Reason 'codex_runner_does_not_estimate_cost'
    }
    $finished = [DateTime]::UtcNow
    $sessionResultId = if ([string]::IsNullOrWhiteSpace($threadId)) { $sessionId } else { $threadId }
    $capabilities = Get-CodexCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem -NativeWorkerAvailable ($auth.Kind -eq 'subscription_file') -AuthKind $auth.Kind
    if ($behavioralCapabilityFailureNames.Count -gt 0) {
        $capabilities['delegated_worker_full_capability'] = 'unsupported'
    }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    if ($auth.Kind -eq 'subscription_file') {
        foreach ($mechanism in @('native app-server initialize + config/read + skills/list + thread/start + turn/start', 'session skills.include_instructions=false', 'session skills.config candidate disable', 'pre-turn skills/list candidate-state verification', 'runtime ambient skill access validation', 'temporary auth-only subscription CODEX_HOME', 'ephemeral thread', 'thread/read after turn completion', 'instructionSources validation', 'model/rerouted fail-closed', 'approvalPolicy=never', 'sandboxPolicy=dangerFullAccess', 'shell_environment_policy.inherit=none', 'filtered parent process environment', 'prompt in turn/start input')) { $mechanisms.Add($mechanism) }
        $continuationMechanism = if ($null -ne $Inputs.Run.Interaction) { 'same-thread repeated turn/start for scripted interaction' } else { 'no session continuation' }
        $mechanisms.Add($continuationMechanism)
    } else {
        foreach ($mechanism in @('--ask-for-approval never', 'codex exec --ephemeral', '--strict-config', '--ignore-user-config', '--ignore-rules', '--sandbox danger-full-access', 'shell_environment_policy.inherit=none', 'session skills.include_instructions=false', 'session skills.config candidate disable', 'pre-turn debug prompt-input native-skill suppression proof', 'pre-turn skills/list candidate-state verification', 'runtime ambient skill access validation', 'isolated CODEX_HOME', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    }
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    if (-not $hardFilesystem) { $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $sandboxEvidence = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
    $credentialEvidence = [ordered]@{
        source = $auth.Kind
        provider_environment_variable = $auth.Name
        unrelated_environment_excluded = $true
        child_tool_visibility = 'codex_shell_environment_policy_inherit_none'
        value_observed = $false
        auth_only_home = if ($auth.Kind -eq 'subscription_file') { [bool]$process.AuthOnlyHome } else { $false }
        auth_only_home_removed = if ($auth.Kind -eq 'subscription_file') { [bool]$process.AuthOnlyHomeRemoved } else { $true }
        ambient_codex_configuration_copied = $false
    }
    $outputLastMessageArgument = if ($auth.Kind -eq 'subscription_file') { $null } else { Get-SandboxVisiblePath -HostPath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -RunRoot $Inputs.Run.RunRoot -Platform $visiblePlatform }
    $evidence = [ordered]@{
        thread_id = $threadId
        thread_session_id = if ($auth.Kind -eq 'subscription_file') { $process.ThreadSessionId } else { $null }
        turn_id = $turnId
        execution_paths = $transport.ExecutionPaths
        event_counts = $eventCounts
        commands = @($commands)
        files = @($files)
        prompt_first_input = if ($auth.Kind -eq 'subscription_file') { $promptFidelity } else { $true }
        resume = $false
        stdout_exit_code = $process.ExitCode
        sandbox = $sandboxEvidence
        output_last_message_argument = $outputLastMessageArgument
        credential = $credentialEvidence
    }
    if ($null -ne $nativeSkillIsolation) {
        $evidence.native_skill_isolation = $nativeSkillIsolation
    }
    $evidence.behavioral_capability = [ordered]@{
        requested_operational_permission = 'full'
        requested_codex_sandbox          = if ($auth.Kind -eq 'subscription_file') { 'dangerFullAccess' } else { 'danger-full-access' }
        requested_policy_source          = if ($auth.Kind -eq 'subscription_file') { 'turn/start.sandboxPolicy' } else { 'codex exec --sandbox danger-full-access' }
        status                           = if ($behavioralCapabilityFailures.Count -gt 0 -or $stderrIndicatesOperationalPermissionFailure) { 'rejected_by_effective_runtime_policy' } else { 'no_structured_policy_rejection_observed' }
        authoritative_signal             = if ($behavioralCapabilityFailures.Count -gt 0) { 'structured item.completed tool result' } elseif ($stderrIndicatesOperationalPermissionFailure) { 'codex_runtime_stderr' } else { 'structured item.completed tool result' }
        failures                         = @(@($behavioralCapabilityFailures.ToArray()) + @(if ($stderrIndicatesOperationalPermissionFailure) { $stderrPolicyRejections } else { @() }))
    }
    if ($behavioralCapabilityFailureNames.Count -gt 0) {
        $evidence.native_worker_evidence_failures = @($behavioralCapabilityFailureNames.ToArray())
    }
    if ($null -ne $Inputs.Run.Interaction) { $evidence.turns = @($process.TurnRecords) }
    if ($auth.Kind -eq 'subscription_file') {
        $rawArtifact = @($artifacts | Where-Object { [string]$_.path -eq $transcriptArtifactPath } | Select-Object -First 1)
        $evidence.capture = [ordered]@{
            source = 'harness_native_transport'
            terminal = [bool]$process.TurnCompleted
            worker_authored = $false
            artifact = $transcriptArtifactPath
            sha256 = if ($rawArtifact.Count -eq 1) { [string]$rawArtifact[0].sha256 } else { $null }
        }
        $evidence.delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = [string]$descriptor.delegation.mechanism
            worker_session_id = $sessionResultId
            observed_model = $observedModel
            observed_working_directory = $observedWorkingDirectory
            observed_home = [string]$process.WorkerHome
            fresh_worker = [bool]$process.ObservedEphemeral -and -not [string]::IsNullOrWhiteSpace([string]$process.ThreadId)
            home_config_isolated = [bool]$process.AuthOnlyHome -and [bool]$process.AuthOnlyHomeRemoved
            prompt_fidelity = $promptFidelity
            prompt_sha256 = $Inputs.Run.PromptHash
            terminal_result_capture = [bool]$process.TurnCompleted -and -not [string]::IsNullOrWhiteSpace([string]$process.RawStdout)
            paired_arm_visible = $false
            grading_material_visible = $false
            nested_model_execution = $false
            model_execution_count = 1
            thread_id = $threadId
            thread_session_id = $process.ThreadSessionId
            turn_id = $turnId
            instruction_sources_observed = [bool]$process.InstructionSourcesObserved
            instruction_source_proof = $instructionSourceProof
            instruction_sources = @($process.InstructionSources)
            invalid_instruction_sources = @($invalidInstructionSources.ToArray())
            unexpected_instruction_sources = @($unexpectedInstructionSources.ToArray())
            requested_runtime_workspace_roots = @($transport.ExecutionPaths.physical_working_directory)
            logical_runtime_workspace_roots = @($Inputs.Run.WorkingDirectoryPath)
            thread_read_observed = $null -ne $process.ThreadReadResponse
            thread_read_observation = $threadReadObservation
            model_reroutes = @($process.ModelReroutes)
            same_session_continuation = if ($null -ne $Inputs.Run.Interaction) { [bool]$process.AllTurnsCompleted } else { $null }
        }
        if ($null -ne $Inputs.Run.Interaction) {
            $evidence.interaction = [ordered]@{
                schema = (Get-RunnerSchemaNames).Interaction
                mode = 'scripted'
                same_session = [bool]$process.AllTurnsCompleted
                session_id = $sessionResultId
                turns = @($process.TurnRecords)
                final_response_sequence = @($process.TurnRecords).Count
                turn_start_requests = @($process.TurnStartRequests)
                turn_start_responses = @($process.TurnStartResponses)
            }
        }
        $threadStartResultEvidence = Get-JsonProperty -Object $process.ThreadStartResponse -Name 'result' -Default ([ordered]@{})
        $threadReadThreadEvidence = if ($null -ne $process.ThreadReadResponse) { Get-JsonProperty -Object (Get-JsonProperty -Object $process.ThreadReadResponse -Name 'result' -Default $null) -Name 'thread' -Default $null } else { $null }
        $turnCompletionEvidence = if ($null -ne $process.TerminalTurn) { [ordered]@{ thread_id = $process.ThreadId; turn_id = $process.TurnId; status = Get-JsonProperty -Object $process.TerminalTurn -Name 'status' -Default $null } } else { $null }
        $evidence.app_server = [ordered]@{
            config_read_request = $process.ConfigReadRequest
            config_read_response = $process.ConfigReadResponse
            skills_list_request = $process.SkillsListRequest
            skills_list_response = $process.SkillsListResponse
            thread_start_request = $process.ThreadStartRequest
            thread_start_response = $process.ThreadStartResponse
            turn_start_request = $process.TurnStartRequest
            turn_start_response = $process.TurnStartResponse
            thread_start = [ordered]@{
                requested_model = $Inputs.Profile.Model
                requested_cwd = $transport.ExecutionPaths.physical_working_directory
                requested_ephemeral = $true
                requested_sandbox = 'read-only'
                requested_allow_provider_model_fallback = if ($supportsProviderModelFallback) { $false } else { $null }
                observed_model = Get-JsonProperty -Object $threadStartResultEvidence -Name 'model' -Default $null
                observed_cwd = Get-JsonProperty -Object $threadStartResultEvidence -Name 'cwd' -Default $null
                observed_ephemeral = Get-JsonProperty -Object (Get-JsonProperty -Object $threadStartResultEvidence -Name 'thread' -Default $null) -Name 'ephemeral' -Default $null
                observed_sandbox = Get-JsonProperty -Object $threadStartResultEvidence -Name 'sandbox' -Default $null
                instruction_sources = @($process.InstructionSources)
            }
            turn_start = [ordered]@{
                thread_id = $process.ThreadId
                requested_model = $Inputs.Profile.Model
                requested_cwd = $transport.ExecutionPaths.physical_working_directory
                requested_effort = $Inputs.Profile.ReasoningEffort
                requested_sandbox_policy = Get-JsonProperty -Object (Get-JsonProperty -Object $process.TurnStartRequest -Name 'params' -Default $null) -Name 'sandboxPolicy' -Default $null
                prompt_sha256 = $process.PromptInputSha256
            }
            turn_starts = @($process.TurnStartRequests | ForEach-Object {
                [ordered]@{
                    thread_id = Get-JsonProperty -Object $_.params -Name 'threadId' -Default $null
                    requested_model = Get-JsonProperty -Object $_.params -Name 'model' -Default $null
                    requested_cwd = Get-JsonProperty -Object $_.params -Name 'cwd' -Default $null
                    prompt_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$_.params.input[0].text))
                }
            })
            terminal_turn = $turnCompletionEvidence
            thread_read = [ordered]@{
                request = [ordered]@{ threadId = $process.ThreadId; includeTurns = $true }
                response = if ($null -eq $threadReadThreadEvidence) { $null } else { [ordered]@{ id = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'id' -Default $null; session_id = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'sessionId' -Default $null; cwd = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'cwd' -Default $null; ephemeral = Get-JsonProperty -Object $threadReadThreadEvidence -Name 'ephemeral' -Default $null } }
                failure = $process.ThreadReadFailure
                observation = $threadReadObservation
            }
            model_rerouted = @($process.ModelReroutes)
        }
    }

    $nativeSkillIsolationFailures = @(if ($null -eq $nativeSkillIsolation) { 'native_skill_isolation_unverified' } else { Get-JsonProperty -Object $nativeSkillIsolation -Name 'failures' -Default @() })
    if (@($nativeSkillIsolationFailures).Count -gt 0) {
        $ambientCandidateSkillExclusionUnverified = $true
        foreach ($failureName in @($nativeSkillIsolationFailures)) {
            if ($nativeEvidenceFailures -notcontains [string]$failureName) { $nativeEvidenceFailures.Add([string]$failureName) }
        }
    }

    if ($auth.Kind -eq 'subscription_file') {
        # Run the common portable validator over the same evidence object that
        # the Codex-specific checks use. This is the single terminal decision:
        # additional Codex failures are merged with, never hidden from, the
        # portable result and orchestration state.
        $commonPreview = [ordered]@{
            status = $status
            session = [ordered]@{ id = $sessionResultId; fresh = [bool]$process.ObservedEphemeral -and -not [string]::IsNullOrWhiteSpace([string]$process.ThreadId); resumed = $false }
            run = [ordered]@{ eval_id = $Inputs.Run.EvalId; eval_name = $Inputs.Run.EvalName; configuration = $Inputs.Run.Mode }
            requested = [ordered]@{ model = $Inputs.Profile.Model }
            runner = [ordered]@{ name = 'codex' }
            evidence = $evidence
        }
        $commonValidation = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $commonPreview -Run $Inputs.Run -RequestedModel ([string]$Inputs.Profile.Model) -ExpectedWorkerSessionId $sessionResultId -ExpectedRunner 'codex' -ExpectedMechanism ([string]$descriptor.delegation.mechanism)
        foreach ($failureName in @($commonValidation.Failures)) {
            if ($nativeEvidenceFailures -notcontains [string]$failureName) { $nativeEvidenceFailures.Add([string]$failureName) }
        }
        # These checks are genuinely Codex-specific. The portable validator
        # above owns model/cwd/home/freshness/prompt/terminal acceptance; this
        # layer contributes only app-server protocol and transport invariants.
        if ($instructionSourcesUnobserved) { $nativeEvidenceFailures.Add('instruction_sources_unobserved'); $ambientCandidateSkillExclusionUnverified = $true }
        if ($invalidInstructionSources.Count -gt 0) { $nativeEvidenceFailures.Add('invalid_instruction_sources'); $ambientCandidateSkillExclusionUnverified = $true }
        if ($unexpectedInstructionSources.Count -gt 0) { $nativeEvidenceFailures.Add('unexpected_instruction_sources'); $ambientCandidateSkillExclusionUnverified = $true }
        if (-not $authHomeProven) { $nativeEvidenceFailures.Add('isolated_auth_home'); $ambientCandidateSkillExclusionUnverified = $true }
        if (-not $terminalTurnProven) { $nativeEvidenceFailures.Add('terminal_turn_status') }
        if ($modelRerouteObserved) { $nativeEvidenceFailures.Add('model_rerouted') }
        if ($threadReadMetadataFailure) { $nativeEvidenceFailures.Add('thread_read_metadata') }
        if ($ambientCandidateSkillExclusionUnverified) { $nativeEvidenceFailures.Add('ambient_candidate_skill_exclusion_unverified') }
        $uniqueNativeEvidenceFailures = @($nativeEvidenceFailures | Select-Object -Unique)
        $nativeEvidenceFailures = [System.Collections.Generic.List[string]]::new()
        foreach ($failureName in $uniqueNativeEvidenceFailures) { $nativeEvidenceFailures.Add([string]$failureName) }
        if ($nativeEvidenceFailures.Count -gt 0) {
            $status = 'incompatible'
            $isBehavioralCapabilityFailure = $behavioralCapabilityFailureNames.Count -gt 0
            $reason = if ($isBehavioralCapabilityFailure) { 'codex_operational_permission_incompatible' } else { 'codex_native_evidence_incompatible' }
            $baseFailureMessage = if ($null -ne $failure) { [string]$failure.message } elseif (-not [string]::IsNullOrWhiteSpace([string]$process.TransportFailure)) { [string]$process.TransportFailure } else { 'Codex app-server terminal evidence was not accepted.' }
            $nativeSkillFailureCode = @($nativeSkillIsolationFailures | Where-Object { $_ -ne 'ambient_candidate_skill_exclusion_unverified' } | Select-Object -First 1)
            $failureCode = if ($isBehavioralCapabilityFailure) { 'harness_operational_permission_incompatible' } elseif ($nativeSkillFailureCode.Count -eq 1) { [string]$nativeSkillFailureCode[0] } else { 'native_evidence_incompatible' }
            $failure = New-ExecutionFailure -Code $failureCode -Message ("Codex app-server evidence failed closed: {0}. Transport detail: {1}" -f ([string]::Join(', ', @($nativeEvidenceFailures)), $baseFailureMessage))
            $exitStatus = $null
        }
        $evidence.native_worker_evidence_failures = @($nativeEvidenceFailures.ToArray())
    }
    if ($auth.Kind -ne 'subscription_file' -and $nativeEvidenceFailures.Count -gt 0) {
        $uniqueNativeEvidenceFailures = @($nativeEvidenceFailures | Select-Object -Unique)
        $status = 'incompatible'
        $reason = 'codex_native_skill_isolation_incompatible'
        $failureCode = [string](@($uniqueNativeEvidenceFailures | Select-Object -First 1)[0])
        if ([string]::IsNullOrWhiteSpace($failureCode)) { $failureCode = 'ambient_candidate_skill_exclusion_unverified' }
        $failure = New-ExecutionFailure -Code $failureCode -Message ("Codex CLI native skill isolation failed closed: {0}." -f ([string]::Join(', ', @($uniqueNativeEvidenceFailures))))
        $exitStatus = $null
        $evidence.native_worker_evidence_failures = @($uniqueNativeEvidenceFailures)
    }
    if ($ambientCandidateSkillExclusionUnverified) {
        $capabilities['ambient_candidate_skill_exclusion'] = 'unsupported'
    }
    return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionResultId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'Codex accepted the requested model and configuration but did not expose concrete backend resolution.'; observations = [ordered]@{ model = $Inputs.Profile.Model; reasoning_effort = $Inputs.Profile.ReasoningEffort } }) -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence $evidence -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-CodexDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-CodexInputs
            Write-RunnerJson -Value (Get-CodexPreflight -Inputs $inputs) -AsOutput
        }
        'execute' {
            $inputs = Resolve-CodexInputs
            [void](Assert-PhaseOneEvidenceWritable -Run $inputs.Run)
            $result = Invoke-CodexExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
