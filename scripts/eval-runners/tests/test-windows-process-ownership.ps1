Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { return }

$runnerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $runnerRoot 'codex/runner.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('ConvertTo-CodexComparablePath', 'Remove-CodexExecutionProjection')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-Ownership ([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$temp = [IO.Path]::GetTempPath()
$root = Join-Path $temp ('agentic-codex-projection-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$projection = @{ Root = $root }
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$children = [System.Collections.Generic.List[object]]::new()
$unrelated = $null
try {
    $unrelated = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 90"' -WindowStyle Hidden -PassThru
    $holder = Join-Path $root 'holder.ps1'
    Set-Content -LiteralPath $holder -Value @'
$file = [IO.File]::Open((Join-Path $PSScriptRoot 'MSBuild.Caching.dll'), 'OpenOrCreate', 'ReadWrite', 'Read')
try {
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'ready') -Value $PID
    Start-Sleep -Seconds 60
} finally { $file.Dispose() }
'@
    $launcher = Join-Path $root 'launcher.ps1'
    Set-Content -LiteralPath $launcher -Value @'
$null = Start-Process -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -ArgumentList ('-NoProfile -File "' + (Join-Path $PSScriptRoot 'holder.ps1') + '"') -WindowStyle Hidden -PassThru
$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ready'))) {
    if ($clock.Elapsed.TotalSeconds -gt 10) { throw 'DLL holder did not start.' }
    Start-Sleep -Milliseconds 25
}
exit 3
'@
    $child = Start-RunnerChildProcess -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $launcher) -WorkingDirectory $root -StdoutPath (Join-Path $root stdout) -StderrPath (Join-Path $root stderr) -TimeoutSeconds 30
    $children.Add($child)
    Assert-Ownership ($child.Process.WaitForExit(15000)) 'Launcher failed to exit.'
    $holderProcessId = [int](Get-Content -LiteralPath (Join-Path $root ready))
    $holderProcess = Get-Process -Id $holderProcessId
    try {
        $dll = Join-Path $root 'MSBuild.Caching.dll'
        $denied = $false
        try { Remove-Item -LiteralPath $dll -Force -ErrorAction Stop } catch { $denied = $true }
        Assert-Ownership $denied 'The surviving descendant must still prevent DLL removal.'
        Assert-Ownership ((Complete-RunnerChildProcess -Child $child) -eq 3) 'Normal completion must preserve the launcher result.'
        Assert-Ownership ((Complete-RunnerChildProcess -Child $child) -eq 3 -and -not $child.TimedOut) 'Repeated finalization must preserve the primary outcome.'
        Assert-Ownership ($holderProcess.HasExited -and $child.TerminationObserved -and $child.OutputDrainCompleted) 'Owned descendants must exit before completion is reported.'
        Assert-Ownership (-not $unrelated.HasExited) 'Terminating a job affected a process outside that job.'
    } finally { $holderProcess.Dispose() }

    foreach ($mode in @('deadline', 'cancellation')) {
        $child = Start-RunnerChildProcess -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WorkingDirectory $root -StdoutPath (Join-Path $root stdout) -StderrPath (Join-Path $root stderr) -TimeoutSeconds 30 -Phase 'runner-cli'
        $children.Add($child)
        if ($mode -eq 'deadline') {
            $child.DeadlineUtc = [DateTime]::UtcNow
            $null = Wait-AnyRunnerChild -Running @($child)
            $null = Complete-RunnerChildProcess -Child $child
            Assert-Ownership ($child.TimedOut -and $child.TerminationReason -match '^runner-cli watchdog deadline reached at') 'Watchdog did not report its actual deadline.'
        } else {
            $null = Complete-RunnerChildProcess -Child $child -CancellationReason 'sibling failed'
            Assert-Ownership (-not $child.TimedOut -and $child.TerminationReason -eq 'sibling failed') 'Sibling cancellation was misclassified.'
        }
        Assert-Ownership ($child.TerminationObserved -and $child.OutputDrainCompleted) 'Termination did not drain output and observe exit.'
    }

    $lock = [IO.File]::Open((Join-Path $root 'MSBuild.Caching.dll'), 'Open', 'Read', 'Read')
    try {
        $warning = Remove-CodexExecutionProjection -Projection $projection
        Assert-Ownership ($warning -like '*Retained*' -and $warning.Contains($root)) 'Persistent locking did not retain the projection with a diagnostic.'
        Assert-Ownership ($child.TerminationReason -eq 'sibling failed') 'Cleanup changed the primary outcome.'
    } finally { $lock.Dispose() }

    & {
        $attempts = [System.Collections.Generic.List[int]]::new()
        function Remove-Item {
            param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction)
            $attempts.Add(1)
            if ($attempts.Count -eq 1) { throw [IO.IOException]::new('transient sharing violation') }
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction $ErrorAction
        }
        Assert-Ownership (-not (Remove-CodexExecutionProjection -Projection $projection) -and -not (Test-Path -LiteralPath $root)) 'A transient failure prevented removal.'
        Assert-Ownership ($attempts.Count -eq 2) 'Cleanup did not retry exactly once after a transient failure.'
    }

    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $targetMajor = ((& $dotnet.Source --version) -split '\.')[0]
    $builds = foreach ($arm in 1..2) {
        $armRoot = Join-Path $root "arm-$arm"
        $homeDir = Join-Path $armRoot 'home'
        New-Item -ItemType Directory -Path $armRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $armRoot 'fixture.csproj') -Value "<Project Sdk='Microsoft.NET.Sdk'><PropertyGroup><TargetFramework>net$targetMajor.0</TargetFramework><NuGetAudit>false</NuGetAudit></PropertyGroup></Project>"
        Set-Content -LiteralPath (Join-Path $armRoot 'Fixture.cs') -Value 'public sealed class Fixture {}'
        Set-Content -LiteralPath (Join-Path $armRoot 'NuGet.Config') -Value '<configuration><packageSources><clear /></packageSources></configuration>'
        $command = @'
