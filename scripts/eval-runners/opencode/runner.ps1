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
        mechanism = 'Runner-owned OpenCode one-shot session (opencode run --format json): the runner starts one fresh OpenCode session per eval execution, delivers the prompt on stdin, and captures the structured session events as terminal evidence'
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
    if ($null -ne $run.Interaction) {
        $checks.Add((New-PreflightCheck -Name 'scripted_multi_turn_same_session' -Status failed -Detail 'The installed OpenCode transport is intentionally fresh one-shot execution. No model-free proof of a supported same-session continuation API is available.'))
        $reasons.Add('scripted_multi_turn_same_session is incompatible: the current OpenCode CLI adapter intentionally avoids resume/session continuation and cannot prove a same-session structured transport; no second independent process is permitted.')
    }
    if ($null -eq $commandInfo) {
        $reasons.Add('The OpenCode CLI executable is not available on PATH.')
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
                $reasons.Add("OpenCode run --help failed with exit status $($help.ExitCode).")
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
            }
        } catch {
            $reasons.Add("Could not inspect OpenCode CLI capabilities: $($_.Exception.Message)")
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
    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The adapter starts one new opencode run process and supplies no resume, continue, or session id.'))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter isolates global/user configuration roots and deliberately preserves repository-owned project configuration; OPENCODE_DISABLE_PROJECT_CONFIG is not used.'))
    $checks.Add((New-PreflightCheck -Name 'prompt_fidelity' -Status passed -Detail 'The exact prompt bytes are sent on stdin as the first and only task input.'))
    $checks.Add((New-PreflightCheck -Name 'native_worker_delegation' -Status unavailable -Detail 'Behavioral eval transport is the runner-owned direct OpenCode session; preflight cannot yet observe that session''s resolved model, cwd, HOME/config, fresh identity, prompt, exclusions, or terminal capture, so those controls stay conditional until execute captures the session''s terminal evidence. OpenCode''s native Task/General subagent (and read-only Explore/Scout) remain separate advertised capabilities and are not the transport.'))
    $warnings.Add('OpenCode runner-owned session controls are conditional. Execution must capture the session''s own terminal evidence (model, cwd, isolated OPENCODE_CONFIG_DIR/HOME, fresh session, prompt hash, transcript); the native Task/General subagent is a harness capability, not the benchmark transport.')
    $warnings.Add('OpenCode does not expose a supported child-tool environment filter in this CLI contract; the runner removes unrelated inherited variables but cannot independently prove that the selected provider credential is hidden from every OpenCode-launched tool.')

    $hardConfinement = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-OpenCodeCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement
    if ($platform -eq 'macos') {
        $warnings.Add('macOS sandbox-exec is deprecated by Apple but is used only when present; a future runner revision may replace it with an equivalent supported mechanism.')
    }
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'OpenCode CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('runner-owned fresh OpenCode session per eval execution', 'opencode run --format json terminal event capture', 'native Task/General subagent available as a separate harness capability, not the transport', 'deterministic runner-owned concurrent fan-out', '--auto', 'isolated OPENCODE_CONFIG_DIR', 'isolated OPENCODE_CONFIG', 'isolated HOME/XDG roots', 'repository-owned project configuration preserved', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    if ($hardConfinement) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    return New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
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
