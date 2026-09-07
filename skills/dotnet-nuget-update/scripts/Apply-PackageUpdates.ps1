[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Updates,
    [string]$UpdatesFile,
    [switch]$DryRun,
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

    $versionNode = $Node.SelectSingleNode('./Version')
    if ($versionNode) {
        return [string]$versionNode.InnerText
    }

    return $null
}

function Get-ConditionValue {
    param($Node)

    if ($null -eq $Node) { return $null }
    if ($Node.Attributes['Condition']) { return [string]$Node.Attributes['Condition'].Value }
    return $null
}

function Parse-Updates {
    param([string]$Json, [string]$JsonFile)

    if (-not [string]::IsNullOrWhiteSpace($Json) -and -not [string]::IsNullOrWhiteSpace($JsonFile)) {
        throw 'Specify either -Updates or -UpdatesFile, not both.'
    }

    if (-not [string]::IsNullOrWhiteSpace($JsonFile)) {
        $Json = Get-Content -Raw -LiteralPath $JsonFile
    }

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw 'One of -Updates or -UpdatesFile is required.'
    }

    $parsed = $Json | ConvertFrom-Json
    if ($parsed -is [string]) { return @($parsed) }
    return @($parsed)
}

function Replace-VersionInLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $attributePattern = '(Version\s*=\s*")' + [regex]::Escape($From) + '(")'
    if ($Line -match $attributePattern) {
        return ($Line -replace $attributePattern, "`${1}$To`${2}")
    }

    $elementPattern = '(<Version>\s*)' + [regex]::Escape($From) + '(\s*</Version>)'
    if ($Line -match $elementPattern) {
        return ($Line -replace $elementPattern, "`${1}$To`${2}")
    }

    return $null
}

function Update-DeclarationLine {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ElementName,
        [Parameter(Mandatory)][string]$Id,
        [string]$Condition,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $lines = $Text -split '\r?\n', -1
    $currentCondition = $null

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]

        if ($line -match '<ItemGroup\b') {
            $conditionMatch = [regex]::Match($line, 'Condition\s*=\s*"([^"]*)"')
            $currentCondition = if ($conditionMatch.Success) { $conditionMatch.Groups[1].Value } else { $null }
        }

        if ($line -match "<$ElementName\b" -and $line -match ('Include\s*=\s*"' + [regex]::Escape($Id) + '"')) {
            if (($Condition ?? '') -eq ($currentCondition ?? '')) {
                $updatedLine = Replace-VersionInLine -Line $line -From $From -To $To
                if ($null -ne $updatedLine) {
                    $lines[$index] = $updatedLine
                    return ($lines -join "`n")
                }
            }
        }

        if ($line -match '</ItemGroup>') {
            $currentCondition = $null
        }
    }

    return $null
}

function Get-CentralDeclarations {
    param([Parameter(Mandatory)][string]$Path)

    [xml]$xml = Get-Content -Raw -LiteralPath $Path
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($itemGroup in @($xml.Project.ItemGroup)) {
        $condition = Get-ConditionValue -Node $itemGroup
        foreach ($node in @($itemGroup.ChildNodes)) {
            if ($node.NodeType -ne 'Element' -or $node.Name -ne 'PackageVersion') { continue }
            $id = if ($node.Attributes['Include']) { [string]$node.Attributes['Include'].Value } else { $null }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $rows.Add([pscustomobject]@{
                id        = $id
                current   = Get-NodeVersion -Node $node
                condition = $condition
                element   = 'PackageVersion'
            })
        }
    }
    return @($rows)
}

function Get-ProjectDeclarations {
    param([Parameter(Mandatory)][string]$Root)

    $rows = [System.Collections.Generic.List[object]]::new()
    $projectFiles = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.csproj -File |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

    foreach ($projectFile in $projectFiles) {
        [xml]$xml = Get-Content -Raw -LiteralPath $projectFile.FullName
        foreach ($itemGroup in @($xml.Project.ItemGroup)) {
            $groupCondition = Get-ConditionValue -Node $itemGroup
            foreach ($node in @($itemGroup.ChildNodes)) {
                if ($node.NodeType -ne 'Element' -or $node.Name -notin @('PackageReference', 'GlobalPackageReference')) { continue }
                $id = if ($node.Attributes['Include']) { [string]$node.Attributes['Include'].Value } else { $null }
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                $version = Get-NodeVersion -Node $node
                if ([string]::IsNullOrWhiteSpace($version)) { continue }
                $nodeCondition = Get-ConditionValue -Node $node
                $rows.Add([pscustomobject]@{
                    id         = $id
                    current    = $version
                    condition  = if ($nodeCondition) { $nodeCondition } else { $groupCondition }
                    element    = $node.Name
                    sourceFile = [System.IO.Path]::GetRelativePath($Root, $projectFile.FullName)
                })
            }
        }
    }
    return @($rows)
}

