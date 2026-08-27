Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-UtcTimestamp {
    param([Parameter(Mandatory = $true)][DateTime]$Value)

    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-RunnerSchemaNames {
    return [ordered]@{
        Protocol = 'codebeltnet/agentic/eval-runner-protocol/1'
        Descriptor = 'codebeltnet/agentic/eval-runner-descriptor/1'
        Preflight = 'codebeltnet/agentic/eval-runner-preflight/1'
        Profile = 'codebeltnet/agentic/eval-execution-profile/1'
        Result = 'codebeltnet/agentic/eval-execution-result/1'
        PortableResult = 'codebeltnet/agentic/eval-result/2'
        Run = 'codebeltnet/agentic/eval-run/1'
        OrchestrationPlan = 'codebeltnet/agentic/eval-orchestration-plan/1'
        Interaction = 'codebeltnet/agentic/eval-interaction/1'
        ExecutionFreeze = 'codebeltnet/agentic/eval-execution-freeze/1'
        Grading = 'codebeltnet/agentic/eval-grading/1'
    }
}

function Get-PackageRunnerDescriptor {
    param([Parameter(Mandatory = $true)][string]$RunnerName)

    if ($RunnerName -notmatch '^[a-z0-9-]+$') {
        throw "execution-profile.json runner '$RunnerName' is not a valid package runner name."
    }

    $runnerPath = Join-Path (Join-Path $PSScriptRoot $RunnerName) 'runner.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
        throw "Package-local runner '$RunnerName' is missing its runner.ps1 descriptor."
    }

    $descriptorOutput = & pwsh -NoProfile -File $runnerPath describe 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Package-local runner '$RunnerName' descriptor failed: $([string]::Join(' ', @($descriptorOutput)))"
    }

    try {
        $descriptor = [string]::Join([Environment]::NewLine, @($descriptorOutput)) | ConvertFrom-Json
        [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    } catch {
        throw "Package-local runner '$RunnerName' returned an invalid descriptor: $($_.Exception.Message)"
    }

    if ([string]$descriptor.name -ne $RunnerName) {
        throw "Package-local runner descriptor name '$($descriptor.name)' does not match selected runner '$RunnerName'."
    }

    return $descriptor
}

function Get-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        if ($null -ne $Object[$Name]) {
            return $Object[$Name]
        }
        return $Default
    }

    if ($null -ne $Object -and @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name }) -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $Default
}

function Get-JsonPropertyNames {
    param([object]$Object)

    if ($null -eq $Object) {
        return @()
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-JsonWithoutProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Object.Keys) {
            if ([string]$key -ne $PropertyName) { $copy[[string]$key] = $Object[$key] }
        }
        return $copy
    }
    $copyObject = [ordered]@{}
    foreach ($property in @($Object.PSObject.Properties)) {
        if ([string]$property.Name -ne $PropertyName) { $copyObject[[string]$property.Name] = $property.Value }
    }
    return $copyObject
}

function ConvertTo-CanonicalJsonValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $canonical = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $canonical[$key] = ConvertTo-CanonicalJsonValue -Value $Value[$key]
        }
        return $canonical
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $canonical = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $canonical.Add((ConvertTo-CanonicalJsonValue -Value $item)) }
        return @($canonical.ToArray())
    }
    $canonicalObject = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $canonicalObject[[string]$property.Name] = ConvertTo-CanonicalJsonValue -Value $property.Value
    }
    return $canonicalObject
}

function Get-JsonFingerprint {
    param([Parameter(Mandatory = $true)][object]$Object)

    $json = ConvertTo-CanonicalJsonValue -Value $Object | ConvertTo-Json -Depth 100 -Compress
    return Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Test-JsonProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return (Get-JsonPropertyNames -Object $Object) -contains $Name
}

function Read-RunnerJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file '$Path' does not exist."
    }

    $json = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.UTF8Encoding]::new($false))
    $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
        return $json | ConvertFrom-Json -DateKind String
    }

    # DateKind was added after the oldest supported PowerShell 7 releases.
    # Keep those versions usable; the canonical writers still emit UTC strings.
    return $json | ConvertFrom-Json
}

function Write-RunnerJson {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [switch]$AsOutput
    )

    $json = ((ConvertTo-Json -InputObject $Value -Depth 100) + [Environment]::NewLine)
    if ($AsOutput) {
        [Console]::Out.Write($json)
        return
    }

    return $json
}

function Get-Sha256HexFromBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-Sha256HexFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return Get-Sha256HexFromBytes -Bytes ([System.IO.File]::ReadAllBytes($resolved))
}

function Test-Sha256 {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9a-fA-F]{64}$'
}

function Expand-WindowsShortPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $IsWindows -or [string]::IsNullOrWhiteSpace($Path)) { return $Path }
    try {
        # Windows APIs and .NET can return either the long or 8.3 spelling of
        # the same existing path.  Normalize that spelling before comparing
        # runner-observed paths; this does not resolve symlinks or authorize a
        # path outside the requested boundary.
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            # DirectoryInfo expands an 8.3 component only when that component
            # is the final component. Walk existing components so a short
            # parent such as ADMINI~1 is expanded before comparing a nested
            # runner path.
            $current = $root
            $remaining = $fullPath.Substring($root.Length) -split '[\\/]'
            for ($componentIndex = 0; $componentIndex -lt $remaining.Count; $componentIndex++) {
                $component = [string]$remaining[$componentIndex]
                if ([string]::IsNullOrWhiteSpace($component)) { continue }
                $next = Join-Path -Path $current -ChildPath $component
                if (Test-Path -LiteralPath $next -PathType Container) {
                    $current = ([System.IO.DirectoryInfo]::new($next)).FullName
                } elseif (Test-Path -LiteralPath $next -PathType Leaf) {
                    $current = ([System.IO.FileInfo]::new($next)).FullName
                } else {
                    $current = Join-Path -Path $current -ChildPath $component
                    if ($componentIndex + 1 -lt $remaining.Count) {
                        $current = Join-Path -Path $current -ChildPath ([string]::Join([System.IO.Path]::DirectorySeparatorChar, @($remaining[($componentIndex + 1)..($remaining.Count - 1)] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })))
                    }
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($current)) { return $current }
        }
        if ($null -eq ([System.Management.Automation.PSTypeName]'CodebeltAgenticWin32Path').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class CodebeltAgenticWin32Path
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint longPathLength);

    public static string Expand(string path)
    {
        uint required = GetLongPathName(path, null, 0);
        if (required == 0) return path;

        var buffer = new StringBuilder((int)required + 1);
        uint written = GetLongPathName(path, buffer, (uint)buffer.Capacity);
        return written == 0 ? path : buffer.ToString();
    }
}
'@ -ErrorAction Stop | Out-Null
        }
        return [CodebeltAgenticWin32Path]::Expand($Path)
    } catch {
        return $Path
    }
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$CandidatePath
    )

    $base = ConvertTo-ComparablePath -Path $BasePath
    $candidate = ConvertTo-ComparablePath -Path $CandidatePath
    if ($null -eq $base -or $null -eq $candidate) { return $false }
    return $candidate -eq $base -or $candidate.StartsWith($base + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '^[A-Za-z]:') {
        throw "$FieldName must be a non-empty relative path."
    }

    $normalized = $RelativePath.Replace('\', '/')
    if (($normalized -split '/') -contains '..') {
        throw "$FieldName must not contain a parent-directory segment."
    }
}

function Resolve-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [ValidateSet('Any', 'File', 'Directory')][string]$Kind = 'Any'
    )

    Assert-SafeRelativePath -RelativePath $RelativePath -FieldName $FieldName
    $resolvedBase = (Resolve-Path -LiteralPath $BasePath -ErrorAction Stop).Path
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedBase ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    if (-not (Test-PathInside -BasePath $resolvedBase -CandidatePath $candidate)) {
        throw "$FieldName resolves outside the run directory."
    }

    $exists = switch ($Kind) {
        'File' { Test-Path -LiteralPath $candidate -PathType Leaf }
        'Directory' { Test-Path -LiteralPath $candidate -PathType Container }
        default { Test-Path -LiteralPath $candidate }
    }
    if (-not $exists) {
        throw "$FieldName '$RelativePath' does not exist under '$resolvedBase'."
    }

    $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    if (-not (Test-PathInside -BasePath $resolvedBase -CandidatePath $resolvedCandidate)) {
        throw "$FieldName resolves through a link outside the run directory."
    }
    return $resolvedCandidate
}

function Get-PlatformName {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    if ($IsLinux) { return 'linux' }
    return 'unknown'
}

function Get-SandboxVisiblePath {
    param(
        [Parameter(Mandatory = $true)][string]$HostPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$Platform = (Get-PlatformName),
        [string]$MountRoot = '/run'
    )

    $fullHostPath = [System.IO.Path]::GetFullPath($HostPath)
    if ($Platform -ne 'linux' -or -not (Test-PathInside -BasePath $RunRoot -CandidatePath $fullHostPath)) {
        return $fullHostPath
    }

    $relative = [System.IO.Path]::GetRelativePath(([System.IO.Path]::GetFullPath($RunRoot)), $fullHostPath).Replace('\', '/')
    if ($relative -eq '.') {
        return $MountRoot.TrimEnd('/')
    }
    return $MountRoot.TrimEnd('/') + '/' + $relative.TrimStart('/')
}

function Get-ObservableVersionFromText {
    param([string]$Text)

    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            return $trimmed
        }
    }
    return $null
}

function New-RunnerProbeEnvironment {
    $environment = [ordered]@{}
    foreach ($name in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'LANG', 'LC_ALL', 'TZ', 'SSL_CERT_FILE', 'NODE_PATH')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }
    $environment['CI'] = '1'
    $environment['NO_COLOR'] = '1'
    return $environment
}

