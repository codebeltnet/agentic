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

    # Check structure, not membership in a curated table. Unicode symbols cover
    # emoji bases; one grapheme also permits flags, modifiers, ZWJ and keycaps.
    $hasSymbol = $false
    foreach ($rune in $emoji.EnumerateRunes()) {
        if ([System.Text.Rune]::GetUnicodeCategory($rune) -in @('OtherSymbol', 'MathSymbol', 'ModifierSymbol')) {
            $hasSymbol = $true
        }
    }
    $isSingleSymbol = [System.Globalization.StringInfo]::ParseCombiningCharacters($emoji).Count -eq 1 -and
        ($hasSymbol -or $emoji -match '^[0-9#*]\uFE0F?\u20E3$')
    if (-not $isSingleSymbol) {
        $errors.Add('Subject must begin with one Unicode emoji or symbol sequence, not text, a shortcode, or multiple emoji.')
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