param($Common, $ArmRoot)
. $Common
$isolated = New-RunnerShellEnvironment -Run @{ HomeDirectoryPath = (Join-Path $ArmRoot 'home') }
foreach ($name in $isolated.Keys) { [Environment]::SetEnvironmentVariable($name, $isolated[$name]) }
if ($env:MSBUILDDISABLENODEREUSE -ne '1' -or $env:DOTNET_CLI_USE_MSBUILD_SERVER -ne '0' -or $env:UseSharedCompilation -ne 'false') { exit 9 }
$peer = if ($ArmRoot.EndsWith('arm-1')) { 'arm-2' } else { 'arm-1' }
Set-Content -LiteralPath (Join-Path $ArmRoot 'building') -Value 'true'
$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $ArmRoot) "$peer/building"))) {
    if ($clock.Elapsed.TotalSeconds -gt 15) { exit 8 }
    Start-Sleep -Milliseconds 50
}
dotnet restore --configfile NuGet.Config
if ($LASTEXITCODE) { exit $LASTEXITCODE }
dotnet build --no-restore
exit $LASTEXITCODE
'@
        $scriptPath = Join-Path $armRoot 'build.ps1'
        Set-Content -LiteralPath $scriptPath -Value $command
        $armChild = Start-RunnerChildProcess -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $scriptPath, (Join-Path $runnerRoot 'runner-common.ps1'), $armRoot) -WorkingDirectory $armRoot -StdoutPath (Join-Path $armRoot stdout) -StderrPath (Join-Path $armRoot stderr) -TimeoutSeconds 60
        $children.Add($armChild)
        $armChild
    }
    foreach ($build in $builds) {
        Assert-Ownership ((Complete-RunnerChildProcess -Child $build) -eq 0 -and $build.CleanupFailures.Count -eq 0) "Concurrent .NET restore/build failed: $(Get-Content $build.StdoutPath -Raw) $(Get-Content $build.StderrPath -Raw)"
    }
    Assert-Ownership (-not (Remove-CodexExecutionProjection -Projection $projection)) 'Parallel builds left the projection locked.'
    Write-Output 'Windows process ownership: PASS'
} finally {
    foreach ($child in $children) {
        $null = Complete-RunnerChildProcess -Child $child -CancellationReason 'test cleanup'
    }
    if ($null -ne $unrelated) {
        if (-not $unrelated.HasExited) { $unrelated.Kill(); $null = $unrelated.WaitForExit(5000) }
        $unrelated.Dispose()
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