function Get-ExternalCommandVersion {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [string]$WorkingDirectory = '',
        [System.Collections.IDictionary]$Environment = (New-RunnerProbeEnvironment),
        [int]$TimeoutSeconds = 30
    )

    $probeDirectory = $WorkingDirectory
    $ownsProbeDirectory = $false
    if ([string]::IsNullOrWhiteSpace($probeDirectory)) {
        $probeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-version-probe-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
        $ownsProbeDirectory = $true
    }
    try {
        $process = Invoke-RunnerProcess -FileName $CommandInfo.FileName -ArgumentList (@($CommandInfo.Prefix) + @('--version')) -WorkingDirectory $probeDirectory -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        $text = [string]::Join("`n", @($process.Stdout, $process.Stderr))
        $version = Get-ObservableVersionFromText -Text $text
        return [pscustomobject]@{
            Version = if ($process.TimedOut -or $process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($version)) { 'unavailable' } else { $version }
            Available = (-not $process.TimedOut -and $process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($version))
            Process = $process
        }
    } catch {
        return [pscustomobject]@{ Version = 'unavailable'; Available = $false; Process = $null; Error = $_.Exception.Message }
    } finally {
        if ($ownsProbeDirectory -and (Test-Path -LiteralPath $probeDirectory)) {
            Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-IsolationCapabilityAssessment {
    param([System.Collections.IDictionary]$Capabilities)

    $required = @(
        'fresh_context',
        'isolated_home_config',
        'isolated_working_directory',
        'ambient_candidate_skill_exclusion',
        'candidate_skill_exposure',
        'prompt_fidelity',
        'model_configuration_lock',
        'response_capture'
    )
    $unproven = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required) {
        $value = if ($null -ne $Capabilities -and $Capabilities.Contains($name)) { [string]$Capabilities[$name] } else { 'unavailable' }
        $valid = if ($name -eq 'candidate_skill_exposure') { $value -in @('supported', 'excluded') } else { $value -eq 'supported' }
        if (-not $valid) { $unproven.Add($name) }
    }

    $filesystemValue = if ($null -ne $Capabilities -and $Capabilities.Contains('filesystem_confinement')) { [string]$Capabilities['filesystem_confinement'] } else { 'unavailable' }
    $hardFilesystem = $filesystemValue -eq 'supported'
    $mandatoryProven = $unproven.Count -eq 0
    return [pscustomobject]@{
        MandatoryProven = $mandatoryProven
        HardFilesystemConfinement = $hardFilesystem
        Level = if (-not $mandatoryProven) { 'unsupported' } elseif ($hardFilesystem) { 'strict' } else { 'pragmatic' }
        Unproven = $unproven.ToArray()
        Required = @($required)
    }
}

function Get-DelegationCapabilityAssessment {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [System.Collections.IDictionary]$Capabilities
    )

    $required = @(
        'native_worker_delegation',
        'delegated_worker_full_capability',
        'delegated_worker_model_lock',
        'delegated_worker_working_directory',
        'delegated_worker_result_capture',
        'delegated_worker_capacity_signal'
    )
    $unproven = [System.Collections.Generic.List[string]]::new()
    $conditional = [System.Collections.Generic.List[string]]::new()
    $unsupported = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required) {
        $value = if ($null -ne $Capabilities -and $Capabilities.Contains($name)) { [string]$Capabilities[$name] } else { 'unavailable' }
        if ($value -ne 'supported') {
            $unproven.Add($name)
            if ($value -eq 'conditional') { $conditional.Add($name) } else { $unsupported.Add($name) }
        }
    }

    $delegation = Get-JsonProperty -Object $Descriptor -Name 'delegation' -Default $null
    $dispatchOwner = [string](Get-JsonProperty -Object $delegation -Name 'dispatch_owner' -Default 'unsupported')
    if ($dispatchOwner -notin @('orchestrator', 'runner')) {
        $unproven.Add('delegation.dispatch_owner')
        $unsupported.Add('delegation.dispatch_owner')
    }
    $mode = [string](Get-JsonProperty -Object $delegation -Name 'mode' -Default 'unsupported')
    $nestedModelExecution = [bool](Get-JsonProperty -Object $delegation -Name 'nested_model_execution' -Default $true)
    $mechanism = [string](Get-JsonProperty -Object $delegation -Name 'mechanism' -Default '')
    $workerRole = [string](Get-JsonProperty -Object $delegation -Name 'worker_role' -Default '')
    $modeIsNative = $mode -eq 'native_worker'
    if (-not $modeIsNative) {
        $unproven.Add('delegation.mode')
        if ($mode -eq 'conditional') { $conditional.Add('delegation.mode') } else { $unsupported.Add('delegation.mode') }
    }
    if ($nestedModelExecution) {
        $unproven.Add('delegation.nested_model_execution')
        $unsupported.Add('delegation.nested_model_execution')
    }
    $delegationFields = [ordered]@{
        full_capability = 'delegated_worker_full_capability'
        model_lock = 'delegated_worker_model_lock'
        working_directory = 'delegated_worker_working_directory'
        result_capture = 'delegated_worker_result_capture'
        capacity = 'delegated_worker_capacity_signal'
    }
    foreach ($field in $delegationFields.Keys) {
        $value = [string](Get-JsonProperty -Object $delegation -Name $field -Default 'unsupported')
        $valid = if ($field -eq 'capacity') { $value -in @('supported', 'harness_authoritative') } else { $value -eq 'supported' }
        if (-not $valid) {
            $unproven.Add("delegation.$field")
            if ($value -eq 'conditional') { $conditional.Add("delegation.$field") } else { $unsupported.Add("delegation.$field") }
        }
    }

    $status = if ($unsupported.Count -gt 0) {
        'unsupported'
    } elseif ($conditional.Count -gt 0) {
        'conditional'
    } else {
        'supported'
    }

    return [pscustomobject]@{
        MandatoryProven = $status -eq 'supported'
        Status = $status
        DispatchOwner = $dispatchOwner
        Mode = $mode
        Mechanism = $mechanism
        WorkerRole = $workerRole
        NestedModelExecution = $nestedModelExecution
        Unproven = @($unproven)
        Conditional = @($conditional)
        Unsupported = @($unsupported)
        Required = @($required)
    }
}

function Get-NativeWorkerTerminalEvidenceRequirements {
    return @(
        'mechanism',
        'worker_session_id',
        'observed_model',
        'observed_working_directory',
        'observed_home',
        'fresh_worker',
        'home_config_isolated',
        'prompt_fidelity',
        'prompt_sha256',
        'terminal_result_capture',
        'paired_arm_visible',
        'grading_material_visible',
        'nested_model_execution',
        'model_execution_count'
    )
}

function ConvertTo-ComparablePath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $full = Expand-WindowsShortPath -Path $full
        $root = [System.IO.Path]::GetPathRoot($full)
        if (-not [string]::IsNullOrWhiteSpace($root) -and $full.Length -gt $root.Length) {
            $full = $full.TrimEnd([char[]]@('\', '/'))
        }
        return $full
    } catch {
        return $null
    }
}

function Test-ExactObservedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Observed
    )

    $expectedComparable = ConvertTo-ComparablePath -Path $Expected
    $observedComparable = ConvertTo-ComparablePath -Path $Observed
    if ($null -eq $expectedComparable -or $null -eq $observedComparable) { return $false }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    return [string]::Equals($expectedComparable, $observedComparable, $comparison)
}

