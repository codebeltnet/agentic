<#
.SYNOPSIS
    Prepares portable with-skill and baseline eval prompts for a repo-managed skill, and collects externally produced results.

.DESCRIPTION
    This script computes and prints. It never executes a prompt, never spawns an agent, and never calls a model.
    It turns skills/<name>/evals/evals.json into a paste-ready evaluation package that a human can run in whatever
    harness, provider, and model they choose, then validates the results that come back.

    Prepare mode writes one directory per eval. The grading key and result stubs stay at the eval-case level, outside
    the two hermetic run directories a worker actually sees:
      eval-metadata.json        id, name, prompt, expected output, assertions, fixtures, hashes, assumptions
      results/                  one prefilled result stub per configuration
      with_skill/               a hermetic run: prompt.md, run.json, repo/ (materialized fixtures), home/, skill/<name>/
      without_skill/            the same run without any skill/ directory and no skill instructions

    Each run directory is the worker's sandbox root: repo/ is the working tree, home/ is an isolated profile, and skill/
    (with_skill only) holds the candidate skill revision. run.json is a harness-neutral contract naming only paths inside
    the run directory. Preparation validates the isolation invariants and fails early if a package would let a baseline
    reach the skill, let a worker reach the source repository, or stage mismatched fixtures.

    Collect mode reads a prepared package plus whatever result files were filled in, validates them, and writes a
    deterministic comparison and static HTML report. The selected external evaluator owns model-backed execution and
    grading; nothing in this repository launches a model.

.PARAMETER Skill
    Name of the repo-managed skill under skills/.

.PARAMETER Eval
    Optional eval ids to include. Defaults to every eval in the skill's evals.json.

.PARAMETER Iteration
    Iteration number to write. Defaults to the next unused iteration in the workspace.

.PARAMETER OutputRoot
    Workspace root. Defaults to .bot/<skill>-workspace. A path inside this repository must stay under .bot/.

.PARAMETER MaxInlineBytes
    Budget for inlining referenced skill resources beyond SKILL.md, which is always inlined. Anything over budget is
    bundled under skill/ and listed in the prompt instead.

.PARAMETER Force
    Overwrite an existing iteration directory.

.PARAMETER Changed
    Prepares a package for every repo-managed skill this branch changed, including uncommitted work. This is the form
    the eval completion gate uses after adding or modifying a skill.

.PARAMETER Base
    Base ref for -Changed. Defaults to origin/main, then main, then the working tree alone.

.PARAMETER CollectResults
    Path to a prepared iteration directory. Validates the result files in it and writes comparison.md, benchmark.json,
    and report.html. This is the fallback for results that were not finalized by the external evaluator.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Skill dotnet-strong-name-signing

.EXAMPLE
    pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed

.EXAMPLE
    pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults $env:TEMP/dotnet-strong-name-signing-workspace/iteration-1
