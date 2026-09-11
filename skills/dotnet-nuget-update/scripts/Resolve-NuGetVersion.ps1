[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Id,
    [switch]$IncludePrerelease,
    [string[]]$Source = @('https://api.nuget.org/v3-flatcontainer'),
    [ValidateRange(1, 32)][int]$MaxConcurrency = 8,
    [ValidateRange(1, 300)][int]$TimeoutSec = 15,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$feed = Get-NuGetVersionListMerged -Id $Id -Sources $Source -MaxConcurrency $MaxConcurrency -TimeoutSec $TimeoutSec
if (-not $feed.found) {
    $missing = [pscustomobject]@{
        id       = $Id
        found    = $false
        error    = $feed.error
        source   = $feed.source
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
    source       = $feed.source
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