function Get-NativeWorkerReportedFailures {
    param([Parameter(Mandatory = $true)][object]$ExecutionEvidence)

    $evidence = Get-JsonProperty -Object $ExecutionEvidence -Name 'evidence' -Default $null
    $reported = @(Get-JsonProperty -Object $evidence -Name 'native_worker_evidence_failures' -Default @())
    if ($reported.Count -eq 0) {
        $reported = @(Get-JsonProperty -Object $ExecutionEvidence -Name 'native_worker_evidence_failures' -Default @())
    }
    return @($reported | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Set-NativeWorkerReportedFailures {
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionEvidence,
        [Parameter(Mandatory = $true)][string[]]$Failures
    )

    $uniqueFailures = @($Failures | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $evidence = Get-JsonProperty -Object $ExecutionEvidence -Name 'evidence' -Default $null
    if ($null -ne $evidence) {
        if ($evidence -is [System.Collections.IDictionary]) {
            $evidence['native_worker_evidence_failures'] = $uniqueFailures
        } elseif (Test-JsonProperty -Object $evidence -Name 'native_worker_evidence_failures') {
            $evidence.native_worker_evidence_failures = $uniqueFailures
        } else {
            Add-Member -InputObject $evidence -MemberType NoteProperty -Name native_worker_evidence_failures -Value $uniqueFailures -Force
        }
    }
    return $uniqueFailures
}

function Test-NativeWorkerTerminalEvidence {
    <#
      Descriptor fields describe what a harness advertises. This validator is
      deliberately separate: it accepts only observations from the actual
      delegated worker for this exact arm. A direct compatibility-run result
      without evidence.delegation is therefore never native-worker evidence.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionEvidence,
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$RequestedModel,
        [string]$ExpectedWorkerSessionId = '',
        [string]$ExpectedRunner = '',
        [string]$ExpectedMechanism = ''
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $status = [string](Get-JsonProperty -Object $ExecutionEvidence -Name 'status' -Default '')
    if ($status -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
        $failures.Add('terminal_result_capture')
    }
    $runEvidence = Get-JsonProperty -Object $ExecutionEvidence -Name 'run' -Default $null
    if ($null -eq $runEvidence) {
        $failures.Add('arm_identity')
    } else {
        if ([int](Get-JsonProperty -Object $runEvidence -Name 'eval_id' -Default 0) -ne [int]$Run.EvalId -or
            [string](Get-JsonProperty -Object $runEvidence -Name 'eval_name' -Default '') -ne [string]$Run.EvalName -or
            [string](Get-JsonProperty -Object $runEvidence -Name 'configuration' -Default '') -ne [string]$Run.Mode) {
            $failures.Add('arm_identity')
        }
    }

    $requestedEvidence = Get-JsonProperty -Object $ExecutionEvidence -Name 'requested' -Default $null
    if ($null -eq $requestedEvidence -or [string](Get-JsonProperty -Object $requestedEvidence -Name 'model' -Default '') -ne $RequestedModel) {
        $failures.Add('requested_model')
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunner)) {
        $runnerEvidence = Get-JsonProperty -Object $ExecutionEvidence -Name 'runner' -Default $null
        if ($null -eq $runnerEvidence -or [string](Get-JsonProperty -Object $runnerEvidence -Name 'name' -Default '') -ne $ExpectedRunner) {
            $failures.Add('runner_identity')
        }
    }

    # Preserve runner-specific terminal codes even when the result has no
    # portable delegation object. The common validator must not erase the
    # transport's exact failure reason while reporting the missing common proof.
    $reportedFailures = @(Get-NativeWorkerReportedFailures -ExecutionEvidence $ExecutionEvidence)
    if ($status -eq 'incompatible') {
        if ($reportedFailures.Count -eq 0) {
            $failures.Add('runner_reported_incompatible')
        } else {
            foreach ($reportedFailure in $reportedFailures) { $failures.Add($reportedFailure) }
        }
    } elseif ($reportedFailures.Count -gt 0) {
        $failures.Add('runner_evidence_status_mismatch')
        foreach ($reportedFailure in $reportedFailures) { $failures.Add($reportedFailure) }
    }

    $delegation = Get-JsonProperty -Object (Get-JsonProperty -Object $ExecutionEvidence -Name 'evidence' -Default $null) -Name 'delegation' -Default $null
    if ($null -eq $delegation) {
        $failures.Add('delegation_terminal_evidence')
        return [pscustomobject]@{ Valid = $false; Failures = @($failures); Delegation = $null }
    }

    foreach ($name in @(Get-NativeWorkerTerminalEvidenceRequirements)) {
        if (-not (Test-JsonProperty -Object $delegation -Name $name)) {
            $failures.Add($name)
        }
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $delegation -Name 'mechanism' -Default ''))) {
        $failures.Add('mechanism')
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMechanism) -and
        [string](Get-JsonProperty -Object $delegation -Name 'mechanism' -Default '') -ne $ExpectedMechanism) {
        $failures.Add('native_mechanism')
    }

    $workerSessionId = [string](Get-JsonProperty -Object $delegation -Name 'worker_session_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($workerSessionId)) {
        if ($failures -notcontains 'worker_session_id') { $failures.Add('worker_session_id') }
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedWorkerSessionId) -and $workerSessionId -ne $ExpectedWorkerSessionId) {
        $failures.Add('worker_session_id')
    }

    if ([string](Get-JsonProperty -Object $delegation -Name 'observed_model' -Default '') -ne $RequestedModel) {
        $failures.Add('requested_model')
    }
    if (-not [bool](Get-JsonProperty -Object $delegation -Name 'fresh_worker' -Default $false)) {
        $failures.Add('fresh_worker')
    }
    if (-not [bool](Get-JsonProperty -Object $delegation -Name 'home_config_isolated' -Default $false)) {
        $failures.Add('isolated_home_config')
    }
    if (-not [bool](Get-JsonProperty -Object $delegation -Name 'prompt_fidelity' -Default $false) -or
        [string](Get-JsonProperty -Object $delegation -Name 'prompt_sha256' -Default '') -ne [string]$Run.PromptHash) {
        $failures.Add('prompt_fidelity')
    }
    if (-not [bool](Get-JsonProperty -Object $delegation -Name 'terminal_result_capture' -Default $false)) {
        $failures.Add('terminal_result_capture')
    }
    if ([bool](Get-JsonProperty -Object $delegation -Name 'paired_arm_visible' -Default $true) -or
        [bool](Get-JsonProperty -Object $delegation -Name 'grading_material_visible' -Default $true)) {
        $failures.Add('paired_arm_and_grading_exclusion')
    }
    if ([bool](Get-JsonProperty -Object $delegation -Name 'nested_model_execution' -Default $true) -or
        [int](Get-JsonProperty -Object $delegation -Name 'model_execution_count' -Default 0) -ne 1) {
        $failures.Add('nested_model_execution')
    }
    $executionPaths = Get-JsonProperty -Object (Get-JsonProperty -Object $ExecutionEvidence -Name 'evidence' -Default $null) -Name 'execution_paths' -Default $null
    $expectedWorkingDirectory = [string]$Run.WorkingDirectoryPath
    $expectedHomeDirectory = [string]$Run.HomeDirectoryPath
    if ($null -ne $executionPaths) {
        $logicalWorkingDirectory = [string](Get-JsonProperty -Object $executionPaths -Name 'logical_working_directory' -Default '')
        $logicalHomeDirectory = [string](Get-JsonProperty -Object $executionPaths -Name 'logical_home_directory' -Default '')
        if (-not (Test-ExactObservedPath -Expected ([string]$Run.WorkingDirectoryPath) -Observed $logicalWorkingDirectory)) {
            $failures.Add('working_directory')
        }
        if (-not (Test-ExactObservedPath -Expected ([string]$Run.HomeDirectoryPath) -Observed $logicalHomeDirectory)) {
            $failures.Add('isolated_home_config')
        }
        $physicalWorkingDirectory = [string](Get-JsonProperty -Object $executionPaths -Name 'physical_working_directory' -Default '')
        $physicalHomeDirectory = [string](Get-JsonProperty -Object $executionPaths -Name 'physical_home_directory' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($physicalWorkingDirectory)) { $expectedWorkingDirectory = $physicalWorkingDirectory }
        if (-not [string]::IsNullOrWhiteSpace($physicalHomeDirectory)) { $expectedHomeDirectory = $physicalHomeDirectory }
    }
    if (-not (Test-ExactObservedPath -Expected $expectedWorkingDirectory -Observed ([string](Get-JsonProperty -Object $delegation -Name 'observed_working_directory' -Default '')))) {
        $failures.Add('working_directory')
    }
    if (-not (Test-ExactObservedPath -Expected $expectedHomeDirectory -Observed ([string](Get-JsonProperty -Object $delegation -Name 'observed_home' -Default '')))) {
        $failures.Add('isolated_home_config')
    }

    $session = Get-JsonProperty -Object $ExecutionEvidence -Name 'session' -Default $null
    if ($null -eq $session -or
        -not [bool](Get-JsonProperty -Object $session -Name 'fresh' -Default $false) -or
        [bool](Get-JsonProperty -Object $session -Name 'resumed' -Default $true) -or
        [string](Get-JsonProperty -Object $session -Name 'id' -Default '') -ne $workerSessionId) {
        $failures.Add('fresh_worker')
    }

    return [pscustomobject]@{
        Valid = $failures.Count -eq 0
        Failures = @($failures | Select-Object -Unique)
        Delegation = $delegation
    }
}

function Assert-NativeWorkerTerminalEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionEvidence,
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$RequestedModel,
        [string]$ExpectedWorkerSessionId = '',
        [string]$ExpectedRunner = '',
        [string]$ExpectedMechanism = ''
    )

    $validation = Test-NativeWorkerTerminalEvidence `
        -ExecutionEvidence $ExecutionEvidence `
        -Run $Run `
        -RequestedModel $RequestedModel `
        -ExpectedWorkerSessionId $ExpectedWorkerSessionId `
        -ExpectedRunner $ExpectedRunner `
        -ExpectedMechanism $ExpectedMechanism
    if (-not $validation.Valid) {
        throw "Native worker terminal evidence is incompatible: $([string]::Join(', ', @($validation.Failures)))."
    }
    return $true
}

function Assert-NativeTerminalCaptureArtifact {
    param([Parameter(Mandatory = $true)][object]$ExecutionResult)

    $capture = Get-JsonProperty -Object $ExecutionResult.evidence -Name 'capture' -Default $null
    if ([string](Get-JsonProperty -Object $capture -Name 'source' -Default '') -ne 'harness_native_transport' -or
        -not [bool](Get-JsonProperty -Object $capture -Name 'terminal' -Default $false) -or
        [bool](Get-JsonProperty -Object $capture -Name 'worker_authored' -Default $true)) {
        throw 'Native worker execution must preserve harness-native terminal capture provenance.'
    }

    $transcriptMetric = Get-JsonProperty -Object $ExecutionResult.telemetry -Name 'transcript' -Default $null
    $transcriptStatus = [string](Get-JsonProperty -Object $transcriptMetric -Name 'status' -Default '')
    $transcriptArtifact = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $transcriptMetric -Name 'value' -Default $null) -Name 'artifact' -Default '')
    if ($transcriptStatus -ne 'available' -or [string]::IsNullOrWhiteSpace($transcriptArtifact)) {
        throw 'Native worker execution must provide an available terminal transcript artifact.'
    }
    $matchingArtifacts = @($ExecutionResult.artifacts | Where-Object {
        [string](Get-JsonProperty -Object $_ -Name 'path' -Default '') -eq $transcriptArtifact
    })
    if ($matchingArtifacts.Count -ne 1) {
        throw "Native worker transcript artifact '$transcriptArtifact' is not recorded exactly once in execution-result.json."
    }
}

