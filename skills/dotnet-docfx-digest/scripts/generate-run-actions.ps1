#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoRoot,
    [string] $Docfx,
    [string] $Settings,
    [string] $Framework = 'net10.0',
    [string] $CsrunImage = 'codebeltnet/csrun:10',
    [ValidateSet('None','Native','Docker','Both')][string] $Verify = 'None'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'integration-example.ps1')
$helpers = Join-Path $PSScriptRoot '../../dotnet-csrun/scripts/sample-tools.ps1'
if (-not (Test-Path $helpers)) { throw "Install dotnet-csrun beside this skill: $helpers" }
. $helpers
Set-StrictMode -Off
function Hash([string] $Text) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))) }
function Normalize([string] $Text) { $Text.Replace("`r`n", "`n").TrimEnd("`n", "`r") }
function Write-Changed([string] $Path, [string] $Text) {
    Assert-RepositoryPath $Path
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $Text) { return $false }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    return $true
}
# Preserve the original encoding/BOM and line endings when adding/removing owned HTML.
function Write-Page([string] $Path, [string] $Original, [string] $Updated) {
    if ($Original -ceq $Updated) { return }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $reader = [IO.StreamReader]::new($Path, [Text.UTF8Encoding]::new($false, $true), $true)
    try { $null = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
    $output = $encoding.GetBytes($Updated)
    $preamble = $encoding.GetPreamble()
    if ($preamble.Length -and $bytes.Length -ge $preamble.Length -and
        [Convert]::ToBase64String($bytes[0..($preamble.Length-1)]) -ceq [Convert]::ToBase64String($preamble)) { $output = [byte[]]($preamble + $output) }
    [IO.File]::WriteAllBytes($Path, $output)
}
$root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RepoRoot))
$rootPrefix = $root
if (-not [IO.Path]::EndsInDirectorySeparator($rootPrefix)) { $rootPrefix += [IO.Path]::DirectorySeparatorChar }
function Assert-RepositoryPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    # Require exact casing even on filesystems that accept aliases for the same path.
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::Ordinal)) { throw "Path outside requested repository: $Path" }
    for ($current = $full; $current.Length -gt $root.Length; $current = Split-Path $current -Parent) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked output path: $current" }
    }
}
$arguments = @('--repo-root', $root, '--run-action-inventory')
if ($Docfx) { $arguments += @('--docfx', $Docfx) }
# One inventory process per repository, never one model/process per document.
$inventoryText = & dotnet run --file (Join-Path $PSScriptRoot 'docfx.cs') -- @arguments
if ($LASTEXITCODE -ne 0) { throw 'DocFX example inventory failed.' }
$inventory = ($inventoryText -join "`n") | ConvertFrom-Json
$configPath = $inventory.config
$workspace = Split-Path $configPath -Parent
Assert-RepositoryPath $configPath
$assetRoot = Join-Path $workspace 'run-actions'
Assert-RepositoryPath $assetRoot
$indexPath = Join-Path $assetRoot 'index.json'
$old = @()
if (Test-Path $indexPath) { $old = @((Get-Content $indexPath -Raw | ConvertFrom-Json).examples) }
$recipes = @()
if (-not $Settings) { $Settings = Join-Path $workspace 'run-actions.settings.json' }
if (Test-Path $Settings) { $recipes = @((Get-Content $Settings -Raw | ConvertFrom-Json).examples) }
$toolHash = Hash ((Get-Content $PSCommandPath -Raw) + (Get-Content (Join-Path $PSScriptRoot 'docfx.cs') -Raw) + (Get-Content (Join-Path $PSScriptRoot 'integration-example.ps1') -Raw) + (Get-Content $helpers -Raw) + $script:Csrun021Asset + $script:Csrun021Sha256 + $script:CsrunTestVerificationTemplate)
$results = [Collections.Generic.List[object]]::new()
$associations = [hashtable]::new([StringComparer]::Ordinal)
$previousPages = foreach ($entry in $old) {
    if (-not $entry.file) { continue }
    $path = [IO.Path]::GetFullPath($entry.file, $root)
    # Legacy indexes stored absolute paths. After moving the checkout, only current
    # inventory paths and prior paths inside this checkout can own associations.
    if ($path.StartsWith($rootPrefix, [StringComparison]::Ordinal)) { $path }
}
$pages = @(@($inventory.examples.file) + @($previousPages) | Where-Object { $_ } | Sort-Object -CaseSensitive -Unique)
foreach ($page in $pages) { Assert-RepositoryPath $page }
$oldByFingerprint = @{}
foreach ($entry in $old) {
    if ($entry.fingerprint) { $oldByFingerprint["$($entry.id)|$($entry.fingerprint)"] = $entry }
}
$recipeBySource = [hashtable]::new([StringComparer]::Ordinal)
foreach ($recipe in $recipes) {
    $key = "$($recipe.uid)|$($recipe.sourceSha256.ToUpperInvariant())"
    if ($recipeBySource.ContainsKey($key)) { throw "Duplicate recipe for $key" }
    $recipeBySource[$key] = $recipe
}
foreach ($example in $inventory.examples) {
    $displayedSource = Normalize $example.code
    $source = $displayedSource
    if ($example.source) { $source = Normalize (($source -split "`n" | Select-Object -Skip 2) -join "`n") }
    $sourceHash = Hash $source
    $identity = if ($example.source) { [IO.Path]::GetRelativePath($root, $example.source).Replace('\','/') + '|' + $sourceHash } else { $sourceHash }
    $id = (Hash ("$($example.uid)|$([IO.Path]::GetRelativePath($root, $example.file).Replace('\','/'))|$identity")).Substring(0,24).ToLowerInvariant()
    $result = [ordered]@{ id=$id; file=$example.file; uid=$example.uid; sourceSha256=$sourceHash; status='unresolved'; coverage='Unresolved'; reason=$null; native='Unverified'; docker='Unverified' }
    try {
        if ($example.contextError) { $result.reason = $example.contextError; continue }
        if ($example.sourceSha256 -and $example.sourceSha256 -cne $sourceHash) { throw 'The inventory and generator disagree on the displayed source hash.' }

        $recipe = $recipeBySource["$($example.uid)|$sourceHash"]
        if ($recipe -and $recipe.PSObject.Properties['harness']) {
            throw 'Move the executable C# into the displayed sample and update its recipe hash.'
        }
        $strategy = 'standalone'
        # Known, inspected integration source. No API-name heuristic may substitute a different test.
        if (-not $recipe -and $sourceHash -ceq '47B0C1FBA94E7B43C8753D0A8242801B328E6B463B6EEDAEB640D4F8A262633E') {
            $recipe = [pscustomobject]@{ repository='codebeltnet/xunit'; commit='84b13767cb9484f8f3a36a71875662edfdb3e511'; project='test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj'; test='Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorkerApplicationTestTest.ShouldBootstrapMinimalWorkerProgram'; framework='net11.0'; image='mcr.microsoft.com/dotnet/sdk:11.0' }
        }
        $isTest = $example.isTest
        if ($recipe.intrinsicLimitation) {
            if ($recipe.manifest -or $recipe.repository) { throw 'An intrinsic limitation cannot also supply an execution recipe.' }
            $result.status = 'unsupported'; $result.coverage = 'Intrinsically non-executable'; $result.reason = $recipe.intrinsicLimitation
            $result.native = 'Unsupported'; $result.docker = 'Unsupported'
            continue
        }
        if ($recipe -and $recipe.PSObject.Properties['repository']) { $strategy = 'repository' }
        elseif ($example.source -and -not ($recipe -and $recipe.PSObject.Properties['manifest'])) {
            $result.reason = 'Inspect the maintained project and source for exact published dependencies or a pinned repository test.'
            continue
        }
        elseif (-not $recipe -and (-not $example.eligible -or $example.standalone -eq $isTest -or $source -match '(?m)^#:')) {
            $result.reason = 'Resolve the dependencies and entry point from the source project, published assets, and maintained tests.'
            continue
        }
        if ($recipe -and -not $recipe.manifest -and $strategy -ne 'repository') { throw 'A recipe must supply a standalone manifest or a pinned repository test.' }
        $transports = @('native','docker')
        foreach ($transport in @('native','docker')) {
            if ($recipe -and $recipe.unsupportedTransports.$transport) {
                $result[$transport] = 'Unsupported'
                $result["${transport}Reason"] = $recipe.unsupportedTransports.$transport
                $transports = @($transports | Where-Object { $_ -ne $transport })
            }
        }
        if (-not $transports.Count) {
            $result.status = 'unsupported'; $result.coverage = 'Intrinsically non-executable'
            $result.reason = "Native: $($result.nativeReason) Docker: $($result.dockerReason)"
            continue
        }
        $result.strategy = $strategy
        if ($strategy -eq 'standalone') { $result.executionSourceSha256 = Hash $displayedSource }
        $image = if ($recipe.csrunImage) { $recipe.csrunImage } else { $CsrunImage }
        $fingerprint = Hash ("$toolHash|$sourceHash|$strategy|$Framework|$image|$($result.executionSourceSha256)|" + ($recipe | ConvertTo-Json -Depth 30 -Compress))
        $prior = @($oldByFingerprint["$id|$fingerprint"] | Where-Object { $null -ne $_ })
        $dir = Join-Path $assetRoot $id
        $reusable = $prior.Count -eq 1
        foreach ($transport in $transports) {
            $path = Join-Path $dir "$transport.ps1"
            if (-not (Test-Path $path) -or -not $reusable -or (Hash ([IO.File]::ReadAllText($path))) -cne $prior[0]."${transport}Sha256") { $reusable = $false }
        }
        if ($reusable) {
            $pair = @{}
            foreach ($transport in $transports) {
                $pair[$transport] = [IO.File]::ReadAllText((Join-Path $dir "$transport.ps1"))
                if ($prior[0]."${transport}Evidence") { $result["${transport}Evidence"] = $prior[0]."${transport}Evidence" }
            }
            $result.native = $prior[0].native; $result.docker = $prior[0].docker
        } elseif ($strategy -eq 'repository') {
            $pair = New-RepositoryExamplePair -Repository $recipe.repository -Commit $recipe.commit -Project $recipe.project -Test $recipe.test -Framework $recipe.framework -Image $recipe.image
        } else {
            $manifest = if ($recipe) { $recipe.manifest | Select-Object * } else { [pscustomobject]@{ schemaVersion=1; mode=$(if ($isTest) {'test'} else {'console'}); framework=$Framework; dependsOn=@($(if ($isTest) {'xunit.v3@4.0.3'})) } }
            if ($manifest.PSObject.Properties['source'] -and (Normalize $manifest.source) -cne $displayedSource) { throw 'Manifest source differs from displayed C#.' }
            $manifest | Add-Member -NotePropertyName source -NotePropertyValue $displayedSource -Force
            $pair = New-CsrunExecutionPair -ManifestJson ($manifest | ConvertTo-Json -Depth 30) -Image $image
        }
        $changed = $false
        foreach ($transport in $transports) {
            $script = Normalize $pair.$transport
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseInput($script,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "Generated $transport script has syntax errors: $errors" }
            $path = Join-Path $dir "$transport.ps1"
            $changed = (Write-Changed $path $script) -or $changed
            $result["${transport}Sha256"] = Hash $script
            if ($Verify -eq 'Both' -or $Verify -eq $transport) {
                $log = Join-Path ([IO.Path]::GetTempPath()) ("docfx-run-$id-$transport-" + [guid]::NewGuid().ToString('N') + '.log')
                & pwsh -NoProfile -NonInteractive -File $path *> $log
                $result[$transport] = if ($LASTEXITCODE -eq 0) { 'Verified' } else { 'Failed' }
                $result["${transport}Evidence"] = $log
            }
        }
        $result.status = if ($changed) { 'generated' } else { 'unchanged' }
        $result.coverage = if ($transports.Count -eq 2) { 'Paired' } else { 'Partially supported' }
        if ($recipe.explanation) { $result.explanation = $recipe.explanation }
        $result.fingerprint = $fingerprint
        $links = @($transports | ForEach-Object {
            $label = if ($_ -eq 'native') { 'Native' } else { 'Docker' }
            '<a href="~/run-actions/' + $id + '/' + $_ + '.ps1" data-transport="' + $_ + '">View ' + $label + ' Script</a>'
        })
        $note = if ($strategy -eq 'repository') { '<p>Runs the pinned repository test <code>' + [Net.WebUtility]::HtmlEncode($recipe.test) + '</code>.</p>' } else { '' }
        $note += if ($recipe.explanation) { '<p>' + [Net.WebUtility]::HtmlEncode($recipe.explanation) + '</p>' } else { '' }
        $link = '<div class="docfx-run-actions" data-example-id="' + $id + '">' + ($links -join ' · ') + $note + '</div>'
        if (-not $associations.ContainsKey($example.file)) { $associations[$example.file] = @{} }
        $associations[$example.file][[int]$example.startLine] = "<!-- docfx-run-actions:start -->`n$link`n<!-- docfx-run-actions:end -->"
    } catch { $result.status='failed'; $result.reason=$_.Exception.Message }
    finally { $results.Add([pscustomobject]$result) }
}
# Apply edits by offset in the original text so each existing line ending is preserved.
foreach ($page in $pages) {
    if (-not (Test-Path -LiteralPath $page)) { continue }
    $original = [IO.File]::ReadAllText($page)
    $edits = [Collections.Generic.List[object]]::new()
    foreach ($block in [regex]::Matches($original, '(?s)(?:\r\n|\n|\r){2}<!-- docfx-run-actions:start -->.*?<!-- docfx-run-actions:end -->')) {
        $edits.Add(@{ Offset = $block.Index; Length = $block.Length; Text = '' })
    }
    if ($associations.ContainsKey($page)) {
        $lines = [regex]::Matches($original, '(?<text>[^\r\n]*)(?<ending>\r\n|\n|\r|$)')
        foreach ($line in $associations[$page].Keys) {
            $end = $line
            while ($end -lt $lines.Count -and $lines[$end].Groups['text'].Value -notmatch '^\s*```') { $end++ }
            if ($end -ge $lines.Count) { throw "Unclosed fence in $page" }
            $fence = $lines[$end]
            $newline = $fence.Groups['ending'].Value
            if (-not $newline) { $newline = $lines[$end - 1].Groups['ending'].Value }
            $edits.Add(@{
                Offset = $fence.Index + $fence.Groups['text'].Length
                Length = 0
                Text = $newline + $newline + $associations[$page][$line].Replace("`n", $newline)
            })
        }
    }
    $updated = $original
    # At a shared offset remove the previous association before inserting its replacement.
    foreach ($edit in $edits | Sort-Object -Property Offset, Length -Descending) {
        $updated = $updated.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.Text)
    }
    Write-Page $page $original $updated
}
# Remove only assets owned by the previous index. Never recursively delete user directories.
foreach ($entry in $results) {
    foreach ($transport in @('native','docker')) {
        if ($entry.$transport -eq 'Unsupported' -and $entry.id -match '^[a-f0-9]{24}$') {
            $path = Join-Path $assetRoot "$($entry.id)/$transport.ps1"
            Assert-RepositoryPath $path
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
    }
}
$active = @($results | Where-Object { $_.status -in @('generated','unchanged') } | ForEach-Object id)
foreach ($previous in $old) {
    if ($previous.id -match '^[a-f0-9]{24}$' -and $previous.id -notin $active) {
        foreach ($name in @('native.ps1','docker.ps1')) {
            $path = Join-Path $assetRoot "$($previous.id)/$name"
            Assert-RepositoryPath $path
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
    }
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
if (-not $config.build) { throw 'docfx.json requires build configuration.' }
$resources = @($config.build.resource)
if (-not @($resources | Where-Object { ($_ | ConvertTo-Json -Compress) -match 'run-actions/\*\*' }).Count) {
    $config.build.resource = @($resources | Where-Object { $null -ne $_ }) + @(@{ files=@('run-actions/**') })
}
# Compose with an existing modern main.js rather than overriding its default export/start hook (e.g. Context7).
$templates = @($config.build.template)
$main = $null
foreach ($template in $templates) {
    $candidate = Join-Path $workspace "$template/public/main.js"
    if (Test-Path $candidate) { $main=$candidate }
}
if (-not $main) {
    $main = Join-Path $workspace 'run-actions-template/public/main.js'
    $null = Write-Changed $main "export default {};`n"
    if ('run-actions-template' -notin $templates) { $config.build.template = $templates + @('run-actions-template') }
}
Assert-RepositoryPath $main
$mainText = [IO.File]::ReadAllText($main)
if (-not $mainText.Contains("import './run-actions.js';")) { $null = Write-Changed $main ($mainText + "`nimport './run-actions.js';`n") }
$null = Write-Changed (Join-Path (Split-Path $main -Parent) 'run-actions.js') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/run-actions.js')))
$null = Write-Changed $configPath (($config | ConvertTo-Json -Depth 100) + "`n")
$persisted = @($results | ForEach-Object {
    $entry = $_ | Select-Object *
    $entry.file = [IO.Path]::GetRelativePath($root, $entry.file).Replace('\','/')
    if ($entry.status -in @('generated','unchanged')) { $entry.status = 'ready' }
    $entry
})
$null = Write-Changed $indexPath (([ordered]@{ examples=$persisted } | ConvertTo-Json -Depth 30) + "`n")
if ($results.Count) { $results | ConvertTo-Json -Depth 30 } else { '[]' }
if (@($results | Where-Object { $_.status -eq 'failed' -or $_.native -eq 'Failed' -or $_.docker -eq 'Failed' }).Count) { exit 1 }
if (@($results | Where-Object coverage -eq 'Unresolved').Count) { exit 2 }
