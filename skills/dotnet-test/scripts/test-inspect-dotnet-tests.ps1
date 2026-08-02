Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-test-inspection-' + [Guid]::NewGuid().ToString('N'))

function Write-File {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    Write-File -Path (Join-Path $workspace 'Directory.Packages.props') -Content @'
<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup><ItemGroup><PackageVersion Include="xunit" Version="2.9.3" /><PackageVersion Include="xunit.v3" Version="3.2.2" /><PackageVersion Include="Microsoft.AspNetCore.Mvc.Testing" Version="10.0.0" /></ItemGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'app/App.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'app/Program.cs') -Content @'
using Codebelt.Bootstrapper.Web; public class Program : MinimalWebProgram { public static void Main(string[] args) { var builder = CreateHostBuilder(args); var app = builder.Build(); app.MapGet("/", () => "ok"); app.Run(); } }
'@
    Write-File -Path (Join-Path $workspace 'test/App.FunctionalTests/App.FunctionalTests.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><PackageReference Include="xunit" /><PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" /><ProjectReference Include="../../app/App.csproj" /></ItemGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'test/App.FunctionalTests/HealthTest.cs') -Content @'
using Microsoft.AspNetCore.Mvc.Testing; using Xunit.Abstractions; public class HealthTest : IClassFixture<WebApplicationFactory<Program>> { }
'@
    Write-File -Path (Join-Path $workspace 'src/Widget/Widget.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'test/Widget.Tests/Widget.Tests.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><PackageReference Include="xunit.v3" /><ProjectReference Include="../../src/Widget/Widget.csproj" /></ItemGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'worker/Worker.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk.Worker"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'worker/Program.cs') -Content @'
using Codebelt.Bootstrapper.Worker; public class Program : MinimalWorkerProgram { public static async Task Main(string[] args) { var builder = CreateHostBuilder(args); await builder.Build().RunAsync(); } }
'@
    Write-File -Path (Join-Path $workspace 'test/Worker.FunctionalTests/Worker.FunctionalTests.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><ProjectReference Include="../../worker/Worker.csproj" /></ItemGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'console/Console.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'console/Program.cs') -Content @'
using Codebelt.Bootstrapper.Console; public class Program : MinimalConsoleProgram<Program> { public static async Task Main(string[] args) { var builder = CreateHostBuilder(args); await builder.Build().RunAsync(); } public override Task RunAsync(IServiceProvider services, CancellationToken token) => Task.CompletedTask; }
'@
    Write-File -Path (Join-Path $workspace 'test/Console.FunctionalTests/Console.FunctionalTests.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><ProjectReference Include="../../console/Console.csproj" /></ItemGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'legacy/Legacy.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup></Project>
'@
    Write-File -Path (Join-Path $workspace 'legacy/Program.cs') -Content @'
System.Console.WriteLine("legacy");
'@
    Write-File -Path (Join-Path $workspace 'test/Legacy.FunctionalTests/Legacy.FunctionalTests.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><IsTestProject>true</IsTestProject></PropertyGroup><ItemGroup><ProjectReference Include="../../legacy/Legacy.csproj" /></ItemGroup></Project>
'@

    $scriptPath = Join-Path $PSScriptRoot 'inspect-dotnet-tests.ps1'
    $json = & pwsh -NoProfile -File $scriptPath -RepoRoot $workspace
    if ($LASTEXITCODE -ne 0) { throw "Inspection script exited with $LASTEXITCODE." }
    $report = $json | ConvertFrom-Json
    if ($report.projectCount -ne 5) { throw "Expected five projects, found $($report.projectCount)." }
    $webProject = $report.projects | Where-Object project -eq 'test/App.FunctionalTests/App.FunctionalTests.csproj'
    $unitProject = $report.projects | Where-Object project -eq 'test/Widget.Tests/Widget.Tests.csproj'
    $workerProject = $report.projects | Where-Object project -eq 'test/Worker.FunctionalTests/Worker.FunctionalTests.csproj'
    $consoleProject = $report.projects | Where-Object project -eq 'test/Console.FunctionalTests/Console.FunctionalTests.csproj'
    $legacyProject = $report.projects | Where-Object project -eq 'test/Legacy.FunctionalTests/Legacy.FunctionalTests.csproj'
    if ($webProject.role -ne 'ASP.NET Core functional test') { throw "Unexpected web role: $($webProject.role)" }
    if ($unitProject.role -ne 'Ordinary unit test') { throw "Unexpected unit role: $($unitProject.role)" }
    if ($workerProject.role -ne 'Console or worker functional test') { throw "Unexpected worker role: $($workerProject.role)" }
    if ($consoleProject.role -ne 'Console or worker functional test') { throw "Unexpected console role: $($consoleProject.role)" }
    if ($legacyProject.role -ne 'Console or worker functional test' -or $legacyProject.blockers.Count -lt 1) { throw 'Expected legacy executable to report the Generic Host blocker.' }
    if ($webProject.xunitGeneration -ne 'v2') { throw "Unexpected xUnit generation: $($webProject.xunitGeneration)" }
    if ($webProject.webApplicationFactoryUsages.Count -lt 1) { throw 'Expected WebApplicationFactory usage.' }
    if (@($webProject.packageOwnership | Where-Object { $_.id -eq 'xunit' -and $_.ownership -eq 'central' }).Count -ne 1) { throw 'Expected central xunit package ownership.' }
    if (-not $webProject.referencedApplications[0].genericHost -or -not $webProject.referencedApplications[0].webHost) { throw 'Expected a detectable web Generic Host.' }
    if ($webProject.referencedApplications[0].hostPattern -ne 'MinimalWebProgram') { throw 'Expected MinimalWebProgram detection.' }
    if ($workerProject.referencedApplications[0].hostPattern -ne 'MinimalWorkerProgram') { throw 'Expected MinimalWorkerProgram detection.' }
    if ($consoleProject.referencedApplications[0].hostPattern -ne 'MinimalConsoleProgram') { throw 'Expected MinimalConsoleProgram detection.' }

    Write-Host 'inspect-dotnet-tests.ps1 regression: PASS'
} finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force }
}