function Resolve-RunContract {
    param([Parameter(Mandatory = $true)][string]$RunPath)

    $resolvedRunPath = (Resolve-Path -LiteralPath $RunPath -ErrorAction Stop).Path
    $runRoot = Split-Path -Parent $resolvedRunPath
    $run = Read-RunnerJson -Path $resolvedRunPath
    $schemas = Get-RunnerSchemaNames

    if ([string]$run.schema -ne $schemas.Run) {
        throw "run.json must declare '$($schemas.Run)'."
    }
    if (-not [bool]$run.freshContextRequired -or -not [bool]$run.filesystemIsolationRequired -or -not [bool]$run.isolatedHomeRequired) {
        throw 'run.json must require a fresh context, a staged filesystem/workspace boundary, and an isolated home.'
    }

    $mode = [string]$run.mode
    if ($mode -notin @('with_skill', 'without_skill')) {
        throw "run.json mode '$mode' is not with_skill or without_skill."
    }

    $promptPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.promptFile) -FieldName 'promptFile' -Kind File
    $workingPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.workingDirectory) -FieldName 'workingDirectory' -Kind Directory
    $homePath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.homeDirectory) -FieldName 'homeDirectory' -Kind Directory

    $interactionPath = $null
    $interaction = $null
    $interactionHash = $null
    $interactionFile = [string](Get-JsonProperty -Object $run -Name 'interactionFile' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($interactionFile)) {
        $interactionPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath $interactionFile -FieldName 'interactionFile' -Kind File
        $interaction = Read-RunnerJson -Path $interactionPath
        $interactionSchemas = Get-RunnerSchemaNames
        if ([string]$interaction.schema -ne $interactionSchemas.Interaction -or [string]$interaction.mode -ne 'scripted') {
            throw "interaction.json must declare '$($interactionSchemas.Interaction)' and mode 'scripted'."
        }
        $interactionTurns = @(Get-JsonProperty -Object $interaction -Name 'turns' -Default @())
        if ($interactionTurns.Count -lt 2) { throw 'Scripted interaction must contain at least two user turns.' }
        $allowedInteractionFields = @('schema', 'mode', 'turns')
        foreach ($name in @(Get-JsonPropertyNames -Object $interaction)) {
            if ($allowedInteractionFields -notcontains $name) { throw "interaction.json contains unsupported field '$name'." }
        }
        for ($turnIndex = 0; $turnIndex -lt $interactionTurns.Count; $turnIndex++) {
            $turn = $interactionTurns[$turnIndex]
            foreach ($name in @(Get-JsonPropertyNames -Object $turn)) {
                if (@('role', 'source', 'content') -notcontains $name) { throw "interaction turn $turnIndex contains unsupported field '$name'." }
            }
            if ([string](Get-JsonProperty -Object $turn -Name 'role' -Default '') -ne 'user') { throw "interaction turn $turnIndex must have role 'user'." }
            $hasSource = (Test-JsonProperty -Object $turn -Name 'source') -and -not [string]::IsNullOrWhiteSpace([string]$turn.source)
            $hasContent = (Test-JsonProperty -Object $turn -Name 'content') -and -not [string]::IsNullOrWhiteSpace([string]$turn.content)
            if ($hasSource -eq $hasContent) { throw "interaction turn $turnIndex must declare exactly one non-empty source or content." }
            if ($hasSource) {
                [void](Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$turn.source) -FieldName "interaction.turns[$turnIndex].source" -Kind File)
            }
        }
        if (-not (Test-JsonProperty -Object $run -Name 'interactionHash') -or -not (Test-Sha256 -Value ([string]$run.interactionHash))) {
            throw 'run.json with interactionFile must declare a valid interactionHash.'
        }
        $interactionHash = [string]$run.interactionHash
        if ($interactionHash -ne (Get-Sha256HexFromFile -Path $interactionPath)) { throw 'run.json interactionHash does not match interaction.json.' }
    }

    $skillPath = $null
    if ($mode -eq 'with_skill') {
        if ([string]::IsNullOrWhiteSpace([string]$run.skillDirectory)) {
            throw 'with_skill run.json must declare skillDirectory.'
        }
        $skillPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.skillDirectory) -FieldName 'skillDirectory' -Kind Directory
        if (-not (Test-Path -LiteralPath (Join-Path $skillPath 'SKILL.md') -PathType Leaf)) {
            throw 'with_skill skillDirectory must contain SKILL.md.'
        }
    } else {
        if ($null -ne $run.skillDirectory -and -not [string]::IsNullOrWhiteSpace([string]$run.skillDirectory)) {
            throw 'without_skill run.json must not declare skillDirectory.'
        }
        $skillRoot = Join-Path $runRoot 'skill'
        if (Test-Path -LiteralPath $skillRoot) {
            throw 'without_skill run must not contain a skill directory.'
        }
    }

    $promptBytes = [System.IO.File]::ReadAllBytes($promptPath)
    $fixtureHash = [string](Get-JsonProperty -Object $run -Name 'fixtureHash' -Default '')
    if (-not (Test-Sha256 -Value $fixtureHash)) {
        throw 'run.json fixtureHash must be a SHA-256 value.'
    }
    if ($mode -eq 'with_skill' -and -not (Test-Sha256 -Value ([string]$run.skillHash))) {
        throw 'with_skill run.json skillHash must be a SHA-256 value.'
    }

    return [pscustomobject]@{
        RunPath = $resolvedRunPath
        RunRoot = $runRoot
        Contract = $run
        EvalId = [int]$run.evalId
        EvalName = [string]$run.evalName
        Mode = $mode
        PromptPath = $promptPath
        PromptBytes = $promptBytes
        PromptHash = Get-Sha256HexFromBytes -Bytes $promptBytes
        WorkingDirectoryPath = $workingPath
        HomeDirectoryPath = $homePath
        SkillDirectoryPath = $skillPath
        CandidateSkillExposed = $mode -eq 'with_skill'
        FixtureHash = $fixtureHash
        SkillHash = if ($mode -eq 'with_skill') { [string]$run.skillHash } else { $null }
        InteractionPath = $interactionPath
        InteractionHash = $interactionHash
        Interaction = $interaction
    }
}

function Get-InteractionTurnText {
    param(
        [Parameter(Mandatory = $true)][object]$Turn,
        [Parameter(Mandatory = $true)][object]$RunData
    )

    $content = Get-JsonProperty -Object $Turn -Name 'content' -Default $null
    if ($null -ne $content) { return [string]$content }
    $sourcePath = Resolve-ContainedPath -BasePath $RunData.RunRoot -RelativePath ([string]$Turn.source) -FieldName 'interaction turn source' -Kind File
    return [System.IO.File]::ReadAllText($sourcePath, [System.Text.UTF8Encoding]::new($false))
}

function Assert-InteractionResultEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionResult,
        [Parameter(Mandatory = $true)][object]$RunData
    )

    if ($null -eq $RunData.Interaction) { return $true }
    if ([string]$ExecutionResult.status -ne 'completed') { return $true }
    $interaction = Get-JsonProperty -Object $ExecutionResult.evidence -Name 'interaction' -Default $null
    if ($null -eq $interaction) { throw 'Scripted interaction execution must provide evidence.interaction.' }
    $schemas = Get-RunnerSchemaNames
    if ([string]$interaction.schema -ne $schemas.Interaction -or [string]$interaction.mode -ne 'scripted' -or -not [bool]$interaction.same_session) {
        throw 'Scripted interaction evidence must prove the eval stayed in one same-session scripted interaction.'
    }
    $sessionId = [string]$ExecutionResult.session.id
    if ([string]$interaction.session_id -ne $sessionId) { throw 'Scripted interaction evidence session_id does not match execution-result session.id.' }
    $requestedTurns = @(Get-JsonProperty -Object $RunData.Interaction -Name 'turns' -Default @())
    $observedTurns = @(Get-JsonProperty -Object $interaction -Name 'turns' -Default @())
    if ($observedTurns.Count -ne ($requestedTurns.Count * 2)) {
        throw "Scripted interaction evidence has $($observedTurns.Count) turns; expected $($requestedTurns.Count * 2) ordered user/assistant turns."
    }
    for ($index = 0; $index -lt $observedTurns.Count; $index++) {
        $observed = $observedTurns[$index]
        $expectedRole = if (($index % 2) -eq 0) { 'user' } else { 'assistant' }
        if ([int](Get-JsonProperty -Object $observed -Name 'sequence' -Default -1) -ne ($index + 1) -or [string]$observed.role -ne $expectedRole) {
            throw 'Scripted interaction evidence does not preserve ordered user/assistant turns.'
        }
        $observedSession = [string](Get-JsonProperty -Object $observed -Name 'session_id' -Default $sessionId)
        if ($observedSession -ne $sessionId) { throw 'Scripted interaction evidence changed session identity between turns.' }
        if ($expectedRole -eq 'user') {
            $requestedTurn = $requestedTurns[[int]($index / 2)]
            $expectedText = Get-InteractionTurnText -Turn $requestedTurn -RunData $RunData
            $expectedHash = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($expectedText))
            if ([string]$observed.content_sha256 -ne $expectedHash) { throw "Scripted interaction user turn $($index / 2) does not match its deterministic package input." }
        } elseif (-not (Test-JsonProperty -Object $observed -Name 'text')) {
            throw "Scripted interaction assistant turn $($index / 2) is missing its terminal response text."
        }
    }
    $finalSequence = [int](Get-JsonProperty -Object $interaction -Name 'final_response_sequence' -Default 0)
    if ($finalSequence -ne $observedTurns.Count) { throw 'Scripted interaction evidence final response does not identify the last assistant turn.' }
    if ([string]$ExecutionResult.final_response.status -eq 'available' -and
        [string]$ExecutionResult.final_response.text -ne [string]$observedTurns[$observedTurns.Count - 1].text) {
        throw 'Scripted interaction final_response does not match the last assistant turn.'
    }
    return $true
}

