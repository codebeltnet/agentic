[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Package,
    [switch]$IncludePrerelease,
    [switch]$OutdatedOnly,
    [string]$Source = 'https://api.nuget.org/v3-flatcontainer',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$autoClasses = @('revision', 'patch', 'minor', 'prerelease')
$approvalClasses = @('major')

function Get-NodeVersion {
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node)

    if ($Node.Attributes['Version']) {
        return [string]$Node.Attributes['Version'].Value
    }

    $versionNode = $Node.SelectSingleNode('./Version')
    if ($versionNode) {
        return [string]$versionNode.InnerText
    }

    return $null
}

function Get-CentralDeclarations {
    param([Parameter(Mandatory)][string]$Path, [string]$PackageFilter)

    [xml]$xml = Get-Content -Raw -LiteralPath $Path
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($itemGroup in @($xml.Project.ItemGroup)) {
        $condition = if ($itemGroup.Attributes['Condition']) { [string]$itemGroup.Attributes['Condition'].Value } else { $null }
        foreach ($node in @($itemGroup.ChildNodes)) {
            if ($node.NodeType -ne 'Element') { continue }
            if ($node.Name -ne 'PackageVersion') { continue }
            $id = if ($node.Attributes['Include']) { [string]$node.Attributes['Include'].Value } else { $null }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($PackageFilter -and $id -ne $PackageFilter) { continue }

            $rows.Add([pscustomobject]@{
                id         = $id
                current    = Get-NodeVersion -Node $node
                element    = $node.Name
                condition  = $condition
                note       = Get-AdjacentXmlComment -Node $node
                sourceFile = 'Directory.Packages.props'
            })
        }
    }

    return @($rows)
}

function Get-ProjectDeclarations {
    param([Parameter(Mandatory)][string]$Root, [string]$PackageFilter)

    $rows = [System.Collections.Generic.List[object]]::new()
    $projectFiles = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.csproj -File |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

    foreach ($projectFile in $projectFiles) {
        [xml]$xml = Get-Content -Raw -LiteralPath $projectFile.FullName
        foreach ($itemGroup in @($xml.Project.ItemGroup)) {
            $groupCondition = if ($itemGroup.Attributes['Condition']) { [string]$itemGroup.Attributes['Condition'].Value } else { $null }
            foreach ($node in @($itemGroup.ChildNodes)) {
                if ($node.NodeType -ne 'Element') { continue }
                if ($node.Name -notin @('PackageReference', 'GlobalPackageReference')) { continue }
                $id = if ($node.Attributes['Include']) { [string]$node.Attributes['Include'].Value } else { $null }
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                if ($PackageFilter -and $id -ne $PackageFilter) { continue }

                $current = Get-NodeVersion -Node $node
                if ([string]::IsNullOrWhiteSpace($current)) { continue }

                $nodeCondition = if ($node.Attributes['Condition']) { [string]$node.Attributes['Condition'].Value } else { $null }
                $rows.Add([pscustomobject]@{
                    id         = $id
                    current    = $current
                    element    = $node.Name
                    condition  = if ($nodeCondition) { $nodeCondition } else { $groupCondition }
                    note       = Get-AdjacentXmlComment -Node $node
                    sourceFile = [System.IO.Path]::GetRelativePath($Root, $projectFile.FullName)
                })
            }
        }
    }

    return @($rows)
}

function Resolve-Candidate {
    param(
        [Parameter(Mandatory)]$Declaration,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Versions,
        [bool]$AllowPrerelease
    )

    $pool = @(if ($AllowPrerelease) { $Versions } else { $Versions | Where-Object { -not (ConvertTo-NuGetSemVer -Version $_).isPrerelease } })
    $latestOverall = if ($pool.Count) { $pool[-1] } else { $null }
    $bandCandidates = @(Get-TfmBand -Condition $Declaration.condition)
    $pinnedMajor = if ($Declaration.current) { (ConvertTo-NuGetSemVer -Version $Declaration.current).major } else { $null }
    $band = $null

    if ($bandCandidates.Count -gt 0 -and $null -ne $pinnedMajor -and $bandCandidates -contains $pinnedMajor) {
        $band = $pinnedMajor
    }

    $allowed = @(if ($null -ne $band) { $pool | Where-Object { (ConvertTo-NuGetSemVer -Version $_).major -eq $band } } else { $pool })
    $candidate = if ($allowed.Count) { $allowed[-1] } else { $null }

    [pscustomobject]@{
        candidate     = $candidate
        latestOverall = $latestOverall
        band          = $band
        heldByBand    = ($null -ne $band -and $candidate -and $latestOverall -and (Compare-NuGetVersion -A $candidate -B $latestOverall) -lt 0)
    }
}

$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$centralPath = Join-Path $repoPath 'Directory.Packages.props'
$management = if (Test-Path -LiteralPath $centralPath) { 'central' } else { 'project' }
$declarations = if ($management -eq 'central') {
    Get-CentralDeclarations -Path $centralPath -PackageFilter $Package
} else {
    Get-ProjectDeclarations -Root $repoPath -PackageFilter $Package
}

