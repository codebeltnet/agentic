param(
    [string]$Ref
)

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Convert-ToRelativePath {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseFull = ([System.IO.Path]::GetFullPath($BasePath)).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($FullPath)

    if (-not $targetFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$FullPath' is not under '$BasePath'"
    }

    return $targetFull.Substring($baseFull.Length).TrimStart('\', '/')
}

function Get-RepoFileList {
    param(
        [string]$RepoRoot,
        [string]$RelativePath,
        [string]$GitRef
    )

    if ([string]::IsNullOrWhiteSpace($GitRef)) {
        $fullPath = Join-Path $RepoRoot $RelativePath
        if (-not (Test-Path $fullPath)) {
            throw "Missing path: $RelativePath"
        }

        return Get-ChildItem -Path $fullPath -Recurse -File -Force |
            ForEach-Object { Convert-ToRelativePath -BasePath $fullPath -FullPath $_.FullName } |
            Sort-Object
    }

    $normalizedPath = $RelativePath -replace '\\', '/'
    $output = git -C $RepoRoot ls-tree -r --name-only $GitRef -- $normalizedPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Missing path at ref '$GitRef': $RelativePath"
    }

    $prefix = $normalizedPath.TrimEnd('/') + '/'
    return @($output | Where-Object { $_ -like "$prefix*" } | ForEach-Object { $_.Substring($prefix.Length) } | Sort-Object)
}

function Get-FileText {
    param(
        [string]$RepoRoot,
        [string]$RelativePath,
        [string]$GitRef
    )

    if ([string]::IsNullOrWhiteSpace($GitRef)) {
        $fullPath = Join-Path $RepoRoot $RelativePath
        if (-not (Test-Path $fullPath)) {
            throw "Missing file: $RelativePath"
        }
        return [System.IO.File]::ReadAllText($fullPath, $utf8NoBom)
    }

    $showTarget = '{0}:{1}' -f $GitRef, ($RelativePath -replace '\\', '/')
    $output = git -C $RepoRoot show $showTarget 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Missing file at ref '$GitRef': $RelativePath"
    }
    return ($output -join [Environment]::NewLine)
}

function Assert-Contains {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Needle
    )

    if (-not $Content.Contains($Needle)) {
        throw "$Name must contain '$Needle'"
    }
}

function Assert-NotContains {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Needle
    )

    if ($Content.Contains($Needle)) {
        throw "$Name must not contain '$Needle'"
    }
}

function Assert-Match {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Pattern
    )

    if ($Content -notmatch $Pattern) {
        throw "$Name must match regex '$Pattern'"
    }
}

function Apply-Replacements {
    param(
        [string]$Content,
        [hashtable]$Map
    )

    $updated = $Content
    foreach ($key in $Map.Keys) {
        $updated = $updated.Replace($key, [string]$Map[$key])
    }
    return $updated
}

function Assert-NoUnexpectedPlaceholders {
    param(
        [string]$Name,
        [string]$Content,
        [string[]]$Allowed = @()
    )

    $tokens = [regex]::Matches($Content, '\{[A-Za-z0-9_]+\}') |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique

    $remaining = @($tokens | Where-Object { $Allowed -notcontains $_ })
    if ($remaining.Count -gt 0) {
        throw "$Name still has unresolved placeholders: $($remaining -join ', ')"
    }
}

function Add-ValidationResult {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        $Results.Add([pscustomobject]@{
            Name = $Name
            Status = 'PASS'
            Details = ''
        })
    } catch {
        $Results.Add([pscustomobject]@{
            Name = $Name
            Status = 'FAIL'
            Details = $_.Exception.Message
        })
    }
}

function Get-AppPlaceholderMap {
    param(
        [string]$AppType,
        [string]$TargetFramework = 'net10.0'
    )

    $targetMajor = if ($TargetFramework -match '^net(\d+)\.0$') { [int]$Matches[1] } else { throw "Unsupported TargetFramework for test map: $TargetFramework" }
    $ubuntuTag = "codebeltnet/ubuntu-testrunner:$targetMajor"
    $aspNetAlignedVersion = switch ($targetMajor) {
        9 { '9.0.14' }
        10 { '10.0.5' }
        default { throw "No test fixture version configured for TFM major $targetMajor" }
    }

    return @{
        '{SOLUTION_NAME}' = 'DemoApp'
        '{ROOT_NAMESPACE}' = 'Acme'
        '{REPO_SLUG}' = 'demoapp'
        '{TARGET_FRAMEWORK}' = $TargetFramework
        '{AppType}' = $AppType
        '{UBUNTU_TESTRUNNER_TAG}' = $ubuntuTag
        '{CODEBELT_EXTENSIONS_XUNIT_APP_VERSION}' = '11.0.7'
        '{MICROSOFT_NET_TEST_SDK_VERSION}' = '18.3.0'
        '{MINVER_VERSION}' = '7.0.0'
        '{COVERLET_COLLECTOR_VERSION}' = '8.0.0'
        '{COVERLET_MSBUILD_VERSION}' = '8.0.0'
        '{XUNIT_V3_VERSION}' = '3.2.2'
        '{XUNIT_V3_RUNNER_CONSOLE_VERSION}' = '3.2.2'
        '{XUNIT_RUNNER_VISUALSTUDIO_VERSION}' = '3.1.5'
        '{CODEBELT_BOOTSTRAPPER_CONSOLE_VERSION}' = '5.0.5'
        '{CODEBELT_BOOTSTRAPPER_WEB_VERSION}' = '5.0.5'
        '{CODEBELT_BOOTSTRAPPER_WORKER_VERSION}' = '5.0.5'
        '{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}' = $aspNetAlignedVersion
        '{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}' = $aspNetAlignedVersion
        '{MICROSOFT_EXTENSIONS_HOSTING_VERSION}' = '10.0.5'
    }
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-RenderedFileFromTemplate {
    param(
        [string]$RepoRoot,
        [string]$RelativePath,
        [string]$DestinationPath,
        [hashtable]$Map,
        [string]$GitRef
    )

    $content = Get-FileText -RepoRoot $RepoRoot -RelativePath $RelativePath -GitRef $GitRef
    $rendered = Apply-Replacements -Content $content -Map $Map
    Write-Utf8File -Path $DestinationPath -Content $rendered
}

function Invoke-DotNetBuildForValidation {
    param(
        [string]$ProjectPath
    )

    $output = & dotnet build $ProjectPath '--nologo' 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join [Environment]::NewLine)
    }
}