function Assert-ProfileHasNoSecrets {
    param([Parameter(Mandatory = $true)][object]$Profile)

    foreach ($property in @($Profile.PSObject.Properties)) {
        if ([string]$property.Name -match '(?i)(secret|token|password|credential|api[_-]?key|private[_-]?key)') {
            throw "execution-profile.json must not contain secret-bearing field '$($property.Name)'."
        }
    }
}

function Resolve-ExecutionProfile {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
    $profile = Read-RunnerJson -Path $resolvedProfilePath
    $schemas = Get-RunnerSchemaNames
    if ([string]$profile.schema -ne $schemas.Profile) {
        throw "execution-profile.json must declare '$($schemas.Profile)'."
    }
    Assert-ProfileHasNoSecrets -Profile $profile

    $allowedProperties = @('schema', 'runner', 'model', 'reasoning_effort', 'configuration_profile', 'tool_profile', 'timeout_seconds', 'concurrency')
    foreach ($propertyName in @(Get-JsonPropertyNames -Object $profile)) {
        if ($allowedProperties -notcontains $propertyName) {
            throw "execution-profile.json contains unsupported field '$propertyName'."
        }
    }

    $timeout = [int](Get-JsonProperty -Object $profile -Name 'timeout_seconds' -Default 0)
    $concurrency = [int](Get-JsonProperty -Object $profile -Name 'concurrency' -Default 0)
    if ($timeout -lt 1 -or $timeout -gt 86400) {
        throw 'execution-profile.json timeout_seconds must be between 1 and 86400.'
    }
    if ($concurrency -lt 1) {
        throw 'execution-profile.json concurrency must be at least 1.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$profile.configuration_profile) -or [string]::IsNullOrWhiteSpace([string]$profile.tool_profile)) {
        throw 'execution-profile.json must declare configuration_profile and tool_profile.'
    }

    $runnerValue = [string](Get-JsonProperty -Object $profile -Name 'runner' -Default '')
    $modelValue = [string](Get-JsonProperty -Object $profile -Name 'model' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($runnerValue) -and $runnerValue -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw 'execution-profile.json runner must be a safe lowercase runner name.'
    }
    if ([string]::IsNullOrWhiteSpace($runnerValue) -or [string]::IsNullOrWhiteSpace($modelValue)) {
        throw 'execution-profile.json must declare non-empty runner and model before a runner can execute.'
    }
    return [pscustomobject]@{
        Path = $resolvedProfilePath
        Profile = $profile
        Hash = Get-Sha256HexFromFile -Path $resolvedProfilePath
        Runner = if ([string]::IsNullOrWhiteSpace($runnerValue)) { $null } else { $runnerValue }
        Model = if ([string]::IsNullOrWhiteSpace($modelValue)) { $null } else { $modelValue }
        ReasoningEffort = if ([string]::IsNullOrWhiteSpace([string]$profile.reasoning_effort)) { $null } else { [string]$profile.reasoning_effort }
        ConfigurationProfile = [string]$profile.configuration_profile
        ToolProfile = [string]$profile.tool_profile
        TimeoutSeconds = $timeout
        Concurrency = $concurrency
    }
}

function Assert-RunnerDescriptor {
    param([Parameter(Mandatory = $true)][object]$Descriptor)

    $schemas = Get-RunnerSchemaNames
    if ([string]$Descriptor.schema -ne $schemas.Descriptor) {
        throw "Runner descriptor must declare '$($schemas.Descriptor)'."
    }
    if ([string]$Descriptor.protocol_version -ne $schemas.Protocol) {
        throw "Runner descriptor protocol_version must be '$($schemas.Protocol)'."
    }
    foreach ($field in @('name', 'version', 'platforms', 'harness', 'capabilities', 'delegation', 'configuration_profiles', 'tool_profiles')) {
        if (-not (Test-JsonProperty -Object $Descriptor -Name $field)) {
            throw "Runner descriptor is missing '$field'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Descriptor.name) -or [string]::IsNullOrWhiteSpace([string]$Descriptor.version)) {
        throw 'Runner descriptor name and version must be non-empty.'
    }
    if (-not (Test-JsonProperty -Object $Descriptor.harness -Name 'name') -or -not (Test-JsonProperty -Object $Descriptor.harness -Name 'version')) {
        throw 'Runner descriptor harness must declare name and version.'
    }

    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $Descriptor.capabilities)) {
        $capabilityValue = Get-JsonProperty -Object $Descriptor.capabilities -Name $capabilityName
        if ([string]$capabilityValue -notin @('supported', 'conditional', 'unsupported')) {
            throw "Runner capability '$capabilityName' must be supported, conditional, or unsupported."
        }
    }

    $required = @(
        'single_turn',
        'scripted_multi_turn_same_session',
        'fresh_context',
        'isolated_home_config',
        'isolated_working_directory',
        'filesystem_confinement',
        'ambient_candidate_skill_exclusion',
        'candidate_skill_exposure',
        'prompt_fidelity',
        'model_configuration_lock',
        'response_capture'
    )
    foreach ($name in $required) {
        if (-not (Test-JsonProperty -Object $Descriptor.capabilities -Name $name)) {
            throw "Runner descriptor is missing required capability '$name'."
        }
    }

    $delegationRequired = @(
        'native_worker_delegation',
        'delegated_worker_full_capability',
        'delegated_worker_model_lock',
        'delegated_worker_working_directory',
        'delegated_worker_result_capture',
        'delegated_worker_capacity_signal'
    )
    foreach ($name in $delegationRequired) {
        if (-not (Test-JsonProperty -Object $Descriptor.capabilities -Name $name)) {
            throw "Runner descriptor is missing required delegation capability '$name'."
        }
    }
    $delegation = $Descriptor.delegation
    foreach ($field in @('dispatch_owner', 'mode', 'mechanism', 'worker_role', 'full_capability', 'model_lock', 'working_directory', 'result_capture', 'capacity', 'nested_model_execution')) {
        if (-not (Test-JsonProperty -Object $delegation -Name $field)) {
            throw "Runner descriptor delegation is missing '$field'."
        }
    }
    if ([string]$delegation.dispatch_owner -notin @('orchestrator', 'runner')) {
        throw "Runner delegation dispatch_owner '$($delegation.dispatch_owner)' must be orchestrator or runner."
    }
    if ([string]$delegation.mode -notin @('native_worker', 'conditional', 'unsupported')) {
        throw "Runner delegation mode '$($delegation.mode)' is unsupported."
    }
    foreach ($field in @('full_capability', 'model_lock', 'working_directory', 'result_capture', 'capacity')) {
        if ([string]$delegation.$field -notin @('supported', 'conditional', 'unsupported', 'harness_authoritative')) {
            throw "Runner delegation '$field' must be supported, conditional, unsupported, or harness_authoritative."
        }
    }
    if ([bool]$delegation.nested_model_execution) {
        throw 'Runner delegation must not describe nested model execution.'
    }

    return $true
}

function New-PreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'unavailable', 'not_applicable')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    return [ordered]@{ name = $Name; status = $Status; detail = $Detail }
}

function New-PreflightDocument {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][bool]$Compatible,
        [object[]]$Checks = @(),
        [string[]]$Mechanisms = @(),
        [object]$ResolvedCapabilities = $null,
        [string[]]$Warnings = @(),
        [string[]]$Reasons = @()
    )

    $schemas = Get-RunnerSchemaNames
    $capabilitiesForAssessment = if ($null -eq $ResolvedCapabilities) { [ordered]@{} } else { $ResolvedCapabilities }
    $assessment = Get-IsolationCapabilityAssessment -Capabilities $capabilitiesForAssessment
    $delegationAssessment = Get-DelegationCapabilityAssessment -Descriptor $Descriptor -Capabilities $capabilitiesForAssessment
    # Isolation is the compatibility transport's local readiness gate. Native
    # delegation has a separate gate: conditional controls may proceed to a
    # delegated worker, while an unavailable/unsupported mechanism cannot.
    $effectiveCompatible = $Compatible -and $assessment.MandatoryProven
    $unprovenControls = [string[]]$assessment.Unproven
    if (-not $effectiveCompatible) { $unprovenControls = [string[]](@($assessment.Unproven) + @('preflight')) }
    return [ordered]@{
        schema = $schemas.Preflight
        protocol_version = $schemas.Protocol
        status = if ($effectiveCompatible) { 'compatible' } else { 'incompatible' }
        runner = [ordered]@{ name = [string]$Descriptor.name; version = [string]$Descriptor.version }
        harness = $Descriptor.harness
        run = [ordered]@{ eval_id = $Run.EvalId; eval_name = $Run.EvalName; configuration = $Run.Mode }
        requested = [ordered]@{
            model = $Profile.Model
            reasoning_effort = $Profile.ReasoningEffort
            configuration_profile = $Profile.ConfigurationProfile
            tool_profile = $Profile.ToolProfile
            timeout_seconds = $Profile.TimeoutSeconds
        }
        checks = @($Checks)
        resolved_capabilities = if ($null -eq $ResolvedCapabilities) { [ordered]@{} } else { $ResolvedCapabilities }
        delegation = [ordered]@{
            dispatch_owner = $delegationAssessment.DispatchOwner
            status = $delegationAssessment.Status
            mode = $delegationAssessment.Mode
            mechanism = $delegationAssessment.Mechanism
            worker_role = $delegationAssessment.WorkerRole
            nested_model_execution = $delegationAssessment.NestedModelExecution
            required_controls = @($delegationAssessment.Required)
            unproven_controls = [string[]]$delegationAssessment.Unproven
            terminal_evidence_required = $delegationAssessment.Status -eq 'conditional'
        }
        isolation = [ordered]@{
            level = if ($effectiveCompatible) { $assessment.Level } else { 'unsupported' }
            status = if ($effectiveCompatible) { 'verified' } else { 'unverified' }
            hard_filesystem_confinement = if ($effectiveCompatible) { $assessment.HardFilesystemConfinement } else { $false }
            unproven_controls = $unprovenControls
        }
        mechanisms = @($Mechanisms)
        warnings = @($Warnings)
        reasons = @($Reasons)
    }
}

