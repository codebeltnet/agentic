<#!
.SYNOPSIS
    OpenCode Eval Runner adapter.

.DESCRIPTION
    This is the only place where OpenCode CLI flags, pure configuration,
    sandbox process setup, and JSON event parsing are defined.
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
    platforms = @('linux', 'macos')
    harness = [ordered]@{ name = 'OpenCode CLI'; version = 'current-supported' }
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
        tool_call_telemetry = 'supported'
        command_evidence = 'conditional'
        file_evidence = 'conditional'
        cost_telemetry = 'conditional'
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

function Resolve-SandboxCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Resolve-ExternalCommand -Name $Name
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

    if ($profile.Runner -ne 'opencode') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than opencode.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is opencode.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Provider)) {
        $reasons.Add('OpenCode requires a provider in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'provider' -Status passed -Detail $profile.Provider))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('OpenCode requires a model in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail ("{0}/{1}" -f $profile.Provider, $profile.Model)))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by opencode.")
    }
    if ($profile.ToolProfile -ne 'default') {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by opencode.")
    }
    if ($null -eq $commandInfo) {
        $reasons.Add('The OpenCode CLI executable is not available on PATH.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $help = Get-OpenCodeHelpResult -CommandInfo $commandInfo -Inputs $Inputs
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $reasons.Add("OpenCode run --help failed with exit status $($help.ExitCode).")
            } else {
                $helpText = [string]::Join("`n", @($help.Stdout, $help.Stderr))
                foreach ($flag in @('--pure', '--format', '--dir', '--model', '--auto')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed OpenCode CLI does not advertise required flag '$flag'.")
                    }
                }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'OpenCode run advertises pure, noninteractive, model, directory, and structured-output controls.'))
                }
            }
        } catch {
            $reasons.Add("Could not inspect OpenCode CLI capabilities: $($_.Exception.Message)")
        }
    }

    $authVariable = if ([string]::IsNullOrWhiteSpace($profile.Provider)) { $null } else { Get-OpenCodeAuthVariable -Provider ([string]$profile.Provider) }
    if ([string]::IsNullOrWhiteSpace($authVariable)) {
        $reasons.Add("No narrow provider authentication environment variable is available for '$($profile.Provider)'. OpenCode global auth profiles are not copied into an eval run.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail "Provider credential will be passed only as $authVariable."))
    }

    if ($platform -notin @('linux', 'macos')) {
        $reasons.Add("Platform '$platform' has no v0.9.1 OpenCode filesystem sandbox implementation.")
    } elseif ($null -eq $sandboxInfo) {
        $reasons.Add("Required $([string]$(if ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' })) isolation command is unavailable.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $($sandboxInfo.Source) sandbox confines the process to the staged run and required system runtime paths."))
    }
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The adapter starts one new opencode run process and supplies no resume, continue, or session id.'))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter uses --pure and isolated OpenCode configuration roots.'))
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail 'The exact prompt bytes are sent on stdin as the first and only task input.'))

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $value = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName)
        if ($capabilityName -eq 'filesystem_confinement' -and $null -ne $sandboxInfo -and $platform -in @('linux', 'macos') -and $reasons.Count -eq 0) {
            $value = 'supported'
        } elseif ($capabilityName -eq 'filesystem_confinement') {
            $value = 'unsupported'
        }
        $capabilities[$capabilityName] = $value
    }
    if ($platform -eq 'macos') {
        $warnings.Add('macOS sandbox-exec is deprecated by Apple but is used only when present; a future runner revision may replace it with an equivalent supported mechanism.')
    }
    $harnessVersion = if ($null -eq $commandInfo) { 'unavailable' } else { 'available' }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'OpenCode CLI'; version = $harnessVersion }
    return New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @('--pure', 'isolated OPENCODE_CONFIG_DIR', 'external filesystem sandbox', 'prompt on stdin', 'no session continuation') -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
}

