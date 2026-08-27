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
        scripted_multi_turn_same_session = 'unsupported'
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
        mechanism = 'Runner-owned GitHub Copilot CLI one-shot session (copilot --output-format json): the runner starts one fresh Copilot process per eval execution, delivers the prompt on stdin, and captures the JSONL session events as terminal evidence'
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
        [bool]$HardFilesystemConfinement = $false
    )

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $capabilities[$capabilityName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName)
    }
    $capabilities['filesystem_confinement'] = if ($HardFilesystemConfinement) { 'supported' } else { 'unsupported' }
    $capabilities['candidate_skill_exposure'] = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' }
    $capabilities['scripted_multi_turn_same_session'] = 'unsupported'
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
    if ($null -ne $run.Interaction) {
        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The installed Copilot transport is one-shot. No model-free proof of a supported same-process/session continuation API is available, so scripted multi-turn execution is incompatible.'))
        $reasons.Add('scripted_multi_turn_same_session is incompatible: the current Copilot CLI adapter exposes only one-shot copilot --output-format json execution and cannot prove a same-session continuation mechanism; no second independent process is permitted.')
    }

    if ($null -eq $commandInfo) {
        $reasons.Add('The GitHub Copilot CLI executable is not available on PATH.')
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
                $reasons.Add("Copilot --help failed with exit status $($help.ExitCode).")
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
            }
        } catch {
            $reasons.Add("Could not inspect Copilot CLI capabilities: $($_.Exception.Message)")
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

    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The adapter starts one new Copilot process, supplies one stdin prompt, and passes no --resume, --continue, --session-id, or --connect.'))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter points COPILOT_HOME, Copilot cache, HOME, USERPROFILE, and XDG roots at the run''s isolated home, disables built-in MCP servers, and preserves only staged repository-owned custom instructions; personal Copilot skills, plugins, MCP config, sessions, memories, and instructions are not imported.'))
    $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "-C $($run.WorkingDirectoryPath); COPILOT_HOME under $($run.HomeDirectoryPath)"))
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail 'The prepared UTF-8 prompt bytes are supplied once through stdin; the execution fake proves the received bytes match the staged prompt.'))
    $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only supported authentication state is made available to Copilot; --secret-env-vars removes every listed token variable from shell and MCP child environments; no Copilot profile or credential file is copied.'))
    $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status unavailable -Detail 'Behavioral eval transport is the runner-owned direct Copilot session; preflight cannot yet observe that session''s resolved model, cwd, HOME/config, fresh identity, prompt, exclusions, or terminal capture, so those controls stay conditional until execute captures the session''s terminal evidence. Copilot''s native task/general-purpose subagent remains a separate advertised capability and is not the transport.'))
    $warnings.Add('Copilot runner-owned session controls are conditional. Execution must capture the session''s own terminal evidence (model, cwd, isolated COPILOT_HOME, fresh session, prompt hash, transcript); the native task/general-purpose subagent is a harness capability, not the benchmark transport.')
    if ($platform -eq 'macos') {
        $warnings.Add('macOS sandbox-exec is deprecated by Apple but is used only when present; a future runner revision may replace it with an equivalent supported mechanism.')
    }
    $hardConfinement = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-CopilotCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'GitHub Copilot CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('runner-owned fresh Copilot CLI session per eval execution', 'copilot --output-format json terminal event capture', 'native task/general-purpose subagent available as a separate harness capability, not the transport', 'prompt on stdin', '--allow-all-tools broad tool approval', 'path and URL verification preserved (no --allow-all-paths/--allow-all-urls)', '--no-ask-user', 'repository-owned custom instructions preserved', '--disable-builtin-mcps', '--secret-env-vars shell/MCP child filtering', 'isolated COPILOT_HOME and COPILOT_CACHE_HOME', 'isolated HOME/XDG roots', 'OS-keychain authentication delegated to Copilot', 'GitHub CLI fallback token resolved by the trusted runner when needed', 'no host GH_CONFIG_DIR exposed to the worker', 'no session continuation')) { $mechanisms.Add($mechanism) }
    if ($hardConfinement) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    return New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
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

    foreach ($event in @($Parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $Warnings.Add('Copilot emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        $data = Get-JsonProperty -Object $event -Name 'data' -Default $null
        switch ($eventType) {
            'assistant.message' {
                $content = [string](Get-JsonProperty -Object $data -Name 'content' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    $assistantContents.Add($content)
                    $finalText = $content
                }
                $model = [string](Get-JsonProperty -Object $data -Name 'model' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($model)) { $observedModel = $model }
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
                if (-not [string]::IsNullOrWhiteSpace($model)) { $observedModel = $model }
            }
            'tool.execution_start' { $toolStarts++ }
            'session.error' { $sessionError = [string](Get-JsonProperty -Object $data -Name 'message' -Default 'Copilot reported a session error.') }
            { $_ -in @('session.start', 'session.info', 'session.idle', 'session.shutdown', 'session.task_complete', 'user.message', 'assistant.message_start', 'assistant.message_delta', 'assistant.turn_start', 'assistant.turn_end', 'assistant.reasoning', 'assistant.tool_call_delta', 'tool.execution_progress', 'tool.execution_partial_result', 'tool.execution_complete', 'command.execute', 'command.completed', 'session.usage_info', 'session.usage_checkpoint') } { }
            default { $Warnings.Add("Unknown Copilot event '$eventType' was preserved as a warning.") }
        }
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
    }
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