function Assert-NativeWorkerDelegation {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][object]$Preflight
    )

    $delegation = Get-JsonProperty -Object $Descriptor -Name 'delegation' -Default $null
    $dispatchOwner = [string](Get-JsonProperty -Object $delegation -Name 'dispatch_owner' -Default '')
    if ($dispatchOwner -notin @('orchestrator', 'runner')) {
        throw "Runner '$($Descriptor.name)' has no valid native dispatch owner."
    }
    $mode = [string](Get-JsonProperty -Object $delegation -Name 'mode' -Default 'unsupported')
    if ($mode -notin @('native_worker', 'conditional')) {
        throw "Runner '$($Descriptor.name)' cannot satisfy the mandatory native Eval Worker contract: delegation mode is '$mode'."
    }
    if ([bool](Get-JsonProperty -Object $delegation -Name 'nested_model_execution' -Default $true)) {
        throw "Runner '$($Descriptor.name)' describes nested model execution; one eval arm must have exactly one model-backed worker."
    }
    if ([string](Get-JsonProperty -Object $Preflight -Name 'status' -Default 'incompatible') -ne 'compatible') {
        throw "Runner '$($Descriptor.name)' preflight is incompatible; the orchestrator must not execute an arm in the parent context."
    }
    $delegationPreflight = Get-JsonProperty -Object $Preflight -Name 'delegation' -Default $null
    $delegationStatus = [string](Get-JsonProperty -Object $delegationPreflight -Name 'status' -Default 'unsupported')
    if ($delegationStatus -notin @('supported', 'conditional')) {
        $unproven = @((Get-JsonProperty -Object $delegationPreflight -Name 'unproven_controls' -Default @()))
        throw "Runner '$($Descriptor.name)' native worker delegation is unavailable during preflight: $([string]::Join(', ', $unproven)). No parent or compatibility-execute fallback is permitted."
    }
    if ($delegationStatus -eq 'conditional' -and -not [bool](Get-JsonProperty -Object $delegationPreflight -Name 'terminal_evidence_required' -Default $false)) {
        throw "Runner '$($Descriptor.name)' reports conditional native worker controls without requiring terminal evidence."
    }
    $capabilities = Get-JsonProperty -Object $Preflight -Name 'resolved_capabilities' -Default $null
    $required = @(
        'native_worker_delegation',
        'delegated_worker_full_capability',
        'delegated_worker_model_lock',
        'delegated_worker_working_directory',
        'delegated_worker_result_capture',
        'delegated_worker_capacity_signal'
    )
    foreach ($name in $required) {
        $value = [string](Get-JsonProperty -Object $capabilities -Name $name -Default 'unsupported')
        if ($value -notin @('supported', 'conditional')) {
            throw "Runner '$($Descriptor.name)' native worker capability '$name' is unavailable; the orchestrator must not fall back to parent or compatibility execution."
        }
    }
    return $true
}

function New-UnavailableMetric {
    param([Parameter(Mandatory = $true)][string]$Reason)

    return [ordered]@{ status = 'unavailable'; reason = $Reason }
}

function New-AvailableMetric {
    param([Parameter(Mandatory = $true)][object]$Value)

    return [ordered]@{ status = 'available'; value = $Value }
}

function New-ExecutionFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    return [ordered]@{ code = $Code; message = $Message }
}

function Assert-PhaseOneEvidenceWritable {
    param([Parameter(Mandatory = $true)][object]$Run)

    # Every runner-owned transport reaches this shared result builder. Once the
    # package-level freeze exists, refusing to build another result prevents a
    # direct runner invocation (or the orchestrator-owned recorder) from
    # truncating or replacing frozen raw evidence.
    $runRoot = [System.IO.Path]::GetFullPath([string]$Run.RunRoot)
    $iterationDirectory = Split-Path -Parent (Split-Path -Parent $runRoot)
    $freezeRelativePath = 'execution-freeze.json'
    $manifestPath = Join-Path $iterationDirectory 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-RunnerJson -Path $manifestPath
        $declaredFreezePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_freeze' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($declaredFreezePath)) { $freezeRelativePath = $declaredFreezePath }
    }
    Assert-SafeRelativePath -RelativePath $freezeRelativePath -FieldName 'execution freeze path'
    $freezePath = Join-Path $iterationDirectory ($freezeRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $freezePath) {
        throw "Execution integrity failure: Phase 1 raw evidence is already frozen at '$freezePath'; requires fresh Phase 1 execution."
    }
    return $true
}

function New-ExecutionResult {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][ValidateSet('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')][string]$Status,
        [string]$FinalResponse,
        [string]$FinalResponseReason,
        [string]$StartedUtc,
        [string]$FinishedUtc,
        [double]$DurationSeconds = 0,
        [Nullable[int]]$ExitStatus,
        [object]$Failure,
        [string]$SessionId,
        [System.Collections.IDictionary]$IsolationCapabilities,
        [string[]]$IsolationMechanisms = @(),
        [object]$ResolvedConfiguration = $null,
        [object]$Telemetry = $null,
        [object[]]$Artifacts = @(),
        [string[]]$Warnings = @(),
        [string[]]$CompatibilityDeviations = @(),
        [object]$Evidence = $null,
        [int]$AttemptCount = 1
    )

    [void](Assert-PhaseOneEvidenceWritable -Run $Run)
    $schemas = Get-RunnerSchemaNames
    $assessment = Get-IsolationCapabilityAssessment -Capabilities $IsolationCapabilities
    $effectiveStatus = $Status
    $effectiveFinalResponse = $FinalResponse
    $effectiveFinalResponseReason = $FinalResponseReason
    $effectiveExitStatus = $ExitStatus
    $effectiveFailure = $Failure
    $effectiveDeviations = [System.Collections.Generic.List[string]]::new()
    foreach ($deviation in @($CompatibilityDeviations)) { $effectiveDeviations.Add([string]$deviation) }
    if ($Status -ne 'incompatible' -and -not $assessment.MandatoryProven) {
        $effectiveStatus = 'incompatible'
        $effectiveFinalResponse = $null
        $effectiveFinalResponseReason = 'isolation_controls_unproven'
        $effectiveExitStatus = $null
        $effectiveFailure = New-ExecutionFailure -Code 'isolation_unproven' -Message ("Mandatory isolation controls were not proven: {0}." -f ([string]::Join(', ', @($assessment.Unproven))))
        $effectiveDeviations.Add('execution_rejected_because_mandatory_isolation_controls_were_unproven')
    }
    $hasResponse = -not [string]::IsNullOrWhiteSpace($effectiveFinalResponse)
    $started = if ([string]::IsNullOrWhiteSpace($StartedUtc)) { [DateTime]::UtcNow } else { [DateTime]::Parse($StartedUtc).ToUniversalTime() }
    $finished = if ([string]::IsNullOrWhiteSpace($FinishedUtc)) { [DateTime]::UtcNow } else { [DateTime]::Parse($FinishedUtc).ToUniversalTime() }
    $isolation = [ordered]@{
        status = if ($effectiveStatus -ne 'incompatible' -and $assessment.MandatoryProven) { 'verified' } else { 'unverified' }
        level = if ($effectiveStatus -eq 'incompatible') { 'unsupported' } else { $assessment.Level }
        hard_filesystem_confinement = if ($effectiveStatus -eq 'incompatible') { $false } else { $assessment.HardFilesystemConfinement }
        capabilities = if ($null -eq $IsolationCapabilities) { [ordered]@{} } else { $IsolationCapabilities }
        mechanisms = @($IsolationMechanisms)
        required_controls = @($assessment.Required)
        unproven_controls = [string[]]$assessment.Unproven
    }

    $resolved = [ordered]@{
        model = $null
        reasoning_effort = $null
        configuration_profile = $null
        tool_profile = $null
        status = 'unavailable'
        reason = 'harness_only_confirmed_the_requested_configuration'
        accepted = [ordered]@{
            model = $Profile.Model
            reasoning_effort = $Profile.ReasoningEffort
            configuration_profile = $Profile.ConfigurationProfile
            tool_profile = $Profile.ToolProfile
        }
    }
    if ($null -ne $ResolvedConfiguration) {
        $resolved.status = [string](Get-JsonProperty -Object $ResolvedConfiguration -Name 'status' -Default 'resolved')
        $resolved.reason = Get-JsonProperty -Object $ResolvedConfiguration -Name 'reason' -Default $null
        foreach ($name in @('model', 'reasoning_effort', 'configuration_profile', 'tool_profile')) {
            $value = Get-JsonProperty -Object $ResolvedConfiguration -Name $name -Default $null
            if ($null -ne $value) { $resolved[$name] = $value }
        }
        $observations = Get-JsonProperty -Object $ResolvedConfiguration -Name 'observations' -Default $null
        if ($null -ne $observations) { $resolved.observations = $observations }
    }

    return [ordered]@{
        schema = $schemas.Result
        protocol_version = $schemas.Protocol
        run_id = [Guid]::NewGuid().ToString('D')
        session = [ordered]@{
            id = if ([string]::IsNullOrWhiteSpace($SessionId)) { [Guid]::NewGuid().ToString('D') } else { $SessionId }
            fresh = $true
            resumed = $false
        }
        status = $effectiveStatus
        run = [ordered]@{
            eval_id = $Run.EvalId
            eval_name = $Run.EvalName
            configuration = $Run.Mode
        }
        final_response = if ($hasResponse) {
            [ordered]@{ status = 'available'; text = $effectiveFinalResponse }
        } else {
            [ordered]@{ status = 'unavailable'; reason = if ([string]::IsNullOrWhiteSpace($effectiveFinalResponseReason)) { 'harness_did_not_return_a_final_response' } else { $effectiveFinalResponseReason } }
        }
        runner = [ordered]@{ name = [string]$Descriptor.name; version = [string]$Descriptor.version }
        harness = $Descriptor.harness
        requested = [ordered]@{
            model = $Profile.Model
            reasoning_effort = $Profile.ReasoningEffort
            configuration_profile = $Profile.ConfigurationProfile
            tool_profile = $Profile.ToolProfile
            timeout_seconds = $Profile.TimeoutSeconds
        }
        resolved = $resolved
        started_utc = Format-UtcTimestamp -Value $started
        finished_utc = Format-UtcTimestamp -Value $finished
        duration_seconds = [Math]::Max(0, [Math]::Round($DurationSeconds, 3))
        exit = [ordered]@{ status = $effectiveExitStatus; failure = $effectiveFailure }
        input = [ordered]@{
            prompt_sha256 = $Run.PromptHash
            run_json_sha256 = Get-Sha256HexFromFile -Path $Run.RunPath
            profile_sha256 = $Profile.Hash
        }
        isolation = $isolation
        telemetry = if ($null -eq $Telemetry) {
            [ordered]@{
                transcript = New-UnavailableMetric -Reason 'harness_did_not_expose_transcript'
                tokens = New-UnavailableMetric -Reason 'harness_did_not_expose_usage'
                tool_calls = New-UnavailableMetric -Reason 'harness_did_not_expose_tool_calls'
                cost = New-UnavailableMetric -Reason 'harness_did_not_expose_cost'
            }
        } else { $Telemetry }
        evidence = if ($null -eq $Evidence) { [ordered]@{} } else { $Evidence }
        artifacts = @($Artifacts)
        warnings = @($Warnings)
        compatibility_deviations = @($effectiveDeviations)
        attempt_count = $AttemptCount
    }
}

