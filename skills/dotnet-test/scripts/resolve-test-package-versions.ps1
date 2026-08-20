param(
    [Parameter(Mandatory = $true)]
    [string[]]$TargetFramework,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Unit', 'WebFunctional', 'ApplicationFunctional')]
    [string]$Role,

    [string[]]$PackageId,

    [string]$XunitAnchorPackageId,

    [string]$XunitAnchorVersion,

    [int]$MaximumCandidates,

    [string]$CacheDirectory = $env:DOTNET_TEST_RESOLVER_CACHE_DIR,

    [string]$TraceFile = $env:DOTNET_TEST_RESOLVER_TRACE_FILE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

if (-not $PSBoundParameters.ContainsKey('MaximumCandidates')) {
    if (-not [string]::IsNullOrWhiteSpace($env:DOTNET_TEST_MAXIMUM_CANDIDATES)) {
        try {
            $MaximumCandidates = [int]$env:DOTNET_TEST_MAXIMUM_CANDIDATES
        } catch {
            throw "DOTNET_TEST_MAXIMUM_CANDIDATES must be an integer. Found '$($env:DOTNET_TEST_MAXIMUM_CANDIDATES)'."
        }
    } else {
        $MaximumCandidates = 30
    }
}

if ($MaximumCandidates -lt 1 -or $MaximumCandidates -gt 100) {
    throw "MaximumCandidates must be between 1 and 100. Found '$MaximumCandidates'."
}

# xUnit versions its packages independently of this skill: xunit.v3 4.0.0 and xunit.runner.visualstudio 4.0.0 are stable
# on NuGet while Codebelt.Extensions.Xunit still builds against 3.2.2. "Newest stable" would therefore drag a test project
# a whole xUnit generation past the Codebelt API it is meant to use, so every id matching this pattern is anchored to the
# Codebelt package instead of resolved freely.
$xunitPackagePattern = '^xunit(\.|$)'
$stableVersionPattern = '^\d+(?:\.\d+){1,3}$'

function Get-ResolverCacheKey {
    param(
        [Parameter(Mandatory = $true)] [string]$RoleName,
        [Parameter(Mandatory = $true)] [string[]]$Frameworks,
        [Parameter(Mandatory = $true)] [string[]]$Packages,
        [Parameter(Mandatory = $true)] [int]$CandidateLimit,
        [string]$Anchor
    )

    $seed = [ordered]@{
        role = $RoleName
        targetFrameworks = @($Frameworks | Sort-Object)
        packageIds = @($Packages | Sort-Object)
        maximumCandidates = $CandidateLimit
        xunitAnchor = [string]$Anchor
    } | ConvertTo-Json -Compress
    return [System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::HashData($utf8NoBom.GetBytes($seed)))).Replace('-', '').ToLowerInvariant()
}

function Write-ResolverTrace {
    param(
        [string]$TraceFilePath,
        [string]$RoleName,
        [string[]]$Frameworks,
        [string[]]$Packages,
        [int]$CandidateLimit,
        [bool]$CacheHit,
        [double]$DurationSeconds,
        [string]$Anchor
    )

    if ([string]::IsNullOrWhiteSpace($TraceFilePath)) { return }
    $directory = Split-Path -Path $TraceFilePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    ([ordered]@{
        role = $RoleName
        targetFrameworks = @($Frameworks)
        packageIds = @($Packages)
        maximumCandidates = $CandidateLimit
        xunitAnchor = [string]$Anchor
        cacheHit = $CacheHit
        durationSeconds = [math]::Round($DurationSeconds, 3)
        timestamp = [DateTimeOffset]::UtcNow.ToString('O')
    } | ConvertTo-Json -Compress) + [Environment]::NewLine | Add-Content -LiteralPath $TraceFilePath -Encoding utf8
}

function Get-VersionKey {
    param([string]$Version)
    $parts = $Version.Split('.')
    return [pscustomobject]@{
        major = if ($parts.Count -gt 0) { [int]$parts[0] } else { 0 }
        minor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
        patch = if ($parts.Count -gt 2) { [int]$parts[2] } else { 0 }
        revision = if ($parts.Count -gt 3) { [int]$parts[3] } else { 0 }
        text = $Version
    }
}

function Compare-VersionText {
    param([string]$Left, [string]$Right)

    $leftKey = Get-VersionKey -Version $Left
    $rightKey = Get-VersionKey -Version $Right
    foreach ($part in @('major', 'minor', 'patch', 'revision')) {
        $leftPart = [int]$leftKey.$part
        $rightPart = [int]$rightKey.$part
        if ($leftPart -ne $rightPart) { return $leftPart.CompareTo($rightPart) }
    }
    return 0
}

