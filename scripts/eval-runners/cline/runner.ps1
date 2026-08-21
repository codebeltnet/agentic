<#!
.SYNOPSIS
    Cline Eval Runner adapter.

.DESCRIPTION
    The adapter uses Cline's supported headless JSON/NDJSON surface. It starts
    one fresh process per arm, supplies the prompt on stdin, uses run-local
    data/config and hooks directories, and never supplies a session id.
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
    name = 'cline'
    version = '0.9.1'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'Cline CLI'; version = 'unavailable' }
    capabilities = [ordered]@{
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
        cost_telemetry = 'conditional'
        credential_child_filtering = 'conditional'
        native_skill_activation_evidence = 'unsupported'
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

function Resolve-ClineInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    return [pscustomobject]@{
        Run = Resolve-RunContract -RunPath $Run
        Profile = Resolve-ExecutionProfile -ProfilePath $Profile
    }
}

function Invoke-ClineCli {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment,
        [byte[]]$InputBytes = @(),
        [int]$TimeoutSeconds = 60
    )

    return Invoke-RunnerProcess -FileName $CommandInfo.FileName -ArgumentList (@($CommandInfo.Prefix) + @($Arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
}

function Get-ClineDescriptor {
    $copy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $copy[$key] = $descriptor[$key] }
    $commandInfo = Resolve-ExternalCommand -Name 'cline'
    $version = 'unavailable'
    if ($null -ne $commandInfo) {
        $observation = Get-ExternalCommandVersion -CommandInfo $commandInfo
        $version = [string]$observation.Version
    }
    $copy.harness = [ordered]@{ name = 'Cline CLI'; version = $version }
    return $copy
}

function New-ClineEnvironment {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $clineRoot = Join-Path $Inputs.Run.HomeDirectoryPath '.cline'
    $dataDirectory = Join-Path $clineRoot 'data'
    $settingsDirectory = Join-Path $dataDirectory 'settings'
    $sandboxDataDirectory = Join-Path $clineRoot 'sandbox-data'
    $teamDataDirectory = Join-Path $dataDirectory 'teams'
    $hooksDirectory = Join-Path $clineRoot 'hooks'
    foreach ($directory in @($clineRoot, $dataDirectory, $settingsDirectory, $sandboxDataDirectory, $teamDataDirectory, $hooksDirectory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return [pscustomobject]@{
        Environment = New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider)) -Additional @{
            CLINE_DATA_DIR = $dataDirectory
            CLINE_SANDBOX_DATA_DIR = $sandboxDataDirectory
            CLINE_HOOKS_DIR = $hooksDirectory
            CLINE_SESSION_BACKEND_MODE = 'local'
        }
        Root = $clineRoot
        DataDirectory = $dataDirectory
        SettingsDirectory = $settingsDirectory
        SandboxDataDirectory = $sandboxDataDirectory
        TeamDataDirectory = $teamDataDirectory
        HooksDirectory = $hooksDirectory
        ConfigPath = $clineRoot
    }
}

function Get-ClineInsideEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$EnvironmentData
    )

    $inside = [ordered]@{
        HOME = '/run/home'
        USERPROFILE = '/run/home'
        XDG_CONFIG_HOME = '/run/home/.config'
        XDG_DATA_HOME = '/run/home/.local/share'
        XDG_CACHE_HOME = '/run/home/.cache'
        TEMP = '/run/home/tmp'
        TMP = '/run/home/tmp'
        CLINE_DATA_DIR = '/run/home/.cline/data'
        CLINE_SANDBOX_DATA_DIR = '/run/home/.cline/sandbox-data'
        CLINE_HOOKS_DIR = '/run/home/.cline/hooks'
        CLINE_SESSION_BACKEND_MODE = 'local'
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    foreach ($name in @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider))) {
        if ($EnvironmentData.Environment.Contains($name) -and -not [string]::IsNullOrWhiteSpace([string]$EnvironmentData.Environment[$name])) {
            $inside[$name] = [string]$EnvironmentData.Environment[$name]
        }
    }
    return $inside
}

