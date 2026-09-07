Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()
$testScripts = Get-ChildItem -LiteralPath $scriptRoot -Filter 'test-*.ps1' -File | Sort-Object Name

foreach ($testScript in $testScripts) {
    Write-Host "Running $($testScript.Name)..."
    try {
        & pwsh -NoProfile -File $testScript.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Exited with $LASTEXITCODE."
        }
    }
    catch {
        $failures.Add("$($testScript.Name): $($_.Exception.Message)")
    }
}

if ($failures.Count -gt 0) {
    throw ("dotnet-nuget-update tests failed:`n- " + ($failures -join "`n- "))
}

Write-Host 'dotnet-nuget-update test suite: PASS'
