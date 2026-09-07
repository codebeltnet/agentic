Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NuGetVersionCache = @{}

function Get-FileLineEndingStyle {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'none' }

    $encoding = Get-FileEncoding -Path $Path
    $text = [System.IO.File]::ReadAllText($Path, $encoding)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $lf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    $cr = ([regex]::Matches($text, "`r(?!`n)")).Count

    if (($crlf + $lf + $cr) -eq 0) { return 'none' }
    if ($crlf -gt 0 -and $lf -eq 0 -and $cr -eq 0) { return 'CRLF' }
    if ($lf -gt 0 -and $crlf -eq 0 -and $cr -eq 0) { return 'LF' }
    if ($cr -gt 0 -and $crlf -eq 0 -and $lf -eq 0) { return 'mixed' }
    return 'mixed'
}

function Get-FileEncoding {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [System.Text.UTF8Encoding]::new($false)
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        return [System.Text.UTF32Encoding]::new($true, $true)
    }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        return [System.Text.UTF32Encoding]::new($false, $true)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.UnicodeEncoding]::new($false, $true)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.UnicodeEncoding]::new($true, $true)
    }

    $nullCount = 0
    $evenNulls = 0
    $oddNulls = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0) {
            $nullCount++
            if ($index % 2 -eq 0) { $evenNulls++ } else { $oddNulls++ }
        }
    }
    if ($nullCount -gt 0 -and $bytes.Length -ge 2) {
        $threshold = [Math]::Max(4, [int]($bytes.Length / 20))
        if ($oddNulls -gt $evenNulls -and $oddNulls -ge $threshold) {
            return [System.Text.UnicodeEncoding]::new($false, $false)
        }
        if ($evenNulls -gt $oddNulls -and $evenNulls -ge $threshold) {
            return [System.Text.UnicodeEncoding]::new($true, $false)
        }
    }

    try {
        $strict = [System.Text.UTF8Encoding]::new($false, $true)
        $null = $strict.GetString($bytes)
        return [System.Text.UTF8Encoding]::new($false)
    }
    catch {
    }

    try {
        return [System.Text.Encoding]::GetEncoding('windows-1252')
    }
    catch {
        return [System.Text.Encoding]::Latin1
    }
}

function Read-TextWithEncoding {
    param([Parameter(Mandatory)][string]$Path)

    $encoding = Get-FileEncoding -Path $Path
    return [System.IO.File]::ReadAllText($Path, $encoding)
}

function Write-TextPreservingEol {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('preserve', 'LF', 'CRLF')][string]$LineEnding = 'preserve'
    )

    $style = $LineEnding
    $existing = 'none'
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-FileLineEndingStyle -Path $Path
    }
    if ($style -eq 'preserve') {
        if ($existing -eq 'CRLF') {
            $style = 'CRLF'
        } elseif ($existing -eq 'mixed') {
            $style = 'mixed'
        } else {
            $style = 'LF'
        }
    }

    $encoding = Get-FileEncoding -Path $Path
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if ($style -eq 'CRLF') {
        $final = $normalized -replace "`n", "`r`n"
    } elseif ($style -eq 'mixed' -and (Test-Path -LiteralPath $Path)) {
        $originalText = [System.IO.File]::ReadAllText($Path, $encoding)
        $originalEndings = @([regex]::Matches($originalText, "`r`n|`n|`r") | ForEach-Object { $_.Value })
        $originalLines = [regex]::Split($originalText, "`r`n|`n|`r")
        $newLines = [regex]::Split($normalized, "`n")
        if ($originalLines.Count -eq $newLines.Count -and $originalEndings.Count -eq ($originalLines.Count - 1)) {
            $builder = [System.Text.StringBuilder]::new()
            for ($index = 0; $index -lt $newLines.Count; $index++) {
                $null = $builder.Append($newLines[$index])
                if ($index -lt $originalEndings.Count) {
                    $null = $builder.Append($originalEndings[$index])
                }
            }
            $final = $builder.ToString()
        } else {
            $final = $normalized
        }
        $style = 'mixed'
    } else {
        $final = $normalized
    }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $final, $encoding)
    return $style
}

