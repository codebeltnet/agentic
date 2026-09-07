[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Id,
    [switch]$IncludePrerelease,
    [string]$Source = 'https://api.nuget.org/v3-flatcontainer',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$feed = Get-NuGetVersionList -Id $Id -Source $Source
if (-not $feed.found) {
    $missing = [pscustomobject]@{
        id       = $Id
        found    = $false
        error    = $feed.error
        source   = $Source
        versions = @()
    }
    if ($AsJson) { $missing | ConvertTo-Json -Depth 8 } else { $missing }
    return
}

$versions = @($feed.versions)
$stable = @($versions | Where-Object { -not (ConvertTo-NuGetSemVer -Version $_).isPrerelease })
$result = [pscustomobject]@{
    id           = $Id
    found        = $true
    source       = $Source
    count        = $versions.Count
    latest       = if ($IncludePrerelease) { if ($versions.Count) { $versions[-1] } else { $null } } else { if ($stable.Count) { $stable[-1] } else { $null } }
    latestStable = if ($stable.Count) { $stable[-1] } else { $null }
    latestAny    = if ($versions.Count) { $versions[-1] } else { $null }
    versions     = $versions
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result
}
