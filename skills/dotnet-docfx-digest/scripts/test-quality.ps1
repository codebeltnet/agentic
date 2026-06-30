param(
    [string]$ValidatorPath = (Join-Path $PSScriptRoot 'docfx.cs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The validator exits non-zero for fixtures that contain diagnostics and writes append-only packet
# heartbeats to stderr; opt out of native-command error promotion so neither is treated as a
# terminating error when this script is invoked from validate-skill-templates.ps1.
$PSNativeCommandUseErrorActionPreference = $false

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-quality-' + [guid]::NewGuid().ToString('N'))

function Write-Utf8File {
    param([string]$Path, [string]$Content)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-Validator {
    param(
        [string]$Workspace = $workspace,
        [string[]]$ExtraArgs = @()
    )

    # Run the native validator with ErrorActionPreference relaxed so its non-zero exit and stderr
    # packet heartbeats are never promoted to a terminating PowerShell error (explicit `throw`
    # statements below still halt the test). This keeps behavior identical whether the script is run
    # directly or invoked from validate-skill-templates.ps1, which sets [Console]::OutputEncoding.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & dotnet run --file $ValidatorPath -- --repo-root $Workspace --json @ExtraArgs 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }

    $text = ($output -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'DocFX validator returned no JSON output.'
    }

    $start = $text.IndexOf('{')
    if ($start -lt 0) { throw "DocFX validator returned no JSON document. Output: $text" }
    return ($text.Substring($start) | ConvertFrom-Json)
}

function Assert-Diagnostic {
    param([object]$Report, [string]$Code)

    if (-not @($Report.errors | Where-Object code -eq $Code)) {
        $reported = @($Report.errors | ForEach-Object code | Sort-Object -Unique) -join ', '
        throw "Expected diagnostic '$Code' was not reported. Reported diagnostics: $reported"
    }
}

function Assert-NoDiagnostic {
    param([object]$Report, [string]$Code)

    $matches = @($Report.errors | Where-Object code -eq $Code)
    if ($matches) {
        $details = $matches | ConvertTo-Json -Compress -Depth 5
        throw "Diagnostic '$Code' was reported but the fixture expected it to be absent. Matching diagnostics: $details"
    }
}

function Assert-DiagnosticForPath {
    param([object]$Report, [string]$Code, [string]$PathFragment)

    if (-not @($Report.errors | Where-Object {
        $_.code -eq $Code -and $_.path -and $_.path.Replace('\\', '/').Contains($PathFragment)
    })) {
        throw "Expected diagnostic '$Code' for path containing '$PathFragment' was not reported."
    }
}

function Assert-NoDiagnosticForPath {
    param([object]$Report, [string]$Code, [string]$PathFragment)

    $matches = @($Report.errors | Where-Object {
        $_.code -eq $Code -and $_.path -and $_.path.Replace('\\', '/').Contains($PathFragment)
    })
    if ($matches) {
        $details = $matches | ConvertTo-Json -Compress -Depth 5
        throw "Diagnostic '$Code' was reported for path containing '$PathFragment'. Matching diagnostics: $details"
    }
}

function Assert-Warning {
    param([object]$Report, [string]$Code)

    if (-not @($Report.warnings | Where-Object code -eq $Code)) {
        throw "Expected warning '$Code' was not reported."
    }
}

function Assert-DiagnosticMessageContains {
    param([object]$Report, [string]$Code, [string]$Text)

    $matches = @($Report.errors | Where-Object {
        $_.code -eq $Code -and $_.message -and $_.message.Contains($Text)
    })
    if (-not $matches) {
        $details = @($Report.errors | Where-Object code -eq $Code) | ConvertTo-Json -Compress -Depth 5
        throw "Expected diagnostic '$Code' message to contain '$Text'. Matching diagnostics: $details"
    }
}

function Initialize-GitRepo {
    param([string]$Workspace)
    Push-Location $Workspace
    try {
        & git init -q 2>$null | Out-Null
        & git config core.autocrlf false 2>$null | Out-Null
        & git config core.safecrlf false 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t add -A 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t commit -q -m base 2>$null | Out-Null
    } finally {
        Pop-Location
    }
}

function New-DocfxJson {
    param([string[]]$ProjectFiles)

    $files = ($ProjectFiles | ForEach-Object { "`"$_`"" }) -join ', '
    return @"
{
  "metadata": [{
    "src": [{ "src": "../", "files": [$files] }],
    "dest": "api",
    "properties": { "TargetFramework": "net10.0" }
  }],
  "build": {
    "content": [{ "files": ["*.md"], "exclude": ["api/namespaces/**", "api/types/**"] }],
    "overwrite": [{ "files": ["api/namespaces/**/*.md", "api/types/**/*.md"] }],
    "dest": "_site"
  }
}
"@
}

$projectCsproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@

try {
    $templateOnlyWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-template-only-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8File (Join-Path $templateOnlyWorkspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
        Write-Utf8File (Join-Path $templateOnlyWorkspace 'src/Utility/Utility.csproj') $projectCsproj
        Write-Utf8File (Join-Path $templateOnlyWorkspace 'src/Utility/Utility.cs') @'
namespace Acme.Utility;

public sealed class Tool
{
    public int Attempts { get; set; }
}
'@
        Write-Utf8File (Join-Path $templateOnlyWorkspace 'skills/dotnet-new-lib-slnx/assets/library/.docfx/docfx.json') @'
{
  "metadata": [{
    "src": [{ "src": "../src", "files": ["{PROJECT_NAME}/**.csproj"] }],
    "dest": "api",
    "properties": { "TargetFramework": "{DOCFX_TARGET_FRAMEWORK}" }
  }],
  "build": {
    "content": [{ "files": ["*.md"] }],
    "overwrite": [{ "files": ["api/namespaces/**/*.md", "api/types/**/*.md"] }],
    "dest": "_site"
  }
}
'@

        $templateOnly = Invoke-Validator -Workspace $templateOnlyWorkspace
        Assert-Diagnostic -Report $templateOnly -Code 'DOCFX_CONFIG_MISSING'
        Assert-NoDiagnostic -Report $templateOnly -Code 'PROJECT_DISCOVERY_FAILED'
        $templateOnlyDocfxPath = if ($templateOnly.PSObject.Properties.Match('docfxPath').Count -gt 0) {
            $templateOnly.docfxPath
        } else {
            $null
        }
        if ($templateOnlyDocfxPath) {
            throw "Template-only fixture should not resolve a docfxPath, but returned '$templateOnlyDocfxPath'."
        }
    } finally {
        if (Test-Path $templateOnlyWorkspace) {
            Remove-Item $templateOnlyWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $badConfigWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-bad-config-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8File (Join-Path $badConfigWorkspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
        Write-Utf8File (Join-Path $badConfigWorkspace 'src/Utility/Utility.csproj') $projectCsproj
        Write-Utf8File (Join-Path $badConfigWorkspace 'src/Utility/Utility.cs') @'
namespace Acme.Utility;

public sealed class Tool
{
    public int Attempts { get; set; }
}
'@
        Write-Utf8File (Join-Path $badConfigWorkspace '.docfx/docfx.json') @'
{
  "metadata": [{
    "src": [{ "src": "../", "files": ["src/Utility/Utility.csproj"] }],
    "dest": "api",
    "properties": { "TargetFramework": "net10.0" }
  }],
  "build": {
    "content": [{ "files": ["*.md"], "exclude": ["api/namespaces/**", "api/types/**"] }],
    "overwrite": [{ "files": ["api/namespaces/**.md", "api/types/**/*.md"] }],
    "dest": "_site"
  }
}
'@

        $badConfig = Invoke-Validator -Workspace $badConfigWorkspace
        Assert-Diagnostic -Report $badConfig -Code 'API_OVERWRITE_CONFIG_INVALID'
        Assert-DiagnosticMessageContains -Report $badConfig -Code 'API_OVERWRITE_CONFIG_INVALID' -Text 'normalized literal equality'
        Assert-DiagnosticMessageContains -Report $badConfig -Code 'API_OVERWRITE_CONFIG_INVALID' -Text 'Closest configured pattern(s): `api/namespaces/**.md`'
    } finally {
        if (Test-Path $badConfigWorkspace) {
            Remove-Item $badConfigWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $interimWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-interim-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8File (Join-Path $interimWorkspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
        Write-Utf8File (Join-Path $interimWorkspace 'src/Utility/Utility.csproj') $projectCsproj
        Write-Utf8File (Join-Path $interimWorkspace 'src/Utility/Utility.cs') @'
namespace Acme.Utility;

public sealed class Tool
{
    public int Attempts { get; set; }
}
'@
        Write-Utf8File (Join-Path $interimWorkspace '.docfx/docfx.json') (New-DocfxJson @('src/Utility/Utility.csproj'))
Initialize-GitRepo $interimWorkspace
Write-Utf8File (Join-Path $interimWorkspace '.docfx/family-exemptions.json') @'
{
  "families": []
}
'@
Write-Utf8File (Join-Path $interimWorkspace '.docfx/skip-compile-allowlist.json') @'
{
  "entries": [
    {
      "diagnosticCode": "SAMPLE_COMPILE_FAILED",
      "filePath": ".docfx/api/types/Acme.Utility.Tool.md",
      "uid": "Acme.Utility.Tool",
      "reason": "requires a provisioned SQL Server schema managed outside the isolated sample compiler",
      "approval": "2026-06-20 issue #1234",
      "lifetime": "temporary"
    }
  ]
}
'@
Write-Utf8File (Join-Path $interimWorkspace '.docfx/api/namespaces/Acme.Utility.md') @'
---
uid: Acme.Utility
---

Namespace overview.
'@
        Write-Utf8File (Join-Path $interimWorkspace '.docfx/api/types/Acme.Utility.Tool.md') @'
---
uid: Acme.Utility.Tool
---

Type overview.
'@
        Write-Utf8File (Join-Path $interimWorkspace 'docfx_json_only.json') '{}'
        Write-Utf8File (Join-Path $interimWorkspace 'docfx_output.txt') 'captured output'
        Write-Utf8File (Join-Path $interimWorkspace '.docfx/docfx_verify.txt') 'captured verification'
        Write-Utf8File (Join-Path $interimWorkspace '.docfx/api/types/Acme.Utility.ScratchNotes.md') @'
---
uid: Scratch.Temp
---

Scratch notes.
'@

        $interimReport = Invoke-Validator -Workspace $interimWorkspace
        Assert-Diagnostic -Report $interimReport -Code 'INTERIM_ARTIFACT_IN_WORKTREE'
        $interimPaths = @($interimReport.errors | Where-Object code -eq 'INTERIM_ARTIFACT_IN_WORKTREE' | ForEach-Object path)
        if (-not ($interimPaths -contains 'docfx_json_only.json')) {
            throw "Expected docfx_json_only.json to be flagged as an interim artifact. Paths: $($interimPaths -join ', ')"
        }
        if (-not ($interimPaths -contains 'docfx_output.txt')) {
            throw "Expected docfx_output.txt to be flagged as an interim artifact. Paths: $($interimPaths -join ', ')"
        }
        if (-not ($interimPaths -contains '.docfx/docfx_verify.txt')) {
            throw "Expected .docfx/docfx_verify.txt to be flagged as an interim artifact. Paths: $($interimPaths -join ', ')"
        }
        if (-not ($interimPaths -contains '.docfx/api/types/Acme.Utility.ScratchNotes.md')) {
            throw "Expected .docfx/api/types/Acme.Utility.ScratchNotes.md to be flagged as an interim artifact. Paths: $($interimPaths -join ', ')"
        }
        if (-not ($interimPaths -contains '.docfx/family-exemptions.json')) {
            throw "Expected .docfx/family-exemptions.json to be flagged as an interim artifact because the skill no longer writes a skip manifest into the repository. Paths: $($interimPaths -join ', ')"
        }
        foreach ($allowed in @('AGENTS.md', '.docfx/docfx.json', '.docfx/api/namespaces/Acme.Utility.md', '.docfx/api/types/Acme.Utility.Tool.md')) {
            if ($interimPaths -contains $allowed) {
                throw "Did not expect $allowed to be flagged as an interim artifact. Paths: $($interimPaths -join ', ')"
            }
        }
        if ($interimPaths -contains '.docfx/skip-compile-allowlist.json') {
            throw "Did not expect .docfx/skip-compile-allowlist.json to be flagged as an interim artifact. Paths: $($interimPaths -join ', ')"
        }
    } finally {
        if (Test-Path $interimWorkspace) {
            Remove-Item $interimWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $approvedSkipWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-approved-skip-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8File (Join-Path $approvedSkipWorkspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
        Write-Utf8File (Join-Path $approvedSkipWorkspace 'src/Utility/Utility.csproj') $projectCsproj
        Write-Utf8File (Join-Path $approvedSkipWorkspace 'src/Utility/Utility.cs') @'
namespace Acme.Utility;

public sealed class Tool
{
    public int Attempts { get; set; }
}
'@
        Write-Utf8File (Join-Path $approvedSkipWorkspace '.docfx/docfx.json') (New-DocfxJson @('src/Utility/Utility.csproj'))
        Write-Utf8File (Join-Path $approvedSkipWorkspace '.docfx/api/namespaces/Acme.Utility.md') @'
---
uid: Acme.Utility
summary: *content
---
Use `Tool` when a caller needs to carry retry-attempt metadata through a small workflow.

Start with `Tool` to hold the attempt count before passing it to another operation.

Availability: `Acme.Utility`
'@
        Write-Utf8File (Join-Path $approvedSkipWorkspace '.docfx/api/types/Acme.Utility.Tool.md') @'
---
uid: Acme.Utility.Tool
example: *content
---
The following example records retry attempts before handing them to a database helper that is intentionally unavailable to the isolated sample compiler.

```csharp
// dotnet-docfx-digest:skip-compile - requires a provisioned SQL Server schema managed outside the isolated sample compiler
using Acme.Utility;

namespace Acme.Utility.Samples;

public sealed class ToolConsumer
{
    public int Execute()
    {
        var tool = new Tool { Attempts = 3 };
        return ExternalDatabase.RecordAttempt(tool.Attempts);
    }
}
```
'@
        Write-Utf8File (Join-Path $approvedSkipWorkspace '.docfx/skip-compile-allowlist.json') @'
{
  "entries": [
    {
      "diagnosticCode": "SAMPLE_COMPILE_FAILED",
      "filePath": ".docfx/api/types/Acme.Utility.Tool.md",
      "uid": "Acme.Utility.Tool",
      "reason": "requires a provisioned SQL Server schema managed outside the isolated sample compiler",
      "approval": "2026-06-20 issue #1234",
      "lifetime": "temporary"
    }
  ]
}
'@
        Initialize-GitRepo $approvedSkipWorkspace

        $approvedSkip = Invoke-Validator -Workspace $approvedSkipWorkspace -ExtraArgs @('--validate-samples')
        Assert-NoDiagnostic -Report $approvedSkip -Code 'FAIL_NEW_SKIP_MARKER_INTRODUCED'
        Assert-NoDiagnostic -Report $approvedSkip -Code 'SAMPLE_SKIP_NOT_ALLOWLISTED'
        Assert-NoDiagnostic -Report $approvedSkip -Code 'SAMPLE_COMPILE_FAILED'
        if ($approvedSkip.summary.samplesSkipped -ne 1) {
            throw "Expected one approved skipped sample; got $($approvedSkip.summary.samplesSkipped)."
        }
        if ($approvedSkip.summary.preExistingApprovedSkipMarkers -ne 1) {
            throw "Expected one pre-existing approved skip marker; got $($approvedSkip.summary.preExistingApprovedSkipMarkers)."
        }
        if ($approvedSkip.summary.newlyIntroducedSkipMarkers -ne 0) {
            throw "Expected zero newly introduced skip markers; got $($approvedSkip.summary.newlyIntroducedSkipMarkers)."
        }
        if (-not @($approvedSkip.skipMarkers | Where-Object { $_.approved -and $_.existedBeforeRun -and $_.uid -eq 'Acme.Utility.Tool' })) {
            throw 'Expected the approved skip marker to be reported with approved=true and existedBeforeRun=true.'
        }
    } finally {
        if (Test-Path $approvedSkipWorkspace) {
            Remove-Item $approvedSkipWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $newSkipWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-new-skip-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8File (Join-Path $newSkipWorkspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
        Write-Utf8File (Join-Path $newSkipWorkspace 'src/Utility/Utility.csproj') $projectCsproj
        Write-Utf8File (Join-Path $newSkipWorkspace 'src/Utility/Utility.cs') @'
namespace Acme.Utility;

public sealed class Tool
{
    public int Attempts { get; set; }
}
'@
        Write-Utf8File (Join-Path $newSkipWorkspace '.docfx/docfx.json') (New-DocfxJson @('src/Utility/Utility.csproj'))
        Write-Utf8File (Join-Path $newSkipWorkspace '.docfx/api/namespaces/Acme.Utility.md') @'
---
uid: Acme.Utility
summary: *content
---
Use `Tool` when a caller needs to carry retry-attempt metadata through a small workflow.

Start with `Tool` to hold the attempt count before passing it to another operation.

Availability: `Acme.Utility`
'@
        Write-Utf8File (Join-Path $newSkipWorkspace '.docfx/api/types/Acme.Utility.Tool.md') @'
---
uid: Acme.Utility.Tool
example: *content
---
The following example records retry attempts before handing them to a database helper that is intentionally unavailable to the isolated sample compiler.

```csharp
using Acme.Utility;

namespace Acme.Utility.Samples;

public sealed class ToolConsumer
{
    public int Execute()
    {
        var tool = new Tool { Attempts = 3 };
        return ExternalDatabase.RecordAttempt(tool.Attempts);
    }
}
```
'@
        Initialize-GitRepo $newSkipWorkspace
        Write-Utf8File (Join-Path $newSkipWorkspace '.docfx/api/types/Acme.Utility.Tool.md') @'
---
uid: Acme.Utility.Tool
example: *content
---
The following example records retry attempts before handing them to a database helper that is intentionally unavailable to the isolated sample compiler.

```csharp
// dotnet-docfx-digest:skip-compile - requires a provisioned SQL Server schema managed outside the isolated sample compiler
using Acme.Utility;

namespace Acme.Utility.Samples;

public sealed class ToolConsumer
{
    public int Execute()
    {
        var tool = new Tool { Attempts = 3 };
        return ExternalDatabase.RecordAttempt(tool.Attempts);
    }
}
```
'@
        Write-Utf8File (Join-Path $newSkipWorkspace '.docfx/skip-compile-allowlist.json') @'
{
  "entries": [
    {
      "diagnosticCode": "SAMPLE_COMPILE_FAILED",
      "filePath": ".docfx/api/types/Acme.Utility.Tool.md",
      "uid": "Acme.Utility.Tool",
      "reason": "requires a provisioned SQL Server schema managed outside the isolated sample compiler",
      "approval": "2026-06-20 issue #1234",
      "lifetime": "temporary"
    }
  ]
}
'@

        $newSkip = Invoke-Validator -Workspace $newSkipWorkspace -ExtraArgs @('--validate-samples')
        Assert-Diagnostic -Report $newSkip -Code 'FAIL_NEW_SKIP_MARKER_INTRODUCED'
        Assert-Diagnostic -Report $newSkip -Code 'SAMPLE_COMPILE_FAILED'
        Assert-NoDiagnostic -Report $newSkip -Code 'SAMPLE_SKIP_NOT_ALLOWLISTED'
        if ($newSkip.summary.samplesSkipped -ne 0) {
            throw "Expected zero skipped samples for a newly introduced skip marker; got $($newSkip.summary.samplesSkipped)."
        }
        if ($newSkip.summary.newlyIntroducedSkipMarkers -ne 1) {
            throw "Expected one newly introduced skip marker; got $($newSkip.summary.newlyIntroducedSkipMarkers)."
        }
        if (-not @($newSkip.skipMarkers | Where-Object { $_.approved -and -not $_.existedBeforeRun -and $_.uid -eq 'Acme.Utility.Tool' })) {
            throw 'Expected the new skip marker to be reported with approved=true and existedBeforeRun=false.'
        }
    } finally {
        if (Test-Path $newSkipWorkspace) {
            Remove-Item $newSkipWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $arrow = "$([char]0x2B07)$([char]0xFE0F)"
    Write-Utf8File (Join-Path $workspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $workspace 'src/Acme.Core.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File (Join-Path $workspace 'src/Api.cs') @'
namespace Acme.Core;

public sealed class Options
{
    public int Attempts { get; set; }
}

public static class StringExtensions
{
    public static string Normalize(this string value)
    {
        return value.Trim().ToUpperInvariant();
    }
}
'@
    Write-Utf8File (Join-Path $workspace '.docfx/docfx.json') @'
{
  "metadata": [{
    "src": [{ "src": "../", "files": ["src/Acme.Core.csproj"] }],
    "dest": "api",
    "properties": { "TargetFramework": "net10.0" }
  }],
  "build": {
    "content": [{ "files": ["*.md"], "exclude": ["api/namespaces/**", "api/types/**"] }],
    "overwrite": [{ "files": ["api/namespaces/**/*.md", "api/types/**/*.md"] }],
    "dest": "_site"
  }
}
'@

    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.md') @"
---
uid: Acme.Core
summary: *content
---
The Acme.Core namespace contains types and extension methods for common work.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|``Normalize``|
"@
    Write-Utf8File (Join-Path $workspace '.docfx/api/types/Acme.Core.Options.md') @'
---
uid: Acme.Core.Options
example: *content
---
```csharp
namespace Samples;

public static class MetadataLookup
{
    public static Type? Find() => Type.GetType("Acme.Core.Options, Acme.Core");
}
```
'@
    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.StringExtensions.md') @'
---
uid: Acme.Core.StringExtensions
example: *content
---
The documented extension method is available at runtime.

```csharp
namespace Cuemon.DocFxExamples;

public static class DocumentedExtensionExample
{
    public static string Describe() => "Normalize";
}
```

---
uid: Acme.Core.StringExtensions
example: *content
---
The documented type is an extension surface.

```csharp
namespace Cuemon.DocFxExamples;

public static class DocumentedTypeExample
{
    public static string Describe() => "StringExtensions";
}
```
'@

    $bad = Invoke-Validator
    foreach ($code in @(
        'NAMESPACE_PROSE_INVENTORY_ONLY',
        'NAMESPACE_USAGE_GUIDANCE_MISSING',
        'NAMESPACE_START_HERE_MISSING',
        'EXAMPLE_UID_DUPLICATE',
        'EXAMPLE_REFLECTION_ONLY',
        'EXAMPLE_PLACEHOLDER'
    )) {
        Assert-Diagnostic -Report $bad -Code $code
    }

    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.md') @"
---
uid: Acme.Core
summary: *content
---
Use ``Options`` when a caller needs to keep retry policy values together before configuring a client. It gives validation and composition code one explicit object to pass across boundaries.

Start with ``Options`` for policy values; use ``Normalize`` at text-ingress boundaries when identifiers need stable casing and whitespace before comparison or storage.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|``Normalize``|
"@
    Write-Utf8File (Join-Path $workspace '.docfx/api/types/Acme.Core.Options.md') @'
---
uid: Acme.Core.Options
example: *content
---
```csharp
namespace Samples;

using Acme.Core;

public static class RetryConfiguration
{
    public static Options Create() => new() { Attempts = 3 };
}
```
'@
    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.StringExtensions.md') @'
---
uid: Acme.Core.StringExtensions
example: *content
---
```csharp
namespace Samples;

using Acme.Core;

public static class IdentifierInput
{
    public static string Prepare(string value) => value.Normalize();
}
```
'@

    $assessmentQueue = Join-Path ([System.IO.Path]::GetTempPath()) ('docfx-assessment-queue-' + [guid]::NewGuid().ToString('N') + '.md')
    try {
        $assessmentQueueReport = Invoke-Validator -ExtraArgs @('--assessment-queue', $assessmentQueue)
        if (-not (Test-Path $assessmentQueue)) {
            throw 'The --assessment-queue flag did not write a Markdown queue file.'
        }
        $queueText = [System.IO.File]::ReadAllText($assessmentQueue)
        if ($queueText -notmatch '^# DocFX Assessment Work Queue') {
            throw 'The assessment work queue heading was not written as expected.'
        }
    } finally {
        if (Test-Path $assessmentQueue) {
            Remove-Item -Path $assessmentQueue -Force
        }
    }

    $good = Invoke-Validator
    $qualityCodes = @(
        'NAMESPACE_FLYIN_MISSING',
        'NAMESPACE_PROSE_INVENTORY_ONLY',
        'NAMESPACE_USAGE_GUIDANCE_MISSING',
        'NAMESPACE_START_HERE_MISSING',
        'EXAMPLE_UID_DUPLICATE',
        'EXAMPLE_PLACEHOLDER',
        'EXAMPLE_REFLECTION_ONLY',
        'EXAMPLE_TARGET_NOT_USED',
        'EXTENSION_EXAMPLE_NOT_INVOKED',
        'EXAMPLE_MISSING'
    )
    $remaining = @($good.errors | Where-Object { $_.code -in $qualityCodes })
    if ($remaining.Count -gt 0) {
        throw "Scenario-led fixture still has quality diagnostics: $($remaining.code -join ', ')"
    }

    Write-Host 'DocFX semantic quality regression passed.'
} finally {
    if (Test-Path $workspace) {
        Remove-Item -Path $workspace -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: source discovery for Cuemon-style next-line namespace braces.
# A block namespace whose opening brace is on the following line must not
# hide its public types. Before the scanner fix the validator discovered
# ~0 targets here; the fixture fails if discovery collapses to one target.
# ----------------------------------------------------------------------
$discovery = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-discovery-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $discovery 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $discovery 'src/Acme.Widgets.csproj') $projectCsproj
    Write-Utf8File (Join-Path $discovery 'src/Widgets.cs') @'
namespace Acme.Widgets
{
    public sealed class Gadget
    {
        public int Size { get; set; }
    }

    public sealed class Sprocket
    {
        public int Teeth { get; set; }
    }

    public sealed class Cog
    {
        public int Radius { get; set; }
    }

    public static class WidgetExtensions
    {
        public static string Describe(this Gadget gadget) => gadget.Size.ToString();
    }
}
'@
    Write-Utf8File (Join-Path $discovery '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Widgets.csproj'))

    $discoveryReport = Invoke-Validator -Workspace $discovery
    if ([int]$discoveryReport.summary.requiredExampleTargets -lt 4) {
        throw "Next-line namespace brace discovery under-reported targets: expected >= 4, got $($discoveryReport.summary.requiredExampleTargets)."
    }
    if (-not @($discoveryReport.errors | Where-Object { $_.code -eq 'EXAMPLE_MISSING' -and $_.namespace -eq 'Acme.Widgets' })) {
        throw 'Discovery fixture did not surface Acme.Widgets targets through the source scanner.'
    }

    Write-Host 'DocFX next-line namespace discovery passed.'
} finally {
    if (Test-Path $discovery) {
        Remove-Item -Path $discovery -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: public static factory classes are valid fast source-scan type
# targets even when they do not declare extension methods. Matching type
# overwrite files must be accepted as deliverables, not scratch artifacts.
# ----------------------------------------------------------------------
$staticFactory = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-static-factory-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $staticFactory 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $staticFactory 'src/Acme.Hosting.csproj') $projectCsproj
    Write-Utf8File (Join-Path $staticFactory 'src/Hosting.cs') @'
namespace Acme.Hosting;

public sealed class HostHarness
{
    public string Name { get; set; } = string.Empty;
}

public static class HostTestFactory
{
    public static HostHarness Create(string name) => new() { Name = name };
}
'@
    Write-Utf8File (Join-Path $staticFactory '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Hosting.csproj'))
    Initialize-GitRepo $staticFactory
    Write-Utf8File (Join-Path $staticFactory '.docfx/api/namespaces/Acme.Hosting.md') @'
---
uid: Acme.Hosting
---

Namespace overview.
'@
    Write-Utf8File (Join-Path $staticFactory '.docfx/api/types/Acme.Hosting.HostHarness.md') @'
---
uid: Acme.Hosting.HostHarness
example: *content
---
```csharp
using Acme.Hosting;

namespace Samples;

public static class HostHarnessExample
{
    public static string ReadName()
    {
        HostHarness harness = HostTestFactory.Create("integration");
        return harness.Name;
    }
}
```
'@
    Write-Utf8File (Join-Path $staticFactory '.docfx/api/types/Acme.Hosting.HostTestFactory.md') @'
---
uid: Acme.Hosting.HostTestFactory
example: *content
---
```csharp
using Acme.Hosting;

namespace Samples;

public static class HostTestFactoryExample
{
    public static string CreateName()
    {
        HostHarness harness = HostTestFactory.Create("integration");
        return harness.Name;
    }
}
```
'@

    $staticFactoryReport = Invoke-Validator -Workspace $staticFactory -ExtraArgs @('--build-api-model')
    if ([int]$staticFactoryReport.summary.requiredExampleTargets -ne 2) {
        throw "Public static factory discovery under-reported targets: expected 2, got $($staticFactoryReport.summary.requiredExampleTargets)."
    }
    Assert-NoDiagnostic -Report $staticFactoryReport -Code 'INTERIM_ARTIFACT_IN_WORKTREE'

    Write-Host 'DocFX static factory discovery passed.'
} finally {
    if (Test-Path $staticFactory) {
        Remove-Item -Path $staticFactory -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: reflection-backed discovery must resolve project-reference DLLs
# copied beside a documented project's runtime output even when the selected
# metadata assembly is a reference assembly under obj/.
# ----------------------------------------------------------------------
$transitiveDiscovery = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-transitive-discovery-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $transitiveDiscovery 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $transitiveDiscovery 'src/Acme.Shared/Acme.Shared.csproj') $projectCsproj
    Write-Utf8File (Join-Path $transitiveDiscovery 'src/Acme.Shared/BaseContext.cs') @'
namespace Acme.Shared;

public abstract class BaseContext
{
    public string Name { get; protected set; } = string.Empty;
}
'@
    Write-Utf8File (Join-Path $transitiveDiscovery 'src/Acme.Hosting/Acme.Hosting.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../Acme.Shared/Acme.Shared.csproj" />
  </ItemGroup>
</Project>
'@
    Write-Utf8File (Join-Path $transitiveDiscovery 'src/Acme.Hosting/HostContext.cs') @'
using Acme.Shared;

namespace Acme.Hosting;

public sealed class HostContext : BaseContext
{
    public HostContext()
    {
        Name = "integration";
    }
}
'@
    Write-Utf8File (Join-Path $transitiveDiscovery '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Hosting/Acme.Hosting.csproj'))
    Write-Utf8File (Join-Path $transitiveDiscovery '.docfx/api/namespaces/Acme.Hosting.md') @'
---
uid: Acme.Hosting
summary: *content
---
Use `HostContext` when an integration workflow needs the configured host name exposed by the shared context contract.

Start with `HostContext` to create the context and read its inherited `Name` result.

Availability: `Acme.Hosting`
'@
    Write-Utf8File (Join-Path $transitiveDiscovery '.docfx/api/types/Acme.Hosting.HostContext.md') @'
---
uid: Acme.Hosting.HostContext
example: *content
---
Create the context when a caller needs the integration host name supplied through the shared base contract.

```csharp
using Acme.Hosting;

namespace Samples;

public static class HostContextExample
{
    public static string ReadName()
    {
        var context = new HostContext();
        return context.Name;
    }
}
```
'@

    $transitiveReport = Invoke-Validator -Workspace $transitiveDiscovery -ExtraArgs @('--build-api-model')
    Assert-NoDiagnostic -Report $transitiveReport -Code 'PUBLIC_API_DISCOVERY_FAILED'
    if ([int]$transitiveReport.summary.requiredExampleTargets -ne 1) {
        throw "Project-reference discovery under-reported targets: expected 1, got $($transitiveReport.summary.requiredExampleTargets)."
    }

    Write-Host 'DocFX transitive project-reference discovery passed.'
} finally {
    if (Test-Path $transitiveDiscovery) {
        Remove-Item -Path $transitiveDiscovery -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: known-bad example quality patterns observed in the Cuemon run.
# Each anti-pattern must raise its dedicated diagnostic.
# ----------------------------------------------------------------------
$quality = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-examples-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $quality 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $quality 'src/Acme.Demo.csproj') $projectCsproj
    Write-Utf8File (Join-Path $quality 'src/Demo.cs') @'
namespace Acme.Demo;

public sealed class Holder { public int Value { get; set; } }
public sealed class Outcome { public int Value { get; set; } }
public sealed class RuntimeNamed { public int Value { get; set; } }
public sealed class Forwarder { public int Value { get; set; } }
public sealed class RepA { public int Value { get; set; } }
public sealed class RepB { public int Value { get; set; } }
public sealed class RepC { public int Value { get; set; } }
public sealed class ReadySignal { public bool IsReady { get; set; } }
public sealed class Leadless { public int Value { get; set; } public void Apply(int value) => Value = value; }
public sealed class AdvancedSetup { public int Value { get; set; } public void Apply(int value) => Value = value; }

public static class ApplicationTestFactory
{
    public static Outcome Create<TEntryPoint>() where TEntryPoint : class => new() { Value = 42 };
}

public static class AppFactory
{
    public static Outcome Create<TEntryPoint>() where TEntryPoint : class => new() { Value = 42 };
}

public static class WebTestFactory
{
    public static Outcome Create<TEntryPoint>() where TEntryPoint : class => new() { Value = 42 };
}

public static class HostFixture
{
    public static Outcome Create<TEntryPoint>() where TEntryPoint : class => new() { Value = 42 };
}

public static class ApplicationRepositoryFactory
{
    public static Outcome Create<TModel>() where TModel : class => new() { Value = 42 };
}
'@
    Write-Utf8File (Join-Path $quality '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Demo.csproj'))

    # Weak inventory lead left intact with appended start-here guidance.
    Write-Utf8File (Join-Path $quality '.docfx/api/namespaces/Acme.Demo.md') @'
---
uid: Acme.Demo
summary: *content
---
The Acme.Demo namespace contains types and helpers that enable common demo work across the package.

Start with `Holder` to keep state together; reach for `Forwarder` when callers need pass-through access.

Availability: `Acme.Demo`
'@

    # default! holder property.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Holder.md') @'
---
uid: Acme.Demo.Holder
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class HolderState
{
    public static Holder Current { get; } = default!;
}
```
'@

    # Construction with no observable next action.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Outcome.md') @'
---
uid: Acme.Demo.Outcome
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class UseOutcome
{
    public static Outcome Build()
    {
        var result = new Outcome();
        return result;
    }
}
```
'@

    # Runtime implementation type names are mechanically observable but do not explain API behavior.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.RuntimeNamed.md') @'
---
uid: Acme.Demo.RuntimeNamed
example: *content
---
The following example prints the runtime implementation name after constructing the documented type.

```csharp
using System;
using Acme.Demo;

namespace Samples;

public static class RuntimeNameReporter
{
    public static void Report()
    {
        var item = new RuntimeNamed { Value = 42 };
        Console.WriteLine(item.GetType().Name);
    }
}
```
'@

    # An empty Program type makes an entry-point sample compile without representing a runnable application.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.ApplicationTestFactory.md') @'
---
uid: Acme.Demo.ApplicationTestFactory
example: *content
---
The following example claims to bootstrap an application and read its configured result.

```csharp
using Acme.Demo;

namespace Samples;

public static class ApplicationFactoryExample
{
    public static int Read()
    {
        var application = ApplicationTestFactory.Create<Program>();
        return application.Value;
    }
}

public class Program { }
```
'@

    foreach ($entryPointType in @('AppFactory', 'WebTestFactory', 'HostFixture')) {
        Write-Utf8File (Join-Path $quality ".docfx/api/types/Acme.Demo.$entryPointType.md") @"
---
uid: Acme.Demo.$entryPointType
example: *content
---
The following example claims to bootstrap an application and read its configured result.

``````csharp
using Acme.Demo;

namespace Samples;

public static class EntryPointExample
{
    public static int Read() => $entryPointType.Create<Program>().Value;
}

public class Program { }
``````
"@
    }

    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.ApplicationRepositoryFactory.md') @'
---
uid: Acme.Demo.ApplicationRepositoryFactory
example: *content
---
This repository factory example uses a local model and returns the configured value.

```csharp
using Acme.Demo;

namespace Samples;

public static class RepositoryFactoryExample
{
    public static int Read() => ApplicationRepositoryFactory.Create<Program>().Value;
}

public class Program { }
```
'@

    # Mass forwarding shell.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Forwarder.md') @'
---
uid: Acme.Demo.Forwarder
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class ForwarderFacade
{
    public static int Read(Forwarder source) => source.Read();
    public static int Peek(Forwarder source) => source.Peek();
    public static int Count(Forwarder source) => source.Count();
}
```
'@

    # Avoidable fully qualified framework references copied straight from tests.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.ReadySignal.md') @'
---
uid: Acme.Demo.ReadySignal
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class UseReadySignal
{
    public static System.Threading.Tasks.Task BuildAsync()
    {
        var signal = new ReadySignal { IsReady = true };
        System.Console.WriteLine(signal.IsReady);
        return System.Threading.Tasks.Task.CompletedTask;
    }
}
```
'@

    # Valid code without a human fly-in before the C# fence.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Leadless.md') @'
---
uid: Acme.Demo.Leadless
example: *content
---
```csharp
namespace Samples;

using System;
using Acme.Demo;

public static class UseLeadless
{
    public static void Run()
    {
        var item = new Leadless();
        item.Apply(42);
        Console.WriteLine(item.Value);
    }
}
```
'@

    # Large setup-shaped sample with a lead that is too shallow for its complexity.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.AdvancedSetup.md') @'
---
uid: Acme.Demo.AdvancedSetup
example: *content
---
The following example shows an advanced processing sample.

```csharp
namespace Samples;

using System;
using System.Collections.Generic;
using Acme.Demo;

public sealed class AdvancedSetupWorkflow
{
    private readonly Dictionary<string, int> values = new();

    public void Run()
    {
        var setup = new AdvancedSetup();
        setup.Apply(1);
        values["first"] = setup.Value;

        setup.Apply(2);
        values["second"] = setup.Value;

        setup.Apply(3);
        values["third"] = setup.Value;

        Console.WriteLine(values["first"]);
        Console.WriteLine(values["second"]);
        Console.WriteLine(values["third"]);
    }
}

public sealed class AdvancedSetupReport
{
    public int First { get; set; }
    public int Second { get; set; }
}

public sealed class AdvancedSetupResult
{
    public int Total { get; set; }
}
```
'@

    # Three structurally identical examples differing only by identifiers.
    foreach ($name in @('RepA', 'RepB', 'RepC')) {
        Write-Utf8File (Join-Path $quality ".docfx/api/types/Acme.Demo.$name.md") @"
---
uid: Acme.Demo.$name
example: *content
---
The following example creates a repeatable item and applies one value before returning it.

``````csharp
namespace Samples;

using Acme.Demo;

public static class Use$name
{
    public static $name Create()
    {
        var item = new $name();
        item.Apply(1);
        return item;
    }
}
``````
"@
    }

    $badQuality = Invoke-Validator -Workspace $quality -ExtraArgs @('--build-api-model')
    foreach ($code in @(
        'EXAMPLE_DEFAULT_PLACEHOLDER',
        'EXAMPLE_NO_OBSERVABLE_OUTCOME',
        'EXAMPLE_RUNTIME_TYPE_NAME_OUTCOME',
        'EXAMPLE_EMPTY_ENTRY_POINT_STUB',
        'EXAMPLE_FORWARDING_SCAFFOLD',
        'EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE',
        'EXAMPLE_LEAD_MISSING',
        'EXAMPLE_ADVANCED_LEAD_MISSING',
        'EXAMPLE_TEMPLATE_REPETITION',
        'NAMESPACE_APPEND_ONLY_REPAIR'
    )) {
        Assert-Diagnostic -Report $badQuality -Code $code
    }
    foreach ($entryPointType in @('AppFactory', 'WebTestFactory', 'HostFixture')) {
        Assert-DiagnosticForPath -Report $badQuality -Code 'EXAMPLE_EMPTY_ENTRY_POINT_STUB' -PathFragment "Acme.Demo.$entryPointType.md"
    }
    Assert-NoDiagnosticForPath -Report $badQuality -Code 'EXAMPLE_EMPTY_ENTRY_POINT_STUB' -PathFragment 'Acme.Demo.ApplicationRepositoryFactory.md'
    Assert-DiagnosticMessageContains -Report $badQuality -Code 'EXAMPLE_NO_OBSERVABLE_OUTCOME' -Text 'placeholder comments still fails'

    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.ReadySignal.md') @'
---
uid: Acme.Demo.ReadySignal
example: *content
---
```csharp
namespace Samples;

using System;
using System.Threading.Tasks;
using Acme.Demo;

public static class UseReadySignal
{
    public static Task BuildAsync()
    {
        var signal = new ReadySignal { IsReady = true };
        Console.WriteLine(signal.IsReady);
        return Task.CompletedTask;
    }
}
```
'@

    $leanQuality = Invoke-Validator -Workspace $quality -ExtraArgs @('--build-api-model')
    Assert-NoDiagnostic -Report $leanQuality -Code 'EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE'

    Write-Host 'DocFX example quality regression passed.'
} finally {
    if (Test-Path $quality) {
        Remove-Item -Path $quality -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: decorated extension receivers and generic method names must stay intact
# in Extension Members tables.
# ----------------------------------------------------------------------
$decoratedExtensions = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-decorated-extension-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $decoratedExtensions 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $decoratedExtensions 'src/Acme.Core.csproj') $projectCsproj
    Write-Utf8File (Join-Path $decoratedExtensions 'src/Decorators.cs') @'
namespace Acme.Core;

public interface IDecorator<T>
{
    T Inner { get; }
}

public static class TypeDecoratorExtensions
{
    public static string AsName<T>(this IDecorator<Type> decorator) => typeof(T).Name + ":" + decorator.Inner.Name;

    public static string AsName(this IDecorator<Type> decorator) => decorator.Inner.Name;
}
'@
    Write-Utf8File (Join-Path $decoratedExtensions '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Core.csproj'))
    Write-Utf8File (Join-Path $decoratedExtensions '.docfx/api/namespaces/Acme.Core.md') @'