function Test-NuGetLiteralVersion {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    $value = $Version.Trim()
    return $value -match '^\d+(\.\d+){0,3}(-[0-9A-Za-z\-.]+)?(\+[0-9A-Za-z\-.]+)?$'
}

function ConvertTo-NuGetSemVer {
    param([Parameter(Mandatory)][string]$Version)

    if (-not (Test-NuGetLiteralVersion -Version $Version)) {
        throw "Non-literal NuGet version expression: '$Version'. Property expressions, floating versions, and ranges cannot be compared as literals."
    }

    $value = $Version.Trim()
    $value = ($value -split '\+', 2)[0]
    $prerelease = $null
    $core = $value
    if ($value.Contains('-')) {
        $core, $prerelease = $value -split '-', 2
    }

    $numbers = @($core -split '\.' | ForEach-Object {
        $token = ($_ -replace '[^\d].*$', '')
        if ([string]::IsNullOrWhiteSpace($token)) { 0 } else { [int]$token }
    })

    while ($numbers.Count -lt 3) { $numbers += 0 }

    [pscustomobject]@{
        major        = $numbers[0]
        minor        = $numbers[1]
        patch        = $numbers[2]
        rest         = @($numbers | Select-Object -Skip 3)
        pre          = $prerelease
        isPrerelease = [bool]$prerelease
        raw          = $Version
    }
}

function Compare-NuGetVersion {
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )

    $left = ConvertTo-NuGetSemVer -Version $A
    $right = ConvertTo-NuGetSemVer -Version $B
    $leftNumbers = @($left.major, $left.minor, $left.patch) + $left.rest
    $rightNumbers = @($right.major, $right.minor, $right.patch) + $right.rest
    $count = [Math]::Max($leftNumbers.Count, $rightNumbers.Count)

    for ($index = 0; $index -lt $count; $index++) {
        $leftValue = if ($index -lt $leftNumbers.Count) { $leftNumbers[$index] } else { 0 }
        $rightValue = if ($index -lt $rightNumbers.Count) { $rightNumbers[$index] } else { 0 }
        if ($leftValue -ne $rightValue) {
            return [int][Math]::Sign($leftValue - $rightValue)
        }
    }

    if (-not $left.isPrerelease -and -not $right.isPrerelease) { return 0 }
    if (-not $left.isPrerelease) { return 1 }
    if (-not $right.isPrerelease) { return -1 }

    $leftPre = $left.pre -split '\.'
    $rightPre = $right.pre -split '\.'
    $preCount = [Math]::Max($leftPre.Count, $rightPre.Count)

    for ($index = 0; $index -lt $preCount; $index++) {
        if ($index -ge $leftPre.Count) { return -1 }
        if ($index -ge $rightPre.Count) { return 1 }

        $leftToken = $leftPre[$index]
        $rightToken = $rightPre[$index]
        $leftNumber = 0
        $rightNumber = 0
        $leftIsNumber = [int]::TryParse($leftToken, [ref]$leftNumber)
        $rightIsNumber = [int]::TryParse($rightToken, [ref]$rightNumber)

        if ($leftIsNumber -and $rightIsNumber) {
            if ($leftNumber -ne $rightNumber) {
                return [int][Math]::Sign($leftNumber - $rightNumber)
            }
        } elseif ($leftIsNumber) {
            return -1
        } elseif ($rightIsNumber) {
            return 1
        } else {
            $compare = [string]::CompareOrdinal($leftToken, $rightToken)
            if ($compare -ne 0) {
                return [int][Math]::Sign($compare)
            }
        }
    }

    return 0
}

function Sort-NuGetVersion {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Version)

    if ($Version.Count -le 1) {
        return ,([string[]]$Version)
    }

    $list = [System.Collections.Generic.List[string]]::new([string[]]$Version)
    $list.Sort([System.Comparison[string]]{ param($a, $b) Compare-NuGetVersion $a $b })
    return ,$list.ToArray()
}

