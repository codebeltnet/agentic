[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Subject,

    [ValidateSet('Forbidden', 'Required')]
    [string] $PrefixMode = 'Forbidden'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = [System.Collections.Generic.List[string]]::new()
$allowedPrefixes = @('init', 'content', 'style', 'fix', 'refactor', 'docs')
$maxLength = 70
$emojiDataPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references/unicode-emoji-ranges.json'
$emojiRanges = (Get-Content -LiteralPath $emojiDataPath -Raw | ConvertFrom-Json).ranges

if ($Subject -match '[\r\n]') {
    $errors.Add('Subject must be exactly one line.')
}

if ($Subject -cne $Subject.Trim()) {
    $errors.Add('Subject must not contain leading or trailing whitespace.')
}

$subjectLength = [System.Globalization.StringInfo]::ParseCombiningCharacters($Subject).Count
if ($subjectLength -gt $maxLength) {
    $errors.Add("Subject is $subjectLength characters; the maximum is $maxLength.")
}

$description = $null
$subjectMatch = [regex]::Match($Subject, '^(?<emoji>\S+)(?<separator>\s+)(?<remainder>.*)$')
if (-not $subjectMatch.Success) {
    $errors.Add('Subject must use the exact form <emoji><one ASCII space><description>.')
}
else {
    $emoji = $subjectMatch.Groups['emoji'].Value
    $separator = $subjectMatch.Groups['separator'].Value
    $remainder = $subjectMatch.Groups['remainder'].Value

    # Unicode Emoji property data distinguishes emoji bases from ordinary symbols.
    # ASCII keycap bases need their enclosing keycap; they are not emoji alone.
    $hasEmojiBase = $false
    foreach ($rune in $emoji.EnumerateRunes()) {
        if ($rune.Value -le 0x39) { continue }
        foreach ($range in $emojiRanges) {
            if ($rune.Value -ge $range[0] -and $rune.Value -le $range[1]) {
                $hasEmojiBase = $true
                break
            }
        }
    }
    $isSingleEmoji = [System.Globalization.StringInfo]::ParseCombiningCharacters($emoji).Count -eq 1 -and
        ($hasEmojiBase -or $emoji -match '^[0-9#*]\uFE0F?\u20E3$')
    if (-not $isSingleEmoji) {
        $errors.Add('Subject must begin with one Unicode emoji sequence, not text, a shortcode, an ordinary symbol, or multiple emoji.')
    }

    if ($separator -cne ' ') {
        $errors.Add('Use exactly one ASCII space between the emoji and the following text.')
    }

    if ($PrefixMode -eq 'Forbidden') {
        $description = $remainder
        if ($remainder -cmatch '^[a-z]+:\s') {
            $errors.Add('A conventional prefix is forbidden unless the user explicitly requested combo mode.')
        }
    }
    else {
        $prefixMatch = [regex]::Match($remainder, '^(?<prefix>[a-z]+): (?<description>.+)$')
        if (-not $prefixMatch.Success) {
            $errors.Add('Combo mode requires <emoji><space><allowed-lowercase-prefix>:<space><description>.')
        }
        else {
            $prefix = $prefixMatch.Groups['prefix'].Value
            $description = $prefixMatch.Groups['description'].Value
            if ($allowedPrefixes -cnotcontains $prefix) {
                $errors.Add("Prefix '${prefix}:' is not allowed. Allowed prefixes: $($allowedPrefixes -join ', ').")
            }
        }
    }
}

if ($null -ne $description) {
    if ([string]::IsNullOrWhiteSpace($description)) {
        $errors.Add('Description is required.')
    }
    elseif ($description -cnotmatch '^\p{Ll}') {
        $errors.Add('Description must begin with a lowercase letter.')
    }
}

if ($errors.Count -gt 0) {
    throw ($errors -join [Environment]::NewLine)
}

[pscustomobject]@{
    Valid      = $true
    Subject    = $Subject
    Emoji      = $emoji
    Length     = $subjectLength
    MaxLength  = $maxLength
    PrefixMode = $PrefixMode
} | ConvertTo-Json