---
uid: Acme.Core
summary: *content
---
Use `TypeDecoratorExtensions` when you need to keep type-focused helper calls available behind a decorator abstraction instead of exposing them as direct `Type` extension methods.

Start with `TypeDecoratorExtensions` when a pipeline already works with `IDecorator<Type>` values and still needs readable type names.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|Type|⬇️|`AsName`, `AsName`|
'@
    Write-Utf8File (Join-Path $decoratedExtensions '.docfx/api/types/Acme.Core.TypeDecoratorExtensions.md') @'
---
uid: Acme.Core.TypeDecoratorExtensions
example: *content
---
```csharp
using System;
using Acme.Core;

namespace Samples;

public sealed class InlineTypeDecorator : IDecorator<Type>
{
    public InlineTypeDecorator(Type inner) => Inner = inner;

    public Type Inner { get; }
}

public static class DecoratedTypeExample
{
    public static void Print()
    {
        IDecorator<Type> decorator = new InlineTypeDecorator(typeof(Guid));

        Console.WriteLine(decorator.AsName());
        Console.WriteLine(decorator.AsName<string>());
    }
}
```
'@

    $decoratedBad = Invoke-Validator -Workspace $decoratedExtensions
    Assert-Diagnostic -Report $decoratedBad -Code 'EXTENSION_RECEIVER_MISMATCH'
    Assert-Diagnostic -Report $decoratedBad -Code 'EXTENSION_METHOD_SIGNATURE_MISSING'

    Write-Utf8File (Join-Path $decoratedExtensions '.docfx/api/namespaces/Acme.Core.md') @'