$repoRoot = Get-RepoRoot
$results = [System.Collections.Generic.List[object]]::new()

Add-ValidationResult -Results $results -Name 'All repo-managed skills include valid per-skill evals/evals.json' -Action {
    $skillRoot = Join-Path $repoRoot 'skills'
    $skillDirectories = Get-ChildItem -Path $skillRoot -Directory | Sort-Object Name

    foreach ($skillDir in $skillDirectories) {
        $relativeEvalPath = ('skills/{0}/evals/evals.json' -f $skillDir.Name)
        $evalText = Get-FileText -RepoRoot $repoRoot -RelativePath $relativeEvalPath -GitRef $Ref
        $evalData = $evalText | ConvertFrom-Json

        if ($evalData.skill_name -ne $skillDir.Name) {
            throw "$relativeEvalPath has skill_name '$($evalData.skill_name)' but expected '$($skillDir.Name)'"
        }

        if (-not $evalData.evals) {
            throw "$relativeEvalPath must define at least one eval"
        }

        if ($evalData.evals.Count -lt 1) {
            throw "$relativeEvalPath must contain at least one eval entry"
        }

        foreach ($eval in $evalData.evals) {
            if (-not $eval.id -and $eval.id -ne 0) {
                throw "$relativeEvalPath contains an eval without id"
            }
            if ([string]::IsNullOrWhiteSpace([string]$eval.prompt)) {
                throw "$relativeEvalPath contains an eval without prompt"
            }
            if ([string]::IsNullOrWhiteSpace([string]$eval.expected_output)) {
                throw "$relativeEvalPath contains an eval without expected_output"
            }
        }
    }
}

Add-ValidationResult -Results $results -Name 'All repo-managed skills keep YAML frontmatter descriptions within 1024 characters' -Action {
    $skillRoot = Join-Path $repoRoot 'skills'
    $skillDirectories = Get-ChildItem -Path $skillRoot -Directory | Sort-Object Name

    foreach ($skillDir in $skillDirectories) {
        $skillRelativePath = ('skills/{0}/SKILL.md' -f $skillDir.Name)
        $skill = Get-FileText -RepoRoot $repoRoot -RelativePath $skillRelativePath -GitRef $Ref

        if ($skill -notmatch '(?ms)^---\r?\n(?<frontmatter>.*?)\r?\n---') {
            throw "$skillRelativePath must include YAML frontmatter delimited by ---"
        }

        $frontmatter = $matches['frontmatter']
        if ($frontmatter -notmatch '(?ms)^description:\s*>\s*\r?\n(?<description>(?:[ \t].*\r?\n?)*)') {
            throw "$skillRelativePath must include a folded YAML description block"
        }

        $descriptionLines = @(
            $matches['description'] -split '\r?\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
        )

        $description = [string]::Join(' ', $descriptionLines)
        if ($description.Length -gt 1024) {
            throw "$skillRelativePath frontmatter description must be 1024 characters or fewer; found $($description.Length)"
        }
    }
}

Add-ValidationResult -Results $results -Name 'App skill collects target framework and conditional web_variant' -Action {
    $forms = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/FORMS.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle '### target_framework'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'If native structured input widgets are unavailable, fall back to the deterministic plain-text interaction format described in the presentation rules below.'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'If the user leaves this field blank after seeing that default, accept `{solution_name}` and continue instead of asking again.'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Newest generally supported .NET LTS channel'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'every generally supported non-preview .NET LTS and STS channel'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle "Prefer the host's native structured input controls for every field when they are available."
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Start with `Field: <field-name>`'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'If the user explicitly says `console` or `worker`, preselect that host type and skip asking `app_host_types` again unless the user clearly requested multiple host types.'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'In plain-text fallback mode, do not add a conversational preamble before a field. Start immediately with `Field: <field-name>`.'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'compute one quick-pick suggestion per generally supported non-preview `.NET` channel'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Include every other supported LTS and STS channel as additional selectable choices'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'If a field with a `default` or `computed_default` is shown to the user and they leave it blank, treat that as accepting the presented recommended value.'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle '### web_variant'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle '**show_when:** `app_host_types` includes `Web`'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Web API (Recommended)'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Empty Web'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Web App / Razor'
}

Add-ValidationResult -Results $results -Name 'App skill documents web-family AppType mapping and package version resolution' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/SKILL.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '## Non-Negotiable Output Contract'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'The scaffold is incomplete unless it produces all required artifacts for the selected host types.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'the solution file named `{SOLUTION_NAME}.slnx` with the original user-facing casing preserved'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'If you cannot generate any required artifact from the documented templates and rules, halt and report the mismatch instead of improvising'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Treat the scaffold as a fidelity copy of the documented template set, not a "best effort" approximation.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '## Step 3: Resolve Dynamic Dependency Versions'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'scripts/resolve-package-versions.ps1'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'current working directory'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'If the host does not render native form controls, follow the deterministic plain-text fallback defined in `FORMS.md` instead of improvising your own questioning style.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Consistency matters more than creativity during parameter collection.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'If the user already said `console` or `worker`, preselect that host type and continue with the next unresolved field instead of re-asking `app_host_types`.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'do not add extra conversational lead-ins between fields.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'treat a blank response as accepting that shown value'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Web` as the host family'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Do **not** substitute vanilla .NET hosting code as a workaround.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'resolve the latest stable version whose **major** matches the selected `{TARGET_FRAMEWORK}` major'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '`Directory.Packages.props` is the authoritative source of NuGet package versions for the generated app scaffold.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Do **not** inline `Version=` attributes into `.csproj` files or `Directory.Build.props` as a workaround for restore or build issues.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'If the lookup step fails, halt and report it instead of guessing.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '`TargetFramework` belongs in the generated root `Directory.Build.props`, not in the generated app or test `.csproj` files.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '`testenvironments.json` is a required shared scaffold asset. Do **not** silently omit it.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Do not selectively copy only "key" shared files.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'expect MinVer to report a placeholder pre-release version such as `0.0.0-alpha.0` until the user initializes git and adds a version tag'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'The solution file must be named `{SOLUTION_NAME}.slnx`, not `{REPO_SLUG}.slnx` and not any lowercased variant.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'The `.slnx` file is required even for single-host scaffolds.'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Every file from `assets/shared/` exists in the generated repo with the same relative path'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'No generated app or test `.csproj` file introduces `<TargetFramework>`'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '{AppType} = Web'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '{AppType} = Api'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '{AppType} = Mvc'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '{AppType} = WebApp'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Worker.cs'
}

