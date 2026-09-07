[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    [xml]$xml = Get-Content -Raw -LiteralPath $Path
    foreach ($propertyGroup in @($xml.Project.PropertyGroup)) {
        foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
            if (-not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                $map[$node.Name] = [string]$node.InnerText
            }
        }
    }

    return $map
}

function Resolve-PropertyTokens {
    param(
        [string]$Value,
        [hashtable]$Map,
        [int]$Depth = 0
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Depth -ge 10) {
        return $Value
    }

    $resolved = [regex]::Replace($Value, '\$\(([A-Za-z0-9_]+)\)', {
        param($match)
        $name = $match.Groups[1].Value
        if ($Map.ContainsKey($name)) {
            return [string]$Map[$name]
        }
        return $match.Value
    })

    if ($resolved -ne $Value -and $resolved -match '\$\(') {
        return Resolve-PropertyTokens -Value $resolved -Map $Map -Depth ($Depth + 1)
    }

    return $resolved
}

function Split-Tfms {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$directoryBuildProps = Join-Path $repoPath 'Directory.Build.props'
$propertyMap = Get-PropertyMap -Path $directoryBuildProps
$declaredIn = [System.Collections.Generic.List[object]]::new()
$allTfms = [System.Collections.Generic.List[string]]::new()
$unresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

if (Test-Path -LiteralPath $directoryBuildProps) {
    [xml]$propsXml = Get-Content -Raw -LiteralPath $directoryBuildProps
    foreach ($propertyGroup in @($propsXml.Project.PropertyGroup)) {
        $condition = if ($propertyGroup.Attributes['Condition']) { [string]$propertyGroup.Attributes['Condition'].Value } else { $null }
        foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -in @('TargetFramework', 'TargetFrameworks') })) {
            $raw = [string]$node.InnerText
            $resolved = Resolve-PropertyTokens -Value $raw -Map $propertyMap
            $tfms = Split-Tfms -Value $resolved
            foreach ($tfm in $tfms) {
                if ($tfm -match '\$\(') { $null = $unresolved.Add($tfm) } else { $allTfms.Add($tfm) }
            }
            $declaredIn.Add([pscustomobject]@{
                scope            = 'Directory.Build.props'
                path             = 'Directory.Build.props'
                property         = $node.Name
                condition        = $condition
                rawValue         = $raw
                resolvedValue    = $resolved
                targetFrameworks = $tfms
            })
        }
    }
}

$projects = [System.Collections.Generic.List[object]]::new()
$projectFiles = Get-ChildItem -LiteralPath $repoPath -Recurse -Filter *.csproj -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

foreach ($projectFile in $projectFiles) {
    [xml]$projectXml = Get-Content -Raw -LiteralPath $projectFile.FullName
    $projectTfms = [System.Collections.Generic.List[string]]::new()
    $projectUnresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($propertyGroup in @($projectXml.Project.PropertyGroup)) {
        $condition = if ($propertyGroup.Attributes['Condition']) { [string]$propertyGroup.Attributes['Condition'].Value } else { $null }
        foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -in @('TargetFramework', 'TargetFrameworks') })) {
            $raw = [string]$node.InnerText
            $resolved = Resolve-PropertyTokens -Value $raw -Map $propertyMap
            $tfms = Split-Tfms -Value $resolved
            foreach ($tfm in $tfms) {
                if ($tfm -match '\$\(') {
                    $null = $projectUnresolved.Add($tfm)
                    $null = $unresolved.Add($tfm)
                } else {
                    $projectTfms.Add($tfm)
                    $allTfms.Add($tfm)
                }
            }
            $declaredIn.Add([pscustomobject]@{
                scope            = 'Project'
                path             = [System.IO.Path]::GetRelativePath($repoPath, $projectFile.FullName)
                property         = $node.Name
                condition        = $condition
                rawValue         = $raw
                resolvedValue    = $resolved
                targetFrameworks = $tfms
            })
        }
    }

    $projects.Add([pscustomobject]@{
        path             = [System.IO.Path]::GetRelativePath($repoPath, $projectFile.FullName)
        targetFrameworks = @($projectTfms | Sort-Object -Unique)
        unresolvedTokens = @($projectUnresolved | Sort-Object)
    })
}

$result = [pscustomobject]@{
    repoRoot         = $repoPath
    targetFrameworks = @($allTfms | Sort-Object -Unique)
    unresolvedTokens = @($unresolved | Sort-Object)
    declaredIn       = @($declaredIn)
    projects         = @($projects)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
} else {
    $result
}
