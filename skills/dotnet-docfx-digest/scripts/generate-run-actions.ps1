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
$manifestPath = Join-Path $workspace 'run-actions.manifest.json'
$oldManifestById = @{}
if (Test-Path -LiteralPath $manifestPath) {
    $oldManifestDoc = Get-Content $manifestPath -Raw | ConvertFrom-Json
    foreach ($entry in @($oldManifestDoc.examples)) {
        if ($entry.id) { $oldManifestById[$entry.id] = ($entry | ConvertTo-Json -Depth 30 -Compress) }
    }
}
$recipes = @()
if (-not $Settings) { $Settings = Join-Path $workspace 'run-actions.settings.json' }
if (Test-Path $Settings) { $recipes = @((Get-Content $Settings -Raw | ConvertFrom-Json).examples) }
$toolHash = Hash ((Get-Content $PSCommandPath -Raw) + (Get-Content (Join-Path $PSScriptRoot 'docfx.cs') -Raw) + (Get-Content (Join-Path $PSScriptRoot 'integration-example.ps1') -Raw) + (Get-Content $helpers -Raw) + $script:Csrun021Asset + $script:Csrun021Sha256 + $script:CsrunTestVerificationTemplate)
$results = [Collections.Generic.List[object]]::new()
$manifestEntries = [Collections.Generic.List[object]]::new()
$associations = [hashtable]::new([StringComparer]::Ordinal)
$pages = @(@($inventory.examples.file) | Where-Object { $_ } | Sort-Object -CaseSensitive -Unique)
foreach ($page in $pages) { Assert-RepositoryPath $page }
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
        $manifestObject = $null
        if ($strategy -eq 'standalone') {
            $manifestObject = if ($recipe) { $recipe.manifest | Select-Object * } else { [pscustomobject]@{ schemaVersion=1; mode=$(if ($isTest) {'test'} else {'console'}); framework=$Framework; dependsOn=@($(if ($isTest) {'xunit.v3@4.0.3'})) } }
            if ($manifestObject.PSObject.Properties['source'] -and (Normalize $manifestObject.source) -cne $displayedSource) { throw 'Manifest source differs from displayed C#.' }
            $manifestObject | Add-Member -NotePropertyName source -NotePropertyValue $displayedSource -Force
        }
        if ($strategy -eq 'repository') {
            $pair = New-RepositoryExamplePair -Repository $recipe.repository -Commit $recipe.commit -Project $recipe.project -Test $recipe.test -Framework $recipe.framework -Image $recipe.image
        } else {
            $pair = New-CsrunExecutionPair -ManifestJson ($manifestObject | ConvertTo-Json -Depth 30) -Image $image
        }
        foreach ($transport in $transports) {
            $script = Normalize $pair.$transport
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseInput($script,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "Generated $transport script has syntax errors: $errors" }
            $result["${transport}Sha256"] = Hash $script
            if ($Verify -eq 'Both' -or $Verify -eq $transport) {
                $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("docfx-run-$id-$transport-" + [guid]::NewGuid().ToString('N') + '.ps1')
                $log = Join-Path ([IO.Path]::GetTempPath()) ("docfx-run-$id-$transport-" + [guid]::NewGuid().ToString('N') + '.log')
                try {
                    [IO.File]::WriteAllText($tempScript, $script, [Text.UTF8Encoding]::new($false))
                    & pwsh -NoProfile -NonInteractive -File $tempScript *> $log
                    $result[$transport] = if ($LASTEXITCODE -eq 0) { 'Verified' } else { 'Failed' }
                    $result["${transport}Evidence"] = $log
                } finally {
                    if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force }
                }
            }
        }
        $manifestEntry = if ($strategy -eq 'repository') {
            [ordered]@{
                id = $id
                strategy = 'repository'
                transports = @($transports)
                repository = $recipe.repository
                commit = $recipe.commit
                project = $recipe.project
                test = $recipe.test
                framework = $recipe.framework
                image = $recipe.image
            }
        } else {
            [ordered]@{
                id = $id
                strategy = 'standalone'
                transports = @($transports)
                image = $image
                manifest = $manifestObject
            }
        }
        $manifestEntryJson = $manifestEntry | ConvertTo-Json -Depth 30 -Compress
        $changed = -not $oldManifestById.ContainsKey($id) -or ($oldManifestById[$id] -cne $manifestEntryJson)
        $result.status = if ($changed) { 'generated' } else { 'unchanged' }
        $result.coverage = if ($transports.Count -eq 2) { 'Paired' } else { 'Partially supported' }
        if ($recipe.explanation) { $result.explanation = $recipe.explanation }
        $result.fingerprint = $fingerprint
        $manifestEntries.Add($manifestEntry)
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
    $main = Join-Path $workspace 'templates/modern/public/main.js'
    $null = Write-Changed $main "export default {};`n"
    if ('templates/modern' -notin $templates) { $config.build.template = $templates + @('templates/modern') }
}
Assert-RepositoryPath $main
$mainText = [IO.File]::ReadAllText($main)
if (-not $mainText.Contains("import './run-actions.js';")) { $null = Write-Changed $main ($mainText + "`nimport './run-actions.js';`n") }
$null = Write-Changed (Join-Path (Split-Path $main -Parent) 'run-actions.js') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/run-actions.js')))
$null = Write-Changed $configPath (($config | ConvertTo-Json -Depth 100) + "`n")
$sortedManifest = @($manifestEntries | Sort-Object { $_.id })
$null = Write-Changed $manifestPath (([ordered]@{ schemaVersion = 1; examples = $sortedManifest } | ConvertTo-Json -Depth 30) + "`n")
$null = Write-Changed (Join-Path $workspace 'BuildRunActions.ps1') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/BuildRunActions.ps1')))
function Test-DockerBuildCommand($CommandAst) {
    if ($CommandAst.CommandElements.Count -lt 2) { return $false }
    $cmdName = $CommandAst.GetCommandName()
    if (-not $cmdName -or $cmdName -inotmatch '(^|[\\/])docker(\.exe)?$') { return $false }
    $firstArg = $CommandAst.CommandElements[1].Extent.Text.Trim("'`"")
    if ($firstArg -ieq 'build') { return $true }
    if ($firstArg -ieq 'buildx' -and $CommandAst.CommandElements.Count -ge 3) {
        return $CommandAst.CommandElements[2].Extent.Text.Trim("'`"") -ieq 'build'
    }
    return $false
}
function Test-ApiCleanupPipeline($PipelineAst) {
    if ($PipelineAst -isnot [Management.Automation.Language.PipelineAst]) { return $false }
    if ($PipelineAst.PipelineElements.Count -ne 2) { return $false }
    $first = $PipelineAst.PipelineElements[0] -as [Management.Automation.Language.CommandAst]
    $second = $PipelineAst.PipelineElements[1] -as [Management.Automation.Language.CommandAst]
    if (-not $first -or -not $second) { return $false }
    $firstName = $first.GetCommandName()
    $secondName = $second.GetCommandName()
    return ($firstName -ieq 'Get-ChildItem' -or $firstName -ieq 'gci') -and
           ($secondName -ieq 'Remove-Item' -or $secondName -ieq 'ri') -and
           ($PipelineAst.Extent.Text -match '(?i)\bapi\b')
}
function Get-LineIndent([string] $Text, [int] $Offset) {
    if ($Offset -eq 0) { return '' }
    $lineStart = $Text.LastIndexOf("`n", $Offset - 1)
    $lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
    $prefix = $Text.Substring($lineStart, $Offset - $lineStart)
    if ($prefix -notmatch '^[ \t]*$') { return $null }
    return $prefix
}
function Update-BuildDocfxImageScript([string] $Original) {
    $standardFlatPattern = '(?i)\A\s*(?<version>\$version\s*=\s*minver[^\r\n]*)(?:\r?\n[ \t]*)+(?<metadata>docfx\s+metadata[^\r\n]*)(?:\r?\n[ \t]*)+(?:&\s*\(Join-Path\s+\$PSScriptRoot\s+[''"]BuildRunActions\.ps1[''"]\)(?:\r?\n[ \t]*)+)?(?<docker>docker\s+buildx\s+build[^\r\n]*)(?:\r?\n[ \t]*)+(?<cleanup>get-childitem\b[^\r\n]*\|\s*remove-item[^\r\n]*)\s*\z'
    $standardTryPattern = '(?i)\A\s*(?<version>\$version\s*=\s*minver[^\r\n]*)(?:\r?\n[ \t]*)+(?<metadata>docfx\s+metadata[^\r\n]*)(?:\r?\n[ \t]*)+(?:&\s*\(Join-Path\s+\$PSScriptRoot\s+[''"]BuildRunActions\.ps1[''"]\)(?:\r?\n[ \t]*)+)?try\s*\{(?:\r?\n[ \t]*)+(?<docker>docker\s+buildx\s+build[^\r\n]*)(?:\r?\n[ \t]*)+\}(?:\r?\n[ \t]*)+finally\s*\{(?:\r?\n[ \t]*)+(?<cleanup>get-childitem\b[^\r\n]*\|\s*remove-item[^\r\n]*)(?:(?:\r?\n[ \t]*)+if\s*\(\s*Test-Path\s+-LiteralPath\s+\(Join-Path\s+\$PSScriptRoot\s+[''"]run-actions[''"]\)\s*\)\s*\{(?:\r?\n[ \t]*)+Remove-Item\s+-LiteralPath\s+\(Join-Path\s+\$PSScriptRoot\s+[''"]run-actions[''"]\)\s+-Recurse\s+-Force(?:\r?\n[ \t]*)+\})?(?:\r?\n[ \t]*)+\}\s*\z'
    $nl = if ($Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $trailingNewline = if ($Original -match '\r?\n\z') { $nl } else { '' }
    $match = [regex]::Match($Original, $standardFlatPattern)
    if (-not $match.Success) { $match = [regex]::Match($Original, $standardTryPattern) }
    if ($match.Success) {
        return (@(
            $match.Groups['version'].Value.Trim()
            $match.Groups['metadata'].Value.Trim()
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            ('    ' + $match.Groups['docker'].Value.Trim())
            '}'
            'finally {'
            ('    ' + $match.Groups['cleanup'].Value.Trim())
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join $nl) + $trailingNewline
    }

    $hasInvoke = $Original.IndexOf('BuildRunActions.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
    $hasCleanup = $Original -match "(?i)['""]run-actions['""]"
    if ($hasInvoke -and $hasCleanup) { return $Original }

    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Original, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { return $Original }

    $dockerCommands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and (Test-DockerBuildCommand $n) }, $true))
    if (-not $dockerCommands.Count) { return $Original }

    $enclosingTries = [Collections.Generic.List[object]]::new()
    $directStmts = [Collections.Generic.List[object]]::new()
    foreach ($cmd in $dockerCommands) {
        $tryNode = $null
        $stmtNode = $null
        for ($cur = $cmd; $cur; $cur = $cur.Parent) {
            if (-not $stmtNode -and $cur -is [Management.Automation.Language.StatementAst] -and
                ($cur.Parent -is [Management.Automation.Language.StatementBlockAst] -or $cur.Parent -is [Management.Automation.Language.NamedBlockAst])) {
                $stmtNode = $cur
            }
            if ($cur.Parent -is [Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($cur, $cur.Parent.Body)) {
                $tryNode = $cur.Parent
                break
            }
        }
        $enclosingTries.Add($tryNode)
        $directStmts.Add($stmtNode)
    }

    $edits = [Collections.Generic.List[object]]::new()
    $allInSameTry = ($null -ne $enclosingTries[0]) -and (@($enclosingTries | Where-Object { -not [object]::ReferenceEquals($_, $enclosingTries[0]) }).Count -eq 0)
    if ($allInSameTry) {
        $tryAst = $enclosingTries[0]
        $tryIndent = Get-LineIndent $Original $tryAst.Extent.StartOffset
        if ($null -eq $tryIndent) { return $Original }
        if (-not $hasInvoke) {
            $edits.Add(@{
                Offset = $tryAst.Extent.StartOffset
                Length = 0
                Text = "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')$nl$tryIndent"
            })
        }
        if (-not $hasCleanup) {
            if ($tryAst.Finally) {
                $bodyIndent = $tryIndent + '    '
                if ($tryAst.Finally.Statements.Count -gt 0) {
                    $lastFinallyIndent = Get-LineIndent $Original $tryAst.Finally.Statements[-1].Extent.StartOffset
                    if ($null -ne $lastFinallyIndent) { $bodyIndent = $lastFinallyIndent }
                }
                $cleanupLines = @(
                    "${bodyIndent}if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
                    "${bodyIndent}    Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
                    "${bodyIndent}}"
                ) -join $nl
                $closeOffset = $tryAst.Finally.Extent.EndOffset - 1
                $closeIndent = Get-LineIndent $Original $closeOffset
                if ($null -ne $closeIndent) {
                    $insertAt = $closeOffset - $closeIndent.Length
                    $edits.Add(@{ Offset = $insertAt; Length = 0; Text = $cleanupLines + $nl })
                } else {
                    $edits.Add(@{ Offset = $closeOffset; Length = 0; Text = $nl + $cleanupLines + $nl + $tryIndent })
                }
            } else {
                $finallyBlock = @(
                    "${tryIndent}finally {"
                    "${tryIndent}    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
                    "${tryIndent}        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
                    "${tryIndent}    }"
                    "${tryIndent}}"
                ) -join $nl
                $edits.Add(@{ Offset = $tryAst.Extent.EndOffset; Length = 0; Text = $nl + $finallyBlock })
            }
        }
    } else {
        $parentBlock = if ($directStmts[0]) { $directStmts[0].Parent } else { $null }
        $allInSameBlock = ($null -ne $parentBlock) -and (@($directStmts | Where-Object { $null -eq $_ -or -not [object]::ReferenceEquals($_.Parent, $parentBlock) }).Count -eq 0)
        if (-not $allInSameBlock) { return $Original }
        $orderedStmts = @($directStmts | Sort-Object { $_.Extent.StartOffset } -Unique)
        $firstStmt = $orderedStmts[0]
        $lastStmt = $orderedStmts[-1]
        $indent = Get-LineIndent $Original $firstStmt.Extent.StartOffset
        if ($null -eq $indent) { return $Original }
        if ($hasCleanup) {
            if (-not $hasInvoke) {
                $edits.Add(@{
                    Offset = $firstStmt.Extent.StartOffset
                    Length = 0
                    Text = "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')$nl$indent"
                })
            }
        } else {
            $dockerSlice = $Original.Substring($firstStmt.Extent.StartOffset, $lastStmt.Extent.EndOffset - $firstStmt.Extent.StartOffset)
            $indentedDocker = (@($dockerSlice -split '\r?\n' | ForEach-Object {
                if ($_ -match '^[ \t]*$') { '' }
                elseif ($indent.Length -gt 0 -and $_.StartsWith($indent, [StringComparison]::Ordinal)) { $indent + '    ' + $_.Substring($indent.Length) }
                else { $indent + '    ' + $_ }
            }) -join $nl)
            $replaceEnd = $lastStmt.Extent.EndOffset
            $cleanupBody = [Collections.Generic.List[string]]::new()
            $stmtList = @($parentBlock.Statements)
            $lastIdx = -1
            for ($i = 0; $i -lt $stmtList.Count; $i++) {
                if ([object]::ReferenceEquals($stmtList[$i], $lastStmt)) { $lastIdx = $i; break }
            }
            if ($lastIdx -ge 0 -and ($lastIdx + 1) -lt $stmtList.Count) {
                $nextStmt = $stmtList[$lastIdx + 1]
                $gap = $Original.Substring($lastStmt.Extent.EndOffset, $nextStmt.Extent.StartOffset - $lastStmt.Extent.EndOffset)
                if ($gap -match '^\s*$' -and (Test-ApiCleanupPipeline $nextStmt)) {
                    $cleanupBody.Add($indent + '    ' + $nextStmt.Extent.Text.Trim())
                    $replaceEnd = $nextStmt.Extent.EndOffset
                }
            }
            $cleanupBody.Add("${indent}    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {")
            $cleanupBody.Add("${indent}        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force")
            $cleanupBody.Add("${indent}    }")
            $replacementLines = [Collections.Generic.List[string]]::new()
            if (-not $hasInvoke) {
                $replacementLines.Add("& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')")
                $replacementLines.Add("${indent}try {")
            } else {
                $replacementLines.Add('try {')
            }
            $replacementLines.Add($indentedDocker)
            $replacementLines.Add("${indent}}")
            $replacementLines.Add("${indent}finally {")
            foreach ($line in $cleanupBody) { $replacementLines.Add($line) }
            $replacementLines.Add("${indent}}")
            $edits.Add(@{
                Offset = $firstStmt.Extent.StartOffset
                Length = $replaceEnd - $firstStmt.Extent.StartOffset
                Text = ($replacementLines -join $nl)
            })
        }
    }

    if (-not $edits.Count) { return $Original }
    $updated = $Original
    foreach ($edit in $edits | Sort-Object -Property Offset, Length -Descending) {
        $updated = $updated.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.Text)
    }
    $verifyTokens = $null; $verifyErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($updated, [ref]$verifyTokens, [ref]$verifyErrors)
    if ($verifyErrors.Count) { return $Original }
    return $updated
}
$buildImagePath = Join-Path $workspace 'BuildDocfxImage.ps1'
if (Test-Path -LiteralPath $buildImagePath) {
    Assert-RepositoryPath $buildImagePath
    $buildImageOriginal = [IO.File]::ReadAllText($buildImagePath)
    $buildImageUpdated = Update-BuildDocfxImageScript $buildImageOriginal
    Write-Page $buildImagePath $buildImageOriginal $buildImageUpdated
}
if ($results.Count) { $results | ConvertTo-Json -Depth 30 } else { '[]' }
if (@($results | Where-Object { $_.status -eq 'failed' -or $_.native -eq 'Failed' -or $_.docker -eq 'Failed' }).Count) { exit 1 }
if (@($results | Where-Object coverage -eq 'Unresolved').Count) { exit 2 }
