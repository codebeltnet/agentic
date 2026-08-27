<#!
.SYNOPSIS
    GitHub Copilot CLI Eval Runner adapter.

.DESCRIPTION
    This is the only place where GitHub Copilot CLI flags, COPILOT_HOME
    handling, non-interactive JSONL event parsing, Copilot authentication,
    and Copilot isolation limitations are defined. It implements the unchanged
    describe/preflight/execute process contract shared by every runner.

    Copilot with claude-haiku-4.5 is the Codebelt reference evaluation
    configuration. The reference is a repository convention for economical,
    stable comparison; it is not an Anthropic default. The model stays fully
    configurable through execution-profile.json, so any Copilot-served model can
    be selected.
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

# GitHub Copilot checks these token variables before its OS credential store and
# GitHub CLI fallback. The values are forwarded only to the Copilot process;
# --secret-env-vars removes them from shell and MCP child environments.
$copilotAuthVariables = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')

$descriptor = [ordered]@{
    schema = (Get-RunnerSchemaNames).Descriptor
    protocol_version = (Get-RunnerSchemaNames).Protocol
    name = 'github-copilot'
    version = '0.9.1'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'GitHub Copilot CLI'; version = 'unavailable' }
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
        tool_call_telemetry = 'conditional'
        command_evidence = 'conditional'
        file_evidence = 'conditional'
        cost_telemetry = 'unsupported'
        credential_child_filtering = 'supported'
        native_skill_activation_evidence = 'unsupported'
        # Behavioral evaluation transport is runner-owned: the runner starts one
        # fresh Copilot CLI session per eval execution and captures the session's
        # own terminal evidence. Copilot's native task/general-purpose subagent
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
        mechanism = 'Runner-owned GitHub Copilot CLI session (copilot --output-format json): the runner starts one fresh process, captures its exact session identity, and uses only an installed-help-proven explicit session continuation for scripted turns'
        worker_role = 'primary-session'
        full_capability = 'conditional'
        model_lock = 'conditional'
        working_directory = 'conditional'
        result_capture = 'conditional'
        capacity = 'harness_authoritative'
        nested_model_execution = $false
    }
    supported_telemetry = @('transcript_event_capture', 'token_telemetry', 'cache_token_telemetry', 'tool_call_telemetry', 'command_evidence', 'file_evidence')
    configuration_profiles = @('isolated-default')
    tool_profiles = @('default')
}

function Write-ProtocolError {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 2
}

function Resolve-CopilotInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    return [pscustomobject]@{
        Run = Resolve-RunContract -RunPath $Run
        Profile = Resolve-ExecutionProfile -ProfilePath $Profile
    }
}

function Get-CopilotTokenVariable {
    foreach ($name in $copilotAuthVariables) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return $name
        }
    }
    return $null
}

function Get-CopilotGhConfigDirectory {
    # GH_CONFIG_DIR is an authentication-state exception to the isolated
    # Copilot configuration roots. Resolve it from GitHub CLI's documented
    # precedence without reading or logging any credential file.
    $configured = [Environment]::GetEnvironmentVariable('GH_CONFIG_DIR')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $xdgConfig = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
        if (-not [string]::IsNullOrWhiteSpace($xdgConfig)) {
            $configured = Join-Path $xdgConfig 'gh'
        } elseif ((Get-PlatformName) -eq 'windows') {
            $applicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
            if (-not [string]::IsNullOrWhiteSpace($applicationData)) {
                $configured = Join-Path $applicationData 'GitHub CLI'
            }
        } else {
            $userHome = [Environment]::GetEnvironmentVariable('HOME')
            if ([string]::IsNullOrWhiteSpace($userHome)) {
                $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
            }
            if (-not [string]::IsNullOrWhiteSpace($userHome)) {
                $configured = Join-Path (Join-Path $userHome '.config') 'gh'
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($configured) -or -not (Test-Path -LiteralPath $configured -PathType Container)) {
        return $null
    }
    return [System.IO.Path]::GetFullPath($configured)
}

function Get-CopilotGitHubCliToken {
    $gh = Resolve-ExternalCommand -Name 'gh'
    if ($null -eq $gh) {
        return $null
    }

    $environment = New-RunnerProbeEnvironment
    foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'GH_CONFIG_DIR')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }

    $probeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-gh-token-probe-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
    try {
        $process = Invoke-RunnerProcess -FileName $gh.FileName -ArgumentList (@($gh.Prefix) + @('auth', 'token')) -WorkingDirectory $probeDirectory -Environment $environment -TimeoutSeconds 30
        if ($process.TimedOut -or $process.ExitCode -ne 0) {
            return $null
        }
        $token = ([string]$process.Stdout).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            return $null
        }
        return $token
    } finally {
        if (Test-Path -LiteralPath $probeDirectory) {
            Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-CopilotAuthentication {
    $tokenVariable = Get-CopilotTokenVariable
    if (-not [string]::IsNullOrWhiteSpace($tokenVariable)) {
        return [pscustomobject]@{
            Source = 'environment'
            TokenVariable = $tokenVariable
            TokenValue = $null
            GitHubCliTokenResolved = $false
        }
    }

    $githubCliToken = Get-CopilotGitHubCliToken
    if (-not [string]::IsNullOrWhiteSpace($githubCliToken)) {
        return [pscustomobject]@{
            Source = 'github_cli_token'
            TokenVariable = 'GH_TOKEN'
            TokenValue = $githubCliToken
            GitHubCliTokenResolved = $true
        }
    }

    return [pscustomobject]@{
        Source = 'copilot_os_keychain_or_github_cli_unverified'
        TokenVariable = $null
        TokenValue = $null
        GitHubCliTokenResolved = $false
    }
}

function Invoke-CopilotCli {
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

function Get-CopilotHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [string[]]$Arguments = @('--help')
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    return Invoke-CopilotCli -CommandInfo $CommandInfo -Arguments $Arguments -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
}

function Remove-CopilotAnsiSequences {
    param([AllowEmptyString()][string]$Text)

    return [regex]::Replace($Text, "`e\[[0-?]*[ -/]*[@-~]", '')
}

function Get-CopilotContinuationCapability {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$HelpText)

    $cleanText = Remove-CopilotAnsiSequences -Text $HelpText
    $lines = @($cleanText -split "`r?`n")
    foreach ($flag in @('--resume', '--session-id')) {
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
            if ($implicitContinuation -or ($flag -eq '--session-id' -and $freshSessionDescription)) { continue }
            $continuationDescription = $contextWithoutFlag -match '(?i)(resume|continue|previous|existing|specific|target|select)'
            $identityDescription = $contextWithoutFlag -match '(?i)(session\s*(?:id|identifier)|by\s+(?:id|identifier)|exact\s+(?:session|id)|identifier)'
            $parameterIdentifiesSession = $match.Groups['parameter'].Value -match '(?i)(?:session[-_ ]?)?id|identifier'
            if ($flag -eq '--resume') { $continuationDescription = $true }
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
    }

    return [pscustomobject]@{
        Available = $false
        Flag = $null
        ArgumentStyle = $null
        Parameter = $null
        HelpEvidence = $null
        Reason = 'The installed Copilot help did not prove a continuation flag that accepts an explicit session id; implicit last-session continuation is not permitted.'
    }
}

function New-CopilotContinuationArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Capability,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    if (-not [bool]$Capability.Available -or [string]::IsNullOrWhiteSpace([string]$Capability.Flag)) {
        throw 'Copilot exact-session continuation was requested without a proven continuation capability.'
    }
    if ([string]$Capability.ArgumentStyle -eq 'equals') {
        return @(([string]$Capability.Flag + '=' + $SessionId))
    }
    return @([string]$Capability.Flag, $SessionId)
}

