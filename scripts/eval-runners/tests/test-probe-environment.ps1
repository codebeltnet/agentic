<#
.SYNOPSIS
    Regression: model-free harness probe temp resolution and probe/eval environment separation.
.DESCRIPTION
    Two MODEL-FREE deterministic regressions:

      1. The iteration-11 failure. The model-free descriptor/version probe must
         always have a writable temporary directory and must never fall back to
         %WINDIR% via [System.IO.Path]::GetTempPath() when TEMP/TMP/USERPROFILE
         are stripped. A normal, non-elevated Windows user must never need write
         access to C:\Windows for a --version/--help/describe probe.

      2. The probe-vs-eval boundary. The model-free probe environment carries OS
         scratch TEMP/TMP but no isolated home and no ambient skill/config policy,
         while the model-backed OpenCode eval environment pins HOME/USERPROFILE/
         config/TEMP inside the isolated per-run home and disables ambient shared
         skill discovery. The two must remain distinct concepts.

    No model is ever executed. The only external processes are `opencode describe`
    (a version/help probe) and `pwsh --version`.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')

function Assert-True { param([bool]$c, [string]$m) if (-not $c) { throw "ASSERT: $m" } }
function Assert-False { param([bool]$c, [string]$m) if ($c) { throw "ASSERT: $m" } }
function Assert-Equal { param($e, $a, [string]$m) if ([string]$e -ne [string]$a) { throw "ASSERT: $m (expected '$e', got '$a')" } }

function Import-OpenCodeRunnerFunctions {
    if ($null -ne (Get-Command New-OpenCodeEnvironment -CommandType Function -ErrorAction SilentlyContinue)) { return }
    $tokens = $null
    $errors = $null
    $openCodeRunnerPath = Join-Path $runnerRoot 'opencode\runner.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($openCodeRunnerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'probe-environment regression could not parse opencode runner.ps1.' }
    $functionAsts = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Sort-Object { $_.Extent.StartOffset })
    foreach ($functionAst in $functionAsts) {
        $definition = [regex]::Replace($functionAst.Extent.Text, ('(?im)^function\s+' + [regex]::Escape($functionAst.Name) + '\b'), ('function script:' + $functionAst.Name), 1)
        Invoke-Expression $definition
    }
}

$systemDirectories = Get-RunnerSystemDirectorySet

