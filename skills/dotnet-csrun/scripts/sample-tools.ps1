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

function Resolve-CsrunEngine {
    [CmdletBinding()]
    param(
        [string] $CacheDirectory,
        [ValidateRange(0, 10080)][int] $MaxAgeMinutes = 60,
        [switch] $ForceRefresh,
        [string] $ReleaseApiUrl = 'https://api.github.com/repos/codebeltnet/csrun/releases/latest'
    )
    if (-not $CacheDirectory) {
        if ($env:CSRUN_CACHE_DIR) {
            $CacheDirectory = $env:CSRUN_CACHE_DIR
        } elseif ($IsWindows) {
            $base = [Environment]::GetFolderPath('LocalApplicationData')
            if (-not $base) { throw 'LocalApplicationData is unavailable for the csrun engine cache.' }
            $CacheDirectory = Join-Path $base 'codebeltnet/csrun-cache'
        } else {
            if (-not $HOME) { throw 'HOME is unavailable for the csrun engine cache.' }
            $CacheDirectory = Join-Path $HOME '.cache/codebeltnet/csrun-cache'
        }
    }
    if (-not [IO.Path]::IsPathFullyQualified($CacheDirectory)) {
        throw "csrun engine cache directory must be an absolute path: $CacheDirectory"
    }
    $CacheDirectory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($CacheDirectory))
    $currentOwner = if ($IsWindows) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { (& id -u).Trim() }
    $windowsTrustedSids = if ($IsWindows) {
        [Collections.Generic.HashSet[string]]::new(
            [string[]]@(
                $currentOwner,
                [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null).Value,
                [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null).Value
            ),
            [StringComparer]::OrdinalIgnoreCase
        )
    } else { $null }
    $windowsWriteMask = if ($IsWindows) {
        [int64](
            [Security.AccessControl.FileSystemRights]::WriteData -bor
            [Security.AccessControl.FileSystemRights]::AppendData -bor
            [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership
        ) -bor [int64]0x10000000 -bor [int64]0x40000000
    } else { [int64]0 }

    function New-PrivateWindowsDirectorySecurity {
        $ds = [Security.AccessControl.DirectorySecurity]::new()
        $ds.SetAccessRuleProtection($true, $false)
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $prop = [Security.AccessControl.PropagationFlags]::None
        $full = [Security.AccessControl.FileSystemRights]::FullControl
        $allow = [Security.AccessControl.AccessControlType]::Allow
        foreach ($sidValue in $windowsTrustedSids) {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
            $ds.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, $full, $inherit, $prop, $allow))
        }
        return $ds
    }

    function Set-PrivateWindowsFileAcl([string] $Path) {
        $fs = [Security.AccessControl.FileSecurity]::new()
        $fs.SetAccessRuleProtection($true, $false)
        $full = [Security.AccessControl.FileSystemRights]::FullControl
        $allow = [Security.AccessControl.AccessControlType]::Allow
        foreach ($sidValue in $windowsTrustedSids) {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
            $fs.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, $full, $allow))
        }
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $fs)
    }

    function Test-PrivateWindowsAcl([string] $Path) {
        $acl = Get-Acl -LiteralPath $Path
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $currentOwner) { return $false }
        $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = $rule.IdentityReference.Value
            if ($windowsTrustedSids.Contains($sid)) { continue }
            if ($sid -eq 'S-1-3-0' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            $rights = [int64]$rule.FileSystemRights.value__
            if (($rights -band $windowsWriteMask) -ne 0) { return $false }
        }
        return $true
    }

    function Get-UnixItemMetadata([string] $Path) {
        $statArgs = if ($IsMacOS) { @('-f', '%u %l %p', $Path) } else { @('-c', '%u %h %f', '--', $Path) }
        $metadata = & stat @statArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or $metadata -notmatch '\A(\d+) (\d+) ([0-9a-f]+)\z') { return $null }
        $radix = if ($IsMacOS) { 8 } else { 16 }
        return @{ Owner = $Matches[1]; Links = [int]$Matches[2]; Mode = [Convert]::ToInt32($Matches[3], $radix) }
    }

    function Test-PrivateCachePath([string] $Path, [switch] $Directory) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.PSIsContainer -ne $Directory.IsPresent) { return $false }
        $linkProp = $item.PSObject.Properties['LinkType']
        if (($linkProp -and $linkProp.Value) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ($IsWindows) {
            try { return (Test-PrivateWindowsAcl $Path) }
            catch { return $false }
        }
        $metadata = Get-UnixItemMetadata $Path
        if (-not $metadata) { return $false }
        return $metadata.Owner -eq $currentOwner -and ($metadata.Mode -band 63) -eq 0 -and
            ($Directory -or (($metadata.Mode -band 0xF000) -eq 0x8000 -and $metadata.Links -eq 1))
    }

    if (-not (Get-Item -LiteralPath $CacheDirectory -Force -ErrorAction SilentlyContinue)) {
        if ($IsWindows) {
            $parentDir = [IO.Path]::GetDirectoryName($CacheDirectory)
            if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
                $null = [IO.Directory]::CreateDirectory($parentDir)
            }
            $null = [IO.FileSystemAclExtensions]::CreateDirectory((New-PrivateWindowsDirectorySecurity), $CacheDirectory)
        } else {
            $null = [IO.Directory]::CreateDirectory($CacheDirectory)
            & chmod 700 -- $CacheDirectory
        }
    }
    if (-not (Test-PrivateCachePath $CacheDirectory -Directory)) {
        throw "csrun engine cache directory failed ownership, ACL, or symlink checks: $CacheDirectory"
    }

    $scriptPath = Join-Path $CacheDirectory 'csrun.ps1'
    $metaPath = Join-Path $CacheDirectory 'engine.json'
    $lockPath = Join-Path $CacheDirectory 'engine.lock'
    $utf8NoBom = [Text.UTF8Encoding]::new($false)

    function Read-VerifiedCache {
        if (-not (Test-PrivateCachePath $scriptPath) -or -not (Test-PrivateCachePath $metaPath)) { return $null }
        try {
            $meta = [IO.File]::ReadAllText($metaPath) | ConvertFrom-Json -AsHashtable
            if (-not $meta -or -not $meta.ContainsKey('sha256') -or -not $meta.ContainsKey('fetchedUtc') -or -not $meta.ContainsKey('tag')) { return $null }
            $expectedSha = [string] $meta['sha256']
            if ($expectedSha -notmatch '^[0-9A-Fa-f]{64}$') { return $null }
            $fetched = [DateTimeOffset]::Parse([string] $meta['fetchedUtc'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $actualSha = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
            if ($actualSha -ine $expectedSha) { return $null }
            return [pscustomobject]@{
                Path = $scriptPath
                Tag = [string] $meta['tag']
                Sha256 = $actualSha.ToUpperInvariant()
                ETag = if ($meta.ContainsKey('etag')) { [string] $meta['etag'] } else { $null }
                DownloadUrl = if ($meta.ContainsKey('downloadUrl')) { [string] $meta['downloadUrl'] } else { $null }
                FetchedUtc = $fetched
            }
        } catch {
            return $null
        }
    }

    function Write-CacheMetadata([string] $Tag, [string] $Sha256, [string] $ETag, [string] $DownloadUrl, [DateTimeOffset] $FetchedUtc) {
        $tmpMeta = Join-Path $CacheDirectory ('engine-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $payload = [ordered]@{
                tag = $Tag
                sha256 = $Sha256.ToUpperInvariant()
                etag = $ETag
                downloadUrl = $DownloadUrl
                fetchedUtc = $FetchedUtc.ToUniversalTime().ToString('O')
            } | ConvertTo-Json -Compress
            [IO.File]::WriteAllText($tmpMeta, $payload, $utf8NoBom)
            if ($IsWindows) { Set-PrivateWindowsFileAcl $tmpMeta } else { & chmod 600 -- $tmpMeta }
            [IO.File]::Move($tmpMeta, $metaPath, $true)
        } finally {
            if (Test-Path -LiteralPath $tmpMeta) { Remove-Item -LiteralPath $tmpMeta -Force }
        }
    }

    $lockStream = $null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ($null -eq $lockStream) {
        try {
            $lockStream = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw "Timed out waiting for csrun engine cache lock: $lockPath"
            }
            Start-Sleep -Milliseconds 100
        }
    }

    $tmpScript = $null
    try {
        if ($IsWindows) { Set-PrivateWindowsFileAcl $lockPath } else { & chmod 600 -- $lockPath 2>$null }
        $now = [DateTimeOffset]::UtcNow
        $cached = Read-VerifiedCache
        if ($cached -and -not $ForceRefresh -and $MaxAgeMinutes -gt 0 -and ($now - $cached.FetchedUtc).TotalMinutes -lt $MaxAgeMinutes) {
            return [pscustomobject]@{
                Path = $cached.Path
                Tag = $cached.Tag
                Sha256 = $cached.Sha256
                FetchedUtc = $cached.FetchedUtc.ToUniversalTime().ToString('O')
                Source = 'Cache'
            }
        }

        $headers = @{ Accept = 'application/vnd.github+json' }
        if ($cached -and $cached.ETag) { $headers['If-None-Match'] = $cached.ETag }

        $response = Invoke-WebRequest -Uri $ReleaseApiUrl -Headers $headers -SkipHttpErrorCheck
        $statusCode = [int] $response.StatusCode
        $responseEtag = $null
        if ($response.Headers -and $response.Headers.ContainsKey('ETag')) {
            $responseEtag = @($response.Headers['ETag']) | Select-Object -First 1
        }

        if ($statusCode -eq 304) {
            if (-not $cached) { throw 'Received HTTP 304 Not Modified without a verified cached csrun engine.' }
            $effectiveEtag = if ($responseEtag) { $responseEtag } else { $cached.ETag }
            Write-CacheMetadata -Tag $cached.Tag -Sha256 $cached.Sha256 -ETag $effectiveEtag -DownloadUrl $cached.DownloadUrl -FetchedUtc $now
            $reverified = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
            if ($reverified -ine $cached.Sha256) { throw "Cached csrun engine checksum changed unexpectedly: $reverified" }
            return [pscustomobject]@{
                Path = $scriptPath
                Tag = $cached.Tag
                Sha256 = $reverified.ToUpperInvariant()
                FetchedUtc = $now.ToString('O')
                Source = 'NotModified'
            }
        }

        if ($statusCode -in @(403, 429)) {
            if ($cached) {
                Write-Warning "GitHub API returned HTTP $statusCode while checking csrun releases; reusing locally verified cached engine $($cached.Tag) (SHA256 $($cached.Sha256), fetched $($cached.FetchedUtc.ToUniversalTime().ToString('O')))."
                return [pscustomobject]@{
                    Path = $cached.Path
                    Tag = $cached.Tag
                    Sha256 = $cached.Sha256
                    FetchedUtc = $cached.FetchedUtc.ToUniversalTime().ToString('O')
                    Source = 'StaleCacheFallback'
                }
            }
            throw "GitHub API returned HTTP $statusCode while resolving csrun release and no verified cached engine is available."
        }

        if ($statusCode -ne 200) {
            throw "Failed to resolve csrun release from $ReleaseApiUrl (HTTP $statusCode)."
        }

        $release = $response.Content | ConvertFrom-Json
        $assets = @($release.assets | Where-Object name -CEQ 'csrun.ps1')
        if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "csrun release $($release.tag_name) must publish one csrun.ps1 asset with a SHA-256 digest."
        }
        $asset = $assets[0]
        $expectedSha = $asset.digest.Substring(7).ToUpperInvariant()

        if (-not $cached -or $cached.Sha256 -ine $expectedSha) {
            $tmpScript = Join-Path $CacheDirectory ('csrun-' + [guid]::NewGuid().ToString('N') + '.tmp')
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpScript
            $actualHash = (Get-FileHash -LiteralPath $tmpScript -Algorithm SHA256).Hash
            if ("sha256:$actualHash" -ne $asset.digest) {
                throw "csrun asset checksum mismatch: $actualHash"
            }
            if ($IsWindows) { Set-PrivateWindowsFileAcl $tmpScript } else { & chmod 600 -- $tmpScript }
            [IO.File]::Move($tmpScript, $scriptPath, $true)
            $tmpScript = $null
        }

        Write-CacheMetadata -Tag ([string] $release.tag_name) -Sha256 $expectedSha -ETag $responseEtag -DownloadUrl ([string] $asset.browser_download_url) -FetchedUtc $now
        return [pscustomobject]@{
            Path = $scriptPath
            Tag = [string] $release.tag_name
            Sha256 = $expectedSha
            FetchedUtc = $now.ToString('O')
            Source = 'GitHub'
        }
    } finally {
        if ($tmpScript -and (Test-Path -LiteralPath $tmpScript)) { Remove-Item -LiteralPath $tmpScript -Force }
        if ($lockStream) { $lockStream.Dispose() }
    }
}