function Get-CopilotEventSessionIds {
    param([Parameter(Mandatory = $true)][object]$Event)

    $data = Get-JsonProperty -Object $Event -Name 'data' -Default $null
    $session = Get-JsonProperty -Object $Event -Name 'session' -Default $null
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @(
            (Get-JsonProperty -Object $Event -Name 'sessionId' -Default $null),
            (Get-JsonProperty -Object $Event -Name 'session_id' -Default $null),
            (Get-JsonProperty -Object $data -Name 'sessionId' -Default $null),
            (Get-JsonProperty -Object $data -Name 'session_id' -Default $null),
            (Get-JsonProperty -Object $session -Name 'id' -Default $null),
            (Get-JsonProperty -Object $session -Name 'sessionId' -Default $null)
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value) -and $values -notcontains [string]$value) { $values.Add([string]$value) }
    }
    return @($values.ToArray())
}

function Resolve-SandboxCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Resolve-ExternalCommand -Name $Name
}

function Get-CopilotDescriptor {
    $copy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $copy[$key] = $descriptor[$key] }
    $commandInfo = Resolve-ExternalCommand -Name 'copilot'
    $version = 'unavailable'
    if ($null -ne $commandInfo) {
        $observation = Get-ExternalCommandVersion -CommandInfo $commandInfo
        $version = [string]$observation.Version
    }
    $copy.harness = [ordered]@{ name = 'GitHub Copilot CLI'; version = $version }
    return $copy
}

function New-CopilotCliArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform = (Get-PlatformName)
    )

    $directoryArgument = Get-SandboxVisiblePath -HostPath $Inputs.Run.WorkingDirectoryPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $secretList = ($copilotAuthVariables -join ',')
    $arguments = [System.Collections.Generic.List[string]]::new()
    # Noninteractive one-shot JSONL run. --allow-all-tools is a broad
    # tool-approval grant required for programmatic execution; it does not
    # include --allow-all-paths or --allow-all-urls, so normal path and URL
    # verification remains active. --no-ask-user keeps the agent from pausing
    # for questions. Repository-owned custom instructions remain enabled so
    # both paired arms see the staged repository exactly as supplied. Ambient
    # Copilot state is excluded by the run-local COPILOT_HOME and environment
    # roots. --disable-builtin-mcps drops the built-in GitHub MCP server.
    # --secret-env-vars removes the listed credentials from shell and MCP
    # child environments.
    foreach ($argument in @(
            '-C', $directoryArgument,
            '--model', $Inputs.Profile.Model,
            '--output-format', 'json',
            '--allow-all-tools',
            '--no-ask-user',
            '--disable-builtin-mcps',
            '--no-color',
            '--log-level', 'none',
            '--no-auto-update',
            ('--secret-env-vars=' + $secretList)
        )) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments.Add('--reasoning-effort')
        $arguments.Add([string]$Inputs.Profile.ReasoningEffort)
    }
    return @($arguments)
}

