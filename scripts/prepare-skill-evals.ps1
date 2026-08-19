<#
.SYNOPSIS
    Prepares portable with-skill and baseline eval prompts for a repo-managed skill, and collects externally produced results.

.DESCRIPTION
    This script computes and prints. It never executes a prompt, never spawns an agent, and never calls a model.
    It turns skills/<name>/evals/evals.json into a paste-ready evaluation package that a human can run in whatever
    harness, provider, and model they choose, then validates the results that come back.

    Prepare mode writes one directory per eval containing:
      with-skill.prompt.md      the task with the effective skill instructions inlined
      without-skill.prompt.md   the same task, same inputs, same response contract, no skill
      eval-metadata.json        id, name, prompt, expected output, assertions, fixtures, assumptions
      files/                    the eval fixtures, copied verbatim
      results/                  one prefilled result stub per configuration

    Collect mode reads a prepared package plus whatever result files were filled in, validates them, and writes a
    deterministic comparison. Grading stays deterministic or human; nothing here grades with a model.

.PARAMETER Skill
    Name of the repo-managed skill under skills/.

.PARAMETER Eval
    Optional eval ids to include. Defaults to every eval in the skill's evals.json.

.PARAMETER Iteration
    Iteration number to write. Defaults to the next unused iteration in the workspace.

.PARAMETER OutputRoot
    Workspace root. Defaults to <temp>/<skill>-workspace. Must be outside this repository.

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
    Path to a prepared iteration directory. Validates the result files in it and writes comparison.md.

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

$packageSchema = 'codebeltnet/agentic/eval-package/1'
$metadataSchema = 'codebeltnet/agentic/eval-metadata/1'
$resultSchema = 'codebeltnet/agentic/eval-result/1'
$maxFixtureInlineBytes = 32768

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
        [void]$builder.AppendLine("These files belong to the skill but are too large, not text, or not referenced from its main instructions. They are bundled in the eval package under ``skill/$SkillName/``. Use them only if your environment can read that directory; otherwise work from the instructions above and say what you could not reach.")
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
    [void]$builder.AppendLine('These files are the input for the task. They are also bundled next to this prompt under `files/` in the eval package.')
    [void]$builder.AppendLine()

    foreach ($fixture in $Fixtures) {
        [void]$builder.AppendLine("## ``$($fixture.PackagePath)``")
        [void]$builder.AppendLine()
        if ($fixture.Inlined) {
            $fixtureText = $fixture.Content.TrimEnd()
            $fence = Get-Fence -Content $fixtureText
            [void]$builder.AppendLine($fence + $fixture.Language)
            [void]$builder.AppendLine($fixtureText)
            [void]$builder.AppendLine($fence)
        } else {
            [void]$builder.AppendLine("Not inlined ($($fixture.Bytes) bytes, $($fixture.SkipReason)). Attach ``$($fixture.PackagePath)`` from the eval package.")
        }
        [void]$builder.AppendLine()
    }

    return $builder.ToString().TrimEnd()
}

function New-PromptDocument {
    param(
        [int]$IterationNumber,
        [object]$EvalEntry,
        [string]$EvalName,
        [string]$Configuration,
        [string]$InstructionSection,
        [string]$InputFilesSection,
        [string]$GeneratedUtc
    )

    # The skill name is deliberately absent from this header. Naming it would tell a baseline run which skill it is
    # being compared against, and the baseline must reach the task with nothing but its normal capabilities.
    $header = @"
<!--
codebeltnet/agentic portable eval prompt
iteration: $IterationNumber
eval_id: $($EvalEntry.id)
eval_name: $EvalName
configuration: $Configuration
generated_utc: $GeneratedUtc
Paste this entire file as the first message to the model under test.
-->
"@

    $sections = [System.Collections.Generic.List[string]]::new()
    $sections.Add($header)
    $sections.Add($InstructionSection)
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
        grading = @($grading)
        notes = ''
    }
}

