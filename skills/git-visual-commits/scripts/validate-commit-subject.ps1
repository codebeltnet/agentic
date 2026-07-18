[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Subject,

    [ValidateSet('Forbidden', 'Required')]
    [string] $PrefixMode = 'Forbidden'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$referencePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references/commit-language.md'
if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
    throw "Bundled commit-language reference is missing: $referencePath"
}

$errors = [System.Collections.Generic.List[string]]::new()
$allowedPrefixes = @('init', 'content', 'style', 'fix', 'refactor', 'docs')
$maxLength = 70
$reference = Get-Content -LiteralPath $referencePath -Raw

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

    $isApprovedEmoji = $reference.Contains("| $emoji |", [System.StringComparison]::Ordinal) -or $emoji -ceq '🎭'
    if (-not $isApprovedEmoji) {
        $errors.Add("Emoji '$emoji' is not an approved entry in the bundled commit-language reference.")
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