function Get-CopilotCapabilityMap {
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

function Get-CopilotPreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $commandInfo = Resolve-ExternalCommand -Name 'copilot'
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $versionObservation = $null
    $continuationCapability = [pscustomobject]@{
        Available = $false
        Flag = $null
        ArgumentStyle = $null
        Parameter = $null
        HelpEvidence = $null
        Reason = 'Copilot exact-session continuation was not probed because the installed help surface was unavailable.'
    }

    if ($profile.Runner -ne 'github-copilot') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than github-copilot.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is github-copilot.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('GitHub Copilot requires a model in execution-profile.json (claude-haiku-4.5 is the Codebelt reference).')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail $profile.Model))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by github-copilot.")
    }
    if ($profile.ToolProfile -ne 'default') {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by github-copilot.")
    }
    if ($null -eq $commandInfo) {
        $reasons.Add('The GitHub Copilot CLI executable is not available on PATH.')
        if ($null -ne $run.Interaction) {
            $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The GitHub Copilot executable is unavailable, so exact-session continuation cannot be proven before execution.'))
            $reasons.Add('scripted_multi_turn_same_session is incompatible: the GitHub Copilot executable is unavailable and no model-free continuation probe can run.')
        }
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment (New-RunnerEnvironment -Run $run) -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The GitHub Copilot CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'copilot --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }
            $help = Get-CopilotHelpResult -CommandInfo $commandInfo -Inputs $Inputs
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $helpFailureReason = "Copilot --help failed with exit status $($help.ExitCode); exact-session continuation cannot be proven."
                $reasons.Add($helpFailureReason)
                if ($null -ne $run.Interaction) {
                    $continuationCapability.Reason = $helpFailureReason
                    $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $helpFailureReason))
                }
            } else {
                $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
                foreach ($flag in @('--output-format', '--model', '--allow-all-tools', '--no-ask-user', '--disable-builtin-mcps', '--secret-env-vars')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed Copilot CLI does not advertise required flag '$flag'.")
                    }
                }
                $visibleForConstruction = if ($platform -eq 'linux' -and $null -ne $sandboxInfo) { 'linux' } else { $platform }
                $constructed = New-CopilotCliArguments -Inputs $Inputs -VisiblePlatform $visibleForConstruction
                foreach ($forbidden in @('--resume', '-r', '--continue', '--session-id', '--connect', '--yolo', '--allow-all', '--allow-all-paths', '--allow-all-urls')) {
                    if (@($constructed) -contains $forbidden) { $reasons.Add("The constructed Copilot invocation must not use session-continuation or over-broad permission option '$forbidden'.") }
                }
                foreach ($required in @('--output-format', '--allow-all-tools', '--no-ask-user', '--disable-builtin-mcps', '--secret-env-vars')) {
                    $present = @($constructed) -contains $required
                    if ($required -eq '--secret-env-vars') {
                        $present = $present -or (@($constructed | Where-Object { $_ -like '--secret-env-vars=*' }).Count -gt 0)
                    }
                    if (-not $present) { $reasons.Add("The constructed Copilot invocation must include '$required'.") }
                }
                $promptOptionCount = @($constructed | Where-Object { $_ -eq '--prompt' -or $_ -eq '-p' -or $_ -like '--prompt=*' }).Count
                if ($promptOptionCount -ne 0) { $reasons.Add('The constructed Copilot invocation must not place the prompt in argv; prompt delivery uses stdin.') }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'Copilot accepts the constructed noninteractive invocation: stdin prompt delivery, --output-format json, --model, broad --allow-all-tools approval, --no-ask-user, --disable-builtin-mcps, --secret-env-vars, and no session continuation.'))
                }
                if ($null -ne $run.Interaction) {
                    $continuationCapability = Get-CopilotContinuationCapability -HelpText $helpText
                    if ($continuationCapability.Available) {
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status passed -Detail ("Copilot help proves explicit exact-session continuation through {0} {1}; resumed invocations retain --output-format json, --model, -C, and the isolated environment." -f $continuationCapability.Flag, $continuationCapability.Parameter)))
                    } else {
                        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $continuationCapability.Reason))
                        $reasons.Add('scripted_multi_turn_same_session is incompatible: ' + $continuationCapability.Reason)
                    }
                }
            }
        } catch {
            $reasons.Add("Could not inspect Copilot CLI capabilities: $($_.Exception.Message)")
            if ($null -ne $run.Interaction -and @($checks | Where-Object { $_.name -eq 'scripted_multi_turn_same_session' }).Count -eq 0) {
                $continuationCapability.Reason = 'Copilot capability inspection failed before exact-session continuation could be proven.'
                $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail $continuationCapability.Reason))
            }
        }
    }

    $authState = Resolve-CopilotAuthentication
    if ($authState.Source -eq 'environment') {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail "Authentication is available through the explicit $($authState.TokenVariable) environment variable; Copilot OS-keychain and GitHub CLI state are not copied into the run."))
    } elseif ($authState.Source -eq 'github_cli_token') {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail 'GitHub CLI fallback resolved a token in the trusted runner; only a protected token environment variable will be passed to Copilot.'))
    } else {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status unavailable -Detail 'No explicit token is present and GitHub CLI fallback did not yield a token; native Copilot OS-keychain lookup is delegated to the installed CLI. This preflight does not contact the Copilot service.'))
        $warnings.Add('Authentication readiness beyond explicit environment tokens and the observable GitHub CLI fallback cannot be proven without a live Copilot request; preflight remains conditional and does not reject a tokenless native OAuth/keychain configuration.')
    }

    if ($platform -notin @('linux', 'macos')) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status not_applicable -Detail "Platform '$platform' has no configured external hard-confinement mechanism; pragmatic isolation remains available."))
        $warnings.Add("Platform '$platform' has no external hard filesystem confinement in this adapter; execution will report pragmatic isolation.")
    } elseif ($null -eq $sandboxInfo) {
        $sandboxName = if ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail "External '$sandboxName' is unavailable; pragmatic isolation remains available."))
        $warnings.Add("External '$sandboxName' was unavailable; execution will report pragmatic isolation.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $($sandboxInfo.Source) sandbox confines Copilot to the staged run and required system runtime paths."))
    }

    $freshSessionDetail = if ($null -eq $run.Interaction) {
        'The adapter starts one new Copilot process, supplies one stdin prompt, and passes no --resume, --continue, --session-id, or --connect.'
    } else {
        'The adapter starts turn 1 in a fresh Copilot process without continuation, waits for its terminal assistant response, then targets only the exact captured session id for later turns.'
    }
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail $freshSessionDetail))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter points COPILOT_HOME, Copilot cache, HOME, USERPROFILE, and XDG roots at the run''s isolated home, disables built-in MCP servers, and preserves only staged repository-owned custom instructions; personal Copilot skills, plugins, MCP config, sessions, memories, and instructions are not imported.'))
    $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "-C $($run.WorkingDirectoryPath); COPILOT_HOME under $($run.HomeDirectoryPath)"))
    $promptFidelityDetail = if ($null -eq $run.Interaction) {
        'The prepared UTF-8 prompt bytes are supplied once through stdin; the execution fake proves the received bytes match the staged prompt.'
    } else {
        'Each scripted user turn is supplied as UTF-8 bytes through stdin; execution must prove every requested turn was delivered in order.'
    }
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail $promptFidelityDetail))
    $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only supported authentication state is made available to Copilot; --secret-env-vars removes every listed token variable from shell and MCP child environments; no Copilot profile or credential file is copied.'))
    $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status unavailable -Detail 'Behavioral eval transport is the runner-owned direct Copilot session; preflight cannot yet observe that session''s resolved model, cwd, HOME/config, fresh identity, prompt, exclusions, or terminal capture, so those controls stay conditional until execute captures the session''s terminal evidence. Copilot''s native task/general-purpose subagent remains a separate advertised capability and is not the transport.'))
    $warnings.Add('Copilot runner-owned session controls are conditional. Execution must capture the session''s own terminal evidence (model, cwd, isolated COPILOT_HOME, fresh session, prompt hash, transcript); the native task/general-purpose subagent is a harness capability, not the benchmark transport.')
    if ($platform -eq 'macos') {
        $warnings.Add('macOS sandbox-exec is deprecated by Apple but is used only when present; a future runner revision may replace it with an equivalent supported mechanism.')
    }
    $hardConfinement = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-CopilotCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement -ContinuationCapability $continuationCapability
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'GitHub Copilot CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('runner-owned fresh Copilot CLI session per eval execution', 'copilot --output-format json terminal event capture', 'native task/general-purpose subagent available as a separate harness capability, not the transport', 'prompt on stdin', '--allow-all-tools broad tool approval', 'path and URL verification preserved (no --allow-all-paths/--allow-all-urls)', '--no-ask-user', 'repository-owned custom instructions preserved', '--disable-builtin-mcps', '--secret-env-vars shell/MCP child filtering', 'isolated COPILOT_HOME and COPILOT_CACHE_HOME', 'isolated HOME/XDG roots', 'OS-keychain authentication delegated to Copilot', 'GitHub CLI fallback token resolved by the trusted runner when needed', 'no host GH_CONFIG_DIR exposed to the worker')) { $mechanisms.Add($mechanism) }
    if ($null -ne $run.Interaction -and $continuationCapability.Available) {
        $mechanisms.Add(("explicit Copilot {0} <session-id> continuation selected from installed help" -f $continuationCapability.Flag))
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
            structured_output = 'copilot --output-format json'
            session_identity_source = 'runtime structured session event'
            exact_session_required = $true
            implicit_continuation = $false
        }
    }
    return $document
}