---
uid: Acme.Core
summary: *content
---
Use `TypeDecoratorExtensions` when you need to keep type-focused helper calls available behind a decorator abstraction instead of exposing them as direct `Type` extension methods.

Start with `TypeDecoratorExtensions` when a pipeline already works with `IDecorator<Type>` values and still needs readable type names.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|IDecorator<Type>|⬇️|`AsName<T>`, `AsName`|
'@

    $decoratedGood = Invoke-Validator -Workspace $decoratedExtensions
    Assert-NoDiagnostic -Report $decoratedGood -Code 'EXTENSION_RECEIVER_MISMATCH'
    Assert-NoDiagnostic -Report $decoratedGood -Code 'EXTENSION_METHOD_SIGNATURE_MISSING'
    Assert-NoDiagnostic -Report $decoratedGood -Code 'EXAMPLE_MISSING'

    Write-Host 'DocFX decorated extension signature regression passed.'
} finally {
    if (Test-Path $decoratedExtensions) {
        Remove-Item -Path $decoratedExtensions -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: Extension Members tables must not list invented extension method
# names. This guards against plausible but nonexistent setup methods such as
# AddCuemonTextJson when the public API only exposes AddMinimalJsonOptions.
# ----------------------------------------------------------------------
$inventedExtension = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-invented-extension-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $inventedExtension 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $inventedExtension 'src/Acme.AspNetCore.Text.Json.csproj') $projectCsproj
    Write-Utf8File (Join-Path $inventedExtension 'src/ServiceCollectionExtensions.cs') @'
namespace Acme.AspNetCore.Text.Json;

public interface IServiceCollection
{
}

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddMinimalJsonOptions(this IServiceCollection services) => services;
}
'@
    Write-Utf8File (Join-Path $inventedExtension '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.AspNetCore.Text.Json.csproj'))
    Write-Utf8File (Join-Path $inventedExtension '.docfx/api/namespaces/Acme.AspNetCore.Text.Json.md') @'
