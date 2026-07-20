[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repairScript = Join-Path $PSScriptRoot 'repair-roslyn-multiproject-artifacts.ps1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempRoot ('agent-smith-roslyn-artifact-' + [guid]::NewGuid().ToString('N'))))
if (-not $testRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Test workspace escaped the temporary root: $testRoot"
}

function Write-Utf8Fixture {
    param(
        [string] $Path,
        [string] $Text,
        [bool] $Bom = $false
    )

    $content = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (-not $Bom) {
        [System.IO.File]::WriteAllBytes($Path, $content)
        return
    }

    $bytes = [byte[]]::new($content.Length + 3)
    $bytes[0] = 0xEF
    $bytes[1] = 0xBB
    $bytes[2] = 0xBF
    [Array]::Copy($content, 0, $bytes, 3, $content.Length)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-Repair {
    param(
        [string] $Path,
        [switch] $Apply
    )

    $arguments = @('-NoProfile', '-File', $repairScript, '-Path', $Path)
    if ($Apply) { $arguments += '-Apply' }
    $output = & pwsh @arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join [Environment]::NewLine)
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string] $Message
    )

    if ($Expected -cne $Actual) {
        throw "$Message Expected: [$Expected] Actual: [$Actual]"
    }
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $recoverable = Join-Path $testRoot 'Recoverable.cs'
    $blockedRecoverable = Join-Path $testRoot 'BlockedRecoverable.cs'
    $unsafe = Join-Path $testRoot 'Unsafe.cs'
    $unsupportedLocalized = Join-Path $testRoot 'UnsupportedLocalized.cs'
    $clean = Join-Path $testRoot 'Clean.cs'
    $crlf = "`r`n"
    $lf = "`n"

    $recoverableText =
        'using System;' + $crlf +
        "<<<<<<< TODO: Unmerged change from project 'Example(net9.0)', Before:" + $crlf +
        'namespace Example' + $crlf +
        '{' + $crlf +
        '    public sealed class Widget { }' + $crlf +
        '}' + $crlf +
        '=======' + $crlf +
        'namespace Example;' + $lf +
        '' + $lf +
        'public sealed class Widget { }' + $lf +
        '>>>>>>> After' + $lf +
        '' + $lf +
        'namespace Example;' + $lf +
        '' + $lf +
        'public sealed class Widget { }' + $lf
    Write-Utf8Fixture -Path $recoverable -Text $recoverableText -Bom $true

    $beforeCheck = [System.IO.File]::ReadAllBytes($recoverable)
    $check = Invoke-Repair -Path $recoverable
    Assert-Equal -Expected 0 -Actual $check.ExitCode -Message 'Check mode should accept the proven duplicate artifact.'
    if ($check.Output -notmatch '"status":\s*"recoverable"') { throw 'Check mode did not report recoverable status.' }
    if ($check.Output -notmatch '"pattern":\s*"whole-document-namespace-conversion"') { throw 'Check mode did not identify the supported structural pattern.' }
    $afterCheck = [System.IO.File]::ReadAllBytes($recoverable)
    Assert-Equal -Expected ([Convert]::ToHexString($beforeCheck)) -Actual ([Convert]::ToHexString($afterCheck)) -Message 'Check mode changed the file.'

    $apply = Invoke-Repair -Path $recoverable -Apply
    Assert-Equal -Expected 0 -Actual $apply.ExitCode -Message 'Apply mode should repair the proven duplicate artifact.'
    if ($apply.Output -notmatch '"status":\s*"repaired"') { throw 'Apply mode did not report repaired status.' }
    $repairedBytes = [System.IO.File]::ReadAllBytes($recoverable)
    if (-not ($repairedBytes[0] -eq 0xEF -and $repairedBytes[1] -eq 0xBB -and $repairedBytes[2] -eq 0xBF)) { throw 'UTF-8 BOM was not preserved.' }
    $repairedText = [System.Text.Encoding]::UTF8.GetString($repairedBytes, 3, $repairedBytes.Length - 3)
    Assert-Equal -Expected ("using System;`n`nnamespace Example;`n`npublic sealed class Widget { }`n") -Actual $repairedText -Message 'Recovered content was not the complete After document.'
    Assert-Equal -Expected 1 -Actual ([regex]::Matches($repairedText, 'namespace Example;').Count) -Message 'Namespace conversion was duplicated.'

    $secondApply = Invoke-Repair -Path $recoverable -Apply
    Assert-Equal -Expected 0 -Actual $secondApply.ExitCode -Message 'Repair should be idempotent.'
    if ($secondApply.Output -notmatch '"status":\s*"clean"') { throw 'Second apply did not report a clean file.' }

    $unsafeText = $recoverableText.Replace('public sealed class Widget { }' + $lf + '>>>>>>> After', 'public sealed class Different { }' + $lf + '>>>>>>> After')
    Write-Utf8Fixture -Path $unsafe -Text $unsafeText
    $unsafeBefore = [System.IO.File]::ReadAllBytes($unsafe)
    $unsafeResult = Invoke-Repair -Path $unsafe -Apply
    Assert-Equal -Expected 2 -Actual $unsafeResult.ExitCode -Message 'Mismatched After content should fail closed.'
    if ($unsafeResult.Output -notmatch '"status":\s*"unsafe"') { throw 'Unsafe artifact was not reported.' }
    $unsafeAfter = [System.IO.File]::ReadAllBytes($unsafe)
    Assert-Equal -Expected ([Convert]::ToHexString($unsafeBefore)) -Actual ([Convert]::ToHexString($unsafeAfter)) -Message 'Unsafe artifact was modified.'

    $unsupportedLocalizedText =
        'namespace Example;' + $lf +
        '' + $lf +
        'public sealed class Localized' + $lf +
        '{' + $lf +
        "    /* Unmerged change from project 'Example(net9.0)'" + $lf +
        '    Before:' + $lf +
        '    if (value) { Execute(); }' + $lf +
        '    After:' + $lf +
        '    if (value)' + $lf +
        '    {' + $lf +
        '        Execute();' + $lf +
        '    }' + $lf +
        '    */' + $lf +
        '}' + $lf
    Write-Utf8Fixture -Path $unsupportedLocalized -Text $unsupportedLocalizedText
    $unsupportedBefore = [System.IO.File]::ReadAllBytes($unsupportedLocalized)
    $unsupportedResult = Invoke-Repair -Path $unsupportedLocalized -Apply
    Assert-Equal -Expected 2 -Actual $unsupportedResult.ExitCode -Message "An unsupported localized artifact should fail closed. Output: $($unsupportedResult.Output)"
    if ($unsupportedResult.Output -notmatch '"pattern":\s*"unrecognized"') { throw 'Unsupported artifact was not reported as an unrecognized pattern.' }
    $unsupportedAfter = [System.IO.File]::ReadAllBytes($unsupportedLocalized)
    Assert-Equal -Expected ([Convert]::ToHexString($unsupportedBefore)) -Actual ([Convert]::ToHexString($unsupportedAfter)) -Message 'Unsupported localized artifact was modified.'

    Write-Utf8Fixture -Path $blockedRecoverable -Text $recoverableText
    $blockedBefore = [System.IO.File]::ReadAllBytes($blockedRecoverable)
    $blockedResult = Invoke-Repair -Path $testRoot -Apply
    Assert-Equal -Expected 2 -Actual $blockedResult.ExitCode -Message 'Directory apply should fail when any artifact is unsafe.'
    $blockedAfter = [System.IO.File]::ReadAllBytes($blockedRecoverable)
    Assert-Equal -Expected ([Convert]::ToHexString($blockedBefore)) -Actual ([Convert]::ToHexString($blockedAfter)) -Message 'Directory apply partially repaired a file despite an unsafe sibling artifact.'

    Write-Utf8Fixture -Path $clean -Text "namespace Example;`n`npublic sealed class Clean { }`n"
    $directoryResult = Invoke-Repair -Path $testRoot
    Assert-Equal -Expected 2 -Actual $directoryResult.ExitCode -Message 'Directory scan should surface the unsafe fixture.'
    if ($directoryResult.Output -notmatch 'Clean\.cs' -or $directoryResult.Output -notmatch '"status":\s*"clean"') { throw 'Directory scan did not report the clean fixture.' }

    Write-Output 'All Roslyn multi-project artifact repair tests passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