function New-CopilotEnvironment {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $copilotHome = Join-Path $Inputs.Run.HomeDirectoryPath '.copilot'
    $copilotCacheHome = Join-Path $Inputs.Run.HomeDirectoryPath '.copilot-cache'
    New-Item -ItemType Directory -Path $copilotHome -Force | Out-Null
    New-Item -ItemType Directory -Path $copilotCacheHome -Force | Out-Null
    $additional = @{
        COPILOT_HOME = $copilotHome
        COPILOT_CACHE_HOME = $copilotCacheHome
        COPILOT_AUTO_UPDATE = 'false'
    }
    $tokenVariable = Get-CopilotTokenVariable
    $authState = Resolve-CopilotAuthentication
    if ($authState.Source -eq 'github_cli_token') {
        $additional[$authState.TokenVariable] = $authState.TokenValue
    }
    return New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables $copilotAuthVariables -Additional $additional
}

function New-CopilotInsideEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $insideEnvironment = [ordered]@{
        HOME = '/run/home'
        USERPROFILE = '/run/home'
        XDG_CONFIG_HOME = '/run/home/.config'
        XDG_DATA_HOME = '/run/home/.local/share'
        XDG_CACHE_HOME = '/run/home/.cache'
        TEMP = '/run/home/tmp'
        TMP = '/run/home/tmp'
        COPILOT_HOME = '/run/home/.copilot'
        COPILOT_CACHE_HOME = '/run/home/.copilot-cache'
        COPILOT_AUTO_UPDATE = 'false'
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    foreach ($authName in $copilotAuthVariables) {
        if ($Environment.Contains($authName) -and -not [string]::IsNullOrWhiteSpace([string]$Environment[$authName])) {
            $insideEnvironment[$authName] = [string]$Environment[$authName]
        }
    }
    return $insideEnvironment
}

function Write-CopilotCapture {
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

function Add-NullableInt64 {
    param([object]$Current, [object]$Value)

    if ($null -eq $Value) { return $Current }
    if ($null -eq $Current) { return [int64]$Value }
    return ([int64]$Current + [int64]$Value)
}

function Read-CopilotEvents {
    param(
        [Parameter(Mandatory = $true)][object]$Parsed,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Warnings
    )

    $assistantContents = [System.Collections.Generic.List[string]]::new()
    $finalText = $null
    $observedModel = $null
    $usageInput = $null
    $usageOutput = $null
    $usageCacheRead = $null
    $usageCacheWrite = $null
    $usageNumToolCalls = 0
    $usageSeen = $false
    $toolStarts = 0
    $sessionError = $null
    $eventCounts = @{}
    $sessionIds = [System.Collections.Generic.List[string]]::new()
    $observedModels = [System.Collections.Generic.List[string]]::new()
    $terminalEventObserved = $false
    $assistantMessageObserved = $false
    $eventTimestamps = [System.Collections.Generic.List[string]]::new()

    foreach ($event in @($Parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $Warnings.Add('Copilot emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        $data = Get-JsonProperty -Object $event -Name 'data' -Default $null
        foreach ($eventSessionId in @(Get-CopilotEventSessionIds -Event $event)) {
            if ($sessionIds -notcontains $eventSessionId) { $sessionIds.Add($eventSessionId) }
        }
        foreach ($timestamp in @(
                (Get-JsonProperty -Object $event -Name 'timestamp' -Default $null),
                (Get-JsonProperty -Object $event -Name 'timestamp_utc' -Default $null)
            )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$timestamp) -and $eventTimestamps -notcontains [string]$timestamp) { $eventTimestamps.Add([string]$timestamp) }
        }
        switch ($eventType) {
            'assistant.message' {
                $assistantMessageObserved = $true
                $content = [string](Get-JsonProperty -Object $data -Name 'content' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    $assistantContents.Add($content)
                    $finalText = $content
                }
                $model = [string](Get-JsonProperty -Object $data -Name 'model' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($model)) {
                    $observedModel = $model
                    if ($observedModels -notcontains $model) { $observedModels.Add($model) }
                }
            }
            'assistant.usage' {
                $usageSeen = $true
                $usageInput = Add-NullableInt64 -Current $usageInput -Value (Get-JsonProperty -Object $data -Name 'inputTokens' -Default $null)
                $usageOutput = Add-NullableInt64 -Current $usageOutput -Value (Get-JsonProperty -Object $data -Name 'outputTokens' -Default $null)
                $usageCacheRead = Add-NullableInt64 -Current $usageCacheRead -Value (Get-JsonProperty -Object $data -Name 'cacheReadTokens' -Default $null)
                $usageCacheWrite = Add-NullableInt64 -Current $usageCacheWrite -Value (Get-JsonProperty -Object $data -Name 'cacheWriteTokens' -Default $null)
                $numToolCalls = Get-JsonProperty -Object $data -Name 'numToolCalls' -Default $null
                if ($null -ne $numToolCalls) { $usageNumToolCalls += [int]$numToolCalls }
                $model = [string](Get-JsonProperty -Object $data -Name 'model' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($model)) {
                    $observedModel = $model
                    if ($observedModels -notcontains $model) { $observedModels.Add($model) }
                }
            }
            'tool.execution_start' { $toolStarts++ }
            'session.error' { $sessionError = [string](Get-JsonProperty -Object $data -Name 'message' -Default 'Copilot reported a session error.') }
            { $_ -in @('session.start', 'session.info', 'session.idle', 'session.shutdown', 'session.task_complete', 'user.message', 'assistant.message_start', 'assistant.message_delta', 'assistant.turn_start', 'assistant.turn_end', 'assistant.reasoning', 'assistant.tool_call_delta', 'tool.execution_progress', 'tool.execution_partial_result', 'tool.execution_complete', 'command.execute', 'command.completed', 'session.usage_info', 'session.usage_checkpoint') } { }
            default { $Warnings.Add("Unknown Copilot event '$eventType' was preserved as a warning.") }
        }
        if ($eventType -in @('session.task_complete', 'session.idle', 'session.shutdown', 'assistant.turn_end')) { $terminalEventObserved = $true }
    }

    if ([string]::IsNullOrWhiteSpace($finalText) -and $assistantContents.Count -gt 0) {
        $finalText = [string]::Join("`n", $assistantContents)
    }
    $toolCalls = if ($toolStarts -gt 0) { $toolStarts } else { $usageNumToolCalls }

    return [pscustomobject]@{
        FinalText = $finalText
        ObservedModel = $observedModel
        UsageSeen = $usageSeen
        UsageInput = $usageInput
        UsageOutput = $usageOutput
        UsageCacheRead = $usageCacheRead
        UsageCacheWrite = $usageCacheWrite
        ToolCalls = $toolCalls
        SessionError = $sessionError
        EventCounts = $eventCounts
        SessionIds = @($sessionIds.ToArray())
        ObservedModels = @($observedModels.ToArray())
        TerminalEventObserved = $terminalEventObserved
        AssistantMessageObserved = $assistantMessageObserved
        EventTimestamps = @($eventTimestamps.ToArray())
        StructuredEventCount = @($Parsed.Events).Count
        ParseErrorCount = @($Parsed.Errors).Count
    }
}

function Invoke-CopilotTurnProcess {
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
        $insideEnvironment = New-CopilotInsideEnvironment -Inputs $Inputs -Environment $Environment
        $sandboxArguments = Get-LinuxEvalSandboxArguments -Inputs $Inputs -CommandInfo $CommandInfo -InsideEnvironment $insideEnvironment
        return Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($Arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
    }
    if ($Platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosEvalSandboxProfile -Inputs $Inputs -CommandInfo $CommandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $CommandInfo.FileName) + @($CommandInfo.Prefix) + @($Arguments)
        return Invoke-RunnerProcess -FileName $SandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
    }
    return Invoke-CopilotCli -CommandInfo $CommandInfo -Arguments $Arguments -Inputs $Inputs -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
}

