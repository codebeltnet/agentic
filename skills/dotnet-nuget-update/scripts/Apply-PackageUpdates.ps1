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

function Get-UpdateField {
    param($Update, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Update) { return $null }
    if ($Update -is [System.Collections.IDictionary]) {
        if ($Update.Contains($Name)) { return $Update[$Name] }
        return $null
    }
    $property = $Update.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
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

function Replace-VersionInBlock {
    param(
        [Parameter(Mandatory)][string]$Block,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $escaped = [regex]::Escape($From)

    foreach ($attributeName in @('Version', 'VersionOverride')) {
        $pattern = '(' + $attributeName + '\s*=\s*)([''"])' + $escaped + '\2'
        $match = [regex]::Match($Block, $pattern)
        if ($match.Success) {
            $prefix = $match.Groups[1].Value
            $quote = $match.Groups[2].Value
            $start = $match.Index + $prefix.Length + $quote.Length
            return $Block.Substring(0, $start) + $To + $Block.Substring($start + $From.Length)
        }
    }

    foreach ($elementName in @('Version', 'VersionOverride')) {
        $pattern = '(<' + $elementName + '\s*>\s*)' + $escaped + '(\s*</' + $elementName + '\s*>)'
        $match = [regex]::Match($Block, $pattern)
        if ($match.Success) {
            $prefix = $match.Groups[1].Value
            $start = $match.Index + $prefix.Length
            return $Block.Substring(0, $start) + $To + $Block.Substring($start + $From.Length)
        }
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

    $lines = [regex]::Split($Text, "`r`n|`n|`r")
    $groupCondition = $null

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]

        if ($line -match '<ItemGroup\b') {
            $tag = $line
            $tagEnd = $index
            while ($tag -notmatch '>' -and ($tagEnd + 1) -lt $lines.Count) {
                $tagEnd++
                $tag += "`n" + $lines[$tagEnd]
            }
            $conditionMatch = [regex]::Match($tag, 'Condition\s*=\s*([''"])(.*?)\1')
            $groupCondition = if ($conditionMatch.Success) { $conditionMatch.Groups[2].Value } else { $null }
            if ($tagEnd -gt $index) {
                $index = $tagEnd
                $line = $lines[$index]
            }
        }

        if ($line -match '</ItemGroup\s*>') {
            $groupCondition = $null
        }

        if ($line -notmatch ('<' + $ElementName + '\b')) {
            continue
        }

        $blockStart = $index
        $tagText = $line
        $tagEnd = $index
        while ($tagText -notmatch '>' -and ($tagEnd + 1) -lt $lines.Count) {
            $tagEnd++
            $tagText += "`n" + $lines[$tagEnd]
        }

        $blockEnd = $tagEnd
        $blockLines = @($lines[$blockStart..$blockEnd])
        if ($tagText -match '/\s*>\s*$' -or $tagText -match '/\s*>') {
            $afterStart = $tagText.Substring($tagText.IndexOf('>') + 1)
            if ($afterStart -match ('</' + $ElementName + '\s*>')) {
                # Self-closing tag text already contains its close; block is complete.
            }
        } else {
            $afterStart = ''
            $greaterAt = $tagText.IndexOf('>')
            if ($greaterAt -ge 0 -and $greaterAt + 1 -lt $tagText.Length) {
                $afterStart = $tagText.Substring($greaterAt + 1)
            }
            if ($afterStart -notmatch ('</' + $ElementName + '\s*>')) {
                $foundClose = $false
                for ($closeIndex = $tagEnd + 1; $closeIndex -lt $lines.Count; $closeIndex++) {
                    $blockLines += $lines[$closeIndex]
                    $blockEnd = $closeIndex
                    if ($lines[$closeIndex] -match ('</' + $ElementName + '\s*>')) {
                        $foundClose = $true
                        break
                    }
                    if ($lines[$closeIndex] -match '<ItemGroup\b' -or $lines[$closeIndex] -match ('<' + $ElementName + '\b')) {
                        break
                    }
                }
                if (-not $foundClose) {
                    $index = $blockEnd
                    continue
                }
            }
        }

        $blockText = $blockLines -join "`n"
        if (-not ([regex]::IsMatch($blockText, 'Include\s*=\s*([''"])' + [regex]::Escape($Id) + '\1'))) {
            $index = $blockEnd
            continue
        }

        $nodeConditionMatch = [regex]::Match($tagText, 'Condition\s*=\s*([''"])(.*?)\1')
        $nodeCondition = if ($nodeConditionMatch.Success) { $nodeConditionMatch.Groups[2].Value } else { $null }
        $effective = if ($nodeCondition) { $nodeCondition } else { $groupCondition }
        if ((($Condition ?? '') -ne ($effective ?? ''))) {
            $index = $blockEnd
            continue
        }

        $updatedBlock = Replace-VersionInBlock -Block $blockText -From $From -To $To
        if ($null -eq $updatedBlock) {
            $index = $blockEnd
            continue
        }

        $updatedLines = [regex]::Split($updatedBlock, "`r`n|`n|`r")
        $newAll = [System.Collections.Generic.List[string]]::new()
        for ($before = 0; $before -lt $blockStart; $before++) {
            $newAll.Add($lines[$before])
        }
        foreach ($updatedLine in $updatedLines) {
            $newAll.Add($updatedLine)
        }
        for ($after = $blockEnd + 1; $after -lt $lines.Count; $after++) {
            $newAll.Add($lines[$after])
        }
        return ($newAll -join "`n")
    }

    return $null
}

function Get-CentralDeclarations {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RepoRoot)

    $raw = Read-TextWithEncoding -Path $Path
    [xml]$xml = $raw
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($itemGroup in @($xml.SelectNodes('/Project/ItemGroup'))) {
        $groupCondition = Get-ConditionValue -Node $itemGroup
        foreach ($node in @($itemGroup.ChildNodes)) {
            if ($node.NodeType -ne 'Element' -or $node.Name -ne 'PackageVersion') { continue }
            $id = if ($node.Attributes['Include']) { [string]$node.Attributes['Include'].Value } else { $null }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $nodeCondition = Get-ConditionValue -Node $node
            $rows.Add([pscustomobject]@{
                id         = $id
                current    = Get-NodeVersion -Node $node
                condition  = if ($nodeCondition) { $nodeCondition } else { $groupCondition }
                element    = 'PackageVersion'
                sourceFile = [System.IO.Path]::GetRelativePath($RepoRoot, (Resolve-Path -LiteralPath $Path).Path)
            })
        }
    }
    return @($rows)
}

