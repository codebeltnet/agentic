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
        # fresh OpenCode session per eval execution and captures the session's own
        # structured event evidence. OpenCode's native Task/General subagent
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
        mechanism = 'Runner-owned OpenCode session (opencode run --format json): the runner starts one fresh process, captures its exact session identity, and uses only an installed-help-proven explicit session continuation for scripted turns'
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
        [Parameter(Mandatory = $true)][object]$Inputs
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    return Invoke-OpenCodeCli -CommandInfo $CommandInfo -Arguments @('run', '--help') -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
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
        $match = [regex]::Match($line, "(?<![A-Za-z0-9_-])$flagPattern(?<assignment>=|\s+)(?<parameter><[^>\r\n]+>|\[[^\]\r\n]+\]|\{[^\}\r\n]+\})", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }
        $contextStart = [Math]::Max(0, $lineIndex - 1)
        $contextEnd = [Math]::Min($lines.Count - 1, $lineIndex + 2)
        $contextLines = [System.Collections.Generic.List[string]]::new()
        foreach ($contextLine in @($lines[$contextStart..$contextEnd])) {
            if ($contextLine -match '(?<![A-Za-z0-9_-])--[A-Za-z0-9][A-Za-z0-9-]*' -and $contextLine -notmatch $flagPattern) { continue }
            $contextLines.Add([string]$contextLine)
        }
        $context = [string]::Join(' ', @($contextLines.ToArray()))
        $contextWithoutFlag = $context -replace $flagPattern, ''
        $implicitContinuation = $contextWithoutFlag -match '(?i)(?:last|most\s+recent|latest|current)\s+session|(?:continue|resume).{0,40}(?:last|most\s+recent|latest)'
        $freshSessionDescription = $contextWithoutFlag -match '(?i)(?:new|fresh|start|create|set).{0,40}session'
        if ($implicitContinuation -or $freshSessionDescription) { continue }
        $continuationDescription = $contextWithoutFlag -match '(?i)(continue|resume|previous|existing|specific|target|select)'
        $identityDescription = $contextWithoutFlag -match '(?i)(session\s*(?:id|identifier)|by\s+(?:id|identifier)|exact\s+(?:session|id)|identifier)'
        $parameterIdentifiesSession = $match.Groups['parameter'].Value -match '(?i)(?:session[-_ ]?)?id|identifier'
        $explicitIdentityDescription = $continuationDescription -and ($identityDescription -or $parameterIdentifiesSession)
        if (-not $explicitIdentityDescription) { continue }
        return [pscustomobject]@{
            Available = $true
            Flag = $flag
            ArgumentStyle = if ($match.Groups['assignment'].Value -eq '=') { 'equals' } else { 'separate' }
            Parameter = $match.Groups['parameter'].Value
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

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $platform = Get-PlatformName
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $versionObservation = $null
    $continuationCapability = [pscustomobject]@{
        Available = $false
        Flag = $null
        ArgumentStyle = $null
        Parameter = $null
        HelpEvidence = $null
        Reason = 'OpenCode exact-session continuation was not probed because the installed run help surface was unavailable.'
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
            $reasons.Add('scripted_multi_turn_same_session is incompatible: the OpenCode executable is unavailable and no model-free continuation probe can run.')
        }
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment (New-RunnerEnvironment -Run $run) -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The OpenCode CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'opencode --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }
            $help = Get-OpenCodeHelpResult -CommandInfo $commandInfo -Inputs $Inputs
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $helpFailureReason = "OpenCode run --help failed with exit status $($help.ExitCode); exact-session continuation cannot be proven."
                $reasons.Add($helpFailureReason)
                if ($null -ne $run.Interaction) {
                    $continuationCapability.Reason = $helpFailureReason
                    $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $helpFailureReason))
                }
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
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'OpenCode run advertises noninteractive, model, directory, and structured-output controls; the adapter intentionally does not use --pure.'))
                }
                if ($null -ne $run.Interaction) {
                    $continuationCapability = Get-OpenCodeContinuationCapability -HelpText $helpText
                    if ($continuationCapability.Available) {
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status passed -Detail ("OpenCode run help proves explicit exact-session continuation through {0} {1}; resumed invocations retain --format json, --model, --dir, and the isolated environment." -f $continuationCapability.Flag, $continuationCapability.Parameter)))
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
        'The adapter starts turn 1 in a fresh OpenCode process without continuation, waits for its terminal structured response, then targets only the exact captured session id for later turns.'
    }
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail $freshSessionDetail))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter isolates global/user configuration roots and deliberately preserves repository-owned project configuration; OPENCODE_DISABLE_PROJECT_CONFIG is not used.'))
    $promptFidelityDetail = if ($null -eq $run.Interaction) {
        'The exact prompt bytes are sent on stdin as the first and only task input.'
    } else {
        'Each scripted user turn is sent as UTF-8 bytes on stdin; execution must prove every requested turn was delivered in order.'
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
    foreach ($mechanism in @('runner-owned fresh OpenCode session per eval execution', 'opencode run --format json terminal event capture', 'native Task/General subagent available as a separate harness capability, not the transport', 'deterministic runner-owned concurrent fan-out', '--auto', 'isolated OPENCODE_CONFIG_DIR', 'isolated OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'repository-owned project configuration preserved', 'prompt on stdin')) { $mechanisms.Add($mechanism) }
    if ($null -ne $run.Interaction -and $continuationCapability.Available) {
        $mechanisms.Add(("explicit OpenCode {0} <session-id> continuation selected from installed help" -f $continuationCapability.Flag))
        $mechanisms.Add('no implicit last-session continuation')
    } else {
        $mechanisms.Add('no session continuation')
    }
    if ($hardConfinement) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    $document = New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
    $document.protocol_observations = [ordered]@{
        scripted_multi_turn_same_session = [ordered]@{
            available = [bool]$continuationCapability.Available
            flag = $continuationCapability.Flag
            argument_style = $continuationCapability.ArgumentStyle
            parameter = $continuationCapability.Parameter
            help_evidence = $continuationCapability.HelpEvidence
            reason = $continuationCapability.Reason
            structured_output = 'opencode run --format json'
            session_identity_source = 'runtime structured event stream'
            exact_session_required = $true
            implicit_continuation = $false
        }
    }
    return $document
}

function New-OpenCodeEnvironment {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $configDirectory = Join-Path $Inputs.Run.HomeDirectoryPath 'opencode-config'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $configPath = Join-Path $configDirectory 'opencode.json'
    [System.IO.File]::WriteAllText($configPath, '{}', [System.Text.UTF8Encoding]::new($false))
    $modelProvider = Get-OpenCodeModelProvider -Model ([string]$Inputs.Profile.Model)
    $authVariables = @(if (-not [string]::IsNullOrWhiteSpace($modelProvider)) { Get-ProviderAuthenticationVariables -Provider $modelProvider })
    return New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables $authVariables -Additional @{
        OPENCODE_CONFIG_DIR = $configDirectory
        OPENCODE_CONFIG = $configPath
        OPENCODE_DISABLE_AUTOUPDATE = '1'
    }
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
        OPENCODE_CONFIG_DIR = '/run/home/opencode-config'
        OPENCODE_CONFIG = '/run/home/opencode-config/opencode.json'
        OPENCODE_DISABLE_AUTOUPDATE = [string]$Environment['OPENCODE_DISABLE_AUTOUPDATE']
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
        EventCounts = $eventCounts
        UsageBuckets = $usageBuckets
        ToolCalls = $toolCalls
        FailureMessage = $failureMessage
        TerminalEventObserved = $terminalEventObserved
        StructuredEventCount = @($Parsed.Events).Count
        ParseErrorCount = @($Parsed.Errors).Count
    }
}

function Invoke-OpenCodeScriptedExecute {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Preflight,
        [Parameter(Mandatory = $true)][object]$ExecutionDescriptor
    )

    $started = [DateTime]::UtcNow
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $environment = New-OpenCodeEnvironment -Inputs $Inputs
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

    $requestedTurns = @($Inputs.Run.Interaction.turns)
    $baseArguments = New-OpenCodeCliArguments -Inputs $Inputs -VisiblePlatform $visiblePlatform
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

        try {
            $turnInputBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($turnText)
            $process = Invoke-OpenCodeTurnProcess -Inputs $Inputs -CommandInfo $commandInfo -Arguments $arguments -Environment $environment -Platform $platform -SandboxInfo $sandboxInfo -InputBytes $turnInputBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
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
            working_directory = [string]$Inputs.Run.WorkingDirectoryPath
            home = [string]$Inputs.Run.HomeDirectoryPath
            config_directory = [string]$environment['OPENCODE_CONFIG_DIR']
            config_file = [string]$environment['OPENCODE_CONFIG']
            started_utc = Format-UtcTimestamp -Value $process.StartedUtc
            finished_utc = Format-UtcTimestamp -Value $process.FinishedUtc
            event_timestamps = @($parsedEvents.EventTimestamps)
            exit_code = $process.ExitCode
            terminal = -not $process.TimedOut -and $process.ExitCode -eq 0
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
    $executionPaths = [ordered]@{
        logical_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
        logical_home_directory = [string]$Inputs.Run.HomeDirectoryPath
        physical_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
        physical_home_directory = [string]$Inputs.Run.HomeDirectoryPath
        physical_run_root = [string]$Inputs.Run.RunRoot
    }
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
        working_directory = [string]$Inputs.Run.WorkingDirectoryPath
        isolated_home = [string]$Inputs.Run.HomeDirectoryPath
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
            observed_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
            observed_home = [string]$Inputs.Run.HomeDirectoryPath
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
    foreach ($mechanism in @('runner-owned fresh OpenCode process for turn 1', 'opencode run --format json structured event capture', 'prompt on stdin', '--model on every turn', '--dir on every turn', 'isolated OPENCODE_CONFIG_DIR and OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'same isolated environment on every turn', 'repository-owned project configuration preserved', 'no implicit last-session continuation')) { $mechanisms.Add($mechanism) }
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
}

function Invoke-OpenCodeExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-OpenCodePreflight -Inputs $Inputs
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $executionDescriptor = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $executionDescriptor[$key] = $descriptor[$key] }
    $executionDescriptor.harness = $preflight.harness
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message ([string]::Join('; ', @($preflight.reasons)))) -SessionId $sessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight; resume = $false }) -AttemptCount 1
    }

    if ($null -ne $Inputs.Run.Interaction) {
        return Invoke-OpenCodeScriptedExecute -Inputs $Inputs -Preflight $preflight -ExecutionDescriptor $executionDescriptor
    }

    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $environment = New-OpenCodeEnvironment -Inputs $Inputs
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $model = [string]$Inputs.Profile.Model
    $arguments = New-OpenCodeCliArguments -Inputs $Inputs -VisiblePlatform $visiblePlatform

    if ($platform -eq 'linux' -and $hardFilesystem) {
        $sandboxArguments = Get-LinuxSandboxArguments -Inputs $Inputs -CommandInfo $commandInfo -Environment $environment
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } elseif ($platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosSandboxProfile -Inputs $Inputs -CommandInfo $commandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $commandInfo.FileName) + @($commandInfo.Prefix) + $arguments
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } else {
        $process = Invoke-OpenCodeCli -CommandInfo $commandInfo -Arguments $arguments -Inputs $Inputs -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    }

    $stdoutArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-OpenCodeCapture -RunData $Inputs -RelativePath 'evidence/opencode-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact); $artifacts.Add($stderrArtifact)
    $parsed = ConvertFrom-JsonLines -Text $process.Stdout
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("OpenCode event parse error: $parseError") }
    $finalTextParts = [System.Collections.Generic.List[string]]::new()
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
    $evidence = [ordered]@{
        event_counts = $eventCounts
        commands = @($commands)
        prompt_first_input = $true
        resume = $false
        model_argument = $model
        sandbox = $sandboxEvidence
        project_configuration = 'repository_owned_project_config_preserved'
        disable_project_config_environment = $false
        credential = $credentialEvidence
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
            observed_working_directory = [string]$Inputs.Run.WorkingDirectoryPath
            observed_home = [string]$Inputs.Run.HomeDirectoryPath
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
    return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $process.FinishedUtc.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'OpenCode accepted the requested runner-native model selector and configuration but did not expose concrete backend resolution.'; observations = [ordered]@{ model = $Inputs.Profile.Model; reasoning_effort = $Inputs.Profile.ReasoningEffort } }) -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence $evidence -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-OpenCodeDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-OpenCodeInputs
            Write-RunnerJson -Value (Get-OpenCodePreflight -Inputs $inputs) -AsOutput
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