Add-ValidationResult -Results $results -Name 'App package template uses specific version placeholders' -Action {
    $packages = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/Directory.Packages.props' -GitRef $Ref
    Assert-NotContains -Name 'app Directory.Packages.props' -Content $packages -Needle '{LATEST}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle 'MinVer'
    Assert-NotContains -Name 'app Directory.Packages.props' -Content $packages -Needle 'BenchmarkDotNet'
    Assert-NotContains -Name 'app Directory.Packages.props' -Content $packages -Needle 'Codebelt.SharedKernel'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{CODEBELT_BOOTSTRAPPER_WEB_VERSION}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{MICROSOFT_EXTENSIONS_HOSTING_VERSION}'
}

Add-ValidationResult -Results $results -Name 'App shared Directory.Packages.props matches actual app asset PackageReference set' -Action {
    $packageTemplate = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/Directory.Packages.props' -GitRef $Ref
    $templatePackages = [regex]::Matches($packageTemplate, '<PackageVersion Include="([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique

    $assetPaths = @(
        'skills/dotnet-new-app-slnx/assets/app/Directory.Build.props',
        'skills/dotnet-new-app-slnx/assets/app/console.csproj',
        'skills/dotnet-new-app-slnx/assets/app/test.csproj',
        'skills/dotnet-new-app-slnx/assets/app/web.csproj',
        'skills/dotnet-new-app-slnx/assets/app/web-api.csproj',
        'skills/dotnet-new-app-slnx/assets/app/web-mvc.csproj',
        'skills/dotnet-new-app-slnx/assets/app/webapp.csproj',
        'skills/dotnet-new-app-slnx/assets/app/worker.csproj'
    )

    $referencedPackages = foreach ($path in $assetPaths) {
        $content = Get-FileText -RepoRoot $repoRoot -RelativePath $path -GitRef $Ref
        [regex]::Matches($content, '<PackageReference Include="([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }
    }
    $referencedPackages = @($referencedPackages | Sort-Object -Unique)

    $extraPackages = @($templatePackages | Where-Object { $referencedPackages -notcontains $_ })
    $missingPackages = @($referencedPackages | Where-Object { $templatePackages -notcontains $_ })

    if ($extraPackages.Count -gt 0) {
        throw "app Directory.Packages.props includes unused packages: $($extraPackages -join ', ')"
    }

    if ($missingPackages.Count -gt 0) {
        throw "app Directory.Packages.props is missing referenced packages: $($missingPackages -join ', ')"
    }
}

Add-ValidationResult -Results $results -Name 'App project templates keep TargetFramework centralized in Directory.Build.props' -Action {
    $projectTemplates = @(
        'skills/dotnet-new-app-slnx/assets/app/console.csproj',
        'skills/dotnet-new-app-slnx/assets/app/web.csproj',
        'skills/dotnet-new-app-slnx/assets/app/web-api.csproj',
        'skills/dotnet-new-app-slnx/assets/app/web-mvc.csproj',
        'skills/dotnet-new-app-slnx/assets/app/webapp.csproj',
        'skills/dotnet-new-app-slnx/assets/app/worker.csproj',
        'skills/dotnet-new-app-slnx/assets/app/test.csproj'
    )

    foreach ($path in $projectTemplates) {
        $content = Get-FileText -RepoRoot $repoRoot -RelativePath $path -GitRef $Ref
        Assert-NotContains -Name $path -Content $content -Needle '<TargetFramework>'
    }
}

Add-ValidationResult -Results $results -Name 'App reference guide uses ROOT_NAMESPACE contract and web-family variant mapping' -Action {
    $guide = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/references/app.md' -GitRef $Ref
    Assert-NotContains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '{NS}'
    Assert-NotContains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '{REPO_SLUG}/'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '{ROOT_NAMESPACE}.{AppType}'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'current working directory'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'do not create an extra solution-named wrapper folder'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '{SOLUTION_NAME}.slnx'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Do **not** derive the `.slnx` filename from `{REPO_SLUG}` or any lowercased variant.'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Treat the files shown in this tree as required output, not aspirational examples.'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '## Required Shared Asset Inventory'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Do not cherry-pick only the files that feel essential.'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '.github/copilot-instructions.md'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Even when there is only one host type, still generate the `.slnx` file'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Directory.Packages.props` is the authoritative version source for app scaffolds.'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Do **not** duplicate `<TargetFramework>` inside the generated app or test `.csproj` files as a workaround.'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'scripts/resolve-package-versions.ps1'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`testenvironments.json` is required output for the scaffold.'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'MinVer may report a bootstrap pre-release such as `0.0.0-alpha.0`'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Where `{AppType}` maps to the emitted project suffix:'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`web-api` (`Web API`)'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`web-mvc` (`MVC`)'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`webapp` (`Web App / Razor`)'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'a `net9.0` app should resolve these packages to the latest stable `9.x` version, not `10.x`'
}

Add-ValidationResult -Results $results -Name 'App skill ships deterministic package version resolver script' -Action {
    $script = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/scripts/resolve-package-versions.ps1' -GitRef $Ref
    Assert-Contains -Name 'resolve-package-versions.ps1' -Content $script -Needle 'https://api.nuget.org/v3/index.json'
    Assert-Contains -Name 'resolve-package-versions.ps1' -Content $script -Needle 'PackageBaseAddress/3.0.0'
    Assert-Contains -Name 'resolve-package-versions.ps1' -Content $script -Needle 'TargetFramework'
    Assert-Contains -Name 'resolve-package-versions.ps1' -Content $script -Needle 'if ([string]::IsNullOrWhiteSpace($TemplatePath))'
    Assert-Contains -Name 'resolve-package-versions.ps1' -Content $script -Needle "Directory.Packages.props'"
    Assert-Contains -Name 'resolve-package-versions.ps1' -Content $script -Needle 'ConvertTo-Json'
}

Add-ValidationResult -Results $results -Name 'App web and worker scaffold files exist and README points to real project path' -Action {
    $worker = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/worker/Worker.cs' -GitRef $Ref
    $web = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web/Program.minimal.cs' -GitRef $Ref
    $webApi = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web-api/Program.minimal.cs' -GitRef $Ref
    $mvcController = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Controllers/HomeController.cs' -GitRef $Ref
    $mvcView = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/Home/Index.cshtml' -GitRef $Ref
    $webAppPage = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Index.cshtml' -GitRef $Ref
    $readme = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/README.md' -GitRef $Ref
    Assert-Contains -Name 'worker/Worker.cs' -Content $worker -Needle 'BackgroundService'
    Assert-Contains -Name 'worker/Worker.cs' -Content $worker -Needle 'logger.LogInformation("Worker running at: {Time}"'
    Assert-Contains -Name 'web/Program.minimal.cs' -Content $web -Needle 'Hello from {ROOT_NAMESPACE}.{AppType}.'
    Assert-Contains -Name 'web-api/Program.minimal.cs' -Content $webApi -Needle 'builder.Services.AddEndpointsApiExplorer();'
    Assert-Contains -Name 'web-mvc/HomeController.cs' -Content $mvcController -Needle 'IActionResult Index()'
    Assert-Contains -Name 'web-mvc/Views/Home/Index.cshtml' -Content $mvcView -Needle 'starter MVC page'
    Assert-Contains -Name 'webapp/Pages/Index.cshtml' -Content $webAppPage -Needle 'starter Razor page'
    Assert-Contains -Name 'app shared README' -Content $readme -Needle 'src/{ROOT_NAMESPACE}.{AppType}/{ROOT_NAMESPACE}.{AppType}.csproj'
    Assert-NotContains -Name 'app shared README' -Content $readme -Needle 'src/{ROOT_NAMESPACE}.{SOLUTION_NAME}.App'
}

Add-ValidationResult -Results $results -Name 'App templates import required bootstrapper and hosting namespaces explicitly' -Action {
    $consoleMinimal = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/console/Program.minimal.cs' -GitRef $Ref
    $consoleStartupProgram = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/console/Program.startup.cs' -GitRef $Ref
    $consoleStartup = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/console/Startup.cs' -GitRef $Ref
    $workerMinimal = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/worker/Program.minimal.cs' -GitRef $Ref
    $workerClass = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/worker/Worker.cs' -GitRef $Ref
    $webMinimal = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web/Program.minimal.cs' -GitRef $Ref
    $webStartupProgram = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web/Program.startup.cs' -GitRef $Ref
    $webStartup = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web/Startup.cs' -GitRef $Ref
    Assert-Contains -Name 'console/Program.minimal.cs' -Content $consoleMinimal -Needle 'using Codebelt.Bootstrapper.Console;'
    Assert-Contains -Name 'console/Program.minimal.cs' -Content $consoleMinimal -Needle 'using Microsoft.Extensions.Hosting;'
    Assert-Contains -Name 'console/Program.startup.cs' -Content $consoleStartupProgram -Needle 'using Codebelt.Bootstrapper.Console;'
    Assert-Contains -Name 'console/Startup.cs' -Content $consoleStartup -Needle 'using Codebelt.Bootstrapper.Console;'
    Assert-Contains -Name 'worker/Program.minimal.cs' -Content $workerMinimal -Needle 'using Codebelt.Bootstrapper.Worker;'
    Assert-Contains -Name 'worker/Program.minimal.cs' -Content $workerMinimal -Needle 'using Microsoft.Extensions.DependencyInjection;'
    Assert-Contains -Name 'worker/Worker.cs' -Content $workerClass -Needle 'using Microsoft.Extensions.Hosting;'
    Assert-Contains -Name 'worker/Worker.cs' -Content $workerClass -Needle 'using Microsoft.Extensions.Logging;'
    Assert-Contains -Name 'web/Program.minimal.cs' -Content $webMinimal -Needle 'using Codebelt.Bootstrapper.Web;'
    Assert-Contains -Name 'web/Program.startup.cs' -Content $webStartupProgram -Needle 'using Codebelt.Bootstrapper.Web;'
    Assert-Contains -Name 'web/Startup.cs' -Content $webStartup -Needle 'using Codebelt.Bootstrapper.Web;'
}

Add-ValidationResult -Results $results -Name 'App shared assets keep MinVer versioning wired end-to-end' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/SKILL.md' -GitRef $Ref
    $buildProps = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/Directory.Build.props' -GitRef $Ref
    $agents = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/AGENTS.md' -GitRef $Ref
    $targets = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/Directory.Build.targets' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'MinVer'
    Assert-Contains -Name 'app Directory.Build.props' -Content $buildProps -Needle '<PackageReference Include="MinVer" PrivateAssets="all" />'
    Assert-Contains -Name 'app shared AGENTS.md' -Content $agents -Needle 'MinVer for semantic versioning from Git tags'
    Assert-Contains -Name 'app shared Directory.Build.targets' -Content $targets -Needle 'AfterTargets="MinVer"'
    Assert-Contains -Name 'app shared Directory.Build.targets' -Content $targets -Needle '$(MinVerMajor).$(MinVerMinor).$(MinVerPatch)'
}

Add-ValidationResult -Results $results -Name 'Web variant package references stay scoped to the correct variant' -Action {
    $web = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web.csproj' -GitRef $Ref
    $webApi = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web-api.csproj' -GitRef $Ref
    $mvc = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/web-mvc.csproj' -GitRef $Ref
    $webApp = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/webapp.csproj' -GitRef $Ref
    Assert-NotContains -Name 'web.csproj' -Content $web -Needle 'Microsoft.AspNetCore.OpenApi'
    Assert-NotContains -Name 'web.csproj' -Content $web -Needle 'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'
    Assert-Contains -Name 'web-api.csproj' -Content $webApi -Needle 'Microsoft.AspNetCore.OpenApi'
    Assert-NotContains -Name 'web-api.csproj' -Content $webApi -Needle 'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'
    Assert-Contains -Name 'web-mvc.csproj' -Content $mvc -Needle 'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'
    Assert-Contains -Name 'webapp.csproj' -Content $webApp -Needle 'Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation'
}

Add-ValidationResult -Results $results -Name 'App dependabot and test environment templates are root-aware and dynamic' -Action {
    $dependabot = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/.github/dependabot.yml' -GitRef $Ref
    $testEnvironments = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/testenvironments.json' -GitRef $Ref
    Assert-Contains -Name 'app dependabot' -Content $dependabot -Needle 'directory: "/"'
    Assert-NotContains -Name 'app dependabot' -Content $dependabot -Needle 'directory: "/src"'
    Assert-NotContains -Name 'app dependabot' -Content $dependabot -Needle 'directory: "/test"'
    Assert-Contains -Name 'app testenvironments' -Content $testEnvironments -Needle '{UBUNTU_TESTRUNNER_TAG}'
    Assert-NotContains -Name 'app testenvironments' -Content $testEnvironments -Needle 'net8.0.418-9.0.311-10.0.103'
}

Add-ValidationResult -Results $results -Name 'Shared .bot assets are tracked and not ignored away' -Action {
    $appIgnore = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/.gitignore' -GitRef $Ref
    $appBot = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared/.bot/README.md' -GitRef $Ref
    $libIgnore = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/shared/.gitignore' -GitRef $Ref
    $libBot = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/shared/.bot/README.md' -GitRef $Ref
    Assert-Contains -Name 'app shared .gitignore' -Content $appIgnore -Needle '!.bot/README.md'
    Assert-Contains -Name 'lib shared .gitignore' -Content $libIgnore -Needle '!.bot/README.md'
    Assert-Contains -Name 'app .bot README' -Content $appBot -Needle '# .bot Workspace'
    Assert-Contains -Name 'lib .bot README' -Content $libBot -Needle '# .bot Workspace'
}

Add-ValidationResult -Results $results -Name 'Library skill documents PROJECT_NAME and DOCFX target framework' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/SKILL.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'current working directory'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle '{PROJECT_NAME}'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle '{DOCFX_TARGET_FRAMEWORK}'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'If the host does not render native form controls, follow the deterministic plain-text fallback defined in `FORMS.md` instead of improvising your own questioning style.'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'Consistency matters more than creativity during parameter collection.'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'treat a blank response as accepting that shown value'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'surface every other generally supported non-preview LTS and STS channel'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'Additional single-target choices: every other supported LTS or STS channel'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'Highest selected generally supported non-preview TFM used for DocFX metadata generation'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'Highest selected generally supported non-preview executable TFM from `target_frameworks`'
}

Add-ValidationResult -Results $results -Name 'Library forms offer active LTS, active STS, and expanded target framework quick-picks' -Action {
    $forms = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/FORMS.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle '### target_frameworks'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'If native structured input widgets are unavailable, fall back to the deterministic plain-text interaction format described in the presentation rules below.'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'If the user leaves this field blank after seeing that default, accept `{solution_name}` and continue instead of asking again.'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'every other generally supported non-preview .NET LTS and STS channel'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle "Prefer the host's native structured input controls for every field when they are available."
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'Start with `Field: <field-name>`'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'compute quick-pick suggestions'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'Include one additional single-target quick-pick for every other supported LTS or STS channel'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'If a field with a `default` or `computed_default` is shown to the user and they leave it blank, treat that as accepting the presented recommended value.'
    Assert-Contains -Name 'dotnet-new-lib-slnx/FORMS.md' -Content $forms -Needle 'Expanded scope: all generally supported `.NET` channels'
}

Add-ValidationResult -Results $results -Name 'Library reference guide uses current-folder scaffolding contract' -Action {
    $guide = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/references/library.md' -GitRef $Ref
    Assert-NotContains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle '{REPO_SLUG}/'
    Assert-Contains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle 'current working directory'
    Assert-Contains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle 'do not create an extra solution-named wrapper folder'
    Assert-Contains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle 'src/{PROJECT_NAME}/{PROJECT_NAME}.csproj'
    Assert-Contains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle 'offer every other generally supported non-preview .NET LTS and STS channel'
    Assert-Contains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle 'highest selected generally supported non-preview executable TFM'
}

Add-ValidationResult -Results $results -Name 'Library templates use PROJECT_NAME and COMPANY_OR_PERSON correctly' -Action {
    $testProject = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/test.csproj' -GitRef $Ref
    $benchmarkProject = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/benchmark.csproj' -GitRef $Ref
    $nugetReadme = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/nuget-readme.md' -GitRef $Ref
    $sharedReadme = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/shared/README.md' -GitRef $Ref
    $agents = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/shared/AGENTS.md' -GitRef $Ref
    $docfx = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/.docfx/docfx.json' -GitRef $Ref
    $toc = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/.docfx/toc.yml' -GitRef $Ref
    Assert-Contains -Name 'library test.csproj' -Content $testProject -Needle '..\..\src\{PROJECT_NAME}\{PROJECT_NAME}.csproj'
    Assert-Contains -Name 'library benchmark.csproj' -Content $benchmarkProject -Needle '..\..\src\{PROJECT_NAME}\{PROJECT_NAME}.csproj'
    Assert-Contains -Name 'library nuget-readme.md' -Content $nugetReadme -Needle 'dotnet add package {PROJECT_NAME}'
    Assert-Contains -Name 'library shared README' -Content $sharedReadme -Needle 'dotnet add package {PROJECT_NAME}'
    Assert-Contains -Name 'library shared AGENTS.md' -Content $agents -Needle '{PROJECT_NAME}.Tests'
    Assert-Contains -Name 'library docfx.json' -Content $docfx -Needle '{PROJECT_NAME}/**.csproj'
    Assert-Contains -Name 'library docfx.json' -Content $docfx -Needle '{DOCFX_TARGET_FRAMEWORK}'
    Assert-Contains -Name 'library docfx.json' -Content $docfx -Needle '{COMPANY_OR_PERSON}'
    Assert-NotContains -Name 'library docfx.json' -Content $docfx -Needle '{COMPANY}'
    Assert-Contains -Name 'library toc.yml' -Content $toc -Needle 'api/{PROJECT_NAME}.html'
}

Add-ValidationResult -Results $results -Name 'Benchmark runner wildcard is preserved and benchmark program is file-scoped' -Action {
    $runnerProject = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/benchmark-runner.csproj' -GitRef $Ref
    $program = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/assets/library/benchmark-program.cs' -GitRef $Ref
    Assert-Contains -Name 'benchmark-runner.csproj' -Content $runnerProject -Needle '..\..\tuning\**\*.csproj'
    Assert-Match -Name 'benchmark-program.cs' -Content $program -Pattern 'namespace\s+\{BENCHMARK_RUNNER_NAMESPACE\};'
}

Add-ValidationResult -Results $results -Name 'Strong-name skill matches FORMS summary flow and 1024-bit default' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-strong-name-signing/SKILL.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'compute the defaults silently, and present a single summary for confirmation'
    Assert-Contains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'default: 1024'
    Assert-NotContains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'default: 4096'
}

Add-ValidationResult -Results $results -Name 'Git visual commits skill enforces identity lock and umbrella commit rejection' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/SKILL.md' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/evals/evals.json' -GitRef $Ref
    $commitLanguage = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/references/commit-language.md' -GitRef $Ref

    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'automatic trigger for this skill, not as a casual hint.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Identity Lock'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Never silently downgrade a requested `git bot commit` to `git commit`.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If the required `git bot` alias is unavailable, halt and report that exact blocker instead of falling back to human identity.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '`yolo` / `auto` skips user confirmation only.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'After every commit, run:'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'git log -1 --format="%an <%ae>"'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'git log -1 --format=%B'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If the body contains literal escape sequences such as `\n` instead of real line breaks'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Do **not** hard-wrap commit bodies at 72 characters; keep short bodies as normal prose'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Umbrella Commit Rejection'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'skill instructions (`SKILL.md`, `FORMS.md`, `references/`, `evals/`)'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Read `references/commit-language.md` before choosing a prefix or emoji.'
    Assert-NotContains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Allowed Prefixes'
    Assert-NotContains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Emoji Selection'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Even in auto-approval mode, surface the commit buckets explicitly before committing.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Do not pass literal `\n` escape sequences and assume the shell will rewrite them.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Prefer grammatical sentence and paragraph breaks over column-based hard wrapping.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Then always run `git log -1 --format="%an <%ae>"` and verify that the author matches the requested identity mode before reporting success.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**New repo capabilities**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'introducing a new repo-managed skill, workflow, or top-level capability'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**Existing skill refactors**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'restructuring or extracting shared rules from an already existing skill'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'do not collapse "new skill introduced" and "existing skill refactored" into one commit'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**New repo-managed skill**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'a newly introduced `skills/<name>/` folder and its local `evals/` or `references/`'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If a commit both introduces a brand-new skill and refactors an existing skill to support it, prefer separate commits.'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle '### Allowed Prefixes'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle '### Emoji Selection'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle 'Gitmoji First, Fallback Second'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle '#### Fallback: Extended Emoji Reference'

    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not let yolo collapse multiple semantic intents into one umbrella commit'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Verifies the commit author after commit and confirms it matches bot identity'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Verifies the stored commit body does not contain literal \\n escape sequences'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not hard-wrap a short commit body mid-sentence just to satisfy a column limit'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'stops with a clear alias-missing error instead of silently falling back to human identity'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Treats a newly introduced skill folder as a separate repo capability intent'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Separates new skill introduction from existing skill refactor work'
}

Add-ValidationResult -Results $results -Name 'Git visual squash summary skill stays self-contained and shares commit language rules' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-squash-summary/SKILL.md' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-squash-summary/evals/evals.json' -GitRef $Ref
    $commitLanguage = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-squash-summary/references/commit-language.md' -GitRef $Ref
    $commitLanguageCommits = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/references/commit-language.md' -GitRef $Ref

    if ($commitLanguage -cne $commitLanguageCommits) {
        throw 'git-visual commit-language references must stay byte-for-byte identical'
    }

    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'This skill turns a stack of commits into a curated grouped summary'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'This skill is non-mutating:'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Retain only distinct high-signal change groups.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Read `references/commit-language.md` before choosing any emoji or prefix.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Favor readable GitHub and terminal output over cleverness.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Do not treat the result as a changelog entry or a dump of commit subjects.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Return grouped lines only, never a title or body.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Keep every output line at or below 72 characters.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Do not invent unsupported changes.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Do not append weak glue like "with", "plus", or "and" just to force'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Fits naturally beneath a PR title or in compact GitHub and terminal views.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Changelog-like wording or release-note phrasing.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Output the finished grouped summary lines and stop.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle '`git bot commit`, `git add`, or any other mutating command.'
    Assert-NotContains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle '<wrapped body lines>'
    Assert-NotContains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'The body is usually 1-4 wrapped lines'
    Assert-Contains -Name 'git-visual-squash-summary/references/commit-language.md' -Content $commitLanguage -Needle '### Allowed Prefixes'
    Assert-Contains -Name 'git-visual-squash-summary/references/commit-language.md' -Content $commitLanguage -Needle '### Emoji Selection'
    Assert-Contains -Name 'git-visual-squash-summary/references/commit-language.md' -Content $commitLanguage -Needle 'Gitmoji First, Fallback Second'

    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Does not run mutating git commands'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Retains only distinct high-signal change groups'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Reads like a curated human-written condensed history rather than a dump of commit subjects'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Favors readable GitHub and terminal output'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Returns grouped lines only and never adds a title or body'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Keeps every output line at or below 72 characters'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Does not treat the result as a changelog entry or commit-subject dump'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Highlights distinct meaningful efforts instead of forcing one dominant umbrella theme'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Does not invent unsupported changes'
}

Add-ValidationResult -Results $results -Name 'Git keep a changelog skill updates CHANGELOG.md from git history' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/SKILL.md' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/evals/evals.json' -GitRef $Ref

    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Create or update `CHANGELOG.md` directly, then stop for user review.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'If `CHANGELOG.md` does not exist, create a compliant one before'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Read full commit subjects and bodies before writing the changelog.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'If the current branch starts with a version hint such as `v0.3.0/`,'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Otherwise, target `## [Unreleased]`.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Always write a release highlight immediately below the target heading.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'The release highlight must explicitly classify the release as `major`,'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Use the standard Keep a Changelog section order:'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Preserve natural line breaks and readable prose. Do not apply any fixed'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'End each bullet with `,` and end the last bullet in each section with'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Do not dump commit subjects verbatim into the changelog.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'If `CHANGELOG.md` is missing, create it with the standard title,'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Update compare links at the bottom when adding a concrete version:'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Do not commit, tag, push, or create a release unless the user asks.'

    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Updates CHANGELOG.md directly instead of only drafting notes in chat'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Reads full commit subjects and bodies before writing the release entry'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Treats a leading branch version such as v0.3.0/ as a release hint'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Uses full commit bodies rather than relying on subject lines alone'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Preserves natural prose wrapping instead of forcing any fixed column width'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Ends bullets with commas and ends the final bullet in each section with a period'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Creates CHANGELOG.md when it does not already exist'
}

Add-ValidationResult -Results $results -Name 'Rendered app worker template leaves no unexpected placeholders' -Action {
    $files = @(
        'skills/dotnet-new-app-slnx/assets/shared/Directory.Packages.props',
        'skills/dotnet-new-app-slnx/assets/shared/testenvironments.json',
        'skills/dotnet-new-app-slnx/assets/shared/README.md',
        'skills/dotnet-new-app-slnx/assets/app/worker/Program.minimal.cs',
        'skills/dotnet-new-app-slnx/assets/app/worker/Worker.cs',
        'skills/dotnet-new-app-slnx/assets/app/test.csproj'
    )
    $map = Get-AppPlaceholderMap -AppType 'Worker'

    foreach ($file in $files) {
        $rendered = Apply-Replacements -Content (Get-FileText -RepoRoot $repoRoot -RelativePath $file -GitRef $Ref) -Map $map
        $allowed = @()
        if ($file.EndsWith('Worker.cs')) {
            $allowed = @('{Time}')
        }
        Assert-NoUnexpectedPlaceholders -Name $file -Content $rendered -Allowed $allowed
    }
}

Add-ValidationResult -Results $results -Name 'Rendered app web-family templates leave no unexpected placeholders and keep variant-specific assets' -Action {
    $variants = @(
        [pscustomobject]@{
            Name = 'Empty Web'
            AppType = 'Web'
            Files = @(
                'skills/dotnet-new-app-slnx/assets/app/web.csproj',
                'skills/dotnet-new-app-slnx/assets/app/web/Program.minimal.cs',
                'skills/dotnet-new-app-slnx/assets/app/web/Program.startup.cs',
                'skills/dotnet-new-app-slnx/assets/app/web/Startup.cs'
            )
        },
        [pscustomobject]@{
            Name = 'Web API'
            AppType = 'Api'
            Files = @(
                'skills/dotnet-new-app-slnx/assets/app/web-api.csproj',
                'skills/dotnet-new-app-slnx/assets/app/web-api/Program.minimal.cs',
                'skills/dotnet-new-app-slnx/assets/app/web-api/Program.startup.cs',
                'skills/dotnet-new-app-slnx/assets/app/web-api/Startup.cs'
            )
        },
        [pscustomobject]@{
            Name = 'MVC'
            AppType = 'Mvc'
            Files = @(
                'skills/dotnet-new-app-slnx/assets/app/web-mvc.csproj',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Program.minimal.cs',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Program.startup.cs',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Startup.cs',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Controllers/HomeController.cs',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/Home/Index.cshtml',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/Shared/_Layout.cshtml',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/_ViewImports.cshtml',
                'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/_ViewStart.cshtml'
            )
        },
        [pscustomobject]@{
            Name = 'Web App / Razor'
            AppType = 'WebApp'
            Files = @(
                'skills/dotnet-new-app-slnx/assets/app/webapp.csproj',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Program.minimal.cs',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Program.startup.cs',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Startup.cs',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Index.cshtml',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Index.cshtml.cs',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Shared/_Layout.cshtml',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/_ViewImports.cshtml',
                'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/_ViewStart.cshtml'
            )
        }
    )

    foreach ($variant in $variants) {
        $map = Get-AppPlaceholderMap -AppType $variant.AppType
        foreach ($file in $variant.Files) {
            $rendered = Apply-Replacements -Content (Get-FileText -RepoRoot $repoRoot -RelativePath $file -GitRef $Ref) -Map $map
            Assert-NoUnexpectedPlaceholders -Name ("{0}: {1}" -f $variant.Name, $file) -Content $rendered
        }
    }
}

Add-ValidationResult -Results $results -Name 'Rendered app templates compile in temp smoke-build workspaces' -Action {
    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-app-smoke-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null

    try {
        $sharedAssetFiles = Get-RepoFileList -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/shared' -GitRef $Ref
        $cases = @(
            [pscustomobject]@{
                Name = 'ConsoleMinimal-net9'
                AppType = 'Console'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/console.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/console/Program.minimal.cs'
                ExtraFiles = @()
            }
            [pscustomobject]@{
                Name = 'ConsoleStartup-net9'
                AppType = 'Console'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/console.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/console/Program.startup.cs'
                ExtraFiles = @(
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/console/Startup.cs'; Destination = 'Startup.cs' }
                )
            }
            [pscustomobject]@{
                Name = 'WorkerMinimal-net9'
                AppType = 'Worker'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/worker.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/worker/Program.minimal.cs'
                ExtraFiles = @(
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/worker/Worker.cs'; Destination = 'Worker.cs' }
                )
            }
            [pscustomobject]@{
                Name = 'WebMinimal-net9'
                AppType = 'Web'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/web.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/web/Program.minimal.cs'
                ExtraFiles = @()
            }
            [pscustomobject]@{
                Name = 'WebApiMinimal-net9'
                AppType = 'Api'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/web-api.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/web-api/Program.minimal.cs'
                ExtraFiles = @()
            }
            [pscustomobject]@{
                Name = 'MvcStartup-net9'
                AppType = 'Mvc'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/web-mvc.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Program.startup.cs'
                ExtraFiles = @(
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Startup.cs'; Destination = 'Startup.cs' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Controllers/HomeController.cs'; Destination = 'Controllers/HomeController.cs' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/Home/Index.cshtml'; Destination = 'Views/Home/Index.cshtml' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/Shared/_Layout.cshtml'; Destination = 'Views/Shared/_Layout.cshtml' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/_ViewImports.cshtml'; Destination = 'Views/_ViewImports.cshtml' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/web-mvc/Views/_ViewStart.cshtml'; Destination = 'Views/_ViewStart.cshtml' }
                )
            }
            [pscustomobject]@{
                Name = 'WebAppMinimal-net9'
                AppType = 'WebApp'
                TargetFramework = 'net9.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/webapp.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/webapp/Program.minimal.cs'
                ExtraFiles = @(
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Index.cshtml'; Destination = 'Pages/Index.cshtml' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Index.cshtml.cs'; Destination = 'Pages/Index.cshtml.cs' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/Shared/_Layout.cshtml'; Destination = 'Pages/Shared/_Layout.cshtml' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/_ViewImports.cshtml'; Destination = 'Pages/_ViewImports.cshtml' }
                    [pscustomobject]@{ Source = 'skills/dotnet-new-app-slnx/assets/app/webapp/Pages/_ViewStart.cshtml'; Destination = 'Pages/_ViewStart.cshtml' }
                )
            }
            [pscustomobject]@{
                Name = 'WebApiMinimal-net10'
                AppType = 'Api'
                TargetFramework = 'net10.0'
                Csproj = 'skills/dotnet-new-app-slnx/assets/app/web-api.csproj'
                Program = 'skills/dotnet-new-app-slnx/assets/app/web-api/Program.minimal.cs'
                ExtraFiles = @()
            }
        )

        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($case in $cases) {
            $caseRoot = Join-Path $workspaceRoot $case.Name
            $map = Get-AppPlaceholderMap -AppType $case.AppType -TargetFramework $case.TargetFramework
            $projectDirectory = Join-Path $caseRoot ("src/Acme.{0}" -f $case.AppType)
            $projectPath = Join-Path $projectDirectory ("Acme.{0}.csproj" -f $case.AppType)
            $testProjectDirectory = Join-Path $caseRoot ("test/Acme.{0}.FunctionalTests" -f $case.AppType)
            $testProjectPath = Join-Path $testProjectDirectory ("Acme.{0}.FunctionalTests.csproj" -f $case.AppType)

            foreach ($relativeSharedPath in $sharedAssetFiles) {
                Write-RenderedFileFromTemplate `
                    -RepoRoot $repoRoot `
                    -RelativePath (Join-Path 'skills/dotnet-new-app-slnx/assets/shared' $relativeSharedPath) `
                    -DestinationPath (Join-Path $caseRoot $relativeSharedPath) `
                    -Map $map `
                    -GitRef $Ref
            }

            Write-RenderedFileFromTemplate -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/Directory.Build.props' -DestinationPath (Join-Path $caseRoot 'Directory.Build.props') -Map $map -GitRef $Ref
            Write-RenderedFileFromTemplate -RepoRoot $repoRoot -RelativePath $case.Csproj -DestinationPath $projectPath -Map $map -GitRef $Ref
            Write-RenderedFileFromTemplate -RepoRoot $repoRoot -RelativePath $case.Program -DestinationPath (Join-Path $projectDirectory 'Program.cs') -Map $map -GitRef $Ref
            Write-RenderedFileFromTemplate -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/assets/app/test.csproj' -DestinationPath $testProjectPath -Map $map -GitRef $Ref

            foreach ($extraFile in $case.ExtraFiles) {
                Write-RenderedFileFromTemplate -RepoRoot $repoRoot -RelativePath $extraFile.Source -DestinationPath (Join-Path $projectDirectory $extraFile.Destination) -Map $map -GitRef $Ref
            }

            foreach ($relativeSharedPath in $sharedAssetFiles) {
                $expectedPath = Join-Path $caseRoot $relativeSharedPath
                if (-not (Test-Path $expectedPath)) {
                    $failures.Add(("[{0}] missing rendered shared asset: {1}" -f $case.Name, $relativeSharedPath))
                }
            }

            foreach ($pathToBuild in @($projectPath, $testProjectPath)) {
                $build = Invoke-DotNetBuildForValidation -ProjectPath $pathToBuild
                if ($build.ExitCode -ne 0) {
                    $failures.Add(("[{0}] dotnet build failed for {1}`n{2}" -f $case.Name, $pathToBuild, $build.Output))
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join "`n`n")
        }
    } finally {
        if (Test-Path $workspaceRoot) {
            Remove-Item -Path $workspaceRoot -Recurse -Force
        }
    }
}