function New-ClineCliArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$EnvironmentData,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform = (Get-PlatformName)
    )

    $workingDirectory = Get-SandboxVisiblePath -HostPath $Inputs.Run.WorkingDirectoryPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $configPath = Get-SandboxVisiblePath -HostPath $EnvironmentData.ConfigPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $dataRoot = Get-SandboxVisiblePath -HostPath $EnvironmentData.DataDirectory -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $hooksDirectory = Get-SandboxVisiblePath -HostPath $EnvironmentData.HooksDirectory -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--json', '--auto-approve', 'true', '--cwd', $workingDirectory, '--config', $configPath, '--data-dir', $dataRoot, '--hooks-dir', $hooksDirectory, '--provider', $Inputs.Profile.Provider, '--model', $Inputs.Profile.Model, '--retries', '0', '--timeout', [string]$Inputs.Profile.TimeoutSeconds)) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments.Add('--thinking')
        $arguments.Add([string]$Inputs.Profile.ReasoningEffort)
    }
    return @($arguments)
}

function Get-ClineCapabilityMap {
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
    return $capabilities
}

function Get-ClinePreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $platform = Get-PlatformName
    $commandInfo = Resolve-ExternalCommand -Name 'cline'
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-ExternalCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-ExternalCommand -Name 'sandbox-exec' } else { $null }
    $versionObservation = $null

    if ($profile.Runner -ne 'cline') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than cline.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is cline.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Provider)) {
        $reasons.Add('Cline requires a provider in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'provider' -Status passed -Detail $profile.Provider))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('Cline requires a model in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail $profile.Model))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') { $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by cline.") }
    if ($profile.ToolProfile -ne 'default') { $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by cline.") }

    $environmentData = New-ClineEnvironment -Inputs $Inputs
    if ($null -eq $commandInfo) {
        $reasons.Add('The Cline CLI executable is not available on PATH.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment $environmentData.Environment -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The Cline CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'cline --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }
            $help = Invoke-ClineCli -CommandInfo $commandInfo -Arguments @('--retries', '0', '--help') -Inputs $Inputs -Environment $environmentData.Environment -TimeoutSeconds 30
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $reasons.Add("Cline --retries 0 --help failed with exit status $($help.ExitCode).")
            } else {
                $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
                foreach ($flag in @('--json', '--auto-approve', '--cwd', '--config', '--data-dir', '--hooks-dir', '--provider', '--model', '--thinking', '--timeout', '--retries')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) { $reasons.Add("The installed Cline CLI does not advertise required flag '$flag'.") }
                }
                $visiblePlatform = if ($platform -eq 'linux' -and $null -ne $sandboxInfo) { 'linux' } else { $platform }
                $constructed = New-ClineCliArguments -Inputs $Inputs -EnvironmentData $environmentData -VisiblePlatform $visiblePlatform
                foreach ($forbidden in @('--id', '--continue', '--session', '--yolo', '--zen', '--tui')) {
                    if (@($constructed) -contains $forbidden) { $reasons.Add("The constructed Cline invocation must not use resume or interactive option '$forbidden'.") }
                }
                $retryIndex = [Array]::IndexOf([string[]]$constructed, '--retries')
                if ($retryIndex -lt 0 -or $constructed[$retryIndex + 1] -ne '0') { $reasons.Add('The constructed Cline invocation must set --retries 0.') }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'Cline advertises JSON/NDJSON output, isolated directories, provider/model selection, timeout, thinking, auto-approval, and zero internal retries.'))
                }
            }
        } catch {
            $reasons.Add("Could not inspect Cline CLI capabilities: $($_.Exception.Message)")
        }
    }

    $authVariables = @(Get-ProviderAuthenticationVariables -Provider ([string]$profile.Provider))
    $authVariable = $null
    foreach ($name in $authVariables) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { $authVariable = $name; break }
    }
    if ([string]::IsNullOrWhiteSpace($authVariable)) {
        $reasons.Add("No narrow provider authentication environment variable is available for '$($profile.Provider)'; ambient Cline auth profiles are not copied into an eval run.")
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
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $($sandboxInfo.Source) confines Cline to the staged run and run-local data/config roots."))
    }
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The adapter starts one new Cline process, supplies no --id, and never reuses a session.'))
    $checks.Add((New-PreflightCheck -Name 'retry_semantics' -Status passed -Detail '--retries 0 disables Cline consecutive operational retries; the runner still starts exactly one semantic process with attempt_count=1.'))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'HOME, Cline data/config, hooks, sessions, and plugin roots are run-local and empty; no ambient user profile is copied.'))
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail 'The exact prompt bytes are sent on stdin as the first and only task input.'))
    $warnings.Add('Cline does not expose a supported child-tool environment filter in this CLI contract; the runner removes unrelated inherited variables but cannot independently prove that the selected provider credential is hidden from every Cline-launched tool.')

    $hardConfinement = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-ClineCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'Cline CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('cline --json', '--auto-approve true', '--retries 0', 'no --id session resume', 'run-local HOME', 'run-local Cline data/config/hooks directories', 'prompt on stdin')) { $mechanisms.Add($mechanism) }
    if ($hardConfinement) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    return New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
}