function Get-CentralPropsFiles {
    param([Parameter(Mandatory)][string]$Root)

    return @(Get-ChildItem -LiteralPath $Root -Recurse -Filter Directory.Packages.props -File |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Sort-Object FullName)
}

function Get-ProjectDeclarations {
    param([Parameter(Mandatory)][string]$Root)

    $rows = [System.Collections.Generic.List[object]]::new()
    $projectFiles = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.csproj -File |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }

    foreach ($projectFile in $projectFiles) {
        $raw = Read-TextWithEncoding -Path $projectFile.FullName
        [xml]$xml = $raw
        foreach ($itemGroup in @($xml.SelectNodes('/Project/ItemGroup'))) {
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
$centralFiles = @(Get-CentralPropsFiles -Root $repoPath)
$hasCentral = $centralFiles.Count -gt 0
$results = [System.Collections.Generic.List[object]]::new()

if ($hasCentral) {
    $fileTexts = @{}
    $fileChanged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $centralDeclarations = [System.Collections.Generic.List[object]]::new()
    foreach ($centralFile in $centralFiles) {
        $fileTexts[$centralFile.FullName] = Read-TextWithEncoding -Path $centralFile.FullName
        foreach ($declaration in @(Get-CentralDeclarations -Path $centralFile.FullName -RepoRoot $repoPath)) {
            $centralDeclarations.Add($declaration)
        }
    }
    $projectDeclarations = @(Get-ProjectDeclarations -Root $repoPath)

    foreach ($update in $updatesList) {
        $updateId = Get-UpdateField -Update $update -Name 'id'
        $updateCondition = Get-UpdateField -Update $update -Name 'condition'
        $updateFrom = Get-UpdateField -Update $update -Name 'from'
        $updateTo = Get-UpdateField -Update $update -Name 'to'
        $updateSource = Get-UpdateField -Update $update -Name 'sourceFile'
        $updateElement = Get-UpdateField -Update $update -Name 'element'

        $isProjectSource = (-not [string]::IsNullOrWhiteSpace($updateSource)) -and
            $updateSource.EndsWith('.csproj', [System.StringComparison]::OrdinalIgnoreCase)

        $targetDeclarations = if ($isProjectSource) { $projectDeclarations } else { $centralDeclarations }

        $candidates = @($targetDeclarations | Where-Object {
            $_.id -eq $updateId -and (($_.condition ?? '') -eq (($updateCondition ?? ''))) -and
            ([string]::IsNullOrWhiteSpace($updateSource) -or $_.sourceFile -eq $updateSource) -and
            ([string]::IsNullOrWhiteSpace($updateElement) -or $_.element -eq $updateElement)
        })

        if ($candidates.Count -eq 0) {
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $updateSource; outcome = 'not-found'; from = $updateFrom; to = $updateTo })
            continue
        }

        $matchingFrom = @($candidates | Where-Object { $_.current -eq $updateFrom })

        if ($matchingFrom.Count -gt 1) {
            if ([string]::IsNullOrWhiteSpace($updateSource)) {
                foreach ($conflict in $matchingFrom) {
                    $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $conflict.sourceFile; outcome = 'conflict'; from = $updateFrom; to = $updateTo })
                }
            } else {
                $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $updateSource; outcome = 'conflict'; from = $updateFrom; to = $updateTo })
            }
            continue
        }

        $resolved = if ($matchingFrom.Count -gt 0) { $matchingFrom[0] } else { $null }
        if ($null -eq $resolved) {
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $updateSource; outcome = 'conflict'; from = $updateFrom; to = $updateTo })
            continue
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $resolved.sourceFile; outcome = 'dry-run'; from = $updateFrom; to = $updateTo })
            continue
        }

        if ($isProjectSource) {
            $projFullPath = Join-Path $repoPath $resolved.sourceFile
            if (-not $fileTexts.ContainsKey($projFullPath)) {
                $fileTexts[$projFullPath] = Read-TextWithEncoding -Path $projFullPath
            }

            $updatedText = Update-DeclarationLine -Text $fileTexts[$projFullPath] -ElementName $resolved.element -Id $updateId -Condition $updateCondition -From $updateFrom -To $updateTo
            if ($null -eq $updatedText) {
                $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $resolved.sourceFile; outcome = 'not-found'; from = $updateFrom; to = $updateTo })
                continue
            }

            $fileTexts[$projFullPath] = $updatedText
            $resolved.current = $updateTo
            $null = $fileChanged.Add($projFullPath)
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $resolved.sourceFile; outcome = 'applied'; from = $updateFrom; to = $updateTo })
        } else {
            $matchFullPath = Join-Path $repoPath $resolved.sourceFile
            $matchKeyCandidates = @($fileTexts.Keys | Where-Object { $_ -ieq $matchFullPath })
            $matchKey = if ($matchKeyCandidates.Count -gt 0) { $matchKeyCandidates[0] } else { $matchFullPath }
            $updatedText = Update-DeclarationLine -Text $fileTexts[$matchKey] -ElementName $resolved.element -Id $updateId -Condition $updateCondition -From $updateFrom -To $updateTo
            if ($null -eq $updatedText) {
                $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $resolved.sourceFile; outcome = 'not-found'; from = $updateFrom; to = $updateTo })
                continue
            }

            $fileTexts[$matchKey] = $updatedText
            $resolved.current = $updateTo
            $null = $fileChanged.Add($matchKey)
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $resolved.sourceFile; outcome = 'applied'; from = $updateFrom; to = $updateTo })
        }
    }

    if (-not $DryRun) {
        foreach ($fullPath in $fileChanged) {
            Write-TextPreservingEol -Path $fullPath -Text $fileTexts[$fullPath] | Out-Null
        }
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
    $updateId = Get-UpdateField -Update $update -Name 'id'
    $updateCondition = Get-UpdateField -Update $update -Name 'condition'
    $updateFrom = Get-UpdateField -Update $update -Name 'from'
    $updateTo = Get-UpdateField -Update $update -Name 'to'
    $updateSource = Get-UpdateField -Update $update -Name 'sourceFile'
    $updateElement = Get-UpdateField -Update $update -Name 'element'

    $matches = @($projectDeclarations | Where-Object {
        $_.id -eq $updateId -and $_.current -eq $updateFrom -and (($_.condition ?? '') -eq (($updateCondition ?? ''))) -and
        ([string]::IsNullOrWhiteSpace($updateSource) -or $_.sourceFile -eq $updateSource) -and
        ([string]::IsNullOrWhiteSpace($updateElement) -or $_.element -eq $updateElement)
    })

    if ($matches.Count -eq 0) {
        $conflicts = @($projectDeclarations | Where-Object {
            $_.id -eq $updateId -and (($_.condition ?? '') -eq (($updateCondition ?? ''))) -and
            ([string]::IsNullOrWhiteSpace($updateSource) -or $_.sourceFile -eq $updateSource) -and
            ([string]::IsNullOrWhiteSpace($updateElement) -or $_.element -eq $updateElement)
        })
        if ($conflicts.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($updateSource)) {
                foreach ($conflict in $conflicts) {
                    $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $conflict.sourceFile; outcome = 'conflict'; from = $updateFrom; to = $updateTo })
                }
            } else {
                $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $updateSource; outcome = 'conflict'; from = $updateFrom; to = $updateTo })
            }
        } else {
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $updateSource; outcome = 'not-found'; from = $updateFrom; to = $updateTo })
        }
        continue
    }

    foreach ($match in $matches) {
        $filePath = Join-Path $repoPath $match.sourceFile
        if (-not $fileTexts.ContainsKey($match.sourceFile)) {
            $fileTexts[$match.sourceFile] = Read-TextWithEncoding -Path $filePath
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $match.sourceFile; outcome = 'dry-run'; from = $updateFrom; to = $updateTo })
            continue
        }

        $updatedText = Update-DeclarationLine -Text $fileTexts[$match.sourceFile] -ElementName $match.element -Id $updateId -Condition $updateCondition -From $updateFrom -To $updateTo
        if ($null -eq $updatedText) {
            $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $match.sourceFile; outcome = 'not-found'; from = $updateFrom; to = $updateTo })
            continue
        }

        $fileTexts[$match.sourceFile] = $updatedText
        $match.current = $updateTo
        $null = $fileChanged.Add($match.sourceFile)
        $results.Add([pscustomobject]@{ id = $updateId; condition = $updateCondition; sourceFile = $match.sourceFile; outcome = 'applied'; from = $updateFrom; to = $updateTo })
    }
}

if (-not $DryRun) {
    foreach ($relativePath in $fileChanged) {
        Write-TextPreservingEol -Path (Join-Path $repoPath $relativePath) -Text $fileTexts[$relativePath] | Out-Null
    }
}

$result = [pscustomobject]@{ repoRoot = $repoPath; mode = 'project'; results = @($results) }
if ($AsJson) { $result | ConvertTo-Json -Depth 12 } else { $result }
