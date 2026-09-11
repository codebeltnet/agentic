[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Package,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

function Get-NodeVersion {
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node)

    if ($Node.Attributes['Version']) {
        return [string]$Node.Attributes['Version'].Value
    }
    if ($Node.Attributes['VersionOverride']) {
        return [string]$Node.Attributes['VersionOverride'].Value
    }

    $versionNode = $Node.SelectSingleNode('./Version')
    if ($versionNode) {
        return [string]$versionNode.InnerText
    }
    $overrideNode = $Node.SelectSingleNode('./VersionOverride')
    if ($overrideNode) {
        return [string]$overrideNode.InnerText
    }

    return $null
}

$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$file = Join-Path $repoPath 'Directory.Packages.props'
if (-not (Test-Path -LiteralPath $file)) {
    $missing = [pscustomobject]@{ repoRoot = $repoPath; found = $false }
    if ($AsJson) { $missing | ConvertTo-Json -Depth 8 } else { $missing }
    return
}

[xml]$xml = Read-TextWithEncoding -Path $file
$groups = [System.Collections.Generic.List[object]]::new()
$packages = [System.Collections.Generic.List[object]]::new()
$centrallyManaged = $null

foreach ($propertyGroup in @($xml.SelectNodes('/Project/PropertyGroup'))) {
    foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
        if ($node.Name -eq 'ManagePackageVersionsCentrally') {
            $centrallyManaged = [string]$node.InnerText
        }
    }
}

foreach ($itemGroup in @($xml.SelectNodes('/Project/ItemGroup'))) {
    $groupCondition = if ($itemGroup.Attributes['Condition']) { [string]$itemGroup.Attributes['Condition'].Value } else { $null }
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($node in @($itemGroup.ChildNodes)) {
        if ($node.NodeType -ne 'Element') { continue }
        if ($node.Name -notin @('PackageVersion', 'PackageReference', 'GlobalPackageReference')) { continue }

        $id = if ($node.Attributes['Include']) { [string]$node.Attributes['Include'].Value } else { $null }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $nodeCondition = if ($node.Attributes['Condition']) { [string]$node.Attributes['Condition'].Value } else { $null }
        $entry = [pscustomobject]@{
            id        = $id
            version   = Get-NodeVersion -Node $node
            element   = $node.Name
            condition = if ($nodeCondition) { $nodeCondition } else { $groupCondition }
            note      = Get-AdjacentXmlComment -Node $node
        }
        $items.Add($entry)
        $packages.Add($entry)
    }

    $groups.Add([pscustomobject]@{
        condition = $groupCondition
        count     = $items.Count
        packages  = @($items)
    })
}

if ($Package) {
    $filteredGroups = [System.Collections.Generic.List[object]]::new()
    $filteredPackages = @($packages | Where-Object { $_.id -eq $Package })
    foreach ($group in @($groups)) {
        $matches = @($group.packages | Where-Object { $_.id -eq $Package })
        if ($matches.Count -gt 0) {
            $filteredGroups.Add([pscustomobject]@{
                condition = $group.condition
                count     = $matches.Count
                packages  = $matches
            })
        }
    }
    $groups = $filteredGroups
    $packages = [System.Collections.Generic.List[object]]::new()
    foreach ($packageEntry in $filteredPackages) { $packages.Add($packageEntry) }
}

$result = [pscustomobject]@{
    repoRoot                       = $repoPath
    file                           = $file
    found                          = $true
    managePackageVersionsCentrally = $centrallyManaged
    conditions                     = @($groups | Where-Object { $_.condition } | ForEach-Object { $_.condition } | Sort-Object -Unique)
    groupCount                     = $groups.Count
    packageCount                   = $packages.Count
    groups                         = @($groups)
    packages                       = @($packages)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
} else {
    $result
}
