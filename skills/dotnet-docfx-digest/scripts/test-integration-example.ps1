#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'integration-example.ps1')
$pair = New-ManagedApplicationExamplePair
$document = Get-Content (Join-Path $PSScriptRoot '../references/one-shot-examples.md') -Raw
$blocks = [regex]::Matches($document, '(?s)```powershell\r?\n(.*?)\r?\n```')
if ($blocks.Count -ne 2) { throw 'Expected two independent published execution blocks.' }
$source = [regex]::Match($document, '(?s)```csharp\r?\n(.*?)\r?\n```').Groups[1].Value.Replace("`r`n", "`n").TrimEnd()
# Hash of the original maintained test at the pinned snapshot, not a reconstructed sample.
$sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
if ($sourceHash -cne '47B0C1FBA94E7B43C8753D0A8242801B328E6B463B6EEDAEB640D4F8A262633E') { throw 'Displayed test differs from the original maintained source.' }
$checks = 0
foreach ($transport in @('Native', 'Docker', 'DockerLinux')) {
    $artifact = if ($transport -eq 'Native') { 'Native' } else { 'Docker' }
    $simulateLinux = $transport -eq 'DockerLinux'
    $index = if ($transport -eq 'Native') { 0 } else { 1 }
    if ($blocks[$index].Groups[1].Value.Replace("`r`n", "`n") -cne $pair.$artifact.Replace("`r`n", "`n")) { throw "Published $artifact block drifted." }
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($pair.$artifact, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "Invalid PowerShell: $errors" }
    $scenarios = @('pass', 'wrong-test', 'zero', 'skip', 'runner-error', 'missing-report', 'dependency', 'environment')
    if ($artifact -eq 'Docker') { $scenarios += 'daemon' }
    if ($simulateLinux) { $scenarios += @('uid', 'gid') }
    foreach ($scenario in $scenarios) {
        & {
            # Offline doubles exercise the complete published block; never evidence of live tests.
            function Invoke-WebRequest { param($Uri, $OutFile) }
            function Expand-Archive {
                param($LiteralPath, $DestinationPath)
                $workspaces.Add((Split-Path $DestinationPath -Parent))
                $null = New-Item -ItemType Directory -Path "$DestinationPath/xunit-84b13767cb9484f8f3a36a71875662edfdb3e511" -Force
            }
            function Get-Command {
                param($Name, $ErrorAction)
                if ($scenario -eq 'environment') { throw "Unavailable $Name" }
            }
            function Invoke-TestDouble {
                if ($scenario -eq 'dependency') { $global:LASTEXITCODE = 1; return 'NU1101: dependency unavailable' }
                $global:LASTEXITCODE = 0
                if ($scenario -eq 'missing-report') { return }
                $null = New-Item -ItemType Directory -Path "$work/results" -Force
                $name = if ($scenario -eq 'wrong-test') { 'Other.Test' } else { $test }
                $count = if ($scenario -eq 'zero') { '0' } else { '1' }
                $result = if ($scenario -eq 'skip') { 'Skip' } else { 'Pass' }
                $errors = if ($scenario -eq 'runner-error') { '1' } else { '0' }
                $tests = if ($scenario -eq 'zero') { '' } else { "<test name='$name' result='$result'/>" }
                Set-Content "$work/results/result.xml" "<assemblies><assembly total='$count' passed='$count' errors='$errors'><collection>$tests</collection></assembly></assemblies>"
                'Offline test double'
            }
            function dotnet {
                if ($transport -ne 'Native') { throw 'Docker block required a host SDK.' }
                Invoke-TestDouble
            }
            function id {
                $flag = $args[0]
                if (-not $simulateLinux) { throw 'Non-Linux block required Unix identity lookup.' }
                $global:LASTEXITCODE = 0
                if ($flag -eq '-u') {
                    if ($scenario -eq 'uid') { $global:LASTEXITCODE = 1; return }
                    return '1234'
                }
                if ($flag -eq '-g') {
                    if ($scenario -eq 'gid') { $global:LASTEXITCODE = 1; return }
                    return '5678'
                }
                throw "Unexpected identity lookup: $flag"
            }
            function docker {
                if ($artifact -ne 'Docker') { throw 'Native block required Docker.' }
                if ($args[0] -eq 'info') { $global:LASTEXITCODE = if ($scenario -eq 'daemon') { 1 } else { 0 }; return }
                $dockerRuns.Add(@($args))
                $imageIndex = [array]::IndexOf($args, 'mcr.microsoft.com/dotnet/sdk:11.0')
                $options = @($args[0..($imageIndex - 1)])
                $userIndex = [array]::IndexOf($options, '--user')
                if ($simulateLinux) {
                    if ($userIndex -lt 0 -or $options[$userIndex + 1] -cne '1234:5678') { throw 'Container must use the host UID:GID on Linux.' }
                }
                elseif ($userIndex -ge 0) { throw 'Non-Linux block should keep the Docker Desktop user default.' }
                foreach ($value in @('HOME=/tmp', 'DOTNET_CLI_HOME=/tmp')) {
                    $valueIndex = [array]::IndexOf($options, $value)
                    if ($valueIndex -le 0 -or $options[$valueIndex - 1] -cne '--env') { throw "Missing writable container home: $value" }
                }
                if ('--init' -notin $options -or 'MSBUILDDISABLENODEREUSE=1' -notin $options -or '--disable-build-servers' -notin $args) { throw 'A disposable SDK run must reap orphaned processes and avoid persistent build servers.' }
                Invoke-TestDouble
            }
            $failed = $false
            $warnings = [Collections.Generic.List[string]]::new()
            $workspaces = [Collections.Generic.List[string]]::new()
            $dockerRuns = [Collections.Generic.List[object]]::new()
            function Write-Warning { param($Message) $warnings.Add($Message) }
            # Exercise both OS branches on every host without changing its read-only $IsLinux.
            try { & ([scriptblock]::Create($pair.$artifact.Replace('$IsLinux', '$simulateLinux'))) | Out-Null }
            catch { if ($scenario -eq 'pass') { throw }; $failed = $true }
            if ($failed -ne ($scenario -ne 'pass')) { throw "$transport/$scenario did not enforce verification." }
            if ($scenario -in @('uid', 'gid') -and $dockerRuns.Count -ne 0) { throw 'Identity lookup failure started a container.' }
            foreach ($workspace in $workspaces) {
                if (Test-Path -LiteralPath $workspace) { throw 'Downloaded workspace leaked.' }
            }
            # The downloaded workspace must be gone after success or failure.
            if ($scenario -notin @('environment', 'daemon')) {
                # Capture its path from the diagnostic warning on failures.
                $warning = @($warnings | Where-Object { "$_" -like '*Diagnostics:*' })
                if ($scenario -ne 'pass' -and $warning.Count -ne 1) { throw 'Missing failure diagnostics.' }
                if ($warning.Count) {
                    $diagnostics = ("$($warning[0])" -split 'Diagnostics: ', 2)[1]
                    $workspace = $diagnostics -replace '-diagnostics$', ''
                    if (Test-Path -LiteralPath $workspace) { throw 'Downloaded workspace leaked.' }
                    if ($scenario -eq 'dependency' -and (Get-Content "$diagnostics/run.log" -Raw) -notmatch 'NU1101') { throw 'Dependency diagnostics lost.' }
                    $resolved = [IO.Path]::GetFullPath($diagnostics)
                    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('/','\') + [IO.Path]::DirectorySeparatorChar
                    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup.' }
                    Remove-Item -LiteralPath $resolved -Recurse -Force
                }
            }
        }
        $checks++
    }
}
Write-Host "One-shot integration artifacts passed: $checks offline cases, published parity and PowerShell syntax (not live verification)."
# Expected negative controls leave LASTEXITCODE nonzero; only assertion failures fail this suite.
exit 0