function Get-PackageBaseAddress {
    $serviceIndex = Invoke-RestMethod -Uri 'https://api.nuget.org/v3/index.json'
    $address = $serviceIndex.resources |
        Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' } |
        Select-Object -First 1 -ExpandProperty '@id'
    if ([string]::IsNullOrWhiteSpace($address)) { throw 'NuGet service index did not expose PackageBaseAddress/3.0.0.' }
    return $address
}

function Get-StableVersion {
    param([string]$BaseAddress, [string]$PackageId)

    $indexUrl = '{0}{1}/index.json' -f $BaseAddress, $PackageId.ToLowerInvariant()
    try { $index = Invoke-RestMethod -Uri $indexUrl } catch { throw "NuGet lookup failed for '$PackageId' at '$indexUrl': $($_.Exception.Message)" }
    $versions = @($index.versions |
        Where-Object { $_ -match $stableVersionPattern } |
        ForEach-Object { Get-VersionKey -Version $_ } |
        Sort-Object major, minor, patch, revision -Descending)
    return [pscustomobject]@{ source = $indexUrl; versions = $versions }
}

function Resolve-XunitAnchor {
    param([string]$BaseAddress, [string]$PackageId, [string]$Version)

    $anchorVersion = $Version
    if ([string]::IsNullOrWhiteSpace($anchorVersion)) {
        $index = Get-StableVersion -BaseAddress $BaseAddress -PackageId $PackageId
        if (@($index.versions).Count -eq 0) { throw "NuGet returned no stable versions for the xUnit anchor package '$PackageId'." }
        $anchorVersion = @($index.versions)[0].text
    }
    if ($anchorVersion -notmatch $stableVersionPattern) {
        throw "XunitAnchorVersion must be a stable version such as '11.2.1'. Found '$anchorVersion'."
    }

    $nuspecUrl = '{0}{1}/{2}/{1}.nuspec' -f $BaseAddress, $PackageId.ToLowerInvariant(), $anchorVersion.ToLowerInvariant()
    try { $nuspec = Invoke-RestMethod -Uri $nuspecUrl } catch { throw "NuGet nuspec lookup failed for '$PackageId' $anchorVersion at '$nuspecUrl': $($_.Exception.Message)" }

    $pins = [ordered]@{}
    foreach ($node in @($nuspec.GetElementsByTagName('dependency'))) {
        $dependencyId = [string]$node.GetAttribute('id')
        if ($dependencyId -notmatch $xunitPackagePattern) { continue }
        $declared = (([string]$node.GetAttribute('version')).Trim('[', ']', '(', ')', ' ') -split ',')[0].Trim()
        if ($declared -notmatch $stableVersionPattern) { continue }
        $key = $dependencyId.ToLowerInvariant()
        if ($pins.Contains($key) -and (Compare-VersionText -Left ([string]$pins[$key]) -Right $declared) -ge 0) { continue }
        $pins[$key] = $declared
    }
    if ($pins.Count -eq 0) {
        throw "'$PackageId' $anchorVersion declares no stable xunit* dependency, so the xUnit ceiling cannot be anchored to it. Pass -XunitAnchorPackageId with a Codebelt xUnit package that does."
    }

    $major = @(@($pins.Values) | ForEach-Object { [int]((Get-VersionKey -Version ([string]$_)).major) } | Sort-Object -Descending)[0]
    return [pscustomobject]@{
        packageId = $PackageId
        version = $anchorVersion
        major = $major
        source = $nuspecUrl
        pins = $pins
    }
}

function Select-AnchoredCandidate {
    param([string]$PackageId, [object[]]$Candidates, [object]$Anchor)

    if ($null -eq $Anchor -or $PackageId -notmatch $xunitPackagePattern) { return @($Candidates) }

    $allowed = @(@($Candidates) | Where-Object { [int]($_.major) -le [int]($Anchor.major) })
    if ($allowed.Count -eq 0) {
        throw "No stable '$PackageId' version at or below major $($Anchor.major) exists. That ceiling comes from $($Anchor.packageId) $($Anchor.version); raise the anchor package before raising the xUnit generation."
    }

    $key = $PackageId.ToLowerInvariant()
    if ($Anchor.pins.Contains($key)) {
        $pinned = [string]$Anchor.pins[$key]
        $exact = @($allowed | Where-Object { $_.text -eq $pinned })
        if ($exact.Count -gt 0) {
            $allowed = @($exact) + @($allowed | Where-Object { $_.text -ne $pinned })
        }
    }
    return @($allowed)
}