function New-OpenCodeEnvironment {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $configDirectory = Join-Path $Inputs.Run.HomeDirectoryPath 'opencode-config'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $configPath = Join-Path $configDirectory 'opencode.json'
    [System.IO.File]::WriteAllText($configPath, '{}', [System.Text.UTF8Encoding]::new($false))
    return New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider)) -Additional @{
        OPENCODE_CONFIG_DIR = $configDirectory
        OPENCODE_CONFIG = $configPath
        OPENCODE_DISABLE_AUTOUPDATE = '1'
        OPENCODE_DISABLE_PROJECT_CONFIG = '1'
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
        XDG_CONFIG_HOME = '/run/home/.config'
        XDG_DATA_HOME = '/run/home/.local/share'
        XDG_CACHE_HOME = '/run/home/.cache'
        TEMP = '/run/home/tmp'
        TMP = '/run/home/tmp'
        OPENCODE_CONFIG_DIR = '/run/home/opencode-config'
        OPENCODE_CONFIG = '/run/home/opencode-config/opencode.json'
        OPENCODE_DISABLE_AUTOUPDATE = [string]$Environment['OPENCODE_DISABLE_AUTOUPDATE']
        OPENCODE_DISABLE_PROJECT_CONFIG = [string]$Environment['OPENCODE_DISABLE_PROJECT_CONFIG']
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    foreach ($authName in @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider))) {
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
        [Parameter(Mandatory = $true)][string]$Text
    )

    $path = Join-Path $RunData.Run.RunRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    return New-ArtifactReference -Run $RunData.Run -Path $RelativePath -Scope run -MediaType (Get-MediaType -Path $RelativePath)
}

function Invoke-OpenCodeExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-OpenCodePreflight -Inputs $Inputs
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        return New-ExecutionResult -Descriptor $descriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message ([string]::Join('; ', @($preflight.reasons)))) -SessionId $sessionId -IsolationCapabilities ([ordered]@{ fresh_context = 'supported'; isolated_home_config = 'supported'; isolated_working_directory = 'supported'; filesystem_confinement = 'unsupported'; ambient_candidate_skill_exclusion = 'supported'; candidate_skill_exposure = 'supported' }) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight }) -AttemptCount 1
    }

    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    $environment = New-OpenCodeEnvironment -Inputs $Inputs
    $model = "{0}/{1}" -f $Inputs.Profile.Provider, $Inputs.Profile.Model
    $directoryArgument = if ((Get-PlatformName) -eq 'linux') { '/run/repo' } else { $Inputs.Run.WorkingDirectoryPath }
    $arguments = @('run', '--format', 'json', '--pure', '--dir', $directoryArgument, '--model', $model, '--auto')
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments += @('--variant', $Inputs.Profile.ReasoningEffort)
    }

    if ((Get-PlatformName) -eq 'linux') {
        $sandboxInfo = Resolve-SandboxCommand -Name 'bwrap'
        $sandboxArguments = Get-LinuxSandboxArguments -Inputs $Inputs -CommandInfo $commandInfo -Environment $environment
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } else {
        $sandboxInfo = Resolve-SandboxCommand -Name 'sandbox-exec'
        $sandboxProfile = New-MacosSandboxProfile -Inputs $Inputs -CommandInfo $commandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $commandInfo.FileName) + @($commandInfo.Prefix) + $arguments
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
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
    return New-ExecutionResult -Descriptor $descriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $process.FinishedUtc.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionId -IsolationCapabilities ([ordered]@{ fresh_context = 'supported'; isolated_home_config = 'supported'; isolated_working_directory = 'supported'; filesystem_confinement = 'supported'; ambient_candidate_skill_exclusion = 'supported'; candidate_skill_exposure = 'supported'; prompt_fidelity = 'supported'; model_configuration_lock = 'supported'; response_capture = 'supported' }) -IsolationMechanisms @('--pure', 'isolated OPENCODE_CONFIG_DIR', 'bwrap/sandbox-exec', 'prompt on stdin', 'no session continuation') -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence ([ordered]@{ event_counts = $eventCounts; commands = @($commands); prompt_first_input = $true; resume = $false; model_argument = $model; sandbox = if ((Get-PlatformName) -eq 'linux') { 'bwrap' } else { 'sandbox-exec' } }) -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value $descriptor -AsOutput }
        'preflight' {
            $inputs = Resolve-OpenCodeInputs
            Write-RunnerJson -Value (Get-OpenCodePreflight -Inputs $inputs) -AsOutput
        }
        'execute' {
            $inputs = Resolve-OpenCodeInputs
            $result = Invoke-OpenCodeExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
