param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$RunRoot,

    [Parameter(Mandatory = $true)]
    [string]$TranscriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultSummaryPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $OutputsPath -Force | Out-Null

$summary = ''
$exitCode = 0

switch ("$($context.eval_id):$($context.configuration)") {
    '1:with_skill' {
        Start-Sleep -Seconds 2
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'assistant-response.md'), "mock executor completed with skill`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'changed-files.md'), "## changed files`n- src\Mock.cs`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $RunRoot 'repo\src\Mock.cs'), "public static class Mock { public const string Mode = ""with_skill""; }`n", $utf8NoBom)
        $summary = 'Mock with-skill execution completed.'
    }
    '1:without_skill' {
        Start-Sleep -Seconds 2
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'assistant-response.md'), "mock executor completed without skill`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'changed-files.md'), "## changed files`n- src\Mock.cs`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $RunRoot 'repo\src\Mock.cs'), "public static class Mock { public const string Mode = ""without_skill""; }`n", $utf8NoBom)
        $summary = 'Mock baseline execution completed.'
    }
    '2:with_skill' {
        $childInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $childInfo.FileName = 'pwsh'
        $childInfo.ArgumentList.Add('-NoProfile')
        $childInfo.ArgumentList.Add('-Command')
        $childInfo.ArgumentList.Add('Start-Sleep -Seconds 300')
        $childInfo.UseShellExecute = $false
        $child = [System.Diagnostics.Process]::Start($childInfo)
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'child.pid'), "$($child.Id)`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'assistant-response.md'), "mock executor hanging to test timeout`n", $utf8NoBom)
        Start-Sleep -Seconds 300
        $summary = 'This line should never be reached.'
    }
    '2:without_skill' {
        Start-Sleep -Seconds 1
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'assistant-response.md'), "mock executor failed without skill`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'changed-files.md'), "## changed files`n- src\Broken.cs`n", $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $RunRoot 'repo\src\Broken.cs'), "public static class Broken { }`n", $utf8NoBom)
        $summary = 'Mock baseline execution failed.'
        $exitCode = 9
    }
    default {
        Start-Sleep -Seconds 1
        [System.IO.File]::WriteAllText((Join-Path $OutputsPath 'assistant-response.md'), "mock executor default path`n", $utf8NoBom)
        $summary = 'Mock execution completed.'
    }
}

[System.IO.File]::WriteAllText($TranscriptPath, @"
# Mock Transcript

## Eval Prompt

$($context.prompt)

## Result

$summary
"@, $utf8NoBom)
[System.IO.File]::WriteAllText($ResultSummaryPath, $summary + [Environment]::NewLine, $utf8NoBom)
exit $exitCode
