Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NuGetVersionCache = @{}

function Get-FileLineEndingStyle {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'none' }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $crlf = 0
    $lf = 0

    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne 10) { continue }
        if ($index -gt 0 -and $bytes[$index - 1] -eq 13) {
            $crlf++
        } else {
            $lf++
        }
    }

    if ($crlf -gt 0 -and $lf -eq 0) { return 'CRLF' }
    if ($lf -gt 0 -and $crlf -eq 0) { return 'LF' }
    if ($lf -eq 0 -and $crlf -eq 0) { return 'none' }
    return 'mixed'
}

function Get-FileEncoding {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [System.Text.UTF8Encoding]::new($false)
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }

    return [System.Text.UTF8Encoding]::new($false)
}

function Write-TextPreservingEol {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('preserve', 'LF', 'CRLF')][string]$LineEnding = 'preserve'
    )

    $style = $LineEnding
    if ($style -eq 'preserve') {
        $style = 'LF'
        if (Test-Path -LiteralPath $Path) {
            $existing = Get-FileLineEndingStyle -Path $Path
            if ($existing -eq 'CRLF') {
                $style = 'CRLF'
            } elseif ($existing -eq 'mixed') {
                $style = 'LF'
            }
        }
    }

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $final = if ($style -eq 'CRLF') { $normalized -replace "`n", "`r`n" } else { $normalized }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $final, (Get-FileEncoding -Path $Path))
    return $style
}

function ConvertTo-NuGetSemVer {
    param([Parameter(Mandatory)][string]$Version)

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
    foreach ($match in [regex]::Matches($Condition, "net(\d+)(?:\.\d+)?'")) {
        $bands.Add([int]$match.Groups[1].Value)
    }

    return @($bands | Where-Object { $_ -ge 5 } | Sort-Object -Unique)
}

function Get-NuGetVersionList {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'https://api.nuget.org/v3-flatcontainer'
    )

    $base = $Source.Trim()
    $packageId = $Id.ToLowerInvariant()
    $isHttp = $base -match '^https?://'
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
            source   = $Source
            url      = $location
            error    = $null
            versions = (Sort-NuGetVersion -Version @($response.versions))
        }
    }
    catch {
        $result = [pscustomobject]@{
            id       = $Id
            found    = $false
            source   = $Source
            url      = $location
            error    = $_.Exception.Message
            versions = @()
        }
    }

    $script:NuGetVersionCache[$cacheKey] = $result
    return $result
}

function Get-AdjacentXmlComment {
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node)

    foreach ($direction in @('PreviousSibling', 'NextSibling')) {
        $cursor = $Node.$direction
        while ($null -ne $cursor) {
            if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
                $cursor = $cursor.$direction
                continue
            }

            if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Text -and [string]::IsNullOrWhiteSpace($cursor.Value)) {
                $cursor = $cursor.$direction
                continue
            }

            if ($cursor.NodeType -eq [System.Xml.XmlNodeType]::Comment) {
                return ([string]$cursor.Value).Trim()
            }

            break
        }
    }

    return $null
}
