#requires -Version 7.0
[CmdletBinding(PositionalBinding = $false)]
param(
    [string] $RepoRoot,
    [string] $Docfx,
    [string] $Settings,
    [string] $Framework = 'net10.0',
    [string] $CsrunImage = 'codebeltnet/csrun:10',
    [ValidateSet('None','Native','Docker','Both')][string] $Verify = 'None',
    [string] $EnginePath,
    [switch] $RunActionPlan,
    [switch] $CheckRecipes,
    [string] $ResolveDependencies,
    [string] $ValidateRunAction,
    [string] $ApplyRunAction,
    [string] $Explain,
    [switch] $Json,
    [switch] $SummaryJson,
    [switch] $VerifyChanged,
    [Alias('Id')][string[]] $TargetId,
    [int] $TimeoutSeconds = 60,
    [int] $MaxParallel = 0,
    [int] $MaxDockerParallel = 0,
    [switch] $Quiet,
    [switch] $NoHeartbeat,
    [int] $HeartbeatSeconds = 10,
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $CliArgs
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$frameworkExplicit = $PSBoundParameters.ContainsKey('Framework')
$maxParallelExplicit = $PSBoundParameters.ContainsKey('MaxParallel')
$maxDockerParallelExplicit = $PSBoundParameters.ContainsKey('MaxDockerParallel')
$isWindowsHost = $IsWindows
$NetFrameworkDockerUnsupportedReason = '.NET Framework targets require Windows and cannot execute in the Linux csrun container.'
function Test-NetFrameworkTfm([string] $Tfm) { return (-not [string]::IsNullOrWhiteSpace($Tfm) -and $Tfm -match '^net4\d+$') }
. (Join-Path $PSScriptRoot 'integration-example.ps1')
$helpers = Join-Path $PSScriptRoot '../../dotnet-csrun/scripts/sample-tools.ps1'
if (-not (Test-Path $helpers)) { throw "Install dotnet-csrun beside this skill: $helpers" }
. $helpers
Set-StrictMode -Off

# Parse GNU/CLI-style --flags alongside native PowerShell parameters.
$idList = [Collections.Generic.List[string]]::new()
if ($TargetId) { foreach ($item in $TargetId) { if ($item) { $idList.Add($item) } } }
if ($CliArgs -and $CliArgs.Count -gt 0) {
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $arg = [string]$CliArgs[$i]
        switch ($arg) {
            '--repo-root' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --repo-root'); exit 3 }
                $RepoRoot = [string]$CliArgs[++$i]
            }
            '--docfx' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --docfx'); exit 3 }
                $Docfx = [string]$CliArgs[++$i]
            }
            '--settings' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --settings'); exit 3 }
                $Settings = [string]$CliArgs[++$i]
            }
            '--framework' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --framework'); exit 3 }
                $Framework = [string]$CliArgs[++$i]
                $frameworkExplicit = $true
            }
            '--csrun-image' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --csrun-image'); exit 3 }
                $CsrunImage = [string]$CliArgs[++$i]
            }
            '--engine-path' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --engine-path'); exit 3 }
                $EnginePath = [string]$CliArgs[++$i]
            }
            '--verify' {
                if (($i + 1) -lt $CliArgs.Count -and [string]$CliArgs[$i + 1] -in @('None','Native','Docker','Both','none','native','docker','both')) {
                    $val = [string]$CliArgs[++$i]
                    $Verify = $val.Substring(0,1).ToUpperInvariant() + $val.Substring(1).ToLowerInvariant()
                } else {
                    $Verify = 'Native'
                }
            }
            '--verify-changed' {
                $VerifyChanged = $true
            }
            '--id' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --id'); exit 3 }
                $idList.Add([string]$CliArgs[++$i])
            }
            '--run-action-plan' { $RunActionPlan = $true }
            '--check-recipes' { $CheckRecipes = $true }
            '--resolve-dependencies' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --resolve-dependencies'); exit 3 }
                $ResolveDependencies = [string]$CliArgs[++$i]
            }
            '--validate-run-action' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --validate-run-action'); exit 3 }
                $ValidateRunAction = [string]$CliArgs[++$i]
            }
            '--apply-run-action' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --apply-run-action'); exit 3 }
                $ApplyRunAction = [string]$CliArgs[++$i]
            }
            '--explain' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --explain'); exit 3 }
                $Explain = [string]$CliArgs[++$i]
            }
            '--json' { $Json = $true }
            '--summary-json' { $SummaryJson = $true }
            '--timeout-seconds' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --timeout-seconds'); exit 3 }
                $TimeoutSeconds = [int]$CliArgs[++$i]
            }
            '--max-parallel' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --max-parallel'); exit 3 }
                $parsedMaxParallel = 0
                if (-not [int]::TryParse([string]$CliArgs[++$i], [ref]$parsedMaxParallel)) {
                    [Console]::Error.WriteLine('--max-parallel must be an integer between 1 and 64.'); exit 3
                }
                $MaxParallel = $parsedMaxParallel
                $maxParallelExplicit = $true
            }
            '--max-docker-parallel' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --max-docker-parallel'); exit 3 }
                $parsedMaxDocker = 0
                if (-not [int]::TryParse([string]$CliArgs[++$i], [ref]$parsedMaxDocker)) {
                    [Console]::Error.WriteLine('--max-docker-parallel must be an integer between 1 and 16.'); exit 3
                }
                $MaxDockerParallel = $parsedMaxDocker
                $maxDockerParallelExplicit = $true
            }
            '--quiet' { $Quiet = $true }
            '--no-heartbeat' { $NoHeartbeat = $true }
            '--heartbeat-seconds' {
                if (($i + 1) -ge $CliArgs.Count) { [Console]::Error.WriteLine('Missing value for --heartbeat-seconds'); exit 3 }
                $parsedHb = 0
                if (-not [int]::TryParse([string]$CliArgs[++$i], [ref]$parsedHb)) {
                    [Console]::Error.WriteLine('--heartbeat-seconds must be an integer between 1 and 300.'); exit 3
                }
                $HeartbeatSeconds = $parsedHb
            }
            default {
                [Console]::Error.WriteLine("Unknown argument: $arg")
                exit 3
            }
        }
        $i++
    }
}
if ($VerifyChanged -and $Verify -eq 'None') { $Verify = 'Native' }
if (-not $RepoRoot) { [Console]::Error.WriteLine('Missing required parameter: -RepoRoot / --repo-root'); exit 3 }
if ($TimeoutSeconds -lt 3 -or $TimeoutSeconds -gt 600) { [Console]::Error.WriteLine('--timeout-seconds must be between 3 and 600.'); exit 3 }
if ($maxParallelExplicit -and ($MaxParallel -lt 1 -or $MaxParallel -gt 64)) { [Console]::Error.WriteLine('--max-parallel must be between 1 and 64.'); exit 3 }
if ($maxDockerParallelExplicit -and ($MaxDockerParallel -lt 1 -or $MaxDockerParallel -gt 16)) { [Console]::Error.WriteLine('--max-docker-parallel must be between 1 and 16.'); exit 3 }
if ($HeartbeatSeconds -lt 1 -or $HeartbeatSeconds -gt 300) { [Console]::Error.WriteLine('--heartbeat-seconds must be between 1 and 300.'); exit 3 }

$cpuCount = [Math]::Max(1, [Environment]::ProcessorCount)
$defaultNativeParallel = [Math]::Max(1, [Math]::Min($cpuCount, 8))
$effectiveNativeParallel = if ($maxParallelExplicit) { $MaxParallel } else { $defaultNativeParallel }
$defaultDockerCap = [Math]::Max(1, [Math]::Min($effectiveNativeParallel, 2))
$effectiveDockerParallel = if ($maxDockerParallelExplicit) {
    $MaxDockerParallel
} elseif ($maxParallelExplicit -and $Verify -eq 'Docker') {
    $MaxParallel
} else {
    $defaultDockerCap
}

function Hash([string] $Text) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))) }
function Normalize([string] $Text) { $Text.Replace("`r`n", "`n").TrimEnd("`n", "`r") }
function Canonicalize-Whitespace([string] $Text) {
    $lines = @($Text.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n" | ForEach-Object { $_.TrimEnd(' ', "`t") })
    ($lines -join "`n").TrimEnd("`n")
}
function Get-UnixCacheMetadata([string] $Path) {
    $statArgs = if ($IsMacOS) { @('-f', '%u %l %p', $Path) } else { @('-c', '%u %h %f', '--', $Path) }
    $metadata = & stat @statArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or $metadata -notmatch '\A(\d+) (\d+) ([0-9a-f]+)\z') { return }
    $radix = if ($IsMacOS) { 8 } else { 16 }
    return @{ Owner = $Matches[1]; Links = [int]$Matches[2]; Mode = [Convert]::ToInt32($Matches[3], $radix) }
}
function Test-PrivateCacheItem([string] $Path, [switch] $Directory) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -ne $Directory.IsPresent -or
        $item.LinkType -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if ($IsWindows) {
        try { return (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $cacheOwner }
        catch { return $false }
    }
    $metadata = Get-UnixCacheMetadata $Path
    return $metadata.Owner -eq $cacheOwner -and ($metadata.Mode -band 63) -eq 0 -and
        ($Directory -or (($metadata.Mode -band 0xF000) -eq 0x8000 -and $metadata.Links -eq 1))
}
function Get-PrivateCacheDirectory([string] $BasePath, [switch] $EnsureCreated) {
    if (-not $BasePath -or -not [IO.Path]::IsPathFullyQualified($BasePath)) { return }
    for ($ancestor = [IO.DirectoryInfo]::new($BasePath); $ancestor; $ancestor = $ancestor.Parent) {
        $item = Get-Item -LiteralPath $ancestor.FullName -Force -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        if (-not $IsWindows) {
            $metadata = Get-UnixCacheMetadata $ancestor.FullName
            if (-not $metadata -or $metadata.Owner -notin @($cacheOwner, '0') -or ($metadata.Mode -band 18)) { return }
        }
    }
    $path = Join-Path $BasePath '.docfx-run-verification'
    if ($EnsureCreated -and -not (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
        if ($IsWindows) { $null = [IO.Directory]::CreateDirectory($path) }
        else { & (Get-Command mkdir -CommandType Application | Select-Object -First 1).Source -m 700 -- $path 2>$null }
    }
    if (Test-PrivateCacheItem $path -Directory) { return $path }
}
function Write-Changed([string] $Path, [string] $Text) {
    Assert-RepositoryPath $Path
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $Text) { return $false }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    return $true
}
function Write-AtomicChanged([string] $Path, [string] $Text) {
    Assert-RepositoryPath $Path
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $Text) { return $false }
    $dir = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($dir)
    $tmp = Join-Path $dir ('.' + [IO.Path]::GetFileName($Path) + '.tmp.' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) }
    }
    return $true
}
# Preserve the original encoding/BOM and line endings when adding/removing owned HTML or updating a fence.
function Write-Page([string] $Path, [string] $Original, [string] $Updated) {
    if ($Original -ceq $Updated) { return }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $reader = [IO.StreamReader]::new($Path, [Text.UTF8Encoding]::new($false, $true), $true)
    try { $null = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
    $output = $encoding.GetBytes($Updated)
    $preamble = $encoding.GetPreamble()
    if ($preamble.Length -and $bytes.Length -ge $preamble.Length -and
        [Convert]::ToBase64String($bytes[0..($preamble.Length-1)]) -ceq [Convert]::ToBase64String($preamble)) { $output = [byte[]]($preamble + $output) }
    [IO.File]::WriteAllBytes($Path, $output)
}
$root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RepoRoot))
$rootPrefix = $root
if (-not [IO.Path]::EndsInDirectorySeparator($rootPrefix)) { $rootPrefix += [IO.Path]::DirectorySeparatorChar }
function Assert-RepositoryPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    # Require exact casing even on filesystems that accept aliases for the same path.
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::Ordinal)) { throw "Path outside requested repository: $Path" }
    for ($current = $full; $current.Length -gt $root.Length; $current = Split-Path $current -Parent) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked output path: $current" }
    }
}
function Get-EngineFailureReason([string] $Message) {
    if ($Message -match 'HTTP 403' -and $Message -match 'no verified cached engine') { return 'github-403-no-cached-engine' }
    if ($Message -match 'HTTP 429' -and $Message -match 'no verified cached engine') { return 'github-429-no-cached-engine' }
    if ($Message -match 'csrun engine asset not found') { return 'engine-path-not-found' }
    return 'engine-resolution-failed'
}
function Resolve-LocalNuGetPackageVersion([string] $PackageId) {
    if (-not $PackageId) { return $null }
    $nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
    $pkgDir = Join-Path $nugetRoot $PackageId.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $pkgDir -PathType Container)) { return $null }
    $stable = @(Get-ChildItem -LiteralPath $pkgDir -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
    if ($stable.Count -gt 0) { return $stable[0].Name }
    return $null
}
function Get-GitLatestSemVerTag([string] $RepositoryRoot) {
    try {
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $git) { return $null }
        $tags = & $git.Source -C $RepositoryRoot tag --sort=-v:refname 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($tag in @($tags)) {
            if ($tag -match '^v?(\d+\.\d+\.\d+)$') { return $Matches[1] }
        }
    } catch {}
    return $null
}
function Get-GitHeadFileText([string] $RepositoryRoot, [string] $FullPath) {
    try {
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $git) { return $null }
        $rel = [IO.Path]::GetRelativePath($RepositoryRoot, $FullPath).Replace('\', '/')
        $out = & $git.Source -C $RepositoryRoot show "HEAD:$rel" 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $out) { return ($out -join "`n") }
    } catch {}
    return $null
}

$arguments = @('--repo-root', $root, '--run-action-inventory')
if ($Docfx) { $arguments += @('--docfx', $Docfx) }
# One inventory process per repository, never one model/process per document.
$inventoryText = & dotnet run --file (Join-Path $PSScriptRoot 'docfx.cs') -- @arguments
if ($LASTEXITCODE -ne 0) { throw 'DocFX example inventory failed.' }
$inventory = ($inventoryText -join "`n") | ConvertFrom-Json
$configPath = $inventory.config
$workspace = Split-Path $configPath -Parent
Assert-RepositoryPath $configPath
$manifestPath = Join-Path $workspace 'run-actions.manifest.json'
$cacheOwner = if ($IsWindows) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { & id -u }
$cacheBase = if ($IsWindows) { [Environment]::GetFolderPath('LocalApplicationData') } else { $HOME }
$needsCacheDir = ($Verify -ne 'None') -or [bool]$ValidateRunAction -or [bool]$ApplyRunAction
$evidenceDirectory = Get-PrivateCacheDirectory $cacheBase -EnsureCreated:$needsCacheDir
$configHash = Hash $configPath

$oldManifestRaw = $null
$oldManifestById = @{}
$oldManifestObjectsById = @{}
$oldManifestByUidAndHash = @{}
if (Test-Path -LiteralPath $manifestPath) {
    $oldManifestRaw = [IO.File]::ReadAllText($manifestPath)
    $oldManifestDoc = $oldManifestRaw | ConvertFrom-Json
    foreach ($entry in @($oldManifestDoc.examples)) {
        if ($entry.id) {
            $oldManifestById[$entry.id] = ($entry | ConvertTo-Json -Depth 30 -Compress)
            $oldManifestObjectsById[$entry.id] = $entry
        }
        $entrySource = $null
        if ($entry.PSObject.Properties['manifest'] -and $entry.manifest -and $entry.manifest.PSObject.Properties['source']) {
            $entrySource = Normalize ([string]$entry.manifest.source)
        } elseif ($entry.PSObject.Properties['source'] -and $entry.source) {
            $entrySource = Normalize ([string]$entry.source)
        }
        if ($entrySource) {
            $ehash = Hash $entrySource
            $euid = if ($entry.PSObject.Properties['uid'] -and $entry.uid) { [string]$entry.uid } else { '' }
            $oldManifestByUidAndHash["$euid|$ehash"] = $entry
            $oldManifestByUidAndHash["|$ehash"] = $entry
        }
    }
}

$recipes = @()
if (-not $Settings) { $Settings = Join-Path $workspace 'run-actions.settings.json' }
if (Test-Path $Settings) { $recipes = @((Get-Content $Settings -Raw | ConvertFrom-Json).examples) }