function Invoke-CopilotScriptedExecute {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Preflight,
        [Parameter(Mandatory = $true)][object]$ExecutionDescriptor
    )

    $started = [DateTime]::UtcNow
    $commandInfo = Resolve-ExternalCommand -Name 'copilot'
    $environment = New-CopilotEnvironment -Inputs $Inputs
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
        $failureMessage = [string](Get-JsonProperty -Object $continuationObservation -Name 'reason' -Default 'Copilot exact-session continuation was not proven by installed help.')
        return New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $failureMessage) -SessionId $fallbackSessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $Preflight; resume = $false }) -AttemptCount 1
    }

    $requestedTurns = @($Inputs.Run.Interaction.turns)
    $baseArguments = New-CopilotCliArguments -Inputs $Inputs -VisiblePlatform $visiblePlatform
    $turnRecords = [System.Collections.Generic.List[object]]::new()
    $nativeTurns = [System.Collections.Generic.List[object]]::new()
    $rawStdout = [System.Collections.Generic.List[string]]::new()
    $rawStderr = [System.Collections.Generic.List[string]]::new()
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $nativeFailures = [System.Collections.Generic.List[string]]::new()
    $eventCounts = @{}
    $observedModels = [System.Collections.Generic.List[string]]::new()
    $usageInput = $null
    $usageOutput = $null
    $usageCacheRead = $null
    $usageCacheWrite = $null
    $usageSeen = $false
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
                $failureMessage = 'Copilot turn 1 did not expose an exact session id, so no continuation invocation was started.'
                break
            }
            $arguments = @($arguments) + @(New-CopilotContinuationArguments -Capability $continuationCapability -SessionId $targetSessionId)
        }

        $turnStarted = [DateTime]::UtcNow
        try {
            $turnInputBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($turnText)
            $process = Invoke-CopilotTurnProcess -Inputs $Inputs -CommandInfo $commandInfo -Arguments $arguments -Environment $environment -Platform $platform -SandboxInfo $sandboxInfo -InputBytes $turnInputBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
        } catch {
            $nativeFailures.Add('transport_failure')
            $status = 'failed'
            $failureCode = 'copilot_failure'
            $failureMessage = $_.Exception.Message
            break
        }
        if ($null -eq $firstProcess) { $firstProcess = $process }
        $lastProcess = $process
        $rawStdout.Add([string]$process.Stdout)
        $rawStderr.Add([string]$process.Stderr)
        $turnNumber = $turnIndex + 1
        $turnArtifact = Write-CopilotCapture -RunData $Inputs -RelativePath ("evidence/copilot-turn-{0}-events.jsonl" -f $turnNumber) -Text ([string]$process.Stdout)
        $turnStderrArtifact = Write-CopilotCapture -RunData $Inputs -RelativePath ("evidence/copilot-turn-{0}-stderr.txt" -f $turnNumber) -Text ([string]$process.Stderr)
        $artifacts.Add($turnArtifact)
        $artifacts.Add($turnStderrArtifact)

        $parsed = if ([string]::IsNullOrEmpty([string]$process.Stdout)) { [pscustomobject]@{ Events = @(); Errors = @() } } else { ConvertFrom-JsonLines -Text $process.Stdout }
        foreach ($parseError in @($parsed.Errors)) { $warnings.Add("Copilot turn $turnNumber event parse error: $parseError") }
        $parsedEvents = Read-CopilotEvents -Parsed $parsed -Warnings $warnings
        foreach ($eventName in $parsedEvents.EventCounts.Keys) {
            if ($eventCounts.ContainsKey($eventName)) { $eventCounts[$eventName] += [int]$parsedEvents.EventCounts[$eventName] } else { $eventCounts[$eventName] = [int]$parsedEvents.EventCounts[$eventName] }
        }
        if ($parsedEvents.UsageSeen) { $usageSeen = $true }
        $usageInput = Add-NullableInt64 -Current $usageInput -Value $parsedEvents.UsageInput
        $usageOutput = Add-NullableInt64 -Current $usageOutput -Value $parsedEvents.UsageOutput
        $usageCacheRead = Add-NullableInt64 -Current $usageCacheRead -Value $parsedEvents.UsageCacheRead
        $usageCacheWrite = Add-NullableInt64 -Current $usageCacheWrite -Value $parsedEvents.UsageCacheWrite
        $toolCalls += [int]$parsedEvents.ToolCalls
        foreach ($modelName in @($parsedEvents.ObservedModels)) {
            if ($observedModels -notcontains $modelName) { $observedModels.Add($modelName) }
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
            copilot_home = [string]$environment['COPILOT_HOME']
            started_utc = Format-UtcTimestamp -Value $process.StartedUtc
            finished_utc = Format-UtcTimestamp -Value $process.FinishedUtc
            event_timestamps = @($parsedEvents.EventTimestamps)
            exit_code = $process.ExitCode
            timed_out = [bool]$process.TimedOut
            terminal = -not $process.TimedOut -and $process.ExitCode -eq 0
        }
        $nativeTurns.Add($nativeTurn)

        $turnProblem = $null
        if ($process.TimedOut) { $turnProblem = 'turn_timeout'; $status = 'timed_out'; $failureCode = 'timed_out'; $failureMessage = 'Copilot did not finish before timeout_seconds.' }
        elseif ($process.ExitCode -ne 0 -or $null -ne $parsedEvents.SessionError) { $turnProblem = 'turn_failed'; $status = 'failed'; $failureCode = 'copilot_failure'; $failureMessage = if ($null -ne $parsedEvents.SessionError) { [string]$parsedEvents.SessionError } else { "Copilot exited with status $($process.ExitCode)." } }
        elseif ($parsedEvents.ParseErrorCount -gt 0) { $turnProblem = 'structured_event_parse'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "Copilot turn $turnNumber did not produce a complete structured event stream." }
        elseif ($sessionIds.Count -ne 1) { $turnProblem = 'session_id_unobservable'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "Copilot turn $turnNumber did not expose exactly one session id in structured events." }
        elseif ($turnIndex -gt 0 -and $observedSessionId -ne $targetSessionId) { $turnProblem = 'session_identity_mismatch'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "Copilot turn $turnNumber returned session '$observedSessionId' instead of the exact resumed session '$targetSessionId'." }
        elseif (-not $parsedEvents.AssistantMessageObserved -or [string]::IsNullOrWhiteSpace([string]$parsedEvents.FinalText) -or -not [bool]$parsedEvents.TerminalEventObserved) { $turnProblem = 'terminal_turn_status'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "Copilot turn $turnNumber did not provide a terminal assistant response and terminal event before continuation." }
        elseif (@($parsedEvents.ObservedModels | Where-Object { [string]$_ -ne [string]$Inputs.Profile.Model }).Count -gt 0) { $turnProblem = 'requested_model'; $status = 'incompatible'; $failureCode = 'native_interaction_incompatible'; $failureMessage = "Copilot turn $turnNumber reported a model different from the requested model '$($Inputs.Profile.Model)'." }

        if ($null -ne $turnProblem) {
            $nativeFailures.Add($turnProblem)
            break
        }
        if ($turnIndex -eq 0) { $capturedSessionId = $observedSessionId }
        $finalText = [string]$parsedEvents.FinalText
        $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 1; role = 'user'; content_sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($turnText)); session_id = $capturedSessionId; timestamp_utc = Format-UtcTimestamp -Value $process.StartedUtc })
        $turnRecords.Add([ordered]@{ sequence = ($turnIndex * 2) + 2; role = 'assistant'; text = $finalText; session_id = $capturedSessionId; timestamp_utc = Format-UtcTimestamp -Value $process.FinishedUtc })
    }

    if ($null -eq $firstProcess) {
        $firstProcess = [pscustomobject]@{ StartedUtc = $started; FinishedUtc = [DateTime]::UtcNow; DurationSeconds = ([DateTime]::UtcNow - $started).TotalSeconds; ExitCode = $null; TimedOut = $false }
    }
    if ($null -eq $lastProcess) { $lastProcess = $firstProcess }
    $combinedStdout = [string]::Join('', @($rawStdout.ToArray()))
    $combinedStderr = [string]::Join('', @($rawStderr.ToArray()))
    if (-not [string]::IsNullOrEmpty($combinedStdout) -and -not $combinedStdout.EndsWith("`n", [StringComparison]::Ordinal)) { $combinedStdout += [Environment]::NewLine }
    if (-not [string]::IsNullOrEmpty($combinedStderr) -and -not $combinedStderr.EndsWith("`n", [StringComparison]::Ordinal)) { $combinedStderr += [Environment]::NewLine }
    $stdoutArtifact = Write-CopilotCapture -RunData $Inputs -RelativePath 'evidence/copilot-events.jsonl' -Text $combinedStdout
    $stderrArtifact = Write-CopilotCapture -RunData $Inputs -RelativePath 'evidence/copilot-stderr.txt' -Text $combinedStderr
    $artifacts.Add($stdoutArtifact)
    $artifacts.Add($stderrArtifact)

    if ($nativeFailures.Count -eq 0 -and $turnRecords.Count -ne ($requestedTurns.Count * 2)) {
        $nativeFailures.Add('turn_order')
        $status = 'incompatible'
        $failureCode = 'native_interaction_incompatible'
        $failureMessage = 'Copilot scripted interaction did not complete every ordered user/assistant turn.'
    }
    if ($status -eq 'completed' -and $nativeFailures.Count -gt 0) { $status = 'incompatible' }
    if ([string]::IsNullOrWhiteSpace($capturedSessionId)) { $capturedSessionId = [Guid]::NewGuid().ToString('D') }
    $finished = $lastProcess.FinishedUtc
    $durationSeconds = [Math]::Round(($finished - $firstProcess.StartedUtc).TotalSeconds, 3)
    $tokenMetric = if (-not $usageSeen) {
        New-UnavailableMetric -Reason 'copilot_did_not_expose_usage_events'
    } else {
        $usageValue = [ordered]@{}
        if ($null -ne $usageInput) { $usageValue['input_tokens'] = [int64]$usageInput }
        if ($null -ne $usageOutput) { $usageValue['output_tokens'] = [int64]$usageOutput }
        if ($null -ne $usageCacheRead) { $usageValue['cache_read_tokens'] = [int64]$usageCacheRead }
        if ($null -ne $usageCacheWrite) { $usageValue['cache_write_tokens'] = [int64]$usageCacheWrite }
        if ($usageValue.Count -eq 0) { New-UnavailableMetric -Reason 'copilot_usage_event_had_no_supported_buckets' } else { New-AvailableMetric -Value $usageValue }
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/copilot-events.jsonl'; complete = $nativeFailures.Count -eq 0 })
        tokens = $tokenMetric
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = New-UnavailableMetric -Reason 'copilot_exposes_a_billing_multiplier_not_a_currency_cost'
    }
    $authState = Resolve-CopilotAuthentication
    $credentialEvidence = [ordered]@{
        source = $authState.Source
        github_token_variable = $authState.TokenVariable
        secret_env_vars = @($copilotAuthVariables)
        secret_env_var_scope = @('shell', 'mcp')
        github_cli_token_resolved = [bool]$authState.GitHubCliTokenResolved
        github_cli_config_forwarded = $false
        login_profile_copied = $false
        auth_file_copied = $false
        value_observed = $false
    }
    $observedModel = if ($observedModels.Count -eq 0) { [string]$Inputs.Profile.Model } else { [string]$observedModels[$observedModels.Count - 1] }
    $transcriptArtifactPath = 'evidence/copilot-events.jsonl'
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
        transport = 'copilot-cli-explicit-session-continuation'
        exact_session_flag = [string]$continuationCapability.Flag
        implicit_continuation = $false
        native_turns = @($nativeTurns.ToArray())
        structured_transcript_complete = [bool]$terminalCapture
        working_directory = [string]$Inputs.Run.WorkingDirectoryPath
        isolated_home = [string]$Inputs.Run.HomeDirectoryPath
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
        sandbox = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
        credential = $credentialEvidence
        interaction = $interactionEvidence
        capture = [ordered]@{
            source = 'harness_native_transport'
            terminal = [bool]$terminalCapture
            worker_authored = $false
            artifact = $transcriptArtifactPath
            sha256 = if ($transcriptArtifact.Count -eq 1) { [string](Get-JsonProperty -Object $transcriptArtifact[0] -Name 'sha256' -Default $null) } else { $null }
            complete_structured_transcript = [bool]$terminalCapture
            turn_artifacts = @($nativeTurns.ToArray() | ForEach-Object { "evidence/copilot-turn-$(Get-JsonProperty -Object $_ -Name 'turn' -Default 0)-events.jsonl" })
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
    foreach ($mechanism in @('runner-owned fresh Copilot CLI process for turn 1', 'copilot --output-format json structured terminal event capture', 'prompt on stdin', '--model on every turn', '-C on every turn', 'isolated COPILOT_HOME and COPILOT_CACHE_HOME', 'isolated HOME/XDG roots', 'same isolated environment on every turn', 'no implicit last-session continuation')) { $mechanisms.Add($mechanism) }
    $mechanisms.Add(("explicit Copilot {0} <session-id> continuation selected from installed help" -f $continuationCapability.Flag))
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    if (-not $hardFilesystem) { $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $exitStatus = if ($status -eq 'completed') { [Nullable[int]]0 } elseif ($status -eq 'timed_out') { $null } else { $null }
    $failureCodeValue = if ([string]::IsNullOrWhiteSpace($failureCode)) { 'native_interaction_incompatible' } else { $failureCode }
    $failureMessageValue = if ([string]::IsNullOrWhiteSpace($failureMessage)) { 'Copilot scripted interaction failed closed.' } else { $failureMessage }
    $failure = if ($nativeFailures.Count -eq 0) { $null } else { New-ExecutionFailure -Code $failureCodeValue -Message $failureMessageValue }
    $resultFinalResponse = if ($status -eq 'completed') { $finalText } else { $null }
    $resultFinalResponseReason = if ($status -eq 'completed') { $null } else { 'native_interaction_incompatible' }
    $result = New-ExecutionResult -Descriptor $ExecutionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $resultFinalResponse -FinalResponseReason $resultFinalResponseReason -StartedUtc $firstProcess.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $durationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $capturedSessionId -IsolationCapabilities (Get-CopilotCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem -ContinuationCapability $continuationCapability) -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'Copilot accepted the requested model alias and configuration; scripted turns retained the exact requested model on every invocation.'; observations = [ordered]@{ model = $Inputs.Profile.Model; observed_models = @($observedModels.ToArray()); continuation_flag = $continuationCapability.Flag } }) -Telemetry $telemetry -Artifacts @($artifacts.ToArray()) -Warnings @($warnings.ToArray()) -Evidence $evidence -AttemptCount 1
    if ($status -eq 'completed') { [void](Assert-InteractionResultEvidence -ExecutionResult $result -RunData $Inputs.Run) }
    return $result
}

