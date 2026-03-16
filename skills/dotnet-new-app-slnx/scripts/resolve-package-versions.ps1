param(
    [string]$TemplatePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetFramework
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
    $scriptRoot = Split-Path -Path $PSCommandPath -Parent
    $TemplatePath = Join-Path $scriptRoot '..\assets\shared\Directory.Packages.props'
}

$TemplatePath = [System.IO.Path]::GetFullPath($TemplatePath)

function Get-VersionSortKey {
    param([string]$Version)

    $stable = $Version.Split('-', 2)[0]
    $parts = $stable.Split('.') | ForEach-Object { [int]$_ }
    while ($parts.Count -lt 4) {
        $parts += 0
    }

    return ,$parts
}

function Compare-VersionKeys {
    param(
        [int[]]$Left,
        [int[]]$Right
    )

    $max = [Math]::Max($Left.Count, $Right.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $Left.Count) { $Left[$i] } else { 0 }
        $r = if ($i -lt $Right.Count) { $Right[$i] } else { 0 }
        if ($l -ne $r) {
            return [Math]::Sign($l - $r)
        }
    }

    return 0
}

function Select-LatestStableVersion {
    param(
        [string[]]$Versions,
        [int]$RequiredMajor = -1
    )

    $stable = $Versions | Where-Object { $_ -notmatch '-' }
    if ($RequiredMajor -ge 0) {
        $stable = $stable | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -eq $RequiredMajor }
    }

    if (-not $stable) {
        throw "No stable versions matched RequiredMajor=$RequiredMajor."
    }

    $best = $null
    $bestKey = $null
    foreach ($version in $stable) {
        $key = Get-VersionSortKey -Version $version
        if ($null -eq $bestKey -or (Compare-VersionKeys -Left $key -Right $bestKey) -gt 0) {
            $best = $version
            $bestKey = $key
        }
    }

    return $best
}

if ($TargetFramework -notmatch '^net(\d+)\.0$') {
    throw "TargetFramework must look like net10.0. Received: $TargetFramework"
}

$targetMajor = [int]$Matches[1]
$frameworkAlignedPackages = @(
    'Microsoft.AspNetCore.OpenApi',
    'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'
)

[xml]$template = Get-Content -Path $TemplatePath -Raw
$packageNodes = @($template.Project.ItemGroup.PackageVersion)
if ($packageNodes.Count -eq 0) {
    throw "No PackageVersion entries found in $TemplatePath"
}

$serviceIndex = Invoke-RestMethod -Uri 'https://api.nuget.org/v3/index.json'
$packageBaseAddress = $serviceIndex.resources |
    Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' } |
    Select-Object -First 1 -ExpandProperty '@id'

if ([string]::IsNullOrWhiteSpace($packageBaseAddress)) {
    throw 'Could not locate PackageBaseAddress/3.0.0 in the NuGet service index.'
}

$result = [ordered]@{}
foreach ($node in $packageNodes) {
    $packageId = [string]$node.Include
    $placeholder = [string]$node.Version
    $indexUrl = '{0}{1}/index.json' -f $packageBaseAddress, $packageId.ToLowerInvariant()
    $index = Invoke-RestMethod -Uri $indexUrl
    if (-not $index.versions) {
        throw "No versions returned for $packageId from $indexUrl"
    }

    $requiredMajor = if ($frameworkAlignedPackages -contains $packageId) { $targetMajor } else { -1 }
    $resolved = Select-LatestStableVersion -Versions $index.versions -RequiredMajor $requiredMajor

    $result[$placeholder] = [ordered]@{
        package_id = $packageId
        version = $resolved
    }
}

$result | ConvertTo-Json -Depth 4