$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$updatesList = Parse-Updates -Json $Updates -JsonFile $UpdatesFile
$centralPath = Join-Path $repoPath 'Directory.Packages.props'
$hasCentral = Test-Path -LiteralPath $centralPath
$results = [System.Collections.Generic.List[object]]::new()

if ($hasCentral) {
    $text = Get-Content -Raw -LiteralPath $centralPath
    $declarations = Get-CentralDeclarations -Path $centralPath
    $changed = $false

    foreach ($update in $updatesList) {
        $matches = @($declarations | Where-Object {
            $_.id -eq $update.id -and (($_.condition ?? '') -eq (($update.condition ?? '')))
        })

        if ($matches.Count -eq 0) {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; outcome = 'not-found'; from = $update.from; to = $update.to })
            continue
        }

        $match = $matches[0]
        if ($match.current -ne $update.from) {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; outcome = 'conflict'; from = $update.from; to = $update.to })
            continue
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; outcome = 'dry-run'; from = $update.from; to = $update.to })
            continue
        }

        $updatedText = Update-DeclarationLine -Text $text -ElementName 'PackageVersion' -Id $update.id -Condition $update.condition -From $update.from -To $update.to
        if ($null -eq $updatedText) {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; outcome = 'not-found'; from = $update.from; to = $update.to })
            continue
        }

        $text = $updatedText
        $match.current = $update.to
        $changed = $true
        $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; outcome = 'applied'; from = $update.from; to = $update.to })
    }

    if ($changed -and -not $DryRun) {
        Write-TextPreservingEol -Path $centralPath -Text $text | Out-Null
    }

    $result = [pscustomobject]@{ repoRoot = $repoPath; mode = 'central'; results = @($results) }
    if ($AsJson) { $result | ConvertTo-Json -Depth 12 } else { $result }
    return
}

$projectDeclarations = Get-ProjectDeclarations -Root $repoPath
if ($projectDeclarations.Count -eq 0) {
    $empty = [pscustomobject]@{ repoRoot = $repoPath; mode = 'project'; results = @($results) }
    if ($AsJson) { $empty | ConvertTo-Json -Depth 12 } else { $empty }
    return
}

$fileTexts = @{}
$fileChanged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($update in $updatesList) {
    $matches = @($projectDeclarations | Where-Object {
        $_.id -eq $update.id -and $_.current -eq $update.from -and (($_.condition ?? '') -eq (($update.condition ?? '')))
    })

    if ($matches.Count -eq 0) {
        $conflicts = @($projectDeclarations | Where-Object {
            $_.id -eq $update.id -and (($_.condition ?? '') -eq (($update.condition ?? '')))
        })
        if ($conflicts.Count -gt 0) {
            foreach ($conflict in $conflicts) {
                $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; sourceFile = $conflict.sourceFile; outcome = 'conflict'; from = $update.from; to = $update.to })
            }
        } else {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; outcome = 'not-found'; from = $update.from; to = $update.to })
        }
        continue
    }

    foreach ($match in $matches) {
        $filePath = Join-Path $repoPath $match.sourceFile
        if (-not $fileTexts.ContainsKey($match.sourceFile)) {
            $fileTexts[$match.sourceFile] = Get-Content -Raw -LiteralPath $filePath
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; sourceFile = $match.sourceFile; outcome = 'dry-run'; from = $update.from; to = $update.to })
            continue
        }

        $updatedText = Update-DeclarationLine -Text $fileTexts[$match.sourceFile] -ElementName $match.element -Id $update.id -Condition $update.condition -From $update.from -To $update.to
        if ($null -eq $updatedText) {
            $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; sourceFile = $match.sourceFile; outcome = 'not-found'; from = $update.from; to = $update.to })
            continue
        }

        $fileTexts[$match.sourceFile] = $updatedText
        $match.current = $update.to
        $null = $fileChanged.Add($match.sourceFile)
        $results.Add([pscustomobject]@{ id = $update.id; condition = $update.condition; sourceFile = $match.sourceFile; outcome = 'applied'; from = $update.from; to = $update.to })
    }
}

if (-not $DryRun) {
    foreach ($relativePath in $fileChanged) {
        Write-TextPreservingEol -Path (Join-Path $repoPath $relativePath) -Text $fileTexts[$relativePath] | Out-Null
    }
}

$result = [pscustomobject]@{ repoRoot = $repoPath; mode = 'project'; results = @($results) }
if ($AsJson) { $result | ConvertTo-Json -Depth 12 } else { $result }
