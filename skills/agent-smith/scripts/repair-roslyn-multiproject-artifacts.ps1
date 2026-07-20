[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $Path,

    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedLines {
    param([string] $Text)

    $lines = @($Text -split "\r\n|\n|\r")
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[0])) {
        $lines = @($lines | Select-Object -Skip 1)
    }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[-1])) {
        $lines = @($lines | Select-Object -SkipLast 1)
    }
    return $lines
}

function Test-LinePrefix {
    param(
        [string[]] $Candidate,
        [string[]] $Complete
    )

    if ($Candidate.Count -eq 0 -or $Candidate.Count -gt $Complete.Count) {
        return $false
    }

    for ($i = 0; $i -lt $Candidate.Count; $i++) {
        if ($Candidate[$i] -cne $Complete[$i]) {
            return $false
        }
    }
    return $true
}

function Get-Utf8File {
    param([string] $LiteralPath)

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        throw "File is not valid UTF-8: $LiteralPath"
    }

    return [pscustomobject]@{
        Bytes = $bytes
        HasBom = $hasBom
        Text = $text
    }
}

function Set-Utf8File {
    param(
        [string] $LiteralPath,
        [string] $Text,
        [bool] $HasBom
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $contentBytes = $encoding.GetBytes($Text)
    if (-not $HasBom) {
        [System.IO.File]::WriteAllBytes($LiteralPath, $contentBytes)
        return
    }

    $bytes = [byte[]]::new(3 + $contentBytes.Length)
    $bytes[0] = 0xEF
    $bytes[1] = 0xBB
    $bytes[2] = 0xBF
    [Array]::Copy($contentBytes, 0, $bytes, 3, $contentBytes.Length)
    [System.IO.File]::WriteAllBytes($LiteralPath, $bytes)
}

function Get-SourceFiles {
    param([string[]] $InputPaths)

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($inputPath in $InputPaths) {
        $resolved = Resolve-Path -LiteralPath $inputPath -ErrorAction Stop
        foreach ($item in $resolved) {
            if ([System.IO.File]::Exists($item.Path)) {
                if ([System.IO.Path]::GetExtension($item.Path) -ieq '.cs') {
                    $files.Add([System.IO.Path]::GetFullPath($item.Path))
                }
                continue
            }

            Get-ChildItem -LiteralPath $item.Path -Filter '*.cs' -File -Recurse |
                Where-Object { $_.FullName -notmatch '[\\/](?:bin|obj)[\\/]' } |
                ForEach-Object { $files.Add($_.FullName) }
        }
    }

    return @($files | Sort-Object -Unique)
}

$artifactPattern = [regex]::new(
    "(?ms)^<<<<<<< TODO: Unmerged change from project '(?<project>[^']+)', Before:\r?\n(?<before>.*?)^=======\r?\n(?<after>.*?)^>>>>>>> After(?:\r?\n|$)",
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
$results = [System.Collections.Generic.List[object]]::new()
$pendingRepairs = [System.Collections.Generic.List[object]]::new()
$hasUnsafeArtifact = $false
$sourceFiles = @(Get-SourceFiles -InputPaths $Path)
if ($sourceFiles.Count -eq 0) {
    throw 'No C# source files were found under the supplied path.'
}

foreach ($file in $sourceFiles) {
    $source = Get-Utf8File -LiteralPath $file
    $matches = $artifactPattern.Matches($source.Text)
    $markerCount = ([regex]::Matches($source.Text, '(?m)^<<<<<<< TODO: Unmerged change from project ')).Count
    $endCount = ([regex]::Matches($source.Text, '(?m)^>>>>>>> After\r?$')).Count
    $legacyCommentCount = ([regex]::Matches($source.Text, 'Unmerged change from project')).Count - $markerCount

    if ($markerCount -eq 0 -and $endCount -eq 0 -and $legacyCommentCount -eq 0) {
        $results.Add([pscustomobject]@{
            path = $file
            status = 'clean'
            pattern = $null
            reason = 'No Roslyn multi-project merge artifact found.'
        })
        continue
    }

    $reason = $null
    if ($matches.Count -ne 1 -or $markerCount -ne 1 -or $endCount -ne 1 -or $legacyCommentCount -ne 0) {
        $reason = 'Expected exactly one complete current-format Roslyn artifact and no legacy comment artifacts.'
    }

    $match = if ($matches.Count -eq 1) { $matches[0] } else { $null }
    $headerText = if ($null -ne $match) { $source.Text.Substring(0, $match.Index) } else { '' }
    $tailText = if ($null -ne $match) { $source.Text.Substring($match.Index + $match.Length) } else { '' }
    $beforeLines = @(if ($null -ne $match) { Get-NormalizedLines -Text $match.Groups['before'].Value })
    $afterLines = @(if ($null -ne $match) { Get-NormalizedLines -Text $match.Groups['after'].Value })
    $tailLines = @(if ($null -ne $match) { Get-NormalizedLines -Text $tailText })

    $beforeNamespace = if ($beforeLines.Count -gt 0) { [regex]::Match($beforeLines[0], '^namespace\s+(?<name>[^;{]+)\s*$') } else { [System.Text.RegularExpressions.Match]::Empty }
    $afterNamespace = if ($afterLines.Count -gt 0) { [regex]::Match($afterLines[0], '^namespace\s+(?<name>[^;{]+)\s*;\s*$') } else { [System.Text.RegularExpressions.Match]::Empty }
    $tailNamespace = if ($tailLines.Count -gt 0) { [regex]::Match($tailLines[0], '^namespace\s+(?<name>[^;{]+)\s*;\s*$') } else { [System.Text.RegularExpressions.Match]::Empty }

    if ($null -eq $reason -and (-not $beforeNamespace.Success -or -not $afterNamespace.Success -or -not $tailNamespace.Success)) {
        $reason = 'No supported repair pattern matched this Roslyn multi-project artifact.'
    }
    if ($null -eq $reason -and ($beforeNamespace.Groups['name'].Value.Trim() -cne $afterNamespace.Groups['name'].Value.Trim() -or $afterNamespace.Groups['name'].Value.Trim() -cne $tailNamespace.Groups['name'].Value.Trim())) {
        $reason = 'The before, partial-after, and complete-after namespace names differ.'
    }
    if ($null -eq $reason -and -not (Test-LinePrefix -Candidate $afterLines -Complete $tailLines)) {
        $reason = 'The partial After branch is not an exact line-for-line prefix of the retained complete After document.'
    }

    if ($null -ne $reason) {
        $hasUnsafeArtifact = $true
        $results.Add([pscustomobject]@{
            path = $file
            status = 'unsafe'
            pattern = 'unrecognized'
            reason = $reason
        })
        continue
    }

    $tailLineEndingMatch = [regex]::Match($tailText, '\r\n|\n|\r')
    $lineEnding = if ($tailLineEndingMatch.Success) { $tailLineEndingMatch.Value } else { [Environment]::NewLine }
    $header = [regex]::Replace($headerText.TrimEnd("`r", "`n"), '\r\n|\n|\r', $lineEnding)
    $tail = [regex]::Replace($tailText.TrimStart("`r", "`n"), '\r\n|\n|\r', $lineEnding)
    $repairedText = if ([string]::IsNullOrEmpty($header)) { $tail } else { $header + $lineEnding + $lineEnding + $tail }

    $result = [pscustomobject]@{
        path = $file
        status = 'recoverable'
        pattern = 'whole-document-namespace-conversion'
        project = $match.Groups['project'].Value
        namespace = $afterNamespace.Groups['name'].Value.Trim()
        beforeLines = $beforeLines.Count
        partialAfterLines = $afterLines.Count
        retainedAfterLines = $tailLines.Count
        reason = 'The partial After branch is an exact prefix of the retained complete namespace-conversion document.'
    }
    $results.Add($result)
    $pendingRepairs.Add([pscustomobject]@{
        path = $file
        text = $repairedText
        hasBom = $source.HasBom
        result = $result
    })
}

if ($Apply -and -not $hasUnsafeArtifact) {
    foreach ($repair in $pendingRepairs) {
        Set-Utf8File -LiteralPath $repair.path -Text $repair.text -HasBom $repair.hasBom
        $repair.result.status = 'repaired'
    }
}

$results | ConvertTo-Json -Depth 4 -AsArray
if ($hasUnsafeArtifact) {
    exit 2
}
exit 0