function Test-IsSystemDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    return $systemDirectories.Contains($full.TrimEnd([char[]]@('\', '/')))
}

function Invoke-ProbeEnvironmentChild {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)

    # Applies New-RunnerProbeEnvironment to a child EXACTLY as Invoke-RunnerProcess
    # does: a cleared process environment populated only from the probe dictionary.
    # This reproduces the stripped-environment context that resolved GetTempPath()
    # to C:\WINDOWS in iteration-11.
    $probeEnvironment = New-RunnerProbeEnvironment
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.WorkingDirectory = $runnerRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    foreach ($key in $probeEnvironment.Keys) { $startInfo.Environment[[string]$key] = [string]$probeEnvironment[$key] }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if (-not $process.WaitForExit(60000)) {
        try { $process.Kill($true) } catch { }
        throw 'probe-environment child process exceeded its finite test wait.'
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-probe-env-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    # =====================================================================
    # Scenario 1 (item #7): a model-free probe always has a writable temp and
    # never uses %WINDIR% - the exact iteration-11 descriptor/version failure.
    # =====================================================================

    # 1a: the shared resolver returns a writable, non-system directory.
    $resolvedRoot = Resolve-RunnerProbeTempRoot
    Assert-True (Test-RunnerDirectoryWritable -Path $resolvedRoot) 'resolved probe temp root must be writable'
    Assert-False (Test-IsSystemDirectory -Path $resolvedRoot) 'resolved probe temp root must not be a Windows/system directory'

    # 1b: the probe environment pins a writable TEMP and TMP.
    $probeEnvironment = New-RunnerProbeEnvironment
    Assert-True ($probeEnvironment.Contains('TEMP') -and $probeEnvironment.Contains('TMP')) 'probe environment must set TEMP and TMP'
    Assert-Equal ([string]$probeEnvironment['TEMP']) ([string]$probeEnvironment['TMP']) 'probe TEMP and TMP must point at one directory'
    Assert-True (Test-RunnerDirectoryWritable -Path ([string]$probeEnvironment['TEMP'])) 'probe TEMP must be writable'
    Assert-False (Test-IsSystemDirectory -Path ([string]$probeEnvironment['TEMP'])) 'probe TEMP must not be a Windows/system directory'

    # 1c: elevation-independent rejection. Even when TEMP/TMP are forced to the
    # Windows directory (which an elevated user CAN write to), the resolver must
    # never return it. This is the guarantee that makes elevation irrelevant.
    $windowsDirectory = [Environment]::GetEnvironmentVariable('WINDIR')
    if (-not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $originalTemp = [Environment]::GetEnvironmentVariable('TEMP')
        $originalTmp = [Environment]::GetEnvironmentVariable('TMP')
        try {
            [Environment]::SetEnvironmentVariable('TEMP', $windowsDirectory)
            [Environment]::SetEnvironmentVariable('TMP', $windowsDirectory)
            $forcedRoot = Resolve-RunnerProbeTempRoot
            Assert-False (Test-IsSystemDirectory -Path $forcedRoot) 'resolver must reject a Windows-directory TEMP even when it is writable'
            $forcedEnvironment = New-RunnerProbeEnvironment
            Assert-False (Test-IsSystemDirectory -Path ([string]$forcedEnvironment['TEMP'])) 'probe environment must not fall back to %WINDIR% when TEMP points at it'
        } finally {
            [Environment]::SetEnvironmentVariable('TEMP', $originalTemp)
            [Environment]::SetEnvironmentVariable('TMP', $originalTmp)
        }
    }

    # 1d: the exact iteration-11 command. `opencode/runner.ps1 describe` under the
    # stripped probe environment must exit 0 and return a valid descriptor. When
    # the OpenCode CLI is installed this runs `opencode --version` through the
    # probe temp; before the fix it failed with an access-denied to C:\WINDOWS.
    $openCodeRunnerPath = Join-Path $runnerRoot 'opencode\runner.ps1'
    $describe = Invoke-ProbeEnvironmentChild -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $openCodeRunnerPath, 'describe')
    Assert-Equal 0 $describe.ExitCode "opencode describe under the probe environment must exit 0 (stderr: $($describe.Stderr))"
    $descriptor = $describe.Stdout | ConvertFrom-Json
    Assert-Equal 'opencode' ([string]$descriptor.name) 'opencode describe must return the opencode descriptor'
    Assert-False ([string]::IsNullOrWhiteSpace([string]$descriptor.harness.version)) 'opencode describe must report a harness version (real or "unavailable")'

    # 1e: inside a stripped probe child, a real --version probe creates its scratch
    # under the writable temp and never touches %WINDIR%. Uses pwsh --version, so
    # it is fully model-free.
    $childScriptPath = Join-Path $testRoot 'probe-version-child.ps1'
    $childScript = @'
param([Parameter(Mandatory = $true)][string]$CommonPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $CommonPath
$getTempPath = [System.IO.Path]::GetTempPath()
$resolved = Resolve-RunnerProbeTempRoot
$systemDirectories = Get-RunnerSystemDirectorySet
$pwshInfo = Resolve-ExternalCommand -Name 'pwsh'
$version = Get-ExternalCommandVersion -CommandInfo $pwshInfo
[ordered]@{
    process_temp_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TEMP'))
    get_temp_path_is_system = $systemDirectories.Contains(([System.IO.Path]::GetFullPath($getTempPath)).TrimEnd([char[]]@('\', '/')))
    resolved_is_system = $systemDirectories.Contains(([System.IO.Path]::GetFullPath($resolved)).TrimEnd([char[]]@('\', '/')))
    version_available = [bool]$version.Available
} | ConvertTo-Json -Compress
'@
    [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))
    $commonPath = (Resolve-Path (Join-Path $runnerRoot 'runner-common.ps1')).Path
    $childProbe = Invoke-ProbeEnvironmentChild -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $childScriptPath, '-CommonPath', $commonPath)
    Assert-Equal 0 $childProbe.ExitCode "stripped-child version probe must exit 0 (stderr: $($childProbe.Stderr))"
    $childSummary = $childProbe.Stdout | ConvertFrom-Json
    Assert-True ([bool]$childSummary.process_temp_present) 'probe child must inherit an explicit TEMP from the probe environment'
    Assert-False ([bool]$childSummary.get_temp_path_is_system) 'probe child GetTempPath() must not resolve to a system directory'
    Assert-False ([bool]$childSummary.resolved_is_system) 'probe child resolver must not return a system directory'
    Assert-True ([bool]$childSummary.version_available) 'model-free pwsh --version probe must succeed under the probe environment'

    # =====================================================================
    # Scenario 2 (item #8): the model-free probe environment and the model-backed
    # OpenCode eval isolation environment are distinct and must not be merged.
    # =====================================================================
    Import-OpenCodeRunnerFunctions

    $separationRoot = Join-Path $testRoot 'separation'
    $withoutRoot = Join-Path $separationRoot 'without_skill'
    $isolatedHome = Join-Path $withoutRoot 'home'
    $isolatedRepo = Join-Path $withoutRoot 'repo'
    New-Item -ItemType Directory -Path $isolatedHome, $isolatedRepo -Force | Out-Null

    # Ambient host canary: a real user's OPENCODE_CONFIG must not leak into the
    # model-backed eval environment.
    $ambientConfigCanary = Join-Path $testRoot 'ambient-user-opencode.json'
    [System.IO.File]::WriteAllText($ambientConfigCanary, '{"ambient_user_config":true}', [System.Text.UTF8Encoding]::new($false))
    $originalOpenCodeConfig = [Environment]::GetEnvironmentVariable('OPENCODE_CONFIG')
    try {
        [Environment]::SetEnvironmentVariable('OPENCODE_CONFIG', $ambientConfigCanary)

        $inputsWithout = [pscustomobject]@{
            Run = [pscustomobject]@{
                HomeDirectoryPath = $isolatedHome
                WorkingDirectoryPath = $isolatedRepo
                CandidateSkillExposed = $false
                SkillDirectoryPath = $null
                SkillHash = $null
                Contract = [pscustomobject]@{}
            }
            Profile = [pscustomobject]@{ Model = 'fixture-model'; ReasoningEffort = 'high' }
        }
        $evalEnvironment = New-OpenCodeEnvironment -Inputs $inputsWithout

        # The eval environment identifies the isolated home, not the host profile.
        Assert-True ($evalEnvironment.Contains('HOME')) 'eval environment must set HOME'
        Assert-True (Test-PathInside -BasePath $isolatedHome -CandidatePath ([string]$evalEnvironment['HOME'])) 'eval HOME must be inside the isolated run home'
        Assert-True (Test-PathInside -BasePath $isolatedHome -CandidatePath ([string]$evalEnvironment['USERPROFILE'])) 'eval USERPROFILE must be inside the isolated run home'
        Assert-True (Test-PathInside -BasePath $isolatedHome -CandidatePath ([string]$evalEnvironment['OPENCODE_CONFIG'])) 'eval OPENCODE_CONFIG must be inside the isolated run home'
        Assert-False (Test-OpenCodePathEqual -Expected $ambientConfigCanary -Observed ([string]$evalEnvironment['OPENCODE_CONFIG'])) 'eval OPENCODE_CONFIG must not be the ambient host config'
        Assert-Equal '1' ([string]$evalEnvironment['OPENCODE_DISABLE_EXTERNAL_SKILLS']) 'eval environment must disable external skill scans'
        Assert-Equal '1' ([string]$evalEnvironment['OPENCODE_DISABLE_CLAUDE_CODE_SKILLS']) 'eval environment must disable Claude-compatible skill scans'
        Assert-True (Test-PathInside -BasePath $isolatedHome -CandidatePath ([string]$evalEnvironment['TEMP'])) 'eval TEMP must be inside the isolated run home'
        Assert-False ($evalEnvironment.Contains('NODE_PATH')) 'eval environment must not carry NODE_PATH'

        $withoutConfig = [System.IO.File]::ReadAllText([string]$evalEnvironment['OPENCODE_CONFIG'], [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        Assert-Equal 'deny' ([string]$withoutConfig.permission.skill) 'without_skill eval config must deny all skills'

        # The model-free probe environment is NOT the eval environment.
        $probeEnvironmentForSeparation = New-RunnerProbeEnvironment
        Assert-False ($probeEnvironmentForSeparation.Contains('HOME')) 'probe environment must not carry HOME'
        Assert-False ($probeEnvironmentForSeparation.Contains('USERPROFILE')) 'probe environment must not carry USERPROFILE'
        Assert-False ($probeEnvironmentForSeparation.Contains('XDG_CONFIG_HOME')) 'probe environment must not carry XDG_CONFIG_HOME'
        Assert-False ($probeEnvironmentForSeparation.Contains('OPENCODE_CONFIG')) 'probe environment must not carry OPENCODE_CONFIG'
        Assert-False ($probeEnvironmentForSeparation.Contains('OPENCODE_DISABLE_EXTERNAL_SKILLS')) 'probe environment must not carry the eval skill-scan policy'
        Assert-True ($probeEnvironmentForSeparation.Contains('TEMP')) 'probe environment must carry OS scratch TEMP'
        Assert-False (Test-PathInside -BasePath $isolatedHome -CandidatePath ([string]$probeEnvironmentForSeparation['TEMP'])) 'probe TEMP is OS scratch, not the isolated home'
        Assert-False (Test-OpenCodePathEqual -Expected ([string]$evalEnvironment['TEMP']) -Observed ([string]$probeEnvironmentForSeparation['TEMP'])) 'probe temp and eval temp must be distinct locations'
    } finally {
        [Environment]::SetEnvironmentVariable('OPENCODE_CONFIG', $originalOpenCodeConfig)
    }

    # with_skill exposes ONLY the prepared candidate and denies everything else.
    $withRoot = Join-Path $separationRoot 'with_skill'
    $withHome = Join-Path $withRoot 'home'
    $withRepo = Join-Path $withRoot 'repo'
    $stagedCandidate = Join-Path (Join-Path $withRoot 'skill') 'dotnet-strong-name-signing'
    New-Item -ItemType Directory -Path $withHome, $withRepo, $stagedCandidate -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stagedCandidate 'SKILL.md'), '# candidate', [System.Text.UTF8Encoding]::new($false))
    $inputsWith = [pscustomobject]@{
        Run = [pscustomobject]@{
            HomeDirectoryPath = $withHome
            WorkingDirectoryPath = $withRepo
            CandidateSkillExposed = $true
            SkillDirectoryPath = $stagedCandidate
            SkillHash = ('a' * 64)
            Contract = [pscustomobject]@{ skillName = 'dotnet-strong-name-signing' }
        }
        Profile = [pscustomobject]@{ Model = 'fixture-model'; ReasoningEffort = 'high' }
    }
    $evalEnvironmentWith = New-OpenCodeEnvironment -Inputs $inputsWith
    Assert-Equal 'dotnet-strong-name-signing' (Get-OpenCodeCandidateSkillName -Run $inputsWith.Run) 'candidate skill name resolves from the staged package'
    $withConfig = [System.IO.File]::ReadAllText([string]$evalEnvironmentWith['OPENCODE_CONFIG'], [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Equal 'deny' ([string]$withConfig.permission.skill.'*') 'with_skill eval config must deny all skills by default'
    Assert-Equal 'allow' ([string]$withConfig.permission.skill.'dotnet-strong-name-signing') 'with_skill eval config must allow only the prepared candidate'

    Write-Output 'Probe environment regression: PASS'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