function Write-ClineCapture {
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

function Invoke-ClineExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-ClinePreflight -Inputs $Inputs
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $executionDescriptor = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $executionDescriptor[$key] = $descriptor[$key] }
    $executionDescriptor.harness = $preflight.harness
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message ([string]::Join('; ', @($preflight.reasons)))) -SessionId $sessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight; resume = $false; session_id_supplied = $false }) -AttemptCount 1
    }

    $commandInfo = Resolve-ExternalCommand -Name 'cline'
    $environmentData = New-ClineEnvironment -Inputs $Inputs
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-ExternalCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-ExternalCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $arguments = New-ClineCliArguments -Inputs $Inputs -EnvironmentData $environmentData -VisiblePlatform $visiblePlatform
    if ($platform -eq 'linux' -and $hardFilesystem) {
        $insideEnvironment = Get-ClineInsideEnvironment -Inputs $Inputs -EnvironmentData $environmentData
        $sandboxArguments = Get-LinuxEvalSandboxArguments -Inputs $Inputs -CommandInfo $commandInfo -InsideEnvironment $insideEnvironment -ReadOnlyRoots @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/lib64', '/libexec', '/etc', '/opt')
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environmentData.Environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } elseif ($platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-MacosEvalSandboxProfile -Inputs $Inputs -CommandInfo $commandInfo -ReadOnlyRoots @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/libexec', '/System', '/Library', '/opt', '/private/var/db')
        $sandboxArguments = @('-f', $sandboxProfile, '--', $commandInfo.FileName) + @($commandInfo.Prefix) + @($arguments)
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environmentData.Environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } else {
        $process = Invoke-ClineCli -CommandInfo $commandInfo -Arguments $arguments -Inputs $Inputs -Environment $environmentData.Environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    }

    $stdoutArtifact = Write-ClineCapture -RunData $Inputs -RelativePath 'evidence/cline-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-ClineCapture -RunData $Inputs -RelativePath 'evidence/cline-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact); $artifacts.Add($stderrArtifact)
    $parsed = ConvertFrom-JsonLines -Text $process.Stdout
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("Cline event parse error: $parseError") }
    $eventCounts = @{}
    $contentEnd = [System.Collections.Generic.List[string]]::new()
    $contentStart = [System.Collections.Generic.List[string]]::new()
    $jsonText = [System.Collections.Generic.List[string]]::new()
    $jsonPartialText = [System.Collections.Generic.List[string]]::new()
    $completionResultText = [System.Collections.Generic.List[string]]::new()
    $finalText = $null
    $returnedSessionId = $null
    $failureMessage = $null
    $usage = [ordered]@{}
    $toolCalls = [System.Collections.Generic.List[object]]::new()
    $commands = [System.Collections.Generic.List[object]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($event in @($parsed.Events)) {
        $topType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($topType)) {
            $warnings.Add('Cline emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($topType)) { $eventCounts[$topType]++ } else { $eventCounts[$topType] = 1 }
        $inner = Get-JsonProperty -Object $event -Name 'event' -Default $null
        $eventType = if ($topType -eq 'agent_event' -and $null -ne $inner) { [string](Get-JsonProperty -Object $inner -Name 'type' -Default '') } else { $topType }
        $payload = if ($topType -eq 'agent_event' -and $null -ne $inner) { $inner } else { $event }

        if ($topType -in @('say', 'ask')) {
            $subtypeName = if ($topType -eq 'say') { 'say' } else { 'ask' }
            $subtype = [string](Get-JsonProperty -Object $event -Name $subtypeName -Default '')
            $text = [string](Get-JsonProperty -Object $event -Name 'text' -Default '')
            $isPartial = [bool](Get-JsonProperty -Object $event -Name 'partial' -Default $false)
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                if ($subtype -eq 'completion_result') { $completionResultText.Add($text) }
                elseif ($subtype -eq 'text') {
                    if ($isPartial) { $jsonPartialText.Add($text) } else { $jsonText.Add($text) }
                }
            }
            if ($topType -eq 'ask') {
                if ($subtype -eq 'api_req_failed') {
                    $failureMessage = if ([string]::IsNullOrWhiteSpace($text)) { 'Cline reported an API request failure.' } else { $text }
                } elseif ($subtype -in @('followup', 'plan_mode_respond', 'act_mode_respond')) {
                    $failureMessage = 'Cline requested interactive input during a noninteractive eval run.'
                } elseif ($subtype -in @('use_mcp_server', 'command', 'tool')) {
                    $toolCalls.Add([ordered]@{ type = $subtype; name = $subtype })
                    if ($subtype -eq 'command' -and -not [string]::IsNullOrWhiteSpace($text)) {
                        $commands.Add([ordered]@{ command = $text })
                    }
                }
            } elseif ($subtype -in @('tool', 'command', 'command_output', 'mcp_server_request_started', 'mcp_server_response')) {
                $toolName = [string](Get-JsonProperty -Object $event -Name 'name' -Default (Get-JsonProperty -Object $event -Name 'tool' -Default ''))
                $toolCalls.Add([ordered]@{ type = $subtype; name = $toolName })
                if ($subtype -eq 'command' -and -not [string]::IsNullOrWhiteSpace($text)) {
                    $commands.Add([ordered]@{ command = $text })
                }
            }
            if ($subtype -eq 'completion_result' -and -not [string]::IsNullOrWhiteSpace($text)) {
                $finalText = $text
            }
            if ($subtype -eq 'api_req_finished' -and -not [string]::IsNullOrWhiteSpace($text)) {
                try {
                    $finishedUsage = $text | ConvertFrom-Json
                    foreach ($name in @('inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost')) {
                        $value = Get-JsonProperty -Object $finishedUsage -Name $name -Default $null
                        if ($null -ne $value) { $usage[$name] = $value }
                    }
                } catch {
                    $warnings.Add('Cline api_req_finished text was not a usage JSON object; it was retained in the transcript.')
                }
            }
            if ($subtype -notin @('task', 'error', 'api_req_started', 'api_req_finished', 'api_req_retried', 'api_req_retry_delayed', 'api_req_deleted', 'text', 'reasoning', 'completion_result', 'user_feedback', 'user_feedback_diff', 'command_output', 'tool', 'shell_integration_warning', 'browser_action', 'browser_action_result', 'command', 'mcp_server_request_started', 'mcp_server_response', 'new_task_started', 'new_task', 'subtask_result', 'checkpoint_saved', 'rooignore_error', 'diff_error', 'followup', 'plan_mode_respond', 'act_mode_respond', 'api_req_failed', 'use_mcp_server', 'resume_task', 'resume_completed_task', 'mistake_limit_reached', 'finishTask')) {
                $warnings.Add("Unknown Cline $topType subtype '$subtype' was preserved as a warning.")
            }
            continue
        }
        switch ($eventType) {
            'done' {
                $candidate = Get-JsonProperty -Object $payload -Name 'text' -Default ''
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { $finalText = [string]$candidate }
                $returnedSessionId = [string](Get-JsonProperty -Object $payload -Name 'sessionId' -Default (Get-JsonProperty -Object $payload -Name 'session_id' -Default $returnedSessionId))
                $doneUsage = Get-JsonProperty -Object $payload -Name 'usage' -Default $null
                if ($null -ne $doneUsage) {
                    foreach ($name in @('inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost')) {
                        $value = Get-JsonProperty -Object $doneUsage -Name $name -Default $null
                        if ($null -ne $value) { $usage[$name] = $value }
                    }
                }
            }
            'content_end' { $text = [string](Get-JsonProperty -Object $payload -Name 'text' -Default ''); if (-not [string]::IsNullOrWhiteSpace($text)) { $contentEnd.Add($text) } }
            'content_start' { $text = [string](Get-JsonProperty -Object $payload -Name 'text' -Default ''); if (-not [string]::IsNullOrWhiteSpace($text)) { $contentStart.Add($text) } }
            'usage' {
                foreach ($name in @('inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost')) {
                    $value = Get-JsonProperty -Object $payload -Name $name -Default $null
                    if ($null -ne $value) { $usage[$name] = $value }
                }
            }
            'tool_call' { $toolCalls.Add([ordered]@{ type = $eventType; name = [string](Get-JsonProperty -Object $payload -Name 'name' -Default (Get-JsonProperty -Object $payload -Name 'tool' -Default '')) }) }
            'tool_use' { $toolCalls.Add([ordered]@{ type = $eventType; name = [string](Get-JsonProperty -Object $payload -Name 'name' -Default (Get-JsonProperty -Object $payload -Name 'tool' -Default '')) }) }
            'command' { $commands.Add([ordered]@{ command = Get-JsonProperty -Object $payload -Name 'command' -Default (Get-JsonProperty -Object $payload -Name 'text' -Default '') }) }
            'file' { $files.Add([ordered]@{ path = Get-JsonProperty -Object $payload -Name 'path' -Default '' }) }
            'error' { $failureMessage = [string](Get-JsonProperty -Object $payload -Name 'message' -Default 'Cline emitted an error.') }
            'hook_event' { }
            'agent_start' { }
            'agent_end' { }
            'iteration_start' { }
            'iteration_end' { }
            default { $warnings.Add("Unknown Cline event '$topType/$eventType' was preserved as a warning.") }
        }
        if ($eventType -eq 'usage') {
            $eventUsage = Get-JsonProperty -Object $payload -Name 'usage' -Default $null
            if ($null -ne $eventUsage) {
                foreach ($name in @('inputTokens', 'outputTokens', 'totalTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost')) {
                    $value = Get-JsonProperty -Object $eventUsage -Name $name -Default $null
                    if ($null -ne $value) { $usage[$name] = $value }
                }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($finalText)) {
        if ($contentEnd.Count -gt 0) { $finalText = [string]::Join('', @($contentEnd)) }
        elseif ($contentStart.Count -gt 0) { $finalText = [string]::Join('', @($contentStart)) }
        elseif ($completionResultText.Count -gt 0) { $finalText = [string]$completionResultText[$completionResultText.Count - 1] }
        elseif ($jsonText.Count -gt 0) { $finalText = [string]$jsonText[$jsonText.Count - 1] }
        elseif ($jsonPartialText.Count -gt 0) { $finalText = [string]::Join('', @($jsonPartialText)) }
    }

    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'; $reason = 'cline_timeout'; $failure = New-ExecutionFailure -Code 'timed_out' -Message 'Cline did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $failureMessage) {
        $failureDetail = if ([string]::IsNullOrWhiteSpace($failureMessage)) { 'Cline exited unsuccessfully.' } else { $failureMessage }
        $status = 'failed'; $reason = 'cline_failure'; $failure = New-ExecutionFailure -Code 'cline_failure' -Message $failureDetail
    } elseif ([string]::IsNullOrWhiteSpace($finalText)) {
        $reason = 'cline_did_not_return_final_response'; $warnings.Add('Cline exited successfully without a final response event.')
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/cline-events.jsonl'; complete = $true })
        tokens = if ($usage.Count -eq 0) { New-UnavailableMetric -Reason 'cline_did_not_expose_usage' } else { New-AvailableMetric -Value $usage }
        tool_calls = New-AvailableMetric -Value $toolCalls.Count
        cost = if ($usage.Contains('cost')) { New-AvailableMetric -Value $usage['cost'] } else { New-UnavailableMetric -Reason 'cline_did_not_expose_cost' }
    }
    $finished = [DateTime]::UtcNow
    $capabilities = Get-ClineCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('cline --json', '--auto-approve true', '--retries 0', 'no --id session resume', 'run-local HOME', 'run-local Cline data/config/hooks directories', 'prompt on stdin')) { $mechanisms.Add($mechanism) }
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement'); $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $credentialEvidence = [ordered]@{
        provider_environment_variables = @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider))
        unrelated_environment_excluded = $true
        child_tool_visibility = 'not_exposed_by_runner_environment; Cline child filtering is not independently observable'
        value_observed = $false
    }
    $sessionResultId = if ([string]::IsNullOrWhiteSpace($returnedSessionId)) { $sessionId } else { $returnedSessionId }
    $sandboxEvidence = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
    return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionResultId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'Cline accepted the requested provider, model, thinking, and configuration but did not expose concrete backend resolution.'; observations = [ordered]@{ provider = $Inputs.Profile.Provider; model = $Inputs.Profile.Model; reasoning_effort = $Inputs.Profile.ReasoningEffort; retries = 0 } }) -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence ([ordered]@{ event_counts = $eventCounts; commands = @($commands); files = @($files); prompt_first_input = $true; resume = $false; session_id_supplied = $false; retry_argument = 0; sandbox = $sandboxEvidence; credential = $credentialEvidence }) -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-ClineDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-ClineInputs
            Write-RunnerJson -Value (Get-ClinePreflight -Inputs $inputs) -AsOutput
        }
        'execute' {
            $inputs = Resolve-ClineInputs
            $result = Invoke-ClineExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