if ($management -eq 'project' -and $declarations.Count -eq 0) {
    $missing = [pscustomobject]@{
        repoRoot   = $repoPath
        found      = $false
        management = 'project'
        declared   = 0
        summary    = [pscustomobject]@{ declared = 0; current = 0; auto = 0; approval = 0; unresolved = 0 }
        rows       = @()
    }
    if ($AsJson) { $missing | ConvertTo-Json -Depth 12 } else { $missing }
    return
}

if ($management -eq 'central' -and -not (Test-Path -LiteralPath $centralPath)) {
    $missing = [pscustomobject]@{
        repoRoot   = $repoPath
        found      = $false
        management = 'central'
        declared   = 0
        summary    = [pscustomobject]@{ declared = 0; current = 0; auto = 0; approval = 0; unresolved = 0 }
        rows       = @()
    }
    if ($AsJson) { $missing | ConvertTo-Json -Depth 12 } else { $missing }
    return
}

$rows = foreach ($declaration in $declarations) {
    $feed = Get-NuGetVersionList -Id $declaration.id -Source $Source
    if (-not $feed.found) {
        [pscustomobject]@{
            id            = $declaration.id
            current       = $declaration.current
            condition     = $declaration.condition
            sourceFile    = $declaration.sourceFile
            note          = $declaration.note
            candidate     = $null
            latestOverall = $null
            band          = $null
            heldByBand    = $false
            bump          = 'unknown'
            action        = 'unresolved'
            reason        = "not resolvable: $($feed.error)"
        }
        continue
    }

    $allowPrerelease = $IncludePrerelease -or ((ConvertTo-NuGetSemVer -Version $declaration.current).isPrerelease)
    $candidateResolution = Resolve-Candidate -Declaration $declaration -Versions $feed.versions -AllowPrerelease:$allowPrerelease

    if ([string]::IsNullOrWhiteSpace($declaration.current) -or [string]::IsNullOrWhiteSpace($candidateResolution.candidate)) {
        [pscustomobject]@{
            id            = $declaration.id
            current       = $declaration.current
            condition     = $declaration.condition
            sourceFile    = $declaration.sourceFile
            note          = $declaration.note
            candidate     = $candidateResolution.candidate
            latestOverall = $candidateResolution.latestOverall
            band          = $candidateResolution.band
            heldByBand    = $candidateResolution.heldByBand
            bump          = 'unknown'
            action        = 'unresolved'
            reason        = if ([string]::IsNullOrWhiteSpace($declaration.current)) { 'declaration has no explicit version' } else { 'no candidate available within the allowed set' }
        }
        continue
    }

    $bump = Get-NuGetVersionBump -From $declaration.current -To $candidateResolution.candidate
    $action = if ($bump -eq 'none') {
        'current'
    } elseif ($approvalClasses -contains $bump) {
        'approval'
    } elseif ($autoClasses -contains $bump) {
        'auto'
    } else {
        'approval'
    }

    $reason = if ($bump -eq 'none' -and $candidateResolution.heldByBand) {
        "newest within the net$($candidateResolution.band) band; $($candidateResolution.latestOverall) exists outside it"
    } elseif ($bump -eq 'none') {
        'already newest allowed'
    } elseif ($action -eq 'approval') {
        'major step - requires human approval before applying'
    } elseif ($candidateResolution.heldByBand) {
        "$bump step within the net$($candidateResolution.band) band; $($candidateResolution.latestOverall) exists outside it"
    } else {
        "$bump step"
    }

    if ($declaration.note -and $action -eq 'auto') {
        $reason = "$reason - READ THE NOTE before applying"
    }

    [pscustomobject]@{
        id            = $declaration.id
        current       = $declaration.current
        condition     = $declaration.condition
        sourceFile    = $declaration.sourceFile
        note          = $declaration.note
        candidate     = $candidateResolution.candidate
        latestOverall = $candidateResolution.latestOverall
        band          = $candidateResolution.band
        heldByBand    = $candidateResolution.heldByBand
        bump          = $bump
        action        = $action
        reason        = $reason
    }
}

$rows = @($rows)
$summary = [pscustomobject]@{
    declared   = $rows.Count
    current    = @($rows | Where-Object { $_.action -eq 'current' }).Count
    auto       = @($rows | Where-Object { $_.action -eq 'auto' }).Count
    approval   = @($rows | Where-Object { $_.action -eq 'approval' }).Count
    unresolved = @($rows | Where-Object { $_.action -eq 'unresolved' }).Count
}

$result = [pscustomobject]@{
    repoRoot   = $repoPath
    found      = $true
    management = $management
    declared   = $rows.Count
    summary    = $summary
    rows       = if ($OutdatedOnly) { @($rows | Where-Object { $_.action -ne 'current' }) } else { $rows }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
} else {
    $result
}