function Get-NuGetVersionBump {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    if ((Compare-NuGetVersion -A $From -B $To) -ge 0) {
        return 'none'
    }

    $fromVersion = ConvertTo-NuGetSemVer -Version $From
    $toVersion = ConvertTo-NuGetSemVer -Version $To

    if ($fromVersion.major -ne $toVersion.major) { return 'major' }
    if ($fromVersion.minor -ne $toVersion.minor) { return 'minor' }
    if ($fromVersion.patch -ne $toVersion.patch) { return 'patch' }

    $fromRest = @($fromVersion.rest)
    $toRest = @($toVersion.rest)
    $count = [Math]::Max($fromRest.Count, $toRest.Count)

    for ($index = 0; $index -lt $count; $index++) {
        $leftValue = if ($index -lt $fromRest.Count) { $fromRest[$index] } else { 0 }
        $rightValue = if ($index -lt $toRest.Count) { $toRest[$index] } else { 0 }
        if ($leftValue -ne $rightValue) { return 'revision' }
    }

    return 'prerelease'
}

function Get-TfmBand {
    param([string]$Condition)

    if ([string]::IsNullOrWhiteSpace($Condition)) { return @() }

    $bands = [System.Collections.Generic.List[int]]::new()
    foreach ($match in [regex]::Matches($Condition, 'net(\d+)(?:\.\d+)?[^''"]*[''"]')) {
        $bands.Add([int]$match.Groups[1].Value)
    }

    return @($bands | Where-Object { $_ -ge 5 } | Sort-Object -Unique)
}

$script:NuGetServiceIndexCache = @{}

function Resolve-NuGetFlatContainerBase {
    param([Parameter(Mandatory)][string]$ServiceIndexUrl)

    $key = $ServiceIndexUrl.Trim()
    if ($script:NuGetServiceIndexCache.ContainsKey($key)) {
        return $script:NuGetServiceIndexCache[$key]
    }

    $index = Invoke-RestMethod -Uri $key -Method Get -TimeoutSec 30 -ErrorAction Stop
    $resources = @($index.resources)
    $flat = @($resources | Where-Object { $_."@type" -eq 'PackageBaseAddress/3.0.0' })
    if ($flat.Count -eq 0) {
        $flat = @($resources | Where-Object { $_."@type" -like 'PackageBaseAddress*' })
    }
    if ($flat.Count -eq 0) {
        throw "Service index '$key' does not expose a PackageBaseAddress resource."
    }

    $base = [string]$flat[0]."@id"
    $script:NuGetServiceIndexCache[$key] = $base
    return $base
}

function Get-NuGetVersionList {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'https://api.nuget.org/v3-flatcontainer'
    )

    $base = $Source.Trim()
    $packageId = $Id.ToLowerInvariant()
    $isHttp = $base -match '^https?://'
    $effectiveSource = $Source
    if ($isHttp -and $base -match 'index\.json\s*$') {
        try {
            $flatBase = Resolve-NuGetFlatContainerBase -ServiceIndexUrl $base
            $base = $flatBase.Trim()
            $effectiveSource = "$Source (flat-container $base)"
        }
        catch {
            $location = "$($base.TrimEnd('/'))/$packageId/index.json"
            $result = [pscustomobject]@{
                id       = $Id
                found    = $false
                source   = $Source
                url      = $location
                error    = "service-index lookup failed for '$Source': $($_.Exception.Message)"
                versions = @()
            }
            $script:NuGetVersionCache["$base|$packageId"] = $result
            return $result
        }
    }
    if ($isHttp) {
        $normalizedBase = $base.TrimEnd('/')
        $location = "$normalizedBase/$packageId/index.json"
    } else {
        $normalizedBase = $base.TrimEnd('\', '/')
        $location = Join-Path (Join-Path $normalizedBase $packageId) 'index.json'
    }

    $cacheKey = "$normalizedBase|$packageId"
    if ($script:NuGetVersionCache.ContainsKey($cacheKey)) {
        return $script:NuGetVersionCache[$cacheKey]
    }

    try {
        $response = if ($isHttp) {
            Invoke-RestMethod -Uri $location -Method Get -TimeoutSec 30 -ErrorAction Stop
        } else {
            Get-Content -Raw -LiteralPath $location -ErrorAction Stop | ConvertFrom-Json
        }

        $result = [pscustomobject]@{
            id       = $Id
            found    = $true
            source   = $effectiveSource
            url      = $location
            error    = $null
            versions = (Sort-NuGetVersion -Version @($response.versions))
        }
    }
    catch {
        $result = [pscustomobject]@{
            id       = $Id
            found    = $false
            source   = $effectiveSource
            url      = $location
            error    = $_.Exception.Message
            versions = @()
        }
    }

    $script:NuGetVersionCache[$cacheKey] = $result
    return $result
}

