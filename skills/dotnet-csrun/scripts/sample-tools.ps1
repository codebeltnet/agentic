#requires -Version 7.0
# Dot-source these artifact helpers. They do not validate manifests or execute samples.
Set-StrictMode -Version Latest

function Get-CsrunSampleIdentity {
    param([Parameter(Mandatory)][string] $ManifestJson)
    $item = ConvertFrom-Json -InputObject $ManifestJson -AsHashtable
    if ($item.source -isnot [string]) { throw 'A manifest source string is required for identity.' }
    # Sort object keys recursively; preserve arrays, source text, and every manifest value.
    function Sort-ManifestValue($Value) {
        if ($Value -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            [string[]] $keys = @($Value.Keys)
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            foreach ($key in $keys) {
                $ordered[$key] = Sort-ManifestValue $Value[$key]
            }
            return $ordered
        }
        if ($Value -is [array]) { return ,@($Value | ForEach-Object { Sort-ManifestValue $_ }) }
        return $Value
    }
    $ordered = Sort-ManifestValue $item
    $canonical = ConvertTo-Json -InputObject $ordered -Depth 100 -Compress
    function Get-TextHash([string] $Value) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    [pscustomobject]@{
        Source = $item.source
        SourceSha256 = Get-TextHash $item.source
        ManifestSha256 = Get-TextHash $canonical
        ManifestJson = ConvertTo-Json -InputObject $ordered -Depth 100
    }
}

function New-CsrunExecutionPair {
    param(
        [Parameter(Mandatory)][string] $ManifestJson,
        # Caller verifies the published image/tag, compatibility, and provenance before delivery.
        [Parameter(Mandatory)][string] $Image,
        [string] $EnginePath
    )
    $identity = Get-CsrunSampleIdentity $ManifestJson
    function Quote-Literal([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }
    # JSON serialization escapes embedded newlines, so source cannot terminate this here-string.
    $prefix = "#requires -Version 7.0`n`$ErrorActionPreference = 'Stop'`n`$PSNativeCommandUseErrorActionPreference = `$false`n`$manifest = @'`n" + $identity.ManifestJson + "`n'@`n"
    $suffix = @'
$code = $LASTEXITCODE
if ($code -ne 0) { throw "csrun execution failed with exit code $code." }
'@
    $nativeCommand = if ($EnginePath) {
        '& pwsh -NoProfile -NonInteractive -File ' + (Quote-Literal $EnginePath) + ' -ManifestJson $manifest'
    } else {
        @'
# Trust warning: downloads and executes publisher code with your permissions. Review before running.
# releases/latest is mutable; retain a reviewed release asset/hash for reproducibility.
$engine = Invoke-RestMethod 'https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1'
& ([scriptblock]::Create($engine)) -ManifestJson $manifest
'@
    }
    $dockerCommand = '$manifest | docker run --rm -i ' + (Quote-Literal $Image)
    $encoding = '$OutputEncoding = [Text.UTF8Encoding]::new($false)' + "`n" + '[Console]::OutputEncoding = $OutputEncoding' + "`n"
    [pscustomobject]@{
        SourceSha256 = $identity.SourceSha256
        ManifestSha256 = $identity.ManifestSha256
        ManifestJson = $identity.ManifestJson
        Native = $prefix + $encoding + $nativeCommand + "`n" + $suffix
        Docker = $prefix + $encoding + $dockerCommand + "`n" + $suffix
    }
}

function Get-CsrunWrapperManifest {
    param([Parameter(Mandatory)][string] $Block)
    # Inspect only a literal assignment in a generated block; never evaluate supplied PowerShell.
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Block, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw 'PowerShell block has syntax errors.' }
    $assignments = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ceq 'manifest'
    }, $true))
    if ($assignments.Count -ne 1) { throw 'Expected one literal manifest assignment; inspect other wrapper formats manually.' }
    $literal = $assignments[0].Right.Find({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst]
    }, $false)
    if (-not $literal -or $assignments[0].Right.Extent.Text -cne $literal.Extent.Text) {
        throw 'Manifest must be a single string literal; no expressions are evaluated.'
    }
    $literal.Value
}

function Set-CsrunSourceRegion {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $Start,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedSource,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ReplacementSource
    )
    # The agent selects the exact region after inspecting context; this is not a Markdown parser.
    # Use only for an authorized repair. Unknown encodings must be handled explicitly elsewhere.
    $full = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [IO.File]::ReadAllBytes($full)
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.UTF8Encoding]::new($false, $true), $true)
    try { $text = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
    if ($Start -lt 0 -or $Start + $ExpectedSource.Length -gt $text.Length -or
        $text.Substring($Start, $ExpectedSource.Length) -cne $ExpectedSource) {
        throw 'Source region changed; inspect again before repair.'
    }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($text.Replace("`r`n", '').Contains("`n") -and $text.Contains("`r`n")) {
        throw 'Mixed line endings require an explicit localized edit.'
    }
    $replacement = $ReplacementSource.Replace("`r`n", "`n").Replace("`n", $newline)
    $updated = $text.Substring(0, $Start) + $replacement + $text.Substring($Start + $ExpectedSource.Length)
    $preamble = $encoding.GetPreamble()
    $hasPreamble = $preamble.Length -gt 0 -and $bytes.Length -ge $preamble.Length -and
        [Convert]::ToBase64String($preamble) -ceq [Convert]::ToBase64String([byte[]] $bytes[0..($preamble.Length - 1)])
    $output = $encoding.GetBytes($updated)
    if ($hasPreamble) { $output = [byte[]] ($preamble + $output) }
    # Fail before writing if decoding/encoding would change any original byte.
    $roundTrip = $encoding.GetBytes($text)
    if ($hasPreamble) { $roundTrip = [byte[]] ($preamble + $roundTrip) }
    if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($roundTrip)) { throw 'Encoding is not losslessly supported.' }
    [IO.File]::WriteAllBytes($full, $output)
}