function Invoke-CopilotExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-CopilotPreflight -Inputs $Inputs
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
        return Invoke-CopilotScriptedExecute -Inputs $Inputs -Preflight $preflight -ExecutionDescriptor $executionDescriptor
    }

    $commandInfo = Resolve-ExternalCommand -Name 'copilot'
    $environment = New-CopilotEnvironment -Inputs $Inputs
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $arguments = New-CopilotCliArguments -Inputs $Inputs -VisiblePlatform $visiblePlatform

    if ($platform -eq 'linux' -and $hardFilesystem) {
        $insideEnvironment = New-CopilotInsideEnvironment -Inputs $Inputs -Environment $environment
        $sandboxArguments = Get-LinuxEvalSandboxArguments -Inputs $Inputs -CommandInfo $commandInfo -InsideEnvironment $insideEnvironment
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } elseif ($platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosEvalSandboxProfile -Inputs $Inputs -CommandInfo $commandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $commandInfo.FileName) + @($commandInfo.Prefix) + @($arguments)
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } else {
        $process = Invoke-CopilotCli -CommandInfo $commandInfo -Arguments $arguments -Inputs $Inputs -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    }

    $stdoutArtifact = Write-CopilotCapture -RunData $Inputs -RelativePath 'evidence/copilot-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-CopilotCapture -RunData $Inputs -RelativePath 'evidence/copilot-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact)
    $artifacts.Add($stderrArtifact)

    $warnings = [System.Collections.Generic.List[string]]::new()
    $parsed = if ([string]::IsNullOrEmpty([string]$process.Stdout)) {
        [pscustomobject]@{ Events = @(); Errors = @() }
    } else {
        ConvertFrom-JsonLines -Text $process.Stdout
    }
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("Copilot event parse error: $parseError") }
    $parsedEvents = Read-CopilotEvents -Parsed $parsed -Warnings $warnings

    $finalText = $parsedEvents.FinalText
    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'
        $reason = 'copilot_timeout'
        $failure = New-ExecutionFailure -Code 'timed_out' -Message 'Copilot did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $parsedEvents.SessionError) {
        $status = 'failed'
        $reason = 'copilot_failure'
        $message = if ($null -ne $parsedEvents.SessionError) { [string]$parsedEvents.SessionError } else { "Copilot exited with status $($process.ExitCode)." }
        $failure = New-ExecutionFailure -Code 'copilot_failure' -Message $message
    } elseif ([string]::IsNullOrWhiteSpace($finalText)) {
        $warnings.Add('Copilot exited successfully without an assistant message; the final response is unavailable.')
        $reason = 'copilot_did_not_return_final_response'
    }

    $tokenMetric = if (-not $parsedEvents.UsageSeen) {
        New-UnavailableMetric -Reason 'copilot_did_not_expose_usage_events'
    } else {
        $usageValue = [ordered]@{}
        if ($null -ne $parsedEvents.UsageInput) { $usageValue['input_tokens'] = [int64]$parsedEvents.UsageInput }
        if ($null -ne $parsedEvents.UsageOutput) { $usageValue['output_tokens'] = [int64]$parsedEvents.UsageOutput }
        if ($null -ne $parsedEvents.UsageCacheRead) { $usageValue['cache_read_tokens'] = [int64]$parsedEvents.UsageCacheRead }
        if ($null -ne $parsedEvents.UsageCacheWrite) { $usageValue['cache_write_tokens'] = [int64]$parsedEvents.UsageCacheWrite }
        if ($usageValue.Count -eq 0) { New-UnavailableMetric -Reason 'copilot_usage_event_had_no_supported_buckets' } else { New-AvailableMetric -Value $usageValue }
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/copilot-events.jsonl'; complete = $true })
        tokens = $tokenMetric
        tool_calls = New-AvailableMetric -Value ([int]$parsedEvents.ToolCalls)
        cost = New-UnavailableMetric -Reason 'copilot_exposes_a_billing_multiplier_not_a_currency_cost'
    }

    $capabilities = Get-CopilotCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('copilot --output-format json', 'prompt on stdin', '--allow-all-tools broad tool approval', 'path and URL verification preserved (no --allow-all-paths/--allow-all-urls)', '--no-ask-user', 'repository-owned custom instructions preserved', '--disable-builtin-mcps', '--secret-env-vars shell/MCP child filtering', 'isolated COPILOT_HOME and COPILOT_CACHE_HOME', 'isolated HOME/XDG roots', 'OS-keychain authentication delegated to Copilot', 'GitHub CLI fallback token resolved by the trusted runner when needed', 'no host GH_CONFIG_DIR exposed to the worker', 'no session continuation')) { $mechanisms.Add($mechanism) }
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    if (-not $hardFilesystem) { $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }

    $authState = Resolve-CopilotAuthentication
    $credentialEvidence = [ordered]@{
        source = $authState.Source
        github_token_variable = $authState.TokenVariable
        secret_env_vars = @($copilotAuthVariables)
        secret_env_var_scope = @('shell', 'mcp')
        github_cli_token_resolved = [bool]$authState.GitHubCliTokenResolved
        github_cli_config_forwarded = $false
        login_profile_copied = $false
        auth_file_copied = $false
        value_observed = $false
    }
    $observedModel = if ([string]::IsNullOrWhiteSpace([string]$parsedEvents.ObservedModel)) { $null } else { [string]$parsedEvents.ObservedModel }
    $resolvedConfiguration = [ordered]@{
        status = 'accepted_request'
        reason = 'Copilot accepted the requested model alias and configuration; it does not expose a distinct backend model snapshot beyond the model it reports in usage events.'
        observations = [ordered]@{
            model = $Inputs.Profile.Model
            reasoning_effort = $Inputs.Profile.ReasoningEffort
            observed_model = $observedModel
        }
    }

    $finished = [DateTime]::UtcNow
    $sandboxEvidence = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
    # Runner-owned terminal evidence for the direct Copilot session. The runner
    # controlled the fresh session, its model lock, working directory, isolated
    # COPILOT_HOME, and stdin prompt, and captured the session's own JSONL
    # transcript. This is transport-owned evidence, never orchestrator-authored.
    $transcriptArtifactPath = 'evidence/copilot-events.jsonl'
    $transcriptArtifact = @($artifacts | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'path' -Default '') -eq $transcriptArtifactPath } | Select-Object -First 1)
    $terminalCapture = (-not $process.TimedOut) -and (-not [string]::IsNullOrWhiteSpace([string]$process.Stdout))
    $delegationObservedModel = if ([string]::IsNullOrWhiteSpace([string]$parsedEvents.ObservedModel)) { [string]$Inputs.Profile.Model } else { [string]$parsedEvents.ObservedModel }
    $evidence = [ordered]@{
        event_counts = $parsedEvents.EventCounts
        observed_model = $observedModel
        prompt_delivery = 'stdin'
        prompt_first_input = $true
        resume = $false
        stdout_exit_code = $process.ExitCode
        sandbox = $sandboxEvidence
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
            observed_model = $delegationObservedModel
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
    return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration $resolvedConfiguration -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence $evidence -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-CopilotDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-CopilotInputs
            Write-RunnerJson -Value (Get-CopilotPreflight -Inputs $inputs) -AsOutput
        }
        'execute' {
            $inputs = Resolve-CopilotInputs
            [void](Assert-PhaseOneEvidenceWritable -Run $inputs.Run)
            $result = Invoke-CopilotExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
