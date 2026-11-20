#requires -Version 7.0
# Dot-source these artifact helpers. They do not validate manifests or execute samples.
Set-StrictMode -Version Latest

$script:CsrunTestVerificationTemplate = @'
function Assert-CsrunTestOutput([string] $Output) {
    $lines = @($Output -split '\r?\n')
    $headers = @($lines | Where-Object { $_ -match '^Test run summary: Passed! - .+\)$' })
    if ($headers.Count -ne 1) { throw 'Expected exactly one completed xUnit test summary.' }
    $headerIndex = [Array]::IndexOf($lines, $headers[0])
    $summaryLines = @($lines | Select-Object -Skip ($headerIndex + 1) -First 4)
    $counts = @{}
    foreach ($line in $summaryLines) {
        if ($line -match '^\s*(total|failed|succeeded|skipped):\s*(\d+)\s*$') { $counts[$Matches[1]] = [int]$Matches[2] }
    }
    if ($counts.Count -ne 4) { throw 'The xUnit test summary counts are incomplete or ambiguous.' }
    $failed = $counts.failed
    $passed = $counts.succeeded
    $skipped = $counts.skipped
    $total = $counts.total
    if ($total -lt 1 -or $passed -lt 1 -or $failed -ne 0 -or $skipped -ne 0 -or $passed -ne $total) {
        throw 'Tests must execute at least once, all pass, and none fail or skip.'
    }
}
'@

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
    $verifyTests = (ConvertFrom-Json -InputObject $identity.ManifestJson).mode -eq 'test'
    function Quote-Literal([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }
    # JSON serialization escapes embedded newlines, so source cannot terminate this here-string.
    $prefix = "#requires -Version 7.0`n`$ErrorActionPreference = 'Stop'`n`$PSNativeCommandUseErrorActionPreference = `$false`n`$manifest = @'`n" + $identity.ManifestJson + "`n'@`n"
    $suffix = @'
if ($process.ExitCode -ne 0) { throw "csrun execution failed with exit code $($process.ExitCode). $diagnostics" }
if ($verifyTests) { Assert-CsrunTestOutput $output }
'@
    $engineSetup = if ($EnginePath) {
        '$enginePath = ' + (Quote-Literal ([IO.Path]::GetFullPath($EnginePath))) + "`nif (-not (Test-Path -LiteralPath `$enginePath -PathType Leaf)) { throw 'csrun engine asset not found.' }"
    } else {
        @'
# Downloads and executes the latest stable csrun release with your permissions.
# Source and release history: https://github.com/codebeltnet/csrun
$engineDirectory = Join-Path ([IO.Path]::GetTempPath()) ('csrun-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $engineDirectory
$enginePath = Join-Path $engineDirectory 'csrun.ps1'
$process = $null
try {
    $release = Invoke-RestMethod 'https://api.github.com/repos/codebeltnet/csrun/releases/latest'
    $assets = @($release.assets | Where-Object name -CEQ 'csrun.ps1')
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "csrun release $($release.tag_name) must publish one csrun.ps1 asset with a SHA-256 digest."
    }
    $asset = $assets[0]
    Invoke-WebRequest $asset.browser_download_url -OutFile $enginePath
    $actualHash = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
    if ("sha256:$actualHash" -ne $asset.digest) { throw "csrun asset checksum mismatch: $actualHash" }
'@
    }
    $nativeInvoke = @'
$startInfo = [Diagnostics.ProcessStartInfo]::new('pwsh')
foreach ($argument in @('-NoProfile','-NonInteractive','-File')) { $startInfo.ArgumentList.Add($argument) }
$startInfo.ArgumentList.Add($enginePath)
$startInfo.ArgumentList.Add('-ManifestJson')
$startInfo.ArgumentList.Add($manifest)
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.UseShellExecute = $false
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) { throw 'Could not start csrun.' }
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$output = $stdoutTask.GetAwaiter().GetResult()
$diagnostics = $stderrTask.GetAwaiter().GetResult()
Write-Output $output
if ($diagnostics) { [Console]::Error.Write($diagnostics) }
'@
    # The image supplies the SDK and PowerShell. Execute the same release asset as Native.
    $dockerInvoke = @'
$enginePayload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($enginePath))
$containerInput = $enginePayload + "`n" + $manifest
$command = '
$ErrorActionPreference = "Stop"
$enginePath = Join-Path ([IO.Path]::GetTempPath()) ("csrun-release-" + [guid]::NewGuid().ToString("N") + ".ps1")
$engineBytes = [Convert]::FromBase64String([Console]::In.ReadLine())
[IO.File]::WriteAllBytes($enginePath, $engineBytes)
$manifest = [Console]::In.ReadToEnd()
& $enginePath -ManifestJson $manifest
exit $LASTEXITCODE
'
$output = (@($containerInput | & docker run --rm -i --entrypoint pwsh __IMAGE__ -NoProfile -NonInteractive -Command $command) -join [Environment]::NewLine)
$process = [pscustomobject]@{ ExitCode = $LASTEXITCODE }
$diagnostics = ''
Write-Output $output
'@
    $dockerInvoke = $dockerInvoke.Replace('__IMAGE__', (Quote-Literal $Image))
    $engineCleanup = if (-not $EnginePath) {
        @'
} catch {
    [Console]::Error.WriteLine("csrun diagnostics retained in: $engineDirectory")
    throw
} finally {
    $resolvedTemp = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $resolvedEngineDirectory = [IO.Path]::GetFullPath($engineDirectory)
    if ([IO.Path]::GetDirectoryName($resolvedEngineDirectory) -ne $resolvedTemp -or
        [IO.Path]::GetFileName($resolvedEngineDirectory) -cnotmatch '^csrun-[a-f0-9]{32}$') { throw 'Unsafe cleanup path.' }
    if ($process -and $process.ExitCode -eq 0) { Remove-Item -LiteralPath $resolvedEngineDirectory -Recurse -Force }
}
'@
    }
    $encoding = '$OutputEncoding = [Text.UTF8Encoding]::new($false)' + "`n" + '[Console]::OutputEncoding = $OutputEncoding' + "`n"
    $native = $prefix + $encoding + '$verifyTests = $' + $verifyTests.ToString().ToLowerInvariant() + "`n" + $script:CsrunTestVerificationTemplate + "`n" + $engineSetup + "`n" + $nativeInvoke + "`n" + $engineCleanup + "`n" + $suffix
    $docker = $prefix + $encoding + '$verifyTests = $' + $verifyTests.ToString().ToLowerInvariant() + "`n" + $script:CsrunTestVerificationTemplate + "`n" + $engineSetup + "`n" + $dockerInvoke + "`n" + $engineCleanup + "`n" + $suffix
    # PowerShell's interactive parser buffers an incomplete script block. Keep all
    # execution and post-execution checks inside the same complete paste unit.
    $native = "& {`n" + $native.TrimEnd() + "`n}`n"
    $docker = "& {`n" + $docker.TrimEnd() + "`n}`n"
    [pscustomobject]@{
        SourceSha256 = $identity.SourceSha256
        ManifestSha256 = $identity.ManifestSha256
        ManifestJson = $identity.ManifestJson
        Native = $native
        Docker = $docker
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