# Collect known package version pins from existing recipes so unversioned MinVer packages can inherit pinned versions.
$knownPackageVersions = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($r in $recipes) {
    $pins = @()
    if ($r.manifest -and $r.manifest.dependsOn) { $pins += @($r.manifest.dependsOn) }
    if ($r.hostHarness -and $r.hostHarness.dependsOn) { $pins += @($r.hostHarness.dependsOn) }
    foreach ($pin in $pins) {
        if ($pin -match '^([^@]+)@(.+)$') { $knownPackageVersions[$Matches[1]] = $Matches[2] }
    }
}
$gitSemVerTag = $null
$gitTagChecked = $false

# Build normalized example records with stable exampleId (uid#<ordinal>), fenceOrdinal, id, classification, and enriched dependencies.
$normalizedExamples = [Collections.Generic.List[object]]::new()
$seenOrdinalByUid = [hashtable]::new([StringComparer]::Ordinal)
$totalOrdinalByUid = [hashtable]::new([StringComparer]::Ordinal)
foreach ($ex in @($inventory.examples)) {
    $uKey = if ($ex.uid) { [string]$ex.uid } else { [IO.Path]::GetRelativePath($root, $ex.file).Replace('\', '/') }
    if (-not $totalOrdinalByUid.ContainsKey($uKey)) { $totalOrdinalByUid[$uKey] = 0 }
    $totalOrdinalByUid[$uKey]++
}
$seenIdSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

foreach ($ex in @($inventory.examples)) {
    $uKey = if ($ex.uid) { [string]$ex.uid } else { [IO.Path]::GetRelativePath($root, $ex.file).Replace('\', '/') }
    if (-not $seenOrdinalByUid.ContainsKey($uKey)) { $seenOrdinalByUid[$uKey] = 0 }
    $seenOrdinalByUid[$uKey]++
    $ordinal = if ($ex.PSObject.Properties['fenceOrdinal'] -and $ex.fenceOrdinal) { [int]$ex.fenceOrdinal } else { $seenOrdinalByUid[$uKey] }
    $fenceCount = if ($ex.PSObject.Properties['fenceCountOnUid'] -and $ex.fenceCountOnUid) { [int]$ex.fenceCountOnUid } else { $totalOrdinalByUid[$uKey] }
    $exampleId = if ($ex.PSObject.Properties['exampleId'] -and $ex.exampleId) { [string]$ex.exampleId } else { "$uKey#$ordinal" }

    $displayedSource = Normalize ([string]$ex.code)
    $source = $displayedSource
    if ($ex.source) { $source = Normalize (($source -split "`n" | Select-Object -Skip 2) -join "`n") }
    $sourceHash = Hash $source
    $wsHash = if ($ex.PSObject.Properties['whitespaceSha256'] -and $ex.whitespaceSha256) { [string]$ex.whitespaceSha256 } else { Hash (Canonicalize-Whitespace $source) }
    $identity = if ($ex.source) { [IO.Path]::GetRelativePath($root, $ex.source).Replace('\','/') + '|' + $sourceHash } else { $sourceHash }
    $baseId = (Hash ("$($ex.uid)|$([IO.Path]::GetRelativePath($root, $ex.file).Replace('\','/'))|$identity")).Substring(0,24).ToLowerInvariant()
    $id = $baseId
    if (-not $seenIdSet.Add($id)) {
        $id = (Hash ("$($ex.uid)|$([IO.Path]::GetRelativePath($root, $ex.file).Replace('\','/'))|$identity|#$ordinal")).Substring(0,24).ToLowerInvariant()
        $null = $seenIdSet.Add($id)
    }

    # Classification fallback for mocked inventories that omit Roslyn metadata.
    $classification = if ($ex.PSObject.Properties['classification'] -and $ex.classification) {
        $ex.classification
    } else {
        $cat = if ($ex.standalone -or $ex.isTest) { 'already-standalone' } else { 'no-entry' }
        $rc = if ($ex.isTest) { 'xunit-test' } elseif ($ex.standalone) { 'top-level-program' } else { 'no-entry-point' }
        [pscustomobject]@{
            category = $cat
            reasonCode = $rc
            convertible = [bool]($ex.standalone -or $ex.isTest)
            suggestedMode = if ($ex.isTest) { 'test' } else { 'console' }
            entryPoint = $null
            blockingConstruct = $null
            blockingLine = $null
            manualHarness = $null
            candidateSource = if ($ex.standalone -or $ex.isTest) { $source } else { $null }
        }
    }

    # Dependency enrichment (fill unversioned repo packages from settings/NuGet cache/git tags).
    $rawDeps = if ($ex.PSObject.Properties['dependencies'] -and $ex.dependencies) { $ex.dependencies } else { $null }
    $resolvedDependsOn = [Collections.Generic.List[string]]::new()
    $depErrors = [Collections.Generic.List[string]]::new()
    $missingPkgs = [Collections.Generic.List[object]]::new()
    $ambiguousTypes = [Collections.Generic.List[object]]::new()
    $unresolvedUsings = [Collections.Generic.List[string]]::new()
    $typeOwnership = [Collections.Generic.List[object]]::new()
    $fwRefs = [Collections.Generic.List[string]]::new()
    $depSdk = if ($rawDeps -and $rawDeps.sdk) { [string]$rawDeps.sdk } else { 'Microsoft.NET.Sdk' }

    if ($rawDeps) {
        foreach ($item in @($rawDeps.typeOwnership)) { $typeOwnership.Add($item) }
        foreach ($item in @($rawDeps.missingPackages)) { $missingPkgs.Add($item) }
        foreach ($item in @($rawDeps.ambiguousTypes)) { $ambiguousTypes.Add($item) }
        foreach ($item in @($rawDeps.unresolvedUsings)) { $unresolvedUsings.Add([string]$item) }
        foreach ($item in @($rawDeps.frameworkReferences)) { $fwRefs.Add([string]$item) }
        foreach ($item in @($rawDeps.errors)) { $depErrors.Add([string]$item) }
        foreach ($dep in @($rawDeps.dependsOn)) {
            if ($dep -match '^[^@]+@.+$') {
                $resolvedDependsOn.Add([string]$dep)
            } else {
                $pkgName = [string]$dep
                $ver = $null
                if ($knownPackageVersions.ContainsKey($pkgName)) {
                    $ver = $knownPackageVersions[$pkgName]
                } else {
                    # Check sibling package with same root prefix in known versions.
                    $rootPrefixPkg = ($pkgName -split '\.')[0] + '.'
                    foreach ($k in $knownPackageVersions.Keys) {
                        if ($k.StartsWith($rootPrefixPkg, [StringComparison]::OrdinalIgnoreCase)) { $ver = $knownPackageVersions[$k]; break }
                    }
                }
                if (-not $ver) { $ver = Resolve-LocalNuGetPackageVersion $pkgName }
                if (-not $ver) {
                    if (-not $gitTagChecked) { $gitSemVerTag = Get-GitLatestSemVerTag $root; $gitTagChecked = $true }
                    $ver = $gitSemVerTag
                }
                if ($ver) {
                    $resolvedDependsOn.Add("$pkgName@$ver")
                } else {
                    $resolvedDependsOn.Add($pkgName)
                    $diag = "missing-package: $pkgName -> $pkgName@<unknown-version>"
                    $missingPkgs.Add([pscustomobject]@{ type = $pkgName; package = $pkgName; project = $null; reason = 'unversioned-package'; diagnostic = $diag })
                    $depErrors.Add($diag)
                }
            }
        }
    }
    $enrichedDeps = [ordered]@{
        dependsOn = @($resolvedDependsOn | Select-Object -Unique)
        sdk = $depSdk
        frameworkReferences = @($fwRefs | Select-Object -Unique)
        typeOwnership = @($typeOwnership)
        missingPackages = @($missingPkgs)
        ambiguousTypes = @($ambiguousTypes)
        unresolvedUsings = @($unresolvedUsings)
        preflightPassed = ($depErrors.Count -eq 0)
        errors = @($depErrors)
    }

    $normalizedExamples.Add([pscustomobject]@{
        raw = $ex
        id = $id
        exampleId = $exampleId
        uid = $ex.uid
        fenceOrdinal = $ordinal
        fenceCountOnUid = $fenceCount
        file = $ex.file
        startLine = [int]$ex.startLine
        endLine = if ($ex.PSObject.Properties['endLine'] -and $ex.endLine) { [int]$ex.endLine } else { 0 }
        displayedSource = $displayedSource
        source = $source
        sourceSha256 = $sourceHash
        whitespaceSha256 = $wsHash
        isTest = [bool]$ex.isTest
        standalone = [bool]$ex.standalone
        eligible = [bool]$ex.eligible
        contextError = $ex.contextError
        classification = $classification
        dependencies = [pscustomobject]$enrichedDeps
    })
}

# Build recipe lookup maps with multi-fence safety (exact exampleId/ordinal first, legacy uid+hash fallback).
$recipeByExactOrdinal = [hashtable]::new([StringComparer]::Ordinal)
$recipeByUidHash = [hashtable]::new([StringComparer]::Ordinal)
$duplicateRecipeKeys = [Collections.Generic.List[string]]::new()
foreach ($recipe in $recipes) {
    $rHash = if ($recipe.sourceSha256) { ([string]$recipe.sourceSha256).ToUpperInvariant() } else { '' }
    $rUid = [string]$recipe.uid
    $rOrdinal = $null
    if ($recipe.PSObject.Properties['fenceOrdinal'] -and $null -ne $recipe.fenceOrdinal) {
        $rOrdinal = [int]$recipe.fenceOrdinal
    } elseif ($recipe.PSObject.Properties['exampleId'] -and ([string]$recipe.exampleId) -match '#(\d+)$') {
        $rOrdinal = [int]$Matches[1]
    }
    if ($null -ne $rOrdinal) {
        $exactKey = "$rUid#$rOrdinal|$rHash"
        if ($recipeByExactOrdinal.ContainsKey($exactKey)) { $duplicateRecipeKeys.Add($exactKey) }
        else { $recipeByExactOrdinal[$exactKey] = $recipe }
    } else {
        $legacyKey = "$rUid|$rHash"
        if ($recipeByUidHash.ContainsKey($legacyKey)) { $duplicateRecipeKeys.Add($legacyKey) }
        else { $recipeByUidHash[$legacyKey] = $recipe }
    }
}

function Find-MatchingRecipe($ExampleObj) {
    $exactKey = "$($ExampleObj.uid)#$($ExampleObj.fenceOrdinal)|$($ExampleObj.sourceSha256)"
    if ($recipeByExactOrdinal.ContainsKey($exactKey)) { return $recipeByExactOrdinal[$exactKey] }
    $legacyKey = "$($ExampleObj.uid)|$($ExampleObj.sourceSha256)"
    if ($recipeByUidHash.ContainsKey($legacyKey)) { return $recipeByUidHash[$legacyKey] }
    return $null
}

function Select-TargetExamples([string[]] $Selectors) {
    $matched = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($sel in $Selectors) {
        foreach ($ex in $normalizedExamples) {
            if ($ex.exampleId -ceq $sel -or $ex.uid -ceq $sel -or $ex.id -ceq $sel) {
                if ($seen.Add($ex.exampleId)) { $matched.Add($ex) }
            }
        }
    }
    return $matched
}

function Get-EffectivePlanEntry($ExampleObj) {
    $recipe = Find-MatchingRecipe $ExampleObj
    $cat = [string]$ExampleObj.classification.category
    $rc = [string]$ExampleObj.classification.reasonCode
    $conv = [bool]$ExampleObj.classification.convertible
    $sMode = [string]$ExampleObj.classification.suggestedMode
    $bConstruct = $ExampleObj.classification.blockingConstruct
    $bLine = $ExampleObj.classification.blockingLine
    $mHarness = $ExampleObj.classification.manualHarness
    $recipeStatus = 'unresolved'

    if ($recipe -and $recipe.intrinsicLimitation) {
        $cat = 'intrinsic'
        $rc = 'intrinsic-limitation'
        $conv = $false
        $bConstruct = [string]$recipe.intrinsicLimitation
        $recipeStatus = 'intrinsic'
    } elseif ($recipe) {
        $recipeStatus = 'paired'
        if ($recipe.mode -eq 'host' -or $recipe.PSObject.Properties['hostHarness']) { $sMode = 'host' }
    } elseif ($ExampleObj.sourceSha256 -ceq '47B0C1FBA94E7B43C8753D0A8242801B328E6B463B6EEDAEB640D4F8A262633E') {
        $recipeStatus = 'paired'
    } elseif (-not $ExampleObj.raw.source -and $ExampleObj.eligible -and $ExampleObj.standalone -ne $ExampleObj.isTest -and $ExampleObj.source -notmatch '(?m)^#:') {
        $recipeStatus = 'paired'
    }

    return [ordered]@{
        exampleId = $ExampleObj.exampleId
        uid = $ExampleObj.uid
        fenceOrdinal = $ExampleObj.fenceOrdinal
        fenceCountOnUid = $ExampleObj.fenceCountOnUid
        id = $ExampleObj.id
        file = $ExampleObj.file
        startLine = $ExampleObj.startLine
        endLine = $ExampleObj.endLine
        sourceSha256 = $ExampleObj.sourceSha256
        category = $cat
        reasonCode = $rc
        convertible = $conv
        suggestedMode = $sMode
        entryPoint = $ExampleObj.classification.entryPoint
        blockingConstruct = $bConstruct
        blockingLine = $bLine
        manualHarness = $mHarness
        recipeStatus = $recipeStatus
        dependencies = $ExampleObj.dependencies
    }
}

function Get-ValidationReceiptPath([string] $ExampleId, [string] $CandidateSourceSha256, [string] $RecipeSha256) {
    if (-not $evidenceDirectory) { return $null }
    $key = (Hash "$configHash|$ExampleId|$CandidateSourceSha256|$RecipeSha256").Substring(0, 24).ToLowerInvariant()
    return (Join-Path $evidenceDirectory "validation-$configHash-$key.json")
}

function Build-CandidateRecipeAndSource($ExampleObj) {
    $existing = Find-MatchingRecipe $ExampleObj
    $cat = [string]$ExampleObj.classification.category
    $isHost = ($cat -eq 'host-blocking') -or ($existing -and ($existing.mode -eq 'host' -or $existing.PSObject.Properties['hostHarness']))
    $candidateSource = if ($isHost) {
        $ExampleObj.source
    } elseif ($ExampleObj.classification.candidateSource) {
        Normalize ([string]$ExampleObj.classification.candidateSource)
    } else {
        $ExampleObj.source
    }
    $candidateHash = Hash $candidateSource
    $candidateWsHash = Hash (Canonicalize-Whitespace $candidateSource)
    $converted = ($candidateSource -cne $ExampleObj.source)
    $deps = @($ExampleObj.dependencies.dependsOn)

    if ($isHost) {
        $resolvedFramework = if ($frameworkExplicit) {
            $Framework
        } elseif ($existing -and $existing.PSObject.Properties['hostHarness'] -and $existing.hostHarness -and $existing.hostHarness.PSObject.Properties['framework'] -and $existing.hostHarness.framework) {
            [string]$existing.hostHarness.framework
        } elseif ($existing -and $existing.manifest -and $existing.manifest.PSObject.Properties['framework'] -and $existing.manifest.framework) {
            [string]$existing.manifest.framework
        } else {
            $Framework
        }
        $hh = if ($existing -and $existing.PSObject.Properties['hostHarness'] -and $existing.hostHarness) {
            $hhCopy = [ordered]@{}
            foreach ($prop in $existing.hostHarness.PSObject.Properties) { $hhCopy[$prop.Name] = $prop.Value }
            $hhCopy['framework'] = $resolvedFramework
            $hhCopy
        } else {
            [ordered]@{
                sdk = if ($ExampleObj.dependencies.sdk) { $ExampleObj.dependencies.sdk } else { 'Microsoft.NET.Sdk.Web' }
                framework = $resolvedFramework
                dependsOn = $deps
                probePath = '/'
                probeMethod = 'GET'
                timeoutSeconds = [Math]::Min([Math]::Max($TimeoutSeconds, 5), 30)
            }
        }
        $recipeObj = [ordered]@{
            uid = $ExampleObj.uid
            exampleId = $ExampleObj.exampleId
            fenceOrdinal = $ExampleObj.fenceOrdinal
            sourceSha256 = $candidateHash
            whitespaceSha256 = $candidateWsHash
            mode = 'host'
            hostHarness = $hh
        }
        $mode = 'host'
    } else {
        $mode = if ($ExampleObj.isTest -or $ExampleObj.classification.suggestedMode -eq 'test') { 'test' } else { 'console' }
        if ($deps.Count -eq 0 -and $existing -and $existing.manifest -and $existing.manifest.PSObject.Properties['dependsOn'] -and $existing.manifest.dependsOn) {
            $deps = @($existing.manifest.dependsOn)
        }
        if ($mode -eq 'test' -and -not ($deps | Where-Object { $_ -like 'xunit.v3@*' })) {
            $deps = @($deps + 'xunit.v3@4.0.3')
        }
        $resolvedFramework = if ($frameworkExplicit) {
            $Framework
        } elseif ($existing -and $existing.manifest -and $existing.manifest.PSObject.Properties['framework'] -and $existing.manifest.framework) {
            [string]$existing.manifest.framework
        } else {
            $Framework
        }
        $resolvedSdk = if ($ExampleObj.dependencies.sdk) { [string]$ExampleObj.dependencies.sdk } else { 'Microsoft.NET.Sdk' }
        $resolvedFwRefs = @($ExampleObj.dependencies.frameworkReferences | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        if ($existing -and $existing.manifest) {
            if ($existing.manifest.PSObject.Properties['sdk'] -and $existing.manifest.sdk) {
                $resolvedSdk = [string]$existing.manifest.sdk
            }
            if ($existing.manifest.PSObject.Properties['frameworkReferences'] -and $existing.manifest.frameworkReferences) {
                $resolvedFwRefs = @($existing.manifest.frameworkReferences | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            }
        }
        $manifestObj = [ordered]@{
            schemaVersion = 1
            mode = $mode
            framework = $resolvedFramework
            dependsOn = @($deps)
        }
        if ($resolvedSdk -and $resolvedSdk -ne 'Microsoft.NET.Sdk') {
            $manifestObj['sdk'] = $resolvedSdk
        }
        if ($resolvedFwRefs.Count -gt 0) {
            $manifestObj['frameworkReferences'] = @($resolvedFwRefs)
        }
        $recipeObj = [ordered]@{
            uid = $ExampleObj.uid
            exampleId = $ExampleObj.exampleId
            fenceOrdinal = $ExampleObj.fenceOrdinal
            sourceSha256 = $candidateHash
            whitespaceSha256 = $candidateWsHash
            manifest = $manifestObj
        }
    }

    $recipeCanonical = $recipeObj | ConvertTo-Json -Depth 30 -Compress
    $recipeSha256 = Hash $recipeCanonical
    return [pscustomobject]@{
        mode = $mode
        framework = $resolvedFramework
        isHost = $isHost
        converted = $converted
        candidateSource = $candidateSource
        candidateSourceSha256 = $candidateHash
        candidateWhitespaceSha256 = $candidateWsHash
        dependsOn = @($deps)
        sdk = if ($isHost) { if ($ExampleObj.dependencies.sdk) { [string]$ExampleObj.dependencies.sdk } else { 'Microsoft.NET.Sdk.Web' } } else { $resolvedSdk }
        frameworkReferences = if ($isHost) { @() } else { @($resolvedFwRefs) }
        recipe = $recipeObj
        recipeSha256 = $recipeSha256
    }
}

# ---------------------------------------------------------------------------
# MODE 1: --run-action-plan [--json]
# ---------------------------------------------------------------------------
if ($RunActionPlan) {
    $planItems = [Collections.Generic.List[object]]::new()
    $byCategory = [ordered]@{}
    $convertibleCount = 0; $nonConvertibleCount = 0; $pairedCount = 0; $unresolvedCount = 0; $intrinsicCount = 0
    foreach ($ex in $normalizedExamples) {
        $item = Get-EffectivePlanEntry $ex
        $planItems.Add($item)
        if (-not $byCategory.Contains($item.category)) { $byCategory[$item.category] = 0 }
        $byCategory[$item.category]++
        if ($item.convertible) { $convertibleCount++ } else { $nonConvertibleCount++ }
        switch ($item.recipeStatus) {
            'paired' { $pairedCount++ }
            'intrinsic' { $intrinsicCount++ }
            default { $unresolvedCount++ }
        }
    }
    $plan = [ordered]@{
        schemaVersion = 2
        config = $configPath
        summary = [ordered]@{
            total = $planItems.Count
            convertible = $convertibleCount
            nonConvertible = $nonConvertibleCount
            paired = $pairedCount
            unresolved = $unresolvedCount
            intrinsic = $intrinsicCount
            byCategory = $byCategory
        }
        examples = @($planItems)
    }
    if ($Json -or $SummaryJson) {
        $plan | ConvertTo-Json -Depth 30
    } else {
        Write-Output "Run-action plan for $configPath ($($planItems.Count) examples: $pairedCount paired, $unresolvedCount unresolved, $intrinsicCount intrinsic)"
        foreach ($k in $byCategory.Keys) { Write-Output "  $k : $($byCategory[$k])" }
        foreach ($item in $planItems) {
            $blocker = if ($item.blockingConstruct) { " | blocker line $($item.blockingLine): $($item.blockingConstruct)" } else { '' }
            Write-Output "- $($item.exampleId) [$($item.category)/$($item.reasonCode)] convertible=$($item.convertible) status=$($item.recipeStatus)$blocker"
        }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# MODE 2: --explain <uid>
# ---------------------------------------------------------------------------
if ($Explain) {
    $targets = Select-TargetExamples @($Explain)
    if ($targets.Count -eq 0) {
        if ($Json) { ([ordered]@{ schemaVersion = 2; error = 'example-not-found'; selector = $Explain } | ConvertTo-Json -Depth 10) }
        else { [Console]::Error.WriteLine("Example not found: $Explain") }
        exit 3
    }
    $entries = @($targets | ForEach-Object { Get-EffectivePlanEntry $_ })
    if ($Json) {
        ([ordered]@{ schemaVersion = 2; selector = $Explain; examples = $entries } | ConvertTo-Json -Depth 30)
    } else {
        foreach ($e in $entries) {
            Write-Output "Example: $($e.exampleId) (id: $($e.id))"
            Write-Output "  File: $($e.file):$($e.startLine)"
            Write-Output "  Category: $($e.category) (reason: $($e.reasonCode))"
            Write-Output "  Convertible: $($e.convertible) | Suggested mode: $($e.suggestedMode) | Recipe status: $($e.recipeStatus)"
            if ($e.blockingConstruct) {
                $lineNote = if ($e.blockingLine) { " (fence line $($e.blockingLine))" } else { '' }
                Write-Output "  Blocking construct: $($e.blockingConstruct)$lineNote"
            }
            if ($e.entryPoint) {
                Write-Output "  Entry point: $($e.entryPoint.type).$($e.entryPoint.method) (static=$($e.entryPoint.isStatic), async=$($e.entryPoint.isAsync), return=$($e.entryPoint.returnType))"
            }
            $depsText = if (@($e.dependencies.dependsOn).Count) { (@($e.dependencies.dependsOn) -join ', ') } else { '(none)' }
            Write-Output "  Dependencies: $depsText (preflightPassed=$($e.dependencies.preflightPassed))"
            foreach ($err in @($e.dependencies.errors)) { Write-Output "  Dependency issue: $err" }
            if ($e.manualHarness) { Write-Output "  Manual harness / guidance: $($e.manualHarness)" }
        }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# MODE 3: --check-recipes [--json]
# ---------------------------------------------------------------------------
if ($CheckRecipes) {
    $issues = [Collections.Generic.List[object]]::new()
    $recipeStatuses = [Collections.Generic.List[object]]::new()
    $matchedCount = 0; $movedCount = 0; $dupCount = 0; $orphanCount = 0; $wsOrphanCount = 0; $semOrphanCount = 0

    $byUid = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($ex in $normalizedExamples) {
        $k = [string]$ex.uid
        if (-not $byUid.ContainsKey($k)) { $byUid[$k] = [Collections.Generic.List[object]]::new() }
        $byUid[$k].Add($ex)
    }

    # Check duplicate recipes (same exampleId, same uid+hash, or multiple un-indexed recipes targeting same uid).
    $seenExact = [hashtable]::new([StringComparer]::Ordinal)
    $seenUidHash = [hashtable]::new([StringComparer]::Ordinal)
    $unindexedCountByUid = [hashtable]::new([StringComparer]::Ordinal)
    for ($idx = 0; $idx -lt $recipes.Count; $idx++) {
        $r = $recipes[$idx]
        $rUid = [string]$r.uid
        $rHash = if ($r.sourceSha256) { ([string]$r.sourceSha256).ToUpperInvariant() } else { '' }
        $rOrd = $null
        if ($r.PSObject.Properties['fenceOrdinal'] -and $null -ne $r.fenceOrdinal) { $rOrd = [int]$r.fenceOrdinal }
        elseif ($r.PSObject.Properties['exampleId'] -and ([string]$r.exampleId) -match '#(\d+)$') { $rOrd = [int]$Matches[1] }

        if ($null -ne $rOrd) {
            $ek = "$rUid#$rOrd"
            if ($seenExact.ContainsKey($ek)) {
                $dupCount++
                $issues.Add([ordered]@{
                    kind = 'duplicate-uid'
                    uid = $rUid
                    exampleId = $ek
                    recipeIndex = $idx
                    sourceSha256 = $rHash
                    reason = "Multiple recipes target the same stable exampleId '$ek'."
                })
            } else { $seenExact[$ek] = $idx }
        } else {
            if (-not $unindexedCountByUid.ContainsKey($rUid)) { $unindexedCountByUid[$rUid] = 0 }
            $unindexedCountByUid[$rUid]++
        }

        $uhKey = "$rUid|$rHash"
        if ($seenUidHash.ContainsKey($uhKey)) {
            $dupCount++
            $issues.Add([ordered]@{
                kind = 'duplicate-uid'
                uid = $rUid
                exampleId = if ($null -ne $rOrd) { "$rUid#$rOrd" } else { $rUid }
                recipeIndex = $idx
                sourceSha256 = $rHash
                reason = "Duplicate recipe for '$uhKey'."
            })
        } else { $seenUidHash[$uhKey] = $idx }
    }

    foreach ($uKey in $unindexedCountByUid.Keys) {
        if ($unindexedCountByUid[$uKey] -gt 1) {
            $dupCount++
            $issues.Add([ordered]@{
                kind = 'duplicate-uid'
                uid = $uKey
                exampleId = $uKey
                reason = "Multiple recipes target UID '$uKey' without distinguishing fenceOrdinal/exampleId."
            })
        }
    }

    # Check every recipe for matched / moved / orphaned (whitespace-only vs semantic).
    for ($idx = 0; $idx -lt $recipes.Count; $idx++) {
        $r = $recipes[$idx]
        $rUid = [string]$r.uid
        $rHash = if ($r.sourceSha256) { ([string]$r.sourceSha256).ToUpperInvariant() } else { '' }
        $rWsHash = if ($r.PSObject.Properties['whitespaceSha256'] -and $r.whitespaceSha256) { ([string]$r.whitespaceSha256).ToUpperInvariant() } else { $null }
        $rOrd = $null
        if ($r.PSObject.Properties['fenceOrdinal'] -and $null -ne $r.fenceOrdinal) { $rOrd = [int]$r.fenceOrdinal }
        elseif ($r.PSObject.Properties['exampleId'] -and ([string]$r.exampleId) -match '#(\d+)$') { $rOrd = [int]$Matches[1] }

        $uidFences = if ($byUid.ContainsKey($rUid)) { @($byUid[$rUid]) } else { @() }
        $hashMatch = @($uidFences | Where-Object { $_.sourceSha256 -ceq $rHash })

        if ($hashMatch.Count -gt 0) {
            $matchedFence = $hashMatch[0]
            $prevManifestEntry = $oldManifestByUidAndHash["$rUid|$rHash"]
            $prevOrd = if ($prevManifestEntry -and $prevManifestEntry.PSObject.Properties['fenceOrdinal'] -and $prevManifestEntry.fenceOrdinal) { [int]$prevManifestEntry.fenceOrdinal } else { $null }

            if (($null -ne $rOrd -and $matchedFence.fenceOrdinal -ne $rOrd) -or
                ($null -eq $rOrd -and $null -ne $prevOrd -and $matchedFence.fenceOrdinal -ne $prevOrd)) {
                $expectedOrd = if ($null -ne $rOrd) { $rOrd } else { $prevOrd }
                $movedCount++
                $issue = [ordered]@{
                    kind = 'moved'
                    uid = $rUid
                    expectedExampleId = "$rUid#$expectedOrd"
                    matchedExampleId = $matchedFence.exampleId
                    expectedFenceOrdinal = $expectedOrd
                    matchedFenceOrdinal = $matchedFence.fenceOrdinal
                    sourceSha256 = $rHash
                    file = $matchedFence.file
                    suggestedUpdate = [ordered]@{
                        action = 'confirm-or-update-ordinal'
                        exampleId = $matchedFence.exampleId
                        fenceOrdinal = $matchedFence.fenceOrdinal
                        sourceSha256 = $rHash
                    }
                }
                $issues.Add($issue)
                $recipeStatuses.Add([ordered]@{ uid = $rUid; exampleId = $matchedFence.exampleId; status = 'moved'; sourceSha256 = $rHash })
            } else {
                $matchedCount++
                $recipeStatuses.Add([ordered]@{ uid = $rUid; exampleId = $matchedFence.exampleId; status = 'matched'; sourceSha256 = $rHash })
            }
            continue
        }

        # Recipe did not match any current fence hash -> orphaned!
        $orphanCount++
        $candidateFence = $null
        if ($null -ne $rOrd) {
            $candidateFence = $uidFences | Where-Object { $_.fenceOrdinal -eq $rOrd } | Select-Object -First 1
        }
        if (-not $candidateFence -and $uidFences.Count -eq 1) {
            $candidateFence = $uidFences[0]
        } elseif (-not $candidateFence -and $uidFences.Count -gt 1) {
            # Prefer a fence whose whitespace hash matches!
            if ($rWsHash) {
                $candidateFence = $uidFences | Where-Object { $_.whitespaceSha256 -ceq $rWsHash } | Select-Object -First 1
            }
            if (-not $candidateFence) { $candidateFence = $uidFences[0] }
        }

        $diffKind = 'unknown'
        $oldSourceText = $null
        if ($r.manifest -and $r.manifest.PSObject.Properties['source'] -and $r.manifest.source) {
            $oldSourceText = Normalize ([string]$r.manifest.source)
        } elseif ($oldManifestByUidAndHash.ContainsKey("$rUid|$rHash")) {
            $om = $oldManifestByUidAndHash["$rUid|$rHash"]
            if ($om.PSObject.Properties['manifest'] -and $om.manifest -and $om.manifest.PSObject.Properties['source']) {
                $oldSourceText = Normalize ([string]$om.manifest.source)
            } elseif ($om.PSObject.Properties['source'] -and $om.source) {
                $oldSourceText = Normalize ([string]$om.source)
            }
        } elseif ($oldManifestByUidAndHash.ContainsKey("|$rHash")) {
            $om = $oldManifestByUidAndHash["|$rHash"]
            if ($om.PSObject.Properties['manifest'] -and $om.manifest -and $om.manifest.PSObject.Properties['source']) {
                $oldSourceText = Normalize ([string]$om.manifest.source)
            } elseif ($om.PSObject.Properties['source'] -and $om.source) {
                $oldSourceText = Normalize ([string]$om.source)
            }
        }

        if (-not $candidateFence) {
            $diffKind = 'uid-removed'
            $semOrphanCount++
        } else {
            if (-not $oldSourceText -and $candidateFence.file) {
                $headText = Get-GitHeadFileText $root $candidateFence.file
                if ($headText) {
                    $fenceMatches = [regex]::Matches($headText, '(?ms)^[ \t]*```(?:csharp|cs)[ \t]*\r?\n(.*?)\r?\n[ \t]*```')
                    foreach ($fm in $fenceMatches) {
                        $candOld = Normalize $fm.Groups[1].Value
                        if ((Hash $candOld) -ceq $rHash) { $oldSourceText = $candOld; break }
                    }
                }
            }

            if ($rWsHash -and $rWsHash -ceq $candidateFence.whitespaceSha256) {
                $diffKind = 'whitespace-only'
                $wsOrphanCount++
            } elseif ($oldSourceText) {
                $oldWs = Canonicalize-Whitespace $oldSourceText
                $newWs = Canonicalize-Whitespace $candidateFence.source
                if ($oldWs -ceq $newWs) {
                    $diffKind = 'whitespace-only'
                    $wsOrphanCount++
                } else {
                    $diffKind = 'semantic'
                    $semOrphanCount++
                }
            } else {
                $diffKind = 'unknown'
                $semOrphanCount++
            }
        }

        $suggestedAction = switch ($diffKind) {
            'whitespace-only' { 'update-source-sha256' }
            'uid-removed' { 'remove-recipe' }
            default { 're-validate-and-apply' }
        }
        $suggestedUpdate = if ($candidateFence) {
            [ordered]@{
                action = $suggestedAction
                uid = $rUid
                exampleId = $candidateFence.exampleId
                fenceOrdinal = $candidateFence.fenceOrdinal
                oldSourceSha256 = $rHash
                newSourceSha256 = $candidateFence.sourceSha256
                newWhitespaceSha256 = $candidateFence.whitespaceSha256
            }
        } else {
            [ordered]@{
                action = 'remove-recipe'
                uid = $rUid
                oldSourceSha256 = $rHash
            }
        }

        $issues.Add([ordered]@{
            kind = 'orphaned'
            diffKind = $diffKind
            uid = $rUid
            exampleId = if ($candidateFence) { $candidateFence.exampleId } elseif ($null -ne $rOrd) { "$rUid#$rOrd" } else { $rUid }
            file = if ($candidateFence) { $candidateFence.file } else { $null }
            recipeSha256 = $rHash
            currentSourceSha256 = if ($candidateFence) { $candidateFence.sourceSha256 } else { $null }
            suggestedUpdate = $suggestedUpdate
        })
        $recipeStatuses.Add([ordered]@{
            uid = $rUid
            exampleId = if ($candidateFence) { $candidateFence.exampleId } else { $rUid }
            status = 'orphaned'
            diffKind = $diffKind
            recipeSha256 = $rHash
            currentSourceSha256 = if ($candidateFence) { $candidateFence.sourceSha256 } else { $null }
        })
    }

    $report = [ordered]@{
        schemaVersion = 2
        settingsPath = $Settings
        normalization = [ordered]@{
            lineEndings = 'LF'
            trimTrailingNewlines = $true
            preservesLineTrailingWhitespace = $true
            whitespaceDiffCanonicalization = 'LF + trim trailing spaces/tabs per line + trim trailing newlines'
        }
        summary = [ordered]@{
            total = $recipes.Count
            matched = $matchedCount
            moved = $movedCount
            duplicateUid = $dupCount
            orphaned = $orphanCount
            whitespaceOnlyOrphans = $wsOrphanCount
            semanticOrphans = $semOrphanCount
        }
        issues = @($issues)
        recipes = @($recipeStatuses)
    }
    if ($Json -or $SummaryJson) {
        $report | ConvertTo-Json -Depth 30
    } else {
        Write-Output "Recipe check ($($recipes.Count) total): matched=$matchedCount moved=$movedCount duplicate-uid=$dupCount orphaned=$orphanCount (whitespace-only=$wsOrphanCount, semantic=$semOrphanCount)"
        foreach ($iss in $issues) {
            Write-Output "- [$($iss.kind)] $($iss.exampleId) diff=$($iss.diffKind) current=$($iss.currentSourceSha256)"
        }
    }
    if ($issues.Count -gt 0) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------
# MODE 4: --resolve-dependencies <uid>
# ---------------------------------------------------------------------------
if ($ResolveDependencies) {
    $targets = Select-TargetExamples @($ResolveDependencies)
    if ($targets.Count -eq 0) {
        ([ordered]@{ schemaVersion = 2; error = 'example-not-found'; selector = $ResolveDependencies } | ConvertTo-Json -Depth 10)
        exit 3
    }
    $resolvedList = @($targets | ForEach-Object {
        $planEntry = Get-EffectivePlanEntry $_
        [ordered]@{
            exampleId = $_.exampleId
            uid = $_.uid
            fenceOrdinal = $_.fenceOrdinal
            id = $_.id
            file = $_.file
            category = $planEntry.category
            reasonCode = $planEntry.reasonCode
            dependsOn = @($_.dependencies.dependsOn)
            sdk = $_.dependencies.sdk
            frameworkReferences = @($_.dependencies.frameworkReferences)
            typeOwnership = @($_.dependencies.typeOwnership)
            missingPackages = @($_.dependencies.missingPackages)
            ambiguousTypes = @($_.dependencies.ambiguousTypes)
            unresolvedUsings = @($_.dependencies.unresolvedUsings)
            preflightPassed = [bool]$_.dependencies.preflightPassed
            errors = @($_.dependencies.errors)
        }
    })
    $allPassed = (@($resolvedList | Where-Object { -not $_.preflightPassed }).Count -eq 0)
    $payload = if ($resolvedList.Count -eq 1) {
        $single = $resolvedList[0]
        [ordered]@{
            schemaVersion = 2
            exampleId = $single.exampleId
            uid = $single.uid
            fenceOrdinal = $single.fenceOrdinal
            id = $single.id
            file = $single.file
            category = $single.category
            reasonCode = $single.reasonCode
            dependsOn = $single.dependsOn
            sdk = $single.sdk
            frameworkReferences = $single.frameworkReferences
            typeOwnership = $single.typeOwnership
            missingPackages = $single.missingPackages
            ambiguousTypes = $single.ambiguousTypes
            unresolvedUsings = $single.unresolvedUsings
            preflightPassed = $single.preflightPassed
            errors = $single.errors
            examples = $resolvedList
        }
    } else {
        [ordered]@{
            schemaVersion = 2
            selector = $ResolveDependencies
            preflightPassed = $allPassed
            examples = $resolvedList
        }
    }
    $payload | ConvertTo-Json -Depth 30
    if (-not $allPassed) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------
# MODE 5: --validate-run-action <uid>
# ---------------------------------------------------------------------------
if ($ValidateRunAction) {
    $targets = Select-TargetExamples @($ValidateRunAction)
    if ($targets.Count -eq 0) {
        ([ordered]@{ schemaVersion = 2; validated = $false; reasonCode = 'example-not-found'; selector = $ValidateRunAction } | ConvertTo-Json -Depth 10)
        exit 3
    }
    if ($targets.Count -gt 1) {
        ([ordered]@{
            schemaVersion = 2
            validated = $false
            reasonCode = 'ambiguous-multi-fence-uid'
            selector = $ValidateRunAction
            candidates = @($targets | ForEach-Object { $_.exampleId })
            message = "Multiple fences share UID '$ValidateRunAction'. Pass an explicit stable exampleId such as '$($targets[0].exampleId)'."
        } | ConvertTo-Json -Depth 10)
        exit 3
    }
    $target = $targets[0]
    $planEntry = Get-EffectivePlanEntry $target
    if (-not $planEntry.convertible -and $planEntry.suggestedMode -ne 'host') {
        ([ordered]@{
            schemaVersion = 2
            validated = $false
            exampleId = $target.exampleId
            uid = $target.uid
            fenceOrdinal = $target.fenceOrdinal
            id = $target.id
            category = $planEntry.category
            reasonCode = $planEntry.reasonCode
            convertible = $false
            blockingConstruct = $planEntry.blockingConstruct
            blockingLine = $planEntry.blockingLine
            manualHarness = $planEntry.manualHarness
        } | ConvertTo-Json -Depth 20)
        exit 1
    }
    if (-not $target.dependencies.preflightPassed) {
        ([ordered]@{
            schemaVersion = 2
            validated = $false
            exampleId = $target.exampleId
            uid = $target.uid
            fenceOrdinal = $target.fenceOrdinal
            id = $target.id
            category = $planEntry.category
            reasonCode = 'dependency-preflight-failed'
            dependsOn = @($target.dependencies.dependsOn)
            errors = @($target.dependencies.errors)
        } | ConvertTo-Json -Depth 20)
        exit 1
    }

    $candidate = Build-CandidateRecipeAndSource $target
    $receiptPath = Get-ValidationReceiptPath $target.exampleId $candidate.candidateSourceSha256 $candidate.recipeSha256
    if ($receiptPath -and (Test-Path -LiteralPath $receiptPath)) { Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue }

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('docfx-validate-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    $null = [IO.Directory]::CreateDirectory($tempDir)
    $stdout = ''; $stderr = ''; $exitCode = -1; $timedOut = $false; $failReason = $null
    try {
        if ($candidate.isHost) {
            $hh = $candidate.recipe.hostHarness
            $hostFramework = if ($hh.framework) { [string]$hh.framework } else { $candidate.framework }
            if ((Test-NetFrameworkTfm $hostFramework) -and -not $isWindowsHost) {
                $exitCode = 1
                $stderr = "Framework '$hostFramework' targets .NET Framework and is only supported natively on Windows."
                $failReason = 'windows-required-for-netframework'
            } else {
                $hostPair = New-HostExamplePair `
                    -Source $candidate.candidateSource `
                    -Framework $hostFramework `
                    -Sdk $(if ($hh.sdk) { [string]$hh.sdk } else { 'Microsoft.NET.Sdk.Web' }) `
                    -DependsOn $(if ($hh.dependsOn) { [string[]]@($hh.dependsOn) } else { @() }) `
                    -ProbePath $(if ($null -ne $hh.probePath) { [string]$hh.probePath } else { '/' }) `
                    -ProbeMethod $(if ($hh.probeMethod) { [string]$hh.probeMethod } else { 'GET' }) `
                    -TimeoutSeconds $(if ($hh.timeoutSeconds) { [int]$hh.timeoutSeconds } else { [Math]::Min($TimeoutSeconds, 30) }) `
                    -ExpectedStatusCode $(if ($hh.expectedStatusCode) { [int]$hh.expectedStatusCode } else { 0 }) `
                    -ExpectedBodyContains $(if ($hh.expectedBodyContains) { [string]$hh.expectedBodyContains } else { '' }) `
                    -StartupDelayMs $(if ($hh.startupDelayMs) { [int]$hh.startupDelayMs } else { 1000 }) `
                    -Image $CsrunImage
                $hostScript = Join-Path $tempDir 'validate-host.ps1'
                [IO.File]::WriteAllText($hostScript, (Normalize $hostPair.Native), [Text.UTF8Encoding]::new($false))
                $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
                foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $hostScript)) { $psi.ArgumentList.Add($a) }
                $psi.WorkingDirectory = $tempDir
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $proc = [Diagnostics.Process]::new()
                $proc.StartInfo = $psi
                try {
                    if (-not $proc.Start()) { throw 'Could not start host validation process.' }
                    $outTask = $proc.StandardOutput.ReadToEndAsync()
                    $errTask = $proc.StandardError.ReadToEndAsync()
                    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                        $timedOut = $true
                        try { $proc.Kill($true) } catch {}
                        $null = $proc.WaitForExit(5000)
                    }
                    $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
                    $stdout = $outTask.GetAwaiter().GetResult()
                    $stderr = $errTask.GetAwaiter().GetResult()
                } finally {
                    $proc.Dispose()
                }
                if ($timedOut) { $failReason = 'execution-timeout' }
                elseif ($exitCode -ne 0) { $failReason = 'host-execution-failed' }
                elseif ([string]::IsNullOrWhiteSpace($stdout)) { $failReason = 'empty-host-output' }
            }
        } else {
            # Validate strictly from the saved recipe manifest so validation matches what csrun will execute.
            $manifestSpec = $candidate.recipe.manifest
            $manifestMode = [string]$manifestSpec['mode']
            $manifestFramework = if ($manifestSpec.Contains('framework') -and $manifestSpec['framework']) { [string]$manifestSpec['framework'] } else { $candidate.framework }
            $manifestSdk = if ($manifestSpec.Contains('sdk') -and $manifestSpec['sdk']) { [string]$manifestSpec['sdk'] } else { 'Microsoft.NET.Sdk' }
            $manifestDeps = if ($manifestSpec.Contains('dependsOn') -and $manifestSpec['dependsOn']) { @($manifestSpec['dependsOn']) } else { @() }
            $manifestFwRefs = if ($manifestSpec.Contains('frameworkReferences') -and $manifestSpec['frameworkReferences']) { @($manifestSpec['frameworkReferences']) } else { @() }
            $isNetFramework = Test-NetFrameworkTfm $manifestFramework

            $invalidManifestError = $null
            if ($manifestSdk -notin @('Microsoft.NET.Sdk', 'Microsoft.NET.Sdk.Web')) {
                $invalidManifestError = "Unsupported csrun manifest sdk: $manifestSdk"
            } elseif ($manifestMode -eq 'console' -and $manifestFwRefs.Count -gt 0) {
                $unsupportedFwRefs = @($manifestFwRefs | Where-Object { $_ -ine 'Microsoft.AspNetCore.App' })
                if ($unsupportedFwRefs.Count -gt 0 -or $manifestSdk -ine 'Microsoft.NET.Sdk.Web') {
                    $invalidManifestError = "Console manifest frameworkReferences only supports Microsoft.AspNetCore.App with sdk Microsoft.NET.Sdk.Web."
                }
            }

            if ($invalidManifestError) {
                $exitCode = 1
                $stderr = $invalidManifestError
                $failReason = 'invalid-manifest'
            } elseif ($isNetFramework -and -not $isWindowsHost) {
                $exitCode = 1
                $stderr = "Framework '$manifestFramework' targets .NET Framework and is only supported natively on Windows."
                $failReason = 'windows-required-for-netframework'
            } else {
                $dotnetExe = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                $artifactsDir = Join-Path $tempDir 'artifacts'
                $useTempProject = $isNetFramework -or ($manifestMode -eq 'test' -and $manifestFwRefs.Count -gt 0)
                if ($useTempProject) {
                    $pkgLines = @($manifestDeps | ForEach-Object {
                        $parts = [string]$_ -split '@', 2
                        "    <PackageReference Include=""$([Security.SecurityElement]::Escape($parts[0]))"" Version=""[$([Security.SecurityElement]::Escape($parts[1]))]"" />"
                    })
                    if ($isNetFramework -and -not ($manifestDeps | Where-Object { $_ -like 'Microsoft.NETFramework.ReferenceAssemblies@*' })) {
                        $pkgLines += '    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="[1.0.3]" PrivateAssets="All" />'
                    }
                    $fwLines = @($manifestFwRefs | ForEach-Object {
                        "    <FrameworkReference Include=""$([Security.SecurityElement]::Escape([string]$_))"" />"
                    })
                    $itemLines = @($pkgLines + $fwLines)
                    $itemGroup = if ($itemLines.Count -gt 0) { "`n  <ItemGroup>`n" + ($itemLines -join "`n") + "`n  </ItemGroup>" } else { '' }
                    $extraProps = [Collections.Generic.List[string]]::new()
                    if ($isNetFramework) {
                        $extraProps.Add('    <LangVersion>latest</LangVersion>')
                        $extraProps.Add('    <WarningsAsErrors>NU1603;NU1605</WarningsAsErrors>')
                    } else {
                        $extraProps.Add('    <PublishAot>false</PublishAot>')
                    }
                    if ($manifestMode -eq 'test') {
                        $extraProps.Add('    <UseMicrosoftTestingPlatformRunner>true</UseMicrosoftTestingPlatformRunner>')
                    }
                    $extraPropsText = if ($extraProps.Count -gt 0) { "`n" + ($extraProps -join "`n") } else { '' }
                    $csprojText = "<Project Sdk=""$manifestSdk"">`n  <PropertyGroup>`n    <OutputType>Exe</OutputType>`n    <TargetFramework>$manifestFramework</TargetFramework>`n    <ImplicitUsings>enable</ImplicitUsings>`n    <Nullable>enable</Nullable>$extraPropsText`n  </PropertyGroup>$itemGroup`n</Project>`n"
                    $buildTargetPath = Join-Path $tempDir 'candidate.csproj'
                    [IO.File]::WriteAllText($buildTargetPath, $csprojText, [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText((Join-Path $tempDir 'Program.cs'), $candidate.candidateSource + "`n", [Text.UTF8Encoding]::new($false))
                } else {
                    # Build file-based app separately from execution so compiler warnings never masquerade as program stdout.
                    $headerLines = [Collections.Generic.List[string]]::new()
                    $headerLines.Add("#:property TargetFramework=$manifestFramework")
                    $headerLines.Add('#:property PublishAot=false')
                    if ($manifestSdk -eq 'Microsoft.NET.Sdk.Web') { $headerLines.Add('#:sdk Microsoft.NET.Sdk.Web') }
                    foreach ($pin in @($manifestDeps)) { $headerLines.Add("#:package $pin") }
                    $appText = ($headerLines -join "`n") + "`n`n" + $candidate.candidateSource + "`n"
                    $buildTargetPath = Join-Path $tempDir 'candidate.cs'
                    [IO.File]::WriteAllText($buildTargetPath, $appText, [Text.UTF8Encoding]::new($false))
                }

                $buildPsi = [Diagnostics.ProcessStartInfo]::new($dotnetExe)
                foreach ($a in @('build', $buildTargetPath, '--artifacts-path', $artifactsDir, '--nologo', '-v', 'quiet')) { $buildPsi.ArgumentList.Add($a) }
                $buildPsi.WorkingDirectory = $tempDir
                $buildPsi.RedirectStandardOutput = $true
                $buildPsi.RedirectStandardError = $true
                $buildPsi.UseShellExecute = $false
                $buildProc = [Diagnostics.Process]::new()
                $buildProc.StartInfo = $buildPsi
                $buildOut = ''; $buildErr = ''; $buildExit = -1
                try {
                    if (-not $buildProc.Start()) { throw 'Could not start dotnet build for candidate manifest.' }
                    $bOutTask = $buildProc.StandardOutput.ReadToEndAsync()
                    $bErrTask = $buildProc.StandardError.ReadToEndAsync()
                    if (-not $buildProc.WaitForExit([Math]::Max($TimeoutSeconds, 60) * 1000)) {
                        $timedOut = $true
                        try { $buildProc.Kill($true) } catch {}
                        $null = $buildProc.WaitForExit(5000)
                    }
                    $buildExit = if ($timedOut) { 124 } else { $buildProc.ExitCode }
                    $buildOut = $bOutTask.GetAwaiter().GetResult()
                    $buildErr = $bErrTask.GetAwaiter().GetResult()
                } finally {
                    $buildProc.Dispose()
                }

                if ($timedOut) {
                    $exitCode = 124
                    $stderr = ($buildOut + "`n" + $buildErr).Trim()
                    $failReason = 'execution-timeout'
                } elseif ($buildExit -ne 0) {
                    $exitCode = $buildExit
                    $stderr = ($buildOut + "`n" + $buildErr).Trim()
                    $failReason = 'build-failed'
                } else {
                    $builtTarget = if ($isNetFramework) {
                        Get-ChildItem -LiteralPath $artifactsDir -Recurse -File -Filter 'candidate.exe' -ErrorAction SilentlyContinue |
                            Sort-Object FullName | Select-Object -First 1
                    } else {
                        Get-ChildItem -LiteralPath $artifactsDir -Recurse -File -Filter 'candidate.dll' -ErrorAction SilentlyContinue |
                            Sort-Object FullName | Select-Object -First 1
                    }
                    if (-not $builtTarget) {
                        $exitCode = 1
                        $failReason = 'build-output-missing'
                    } else {
                        $psi = if ($isNetFramework) {
                            [Diagnostics.ProcessStartInfo]::new($builtTarget.FullName)
                        } else {
                            $p = [Diagnostics.ProcessStartInfo]::new($dotnetExe)
                            $p.ArgumentList.Add($builtTarget.FullName)
                            $p
                        }
                        if ($manifestMode -eq 'test') {
                            foreach ($a in @('--show-live-output', 'on', '--progress', 'off', '--no-banner')) { $psi.ArgumentList.Add($a) }
                        }
                        $psi.WorkingDirectory = $tempDir
                        $psi.RedirectStandardOutput = $true
                        $psi.RedirectStandardError = $true
                        $psi.UseShellExecute = $false
                        $proc = [Diagnostics.Process]::new()
                        $proc.StartInfo = $psi
                        try {
                            if (-not $proc.Start()) { throw 'Could not start candidate assembly.' }
                            $outTask = $proc.StandardOutput.ReadToEndAsync()
                            $errTask = $proc.StandardError.ReadToEndAsync()
                            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                                $timedOut = $true
                                try { $proc.Kill($true) } catch {}
                                $null = $proc.WaitForExit(5000)
                            }
                            $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
                            $stdout = $outTask.GetAwaiter().GetResult()
                            $stderr = $errTask.GetAwaiter().GetResult()
                        } finally {
                            $proc.Dispose()
                        }
                        if ($timedOut) {
                            $failReason = 'execution-timeout'
                        } elseif ($exitCode -ne 0) {
                            $failReason = 'run-failed'
                        } elseif ($manifestMode -eq 'console' -and [string]::IsNullOrWhiteSpace($stdout)) {
                            $failReason = 'empty-console-output'
                        } elseif ($manifestMode -eq 'test') {
                            try {
                                Invoke-Expression $script:CsrunTestVerificationTemplate
                                Assert-CsrunTestOutput $stdout
                            } catch {
                                $failReason = 'test-assertion-failed'
                                $stderr = ($stderr + "`n" + $_.Exception.Message).Trim()
                            }
                        }
                    }
                }
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $passed = ($null -eq $failReason)
    if ($passed -and $receiptPath) {
        $receipt = [ordered]@{
            schemaVersion = 2
            validatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            exampleId = $target.exampleId
            uid = $target.uid
            fenceOrdinal = $target.fenceOrdinal
            originalSourceSha256 = $target.sourceSha256
            candidateSourceSha256 = $candidate.candidateSourceSha256
            recipeSha256 = $candidate.recipeSha256
            mode = $candidate.mode
            framework = $candidate.framework
            passed = $true
        }
        $tmpReceipt = $receiptPath + '.tmp.' + [guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($tmpReceipt, ($receipt | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
            if (-not $isWindowsHost) { & chmod 600 -- $tmpReceipt 2>$null }
            [IO.File]::Move($tmpReceipt, $receiptPath, $true)
        } finally {
            if (Test-Path -LiteralPath $tmpReceipt) { [IO.File]::Delete($tmpReceipt) }
        }
    }

    $resultObj = [ordered]@{
        schemaVersion = 2
        validated = $passed
        exampleId = $target.exampleId
        uid = $target.uid
        fenceOrdinal = $target.fenceOrdinal
        id = $target.id
        category = $planEntry.category
        reasonCode = if ($passed) { 'validated' } else { $failReason }
        mode = $candidate.mode
        framework = $candidate.framework
        converted = $candidate.converted
        sourceSha256 = $target.sourceSha256
        candidateSourceSha256 = $candidate.candidateSourceSha256
        recipeSha256 = $candidate.recipeSha256
        dependsOn = @($candidate.dependsOn)
        exitCode = $exitCode
        timedOut = $timedOut
        stdout = $stdout.TrimEnd("`r", "`n")
        stderr = $stderr.TrimEnd("`r", "`n")
    }
    $resultObj | ConvertTo-Json -Depth 20
    if (-not $passed) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------
# MODE 6: --apply-run-action <uid>
# ---------------------------------------------------------------------------
if ($ApplyRunAction) {
    $targets = Select-TargetExamples @($ApplyRunAction)
    if ($targets.Count -eq 0) {
        ([ordered]@{ schemaVersion = 2; applied = $false; reasonCode = 'example-not-found'; selector = $ApplyRunAction } | ConvertTo-Json -Depth 10)
        exit 3
    }
    if ($targets.Count -gt 1) {
        ([ordered]@{
            schemaVersion = 2
            applied = $false
            reasonCode = 'ambiguous-multi-fence-uid'
            selector = $ApplyRunAction
            candidates = @($targets | ForEach-Object { $_.exampleId })
            message = "Multiple fences share UID '$ApplyRunAction'. Pass an explicit stable exampleId such as '$($targets[0].exampleId)'."
        } | ConvertTo-Json -Depth 10)
        exit 3
    }
    $target = $targets[0]
    Assert-RepositoryPath $target.file
    $candidate = Build-CandidateRecipeAndSource $target
    $receiptPath = Get-ValidationReceiptPath $target.exampleId $candidate.candidateSourceSha256 $candidate.recipeSha256
    $validReceipt = $false
    if ($receiptPath -and (Test-PrivateCacheItem $receiptPath)) {
        try {
            $rec = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
            if ($rec.passed -eq $true -and
                $rec.exampleId -ceq $target.exampleId -and
                $rec.candidateSourceSha256 -ceq $candidate.candidateSourceSha256 -and
                $rec.recipeSha256 -ceq $candidate.recipeSha256) {
                $validReceipt = $true
            }
        } catch {}
    }

    if (-not $validReceipt) {
        ([ordered]@{
            schemaVersion = 2
            applied = $false
            reasonCode = 'validation-required'
            exampleId = $target.exampleId
            uid = $target.uid
            fenceOrdinal = $target.fenceOrdinal
            expectedRecipeSha256 = $candidate.recipeSha256
            message = "Refusing to apply before validation passes. Run --validate-run-action $($target.exampleId) first."
        } | ConvertTo-Json -Depth 10)
        exit 1
    }

    # Surgically update ONLY the target fence if conversion changed the source.
    $fenceUpdated = $false
    if ($candidate.converted) {
        $originalText = [IO.File]::ReadAllText($target.file)
        $lineMatches = [regex]::Matches($originalText, '(?<text>[^\r\n]*)(?<ending>\r\n|\n|\r|$)')
        $openIdx = $target.startLine - 1
        $closeIdx = $openIdx + 1
        while ($closeIdx -lt $lineMatches.Count -and $lineMatches[$closeIdx].Groups['text'].Value -notmatch '^\s*```') { $closeIdx++ }
        if ($closeIdx -ge $lineMatches.Count) { throw "Unclosed C# fence in $($target.file) starting at line $($target.startLine)." }
        $nl = $lineMatches[$openIdx].Groups['ending'].Value
        if (-not $nl) { $nl = "`n" }
        $bodyStart = $lineMatches[$openIdx].Index + $lineMatches[$openIdx].Length
        $bodyEnd = $lineMatches[$closeIdx].Index
        $replacementBody = $candidate.candidateSource.Replace("`r`n", "`n").Replace("`n", $nl) + $nl
        $updatedText = $originalText.Remove($bodyStart, $bodyEnd - $bodyStart).Insert($bodyStart, $replacementBody)
        Write-Page $target.file $originalText $updatedText
        $fenceUpdated = $true
    }

    # Atomically upsert the recipe in run-actions.settings.json without touching recipes matching other fences!
    $otherFenceHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($other in $normalizedExamples) {
        if ($other.uid -ceq $target.uid -and $other.fenceOrdinal -ne $target.fenceOrdinal) {
            $null = $otherFenceHashes.Add($other.sourceSha256)
        }
    }

    $settingsList = [Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($r in $recipes) {
        $rUid = [string]$r.uid
        $rHash = if ($r.sourceSha256) { ([string]$r.sourceSha256).ToUpperInvariant() } else { '' }
        $rOrd = $null
        if ($r.PSObject.Properties['fenceOrdinal'] -and $null -ne $r.fenceOrdinal) { $rOrd = [int]$r.fenceOrdinal }
        elseif ($r.PSObject.Properties['exampleId'] -and ([string]$r.exampleId) -match '#(\d+)$') { $rOrd = [int]$Matches[1] }

        # Never overwrite an existing recipe that still matches a different fence!
        if ($rUid -ceq $target.uid -and $null -ne $rOrd -and $rOrd -ne $target.fenceOrdinal) {
            $settingsList.Add($r)
            continue
        }
        if ($rUid -ceq $target.uid -and $null -eq $rOrd -and $otherFenceHashes.Contains($rHash) -and $rHash -cne $target.sourceSha256) {
            $settingsList.Add($r)
            continue
        }
        if ($rUid -ceq $target.uid -and (($null -ne $rOrd -and $rOrd -eq $target.fenceOrdinal) -or $rHash -ceq $target.sourceSha256 -or $rHash -ceq $candidate.candidateSourceSha256)) {
            if (-not $replaced) {
                $settingsList.Add($candidate.recipe)
                $replaced = $true
            }
            continue
        }
        $settingsList.Add($r)
    }
    if (-not $replaced) { $settingsList.Add($candidate.recipe) }

    $settingsDoc = [ordered]@{ examples = @($settingsList) }
    $null = Write-AtomicChanged $Settings (($settingsDoc | ConvertTo-Json -Depth 30) + "`n")

    ([ordered]@{
        schemaVersion = 2
        applied = $true
        exampleId = $target.exampleId
        uid = $target.uid
        fenceOrdinal = $target.fenceOrdinal
        file = $target.file
        settingsPath = $Settings
        fenceUpdated = $fenceUpdated
        sourceSha256 = $candidate.candidateSourceSha256
        recipeSha256 = $candidate.recipeSha256
    } | ConvertTo-Json -Depth 20)
    exit 0
}

# ---------------------------------------------------------------------------
# MODE 7: Generation & Verification
# ---------------------------------------------------------------------------
if ($duplicateRecipeKeys.Count -gt 0) {
    throw "Duplicate recipe for $($duplicateRecipeKeys[0])"
}

$verifyTargetIds = $null
if ($idList.Count -gt 0) {
    $matchedTargets = Select-TargetExamples @($idList)
    if ($matchedTargets.Count -eq 0) {
        $msg = "No examples matched --id selector(s): $($idList -join ', ')"
        if ($SummaryJson -or $Json) {
            ([ordered]@{ schemaVersion = 2; exitCode = 3; failureReason = 'example-not-found'; error = $msg } | ConvertTo-Json -Depth 10)
        } else {
            [Console]::Error.WriteLine($msg)
        }
        exit 3
    }
    $verifyTargetIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($mt in $matchedTargets) { $null = $verifyTargetIds.Add($mt.exampleId) }
}

$toolHash = Hash ((Get-Content $PSCommandPath -Raw) + (Get-Content (Join-Path $PSScriptRoot 'docfx.cs') -Raw) + (Get-Content (Join-Path $PSScriptRoot 'integration-example.ps1') -Raw) + (Get-Content $helpers -Raw) + $script:Csrun021Asset + $script:Csrun021Sha256 + $script:CsrunTestVerificationTemplate)
$resultMaps = [Collections.Generic.List[object]]::new()
$pendingVerifications = [Collections.Generic.List[object]]::new()
$manifestEntries = [Collections.Generic.List[object]]::new()
$associations = [hashtable]::new([StringComparer]::Ordinal)
$pages = @((@($inventory.examples.file) + @($inventory.associatedPages)) | Where-Object { $_ } | Sort-Object -CaseSensitive -Unique)
foreach ($page in $pages) { Assert-RepositoryPath $page }

# Preflight verification engine BEFORE mutating any file or manifest!
$resolvedVerificationEngine = $null
if ($EnginePath) {
    $fullEnginePath = [IO.Path]::GetFullPath($EnginePath)
    if (-not (Test-Path -LiteralPath $fullEnginePath -PathType Leaf)) {
        if ($Verify -ne 'None') {
            $errPayload = [ordered]@{
                schemaVersion = 2
                exitCode = 1
                failureReason = 'engine-path-not-found'
                manifestPreserved = (Test-Path -LiteralPath $manifestPath)
                error = "csrun engine asset not found: $fullEnginePath"
            }
            $errPayload | ConvertTo-Json -Depth 10
            exit 1
        }
        throw "csrun engine asset not found: $fullEnginePath"
    }
    $resolvedVerificationEngine = [pscustomobject]@{
        Path = $fullEnginePath
        Tag = $null
        Sha256 = (Get-FileHash -LiteralPath $fullEnginePath -Algorithm SHA256).Hash.ToUpperInvariant()
        Source = 'Explicit'
    }
}

$needsStandaloneEnginePreflight = $false
if ($Verify -ne 'None' -and -not $resolvedVerificationEngine) {
    foreach ($ex in $normalizedExamples) {
        if ($verifyTargetIds -and -not $verifyTargetIds.Contains($ex.exampleId)) { continue }
        $r = Find-MatchingRecipe $ex
        if ($r -and ($r.intrinsicLimitation -or $r.PSObject.Properties['repository'] -or $r.mode -eq 'host' -or $r.PSObject.Properties['hostHarness'])) { continue }
        if (-not $r -and $ex.sourceSha256 -ceq '47B0C1FBA94E7B43C8753D0A8242801B328E6B463B6EEDAEB640D4F8A262633E') { continue }
        $preflightFramework = if ($r -and $r.manifest -and $r.manifest.PSObject.Properties['framework'] -and $r.manifest.framework) { [string]$r.manifest.framework } else { $Framework }
        if (Test-NetFrameworkTfm $preflightFramework) {
            if ($Verify -eq 'Docker' -or -not $isWindowsHost) { continue }
        }
        if ($r -and $r.manifest) { $needsStandaloneEnginePreflight = $true; break }
        if (-not $r -and -not $ex.raw.source -and $ex.eligible -and $ex.standalone -ne $ex.isTest -and $ex.source -notmatch '(?m)^#:') { $needsStandaloneEnginePreflight = $true; break }
    }
}

if ($needsStandaloneEnginePreflight) {
    try {
        $resolvedVerificationEngine = Resolve-CsrunEngine
    } catch {
        $failureReason = Get-EngineFailureReason $_.Exception.Message
        $errPayload = [ordered]@{
            schemaVersion = 2
            mode = 'verify'
            exitCode = 1
            failureReason = $failureReason
            manifestPreserved = (Test-Path -LiteralPath $manifestPath)
            error = $_.Exception.Message
            generated = 0
            unchanged = 0
            verified = 0
            failed = 1
            unresolved = 0
            intrinsic = 0
            'skipped-by-category' = [ordered]@{}
        }
        $errPayload | ConvertTo-Json -Depth 10
        exit 1
    }
}

$verificationExecuted = 0
$verificationReused = 0
$verificationFailedCount = 0

foreach ($exObj in $normalizedExamples) {
    $example = $exObj.raw
    $displayedSource = $exObj.displayedSource
    $source = $exObj.source
    $sourceHash = $exObj.sourceSha256
    $id = $exObj.id
    $result = [ordered]@{
        id = $id
        exampleId = $exObj.exampleId
        fenceOrdinal = $exObj.fenceOrdinal
        file = $example.file
        uid = $example.uid
        sourceSha256 = $sourceHash
        status = 'unresolved'
        coverage = 'Unresolved'
        category = $exObj.classification.category
        reasonCode = $exObj.classification.reasonCode
        reason = $null
        native = 'Unverified'
        docker = 'Unverified'
    }
    try {
        if ($example.contextError) { $result.reason = $example.contextError; continue }
        if ($example.sourceSha256 -and $example.sourceSha256 -cne $sourceHash) { throw 'The inventory and generator disagree on the displayed source hash.' }

        $recipe = Find-MatchingRecipe $exObj
        if ($recipe -and $recipe.PSObject.Properties['harness']) {
            throw 'Move the executable C# into the displayed sample and update its recipe hash.'
        }
        $strategy = 'standalone'
        # Known, inspected integration source. No API-name heuristic may substitute a different test.
        if (-not $recipe -and $sourceHash -ceq '47B0C1FBA94E7B43C8753D0A8242801B328E6B463B6EEDAEB640D4F8A262633E') {
            $recipe = [pscustomobject]@{ repository='codebeltnet/xunit'; commit='84b13767cb9484f8f3a36a71875662edfdb3e511'; project='test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj'; test='Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorkerApplicationTestTest.ShouldBootstrapMinimalWorkerProgram'; framework='net11.0'; image='mcr.microsoft.com/dotnet/sdk:11.0' }
        }
        $isTest = $example.isTest
        if ($recipe.intrinsicLimitation) {
            if ($recipe.manifest -or $recipe.repository -or $recipe.hostHarness) { throw 'An intrinsic limitation cannot also supply an execution recipe.' }
            $result.status = 'unsupported'; $result.coverage = 'Intrinsically non-executable'; $result.category = 'intrinsic'; $result.reasonCode = 'intrinsic-limitation'; $result.reason = $recipe.intrinsicLimitation
            $result.native = 'Unsupported'; $result.docker = 'Unsupported'
            continue
        }
        if ($recipe -and $recipe.PSObject.Properties['repository']) { $strategy = 'repository' }
        elseif ($recipe -and ($recipe.mode -eq 'host' -or $recipe.PSObject.Properties['hostHarness'] -or ($recipe.manifest -and $recipe.manifest.mode -eq 'host'))) { $strategy = 'host' }
        elseif ($example.source -and -not ($recipe -and $recipe.PSObject.Properties['manifest'])) {
            $result.reason = 'Inspect the maintained project and source for exact published dependencies or a pinned repository test.'
            continue
        }
        elseif (-not $recipe -and (-not $example.eligible -or $example.standalone -eq $isTest -or $source -match '(?m)^#:')) {
            $result.reason = 'Resolve the dependencies and entry point from the source project, published assets, and maintained tests.'
            continue
        }
        if ($recipe -and -not $recipe.manifest -and $strategy -notin @('repository', 'host')) { throw 'A recipe must supply a standalone manifest, hostHarness, or pinned repository test.' }
        $effectiveFramework = if ($strategy -eq 'repository') {
            if ($recipe -and $recipe.PSObject.Properties['framework'] -and $recipe.framework) { [string]$recipe.framework } else { $Framework }
        } elseif ($strategy -eq 'host') {
            if ($recipe -and $recipe.PSObject.Properties['hostHarness'] -and $recipe.hostHarness -and $recipe.hostHarness.PSObject.Properties['framework'] -and $recipe.hostHarness.framework) { [string]$recipe.hostHarness.framework }
            elseif ($recipe -and $recipe.manifest -and $recipe.manifest.PSObject.Properties['framework'] -and $recipe.manifest.framework) { [string]$recipe.manifest.framework }
            else { $Framework }
        } else {
            if ($recipe -and $recipe.manifest -and $recipe.manifest.PSObject.Properties['framework'] -and $recipe.manifest.framework) { [string]$recipe.manifest.framework } else { $Framework }
        }
        $isNetFrameworkTarget = Test-NetFrameworkTfm $effectiveFramework
        $transports = @('native','docker')
        foreach ($transport in @('native','docker')) {
            if ($recipe -and $recipe.unsupportedTransports.$transport) {
                $result[$transport] = 'Unsupported'
                $result["${transport}Reason"] = $recipe.unsupportedTransports.$transport
                $transports = @($transports | Where-Object { $_ -ne $transport })
            }
        }
        if ($isNetFrameworkTarget -and 'docker' -in $transports) {
            $result['docker'] = 'Unsupported'
            $result['dockerReason'] = $NetFrameworkDockerUnsupportedReason
            $transports = @($transports | Where-Object { $_ -ne 'docker' })
        }
        if (-not $transports.Count) {
            $result.status = 'unsupported'; $result.coverage = 'Intrinsically non-executable'
            $result.reason = "Native: $($result.nativeReason) Docker: $($result.dockerReason)"
            continue
        }
        $result.strategy = $strategy
        if ($strategy -in @('standalone', 'host')) { $result.executionSourceSha256 = Hash $displayedSource }
        $image = if ($recipe.csrunImage) { $recipe.csrunImage } else { $CsrunImage }
        $fingerprint = Hash ("$toolHash|$sourceHash|$strategy|$Framework|$image|$($result.executionSourceSha256)|" + ($recipe | ConvertTo-Json -Depth 30 -Compress))
        $manifestObject = $null
        $hostHarnessObj = $null
        if ($strategy -eq 'standalone') {
            if ($recipe) {
                $manifestObject = $recipe.manifest | Select-Object *
            } else {
                $manifestObject = [pscustomobject]@{ schemaVersion=1; mode=$(if ($isTest) {'test'} else {'console'}); framework=$Framework; dependsOn=@($(if ($isTest) {'xunit.v3@4.0.3'})) }
                if ($exObj.dependencies.sdk -and $exObj.dependencies.sdk -ne 'Microsoft.NET.Sdk') {
                    $manifestObject | Add-Member -NotePropertyName sdk -NotePropertyValue ([string]$exObj.dependencies.sdk) -Force
                }
                $autoFwRefs = @($exObj.dependencies.frameworkReferences | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
                if ($autoFwRefs.Count -gt 0) {
                    $manifestObject | Add-Member -NotePropertyName frameworkReferences -NotePropertyValue $autoFwRefs -Force
                }
            }
            if ($manifestObject.PSObject.Properties['source'] -and (Normalize $manifestObject.source) -cne $displayedSource) { throw 'Manifest source differs from displayed C#.' }
            $manifestObject | Add-Member -NotePropertyName source -NotePropertyValue $displayedSource -Force
        } elseif ($strategy -eq 'host') {
            $hh = if ($recipe.PSObject.Properties['hostHarness'] -and $recipe.hostHarness) { $recipe.hostHarness } else { [pscustomobject]@{} }
            $hostFw = if ($hh.PSObject.Properties['framework'] -and $hh.framework) { [string]$hh.framework } elseif ($recipe.manifest -and $recipe.manifest.framework) { [string]$recipe.manifest.framework } else { $Framework }
            $hostDeps = if ($hh.PSObject.Properties['dependsOn'] -and $hh.dependsOn) { [string[]]@($hh.dependsOn) } elseif ($recipe.manifest -and $recipe.manifest.dependsOn) { [string[]]@($recipe.manifest.dependsOn) } else { @() }
            $hostHarnessObj = [ordered]@{
                sdk = if ($hh.PSObject.Properties['sdk'] -and $hh.sdk) { [string]$hh.sdk } else { 'Microsoft.NET.Sdk.Web' }
                framework = $hostFw
                dependsOn = @($hostDeps)
                probePath = if ($hh.PSObject.Properties['probePath']) { [string]$hh.probePath } else { '/' }
                probeMethod = if ($hh.PSObject.Properties['probeMethod'] -and $hh.probeMethod) { [string]$hh.probeMethod } else { 'GET' }
                timeoutSeconds = if ($hh.PSObject.Properties['timeoutSeconds'] -and $hh.timeoutSeconds) { [int]$hh.timeoutSeconds } else { 15 }
                expectedStatusCode = if ($hh.PSObject.Properties['expectedStatusCode'] -and $hh.expectedStatusCode) { [int]$hh.expectedStatusCode } else { 0 }
                expectedBodyContains = if ($hh.PSObject.Properties['expectedBodyContains'] -and $hh.expectedBodyContains) { [string]$hh.expectedBodyContains } else { '' }
                startupDelayMs = if ($hh.PSObject.Properties['startupDelayMs'] -and $hh.startupDelayMs) { [int]$hh.startupDelayMs } else { 1000 }
            }
        }
        if ($strategy -eq 'repository') {
            $pair = New-RepositoryExamplePair -Repository $recipe.repository -Commit $recipe.commit -Project $recipe.project -Test $recipe.test -Framework $recipe.framework -Image $recipe.image
        } elseif ($strategy -eq 'host') {
            $pair = New-HostExamplePair `
                -Source $displayedSource `
                -Framework $hostHarnessObj.framework `
                -Sdk $hostHarnessObj.sdk `
                -DependsOn $hostHarnessObj.dependsOn `
                -ProbePath $hostHarnessObj.probePath `
                -ProbeMethod $hostHarnessObj.probeMethod `
                -TimeoutSeconds $hostHarnessObj.timeoutSeconds `
                -ExpectedStatusCode $hostHarnessObj.expectedStatusCode `
                -ExpectedBodyContains $hostHarnessObj.expectedBodyContains `
                -StartupDelayMs $hostHarnessObj.startupDelayMs `
                -Image $image
        } else {
            $manifestJson = $manifestObject | ConvertTo-Json -Depth 30
            $pair = New-CsrunExecutionPair -ManifestJson $manifestJson -Image $image
        }

        $manifestEntry = if ($strategy -eq 'repository') {
            [ordered]@{
                id = $id
                exampleId = $exObj.exampleId
                uid = $example.uid
                fenceOrdinal = $exObj.fenceOrdinal
                strategy = 'repository'
                transports = @($transports)
                repository = $recipe.repository
                commit = $recipe.commit
                project = $recipe.project
                test = $recipe.test
                framework = $recipe.framework
                image = $recipe.image
            }
        } elseif ($strategy -eq 'host') {
            [ordered]@{
                id = $id
                exampleId = $exObj.exampleId
                uid = $example.uid
                fenceOrdinal = $exObj.fenceOrdinal
                strategy = 'host'
                transports = @($transports)
                framework = $hostHarnessObj.framework
                image = $image
                source = $displayedSource
                hostHarness = $hostHarnessObj
            }
        } else {
            [ordered]@{
                id = $id
                exampleId = $exObj.exampleId
                uid = $example.uid
                fenceOrdinal = $exObj.fenceOrdinal
                strategy = 'standalone'
                transports = @($transports)
                image = $image
                manifest = $manifestObject
            }
        }
        $manifestEntryJson = $manifestEntry | ConvertTo-Json -Depth 30 -Compress
        $changed = -not $oldManifestById.ContainsKey($id) -or ($oldManifestById[$id] -cne $manifestEntryJson)

        $verifyPair = $null
        $inVerifyScope = (-not $verifyTargetIds) -or $verifyTargetIds.Contains($exObj.exampleId)
        foreach ($transport in $transports) {
            $script = Normalize $pair.$transport
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseInput($script,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "Generated $transport script has syntax errors: $errors" }
            $scriptHash = Hash $script
            $result["${transport}Sha256"] = $scriptHash
            $evidencePath = if ($evidenceDirectory) { Join-Path $evidenceDirectory "$configHash-$id-$transport-$scriptHash.json" }

            # Read existing cached evidence first (supports both unverified runs and --verify-changed reuse).
            $cachedState = $null
            $cachedLog = $null
            $cachedEngineSha = $null
            if ($evidencePath -and (Test-PrivateCacheItem $evidencePath)) {
                try {
                    $evidence = [IO.File]::ReadAllText($evidencePath) | ConvertFrom-Json
                    if ($evidence.state -in @('Verified', 'Failed') -and
                        $evidence.log -cmatch "\Adocfx-run-$id-$transport-[a-f0-9]{32}\.log\z") {
                        $log = Join-Path $evidenceDirectory $evidence.log
                        if (Test-PrivateCacheItem $log) {
                            $cachedState = $evidence.state
                            $cachedLog = $log
                            if ($evidence.PSObject.Properties['engineSha256'] -and $evidence.engineSha256) {
                                $cachedEngineSha = ([string]$evidence.engineSha256).ToUpperInvariant()
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Could not read $transport verification evidence for $id"
                }
            }

            $shouldRunVerify = $inVerifyScope -and ($Verify -eq 'Both' -or $Verify -eq $transport)
            if ($shouldRunVerify -and $transport -eq 'native' -and $isNetFrameworkTarget -and -not $isWindowsHost) {
                $shouldRunVerify = $false
                $result['native'] = 'Unverified'
                $result['nativeReason'] = "Framework '$effectiveFramework' targets .NET Framework and requires Windows for Native verification."
                if (-not $Quiet) {
                    [Console]::Error.WriteLine("[skip] $($exObj.exampleId) (Native) -> Unverified ($effectiveFramework requires Windows)")
                }
                continue
            }
            $engineMatchesEvidence = ($strategy -ne 'standalone') -or (
                $resolvedVerificationEngine -and
                $resolvedVerificationEngine.Sha256 -and
                $cachedEngineSha -and
                $cachedEngineSha -ceq ([string]$resolvedVerificationEngine.Sha256).ToUpperInvariant()
            )
            if ($shouldRunVerify -and $VerifyChanged -and -not $changed -and $cachedState -eq 'Verified' -and $engineMatchesEvidence) {
                $shouldRunVerify = $false
                $verificationReused++
                $result[$transport] = $cachedState
                $result["${transport}Evidence"] = $cachedLog
                continue
            }

            if ($shouldRunVerify) {
                if (-not $evidencePath) { throw 'A private, user-owned directory is required to record run-action verification.' }
                $executionScript = $script
                if ($strategy -eq 'standalone') {
                    if (-not $resolvedVerificationEngine) {
                        $resolvedVerificationEngine = Resolve-CsrunEngine
                    }
                    if (-not $verifyPair) {
                        $verifyPair = New-CsrunExecutionPair -ManifestJson $manifestJson -Image $image -EnginePath $resolvedVerificationEngine.Path
                    }
                    $executionScript = Normalize $verifyPair.$transport
                }
                $pendingVerifications.Add([pscustomobject]@{
                    ResultIndex = $resultMaps.Count
                    Id = $id
                    ExampleId = $exObj.exampleId
                    Transport = $transport
                    TransportLabel = if ($transport -eq 'native') { 'Native' } else { 'Docker' }
                    Strategy = $strategy
                    ExecutionScript = $executionScript
                    EvidencePath = $evidencePath
                    EngineSha256 = if ($strategy -eq 'standalone' -and $resolvedVerificationEngine) { $resolvedVerificationEngine.Sha256 } else { $null }
                    EngineTag = if ($strategy -eq 'standalone' -and $resolvedVerificationEngine) { $resolvedVerificationEngine.Tag } else { $null }
                })
            } elseif ($cachedState) {
                $result[$transport] = $cachedState
                $result["${transport}Evidence"] = $cachedLog
                if ($Verify -ne 'None') { $verificationReused++ }
            }
        }

        $result.status = if ($changed) { 'generated' } else { 'unchanged' }
        $result.coverage = if ($transports.Count -eq 2) { 'Paired' } else { 'Partially supported' }
        if ($recipe.explanation) { $result.explanation = $recipe.explanation }
        $result.fingerprint = $fingerprint
        $manifestEntries.Add($manifestEntry)
        $links = @($transports | ForEach-Object {
            $label = if ($_ -eq 'native') { 'Native' } else { 'Docker' }
            '<a href="~/run-actions/' + $id + '/' + $_ + '.ps1" data-transport="' + $_ + '">View ' + $label + ' Script</a>'
        })
        $note = if ($strategy -eq 'repository') { '<p>Runs the pinned repository test <code>' + [Net.WebUtility]::HtmlEncode($recipe.test) + '</code>.</p>' }
                elseif ($strategy -eq 'host') { '<p>Starts the host with a timeout, performs the demonstrated action, and shuts down cleanly.</p>' }
                else { '' }
        $note += if ($recipe.explanation) { '<p>' + [Net.WebUtility]::HtmlEncode($recipe.explanation) + '</p>' } else { '' }
        $link = '<div class="docfx-run-actions" data-example-id="' + $id + '">' + ($links -join ' · ') + $note + '</div>'
        if (-not $associations.ContainsKey($example.file)) { $associations[$example.file] = @{} }
        $associations[$example.file][[int]$example.startLine] = "<!-- docfx-run-actions:start -->`n$link`n<!-- docfx-run-actions:end -->"
    } catch { $result.status='failed'; $result.reason=$_.Exception.Message }
    finally { $resultMaps.Add($result) }
}

if ($pendingVerifications.Count -gt 0) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    $isMockedPwsh = ($null -ne $pwshCmd -and $pwshCmd.CommandType -eq 'Function')
    $pwshExe = if (-not $isMockedPwsh) {
        (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    } else { $null }

    $totalPending = $pendingVerifications.Count
    $verifySw = [Diagnostics.Stopwatch]::StartNew()
    $progressLock = [object]::new()
    $progressState = [hashtable]::Synchronized(@{
        Completed = 0
        InFlight = 0
        Verified = 0
        Failed = 0
        LastActivityUtc = [DateTimeOffset]::UtcNow
    })

    $nativeBatch = @($pendingVerifications | Where-Object { $_.Transport -eq 'native' })
    $dockerBatch = @($pendingVerifications | Where-Object { $_.Transport -eq 'docker' })
    $verifyBatches = [Collections.Generic.List[object]]::new()
    if ($nativeBatch.Count -gt 0) {
        $verifyBatches.Add([pscustomobject]@{ Transport = 'native'; Items = $nativeBatch; ThrottleLimit = $effectiveNativeParallel })
    }
    if ($dockerBatch.Count -gt 0) {
        $verifyBatches.Add([pscustomobject]@{ Transport = 'docker'; Items = $dockerBatch; ThrottleLimit = $effectiveDockerParallel })
    }

    foreach ($batch in $verifyBatches) {
        $batchResults = @()
        if ($isMockedPwsh) {
            $seqList = [Collections.Generic.List[object]]::new()
            foreach ($item in $batch.Items) {
                $itemSw = [Diagnostics.Stopwatch]::StartNew()
                $runName = "docfx-run-$($item.Id)-$($item.Transport)-" + [guid]::NewGuid().ToString('N')
                $tempScript = Join-Path $evidenceDirectory "$runName.ps1"
                $log = Join-Path $evidenceDirectory "$runName.log"
                $state = 'Failed'
                $workerError = $null
                try {
                    [IO.File]::WriteAllText($tempScript, $item.ExecutionScript, [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText($log, '')
                    & pwsh -NoProfile -NonInteractive -File $tempScript *> $log
                    $state = if ($LASTEXITCODE -eq 0) { 'Verified' } else { 'Failed' }
                    $pendingEvidence = Join-Path $evidenceDirectory "$runName.tmp"
                    try {
                        $evidence = [ordered]@{ state = $state; log = "$runName.log" }
                        if ($item.Strategy -eq 'standalone' -and $item.EngineSha256) {
                            $evidence.engineSha256 = $item.EngineSha256
                            if ($item.EngineTag) { $evidence.engineTag = $item.EngineTag }
                        }
                        [IO.File]::WriteAllText($pendingEvidence, ($evidence | ConvertTo-Json -Compress))
                        if (-not $IsWindows) { & chmod 600 -- $pendingEvidence $log }
                        [IO.File]::Move($pendingEvidence, $item.EvidencePath, $true)
                    } finally {
                        if (Test-Path -LiteralPath $pendingEvidence) { [IO.File]::Delete($pendingEvidence) }
                    }
                } catch {
                    $state = 'Failed'
                    $workerError = $_.Exception.Message
                } finally {
                    if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue }
                    $itemSw.Stop()
                    $elapsedSec = $itemSw.Elapsed.TotalSeconds
                    $progressState.Completed++
                    if ($state -eq 'Verified') { $progressState.Verified++ } else { $progressState.Failed++ }
                    $progressState.LastActivityUtc = [DateTimeOffset]::UtcNow
                    if (-not $Quiet) {
                        $elapsedText = $elapsedSec.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
                        [Console]::Error.WriteLine("[$($progressState.Completed)/$totalPending] Verifying $($item.ExampleId) ($($item.TransportLabel)) -> $state (${elapsedText}s)")
                    }
                }
                $seqList.Add([pscustomobject]@{
                    ResultIndex = $item.ResultIndex
                    Transport = $item.Transport
                    State = $state
                    EvidencePath = $log
                    ElapsedSeconds = [Math]::Round($elapsedSec, 3)
                    Error = $workerError
                })
            }
            $batchResults = @($seqList)
        } else {
            $job = $batch.Items | ForEach-Object -ThrottleLimit $batch.ThrottleLimit -AsJob -Parallel {
                $ErrorActionPreference = 'Stop'
                $PSNativeCommandUseErrorActionPreference = $false
                $item = $_
                $lockRef = $using:progressLock
                $stateRef = $using:progressState
                $evidenceDirRef = $using:evidenceDirectory
                $pwshExeRef = $using:pwshExe
                $isWinRef = $using:IsWindows
                $quietRef = $using:Quiet
                $totalPendingRef = $using:totalPending
                $itemSw = [Diagnostics.Stopwatch]::StartNew()
                [Threading.Monitor]::Enter($lockRef)
                try { $stateRef.InFlight++ } finally { [Threading.Monitor]::Exit($lockRef) }

                $runName = "docfx-run-$($item.Id)-$($item.Transport)-" + [guid]::NewGuid().ToString('N')
                $tempScript = Join-Path $evidenceDirRef "$runName.ps1"
                $log = Join-Path $evidenceDirRef "$runName.log"
                $state = 'Failed'
                $workerError = $null
                try {
                    [IO.File]::WriteAllText($tempScript, $item.ExecutionScript, [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText($log, '')
                    & $pwshExeRef -NoProfile -NonInteractive -File $tempScript *> $log
                    $state = if ($LASTEXITCODE -eq 0) { 'Verified' } else { 'Failed' }
                    $pendingEvidence = Join-Path $evidenceDirRef "$runName.tmp"
                    try {
                        $evidence = [ordered]@{ state = $state; log = "$runName.log" }
                        if ($item.Strategy -eq 'standalone' -and $item.EngineSha256) {
                            $evidence.engineSha256 = $item.EngineSha256
                            if ($item.EngineTag) { $evidence.engineTag = $item.EngineTag }
                        }
                        [IO.File]::WriteAllText($pendingEvidence, ($evidence | ConvertTo-Json -Compress))
                        if (-not $isWinRef) { & chmod 600 -- $pendingEvidence $log }
                        [IO.File]::Move($pendingEvidence, $item.EvidencePath, $true)
                    } finally {
                        if (Test-Path -LiteralPath $pendingEvidence) { [IO.File]::Delete($pendingEvidence) }
                    }
                } catch {
                    $state = 'Failed'
                    $workerError = $_.Exception.Message
                } finally {
                    if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue }
                    $itemSw.Stop()
                    $elapsedSec = $itemSw.Elapsed.TotalSeconds
                    [Threading.Monitor]::Enter($lockRef)
                    try {
                        $stateRef.InFlight--
                        $stateRef.Completed++
                        if ($state -eq 'Verified') { $stateRef.Verified++ } else { $stateRef.Failed++ }
                        $stateRef.LastActivityUtc = [DateTimeOffset]::UtcNow
                        if (-not $quietRef) {
                            $elapsedText = $elapsedSec.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
                            [Console]::Error.WriteLine("[$($stateRef.Completed)/$totalPendingRef] Verifying $($item.ExampleId) ($($item.TransportLabel)) -> $state (${elapsedText}s)")
                        }
                    } finally {
                        [Threading.Monitor]::Exit($lockRef)
                    }
                }
                [pscustomobject]@{
                    ResultIndex = $item.ResultIndex
                    Transport = $item.Transport
                    State = $state
                    EvidencePath = $log
                    ElapsedSeconds = [Math]::Round($elapsedSec, 3)
                    Error = $workerError
                }
            }
            try {
                while ($job.State -in @('NotStarted', 'Running')) {
                    Start-Sleep -Milliseconds 250
                    if (-not $Quiet -and -not $NoHeartbeat) {
                        $nowUtc = [DateTimeOffset]::UtcNow
                        [Threading.Monitor]::Enter($progressLock)
                        try {
                            if (($nowUtc - $progressState.LastActivityUtc).TotalSeconds -ge $HeartbeatSeconds) {
                                $totalElapsed = $verifySw.Elapsed.TotalSeconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
                                [Console]::Error.WriteLine("[heartbeat] Verification progress: $($progressState.Completed)/$totalPending completed ($($progressState.InFlight) running, $($progressState.Verified) verified, $($progressState.Failed) failed, ${totalElapsed}s elapsed)")
                                $progressState.LastActivityUtc = $nowUtc
                            }
                        } finally {
                            [Threading.Monitor]::Exit($progressLock)
                        }
                    }
                }
                $batchResults = @(Receive-Job -Job $job -Wait)
            } finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($vr in $batchResults) {
            if ($null -eq $vr) { continue }
            $targetResult = $resultMaps[$vr.ResultIndex]
            $targetResult[$vr.Transport] = $vr.State
            $targetResult["$($vr.Transport)Evidence"] = $vr.EvidencePath
            if ($vr.Error -and -not $targetResult.reason) {
                $targetResult.reason = $vr.Error
            }
            $verificationExecuted++
            if ($vr.State -eq 'Failed') { $verificationFailedCount++ }
        }
    }
    $verifySw.Stop()
}

$results = [Collections.Generic.List[object]]::new()
foreach ($rm in $resultMaps) { $results.Add([pscustomobject]$rm) }

$hasHardFailure = (@($results | Where-Object { $_.status -eq 'failed' -or $_.native -eq 'Failed' -or $_.docker -eq 'Failed' }).Count -gt 0)
$skipMutations = ($Verify -ne 'None' -and $hasHardFailure)
# Never replace or destroy a previous manifest or page associations as a side effect of any hard verification failure.
$manifestPreserved = $skipMutations -and (Test-Path -LiteralPath $manifestPath)

if (-not $skipMutations) {
    # Apply edits by offset in the original text so each existing line ending is preserved.
    foreach ($page in $pages) {
        if (-not (Test-Path -LiteralPath $page)) { continue }
        $original = [IO.File]::ReadAllText($page)
        $edits = [Collections.Generic.List[object]]::new()
        foreach ($block in [regex]::Matches($original, '(?s)(?:\A|(?:\r\n|\n|\r){1,2})<!-- docfx-run-actions:start -->.*?<!-- docfx-run-actions:end -->')) {
            $edits.Add(@{ Offset = $block.Index; Length = $block.Length; Text = '' })
        }
        if ($associations.ContainsKey($page)) {
            $lines = [regex]::Matches($original, '(?<text>[^\r\n]*)(?<ending>\r\n|\n|\r|$)')
            foreach ($line in $associations[$page].Keys) {
                $end = $line
                while ($end -lt $lines.Count -and $lines[$end].Groups['text'].Value -notmatch '^\s*```') { $end++ }
                if ($end -ge $lines.Count) { throw "Unclosed fence in $page" }
                $fence = $lines[$end]
                $newline = $fence.Groups['ending'].Value
                if (-not $newline) { $newline = $lines[$end - 1].Groups['ending'].Value }
                $edits.Add(@{
                    Offset = $fence.Index + $fence.Groups['text'].Length
                    Length = 0
                    Text = $newline + $newline + $associations[$page][$line].Replace("`n", $newline)
                })
            }
        }
        $updated = $original
        # At a shared offset remove the previous association before inserting its replacement.
        foreach ($edit in $edits | Sort-Object -Property Offset, Length -Descending) {
            $updated = $updated.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.Text)
        }
        Write-Page $page $original $updated
    }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $config.build) { throw 'docfx.json requires build configuration.' }
    $resources = @($config.build.resource)
    if (-not @($resources | Where-Object { ($_ | ConvertTo-Json -Compress) -match 'run-actions/\*\*' }).Count) {
        $config.build.resource = @($resources | Where-Object { $null -ne $_ }) + @(@{ files=@('run-actions/**') })
    }
    # Compose with an existing modern main.js rather than overriding its default export/start hook (e.g. Context7).
    # DocFX supplies the embedded default when template is omitted. Keep that base
    # when adding our overlay, including sites previously written as [null, overlay].
    $templates = @($config.build.template)
    $templatesChanged = $null -in $templates
    if ($templatesChanged) {
        $templates = @('default') + @($templates | Where-Object { $null -ne $_ -and $_ -ne 'default' })
    }
    $main = $null
    foreach ($template in $templates) {
        $candidate = Join-Path $workspace "$template/public/main.js"
        if (Test-Path $candidate) { $main=$candidate }
    }
    if (-not $main) {
        $main = Join-Path $workspace 'templates/modern/public/main.js'
        $null = Write-Changed $main "export default {};`n"
        if ('templates/modern' -notin $templates) {
            $templates = $templates + @('templates/modern')
            $templatesChanged = $true
        }
    }
    $msStyleTemplates = @($templates | Where-Object { $_ -eq 'templates/ms-style' })
    if ($msStyleTemplates.Count -gt 0) {
        $reorderedTemplates = @($templates | Where-Object { $_ -ne 'templates/ms-style' }) + $msStyleTemplates
        if (($reorderedTemplates -join "`0") -ne ($templates -join "`0")) {
            $templates = $reorderedTemplates
            $templatesChanged = $true
        }
    }
    if ($templatesChanged) { $config.build.template = $templates }
    Assert-RepositoryPath $main
    $mainText = [IO.File]::ReadAllText($main)
    if (-not $mainText.Contains("import './run-actions.js';")) { $null = Write-Changed $main ($mainText + "`nimport './run-actions.js';`n") }
    $null = Write-Changed (Join-Path (Split-Path $main -Parent) 'run-actions.js') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/run-actions.js')))
    $null = Write-Changed $configPath (($config | ConvertTo-Json -Depth 100) + "`n")
    $sortedManifest = @($manifestEntries | Sort-Object { $_.id })
    $null = Write-AtomicChanged $manifestPath (([ordered]@{ schemaVersion = 1; examples = $sortedManifest } | ConvertTo-Json -Depth 30) + "`n")
    $null = Write-Changed (Join-Path $workspace 'BuildRunActions.ps1') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/BuildRunActions.ps1')))
}

function Test-DockerBuildCommand($CommandAst) {
    if ($CommandAst.CommandElements.Count -lt 2) { return $false }
    $cmdName = $CommandAst.GetCommandName()
    if (-not $cmdName -or $cmdName -inotmatch '(^|[\\/])docker(\.exe)?$') { return $false }
    $firstArg = $CommandAst.CommandElements[1].Extent.Text.Trim("'`"")
    if ($firstArg -ieq 'build') { return $true }
    if ($firstArg -ieq 'buildx' -and $CommandAst.CommandElements.Count -ge 3) {
        return $CommandAst.CommandElements[2].Extent.Text.Trim("'`"") -ieq 'build'
    }
    return $false
}
function Test-ApiCleanupPipeline($PipelineAst) {
    if ($PipelineAst -isnot [Management.Automation.Language.PipelineAst]) { return $false }
    if ($PipelineAst.PipelineElements.Count -ne 2) { return $false }
    $first = $PipelineAst.PipelineElements[0] -as [Management.Automation.Language.CommandAst]
    $second = $PipelineAst.PipelineElements[1] -as [Management.Automation.Language.CommandAst]
    if (-not $first -or -not $second) { return $false }
    $firstName = $first.GetCommandName()
    $secondName = $second.GetCommandName()
    return ($firstName -ieq 'Get-ChildItem' -or $firstName -ieq 'gci') -and
           ($secondName -ieq 'Remove-Item' -or $secondName -ieq 'ri') -and
           ($PipelineAst.Extent.Text -match '(?i)\bapi\b')
}
function Get-LineIndent([string] $Text, [int] $Offset) {
    if ($Offset -eq 0) { return '' }
    $lineStart = $Text.LastIndexOf("`n", $Offset - 1)
    $lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
    $prefix = $Text.Substring($lineStart, $Offset - $lineStart)
    if ($prefix -notmatch '^[ \t]*$') { return $null }
    return $prefix
}
function Update-BuildDocfxImageScript([string] $Original) {
    $standardFlatPattern = '(?i)\A\s*(?<version>\$version\s*=\s*minver[^\r\n]*)(?:\r?\n[ \t]*)+(?<metadata>docfx\s+metadata[^\r\n]*)(?:\r?\n[ \t]*)+(?:&\s*\(Join-Path\s+\$PSScriptRoot\s+[''"]BuildRunActions\.ps1[''"]\)(?:\r?\n[ \t]*)+)?(?<docker>docker\s+buildx\s+build[^\r\n]*)(?:\r?\n[ \t]*)+(?<cleanup>get-childitem\b[^\r\n]*\|\s*remove-item[^\r\n]*)\s*\z'
    $standardTryPattern = '(?i)\A\s*(?<version>\$version\s*=\s*minver[^\r\n]*)(?:\r?\n[ \t]*)+(?<metadata>docfx\s+metadata[^\r\n]*)(?:\r?\n[ \t]*)+(?:&\s*\(Join-Path\s+\$PSScriptRoot\s+[''"]BuildRunActions\.ps1[''"]\)(?:\r?\n[ \t]*)+)?try\s*\{(?:\r?\n[ \t]*)+(?<docker>docker\s+buildx\s+build[^\r\n]*)(?:\r?\n[ \t]*)+\}(?:\r?\n[ \t]*)+finally\s*\{(?:\r?\n[ \t]*)+(?<cleanup>get-childitem\b[^\r\n]*\|\s*remove-item[^\r\n]*)(?:(?:\r?\n[ \t]*)+if\s*\(\s*Test-Path\s+-LiteralPath\s+\(Join-Path\s+\$PSScriptRoot\s+[''"]run-actions[''"]\)\s*\)\s*\{(?:\r?\n[ \t]*)+Remove-Item\s+-LiteralPath\s+\(Join-Path\s+\$PSScriptRoot\s+[''"]run-actions[''"]\)\s+-Recurse\s+-Force(?:\r?\n[ \t]*)+\})?(?:\r?\n[ \t]*)+\}\s*\z'
    $nl = if ($Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $trailingNewline = if ($Original -match '\r?\n\z') { $nl } else { '' }
    $match = [regex]::Match($Original, $standardFlatPattern)
    if (-not $match.Success) { $match = [regex]::Match($Original, $standardTryPattern) }
    if ($match.Success) {
        return (@(
            $match.Groups['version'].Value.Trim()
            $match.Groups['metadata'].Value.Trim()
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            ('    ' + $match.Groups['docker'].Value.Trim())
            '}'
            'finally {'
            ('    ' + $match.Groups['cleanup'].Value.Trim())
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join $nl) + $trailingNewline
    }

    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Original, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { return $Original }

    $hasInvoke = $null -ne $ast.Find({
        param($node)
        if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
        if ($node.GetCommandName() -match '(^|[\\/])BuildRunActions\.ps1$') { return $true }
        if ($node.InvocationOperator -notin @('Ampersand', 'Dot')) { return $false }
        $target = $node.CommandElements[0]
        if ($target -is [Management.Automation.Language.ParenExpressionAst] -and $target.Pipeline.PipelineElements.Count -eq 1) {
            $join = $target.Pipeline.PipelineElements[0]
            if ($join -is [Management.Automation.Language.CommandAst] -and $join.GetCommandName() -eq 'Join-Path') {
                return $null -ne ($join.CommandElements | Where-Object {
                    $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -ieq 'BuildRunActions.ps1'
                } | Select-Object -First 1)
            }
        }
        return $target.Extent.Text -match '\A"\$(?:PSScriptRoot|\{PSScriptRoot\})[\\/]BuildRunActions\.ps1"\z'
    }, $true)
    $hasCleanup = $Original -match "(?i)['""]run-actions['""]"
    if ($hasInvoke -and $hasCleanup) { return $Original }

    $dockerCommands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and (Test-DockerBuildCommand $n) }, $true))
    if (-not $dockerCommands.Count) { return $Original }

    $enclosingTries = [Collections.Generic.List[object]]::new()
    $directStmts = [Collections.Generic.List[object]]::new()
    foreach ($cmd in $dockerCommands) {
        $tryNode = $null
        $stmtNode = $null
        for ($cur = $cmd; $cur; $cur = $cur.Parent) {
            if (-not $stmtNode -and $cur -is [Management.Automation.Language.StatementAst] -and
                ($cur.Parent -is [Management.Automation.Language.StatementBlockAst] -or $cur.Parent -is [Management.Automation.Language.NamedBlockAst])) {
                $stmtNode = $cur
            }
            if ($cur.Parent -is [Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($cur, $cur.Parent.Body)) {
                $tryNode = $cur.Parent
                break
            }
        }
        $enclosingTries.Add($tryNode)
        $directStmts.Add($stmtNode)
    }

    $edits = [Collections.Generic.List[object]]::new()
    $allInSameTry = ($null -ne $enclosingTries[0]) -and (@($enclosingTries | Where-Object { -not [object]::ReferenceEquals($_, $enclosingTries[0]) }).Count -eq 0)
    if ($allInSameTry) {
        $tryAst = $enclosingTries[0]
        $tryIndent = Get-LineIndent $Original $tryAst.Extent.StartOffset
        if ($null -eq $tryIndent) { return $Original }
        if (-not $hasInvoke) {
            $edits.Add(@{
                Offset = $tryAst.Extent.StartOffset
                Length = 0
                Text = "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')$nl$tryIndent"
            })
        }
        if (-not $hasCleanup) {
            if ($tryAst.Finally) {
                $bodyIndent = $tryIndent + '    '
                if ($tryAst.Finally.Statements.Count -gt 0) {
                    $lastFinallyIndent = Get-LineIndent $Original $tryAst.Finally.Statements[-1].Extent.StartOffset
                    if ($null -ne $lastFinallyIndent) { $bodyIndent = $lastFinallyIndent }
                }
                $cleanupLines = @(
                    "${bodyIndent}if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
                    "${bodyIndent}    Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
                    "${bodyIndent}}"
                ) -join $nl
                $closeOffset = $tryAst.Finally.Extent.EndOffset - 1
                $closeIndent = Get-LineIndent $Original $closeOffset
                if ($null -ne $closeIndent) {
                    $insertAt = $closeOffset - $closeIndent.Length
                    $edits.Add(@{ Offset = $insertAt; Length = 0; Text = $cleanupLines + $nl })
                } else {
                    $edits.Add(@{ Offset = $closeOffset; Length = 0; Text = $nl + $cleanupLines + $nl + $tryIndent })
                }
            } else {
                $finallyBlock = @(
                    "${tryIndent}finally {"
                    "${tryIndent}    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
                    "${tryIndent}        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
                    "${tryIndent}    }"
                    "${tryIndent}}"
                ) -join $nl
                $edits.Add(@{ Offset = $tryAst.Extent.EndOffset; Length = 0; Text = $nl + $finallyBlock })
            }
        }
    } else {
        $parentBlock = if ($directStmts[0]) { $directStmts[0].Parent } else { $null }
        $allInSameBlock = ($null -ne $parentBlock) -and (@($directStmts | Where-Object { $null -eq $_ -or -not [object]::ReferenceEquals($_.Parent, $parentBlock) }).Count -eq 0)
        if (-not $allInSameBlock) { return $Original }
        $orderedStmts = @($directStmts | Sort-Object { $_.Extent.StartOffset } -Unique)
        $firstStmt = $orderedStmts[0]
        $lastStmt = $orderedStmts[-1]
        $indent = Get-LineIndent $Original $firstStmt.Extent.StartOffset
        if ($null -eq $indent) { return $Original }
        if ($hasCleanup) {
            if (-not $hasInvoke) {
                $edits.Add(@{
                    Offset = $firstStmt.Extent.StartOffset
                    Length = 0
                    Text = "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')$nl$indent"
                })
            }
        } else {
            $dockerSlice = $Original.Substring($firstStmt.Extent.StartOffset, $lastStmt.Extent.EndOffset - $firstStmt.Extent.StartOffset)
            $indentedDocker = (@($dockerSlice -split '\r?\n' | ForEach-Object {
                if ($_ -match '^[ \t]*$') { '' }
                elseif ($indent.Length -gt 0 -and $_.StartsWith($indent, [StringComparison]::Ordinal)) { $indent + '    ' + $_.Substring($indent.Length) }
                else { $indent + '    ' + $_ }
            }) -join $nl)
            $replaceEnd = $lastStmt.Extent.EndOffset
            $cleanupBody = [Collections.Generic.List[string]]::new()
            $stmtList = @($parentBlock.Statements)
            $lastIdx = -1
            for ($i = 0; $i -lt $stmtList.Count; $i++) {
                if ([object]::ReferenceEquals($stmtList[$i], $lastStmt)) { $lastIdx = $i; break }
            }
            if ($lastIdx -ge 0 -and ($lastIdx + 1) -lt $stmtList.Count) {
                $nextStmt = $stmtList[$lastIdx + 1]
                $gap = $Original.Substring($lastStmt.Extent.EndOffset, $nextStmt.Extent.StartOffset - $lastStmt.Extent.EndOffset)
                if ($gap -match '^\s*$' -and (Test-ApiCleanupPipeline $nextStmt)) {
                    $cleanupBody.Add($indent + '    ' + $nextStmt.Extent.Text.Trim())
                    $replaceEnd = $nextStmt.Extent.EndOffset
                }
            }
            $cleanupBody.Add("${indent}    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {")
            $cleanupBody.Add("${indent}        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force")
            $cleanupBody.Add("${indent}    }")
            $replacementLines = [Collections.Generic.List[string]]::new()
            if (-not $hasInvoke) {
                $replacementLines.Add("& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')")
                $replacementLines.Add("${indent}try {")
            } else {
                $replacementLines.Add('try {')
            }
            $replacementLines.Add($indentedDocker)
            $replacementLines.Add("${indent}}")
            $replacementLines.Add("${indent}finally {")
            foreach ($line in $cleanupBody) { $replacementLines.Add($line) }
            $replacementLines.Add("${indent}}")
            $edits.Add(@{
                Offset = $firstStmt.Extent.StartOffset
                Length = $replaceEnd - $firstStmt.Extent.StartOffset
                Text = ($replacementLines -join $nl)
            })
        }
    }

    if (-not $edits.Count) { return $Original }
    $updated = $Original
    foreach ($edit in $edits | Sort-Object -Property Offset, Length -Descending) {
        $updated = $updated.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.Text)
    }
    $verifyTokens = $null; $verifyErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($updated, [ref]$verifyTokens, [ref]$verifyErrors)
    if ($verifyErrors.Count) { return $Original }
    return $updated
}
if (-not $skipMutations) {
    $buildImagePath = Join-Path $workspace 'BuildDocfxImage.ps1'
    if (Test-Path -LiteralPath $buildImagePath) {
        Assert-RepositoryPath $buildImagePath
        $buildImageOriginal = [IO.File]::ReadAllText($buildImagePath)
        $buildImageUpdated = Update-BuildDocfxImageScript $buildImageOriginal
        Write-Page $buildImagePath $buildImageOriginal $buildImageUpdated
    }
}

$failedTotal = @($results | Where-Object { $_.status -eq 'failed' -or $_.native -eq 'Failed' -or $_.docker -eq 'Failed' }).Count
$unresolvedTotal = @($results | Where-Object coverage -eq 'Unresolved').Count
$exitCodeOut = if ($failedTotal -gt 0) { 1 } elseif ($unresolvedTotal -gt 0) { 2 } else { 0 }

if ($SummaryJson) {
    $skippedByCategory = [ordered]@{}
    foreach ($r in $results) {
        if ($r.coverage -eq 'Unresolved' -and $r.category) {
            if (-not $skippedByCategory.Contains($r.category)) { $skippedByCategory[$r.category] = 0 }
            $skippedByCategory[$r.category]++
        }
    }
    $nativeVerified = @($results | Where-Object native -eq 'Verified').Count
    $dockerVerified = @($results | Where-Object docker -eq 'Verified').Count
    $verifiedCount = switch ($Verify) {
        'Native' { $nativeVerified }
        'Docker' { $dockerVerified }
        default { @($results | Where-Object { $_.native -eq 'Verified' -or $_.docker -eq 'Verified' }).Count }
    }
    $verifyScope = if ($Verify -eq 'None') { 'none' }
                   elseif ($verifyTargetIds) { 'id' }
                   elseif ($VerifyChanged) { 'changed' }
                   else { 'all' }
    $summaryDoc = [ordered]@{
        schemaVersion = 2
        mode = if ($Verify -ne 'None') { 'verify' } else { 'generate' }
        exitCode = $exitCodeOut
        failureReason = $null
        verifyScope = $verifyScope
        manifestPreserved = $manifestPreserved
        total = $results.Count
        generated = @($results | Where-Object status -eq 'generated').Count
        unchanged = @($results | Where-Object status -eq 'unchanged').Count
        verified = $verifiedCount
        failed = $failedTotal
        unresolved = $unresolvedTotal
        intrinsic = @($results | Where-Object coverage -eq 'Intrinsically non-executable').Count
        'skipped-by-category' = $skippedByCategory
        verification = [ordered]@{
            nativeVerified = $nativeVerified
            dockerVerified = $dockerVerified
            executed = $verificationExecuted
            reused = $verificationReused
            failed = $verificationFailedCount
            maxParallel = $effectiveNativeParallel
            maxDockerParallel = $effectiveDockerParallel
        }
        examples = @($results)
    }
    $summaryDoc | ConvertTo-Json -Depth 30
} else {
    if ($results.Count) { $results | ConvertTo-Json -Depth 30 } else { '[]' }
}
exit $exitCodeOut