Add-ValidationResult -Results $results -Name 'Rendered library templates leave no unexpected placeholders' -Action {
    $files = @(
        'skills/dotnet-new-lib-slnx/assets/library/test.csproj',
        'skills/dotnet-new-lib-slnx/assets/library/benchmark.csproj',
        'skills/dotnet-new-lib-slnx/assets/library/nuget-readme.md',
        'skills/dotnet-new-lib-slnx/assets/shared/README.md',
        'skills/dotnet-new-lib-slnx/assets/shared/AGENTS.md',
        'skills/dotnet-new-lib-slnx/assets/library/.docfx/docfx.json',
        'skills/dotnet-new-lib-slnx/assets/library/.docfx/toc.yml',
        'skills/dotnet-new-lib-slnx/assets/library/benchmark-program.cs'
    )
    $map = @{
        '{SOLUTION_NAME}' = 'MyLibrary'
        '{ROOT_NAMESPACE}' = 'Acme'
        '{PROJECT_NAME}' = 'MyLibrary'
        '{AUTHOR}' = 'Jane Doe'
        '{AUTHOR_EMAIL}' = 'jane@example.com'
        '{COMPANY_OR_PERSON}' = 'Jane Doe'
        '{COPYRIGHT_YEAR}' = '2026'
        '{PACKAGE_PROJECT_URL}' = 'https://example.com/mylibrary'
        '{REPOSITORY_URL}' = 'https://github.com/acme/mylibrary'
        '{REPO_OWNER}' = 'acme'
        '{REPO_SLUG}' = 'mylibrary'
        '{TARGET_FRAMEWORKS}' = 'net10.0;net8.0'
        '{DOCFX_TARGET_FRAMEWORK}' = 'net10.0'
        '{BENCHMARK_RUNNER_PROJECT_NAME}' = 'benchmark-runner'
        '{BENCHMARK_RUNNER_NAMESPACE}' = 'benchmark_runner'
        '{BENCHMARK_RUNNER_TARGET_FRAMEWORK}' = 'net10.0'
        '{BENCHMARK_RUNTIME_JOBS}' = '                    .AddJob(slimJob.WithRuntime(CoreRuntime.Core10_0))'
        '{SNK_FILE}' = 'mylibrary.snk'
        '{SONARCLOUD_ORG}' = 'acme'
        '{SONARCLOUD_KEY}' = 'acme_mylibrary'
    }

    foreach ($file in $files) {
        $rendered = Apply-Replacements -Content (Get-FileText -RepoRoot $repoRoot -RelativePath $file -GitRef $Ref) -Map $map
        Assert-NoUnexpectedPlaceholders -Name $file -Content $rendered
    }
}

$passed = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$label = if ([string]::IsNullOrWhiteSpace($Ref)) { 'WORKTREE' } else { $Ref }

Write-Host ("Validation target: {0}" -f $label)
Write-Host ("Passed: {0}" -f $passed)
Write-Host ("Failed: {0}" -f $failed)
Write-Host ''

foreach ($result in $results) {
    $prefix = if ($result.Status -eq 'PASS') { '[PASS]' } else { '[FAIL]' }
    Write-Host ("{0} {1}" -f $prefix, $result.Name)
    if ($result.Status -eq 'FAIL') {
        Write-Host ("       {0}" -f $result.Details)
    }
}

if ($failed -gt 0) {
    exit 1
}