function Assert-ExecutionResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    $schemas = Get-RunnerSchemaNames
    if ([string]$Result.schema -ne $schemas.Result) {
        throw "execution-result.json must declare '$($schemas.Result)'."
    }
    if ([string]$Result.protocol_version -ne $schemas.Protocol) {
        throw "execution-result.json protocol_version must be '$($schemas.Protocol)'."
    }
    if ([string]$Result.status -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
        throw "execution-result.json status '$($Result.status)' is unsupported."
    }
    foreach ($field in @('run_id', 'runner', 'harness', 'requested', 'resolved', 'started_utc', 'finished_utc', 'duration_seconds', 'exit', 'final_response', 'input', 'isolation', 'telemetry', 'evidence', 'artifacts', 'warnings', 'compatibility_deviations')) {
        if (-not (Test-JsonProperty -Object $Result -Name $field)) {
            throw "execution-result.json is missing '$field'."
        }
    }
    $runIdentity = Get-JsonProperty -Object $Result -Name 'run' -Default $null
    foreach ($field in @('eval_id', 'eval_name', 'configuration')) {
        if ($null -eq $runIdentity -or -not (Test-JsonProperty -Object $runIdentity -Name $field)) {
            throw "execution-result.json run.$field must be present."
        }
    }
    if (-not (Test-JsonProperty -Object $Result.requested -Name 'timeout_seconds')) {
        throw 'execution-result.json requested.timeout_seconds must be present.'
    }
    foreach ($identityName in @('runner', 'harness')) {
        $identity = Get-JsonProperty -Object $Result -Name $identityName -Default $null
        foreach ($identityField in @('name', 'version')) {
            if ($null -eq $identity -or -not (Test-JsonProperty -Object $identity -Name $identityField) -or
                [string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $identity -Name $identityField -Default ''))) {
                throw "execution-result.json $identityName.$identityField must be non-empty."
            }
        }
    }
    $exitObject = Get-JsonProperty -Object $Result -Name 'exit' -Default $null
    if ($null -eq $exitObject -or -not (Test-JsonProperty -Object $exitObject -Name 'status')) {
        throw 'execution-result.json exit.status must be present and numeric or null.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Result.run_id)) {
        throw 'execution-result.json run_id must be non-empty.'
    }
    if (-not (Test-JsonProperty -Object $Result.session -Name 'id') -or
        -not [bool](Get-JsonProperty -Object $Result.session -Name 'fresh' -Default $false) -or
        [bool](Get-JsonProperty -Object $Result.session -Name 'resumed' -Default $true)) {
        throw 'execution-result.json must identify a fresh, non-resumed session.'
    }
    if ([int](Get-JsonProperty -Object $Result -Name 'attempt_count' -Default 0) -ne 1) {
        throw 'execution-result.json attempt_count must be exactly 1; quality retries are not allowed.'
    }
    $exitStatus = Get-JsonProperty -Object $exitObject -Name 'status' -Default $null
    if ($null -ne $exitStatus) {
        $numericExitStatus = $exitStatus -is [byte] -or
            $exitStatus -is [sbyte] -or
            $exitStatus -is [int16] -or
            $exitStatus -is [uint16] -or
            $exitStatus -is [int32] -or
            $exitStatus -is [uint32] -or
            $exitStatus -is [int64] -or
            $exitStatus -is [uint64]
        if (-not $numericExitStatus) {
            throw 'execution-result.json exit.status must be a JSON number or null; textual lifecycle labels are not valid exit codes.'
        }
    }
    $isolationStatus = [string](Get-JsonProperty -Object $Result.isolation -Name 'status' -Default '')
    $isolationLevel = [string](Get-JsonProperty -Object $Result.isolation -Name 'level' -Default '')
    $hardFilesystem = [bool](Get-JsonProperty -Object $Result.isolation -Name 'hard_filesystem_confinement' -Default $false)
    if ($isolationStatus -notin @('verified', 'unverified')) {
        throw "execution-result.json isolation.status '$isolationStatus' is unsupported."
    }
    if ($isolationLevel -notin @('strict', 'pragmatic', 'unsupported')) {
        throw "execution-result.json isolation.level '$isolationLevel' is unsupported."
    }
    if ($Result.status -eq 'incompatible') {
        if ($isolationStatus -ne 'unverified' -or $isolationLevel -ne 'unsupported') {
            throw 'An incompatible execution must report unverified, unsupported isolation.'
        }
    } else {
        if ($isolationStatus -ne 'verified' -or $isolationLevel -eq 'unsupported') {
            throw 'A non-incompatible execution must prove the mandatory experimental controls.'
        }
        if ($isolationLevel -eq 'strict' -and -not $hardFilesystem) {
            throw 'Strict isolation must report hard filesystem confinement.'
        }
        if ($isolationLevel -eq 'pragmatic' -and $hardFilesystem) {
            throw 'Pragmatic isolation must not claim hard filesystem confinement.'
        }
        $requiredControls = @('fresh_context', 'isolated_home_config', 'isolated_working_directory', 'ambient_candidate_skill_exclusion', 'candidate_skill_exposure', 'prompt_fidelity', 'model_configuration_lock', 'response_capture')
        foreach ($control in $requiredControls) {
            $value = [string](Get-JsonProperty -Object $Result.isolation.capabilities -Name $control -Default 'unavailable')
            if ($control -eq 'candidate_skill_exposure') {
                if ($value -notin @('supported', 'excluded')) { throw "Mandatory isolation capability '$control' is not proven." }
            } elseif ($value -ne 'supported') {
                throw "Mandatory isolation capability '$control' is not proven."
            }
        }
    }
    $resolvedStatus = [string](Get-JsonProperty -Object $Result.resolved -Name 'status' -Default '')
    if ($resolvedStatus -notin @('unavailable', 'accepted_request', 'resolved')) {
        throw "execution-result.json resolved.status '$resolvedStatus' is unsupported."
    }
    if (-not (Test-JsonProperty -Object $Result.resolved -Name 'accepted')) {
        throw 'execution-result.json resolved must preserve the requested configuration as accepted evidence.'
    }
    $hasPortableProvider =
        (Test-JsonProperty -Object $Result.requested -Name 'provider') -or
        (Test-JsonProperty -Object $Result.resolved -Name 'provider') -or
        (Test-JsonProperty -Object $Result.resolved.accepted -Name 'provider')
    if ($hasPortableProvider) {
        throw 'execution-result.json must not expose provider in portable requested/resolved configuration fields.'
    }
    foreach ($hashField in @('prompt_sha256', 'run_json_sha256', 'profile_sha256')) {
        if (-not (Test-Sha256 -Value ([string]$Result.input.$hashField))) {
            throw "execution-result.json input.$hashField must be a SHA-256 value."
        }
    }
    if ([double]$Result.duration_seconds -lt 0) {
        throw 'execution-result.json duration_seconds must not be negative.'
    }
    $responseStatus = [string]$Result.final_response.status
    if ($responseStatus -eq 'available') {
        if (-not (Test-JsonProperty -Object $Result.final_response -Name 'text')) {
            throw 'Available final_response must contain text.'
        }
    } elseif ($responseStatus -eq 'unavailable') {
        if ([string]::IsNullOrWhiteSpace([string]$Result.final_response.reason)) {
            throw 'Unavailable final_response must contain a reason.'
        }
    } else {
        throw "final_response status '$responseStatus' is unsupported."
    }

    foreach ($metricName in @(Get-JsonPropertyNames -Object $Result.telemetry)) {
        $metric = Get-JsonProperty -Object $Result.telemetry -Name $metricName
        $status = [string](Get-JsonProperty -Object $metric -Name 'status' -Default '')
        if ($status -notin @('available', 'unavailable')) {
            throw "Telemetry '$metricName' must declare available or unavailable status."
        }
        if ($status -eq 'unavailable' -and [string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $metric -Name 'reason' -Default ''))) {
            throw "Unavailable telemetry '$metricName' must declare a reason."
        }
    }

    foreach ($artifact in @($Result.artifacts)) {
        $path = [string](Get-JsonProperty -Object $artifact -Name 'path' -Default '')
        $scope = [string](Get-JsonProperty -Object $artifact -Name 'scope' -Default '')
        Assert-SafeRelativePath -RelativePath $path -FieldName 'artifact.path'
        if ($scope -notin @('run', 'package')) {
            throw "artifact.scope '$scope' must be run or package."
        }
        if (-not (Test-Sha256 -Value ([string]$artifact.sha256))) {
            throw 'artifact.sha256 must be a SHA-256 value.'
        }
        if ([int64]$artifact.size -lt 0 -or [string]::IsNullOrWhiteSpace([string]$artifact.media_type)) {
            throw 'artifact must declare non-negative size and media_type.'
        }
    }

    return $true
}

