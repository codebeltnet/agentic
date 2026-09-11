<#
.SYNOPSIS
    Executes .NET file-based apps without paying the `dotnet run --file` CLI overhead per call.

.DESCRIPTION
    `dotnet run --file` re-evaluates the SDK, restore graph, and MSBuild pipeline on every
    invocation. On a current SDK that costs several seconds even when the built output is already
    up to date and the app itself runs in a fraction of a second. Deterministic validation suites
    invoke the same file-based app dozens of times per run, so that fixed cost dominates their
    runtime.

    Get-FileBasedAppCommand builds the app once per source revision and returns the command that
    executes the built assembly directly. The executed code, the arguments, the current directory,
    and the environment are identical to `dotnet run --file`; only the redundant SDK startup is
    removed. The build cache is content-addressed by source hash plus SDK version and lives outside
    the repository, under the user temp directory.

    This helper caches a build artifact, never a validation result. Every assertion still runs on
    every execution. When the cache cannot be prepared for any reason the helper falls back to
    `dotnet run --file`, so a caller is never worse off than before.

    Callers keep full control of redirection and exit codes:

        $app = Get-FileBasedAppCommand -SourcePath $ValidatorPath
        $output = & $app.Executable @($app.ArgumentPrefix + @('--repo-root', $Workspace, '--json')) 2>$null
#>

$script:FileBasedAppCache = @{}
$script:FileBasedAppSdkVersion = $null

function Get-FileBasedAppCacheRoot {
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'agentic-file-based-app-cache')
}

function Get-FileBasedAppSdkVersion {
    if ($null -ne $script:FileBasedAppSdkVersion) {
        return $script:FileBasedAppSdkVersion
    }

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $version = & dotnet --version 2>$null | Select-Object -First 1
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    $script:FileBasedAppSdkVersion = if ([string]::IsNullOrWhiteSpace([string]$version)) { 'unknown' } else { ([string]$version).Trim() }
    return $script:FileBasedAppSdkVersion
}

function Get-FileBasedAppFallbackCommand {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    return [pscustomobject]@{
        Executable     = 'dotnet'
        ArgumentPrefix = @('run', '--file', $SourcePath, '--')
        Mode           = 'dotnet-run'
        Assembly       = $null
    }
}

function Find-FileBasedAppAssembly {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$AssemblyName
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    $assembly = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $AssemblyName -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        Select-Object -First 1

    if ($null -eq $assembly) {
        return $null
    }

    return $assembly.FullName
}

function Build-FileBasedAppRevision {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$RevisionDirectory,
        [Parameter(Mandatory = $true)][string]$AssemblyName
    )

    $cacheRoot = Split-Path -Parent $RevisionDirectory
    $staging = Join-Path $cacheRoot ('.staging-' + [Guid]::NewGuid().ToString('N'))

    $previousErrorAction = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name 'PSNativeCommandUseErrorActionPreference' -ErrorAction SilentlyContinue
    if ($null -ne $nativePreferenceVariable) {
        $previousNativePreference = $nativePreferenceVariable.Value
    }
    $ErrorActionPreference = 'Continue'
    if ($null -ne $nativePreferenceVariable) {
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        & dotnet build $SourcePath --artifacts-path $staging --nologo -v quiet 1>$null 2>$null
        $buildExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
        if ($null -ne $nativePreferenceVariable) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($buildExitCode -ne 0) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    if ($null -eq (Find-FileBasedAppAssembly -Root $staging -AssemblyName $AssemblyName)) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    if (Test-Path -LiteralPath $RevisionDirectory) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $RevisionDirectory
    }

    try {
        [System.IO.Directory]::Move($staging, $RevisionDirectory)
    } catch {
        # A concurrent suite built the same revision first; prefer that copy.
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $RevisionDirectory)) {
            return $null
        }
    }

    return $RevisionDirectory
}

function Remove-StaleFileBasedAppRevisions {
    param(
        [Parameter(Mandatory = $true)][string]$AppDirectory,
        [Parameter(Mandatory = $true)][string]$KeepRevision
    )

    Get-ChildItem -LiteralPath $AppDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $KeepRevision } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-FileBasedAppCommand {
    <#
    .SYNOPSIS
        Resolves the command that runs a file-based app, building it once per revision.
    .OUTPUTS
        An object with Executable, ArgumentPrefix, Mode, and Assembly. Append the app's own
        arguments to ArgumentPrefix and invoke Executable, e.g.
        `& $command.Executable @($command.ArgumentPrefix + $arguments)`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$NoCache
    )

    if ($NoCache) {
        return (Get-FileBasedAppFallbackCommand -SourcePath $SourcePath)
    }

    try {
        $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
    } catch {
        return (Get-FileBasedAppFallbackCommand -SourcePath $SourcePath)
    }

    $cacheKey = $source + '|' + (Get-FileBasedAppSdkVersion)
    if ($script:FileBasedAppCache.ContainsKey($cacheKey)) {
        return $script:FileBasedAppCache[$cacheKey]
    }

    $fallback = Get-FileBasedAppFallbackCommand -SourcePath $source

    try {
        $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($source) + '.dll'
        $sdkTag = [regex]::Replace((Get-FileBasedAppSdkVersion), '[^A-Za-z0-9._-]', '_')
        $revision = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash + '-' + $sdkTag
        $appDirectory = Join-Path (Get-FileBasedAppCacheRoot) ([System.IO.Path]::GetFileNameWithoutExtension($source))
        $revisionDirectory = Join-Path $appDirectory $revision

        $assembly = Find-FileBasedAppAssembly -Root $revisionDirectory -AssemblyName $assemblyName
        if ($null -eq $assembly) {
            [void](Build-FileBasedAppRevision -SourcePath $source -RevisionDirectory $revisionDirectory -AssemblyName $assemblyName)
            $assembly = Find-FileBasedAppAssembly -Root $revisionDirectory -AssemblyName $assemblyName
        }

        if ($null -eq $assembly) {
            $script:FileBasedAppCache[$cacheKey] = $fallback
            return $fallback
        }

        Remove-StaleFileBasedAppRevisions -AppDirectory $appDirectory -KeepRevision $revision

        $command = [pscustomobject]@{
            Executable     = 'dotnet'
            ArgumentPrefix = @($assembly)
            Mode           = 'cached-assembly'
            Assembly       = $assembly
        }
        $script:FileBasedAppCache[$cacheKey] = $command
        return $command
    } catch {
        $script:FileBasedAppCache[$cacheKey] = $fallback
        return $fallback
    }
}