function Get-NuGetVersionListMerged {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Sources
    )

    $rawSources = @($Sources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $flatSources = [System.Collections.Generic.List[string]]::new()
    foreach ($rawEntry in $rawSources) {
        foreach ($part in ($rawEntry -split ';')) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $flatSources.Add($trimmed)
            }
        }
    }
    $effectiveSources = @($flatSources.ToArray())
    if ($effectiveSources.Count -eq 0) {
        $effectiveSources = @('https://api.nuget.org/v3-flatcontainer')
    }

    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $errors = [System.Collections.Generic.List[string]]::new()
    $usedSources = [System.Collections.Generic.List[string]]::new()
    $lastUrl = $null

    foreach ($sourceEntry in $effectiveSources) {
        $feed = Get-NuGetVersionList -Id $Id -Source $sourceEntry
        $lastUrl = $feed.url
        if ($feed.found) {
            $null = $usedSources.Add($sourceEntry)
            foreach ($version in @($feed.versions)) {
                if ($seen.Add($version)) {
                    $merged.Add($version)
                }
            }
        } else {
            $errors.Add("$sourceEntry : $($feed.error)")
        }
    }

    if ($usedSources.Count -gt 0) {
        return [pscustomobject]@{
            id       = $Id
            found    = $true
            source   = ($usedSources -join '; ')
            url      = $lastUrl
            error    = $null
            versions = (Sort-NuGetVersion -Version @($merged.ToArray()))
        }
    }

    return [pscustomobject]@{
        id       = $Id
        found    = $false
        source   = ($effectiveSources -join '; ')
        url      = $lastUrl
        error    = ($errors -join ' | ')
        versions = @()
    }
}

function Get-AdjacentXmlComment {
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node)

    # A leading comment on the lines above a declaration documents that
    # declaration. Only the immediately preceding comment is attached so a
    # comment between two declarations is not attributed to both packages.
    $cursor = $Node.PreviousSibling
    while ($null -ne $cursor) {
        if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
            $cursor = $cursor.PreviousSibling
            continue
        }

        if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace($cursor.Value)) {
            $cursor = $cursor.PreviousSibling
            continue
        }

        if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Comment) {
            return ([string]$cursor.Value).Trim()
        }

        break
    }

    # A trailing comment after the last package declaration in its parent has
    # no following declaration to document, so it documents this one. Comments
    # between two package declarations belong to the following declaration and
    # are intentionally not attached here.
    $cursor = $Node.NextSibling
    while ($null -ne $cursor) {
        if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
            $cursor = $cursor.NextSibling
            continue
        }

        if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace($cursor.Value)) {
            $cursor = $cursor.NextSibling
            continue
        }

        if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Comment) {
            $after = $cursor.NextSibling
            while ($null -ne $after -and (($after.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) -or ($after.NodeType -eq [System.Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace($after.Value)))) {
                $after = $after.NextSibling
            }

            if ($null -eq $after) {
                return ([string]$cursor.Value).Trim()
            }

            if ($after.NodeType -eq [System.Xml.XmlNodeType]::Element -and $after.Name -in @('PackageVersion', 'PackageReference', 'GlobalPackageReference')) {
                return $null
            }

            return ([string]$cursor.Value).Trim()
        }

        break
    }

    return $null
}