function Get-Assertions {
    param([object]$EvalEntry)

    if ($EvalEntry.PSObject.Properties.Name -contains 'expectations' -and $null -ne $EvalEntry.expectations) {
        return @($EvalEntry.expectations | ForEach-Object { [string]$_ })
    }

    return @()
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
        Join-Path ([System.IO.Path]::GetTempPath()) "$Skill-workspace"
    } else {
        $OutputRoot
    }
    $workspaceRoot = [System.IO.Path]::GetFullPath($workspaceRoot, (Get-Location).Path)
    if (Test-IsInsidePath -BasePath $repoRoot -CandidatePath $workspaceRoot) {
        throw "Eval workspaces must live outside this repository. '$workspaceRoot' is inside '$repoRoot'."
    }
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

    $skillText = [System.IO.File]::ReadAllText($skillMarkdownPath, $utf8NoBom)
    $skillBody = if ($skillText -match '(?ms)\A---\r?\n.*?\r?\n---\r?\n(?<body>.*)\z') { $Matches['body'] } else { $skillText }

    $inventory = Get-SkillFileInventory -SkillDirectory $skillDirectory -SkillBody $skillBody -Budget $MaxInlineBytes

    $bundledSkillDirectory = Join-Path (Join-Path $iterationDirectory 'skill') $Skill
    New-Item -ItemType Directory -Path $bundledSkillDirectory -Force | Out-Null
    Copy-Item -LiteralPath $skillMarkdownPath -Destination (Join-Path $bundledSkillDirectory 'SKILL.md') -Force
    foreach ($item in @($inventory.Inlined) + @($inventory.Bundled)) {
        $destination = Join-Path $bundledSkillDirectory ($item.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $item.FullPath -Destination $destination -Force
    }

    $generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $withSkillInstructions = New-SkillInstructionSection -SkillName $Skill -SkillBody $skillBody -Inventory $inventory
    $manifestEvals = [System.Collections.Generic.List[object]]::new()

    foreach ($evalEntry in $selectedEvals) {
        $evalName = Get-EvalName -EvalEntry $evalEntry
        $evalDirectory = Join-Path $iterationDirectory $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null

        $fixtures = [System.Collections.Generic.List[object]]::new()
        if ($evalEntry.PSObject.Properties.Name -contains 'files' -and $null -ne $evalEntry.files) {
            foreach ($fixturePath in @($evalEntry.files)) {
                $normalized = ([string]$fixturePath).Trim() -replace '\\', '/'
                $sourcePath = Join-Path $skillDirectory ($normalized -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $sourcePath)) {
                    throw "Missing fixture 'skills/$Skill/$normalized' referenced by eval $($evalEntry.id)."
                }

                $packageRelative = 'files/' + ($normalized -replace '^evals/files/', '')
                $destination = Join-Path $evalDirectory ($packageRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                $destinationDirectory = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                }
                Copy-Item -LiteralPath $sourcePath -Destination $destination -Force

                $bytes = (Get-Item -LiteralPath $sourcePath).Length
                $isBinary = Test-IsBinaryFile -Path $sourcePath
                $skipReason = if ($isBinary) { 'not text' } elseif ($bytes -gt $maxFixtureInlineBytes) { "over the $maxFixtureInlineBytes-byte inline cap" } else { $null }

                $fixtures.Add([pscustomobject]@{
                    EvalPath = $normalized
                    PackagePath = $packageRelative
                    Bytes = $bytes
                    Inlined = $null -eq $skipReason
                    SkipReason = $skipReason
                    Language = Get-FenceLanguage -Path $sourcePath
                    Content = if ($null -eq $skipReason) { [System.IO.File]::ReadAllText($sourcePath, $utf8NoBom) } else { '' }
                })
            }
        }

        $inputFilesSection = New-InputFilesSection -Fixtures @($fixtures)
        $assertions = Get-Assertions -EvalEntry $evalEntry

        $withSkillPrompt = New-PromptDocument -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'with_skill' -InstructionSection $withSkillInstructions -InputFilesSection $inputFilesSection -GeneratedUtc $generatedUtc
        $withoutSkillPrompt = New-PromptDocument -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'without_skill' -InstructionSection $withoutSkillPreamble -InputFilesSection $inputFilesSection -GeneratedUtc $generatedUtc

        Write-Utf8File -Path (Join-Path $evalDirectory 'with-skill.prompt.md') -Content $withSkillPrompt
        Write-Utf8File -Path (Join-Path $evalDirectory 'without-skill.prompt.md') -Content $withoutSkillPrompt

        $assumptions = [System.Collections.Generic.List[string]]::new()
        $assumptions.Add('Run with_skill and without_skill on the same model, same version, and same configuration. Different models measure the model, not the skill.')
        $assumptions.Add('Both prompts carry the same task, the same input files, and the same response contract. Only the operating-instructions section differs.')
        $assumptions.Add("The with_skill prompt inlines skills/$Skill/SKILL.md plus $(@($inventory.Inlined).Count) referenced resource file(s).")
        if (@($inventory.Bundled).Count -gt 0) {
            $assumptions.Add("$(@($inventory.Bundled).Count) skill file(s) are bundled under skill/$Skill/ instead of inlined; a harness without filesystem access to the package cannot reach them.")
        }
        $notInlinedFixtures = @($fixtures | Where-Object { -not $_.Inlined })
        if ($notInlinedFixtures.Count -gt 0) {
            $assumptions.Add("$($notInlinedFixtures.Count) input file(s) are attached under files/ rather than inlined; attach them identically to both configurations.")
        }
        $assumptions.Add('The expected output and assertions in this file are the grading key. Do not paste them into either prompt.')

        $metadata = [ordered]@{
            schema = $metadataSchema
            skill_name = $Skill
            iteration = $iterationNumber
            eval_id = [int]$evalEntry.id
            eval_name = $evalName
            prompt = [string]$evalEntry.prompt
            expected_output = [string]$evalEntry.expected_output
            assertions = @($assertions)
            input_files = @($fixtures | ForEach-Object {
                [ordered]@{
                    eval_path = $_.EvalPath
                    package_path = $_.PackagePath
                    bytes = $_.Bytes
                    inlined = $_.Inlined
                }
            })
            configurations = [ordered]@{
                with_skill = [ordered]@{
                    prompt_file = 'with-skill.prompt.md'
                    result_file = 'results/with-skill.result.json'
                }
                without_skill = [ordered]@{
                    prompt_file = 'without-skill.prompt.md'
                    result_file = 'results/without-skill.result.json'
                }
            }
            assumptions = @($assumptions)
        }

        ConvertTo-JsonFile -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value $metadata
        ConvertTo-JsonFile -Path (Join-Path $evalDirectory 'results/with-skill.result.json') -Value (New-ResultStub -SkillName $Skill -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'with_skill' -Assertions $assertions)
        ConvertTo-JsonFile -Path (Join-Path $evalDirectory 'results/without-skill.result.json') -Value (New-ResultStub -SkillName $Skill -IterationNumber $iterationNumber -EvalEntry $evalEntry -EvalName $evalName -Configuration 'without_skill' -Assertions $assertions)

        $manifestEvals.Add([ordered]@{
            eval_id = [int]$evalEntry.id
            eval_name = $evalName
            directory = $evalName
            with_skill_prompt = "$evalName/with-skill.prompt.md"
            without_skill_prompt = "$evalName/without-skill.prompt.md"
            metadata = "$evalName/eval-metadata.json"
            input_files = @($fixtures | ForEach-Object { $_.PackagePath })
        })
    }

    $manifest = [ordered]@{
        schema = $packageSchema
        skill_name = $Skill
        skill_source = "skills/$Skill"
        iteration = $iterationNumber
        generated_utc = $generatedUtc
        configurations = @('with_skill', 'without_skill')
        execution = 'manual'
        max_inline_bytes = $MaxInlineBytes
        skill_instructions = [ordered]@{
            inlined = @('SKILL.md') + @($inventory.Inlined | ForEach-Object { $_.Path })
            inlined_resource_bytes = $inventory.InlinedBytes
            bundled_only = @($inventory.Bundled | ForEach-Object { $_.Path })
        }
        evals = @($manifestEvals)
    }
    ConvertTo-JsonFile -Path (Join-Path $iterationDirectory 'manifest.json') -Value $manifest

    Write-Utf8File -Path (Join-Path $iterationDirectory 'README.md') -Content (New-PackageReadme -SkillName $Skill -IterationNumber $iterationNumber -IterationDirectory $iterationDirectory -ManifestEvals @($manifestEvals))

    Write-Host "Prepared $($manifestEvals.Count) eval case(s) for '$Skill' (iteration $iterationNumber)."
    Write-Host "Package: $iterationDirectory"
    Write-Host ''
    Write-Host 'Ready for external execution:'
    foreach ($entry in $manifestEvals) {
        Write-Host ("  {0}" -f $entry.eval_name)
        Write-Host ("    with_skill    {0}" -f (Join-Path $iterationDirectory ($entry.with_skill_prompt -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
        Write-Host ("    without_skill {0}" -f (Join-Path $iterationDirectory ($entry.without_skill_prompt -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    }
    Write-Host ''
    Write-Host 'This script prepared prompts only. It did not run them, and nothing here will.'
    Write-Host 'Run both configurations yourself on the same model and configuration, record each result in the matching results/*.result.json, then run:'
    Write-Host ("  pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults `"$iterationDirectory`"")
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
    [void]$builder.AppendLine('Prepared by `scripts/prepare-skill-evals.ps1` in `codebeltnet/agentic`. Nothing in this package was executed. You choose the harness, provider, and model, and you run both configurations.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## What is here')
    [void]$builder.AppendLine()
    foreach ($entry in $ManifestEvals) {
        [void]$builder.AppendLine("- ``$($entry.eval_name)/`` - eval $($entry.eval_id)")
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Each eval directory holds `with-skill.prompt.md`, `without-skill.prompt.md`, `eval-metadata.json`, the input files under `files/`, and result stubs under `results/`. The complete skill tree is bundled under `skill/` for harnesses that can read files.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## How to run')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('1. Pick one model and one configuration. Use the same one for every prompt in this iteration.')
    [void]$builder.AppendLine('2. Paste `with-skill.prompt.md` as the first message of a fresh session. Attach any file listed under `files/` that the prompt says is not inlined.')
    [void]$builder.AppendLine('3. Paste `without-skill.prompt.md` in a separate fresh session, with the same attachments.')
    [void]$builder.AppendLine('4. Save each response into the matching file under the eval''s `results/` directory.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('A with-skill run on one model compared against a baseline on another measures both the model and the skill. That is not a skill-effectiveness result, so do not report it as one. If you do mix models, say so explicitly and treat the comparison as directional only.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Reporting results back')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Fill in each `results/*.result.json`:')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('- `model`, `provider`, `harness` - what actually ran it, as specifically as you know')
    [void]$builder.AppendLine('- `executed_utc` - when')
    [void]$builder.AppendLine('- `output` - the produced output, or a summary plus paths in `output_files`')
    [void]$builder.AppendLine('- `grading[].passed` - `true` or `false` per assertion once you or a deterministic script has checked it, with `evidence`')
    [void]$builder.AppendLine('- `notes` - anything that would change how the result reads')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Then validate and compare:')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('```console')
    [void]$builder.AppendLine("pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults `"$IterationDirectory`"")
    [void]$builder.AppendLine('```')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('You can also hand the filled-in result files straight to an agent working in the repository. It reads `eval_id`, `configuration`, `model`, and `output`, and grades against the assertions in `eval-metadata.json` using deterministic checks and human judgment.')
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
    $changedSkills = Get-ChangedSkillNames -RepoRoot $repoRoot -BaseRef $baseRef

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

            $hasOutput = -not [string]::IsNullOrWhiteSpace([string]$result.output) -or @($result.output_files).Count -gt 0
            if (-not $hasOutput) {
                $warnings.Add("$($entry.eval_name)/$configuration - not run yet (empty output and no output_files).")
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$result.model)) {
                $warnings.Add("$($entry.eval_name)/$configuration - no model recorded, so this arm cannot back a controlled comparison.")
            }

            $graded = @($result.grading | Where-Object { $null -ne $_.passed })
            $passed = @($graded | Where-Object { [bool]$_.passed }).Count
            $total = @($result.grading).Count

            $observed[$configuration] = [pscustomobject]@{
                Model = [string]$result.model
                Provider = [string]$result.provider
                Graded = $graded.Count
                Passed = $passed
                Total = $total
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
    [void]$builder.AppendLine('Assertion grading is deterministic or human. No model graded anything here.')
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