function New-RunnerEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [string[]]$AuthenticationVariables = @(),
        [hashtable]$Additional = @{}
    )

    $environment = [ordered]@{}
    foreach ($name in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'LANG', 'LC_ALL', 'TZ', 'SSL_CERT_FILE', 'NODE_PATH')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }

    $tempPath = Join-Path $Run.HomeDirectoryPath 'tmp'
    foreach ($directory in @($Run.HomeDirectoryPath, $tempPath, (Join-Path $Run.HomeDirectoryPath '.config'), (Join-Path $Run.HomeDirectoryPath '.local/share'), (Join-Path $Run.HomeDirectoryPath '.cache'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $environment['HOME'] = $Run.HomeDirectoryPath
    $environment['USERPROFILE'] = $Run.HomeDirectoryPath
    $environment['XDG_CONFIG_HOME'] = Join-Path $Run.HomeDirectoryPath '.config'
    $environment['XDG_DATA_HOME'] = Join-Path $Run.HomeDirectoryPath '.local/share'
    $environment['XDG_CACHE_HOME'] = Join-Path $Run.HomeDirectoryPath '.cache'
    $environment['TEMP'] = $tempPath
    $environment['TMP'] = $tempPath
    $environment['CI'] = '1'
    $environment['NO_COLOR'] = '1'

    foreach ($name in $AuthenticationVariables | Sort-Object -Unique) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }
    foreach ($key in $Additional.Keys) {
        $environment[$key] = [string]$Additional[$key]
    }

    return $environment
}

function Get-LinuxEvalSandboxArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$InsideEnvironment,
        [string[]]$ReadOnlyRoots = @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/lib64', '/libexec', '/etc', '/opt')
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--die-with-parent', '--new-session', '--unshare-pid')) { $arguments.Add($argument) }
    foreach ($path in $ReadOnlyRoots) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            $arguments.Add('--ro-bind'); $arguments.Add($path); $arguments.Add($path)
        }
    }
    $arguments.Add('--proc'); $arguments.Add('/proc')
    $arguments.Add('--dev'); $arguments.Add('/dev')
    $arguments.Add('--tmpfs'); $arguments.Add('/tmp')
    $arguments.Add('--bind'); $arguments.Add($Inputs.Run.RunRoot); $arguments.Add('/run')
    $commandSource = [string]$CommandInfo.Source
    $commandDirectory = Split-Path -Parent $commandSource
    if (-not ($commandSource.StartsWith('/usr/', [System.StringComparison]::Ordinal) -or $commandSource.StartsWith('/bin/', [System.StringComparison]::Ordinal) -or $commandSource.StartsWith('/opt/', [System.StringComparison]::Ordinal))) {
        if (Test-Path -LiteralPath $commandDirectory -PathType Container) {
            $arguments.Add('--ro-bind'); $arguments.Add($commandDirectory); $arguments.Add($commandDirectory)
        }
    }
    $arguments.Add('--chdir'); $arguments.Add('/run/repo')
    foreach ($key in @($InsideEnvironment.Keys)) {
        $arguments.Add('--setenv'); $arguments.Add([string]$key); $arguments.Add([string]$InsideEnvironment[$key])
    }
    $arguments.Add('--')
    $arguments.Add($CommandInfo.FileName)
    foreach ($prefix in @($CommandInfo.Prefix)) { $arguments.Add($prefix) }
    return @($arguments)
}

function New-MacosEvalSandboxProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [string[]]$ReadOnlyRoots = @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/libexec', '/System', '/Library', '/opt', '/private/var/db')
    )

    $profilePath = Join-Path $Inputs.Run.HomeDirectoryPath 'eval-sandbox.sb'
    $runRoot = $Inputs.Run.RunRoot.Replace('\', '/')
    $commandDirectory = (Split-Path -Parent ([string]$CommandInfo.Source)).Replace('\', '/')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('(version 1)')
    $lines.Add('(deny default)')
    $lines.Add('(allow process*)')
    $lines.Add('(allow network*)')
    foreach ($root in @($ReadOnlyRoots + @($commandDirectory)) | Sort-Object -Unique) {
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

function Resolve-ExternalCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        foreach ($candidateName in @("$Name.ps1", "$Name.cmd", "$Name.exe")) {
            $command = Get-Command $candidateName -ErrorAction SilentlyContinue
            if ($null -ne $command) { break }
        }
    }
    if ($null -eq $command) {
        return $null
    }

    $source = [string]$command.Source
    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) {
            return $null
        }
        return [pscustomobject]@{ FileName = [string]$pwsh.Source; Prefix = @('-NoProfile', '-File', $source); Source = $source }
    }

    return [pscustomobject]@{ FileName = $source; Prefix = @(); Source = $source }
}

function Invoke-RunnerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [System.Collections.IDictionary]$Environment = @{},
        [AllowEmptyCollection()][byte[]]$InputBytes = @(),
        [int]$TimeoutSeconds = 900
    )

    $start = [DateTime]::UtcNow
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($ArgumentList)) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $startInfo.Environment.Clear()
    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start '$FileName'."
        }

        if ($null -ne $InputBytes -and $InputBytes.Length -gt 0) {
            $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [Math]::Min([int64]::MaxValue, [int64]$TimeoutSeconds * 1000)
        $exited = $process.WaitForExit([int]([Math]::Min($timeoutMilliseconds, [int]::MaxValue)))
        $timedOut = -not $exited
        if ($timedOut) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $finish = [DateTime]::UtcNow

        return [pscustomobject]@{
            ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
            TimedOut = $timedOut
            Stdout = $stdout
            Stderr = $stderr
            StartedUtc = $start
            FinishedUtc = $finish
            DurationSeconds = [Math]::Round(($finish - $start).TotalSeconds, 3)
        }
    } finally {
        $process.Dispose()
    }
}

function Get-ProviderAuthenticationVariables {
    param([string]$Provider)

    $normalized = ([string]$Provider).ToLowerInvariant()
    switch -Regex ($normalized) {
        '^openai$|^chatgpt$' { return @('OPENAI_API_KEY') }
        '^anthropic$' { return @('ANTHROPIC_API_KEY') }
        '^google$|^google-vertex$|^gemini$' { return @('GOOGLE_API_KEY', 'GEMINI_API_KEY') }
        '^openrouter$' { return @('OPENROUTER_API_KEY') }
        '^xai$|^x-ai$' { return @('XAI_API_KEY') }
        '^mistral$' { return @('MISTRAL_API_KEY') }

        default { return @() }
    }
}

function Test-EnvironmentVariablePresent {
    param([string[]]$Names)

    foreach ($name in @($Names)) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return $true
        }
    }
    return $false
}

function New-ArtifactReference {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('run', 'package')][string]$Scope = 'run',
        [string]$MediaType = 'application/octet-stream'
    )

    Assert-SafeRelativePath -RelativePath $Path -FieldName 'artifact.path'
    $base = if ($Scope -eq 'run') { $Run.RunRoot } else { Split-Path -Parent (Split-Path -Parent $Run.RunRoot) }
    $full = Resolve-ContainedPath -BasePath $base -RelativePath $Path -FieldName 'artifact.path' -Kind File
    return [ordered]@{
        path = $Path.Replace('\', '/')
        scope = $Scope
        sha256 = Get-Sha256HexFromFile -Path $full
        size = (Get-Item -LiteralPath $full).Length
        media_type = $MediaType
    }
}

function Get-MediaType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.jsonl' { return 'application/x-ndjson' }
        '.json' { return 'application/json' }
        '.txt' { return 'text/plain; charset=utf-8' }
        '.md' { return 'text/markdown; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function ConvertFrom-JsonLines {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $events = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add(($line | ConvertFrom-Json))
        } catch {
            $errors.Add("line ${lineNumber}: $($_.Exception.Message)")
        }
    }
    return [pscustomobject]@{ Events = @($events); Errors = @($errors) }
}

function Get-OutputTextFromFinalResponse {
    param([object]$Result)

    if ([string](Get-JsonProperty -Object $Result.final_response -Name 'status' -Default '') -eq 'available') {
        return [string]$Result.final_response.text
    }
    return $null
}