#>
[CmdletBinding(DefaultParameterSetName = 'Prepare')]
param(
    [Parameter(ParameterSetName = 'Prepare', Mandatory = $true, Position = 0)]
    [string]$Skill,

    [Parameter(ParameterSetName = 'Prepare')]
    [int[]]$Eval,

    [Parameter(ParameterSetName = 'Prepare')]
    [int]$Iteration,

    [Parameter(ParameterSetName = 'Changed', Mandatory = $true)]
    [switch]$Changed,

    [Parameter(ParameterSetName = 'Changed')]
    [string]$Base,

    [Parameter(ParameterSetName = 'Prepare')]
    [Parameter(ParameterSetName = 'Changed')]
    [string]$OutputRoot,

    [Parameter(ParameterSetName = 'Prepare')]
    [Parameter(ParameterSetName = 'Changed')]
    [int]$MaxInlineBytes = 120000,

    [Parameter(ParameterSetName = 'Prepare')]
    [Parameter(ParameterSetName = 'Changed')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Collect', Mandatory = $true)]
    [string]$CollectResults
)

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

# Captured at script scope: $PSBoundParameters inside a function describes that function, not this script.
$scriptBoundParameters = $PSBoundParameters

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$packageSchema = 'codebeltnet/agentic/eval-package/2'
$metadataSchema = 'codebeltnet/agentic/eval-metadata/2'
$resultSchema = 'codebeltnet/agentic/eval-result/2'
$runSchema = 'codebeltnet/agentic/eval-run/1'
$maxFixtureInlineBytes = 32768

# A materialized run is hermetic: the harness treats the run directory as the worker's sandbox root, mounts repo/ as
# the working directory and home/ as the isolated user profile, and exposes skill/ only for a with_skill run. Nothing
# else in the package - the grading key, the paired run, other evals, or results - lives inside a run directory, so a
# worker confined to its run directory cannot reach any of it.
$runDirectoryNames = [ordered]@{
    Working = 'repo'
    Home = 'home'
    Skill = 'skill'
    Prompt = 'prompt.md'
    Run = 'run.json'
}
$reportToolRelativePath = 'tools/generate-eval-report.ps1'

# These directory names are generated build state or harness bookkeeping. They must never be staged into a run's
# repository, and their presence (other than an intentional .git) means a fixture leaked build output.
$forbiddenFixtureSegments = @('bin', 'obj', '.vs', '.bot', '__pycache__', 'BenchmarkDotNet.Artifacts', 'TestResults')

$responseContract = @'
# Response contract

Respond in a single message.

- Do the work in that message. If the task produces or changes files, include every file path with its final content in fenced code blocks, and also write them to disk when the environment allows it.
- If you would normally pause and ask before acting, say what you would ask and why, then stop there. That pause is a valid response.
- State any assumption you had to make instead of waiting for an answer.
'@

$withSkillPreamble = @'
# Operating instructions

The instructions below are a skill: reusable operating instructions that a capable agent loads before doing this kind of work. Follow them for the task in this message. They are reproduced here in full, so you do not need to load anything else.
'@

$withoutSkillPreamble = @'
# Operating instructions

You have no special instructions for this task beyond your normal capabilities. Solve the task in this message the way you normally would.
'@

# Identical for both configurations, and placed before the task so it never disturbs the task-and-inputs invariant that
# a with_skill and a without_skill prompt share. It reinforces, in prose, the boundary the harness enforces for real:
# operate on the staged files, not on anything discovered elsewhere on the machine.
$workingEnvironmentSection = @'
# Working environment

Your working directory is a repository that was staged for this task. Treat it as the project root. The files under it are real, complete, and the only source of truth. Read and edit those files directly.

Do not look for the project anywhere else on the machine, and do not reconstruct it from the text of this prompt. This is a disposable copy prepared for a single run. Your home and configuration directories are isolated to this run as well, so anything you install, configure, or discover stays local to it. Work only inside your run package; nothing outside it is part of this task.
'@

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # Package files are portable artifacts that get pasted between machines and harnesses, so they are written with
    # LF endings regardless of the platform that generated them.
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    Write-Utf8File -Path $Path -Content (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

function Test-IsBinaryFile {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new(8000)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        for ($index = 0; $index -lt $read; $index++) {
            if ($buffer[$index] -eq 0) {
                return $true
            }
        }
    } finally {
        $stream.Dispose()
    }

    return $false
}

function Get-Fence {
    param([string]$Content)

    $longest = 0
    foreach ($match in [regex]::Matches($Content, '`+')) {
        if ($match.Length -gt $longest) {
            $longest = $match.Length
        }
    }

    return ('`' * [Math]::Max(3, $longest + 1))
}

function Get-FenceLanguage {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.cs' { 'csharp' }
        '.csproj' { 'xml' }
        '.props' { 'xml' }
        '.targets' { 'xml' }
        '.slnx' { 'xml' }
        '.xml' { 'xml' }
        '.cshtml' { 'html' }
        '.razor' { 'html' }
        '.html' { 'html' }
        '.css' { 'css' }
        '.js' { 'javascript' }
        '.json' { 'json' }
        '.md' { 'markdown' }
        '.ps1' { 'powershell' }
        '.psm1' { 'powershell' }
        '.py' { 'python' }
        '.sh' { 'bash' }
        '.yml' { 'yaml' }
        '.yaml' { 'yaml' }
        default { 'text' }
    }
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseFull = ([System.IO.Path]::GetFullPath($BasePath)).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $targetFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$FullPath' is not under '$BasePath'."
    }

    return ($targetFull.Substring($baseFull.Length).TrimStart('\', '/') -replace '\\', '/')
}

function Test-IsInsidePath {
    param(
        [string]$BasePath,
        [string]$CandidatePath
    )

    $baseFull = ([System.IO.Path]::GetFullPath($BasePath)).TrimEnd('\', '/')
    $candidateFull = ([System.IO.Path]::GetFullPath($CandidatePath)).TrimEnd('\', '/')

    return $candidateFull -eq $baseFull -or $candidateFull.StartsWith($baseFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-WorkspaceLocation {
    param(
        [string]$RepoRoot,
        [string]$WorkspaceRoot
    )

    if (-not (Test-IsInsidePath -BasePath $RepoRoot -CandidatePath $WorkspaceRoot)) {
        return
    }

    # Inside the repository only under .bot/, which this repository ignores. Some harnesses refuse to work outside
    # the repository folder at all, and .bot/ gives them a home that git never sees.
    $botRoot = Join-Path $RepoRoot '.bot'
    if (-not (Test-IsInsidePath -BasePath $botRoot -CandidatePath $WorkspaceRoot)) {
        throw "Eval packages inside this repository must live under .bot/. '$WorkspaceRoot' does not, so it would become part of the working tree. Use .bot/<skill>-workspace or a path outside the repository."
    }

    # A .bot/ that stopped being ignored would quietly turn eval output into stageable files.
    [void](git -C $RepoRoot check-ignore -q -- $WorkspaceRoot 2>$null)
    if ($LASTEXITCODE -eq 1) {
        throw "'$WorkspaceRoot' is inside the repository but git does not ignore it. Restore the .bot/ ignore rule before writing eval packages there."
    }
}

function Get-EvalName {
    param([object]$EvalEntry)

    if ($EvalEntry.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace([string]$EvalEntry.name)) {
        $source = [string]$EvalEntry.name
    } else {
        $words = @(([string]$EvalEntry.prompt) -split '\s+' | Where-Object { $_ -ne '' } | Select-Object -First 8)
        $source = [string]::Join(' ', $words)
    }

    $slug = ($source.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 48) {
        $slug = $slug.Substring(0, 48).Trim('-')
    }
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'eval'
    }

    return ('eval-{0:d2}-{1}' -f [int]$EvalEntry.id, $slug)
}

function Get-SkillFileInventory {
    param(
        [string]$SkillDirectory,
        [string]$SkillBody,
        [int]$Budget
    )

    $files = Get-ChildItem -LiteralPath $SkillDirectory -Recurse -File -Force |
        ForEach-Object { Get-RelativePath -BasePath $SkillDirectory -FullPath $_.FullName } |
        Where-Object {
            $_ -ne 'SKILL.md' -and
            -not $_.StartsWith('evals/') -and
            $_ -notmatch '(^|/)(bin|obj)/' -and
            $_ -notmatch '(^|/)__pycache__/'
        } |
        Sort-Object

    $inventory = foreach ($relativePath in $files) {
        $fullPath = Join-Path $SkillDirectory $relativePath
        $index = $SkillBody.IndexOf($relativePath, [System.StringComparison]::Ordinal)
        [pscustomobject]@{
            Path = $relativePath
            FullPath = $fullPath
            Bytes = (Get-Item -LiteralPath $fullPath).Length
            Referenced = $index -ge 0
            Order = if ($index -ge 0) { $index } else { [int]::MaxValue }
        }
    }

    $inventory = @($inventory | Sort-Object Order, Path)

    $inlined = [System.Collections.Generic.List[object]]::new()
    $bundled = [System.Collections.Generic.List[object]]::new()
    $used = 0

    foreach ($item in $inventory) {
        $extension = [System.IO.Path]::GetExtension($item.Path).ToLowerInvariant()
        $isInlineCandidate = $item.Referenced -and @('.md', '.txt') -contains $extension -and -not (Test-IsBinaryFile -Path $item.FullPath)

        if ($isInlineCandidate -and ($used + $item.Bytes) -le $Budget) {
            $used += $item.Bytes
            $inlined.Add($item)
        } else {
            $bundled.Add($item)
        }
    }

    return [pscustomobject]@{
        Inlined = @($inlined)
        Bundled = @($bundled)
        InlinedBytes = $used
    }
}

function New-SkillInstructionSection {
    param(
        [string]$SkillName,
        [string]$SkillBody,
        [object]$Inventory
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine($withSkillPreamble)
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("## Skill: $SkillName")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine($SkillBody.Trim())
    [void]$builder.AppendLine()

    foreach ($item in $Inventory.Inlined) {
        $resourceText = ([System.IO.File]::ReadAllText($item.FullPath, [System.Text.UTF8Encoding]::new($false))).TrimEnd()
        $fence = Get-Fence -Content $resourceText
        [void]$builder.AppendLine("## Skill resource: $($item.Path)")
        [void]$builder.AppendLine()
        [void]$builder.AppendLine($fence + 'markdown')
        [void]$builder.AppendLine($resourceText)
        [void]$builder.AppendLine($fence)
        [void]$builder.AppendLine()
    }

    if ($Inventory.Bundled.Count -gt 0) {
        [void]$builder.AppendLine('## Skill resources that are not inlined')
        [void]$builder.AppendLine()
        [void]$builder.AppendLine("These files belong to the skill but are too large, not text, or not referenced from its main instructions. The complete skill tree, including these, is staged in your run package under ``skill/$SkillName/`` (a sibling of your working directory). Read them from there when your environment allows it; otherwise work from the instructions above and say what you could not reach.")
        [void]$builder.AppendLine()
        foreach ($item in $Inventory.Bundled) {
            [void]$builder.AppendLine("- ``skill/$SkillName/$($item.Path)`` ($($item.Bytes) bytes)")
        }
        [void]$builder.AppendLine()
    }

    return $builder.ToString().TrimEnd()
}

function New-InputFilesSection {
    param([object[]]$Fixtures)

    if (@($Fixtures).Count -eq 0) {
        return $null
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('# Input files')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('These files already exist as real files in your working directory, at the paths shown. They are the input for the task. Read and edit them there; the copies below are only for reference.')
    [void]$builder.AppendLine()

    foreach ($fixture in $Fixtures) {
        [void]$builder.AppendLine("## ``$($fixture.RepoRelative)``")
        [void]$builder.AppendLine()
        if ($fixture.Inlined) {
            $fixtureText = $fixture.Content.TrimEnd()
            $fence = Get-Fence -Content $fixtureText
            [void]$builder.AppendLine($fence + $fixture.Language)
            [void]$builder.AppendLine($fixtureText)
            [void]$builder.AppendLine($fence)
        } else {
            [void]$builder.AppendLine("Present in your working directory at ``$($fixture.RepoRelative)`` ($($fixture.Bytes) bytes, $($fixture.SkipReason)); read it there.")
        }
        [void]$builder.AppendLine()
    }

    return $builder.ToString().TrimEnd()
}

function New-PromptDocument {
    param(
        [object]$EvalEntry,
        [string]$InstructionSection,
        [string]$InputFilesSection
    )

    $sections = [System.Collections.Generic.List[string]]::new()
    $sections.Add($InstructionSection)
    $sections.Add($workingEnvironmentSection)
    $sections.Add("# Task`n`n$(([string]$EvalEntry.prompt).Trim())")
    if (-not [string]::IsNullOrWhiteSpace($InputFilesSection)) {
        $sections.Add($InputFilesSection)
    }
    $sections.Add($responseContract)

    return ([string]::Join("`n`n", $sections)).TrimEnd() + [Environment]::NewLine
}

function New-ResultStub {
    param(
        [string]$SkillName,
        [int]$IterationNumber,
        [object]$EvalEntry,
        [string]$EvalName,
        [string]$Configuration,
        [string[]]$Assertions
    )

    $grading = foreach ($assertion in $Assertions) {
        [ordered]@{
            text = $assertion
            passed = $null
            evidence = ''
        }
    }

    return [ordered]@{
        schema = $resultSchema
        skill_name = $SkillName
        iteration = $IterationNumber
        eval_id = [int]$EvalEntry.id
        eval_name = $EvalName
        configuration = $Configuration
        model = ''
        provider = ''
        harness = ''
        executed_utc = ''
        output = ''
        output_files = @()
        transcript = ''
        shell_commands = @()
        files_read = @()
        files_written = @()
        stdout = ''
        stderr = ''
        exit_status = $null
        duration_seconds = $null
        total_tokens = $null
        tool_calls = $null
        isolation = [ordered]@{
            fresh_context = $null
            isolated_home = $null
            isolated_cwd = $null
            filesystem_sandbox = $null
            candidate_skill_exposed = $null
            transcript_captured = $null
        }
        grading = @($grading)
        notes = ''
    }
}

function Get-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $Default
}

# Render a run's self-reported isolation guarantees as a compact Y/N/? line. A missing object reads as "not reported",
# which tells the grader the harness did not confirm any boundary and that process-dependent assertions are suspect.
function Format-IsolationReport {
    param([object]$Isolation)

    if ($null -eq $Isolation) {
        return 'not reported'
    }

    $flags = [ordered]@{
        fresh = 'fresh_context'
        home = 'isolated_home'
        cwd = 'isolated_cwd'
        fs = 'filesystem_sandbox'
        skill = 'candidate_skill_exposed'
        tx = 'transcript_captured'
    }
    $parts = foreach ($key in $flags.Keys) {
        $value = Get-JsonProperty -Object $Isolation -Name $flags[$key]
        $mark = if ($null -eq $value) { '?' } elseif ([bool]$value) { 'Y' } else { 'N' }
        "$key=$mark"
    }

    return ($parts -join ' ')
}

function Get-Assertions {
    param([object]$EvalEntry)

    if ($EvalEntry.PSObject.Properties.Name -contains 'expectations' -and $null -ne $EvalEntry.expectations) {
        return @($EvalEntry.expectations | ForEach-Object { [string]$_ })
    }

    return @()
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([string]$Path)

    return Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($Path))
}

# A stable fingerprint of a directory tree: every file's forward-slashed relative path and its content hash, sorted,
# hashed again. Two trees with byte-identical files produce the same value regardless of enumeration order or platform.
function Get-TreeHash {
    param(
        [string]$Root,
        [string[]]$ExcludeSegments = @()
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)) {
        $relative = Get-RelativePath -BasePath $Root -FullPath $file.FullName
        $segments = $relative.Split('/')
        if ($ExcludeSegments.Count -gt 0 -and (@($segments | Where-Object { $ExcludeSegments -contains $_ }).Count -gt 0)) {
            continue
        }
        $entries.Add("$relative`:$(Get-FileSha256 -Path $file.FullName)")
    }

    $joined = [string]::Join("`n", @($entries | Sort-Object))
    return Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($joined))
}

function Get-EvalWorkspaceOption {
    param([object]$EvalEntry)

    $wantsGit = $false
    if ($EvalEntry.PSObject.Properties.Name -contains 'workspace' -and $null -ne $EvalEntry.workspace) {
        $workspace = $EvalEntry.workspace
        if ($workspace.PSObject.Properties.Name -contains 'git' -and $null -ne $workspace.git) {
            $wantsGit = [bool]$workspace.git
        }
    }

    return [pscustomobject]@{
        Git = $wantsGit
    }
}

# The fixtures for one eval share a scenario directory under evals/files/ (for example evals/files/zero-config/...). That
# scenario directory is the repository root the worker should see, so it is stripped when a fixture is materialized:
# evals/files/zero-config/src/App.cs becomes repo/src/App.cs. Flat fixtures placed directly under evals/files/ (a single
# document, say) keep their own name at the repository root.
function Resolve-FixtureLayout {
    param([string[]]$FixturePaths)

    $normalized = @($FixturePaths | ForEach-Object { ([string]$_).Trim() -replace '\\', '/' } | Where-Object { $_ -ne '' })
    $underFiles = @(foreach ($path in $normalized) {
        if ($path -notmatch '^evals/files/.+') {
            throw "Fixture '$path' must live under evals/files/."
        }
        $path.Substring('evals/files/'.Length)
    })

    $firstSegments = @($underFiles | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    $scenario = $null
    if ($firstSegments.Count -eq 1) {
        $candidate = $firstSegments[0]
        # A shared first segment is the scenario root only when it is a directory, meaning at least one fixture has a
        # path below it. A lone file such as report.md keeps its name at the repository root instead.
        if (@($underFiles | Where-Object { $_ -like "$candidate/*" }).Count -gt 0) {
            $scenario = $candidate
        }
    }

    $map = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $normalized.Count; $index++) {
        $evalRelative = $underFiles[$index]
        $repoRelative = if ($null -ne $scenario -and $evalRelative -like "$scenario/*") {
            $evalRelative.Substring($scenario.Length + 1)
        } else {
            $evalRelative
        }
        if ([string]::IsNullOrWhiteSpace($repoRelative)) {
            throw "Fixture '$($normalized[$index])' resolves to an empty repository path."
        }
        $map.Add([pscustomobject]@{
            EvalPath = $normalized[$index]
            RepoRelative = $repoRelative
        })
    }

    return [pscustomobject]@{
        Scenario = $scenario
        Files = @($map)
    }
}

function Assert-RepoRelativeIsSafe {
    param([string]$RepoRelative)

    $segments = $RepoRelative.Split('/')
    if ($segments -contains '..') {
        throw "Fixture path '$RepoRelative' escapes the repository root."
    }
    foreach ($segment in $segments) {
        if ($forbiddenFixtureSegments -contains $segment) {
            throw "Fixture path '$RepoRelative' includes generated build state ('$segment'); eval fixtures must not carry $($forbiddenFixtureSegments -join ', ')."
        }
    }
}

# Copy an eval's fixtures into a run's repo/ as real files, preserving structure and returning the repo-relative paths so
# the manifest and run.json can describe exactly what the worker received.
function Copy-FixtureRepo {
    param(
        [string]$SkillDirectory,
        [object]$Layout,
        [string]$RepoDirectory,
        [int]$EvalId
    )

    New-Item -ItemType Directory -Path $RepoDirectory -Force | Out-Null
    foreach ($file in $Layout.Files) {
        Assert-RepoRelativeIsSafe -RepoRelative $file.RepoRelative
        $sourcePath = Join-Path $SkillDirectory ($file.EvalPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Missing fixture 'skills/*/$($file.EvalPath)' referenced by eval $EvalId."
        }
        $destination = Join-Path $RepoDirectory ($file.RepoRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
    }
}

# Stage a real, disposable git repository so tools that probe for a repository root or derive a version from git history
# (MinVer, Nerdbank.GitVersioning, SourceLink) behave exactly as they do on a developer's machine. Fixed identity and
# timestamps keep the two paired runs byte-identical; nothing is written to the caller's global or local git config.
function Initialize-GitWorkspace {
    param([string]$RepoDirectory)

    $identity = @(
        '-c', 'user.name=Eval Harness',
        '-c', 'user.email=eval-harness@localhost',
        '-c', 'commit.gpgsign=false',
        '-c', 'core.autocrlf=false'
    )
    $env:GIT_AUTHOR_DATE = '2020-01-01T00:00:00Z'
    $env:GIT_COMMITTER_DATE = '2020-01-01T00:00:00Z'
    try {
        & git @identity init -b main --quiet -- $RepoDirectory 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git @identity init --quiet -- $RepoDirectory 2>$null | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            throw "git init failed while staging a workspace at '$RepoDirectory'."
        }
        & git @identity -C $RepoDirectory add -A 2>$null | Out-Null
        & git @identity -C $RepoDirectory commit -m 'Staged eval workspace' --quiet 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed while staging a workspace at '$RepoDirectory'."
        }
        & git @identity -C $RepoDirectory tag 'v1.0.0' 2>$null | Out-Null
    } finally {
        Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
    }
}

# Stage the exact candidate skill revision the worker is meant to evaluate. The whole tree ships (minus evals and build
# output) so the SKILL.md and everything it references - scripts, references, assets - are present without any fallback
# to a globally installed copy.
function Copy-SkillTree {
    param(
        [string]$SkillDirectory,
        [string]$DestinationSkillRoot
    )

    New-Item -ItemType Directory -Path $DestinationSkillRoot -Force | Out-Null
    $files = Get-ChildItem -LiteralPath $SkillDirectory -Recurse -File -Force |
        ForEach-Object { Get-RelativePath -BasePath $SkillDirectory -FullPath $_.FullName } |
        Where-Object {
            -not $_.StartsWith('evals/') -and
            $_ -notmatch '(^|/)(bin|obj)/' -and
            $_ -notmatch '(^|/)__pycache__/'
        } |
        Sort-Object

    foreach ($relative in $files) {
        $sourcePath = Join-Path $SkillDirectory ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destination = Join-Path $DestinationSkillRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
    }

    return @($files)
}

# Carry the dependency-free report writer with the package so the external evaluator can finish the complete
# execute -> grade -> report workflow without reaching back into this repository or relying on a user-specific install.
function Copy-ReportTool {
    param(
        [string]$RepoRoot,
        [string]$IterationDirectory
    )

    $source = Join-Path (Join-Path $RepoRoot 'scripts') 'generate-eval-report.ps1'
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Missing report tool '$source'."
    }

    $destination = Join-Path $IterationDirectory $reportToolRelativePath
    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    return $destination
}

