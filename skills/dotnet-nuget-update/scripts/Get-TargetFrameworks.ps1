[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

function Get-PropertyMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    $raw = Read-TextWithEncoding -Path $Path
    [xml]$xml = $raw
    foreach ($propertyGroup in @($xml.SelectNodes('/Project/PropertyGroup'))) {
        foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
            if (-not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                $map[$node.Name] = [string]$node.InnerText
            }
        }
    }

    return $map
}

function Get-ImportPaths {
    param([string]$Path)

    $imports = @()
    if (-not (Test-Path -LiteralPath $Path)) { return @($imports) }
    try {
        $raw = Read-TextWithEncoding -Path $Path
        [xml]$xml = $raw
        foreach ($import in @($xml.SelectNodes('/Project/Import'))) {
            if ($import.Attributes['Project']) {
                $imports += [string]$import.Attributes['Project'].Value
            }
        }
    }
    catch {
    }
    return @($imports)
}

function Resolve-ImportPath {
    param([Parameter(Mandatory)][string]$FromFile, [Parameter(Mandatory)][string]$ImportProject, [Parameter(Mandatory)][string]$RepoRoot)

    $candidate = $ImportProject.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    if ($candidate -match '^\$\(') { return $null }
    $candidate = $candidate -replace '\$\(MSBuildThisFileDirectory\)', ((Split-Path -Parent $FromFile) + [System.IO.Path]::DirectorySeparatorChar)
    $candidate = $candidate -replace '\$\(MSBuildProjectDirectory\)', ((Split-Path -Parent $FromFile) + [System.IO.Path]::DirectorySeparatorChar)
    try {
        $baseDir = Split-Path -Parent $FromFile
        $combined = if ([System.IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $baseDir $candidate }
        $full = [System.IO.Path]::GetFullPath($combined)
        if ($full.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
            return $full
        }
    }
    catch {
    }
    return $null
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
$propsFiles = @(Get-ChildItem -LiteralPath $repoPath -Recurse -File |
    Where-Object { $_.Extension -in @('.props', '.targets') -and $_.FullName -notmatch '\\(bin|obj)\\' } |
    Sort-Object FullName)
$projectFiles = @(Get-ChildItem -LiteralPath $repoPath -Recurse -Filter *.csproj -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
    Sort-Object FullName)

$importedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($propsFile in $propsFiles) {
    foreach ($importProject in @(Get-ImportPaths -Path $propsFile.FullName)) {
        $resolved = Resolve-ImportPath -FromFile $propsFile.FullName -ImportProject $importProject -RepoRoot $repoPath
        if ($resolved -and -not (Test-Path -LiteralPath $resolved)) { continue }
        if ($resolved) { $null = $importedFiles.Add($resolved) }
    }
}
foreach ($projectFile in $projectFiles) {
    foreach ($importProject in @(Get-ImportPaths -Path $projectFile.FullName)) {
        $resolved = Resolve-ImportPath -FromFile $projectFile.FullName -ImportProject $importProject -RepoRoot $repoPath
        if ($resolved) { $null = $importedFiles.Add($resolved) }
    }
}
foreach ($importedPath in @($importedFiles)) {
    if (-not (@($propsFiles | ForEach-Object { $_.FullName }) -contains $importedPath) -and (Test-Path -LiteralPath $importedPath)) {
        $propsFiles += (Get-Item -LiteralPath $importedPath)
    }
}
$propsFiles = @($propsFiles | Sort-Object FullName -Unique)

$propertyMap = @{}
foreach ($propsFile in @($propsFiles | Sort-Object { $_.FullName.Length })) {
    foreach ($entry in (Get-PropertyMap -Path $propsFile.FullName).GetEnumerator()) {
        $propertyMap[$entry.Key] = $entry.Value
    }
}
if (Test-Path -LiteralPath $directoryBuildProps) {
    foreach ($entry in (Get-PropertyMap -Path $directoryBuildProps).GetEnumerator()) {
        $propertyMap[$entry.Key] = $entry.Value
    }
}
$declaredIn = [System.Collections.Generic.List[object]]::new()
$allTfms = [System.Collections.Generic.List[string]]::new()
$unresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-TfmDeclarations {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][hashtable]$Map
    )

    $raw = Read-TextWithEncoding -Path $FilePath
    [xml]$fileXml = $raw
    foreach ($propertyGroup in @($fileXml.SelectNodes('/Project/PropertyGroup'))) {
        $condition = if ($propertyGroup.Attributes['Condition']) { [string]$propertyGroup.Attributes['Condition'].Value } else { $null }
        foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -in @('TargetFramework', 'TargetFrameworks') })) {
            $rawValue = [string]$node.InnerText
            $resolved = Resolve-PropertyTokens -Value $rawValue -Map $Map
            $tfms = Split-Tfms -Value $resolved
            foreach ($tfm in $tfms) {
                if ($tfm -match '\$\(') { $null = $unresolved.Add($tfm) } else { $allTfms.Add($tfm) }
            }
            $declaredIn.Add([pscustomobject]@{
                scope            = $Scope
                path             = $RelativePath
                property         = $node.Name
                condition        = $condition
                rawValue         = $rawValue
                resolvedValue    = $resolved
                targetFrameworks = $tfms
            })
        }
    }
}

foreach ($propsFile in $propsFiles) {
    $relative = [System.IO.Path]::GetRelativePath($repoPath, $propsFile.FullName)
    $scope = if ($propsFile.Name -ieq 'Directory.Build.props') { 'Directory.Build.props' }
        elseif ($propsFile.Extension -ieq '.props') { 'Props' }
        else { 'Targets' }
    Add-TfmDeclarations -FilePath $propsFile.FullName -Scope $scope -RelativePath $relative -Map $propertyMap
}

$projects = [System.Collections.Generic.List[object]]::new()

foreach ($projectFile in $projectFiles) {
    $localMap = @{}
    foreach ($entry in $propertyMap.GetEnumerator()) { $localMap[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-PropertyMap -Path $projectFile.FullName).GetEnumerator()) { $localMap[$entry.Key] = $entry.Value }
    $rawProject = Read-TextWithEncoding -Path $projectFile.FullName
    [xml]$projectXml = $rawProject
    $projectTfms = [System.Collections.Generic.List[string]]::new()
    $projectUnresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($propertyGroup in @($projectXml.SelectNodes('/Project/PropertyGroup'))) {
        $condition = if ($propertyGroup.Attributes['Condition']) { [string]$propertyGroup.Attributes['Condition'].Value } else { $null }
        foreach ($node in @($propertyGroup.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -in @('TargetFramework', 'TargetFrameworks') })) {
            $raw = [string]$node.InnerText
            $resolved = Resolve-PropertyTokens -Value $raw -Map $localMap
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