---
uid: Acme.AspNetCore.Text.Json
summary: *content
---
Configure JSON options for ASP.NET Core applications with source-backed Cuemon conventions. Start with `AddMinimalJsonOptions` on `IServiceCollection`.

Availability: `Acme.AspNetCore.Text.Json`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|IServiceCollection|⬇️|`AddCuemonTextJson`, `AddMinimalJsonOptions`|
'@
    Write-Utf8File (Join-Path $inventedExtension '.docfx/api/types/Acme.AspNetCore.Text.Json.ServiceCollectionExtensions.md') @'
---
uid: Acme.AspNetCore.Text.Json.ServiceCollectionExtensions
example: *content
---
```csharp
using Acme.AspNetCore.Text.Json;

namespace Samples;

public static class MinimalJsonOptionsExample
{
    public static IServiceCollection ConfigureJson(IServiceCollection services)
    {
        return services.AddMinimalJsonOptions();
    }
}
```
'@

    $inventedReport = Invoke-Validator -Workspace $inventedExtension
    Assert-Diagnostic -Report $inventedReport -Code 'EXTENSION_METHOD_UNKNOWN'

    Write-Utf8File (Join-Path $inventedExtension '.docfx/api/namespaces/Acme.AspNetCore.Text.Json.md') @'
---
uid: Acme.AspNetCore.Text.Json
summary: *content
---
Configure JSON options for ASP.NET Core applications with source-backed Cuemon conventions. Start with `AddMinimalJsonOptions` on `IServiceCollection`.