# The candidate skill's fingerprint, computed from the source over exactly the files Copy-SkillTree stages. The staged
# copy in each with_skill run must reproduce this value, which is how preparation proves the worker received the
# revision under development rather than a globally installed one.
function Get-CandidateSkillHash {
    param([string]$SkillDirectory)

    $files = Get-ChildItem -LiteralPath $SkillDirectory -Recurse -File -Force |
        ForEach-Object { Get-RelativePath -BasePath $SkillDirectory -FullPath $_.FullName } |
        Where-Object {
            -not $_.StartsWith('evals/') -and
            $_ -notmatch '(^|/)(bin|obj)/' -and
            $_ -notmatch '(^|/)__pycache__/'
        } |
        Sort-Object

    $entries = foreach ($relative in $files) {
        $fullPath = Join-Path $SkillDirectory ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        "$relative`:$(Get-FileSha256 -Path $fullPath)"
    }

    $joined = [string]::Join("`n", @($entries | Sort-Object))
    return Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($joined))
}

function New-RunManifest {
    param(
        [string]$SkillName,
        [int]$IterationNumber,
        [object]$EvalEntry,
        [string]$EvalName,
        [string]$Configuration,
        [string[]]$RepoFiles,
        [string]$FixtureHash,
        [string]$SkillHash,
        [bool]$GitWorkspace
    )

    $skillDirectory = if ($Configuration -eq 'with_skill') { "$($runDirectoryNames.Skill)/$SkillName" } else { $null }

    return [ordered]@{
        schema = $runSchema
        evalId = [int]$EvalEntry.id
        evalName = $EvalName
        skillName = if ($Configuration -eq 'with_skill') { $SkillName } else { $null }
        iteration = $IterationNumber
        mode = $Configuration
        promptFile = $runDirectoryNames.Prompt
        workingDirectory = $runDirectoryNames.Working
        homeDirectory = $runDirectoryNames.Home
        skillDirectory = $skillDirectory
        freshContextRequired = $true
        filesystemIsolationRequired = $true
        isolatedHomeRequired = $true
        gitWorkspace = $GitWorkspace
        inputFiles = @($RepoFiles)
        fixtureHash = $FixtureHash
        skillHash = if ($Configuration -eq 'with_skill') { $SkillHash } else { $null }
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = $runDirectoryNames.Working
            homeDirectory = $runDirectoryNames.Home
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
}

# Fail package generation the moment a run violates an isolation invariant, so a contaminated package never reaches a
# harness. These checks operate on the materialized run directories, not on prose.
function Assert-RunIsolation {
    param(
        [string]$EvalName,
        [string]$SkillName,
        [string]$EvalCaseDirectory,
        [string]$SkillHash,
        [bool]$GitWorkspace
    )

    $withSkillDir = Join-Path $EvalCaseDirectory 'with_skill'
    $withoutSkillDir = Join-Path $EvalCaseDirectory 'without_skill'

    foreach ($configuration in @('with_skill', 'without_skill')) {
        $runDir = Join-Path $EvalCaseDirectory $configuration
        $repoDir = Join-Path $runDir $runDirectoryNames.Working
        $homeDir = Join-Path $runDir $runDirectoryNames.Home
        $promptPath = Join-Path $runDir $runDirectoryNames.Prompt
        $runJsonPath = Join-Path $runDir $runDirectoryNames.Run

        # 1. Every run has its own materialized repository, and 3. it holds no build state.
        if (-not (Test-Path -LiteralPath $repoDir)) {
            throw "$EvalName/$configuration is missing its materialized repo/."
        }
        foreach ($directory in (Get-ChildItem -LiteralPath $repoDir -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($forbiddenFixtureSegments -contains $directory.Name) {
                throw "$EvalName/$configuration staged generated build state under repo/ ('$($directory.Name)')."
            }
            if ($directory.Name -eq '.git' -and -not $GitWorkspace) {
                throw "$EvalName/$configuration staged an unexpected .git directory."
            }
        }
        if ($GitWorkspace -and -not (Test-Path -LiteralPath (Join-Path $repoDir '.git'))) {
            throw "$EvalName/$configuration declared a git workspace but no .git was staged."
        }

        # 5. Prompt path and manifest resolve only to staged resources, and 10. fresh context is declared.
        if (-not (Test-Path -LiteralPath $promptPath)) {
            throw "$EvalName/$configuration is missing prompt.md."
        }
        if (-not (Test-Path -LiteralPath $runJsonPath)) {
            throw "$EvalName/$configuration is missing run.json."
        }
        if (-not (Test-Path -LiteralPath $homeDir)) {
            throw "$EvalName/$configuration is missing its isolated home/."
        }

        $runJsonText = [System.IO.File]::ReadAllText($runJsonPath, $utf8NoBom)
        $runManifest = $runJsonText | ConvertFrom-Json
        if (-not [bool]$runManifest.freshContextRequired) {
            throw "$EvalName/$configuration run.json must require fresh context."
        }
        if (-not [bool]$runManifest.filesystemIsolationRequired -or -not [bool]$runManifest.isolatedHomeRequired) {
            throw "$EvalName/$configuration run.json must require filesystem and home isolation."
        }

        # 6. No run manifest references the source repository, and 7. none references a global skill install.
        foreach ($needle in @('skills/', '.agents', '.claude', '.codex', '.gemini', ':\', ':/')) {
            if ($configuration -eq 'with_skill' -and $needle -eq 'skills/') {
                # with_skill legitimately names skill/<name>; only reject an out-of-package skills/ reference.
                continue
            }
            if ($runJsonText.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "$EvalName/$configuration run.json references '$needle', which points outside the run package."
            }
        }
    }

    # 2. with_skill contains the candidate skill; 4. required skill files are staged and match the source revision.
    $stagedSkillRoot = Join-Path (Join-Path $withSkillDir $runDirectoryNames.Skill) $SkillName
    if (-not (Test-Path -LiteralPath (Join-Path $stagedSkillRoot 'SKILL.md'))) {
        throw "$EvalName/with_skill is missing the candidate skill (skill/$SkillName/SKILL.md)."
    }
    $stagedSkillHash = Get-TreeHash -Root $stagedSkillRoot
    if ($stagedSkillHash -ne $SkillHash) {
        throw "$EvalName/with_skill staged a candidate skill that does not match the source revision."
    }

    # 3 (baseline). without_skill contains no copy of the candidate skill by any name.
    $baselineSkillDir = Join-Path $withoutSkillDir $runDirectoryNames.Skill
    if (Test-Path -LiteralPath $baselineSkillDir) {
        throw "$EvalName/without_skill must not contain a skill/ directory."
    }
    if (Test-Path -LiteralPath (Join-Path $withoutSkillDir 'SKILL.md')) {
        throw "$EvalName/without_skill must not contain a SKILL.md."
    }

    # 9. The with_skill and without_skill repositories are otherwise identical.
    $withHash = Get-TreeHash -Root (Join-Path $withSkillDir $runDirectoryNames.Working) -ExcludeSegments @('.git')
    $withoutHash = Get-TreeHash -Root (Join-Path $withoutSkillDir $runDirectoryNames.Working) -ExcludeSegments @('.git')
    if ($withHash -ne $withoutHash) {
        throw "$EvalName repositories differ between with_skill and without_skill; the only difference must be the skill."
    }
}

function Invoke-PrepareMode {
    param([string]$SkillName = $Skill)

    $Skill = $SkillName
    $repoRoot = Get-RepoRoot
    $skillDirectory = Join-Path (Join-Path $repoRoot 'skills') $Skill
    if (-not (Test-Path -LiteralPath $skillDirectory)) {
        throw "Unknown repo-managed skill '$Skill'. Expected skills/$Skill/ under $repoRoot."
    }

    $skillMarkdownPath = Join-Path $skillDirectory 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMarkdownPath)) {
        throw "Missing skills/$Skill/SKILL.md."
    }

    $evalsPath = Join-Path (Join-Path $skillDirectory 'evals') 'evals.json'
    if (-not (Test-Path -LiteralPath $evalsPath)) {
        throw "Missing skills/$Skill/evals/evals.json."
    }

    $evalsDocument = [System.IO.File]::ReadAllText($evalsPath, $utf8NoBom) | ConvertFrom-Json
    $selectedEvals = @($evalsDocument.evals)
    if ($scriptBoundParameters.ContainsKey('Eval')) {
        $selectedEvals = @($selectedEvals | Where-Object { $Eval -contains [int]$_.id })
        $missing = @($Eval | Where-Object { $id = $_; -not (@($evalsDocument.evals) | Where-Object { [int]$_.id -eq $id }) })
        if ($missing.Count -gt 0) {
            throw "Unknown eval id(s) for '$Skill': $($missing -join ', ')."
        }
    }
    if ($selectedEvals.Count -eq 0) {
        throw "No evals selected for '$Skill'."
    }

    $workspaceRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        Join-Path (Join-Path $repoRoot '.bot') "$Skill-workspace"
    } else {
        $OutputRoot
    }
    $workspaceRoot = [System.IO.Path]::GetFullPath($workspaceRoot, (Get-Location).Path)
    Assert-WorkspaceLocation -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot
    if (-not (Test-Path -LiteralPath $workspaceRoot)) {
        New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null
    }

    $iterationNumber = if ($scriptBoundParameters.ContainsKey('Iteration')) {
        $Iteration
    } else {
        $existing = @(Get-ChildItem -LiteralPath $workspaceRoot -Directory -Filter 'iteration-*' -ErrorAction SilentlyContinue |
            ForEach-Object { if ($_.Name -match '^iteration-(\d+)$') { [int]$Matches[1] } })
        if ($existing.Count -eq 0) { 1 } else { (($existing | Measure-Object -Maximum).Maximum + 1) }
    }
    if ($iterationNumber -lt 1) {
        throw "Iteration must be 1 or greater; got $iterationNumber."
    }

    $iterationDirectory = Join-Path $workspaceRoot "iteration-$iterationNumber"
    if (Test-Path -LiteralPath $iterationDirectory) {
        if (-not $Force) {
            throw "'$iterationDirectory' already exists. Pass -Force to replace it, or -Iteration <n> to write a new one."
        }
        Remove-Item -LiteralPath $iterationDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $iterationDirectory -Force | Out-Null
    [void](Copy-ReportTool -RepoRoot $repoRoot -IterationDirectory $iterationDirectory)

    $skillText = [System.IO.File]::ReadAllText($skillMarkdownPath, $utf8NoBom)
    $skillBody = if ($skillText -match '(?ms)\A---\r?\n.*?\r?\n---\r?\n(?<body>.*)\z') { $Matches['body'] } else { $skillText }

    $inventory = Get-SkillFileInventory -SkillDirectory $skillDirectory -SkillBody $skillBody -Budget $MaxInlineBytes
    $skillHash = Get-CandidateSkillHash -SkillDirectory $skillDirectory

    $generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $withSkillInstructions = New-SkillInstructionSection -SkillName $Skill -SkillBody $skillBody -Inventory $inventory
    $manifestEvals = [System.Collections.Generic.List[object]]::new()

    foreach ($evalEntry in $selectedEvals) {
        $evalName = Get-EvalName -EvalEntry $evalEntry
        $evalDirectory = Join-Path $iterationDirectory $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null

        $workspaceOption = Get-EvalWorkspaceOption -EvalEntry $evalEntry

        $fixturePaths = @()
        if ($evalEntry.PSObject.Properties.Name -contains 'files' -and $null -ne $evalEntry.files) {
            $fixturePaths = @($evalEntry.files)
        }

        $fixtures = [System.Collections.Generic.List[object]]::new()
        $layout = $null
        if (@($fixturePaths).Count -gt 0) {
            $layout = Resolve-FixtureLayout -FixturePaths $fixturePaths
            foreach ($file in $layout.Files) {
                $sourcePath = Join-Path $skillDirectory ($file.EvalPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $sourcePath)) {
                    throw "Missing fixture 'skills/$Skill/$($file.EvalPath)' referenced by eval $($evalEntry.id)."
                }
                $bytes = (Get-Item -LiteralPath $sourcePath).Length
                $isBinary = Test-IsBinaryFile -Path $sourcePath
                $skipReason = if ($isBinary) { 'not text' } elseif ($bytes -gt $maxFixtureInlineBytes) { "over the $maxFixtureInlineBytes-byte inline cap" } else { $null }
                $fixtures.Add([pscustomobject]@{
                    EvalPath = $file.EvalPath
                    RepoRelative = $file.RepoRelative
                    Bytes = $bytes
                    Inlined = $null -eq $skipReason
                    SkipReason = $skipReason
                    Language = Get-FenceLanguage -Path $sourcePath
                    Content = if ($null -eq $skipReason) { [System.IO.File]::ReadAllText($sourcePath, $utf8NoBom) } else { '' }
                })
            }
        }

        $repoFiles = @($fixtures | ForEach-Object { $_.RepoRelative } | Sort-Object)

        # Materialize both runs. Each run directory is the worker's sandbox root: repo/ is the working tree, home/ is an
        # isolated profile, and skill/ (with_skill only) holds the candidate. The grading key and results live one level
        # up, outside every run directory, so a worker confined to its run directory can never reach them.
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runDir = Join-Path $evalDirectory $configuration
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null

            $repoDir = Join-Path $runDir $runDirectoryNames.Working
            if ($null -ne $layout) {
                Copy-FixtureRepo -SkillDirectory $skillDirectory -Layout $layout -RepoDirectory $repoDir -EvalId ([int]$evalEntry.id)
            } else {
                New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
            }
            if ($workspaceOption.Git) {
                Initialize-GitWorkspace -RepoDirectory $repoDir
            }

            $homeDir = Join-Path $runDir $runDirectoryNames.Home
            New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
            Write-Utf8File -Path (Join-Path $homeDir 'README.txt') -Content "This is an isolated, deliberately empty home directory for one eval run. A harness sets HOME - and the platform-equivalent profile and config roots - here so the worker cannot see the machine's global agent configuration, skills, plugins, MCP servers, or memories.`n"

            if ($configuration -eq 'with_skill') {
                $stagedSkillRoot = Join-Path (Join-Path $runDir $runDirectoryNames.Skill) $Skill
                [void](Copy-SkillTree -SkillDirectory $skillDirectory -DestinationSkillRoot $stagedSkillRoot)
            }
        }

        # Identical between runs by construction; validated below. The .git directory is excluded because two git init
        # runs would otherwise differ, while the tracked fixture content is the same.
        $fixtureHash = Get-TreeHash -Root (Join-Path (Join-Path $evalDirectory 'with_skill') $runDirectoryNames.Working) -ExcludeSegments @('.git')

        $inputFilesSection = New-InputFilesSection -Fixtures @($fixtures)
        $assertions = Get-Assertions -EvalEntry $evalEntry

        $withSkillPrompt = New-PromptDocument -EvalEntry $evalEntry -InstructionSection $withSkillInstructions -InputFilesSection $inputFilesSection
        $withoutSkillPrompt = New-PromptDocument -EvalEntry $evalEntry -InstructionSection $withoutSkillPreamble -InputFilesSection $inputFilesSection

        Write-Utf8File -Path (Join-Path (Join-Path $evalDirectory 'with_skill') $runDirectoryNames.Prompt) -Content $withSkillPrompt
        Write-Utf8File -Path (Join-Path (Join-Path $evalDirectory 'without_skill') $runDirectoryNames.Prompt) -Content $withoutSkillPrompt

        ConvertTo-JsonFile -Path (Join-Path (Join-Path $evalDirectory 'with_skill') $runDirectoryNames.Run) -Value (New-RunManifest -SkillName $Skill -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'with_skill' -RepoFiles $repoFiles -FixtureHash $fixtureHash -SkillHash $skillHash -GitWorkspace $workspaceOption.Git)
        ConvertTo-JsonFile -Path (Join-Path (Join-Path $evalDirectory 'without_skill') $runDirectoryNames.Run) -Value (New-RunManifest -SkillName $Skill -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'without_skill' -RepoFiles $repoFiles -FixtureHash $fixtureHash -SkillHash $null -GitWorkspace $workspaceOption.Git)

        $assumptions = [System.Collections.Generic.List[string]]::new()
        $assumptions.Add('Run with_skill and without_skill on the same model, same version, and same configuration. Different models measure the model, not the skill.')
        $assumptions.Add('Each run is hermetic: launch a fresh worker with its run directory as the sandbox root, its repo/ as the working directory, and its home/ as the isolated profile.')
        $assumptions.Add("Both runs share an identical materialized repository. Only the with_skill run exposes the candidate skill under skill/$Skill/.")
        $notInlinedFixtures = @($fixtures | Where-Object { -not $_.Inlined })
        if ($notInlinedFixtures.Count -gt 0) {
            $assumptions.Add("$($notInlinedFixtures.Count) input file(s) are large or binary; they are materialized in repo/ but not inlined in the prompt.")
        }
        if ($workspaceOption.Git) {
            $assumptions.Add('This eval stages a real .git in repo/ so repository-root detection and version-deriving tools behave as on a developer machine.')
        }
        $assumptions.Add('The expected output and assertions in this file are the grading key. They live outside every run directory and must never reach a worker.')

        $metadata = [ordered]@{
            schema = $metadataSchema
            skill_name = $Skill
            iteration = $iterationNumber
            eval_id = [int]$evalEntry.id
            eval_name = $evalName
            prompt = [string]$evalEntry.prompt
            expected_output = [string]$evalEntry.expected_output
            assertions = @($assertions)
            fixture_hash = $fixtureHash
            skill_hash = $skillHash
            git_workspace = $workspaceOption.Git
            input_files = @($fixtures | ForEach-Object {
                [ordered]@{
                    eval_path = $_.EvalPath
                    repo_path = $_.RepoRelative
                    bytes = $_.Bytes
                    inlined = $_.Inlined
                }
            })
            configurations = [ordered]@{
                with_skill = [ordered]@{
                    run_directory = 'with_skill'
                    prompt_file = "with_skill/$($runDirectoryNames.Prompt)"
                    run_manifest = "with_skill/$($runDirectoryNames.Run)"
                    result_file = 'results/with-skill.result.json'
                }
                without_skill = [ordered]@{
                    run_directory = 'without_skill'
                    prompt_file = "without_skill/$($runDirectoryNames.Prompt)"
                    run_manifest = "without_skill/$($runDirectoryNames.Run)"
                    result_file = 'results/without-skill.result.json'
                }
            }
            assumptions = @($assumptions)
        }

        ConvertTo-JsonFile -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value $metadata
        ConvertTo-JsonFile -Path (Join-Path $evalDirectory 'results/with-skill.result.json') -Value (New-ResultStub -SkillName $Skill -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'with_skill' -Assertions $assertions)
        ConvertTo-JsonFile -Path (Join-Path $evalDirectory 'results/without-skill.result.json') -Value (New-ResultStub -SkillName $Skill -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'without_skill' -Assertions $assertions)

        Assert-RunIsolation -EvalName $evalName -SkillName $Skill -EvalCaseDirectory $evalDirectory -SkillHash $skillHash -GitWorkspace $workspaceOption.Git

        $manifestEvals.Add([ordered]@{
            eval_id = [int]$evalEntry.id
            eval_name = $evalName
            directory = $evalName
            metadata = "$evalName/eval-metadata.json"
            fixture_hash = $fixtureHash
            skill_hash = $skillHash
            git_workspace = $workspaceOption.Git
            input_files = @($repoFiles)
            runs = [ordered]@{
                with_skill = [ordered]@{
                    mode = 'with_skill'
                    directory = "$evalName/with_skill"
                    run_manifest = "$evalName/with_skill/$($runDirectoryNames.Run)"
                    prompt = "$evalName/with_skill/$($runDirectoryNames.Prompt)"
                    working_directory = "$evalName/with_skill/$($runDirectoryNames.Working)"
                    home_directory = "$evalName/with_skill/$($runDirectoryNames.Home)"
                    skill_directory = "$evalName/with_skill/$($runDirectoryNames.Skill)/$Skill"
                    result = "$evalName/results/with-skill.result.json"
                }
                without_skill = [ordered]@{
                    mode = 'without_skill'
                    directory = "$evalName/without_skill"
                    run_manifest = "$evalName/without_skill/$($runDirectoryNames.Run)"
                    prompt = "$evalName/without_skill/$($runDirectoryNames.Prompt)"
                    working_directory = "$evalName/without_skill/$($runDirectoryNames.Working)"
                    home_directory = "$evalName/without_skill/$($runDirectoryNames.Home)"
                    skill_directory = $null
                    result = "$evalName/results/without-skill.result.json"
                }
            }
        })
    }

    $manifest = [ordered]@{
        schema = $packageSchema
        skill_name = $Skill
        skill_source = "skills/$Skill"
        iteration = $iterationNumber
        generated_utc = $generatedUtc
        configurations = @('with_skill', 'without_skill')
        execution = 'external_handoff'
        runner_prompt = 'RUN-THIS.prompt.md'
        report = [ordered]@{
            tool = $reportToolRelativePath
            html = 'report.html'
            benchmark = 'benchmark.json'
        }
        max_inline_bytes = $MaxInlineBytes
        skill_hash = $skillHash
        isolation = [ordered]@{
            fresh_context_required = $true
            isolated_home_required = $true
            isolated_cwd_required = $true
            filesystem_sandbox_recommended = $true
            candidate_skill_exposure = 'run_directory'
            transcript_capture_requested = $true
            sandbox_root = 'each run directory'
            working_directory = $runDirectoryNames.Working
            home_directory = $runDirectoryNames.Home
        }
        harness_contract = @(
            'fresh context',
            'isolated HOME/config',
            'isolated CWD',
            'filesystem sandbox',
            'candidate skill exposure',
            'transcript capture'
        )
        skill_instructions = [ordered]@{
            inlined = @('SKILL.md') + @($inventory.Inlined | ForEach-Object { $_.Path })
            inlined_resource_bytes = $inventory.InlinedBytes
            staged_full_tree = $true
        }
        evals = @($manifestEvals)
    }
    ConvertTo-JsonFile -Path (Join-Path $iterationDirectory 'manifest.json') -Value $manifest

    Write-Utf8File -Path (Join-Path $iterationDirectory 'README.md') -Content (New-PackageReadme -SkillName $Skill -IterationNumber $iterationNumber -IterationDirectory $iterationDirectory -ManifestEvals @($manifestEvals))
    $runnerPath = Join-Path $iterationDirectory 'RUN-THIS.prompt.md'
    Write-Utf8File -Path $runnerPath -Content (New-RunnerPrompt -IterationDirectory $iterationDirectory -IterationNumber $iterationNumber -ManifestEvals @($manifestEvals))

    Write-Host "Prepared $($manifestEvals.Count) eval case(s) for '$Skill' (iteration $iterationNumber) as $($manifestEvals.Count * 2) hermetic run package(s)."
    Write-Host "Package: $iterationDirectory"
    Write-Host ''
    Write-Host 'Every run is a self-contained directory: repo/ is the working tree, home/ is an isolated'
    Write-Host 'profile, and skill/ (with_skill only) holds the candidate. A harness runs a worker from that'
    Write-Host 'directory alone and never needs the source repository or a globally installed skill.'
    Write-Host ''
    Write-Host 'Hand this one file to the agent of your choice. It drives the whole package:'
    Write-Host "  $runnerPath"
    Write-Host ''
    Write-Host 'Point the harness at that path. Do not reproduce its contents in chat: a pasted copy'
    Write-Host 'loses the absolute paths it depends on, and the harness then cannot find the package.'
    Write-Host ''
    Write-Host 'The runner makes the selected agent the evaluator, grader, and report producer. It must create'
    Write-Host 'one isolated fresh worker per run, then grade the collected results and generate report.html.'
    Write-Host ''
    Write-Host 'This script prepared prompts only. It did not run them, and nothing here will.'
    Write-Host 'The selected evaluator should finish the package in one run. If it cannot write back to this package,'
    Write-Host 'bring back the result objects and use the repository collector as a fallback:'
    Write-Host ("  pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults `"$iterationDirectory`"")
}

function New-RunnerPrompt {
    param(
        [string]$IterationDirectory,
        [int]$IterationNumber,
        [object[]]$ManifestEvals
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('# Run, grade, and report this evaluation package')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('START NOW. You are the evaluator, grader, and report producer for this package. Do not ask me which role to perform, whether to run the workers, or whether to continue to grading. Execute the complete workflow in this one handoff and return the finished report.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Do not execute evaluation prompts in the current agent context. Create an isolated fresh-context worker for every run, then continue in this coordinator context with grading and report generation after all workers finish.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Everything you need is in this directory:')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("    $IterationDirectory")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("This file is `"$(Join-Path $IterationDirectory 'RUN-THIS.prompt.md')`". Use that package path as authoritative. If the package is inaccessible, report the concrete access failure; do not ask the user to choose another workflow.")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("It holds $(@($ManifestEvals).Count) eval case(s), each with a `with_skill` and `without_skill` run. Every run is a self-contained directory that holds a `prompt.md`, a `run.json` contract, a `repo/` working tree, an isolated `home/`, and - for `with_skill` only - a `skill/` directory with the candidate. The runs differ only in whether that candidate skill is present. You run the experiment, grade the completed results, and generate the report.")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('A person selected this harness and handed you this package. That authorizes these runs, grading, aggregation, and report generation. The repository prohibition on automated model evaluation binds repository scripts and the agent that prepared the package; it does not bind the user-directed external executor completing this specific handoff.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Execute now')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('This package assumes the harness can give each run a fresh context, an isolated HOME/config root, an isolated working directory, and a filesystem sandbox scoped to the run directory. A harness that cannot provide fresh, independent sessions is incompatible with these evals. Continue without asking for role clarification, and report per run which guarantees you satisfied - fresh context, isolated HOME/config, isolated CWD, filesystem sandbox, candidate skill exposure, and transcript capture.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Orchestration contract')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('1. For every eval case, create one isolated fresh-context worker for `with_skill` and a second isolated fresh-context worker for `without_skill`. Never reuse a worker or session between runs, between cases, or between iterations.')
    [void]$builder.AppendLine('2. Launch each worker from its own run directory, which is the worker''s sandbox root. Set the working directory to that run''s `repo/`, set HOME and the platform-equivalent profile and config roots to its `home/`, and confine filesystem access to the run directory. Read the run''s `run.json` for the exact contract: `workingDirectory`, `homeDirectory`, `skillDirectory`, and the fresh-context, filesystem, and home isolation flags.')
    [void]$builder.AppendLine('3. Give each worker only its `prompt.md` and the files already staged in its run directory. Do not expose this runner, `manifest.json`, any `eval-metadata.json`, `comparison.md`, result files, grading criteria, expectations, the paired run, another case''s output, or any note that an experiment is underway. All of those live outside the run directory, so keeping the worker inside it keeps them hidden.')
    [void]$builder.AppendLine('4. The candidate skill is already inlined in the with_skill run''s `prompt.md` and staged under its `skill/` directory. Do not load, summarize, or add it yourself. The without_skill run carries no skill instructions and no `skill/` directory; do not expose the candidate skill to that worker by any route, including a globally installed copy.')
    [void]$builder.AppendLine('5. Send each `prompt.md` unchanged as the worker''s first message. The input files are already real files in the worker''s `repo/`; the worker reads and edits them there rather than from attachments.')
    [void]$builder.AppendLine('6. Use the same model, version, configuration, tools, and limits for every worker. Disable persistent memory or cross-session recall. Independent runs may execute concurrently when the selected harness and token budget allow it.')
    [void]$builder.AppendLine('7. Record the worker''s complete response, transcript when available, token usage, elapsed time, and tool-call count. When the harness exposes them, also record the shell commands, files read and written, stdout and stderr, and exit status, and which isolation guarantees you satisfied. Record refusals, questions, and failures as results. Do not retry to improve an answer.')
    [void]$builder.AppendLine('8. Work only inside this package. Do not read or modify the source repository around it. Do not begin grading until every available worker has completed or failed and its result is recorded.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('For each case in `manifest.json`, the `runs.with_skill` and `runs.without_skill` entries give each run''s directory, its `prompt`, its `run_manifest` (`run.json`), and the `result` file to write. Run the two prompts in separate workers, then overwrite the matching result file without reading its existing contents. A partial package is valid: record every completed run, continue to grading/reporting, and mark missing arms honestly instead of asking what to do next.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Result shape')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('```json')
    [void]$builder.AppendLine('{')
    [void]$builder.AppendLine('  "schema": "codebeltnet/agentic/eval-result/2",')
    [void]$builder.AppendLine("  `"iteration`": $IterationNumber,")
    [void]$builder.AppendLine('  "eval_id": 1,')
    [void]$builder.AppendLine('  "eval_name": "the directory name",')
    [void]$builder.AppendLine('  "configuration": "with_skill",')
    [void]$builder.AppendLine('  "model": "the exact model id you used",')
    [void]$builder.AppendLine('  "provider": "who served it",')
    [void]$builder.AppendLine('  "harness": "what you are",')
    [void]$builder.AppendLine('  "executed_utc": "2026-01-01T00:00:00Z",')
    [void]$builder.AppendLine('  "output": "the complete response the run produced",')
    [void]$builder.AppendLine('  "output_files": ["paths of any files the run wrote"],')
    [void]$builder.AppendLine('  "transcript": "the complete worker transcript when the harness exposes it",')
    [void]$builder.AppendLine('  "shell_commands": ["commands the run executed, when exposed"],')
    [void]$builder.AppendLine('  "files_read": ["paths the run read, when exposed"],')
    [void]$builder.AppendLine('  "files_written": ["paths the run wrote, when exposed"],')
    [void]$builder.AppendLine('  "exit_status": 0,')
    [void]$builder.AppendLine('  "duration_seconds": 12.5,')
    [void]$builder.AppendLine('  "total_tokens": 1234,')
    [void]$builder.AppendLine('  "tool_calls": 6,')
    [void]$builder.AppendLine('  "isolation": {')
    [void]$builder.AppendLine('    "fresh_context": true,')
    [void]$builder.AppendLine('    "isolated_home": true,')
    [void]$builder.AppendLine('    "isolated_cwd": true,')
    [void]$builder.AppendLine('    "filesystem_sandbox": true,')
    [void]$builder.AppendLine('    "candidate_skill_exposed": true,')
    [void]$builder.AppendLine('    "transcript_captured": true')
    [void]$builder.AppendLine('  },')
    [void]$builder.AppendLine('  "grading": [],')
    [void]$builder.AppendLine('  "notes": "anything that would change how this result reads"')
    [void]$builder.AppendLine('}')
    [void]$builder.AppendLine('```')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('`transcript`, `shell_commands`, `files_read`, `files_written`, `exit_status`, `duration_seconds`, `total_tokens`, `tool_calls`, and every `isolation` flag are optional. Include each when the harness exposes it and omit it otherwise. Never estimate a missing value. For `with_skill`, set `isolation.candidate_skill_exposed` to how the skill actually reached the worker.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('`configuration` is `with_skill` or `without_skill` and must match the prompt you ran. Read `eval_id` and `eval_name` from `manifest.json`; do not send them to the worker. Put the full model response in `output`. If it is very long, write it beside the result file and list that path in `output_files` with a summary in `output`.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('`output` is the model''s message in full, including questions, caveats, explanations, or a refusal. Tool output is evidence from the run, not a replacement for the model response. Put the full worker event history in `transcript` when the harness exposes it.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Grade and report immediately')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('After all available workers finish, read each eval''s `eval-metadata.json`. Only now may you read `expected_output` and `assertions`; they are the grading key and were intentionally hidden from the workers.')
    [void]$builder.AppendLine('1. Grade every completed result against every assertion. Use deterministic checks for mechanical assertions and concrete output, transcript, and file evidence for process assertions. Use judgement only where the assertion is genuinely qualitative, and say so in the evidence. Never infer a tool or file action from the model''s self-report when process evidence is absent.')
    [void]$builder.AppendLine('2. Write grading back into the matching result file using exactly `grading[].text`, `grading[].passed`, and `grading[].evidence`. Use `passed: null` when an assertion cannot be judged from captured evidence. Do not grade a missing run as passed.')
    [void]$builder.AppendLine(('The package-relative report tool is `' + $reportToolRelativePath + '`. Invoke that staged copy so this handoff stays self-contained.'))
    [void]$builder.AppendLine("3. Run the packaged report tool now; do not ask the user to run a second command: `pwsh -NoProfile -File `"$(Join-Path $IterationDirectory $reportToolRelativePath)`" -IterationDirectory `"$IterationDirectory`"`. It writes `report.html` and `benchmark.json` at the package root, including partial-run status, formal grades, outputs, model/runtime telemetry, isolation evidence, and reviewer notes.")
    [void]$builder.AppendLine('4. If the harness can open local files, open `report.html` after it is written. Otherwise return its absolute path as the primary artifact. Do not wait for browser feedback before finishing the handoff.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The report is the completion artifact. Do not stop after worker execution, do not return a prose-only recap, and do not ask whether grading or HTML generation is wanted.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Final handoff')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The finished artifact is the report, not a request for another command. If you can write to the package machine, leave every result, grading field, `benchmark.json`, and `report.html` in place. Return the absolute report path, the completed/expected run count, any missing arms, the model/provider, and a concise quality summary.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('If you cannot write to the package machine, return one fenced JSON block containing every completed result object, including its `grading` array, plus the generated report as an artifact when the harness supports file handoff. Do not return separate blocks or a human summary in place of the result objects. State any missing arms and the concrete artifact-transfer limitation.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('If you cannot write to that machine - a different product, a browser, a sandbox that shares no disk with it - the results have to travel as text. End with one fenced block, and say plainly that it is meant to be pasted into the repository session as-is:')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('```')
    [void]$builder.AppendLine('Eval results, grading, and report artifact.')
    [void]$builder.AppendLine("Package: $IterationDirectory")
    [void]$builder.AppendLine('Model: <exact id> via <provider>, harness <what you are>')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('<a JSON array of the result objects described above, one per run you completed>')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Still unfilled: <the cases and configurations nobody has run yet>')
    [void]$builder.AppendLine('```')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('One block covering everything you ran, not one per case, and the outputs go in it verbatim - a summary written for a human to skim cannot be graded against assertions.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The repository collector is only a fallback when result files were transferred without the report artifacts: `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults <iteration-path>`. It validates the returned files and regenerates the deterministic comparison and HTML report; it is not the normal next step after this prompt.')

    return $builder.ToString()
}

function New-PackageReadme {
    param(
        [string]$SkillName,
        [int]$IterationNumber,
        [string]$IterationDirectory,
        [object[]]$ManifestEvals
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine("# Eval package: $SkillName (iteration $IterationNumber)")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Prepared by `scripts/prepare-skill-evals.ps1` in `codebeltnet/agentic`. Nothing in this package was executed. You choose the harness, provider, and model; the selected external evaluator runs both configurations, grades them, and generates the report.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## What is here')
    [void]$builder.AppendLine()
    foreach ($entry in $ManifestEvals) {
        [void]$builder.AppendLine("- ``$($entry.eval_name)/`` - eval $($entry.eval_id)")
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Each eval directory holds the grading key (`eval-metadata.json`), result stubs under `results/`, and two hermetic run directories: `with_skill/` and `without_skill/`. A run directory holds `prompt.md`, a `run.json` contract, a `repo/` working tree materialized from the fixtures, an isolated `home/`, and - for `with_skill` only - a `skill/` directory with the candidate skill. The grading key and results sit outside both run directories, so a worker confined to its run directory never sees them.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Isolation model')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The package guarantees what a generator can: identical materialized repositories for both runs, the candidate skill staged only under `with_skill/skill/`, an empty isolated `home/` per run, and a `run.json` that names only paths inside the run directory. Fixture and skill hashes are recorded so you can prove what each worker received.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The harness must supply the rest at runtime: a fresh context per run, the run directory as the working and config root (working directory `repo/`, HOME `home/`), and a filesystem sandbox that keeps the worker inside its run directory so global skills, global config, the source repository, the paired run, and the grading key stay out of reach. Prompt wording alone does not enforce this; the sandbox does.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## How to run')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('1. Pick one model and configuration. Use the same one for every run in this iteration.')
    [void]$builder.AppendLine('2. For each eval, launch a fresh worker for `with_skill/` with its run directory as the sandbox root, `repo/` as the working directory, and `home/` as HOME. Send `prompt.md` as the first message. Read `run.json` for the contract.')
    [void]$builder.AppendLine('3. Launch a second fresh worker for `without_skill/` the same way. Never reuse a worker between runs.')
    [void]$builder.AppendLine('4. Save each response into the matching file under the eval''s `results/` directory, then grade every completed result and run `tools/generate-eval-report.ps1`.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('`RUN-THIS.prompt.md` turns a harness that can create isolated workers or sessions into the evaluator, grader, and report producer. It reads the package, creates one new worker per run from its run directory, keeps runner instructions and grading data out of every worker, records results, grades after collection, and writes `report.html` plus `benchmark.json`. It never executes an eval prompt in its own context.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('A harness that cannot provide fresh, independent sessions with isolated working and config roots is incompatible with these evals. `-CollectResults` accepts a partial iteration and reports unfilled runs as missing.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('A with_skill run on one model compared against a baseline on another measures both the model and the skill. That is not a skill-effectiveness result, so do not report it as one. If you do mix models, say so explicitly and treat the comparison as directional only.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Report artifacts')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Fill in each `results/*.result.json`:')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('- `model`, `provider`, `harness` - what actually ran it, as specifically as you know')
    [void]$builder.AppendLine('- `executed_utc` - when')
    [void]$builder.AppendLine('- `output` - the produced output, or a summary plus paths in `output_files`')
    [void]$builder.AppendLine('- `transcript`, `shell_commands`, `files_read`, `files_written`, `exit_status`, `duration_seconds`, `total_tokens`, `tool_calls` - include the values the harness exposes; omit unavailable values rather than estimating them')
    [void]$builder.AppendLine('- `isolation` - the guarantees the harness satisfied for this run; process-dependent assertions can only be graded from a run that captured the needed evidence')
    [void]$builder.AppendLine('- `grading[].passed` - `true`, `false`, or `null` per assertion once the external evaluator or a deterministic script has checked it, with `evidence`')
    [void]$builder.AppendLine('- `notes` - anything that would change how the result reads')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The normal handoff finishes with these package-root artifacts:')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('```text')
    [void]$builder.AppendLine('report.html     interactive static review with outputs, formal grades, telemetry, and reviewer notes')
    [void]$builder.AppendLine('benchmark.json  machine-readable quality and runtime summary')
    [void]$builder.AppendLine('```')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('If the harness cannot write to the package machine, its final handoff should contain one paste-ready JSON array of completed result objects including grading, plus the report as a file artifact when supported. A prose-only recap is not sufficient.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('For transferred results without report artifacts, the repository-side fallback is `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults <iteration-path>`, which validates the files and regenerates `comparison.md`, `benchmark.json`, and `report.html`.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('This workspace is temporary. Do not commit it to the repository unless someone explicitly asks for a checked-in example.')

    return $builder.ToString()
}

function Get-BaseRef {
    param([string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($Base)) {
        [void](git -C $RepoRoot rev-parse --verify --quiet "$Base^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "Unknown base ref '$Base'."
        }
        return $Base
    }

    foreach ($candidate in @('origin/main', 'main')) {
        [void](git -C $RepoRoot rev-parse --verify --quiet "$candidate^{commit}" 2>$null)
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    return $null
}

function Get-ChangedSkillNames {
    param(
        [string]$RepoRoot,
        [string]$BaseRef
    )

    $paths = [System.Collections.Generic.List[string]]::new()

    # Uncommitted work, staged or not, including files git has never seen.
    $status = git -C $RepoRoot status --porcelain --untracked-files=all -- 'skills' 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($status)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $entry = $line.Substring(2).Trim()
            $arrow = $entry.IndexOf(' -> ', [System.StringComparison]::Ordinal)
            if ($arrow -ge 0) {
                $paths.Add($entry.Substring(0, $arrow).Trim('"'))
                $paths.Add($entry.Substring($arrow + 4).Trim('"'))
            } else {
                $paths.Add($entry.Trim('"'))
            }
        }
    }

    # Everything this branch changed relative to its base.
    if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
        $committed = git -C $RepoRoot diff --name-only "$BaseRef...HEAD" -- 'skills' 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in @($committed)) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $paths.Add($line.Trim('"'))
                }
            }
        }
    }

    $names = foreach ($path in $paths) {
        $segments = ($path -replace '\\', '/').Split('/')
        if ($segments.Length -ge 2 -and $segments[0] -eq 'skills') {
            $segments[1]
        }
    }

    return @($names |
        Sort-Object -Unique |
        Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $RepoRoot 'skills') $_) })
}