function Get-AnchorConstraint {
    param([string]$PackageId, [string]$Version, [object]$Anchor)

    if ($null -eq $Anchor -or $PackageId -notmatch $xunitPackagePattern) { return 'unanchored' }

    $key = $PackageId.ToLowerInvariant()
    if (-not $Anchor.pins.Contains($key)) {
        return "capped at major $($Anchor.major) by $($Anchor.packageId) $($Anchor.version)"
    }
    $pinned = [string]$Anchor.pins[$key]
    if ($pinned -eq $Version) {
        return "matched 1:1 to the $pinned dependency declared by $($Anchor.packageId) $($Anchor.version)"
    }
    return "capped at major $($Anchor.major) by $($Anchor.packageId) $($Anchor.version) which declares $pinned"
}

function Test-PackageCompatibility {
    param([object[]]$Packages, [string[]]$Frameworks, [string]$Workspace)

    $projectPath = Join-Path $Workspace 'compatibility.csproj'
    $frameworkElement = if ($Frameworks.Count -eq 1) {
        "<TargetFramework>$($Frameworks[0])</TargetFramework>"
    } else {
        "<TargetFrameworks>$($Frameworks -join ';')</TargetFrameworks>"
    }
    $packageReferences = @(
        foreach ($package in @($Packages)) {
            '    <PackageReference Include="{0}" Version="{1}" />' -f $package.packageId, $package.version
        }
    ) -join [Environment]::NewLine
    $xml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    $frameworkElement
    <RestorePackagesPath>$(Join-Path $Workspace 'packages')</RestorePackagesPath>
  </PropertyGroup>
  <ItemGroup>
$packageReferences
  </ItemGroup>
</Project>
"@
    [System.IO.File]::WriteAllText($projectPath, $xml, $utf8NoBom)
    $output = @(& dotnet restore $projectPath --nologo --verbosity quiet --force-evaluate 2>&1)
    return [pscustomobject]@{
        compatible = $LASTEXITCODE -eq 0
        output = ($output -join [Environment]::NewLine)
    }
}

foreach ($framework in $TargetFramework) {
    if ($framework -notmatch '^net(?:standard)?\d+(?:\.\d+)+$|^net\d{2,3}$') {
        throw "Unsupported target framework syntax: '$framework'."
    }
}

$codebeltPackage = if ($Role -eq 'Unit') { 'Codebelt.Extensions.Xunit' } else { 'Codebelt.Extensions.Xunit.App' }
$packageIds = if ($PackageId -and $PackageId.Count -gt 0) {
    @($PackageId)
} else {
    @('Microsoft.NET.Test.Sdk', 'xunit.v3', 'xunit.v3.runner.console', 'xunit.runner.visualstudio', $codebeltPackage)
}

$anchorPackageId = if ([string]::IsNullOrWhiteSpace($XunitAnchorPackageId)) { $codebeltPackage } else { $XunitAnchorPackageId }
$anchoredPackageIds = @($packageIds | Where-Object { $_ -match $xunitPackagePattern })
$flatContainerAddress = $null
$anchor = $null
if ($anchoredPackageIds.Count -gt 0) {
    $flatContainerAddress = Get-PackageBaseAddress
    $anchor = Resolve-XunitAnchor -BaseAddress $flatContainerAddress -PackageId $anchorPackageId -Version $XunitAnchorVersion
}
$anchorKey = if ($null -eq $anchor) { '' } else { '{0}/{1}' -f $anchor.packageId, $anchor.version }

$cacheKey = if ([string]::IsNullOrWhiteSpace($CacheDirectory)) { $null } else { Get-ResolverCacheKey -RoleName $Role -Frameworks $TargetFramework -Packages $packageIds -CandidateLimit $MaximumCandidates -Anchor $anchorKey }
$cachePath = if ($null -eq $cacheKey) { $null } else { Join-Path $CacheDirectory ($cacheKey + '.json') }
$startedAt = [DateTimeOffset]::UtcNow