Availability: `Acme.AspNetCore.Text.Json`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|IServiceCollection|⬇️|`AddMinimalJsonOptions`|
'@

    $sourceBackedReport = Invoke-Validator -Workspace $inventedExtension
    Assert-NoDiagnostic -Report $sourceBackedReport -Code 'EXTENSION_METHOD_UNKNOWN'
    Assert-NoDiagnostic -Report $sourceBackedReport -Code 'EXTENSION_METHOD_MISSING'

    Write-Host 'DocFX invented extension-member regression passed.'
} finally {
    if (Test-Path $inventedExtension) {
        Remove-Item -Path $inventedExtension -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: one authored extension-container example may satisfy several extension targets.
# The section is one authored scenario and must not be counted once per covered method.
# ----------------------------------------------------------------------
$sharedExtension = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-shared-extension-' + [guid]::NewGuid().ToString('N'))
try {
    $arrow = "$([char]0x2B07)$([char]0xFE0F)"
    Write-Utf8File (Join-Path $sharedExtension 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $sharedExtension 'src/Acme.Extensions.csproj') $projectCsproj
    Write-Utf8File (Join-Path $sharedExtension 'src/Extensions.cs') @'
namespace Acme.Extensions;

public static class TextExtensions
{
    public static string Trimmed(this string value) => value.Trim();
    public static string Uppercase(this string value) => value.ToUpperInvariant();
    public static int WordCount(this string value) => value.Split(' ', System.StringSplitOptions.RemoveEmptyEntries).Length;
}
'@
    Write-Utf8File (Join-Path $sharedExtension '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Extensions.csproj'))
    Write-Utf8File (Join-Path $sharedExtension '.docfx/api/namespaces/Acme.Extensions.md') @"
---
uid: Acme.Extensions
summary: *content
---
Choose these text operations when input needs small, explicit transformations before display or comparison. `TextExtensions` keeps each operation available directly on the source string.

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|``Trimmed``, ``Uppercase``, ``WordCount``|

Availability: ``Acme.Extensions``
"@
    Write-Utf8File (Join-Path $sharedExtension '.docfx/api/types/Acme.Extensions.TextExtensions.md') @'
---
uid: Acme.Extensions.TextExtensions
example: *content
---
This example prepares a user-entered title and reports the resulting word count.

```csharp
using System;
using Acme.Extensions;

namespace Samples;

public static class TextPreparationExample
{
    public static void PrintPreparedTitle()
    {
        const string input = "  release notes  ";
        var prepared = input.Trimmed().Uppercase();

        Console.WriteLine(prepared);
        Console.WriteLine(prepared.WordCount());
    }
}
```
'@

    $sharedReport = Invoke-Validator -Workspace $sharedExtension
    Assert-NoDiagnostic -Report $sharedReport -Code 'EXAMPLE_TEMPLATE_REPETITION'
    Assert-NoDiagnostic -Report $sharedReport -Code 'EXAMPLE_MISSING'

    Write-Host 'DocFX shared extension example fingerprint regression passed.'
} finally {
    if (Test-Path $sharedExtension) {
        Remove-Item -Path $sharedExtension -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: mechanical namespace prose repeated across unrelated pages.
# Three namespaces that share one normalized prose skeleton must fail. Two unrelated pages using
# the distinctive "namespace helps you / Use it when / Start with" cadence must also fail even
# when their domain vocabulary is otherwise different.
# ----------------------------------------------------------------------
$prose = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-prose-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $prose 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $prose 'src/Acme.Families.csproj') $projectCsproj
    Write-Utf8File (Join-Path $prose 'src/Families.cs') @'
namespace Alpha
{
    public sealed class AlphaType { public int Value { get; set; } }
}

namespace Beta
{
    public sealed class BetaType { public int Value { get; set; } }
}

namespace Gamma
{
    public sealed class GammaType { public int Value { get; set; } }
}
'@
    Write-Utf8File (Join-Path $prose '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Families.csproj'))

    foreach ($pair in @(@('Alpha', 'AlphaType'), @('Beta', 'BetaType'), @('Gamma', 'GammaType'))) {
        $ns = $pair[0]
        $type = $pair[1]
        Write-Utf8File (Join-Path $prose ".docfx/api/namespaces/$ns.md") @"
---
uid: $ns
summary: *content
---
Use ``$type`` when callers need a single entry point for the workflow. It keeps configuration explicit and easy to pass across boundaries.

Availability: ``$ns``
"@
    }

    $proseReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $proseReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    # Replace the three exact skeletons with two lexically different pages that retain the same
    # mechanical rhetorical frame. Gamma remains independently written and must not be required
    # to trigger the diagnostic.
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Alpha.md') @'
---
uid: Alpha
summary: *content
---
The `Alpha` namespace helps you retry transient work without scattering recovery bookkeeping across call sites.

Use it when a caller owns the retry decision and needs a bounded attempt count. If you are defining the recovery policy, begin with `AlphaType` to execute the protected operation.

Availability: `Alpha`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Beta.md') @'
---
uid: Beta
summary: *content
---
The `Beta` namespace helps you divide a large import into predictable processing windows.

Use it when workers need bounded ranges instead of hand-maintained indexes. If you are dividing a new workload, start with `BetaType` to plan each assignment.

Availability: `Beta`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Gamma.md') @'
---
uid: Gamma
summary: *content
---
Choose `GammaType` when a boundary needs one explicit value that can be inspected before work begins. It keeps the decision local to the caller rather than hiding it in shared state.

Availability: `Gamma`
'@

    $rhetoricalReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $rhetoricalReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Alpha.md') @'
---
uid: Alpha
summary: *content
---
Use the `Alpha` namespace when operations can fail transiently and callers need bounded retries. The namespace separates recovery policy from the work itself.

Start with `AlphaType` to define the attempt budget, then execute the protected operation. Choose this namespace when retry behavior belongs to application flow.

Availability: `Alpha`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Beta.md') @'
---
uid: Beta
summary: *content
---
Use the `Beta` namespace when imports need predictable windows instead of handwritten indexes. The namespace keeps range planning in one place.

Start with `BetaType` to select the window size, then create each assignment. Choose this namespace when the caller controls batching directly.

Availability: `Beta`
'@

    $imperativeReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $imperativeReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    # Vary the lead paragraphs while retaining the repeated navigation paragraph that escaped
    # the earlier signatures during the representative forward test.
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Alpha.md') @'
---
uid: Alpha
summary: *content
---
The `Alpha` namespace turns transient failures into bounded recovery attempts without spreading retry bookkeeping across call sites. Use it when application code owns the recovery decision.

Start with `AlphaType` to choose the attempt budget, then pass that policy to the operation that performs the work.

Availability: `Alpha`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Beta.md') @'
---
uid: Beta
summary: *content
---
The `Beta` namespace divides large imports into predictable processing windows for workers and queues. It is useful when callers need bounded ranges instead of handwritten indexes.

Start with `BetaType` to select the window size, then use the resulting assignments in the processing loop.

Availability: `Beta`
'@

    $navigationReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $navigationReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    Write-Host 'DocFX namespace prose repetition regression passed.'
} finally {
    if (Test-Path $prose) {
        Remove-Item -Path $prose -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: fast DocFX-YAML discovery must collapse C# 14 synthetic extension-block
# containers back to the authored outer static class instead of requiring a standalone
# `<G>$...` overwrite file.
# ----------------------------------------------------------------------
$yamlExtensionBlocks = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-yaml-extension-blocks-' + [guid]::NewGuid().ToString('N'))
try {
    $arrow = "$([char]0x2B07)$([char]0xFE0F)"
    Write-Utf8File (Join-Path $yamlExtensionBlocks 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $yamlExtensionBlocks 'src/Acme.Core.csproj') $projectCsproj
    Write-Utf8File (Join-Path $yamlExtensionBlocks 'src/Extensions.cs') @'
namespace Acme.Core;

public static class EndpointExtensions
{
}
'@
    Write-Utf8File (Join-Path $yamlExtensionBlocks '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Core.csproj'))
    $literalSyntheticName = '<G>$AB12CD34'
    $literalSyntheticUid = "Acme.Core.EndpointExtensions.$literalSyntheticName"
    $puaSyntheticName = "$([char]0xF03C)" + 'G' + "$([char]0xF03E)" + '$6D0D8037DBBD61D10816ECA5F93B896F'
    $puaSyntheticUid = "Acme.Core.EndpointExtensions.$puaSyntheticName"
    Write-Utf8File (Join-Path $yamlExtensionBlocks '.docfx/api/Acme.Core.EndpointExtensions.yml') @"
items:
- uid: Acme.Core.EndpointExtensions
  parent: Acme.Core
  type: Class
  namespace: Acme.Core
  name: EndpointExtensions
  syntax:
    content: public static class EndpointExtensions
- uid: $literalSyntheticUid
  parent: Acme.Core.EndpointExtensions
  type: Class
  namespace: Acme.Core
  name: $literalSyntheticName
  syntax:
    content: public sealed class $literalSyntheticName
- uid: $literalSyntheticUid.Normalize(System.String)
  parent: $literalSyntheticUid
  type: Method
  namespace: Acme.Core
  name: Normalize
  syntax:
    content: public static string Normalize(this string value)
- uid: $puaSyntheticUid
  parent: Acme.Core.EndpointExtensions
  type: Class
  namespace: Acme.Core
  name: $puaSyntheticName
  syntax:
    content: public sealed class $puaSyntheticName
- uid: $puaSyntheticUid.Normalize(System.String)
  parent: $puaSyntheticUid
  type: Method
  namespace: Acme.Core
  name: Normalize
  syntax:
    content: public static string Normalize(this string value)
"@
    Write-Utf8File (Join-Path $yamlExtensionBlocks '.docfx/api/namespaces/Acme.Core.md') @"
---
uid: Acme.Core
summary: *content
---
Use `EndpointExtensions` when text should be normalized at an ingress boundary before validation or comparison.

Start with `EndpointExtensions` when callers want one explicit `Normalize` call directly on the incoming string.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|`Normalize`|
"@
    Write-Utf8File (Join-Path $yamlExtensionBlocks '.docfx/api/types/Acme.Core.EndpointExtensions.md') @'
---
uid: Acme.Core.EndpointExtensions
example: *content
---
The `EndpointExtensions` class provides extension methods for `string` through C# 14 extension blocks.

```csharp
using Acme.Core;

namespace Samples;

public static class BoundaryInput
{
    public static string Normalize(string value) => value.Normalize();
}
```
'@

    $yamlExtensionSyntaxReport = Invoke-Validator -Workspace $yamlExtensionBlocks
    if ($yamlExtensionSyntaxReport.summary.apiModelSource -ne 'docfx-yaml') {
        throw "Expected docfx-yaml discovery for the synthetic extension-block fixture, got '$($yamlExtensionSyntaxReport.summary.apiModelSource)'."
    }

    Assert-Warning -Report $yamlExtensionSyntaxReport -Code 'DOCFX_EXTENSION_BLOCK_UNSUPPORTED'
    Assert-Diagnostic -Report $yamlExtensionSyntaxReport -Code 'EXAMPLE_EXTENSION_CONTAINER_LANGUAGE_FOCUS'

    Write-Utf8File (Join-Path $yamlExtensionBlocks '.docfx/api/types/Acme.Core.EndpointExtensions.md') @'
---
uid: Acme.Core.EndpointExtensions
example: *content
---
Use `EndpointExtensions` when incoming text should be normalized at the boundary before validation or comparison.

```csharp
using Acme.Core;

namespace Samples;

public static class BoundaryInput
{
    public static string Normalize(string value) => value.Normalize();
}
```
'@

    $yamlExtensionReport = Invoke-Validator -Workspace $yamlExtensionBlocks
    Assert-Warning -Report $yamlExtensionReport -Code 'DOCFX_EXTENSION_BLOCK_UNSUPPORTED'
    Assert-NoDiagnostic -Report $yamlExtensionReport -Code 'EXAMPLE_EXTENSION_CONTAINER_LANGUAGE_FOCUS'
    Assert-NoDiagnostic -Report $yamlExtensionReport -Code 'EXAMPLE_MISSING'
    Assert-NoDiagnostic -Report $yamlExtensionReport -Code 'EXAMPLE_TARGET_NOT_USED'
    Assert-NoDiagnostic -Report $yamlExtensionReport -Code 'EXTENSION_EXAMPLE_NOT_INVOKED'

    Write-Utf8File (Join-Path $yamlExtensionBlocks ('.docfx/api/types/' + $puaSyntheticUid + '.md')) 'Synthetic extension-block filenames must be rejected.'
    Set-Variable -Name syntheticFilenameReport -Value (Invoke-Validator -Workspace $yamlExtensionBlocks)
    Assert-Diagnostic -Report (Get-Variable -Name syntheticFilenameReport -ValueOnly) -Code 'API_OVERWRITE_SYNTHETIC_UID_FILENAME'

    Write-Host 'DocFX YAML extension-block regression passed.'
} finally {
    if (Test-Path $yamlExtensionBlocks) {
        Remove-Item -Path $yamlExtensionBlocks -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: result/profiler carrier examples should use the public producer
# workflow when direct construction depends on internal constructors.
# ----------------------------------------------------------------------
$factoryOrigin = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-factory-origin-' + [guid]::NewGuid().ToString('N'))
try {
Write-Utf8File (Join-Path $factoryOrigin 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
Write-Utf8File (Join-Path $factoryOrigin 'src/Acme.Measure.csproj') $projectCsproj
Write-Utf8File (Join-Path $factoryOrigin 'src/OperationMeasure.cs') @'
using System;
using System.Diagnostics;

namespace Acme.Measure;

public class OperationProfiler
{
public TimeSpan Elapsed { get; set; }
}

public sealed class OperationProfiler<TResult> : OperationProfiler
{
internal OperationProfiler()
{
}

public TResult Result { get; set; } = default!;
}

public static class OperationMeasure
{
public static OperationProfiler<TResult> WithFunc<TResult>(Func<TResult> callback)
{
    var stopwatch = Stopwatch.StartNew();
    var result = callback();
    stopwatch.Stop();
    return new OperationProfiler<TResult>()
    {
        Result = result,
        Elapsed = stopwatch.Elapsed
    };
}
}
'@
Write-Utf8File (Join-Path $factoryOrigin '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Measure.csproj'))

Write-Utf8File (Join-Path $factoryOrigin '.docfx/api/types/Acme.Measure.OperationProfiler.md') @'
---
uid: Acme.Measure.OperationProfiler
example: *content
---
```csharp
using Acme.Measure;

namespace Samples;

public static class ManualProfilerExample
{
public static int Measure()
{
    var profiler = new OperationProfiler<int>();
    profiler.Result = 42;
    return profiler.Result;
}
}
```
'@

$badFactoryOrigin = Invoke-Validator -Workspace $factoryOrigin -ExtraArgs @('--build-api-model', '--validate-samples')
Assert-Diagnostic -Report $badFactoryOrigin -Code 'SAMPLE_COMPILE_FAILED'

Write-Utf8File (Join-Path $factoryOrigin '.docfx/api/types/Acme.Measure.OperationProfiler.md') @'
---
uid: Acme.Measure.OperationProfiler
example: *content
---
Use `OperationMeasure` when callers need to time a callback and inspect the returned profiler.

```csharp
using System.Threading;
using Acme.Measure;

namespace Samples;

public static class OperationMeasureExample
{
public static int Measure()
{
    OperationProfiler<int> profiler = OperationMeasure.WithFunc(() =>
    {
        Thread.Sleep(10);
        return 42;
    });

    return profiler.Result;
}
}
```
'@

$goodFactoryOrigin = Invoke-Validator -Workspace $factoryOrigin -ExtraArgs @('--build-api-model', '--validate-samples')
Assert-NoDiagnostic -Report $goodFactoryOrigin -Code 'SAMPLE_COMPILE_FAILED'

Write-Host 'DocFX factory-origin example regression passed.'
} finally {
if (Test-Path $factoryOrigin) {
    Remove-Item -Path $factoryOrigin -Recurse -Force
}
}

# ----------------------------------------------------------------------
# Scenario: sample compile diagnostics should point at likely missing
# extension-method using directives instead of leaving only raw CS1061.
# ----------------------------------------------------------------------
$missingUsing = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-missing-using-' + [guid]::NewGuid().ToString('N'))
try {
Write-Utf8File (Join-Path $missingUsing 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
Write-Utf8File (Join-Path $missingUsing 'src/Acme.Linq.csproj') $projectCsproj
Write-Utf8File (Join-Path $missingUsing 'src/QueryRunner.cs') @'
namespace Acme.Linq;

public sealed class QueryRunner
{
    public int[] Values { get; } = new[] { 1, 2, 3 };
}
'@
Write-Utf8File (Join-Path $missingUsing '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Linq.csproj'))
Write-Utf8File (Join-Path $missingUsing '.docfx/api/types/Acme.Linq.QueryRunner.md') @'
---
uid: Acme.Linq.QueryRunner
example: *content
---
Use `QueryRunner` when callers need to transform the produced values before displaying them.

```csharp
namespace Samples;

using System;
using Acme.Linq;

public static class QueryRunnerExample
{
    public static void PrintValues()
    {
        var runner = new QueryRunner();
        var doubled = runner.Values.Select(value => value * 2);

        Console.WriteLine(string.Join(", ", doubled));
    }
}
```
'@

$missingUsingReport = Invoke-Validator -Workspace $missingUsing -ExtraArgs @('--build-api-model', '--validate-samples')
Assert-Diagnostic -Report $missingUsingReport -Code 'SAMPLE_COMPILE_FAILED'
Assert-DiagnosticMessageContains -Report $missingUsingReport -Code 'SAMPLE_COMPILE_FAILED' -Text 'missing `using System.Linq;`'

Write-Host 'DocFX missing-using compile diagnostic regression passed.'
} finally {
if (Test-Path $missingUsing) {
    Remove-Item -Path $missingUsing -Recurse -Force
}
}

    # ----------------------------------------------------------------------
    # Scenario: build-backed reflection discovery must also collapse C# 14
    # extension-block containers. Current compilers emit nested <G>$... and <M>$...
    # implementation types; neither is nameable from C#, so neither may become an
    # EXAMPLE_MISSING or EXAMPLE_TARGET_NOT_USED work item.
    # ----------------------------------------------------------------------
$reflectionExtensionBlocks = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-reflection-extension-blocks-' + [guid]::NewGuid().ToString('N'))
try {
    $arrow = "$([char]0x2B07)$([char]0xFE0F)"
    Write-Utf8File (Join-Path $reflectionExtensionBlocks 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $reflectionExtensionBlocks 'src/Acme.Core.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <LangVersion>preview</LangVersion>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File (Join-Path $reflectionExtensionBlocks 'src/Extensions.cs') @'
namespace Acme.Core;

public static class EndpointExtensions
{
    extension(string value)
    {
        public string NormalizeForBoundary() => value.Trim();
    }
}
'@
    Write-Utf8File (Join-Path $reflectionExtensionBlocks '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Core.csproj'))
    Write-Utf8File (Join-Path $reflectionExtensionBlocks '.docfx/api/namespaces/Acme.Core.md') @"
---
uid: Acme.Core
summary: *content
---
Use `EndpointExtensions` when text should be normalized at an ingress boundary before validation or comparison.

Start with `EndpointExtensions` when callers want one explicit `NormalizeForBoundary` call directly on the incoming string.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|`NormalizeForBoundary`|
"@
    Write-Utf8File (Join-Path $reflectionExtensionBlocks '.docfx/api/types/Acme.Core.EndpointExtensions.md') @'
---
uid: Acme.Core.EndpointExtensions
example: *content
---
```csharp
using Acme.Core;

namespace Samples;

public static class BoundaryInput
{
    public static string Normalize(string value) => value.NormalizeForBoundary();
}
```
'@

    $reflectionExtensionReport = Invoke-Validator -Workspace $reflectionExtensionBlocks -ExtraArgs @('--build-api-model')
    Assert-Warning -Report $reflectionExtensionReport -Code 'DOCFX_EXTENSION_BLOCK_UNSUPPORTED'
    Assert-NoDiagnostic -Report $reflectionExtensionReport -Code 'EXAMPLE_MISSING'
    Assert-NoDiagnostic -Report $reflectionExtensionReport -Code 'EXAMPLE_TARGET_NOT_USED'
    Assert-NoDiagnostic -Report $reflectionExtensionReport -Code 'EXTENSION_EXAMPLE_NOT_INVOKED'

    Write-Host 'DocFX reflection extension-block regression passed.'
} finally {
    $reflectionExtensionBlocksVariable = Get-Variable -Name reflectionExtensionBlocks -ErrorAction SilentlyContinue
    if ($reflectionExtensionBlocksVariable -and $reflectionExtensionBlocksVariable.Value -and (Test-Path -LiteralPath $reflectionExtensionBlocksVariable.Value)) {
        Remove-Item -LiteralPath $reflectionExtensionBlocksVariable.Value -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------
# Scenario: the conservative source scanner must detect public delegate types
# as required example targets, including generic delegates with variance
# modifiers. Without this, DocFX-authored type pages for those delegates
# are flagged as INTERIM_ARTIFACT_IN_WORKTREE.
# ----------------------------------------------------------------------
$delegateDiscovery = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-delegate-discovery-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $delegateDiscovery 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $delegateDiscovery 'src/Acme.Delegates.csproj') $projectCsproj
    Write-Utf8File (Join-Path $delegateDiscovery 'src/Delegates.cs') @'
namespace Acme.Delegates;

public delegate string PlainHandler(string input);

public delegate T GenericHandler<T>(T value);

public delegate TSuccess TesterFunc<TResult, out TSuccess>(out TResult result);

public sealed class Counter
{
    public int Value { get; set; }
}
'@
    Write-Utf8File (Join-Path $delegateDiscovery '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Delegates.csproj'))
    Initialize-GitRepo $delegateDiscovery
    Write-Utf8File (Join-Path $delegateDiscovery '.docfx/api/namespaces/Acme.Delegates.md') @'
---
uid: Acme.Delegates
---

Namespace overview.
'@

    $delegateReport = Invoke-Validator -Workspace $delegateDiscovery
    # All three delegates plus Counter should be required targets.
    if ([int]$delegateReport.summary.requiredExampleTargets -ne 4) {
        throw "Public delegate discovery under-reported targets: expected 4, got $($delegateReport.summary.requiredExampleTargets)."
    }
    Assert-Diagnostic -Report $delegateReport -Code 'EXAMPLE_MISSING'

    # Add type overwrite files for the plain delegate and Counter, then verify
    # the previously-clean type files are recognized as known deliverables and
    # do not trigger INTERIM_ARTIFACT_IN_WORKTREE.
    Write-Utf8File (Join-Path $delegateDiscovery '.docfx/api/types/Acme.Delegates.PlainHandler.md') @'
---
uid: Acme.Delegates.PlainHandler
example: *content
---
```csharp
using Acme.Delegates;

namespace Samples;

public static class PlainHandlerExample
{
    public static string Run() => ((PlainHandler)(input => input.ToUpperInvariant()))("hello");
}
```
'@
    Write-Utf8File (Join-Path $delegateDiscovery '.docfx/api/types/Acme.Delegates.Counter.md') @'
---
uid: Acme.Delegates.Counter
example: *content
---
```csharp
using Acme.Delegates;

namespace Samples;

public static class CounterExample
{
    public static int Next() => new Counter { Value = 42 }.Value;
}
```
'@

    $delegateReportAfter = Invoke-Validator -Workspace $delegateDiscovery
    Assert-NoDiagnostic -Report $delegateReportAfter -Code 'INTERIM_ARTIFACT_IN_WORKTREE'
    # Only the two generic delegates should still be missing.
    $stillMissing = @($delegateReportAfter.errors | Where-Object code -eq 'EXAMPLE_MISSING')
    if ($stillMissing.Count -ne 2) {
        throw "Expected 2 remaining EXAMPLE_MISSING (GenericHandler, TesterFunc); got $($stillMissing.Count)."
    }

    Write-Host 'DocFX public delegate discovery regression passed.'
} finally {
    if (Test-Path $delegateDiscovery) {
        Remove-Item $delegateDiscovery -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------
# Scenario: the conservative source scanner must only surface 'public static'
# extension methods as required targets. Private, protected, and internal
# 'static' helpers with 'this' parameters are implementation details, not
# part of the public API surface.
# ----------------------------------------------------------------------
$visibilityFilter = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-visibility-filter-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $visibilityFilter 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $visibilityFilter 'src/Acme.Visibility.csproj') $projectCsproj
    Write-Utf8File (Join-Path $visibilityFilter 'src/Visibility.cs') @'
namespace Acme.Visibility;

public static class TextExtensions
{
    public static string PublicNormalize(this string value) => value.Trim().ToUpperInvariant();

    private static string PrivateNormalize(this string value) => value.ToLowerInvariant();

    internal static string InternalNormalize(this string value) => value;
}
'@
    Write-Utf8File (Join-Path $visibilityFilter '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Visibility.csproj'))
    Initialize-GitRepo $visibilityFilter
    Write-Utf8File (Join-Path $visibilityFilter '.docfx/api/namespaces/Acme.Visibility.md') @'
---
uid: Acme.Visibility
---

Namespace overview.
'@

    $visibilityReport = Invoke-Validator -Workspace $visibilityFilter
    # Only TextExtensions (the public static container) plus PublicNormalize
    # (the single public extension method) should be required targets. The
    # private/internal 'static' helpers with 'this' parameters are not part
    # of the public API surface and must be invisible to the validator.
    if ([int]$visibilityReport.summary.extensionMethods -ne 1) {
        throw "Public extension method discovery: expected 1, got $($visibilityReport.summary.extensionMethods)."
    }
    $missingMessages = @($visibilityReport.errors | Where-Object code -eq 'EXAMPLE_MISSING' | ForEach-Object message)
    $missingJoined = ($missingMessages -join "`n")
    if ($missingJoined -notmatch 'PublicNormalize') {
        throw "Expected EXAMPLE_MISSING for public extension method 'PublicNormalize'. Got: $missingJoined"
    }
    if ($missingJoined -match 'PrivateNormalize') {
        throw "Private extension method 'PrivateNormalize' must not be a required target. Got: $missingJoined"
    }
    if ($missingJoined -match 'InternalNormalize') {
        throw "Internal extension method 'InternalNormalize' must not be a required target. Got: $missingJoined"
    }

    Write-Host 'DocFX extension visibility filter regression passed.'
} finally {
    if (Test-Path $visibilityFilter) {
        Remove-Item $visibilityFilter -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The validator returns a non-zero exit code for fixtures that intentionally contain
# diagnostics. Success here is determined by the assertions above not throwing, so reset
# the process exit code for callers (e.g. validate-skill-templates.ps1) that inspect it.
exit 0
