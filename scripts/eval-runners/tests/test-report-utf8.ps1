<#
.SYNOPSIS
    Windows UTF-8 report-generation regression (model-free).

.DESCRIPTION
    OpenCode's forensic iteration-5 exposed a real Windows encoding problem: the
    packaged upstream Anthropic skill-creator viewer reads model output and
    writes the static HTML report using the platform default encoding (cp1252 on
    Windows), so non-ASCII evidence is silently corrupted (and, for characters
    outside cp1252, generation can fail outright).

    generate-eval-report.ps1 fixes this centrally by forcing CPython UTF-8 Mode
    (PYTHONUTF8=1 / PYTHONIOENCODING=utf-8) for every upstream Python invocation,
    WITHOUT modifying any packaged upstream Python source. This test proves the
    fix against the real, unmodified upstream generate_review.py: with UTF-8 Mode
    the generated report embeds the correct code points (\u2615, \u65e5); on
    Windows without it, the same run corrupts them. It never invokes a model.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

$repoScriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$reportScriptPath = Join-Path $repoScriptsRoot 'generate-eval-report.ps1'
$reportScript = [System.IO.File]::ReadAllText($reportScriptPath, [System.Text.UTF8Encoding]::new($false))

# 1. The fix must be wired into the shared report invocation, not into upstream.
Assert-True ($reportScript -match "PYTHONUTF8\s*=\s*'1'") 'generate-eval-report.ps1 forces CPython UTF-8 Mode for upstream Python tooling'
Assert-True ($reportScript -match "PYTHONIOENCODING\s*=\s*'utf-8'") 'generate-eval-report.ps1 forces UTF-8 Python stdio encoding'

function Resolve-PythonCommand {
    foreach ($name in @('python', 'py')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return [string]$command.Source }
    }
    return $null
}

function Resolve-SkillCreatorPath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:SKILL_CREATOR_PATH)) { $candidates.Add($env:SKILL_CREATOR_PATH) }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path $env:USERPROFILE '.agents/skills/skill-creator'))
        $candidates.Add((Join-Path $env:USERPROFILE '.claude/skills/skill-creator'))
        $candidates.Add((Join-Path $env:USERPROFILE '.gemini/antigravity-cli/skills/skill-creator'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        $candidates.Add((Join-Path $env:HOME '.agents/skills/skill-creator'))
        $candidates.Add((Join-Path $env:HOME '.claude/skills/skill-creator'))
    }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath (Join-Path $candidate 'eval-viewer/generate_review.py'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

$pythonCommand = Resolve-PythonCommand
$skillCreatorPath = Resolve-SkillCreatorPath
if ($null -eq $pythonCommand -or $null -eq $skillCreatorPath) {
    Write-Output 'Report UTF-8 regression: SKIP (python or upstream skill-creator viewer unavailable in this environment)'
    exit 0
}

$viewerPath = Join-Path $skillCreatorPath 'eval-viewer/generate_review.py'
$viewerBytesBefore = [System.IO.File]::ReadAllBytes($viewerPath)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# A coffee glyph (U+2615) and a CJK ideograph (U+65E5) are both outside cp1252;
# with correct UTF-8 reading the upstream viewer embeds them as \u2615 / \u65e5.
$coffee = [char]0x2615
$sun = [char]0x65E5
$marker = "MARKER cafe $coffee $sun done"

$workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-report-utf8-' + [Guid]::NewGuid().ToString('N'))
try {
    $runDirectory = Join-Path $workspaceRoot 'eval-1\with_skill\run-1'
    $outputsDirectory = Join-Path $runDirectory 'outputs'
    New-Item -ItemType Directory -Path $outputsDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $runDirectory 'eval_metadata.json'), '{"prompt":"probe prompt","eval_id":1}', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $runDirectory 'grading.json'), '{"expectations":[{"text":"t","passed":true,"evidence":"e"}],"summary":{"passed":1,"failed":0,"total":1}}', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $outputsDirectory 'output.md'), $marker, $utf8NoBom)

    function Invoke-Viewer {
        param([string]$Label, [bool]$Utf8Mode)

        $previousUtf8 = [Environment]::GetEnvironmentVariable('PYTHONUTF8')
        $previousIo = [Environment]::GetEnvironmentVariable('PYTHONIOENCODING')
        if ($Utf8Mode) {
            $env:PYTHONUTF8 = '1'
            $env:PYTHONIOENCODING = 'utf-8'
        } else {
            Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        $outputHtml = Join-Path $workspaceRoot "report-$Label.html"
        try {
            $viewerOutput = & $pythonCommand $viewerPath $workspaceRoot '--skill-name' 'report-utf8-probe' '--static' $outputHtml 2>&1
            $exit = $LASTEXITCODE
        } finally {
            if ($null -eq $previousUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $previousUtf8 }
            if ($null -eq $previousIo) { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue } else { $env:PYTHONIOENCODING = $previousIo }
        }
        return [pscustomobject]@{
            ExitCode = $exit
            Output = [string]::Join([Environment]::NewLine, @($viewerOutput))
            Html = if (Test-Path -LiteralPath $outputHtml -PathType Leaf) { [System.IO.File]::ReadAllText($outputHtml, $utf8NoBom) } else { $null }
        }
    }

    # With the fix, the unmodified upstream viewer must succeed and embed the
    # correct code points for the non-ASCII evidence.
    $withFix = Invoke-Viewer -Label 'withfix' -Utf8Mode $true
    Assert-True ($withFix.ExitCode -eq 0) "upstream viewer succeeds under UTF-8 Mode: $($withFix.Output)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($withFix.Html)) 'upstream viewer writes a non-empty static report under UTF-8 Mode'
    Assert-True ($withFix.Html.Contains('\u2615')) 'UTF-8 Mode report preserves the coffee code point (U+2615) as correct evidence'
    Assert-True ($withFix.Html.Contains('\u65e5')) 'UTF-8 Mode report preserves the CJK code point (U+65E5) as correct evidence'

    # On Windows the default is cp1252, so the same unmodified viewer WITHOUT the
    # fix corrupts the evidence: the correct code points do not appear. This
    # proves the central fix is necessary. Non-Windows defaults are already
    # UTF-8, so only assert the necessity where the platform default differs.
    if ($IsWindows) {
        $withoutFix = Invoke-Viewer -Label 'nofix' -Utf8Mode $false
        Assert-True (-not ($withoutFix.Html -and $withoutFix.Html.Contains('\u2615'))) 'without UTF-8 Mode the Windows default (cp1252) corrupts non-ASCII evidence, proving the fix is required'
    }

    # The packaged upstream Python source must be byte-identical: the fix is in
    # the invocation, never in upstream files.
    $viewerBytesAfter = [System.IO.File]::ReadAllBytes($viewerPath)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$viewerBytesBefore, [byte[]]$viewerBytesAfter)) 'upstream generate_review.py remains byte-identical; the fix never patches upstream Python'

    Write-Output 'Report UTF-8 regression: PASS'
} finally {
    if (Test-Path -LiteralPath $workspaceRoot) { Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