function Invoke-ChangedMode {
    $repoRoot = Get-RepoRoot
    $baseRef = Get-BaseRef -RepoRoot $repoRoot
    # An empty pipeline result unrolls to $null on assignment, so keep the array wrapper here.
    $changedSkills = @(Get-ChangedSkillNames -RepoRoot $repoRoot -BaseRef $baseRef)

    $scope = if ([string]::IsNullOrWhiteSpace($baseRef)) { 'the working tree' } else { "$baseRef...HEAD plus the working tree" }
    Write-Host "Changed repo-managed skills in $scope"

    if ($changedSkills.Count -eq 0) {
        Write-Host '  none'
        Write-Host ''
        Write-Host 'No skill changed, so there is nothing to evaluate. The eval gate is satisfied.'
        return
    }

    foreach ($changedSkill in $changedSkills) {
        Write-Host "  $changedSkill"
    }
    Write-Host ''

    foreach ($changedSkill in $changedSkills) {
        Invoke-PrepareMode -SkillName $changedSkill
        Write-Host ''
    }

    Write-Host ("Prepared eval packages for {0} changed skill(s). Hand these prompts to the user; do not run them." -f $changedSkills.Count)
}

function Invoke-CollectMode {
    if (-not (Test-Path -LiteralPath $CollectResults)) {
        throw "Missing eval package directory '$CollectResults'."
    }

    $iterationDirectory = (Resolve-Path -LiteralPath $CollectResults).Path
    $manifestPath = Join-Path $iterationDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "'$iterationDirectory' is not a prepared eval package; manifest.json is missing."
    }

    $manifest = [System.IO.File]::ReadAllText($manifestPath, $utf8NoBom) | ConvertFrom-Json
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($manifest.evals)) {
        $evalDirectory = Join-Path $iterationDirectory $entry.directory
        $metadata = [System.IO.File]::ReadAllText((Join-Path $evalDirectory 'eval-metadata.json'), $utf8NoBom) | ConvertFrom-Json
        $observed = @{}

        foreach ($configuration in @('with_skill', 'without_skill')) {
            $fileName = if ($configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
            $resultPath = Join-Path (Join-Path $evalDirectory 'results') $fileName
            if (-not (Test-Path -LiteralPath $resultPath)) {
                $warnings.Add("$($entry.eval_name)/$configuration - no result file at results/$fileName.")
                continue
            }

            try {
                $result = [System.IO.File]::ReadAllText($resultPath, $utf8NoBom) | ConvertFrom-Json
            } catch {
                $errors.Add("$($entry.eval_name)/$configuration - results/$fileName is not valid JSON: $($_.Exception.Message)")
                continue
            }

            if ([string]$result.configuration -ne $configuration) {
                $errors.Add("$($entry.eval_name)/$configuration - results/$fileName declares configuration '$($result.configuration)'.")
                continue
            }
            if ([int]$result.eval_id -ne [int]$metadata.eval_id) {
                $errors.Add("$($entry.eval_name)/$configuration - results/$fileName declares eval_id $($result.eval_id) but the package says $($metadata.eval_id).")
                continue
            }

            $outputText = [string](Get-JsonProperty -Object $result -Name 'output' -Default '')
            $outputFiles = @(Get-JsonProperty -Object $result -Name 'output_files' -Default @())
            $hasOutput = -not [string]::IsNullOrWhiteSpace($outputText) -or $outputFiles.Count -gt 0
            if (-not $hasOutput) {
                $warnings.Add("$($entry.eval_name)/$configuration - not run yet (empty output and no output_files).")
                continue
            }

            $model = [string](Get-JsonProperty -Object $result -Name 'model' -Default '')
            if ([string]::IsNullOrWhiteSpace($model)) {
                $warnings.Add("$($entry.eval_name)/$configuration - no model recorded, so this arm cannot back a controlled comparison.")
            }

            # A transferred or partial result may arrive without grading. Fall back to the assertion count from the
            # package so the row still shows how much is left to check.
            $grading = @(Get-JsonProperty -Object $result -Name 'grading' -Default @())
            $graded = @($grading | Where-Object { $null -ne (Get-JsonProperty -Object $_ -Name 'passed') })
            $passed = @($graded | Where-Object { [bool]$_.passed }).Count
            $total = if ($grading.Count -gt 0) { $grading.Count } else { @($metadata.assertions).Count }
            if ($graded.Count -eq 0) {
                $warnings.Add("$($entry.eval_name)/$configuration - ran but nothing is graded yet; $total assertion(s) still need a deterministic check or human judgement.")
            }

            $transcriptText = [string](Get-JsonProperty -Object $result -Name 'transcript' -Default '')
            $shellCommands = @(Get-JsonProperty -Object $result -Name 'shell_commands' -Default @())
            $filesRead = @(Get-JsonProperty -Object $result -Name 'files_read' -Default @())
            $filesWritten = @(Get-JsonProperty -Object $result -Name 'files_written' -Default @())
            $hasProcessEvidence = (-not [string]::IsNullOrWhiteSpace($transcriptText)) -or $shellCommands.Count -gt 0 -or $filesRead.Count -gt 0 -or $filesWritten.Count -gt 0
            if (-not $hasProcessEvidence) {
                $warnings.Add("$($entry.eval_name)/$configuration - no transcript or process evidence recorded; assertions about tool, shell, or file behavior are ungradeable for this run and must not be inferred from the model's self-report.")
            }

            $isolation = Get-JsonProperty -Object $result -Name 'isolation' -Default $null
            $isolationReport = Format-IsolationReport -Isolation $isolation

            $observed[$configuration] = [pscustomobject]@{
                Model = $model
                Provider = [string](Get-JsonProperty -Object $result -Name 'provider' -Default '')
                Graded = $graded.Count
                Passed = $passed
                Total = $total
                TranscriptRecorded = -not [string]::IsNullOrWhiteSpace($transcriptText)
                ProcessEvidence = $hasProcessEvidence
                IsolationReport = $isolationReport
                DurationSeconds = Get-JsonProperty -Object $result -Name 'duration_seconds'
                TotalTokens = Get-JsonProperty -Object $result -Name 'total_tokens'
                ToolCalls = Get-JsonProperty -Object $result -Name 'tool_calls'
            }
        }

        $withSkill = if ($observed.ContainsKey('with_skill')) { $observed['with_skill'] } else { $null }
        $withoutSkill = if ($observed.ContainsKey('without_skill')) { $observed['without_skill'] } else { $null }

        if ($null -ne $withSkill -and $null -ne $withoutSkill) {
            if ($withSkill.Model -ne $withoutSkill.Model) {
                $warnings.Add("$($entry.eval_name) - with_skill ran on '$($withSkill.Model)' and without_skill on '$($withoutSkill.Model)'. That comparison measures the model as well as the skill.")
            }
        } elseif ($null -ne $withSkill -or $null -ne $withoutSkill) {
            $warnings.Add("$($entry.eval_name) - only one configuration has a result, so there is no controlled comparison yet.")
        }

        $rows.Add([pscustomobject]@{
            EvalName = $entry.eval_name
            WithSkill = $withSkill
            WithoutSkill = $withoutSkill
            Assertions = @($metadata.assertions).Count
        })
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine("# Eval comparison: $($manifest.skill_name) (iteration $($manifest.iteration))")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('This repository-side comparison validates recorded grading and never invokes a model. Grading may have been performed by the user-directed external evaluator before this report was generated.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Eval | Assertions | with_skill model | with_skill graded | without_skill model | without_skill graded |')
    [void]$builder.AppendLine('| --- | --- | --- | --- | --- | --- |')

    foreach ($row in $rows) {
        $withModel = if ($null -ne $row.WithSkill) { $row.WithSkill.Model } else { '-' }
        $withGraded = if ($null -ne $row.WithSkill) { "$($row.WithSkill.Passed)/$($row.WithSkill.Graded) of $($row.WithSkill.Total)" } else { 'not run' }
        $withoutModel = if ($null -ne $row.WithoutSkill) { $row.WithoutSkill.Model } else { '-' }
        $withoutGraded = if ($null -ne $row.WithoutSkill) { "$($row.WithoutSkill.Passed)/$($row.WithoutSkill.Graded) of $($row.WithoutSkill.Total)" } else { 'not run' }
        [void]$builder.AppendLine("| $($row.EvalName) | $($row.Assertions) | $withModel | $withGraded | $withoutModel | $withoutGraded |")
    }

    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Run metrics')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Eval | Configuration | Duration (s) | Tokens | Tool calls | Transcript |')
    [void]$builder.AppendLine('| --- | --- | --- | --- | --- | --- |')
    foreach ($row in $rows) {
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $run = if ($configuration -eq 'with_skill') { $row.WithSkill } else { $row.WithoutSkill }
            $duration = if ($null -ne $run -and $null -ne $run.DurationSeconds -and -not [string]::IsNullOrWhiteSpace([string]$run.DurationSeconds)) { [string]$run.DurationSeconds } else { '-' }
            $tokens = if ($null -ne $run -and $null -ne $run.TotalTokens -and -not [string]::IsNullOrWhiteSpace([string]$run.TotalTokens)) { [string]$run.TotalTokens } else { '-' }
            $toolCalls = if ($null -ne $run -and $null -ne $run.ToolCalls -and -not [string]::IsNullOrWhiteSpace([string]$run.ToolCalls)) { [string]$run.ToolCalls } else { '-' }
            $transcript = if ($null -ne $run -and $run.TranscriptRecorded) { 'recorded' } else { '-' }
            [void]$builder.AppendLine("| $($row.EvalName) | $configuration | $duration | $tokens | $toolCalls | $transcript |")
        }
    }

    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Isolation reported')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Flags each run''s harness confirmed: fresh context, isolated home, isolated cwd, filesystem sandbox, candidate skill exposure, transcript capture (Y/N, ? unknown). Process-dependent assertions are only gradeable from a run with process evidence.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Eval | Configuration | Isolation | Process evidence |')
    [void]$builder.AppendLine('| --- | --- | --- | --- |')
    foreach ($row in $rows) {
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $run = if ($configuration -eq 'with_skill') { $row.WithSkill } else { $row.WithoutSkill }
            $isolationReport = if ($null -ne $run) { $run.IsolationReport } else { '-' }
            $evidence = if ($null -ne $run -and $run.ProcessEvidence) { 'yes' } elseif ($null -ne $run) { 'none' } else { '-' }
            [void]$builder.AppendLine("| $($row.EvalName) | $configuration | $isolationReport | $evidence |")
        }
    }

    if ($warnings.Count -gt 0) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('## Open items')
        [void]$builder.AppendLine()
        foreach ($warning in $warnings) {
            [void]$builder.AppendLine("- $warning")
        }
    }

    $comparisonPath = Join-Path $iterationDirectory 'comparison.md'
    Write-Utf8File -Path $comparisonPath -Content ($builder.ToString().TrimEnd() + [Environment]::NewLine)

    Write-Host $builder.ToString().TrimEnd()
    Write-Host ''
    Write-Host "Wrote $comparisonPath"

    $reportScript = Join-Path (Join-Path (Get-RepoRoot) 'scripts') 'generate-eval-report.ps1'
    $reportOutput = & pwsh -NoProfile -File $reportScript -IterationDirectory $iterationDirectory 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errors.Add("Report generation failed: $($reportOutput -join [Environment]::NewLine)")
    } else {
        foreach ($line in @($reportOutput)) {
            Write-Host $line
        }
    }

    if ($errors.Count -gt 0) {
        Write-Host ''
        Write-Host 'Result files rejected:'
        foreach ($errorMessage in $errors) {
            Write-Host "  $errorMessage"
        }
        exit 1
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Collect' { Invoke-CollectMode }
    'Changed' { Invoke-ChangedMode }
    default { Invoke-PrepareMode }
}