if ($null -ne $cachePath -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    $cached = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    $durationSeconds = [math]::Round(([DateTimeOffset]::UtcNow - $startedAt).TotalSeconds, 3)
    if ($null -eq $cached.cache) {
        $cached | Add-Member -NotePropertyName cache -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -eq $cached.timing) {
        $cached | Add-Member -NotePropertyName timing -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $cached.cache | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
    $cached.cache | Add-Member -NotePropertyName hit -NotePropertyValue $true -Force
    $cached.cache | Add-Member -NotePropertyName key -NotePropertyValue $cacheKey -Force
    $cached.timing | Add-Member -NotePropertyName durationSeconds -NotePropertyValue $durationSeconds -Force
    Write-ResolverTrace -TraceFilePath $TraceFile -RoleName $Role -Frameworks $TargetFramework -Packages $packageIds -CandidateLimit $MaximumCandidates -CacheHit $true -DurationSeconds $durationSeconds -Anchor $anchorKey
    $cached | ConvertTo-Json -Depth 8
    return
}

if ($null -eq $flatContainerAddress) { $flatContainerAddress = Get-PackageBaseAddress }

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-test-package-resolution-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null

try {
    $packageCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($id in @($packageIds | Sort-Object -Unique)) {
        $index = Get-StableVersion -BaseAddress $flatContainerAddress -PackageId $id
        if (@($index.versions).Count -eq 0) { throw "NuGet returned no stable versions for '$id'." }
        # Anchor first, trim second: a package whose newest candidates are all above the anchored major would otherwise
        # arrive here with nothing left to try.
        $candidates = @(Select-AnchoredCandidate -PackageId $id -Candidates @($index.versions) -Anchor $anchor |
            Select-Object -First $MaximumCandidates)
        $packageCandidates.Add([pscustomobject]@{ packageId = $id; source = $index.source; candidates = $candidates })
    }

    function Resolve-PackageSet {
        param([int]$Index, [object[]]$Selected)

        if ($Index -ge $packageCandidates.Count) {
            return [pscustomobject]@{
                compatible = $true
                packages = @($Selected)
            }
        }

        $package = $packageCandidates[$Index]
        $lastFailure = $null
        foreach ($candidate in @($package.candidates)) {
            $packageWorkspace = Join-Path $workspace ([System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $packageWorkspace -Force | Out-Null
            $selectedPackage = [pscustomobject]@{
                packageId = $package.packageId
                version = $candidate.text
                source = $package.source
            }
            $trial = @($Selected) + $selectedPackage
            $compatibility = Test-PackageCompatibility -Packages $trial -Frameworks $TargetFramework -Workspace $packageWorkspace
            if (-not $compatibility.compatible) {
                $lastFailure = $compatibility.output
                continue
            }

            $resolution = Resolve-PackageSet -Index ($Index + 1) -Selected $trial
            if ($resolution.compatible) {
                return $resolution
            }
            $lastFailure = $resolution.output
        }

        return [pscustomobject]@{
            compatible = $false
            packageId = $package.packageId
            candidateCount = @($package.candidates).Count
            output = $lastFailure
        }
    }

    $resolution = Resolve-PackageSet -Index 0 -Selected @()
    if (-not $resolution.compatible) {
        throw "No stable '$($resolution.packageId)' version among the newest $($resolution.candidateCount) candidates restored with a compatible package set for '$($TargetFramework -join ';')'. Last restore output:`n$($resolution.output)"
    }

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($package in @($resolution.packages)) {
        $resolved.Add([pscustomobject]@{
            packageId = $package.packageId
            version = $package.version
            source = $package.source
            compatibility = 'combined restore passed'
            constraint = Get-AnchorConstraint -PackageId $package.packageId -Version $package.version -Anchor $anchor
        })
    }

    $durationSeconds = [math]::Round(([DateTimeOffset]::UtcNow - $startedAt).TotalSeconds, 3)
    $result = [ordered]@{
        role = $Role
        targetFrameworks = @($TargetFramework)
        maximumCandidates = $MaximumCandidates
        xunitAnchor = if ($null -eq $anchor) { $null } else {
            [ordered]@{
                packageId = $anchor.packageId
                version = $anchor.version
                major = $anchor.major
                source = $anchor.source
                declaredDependencies = $anchor.pins
            }
        }
        cache = [ordered]@{
            enabled = $null -ne $cachePath
            hit = $false
            key = $cacheKey
        }
        timing = [ordered]@{
            durationSeconds = $durationSeconds
        }
        packages = @($resolved | Sort-Object packageId)
    }

    if ($null -ne $cachePath) {
        $directory = Split-Path -Path $cachePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cachePath -Encoding utf8
    }

    Write-ResolverTrace -TraceFilePath $TraceFile -RoleName $Role -Frameworks $TargetFramework -Packages $packageIds -CandidateLimit $MaximumCandidates -CacheHit $false -DurationSeconds $durationSeconds -Anchor $anchorKey
    $result | ConvertTo-Json -Depth 8
} finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force }
}
