param(
    [string]$Ref
)

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
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
        return [System.IO.File]::ReadAllText($fullPath)
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
        [string]$AppType
    )

    return @{
        '{SOLUTION_NAME}' = 'DemoApp'
        '{ROOT_NAMESPACE}' = 'Acme'
        '{REPO_SLUG}' = 'demoapp'
        '{TARGET_FRAMEWORK}' = 'net10.0'
        '{AppType}' = $AppType
        '{UBUNTU_TESTRUNNER_TAG}' = 'codebeltnet/ubuntu-testrunner:10'
        '{CODEBELT_EXTENSIONS_XUNIT_APP_VERSION}' = '1.0.0'
        '{MICROSOFT_NET_TEST_SDK_VERSION}' = '17.14.1'
        '{MINVER_VERSION}' = '6.0.0'
        '{COVERLET_COLLECTOR_VERSION}' = '6.0.4'
        '{COVERLET_MSBUILD_VERSION}' = '6.0.4'
        '{XUNIT_V3_VERSION}' = '3.1.1'
        '{XUNIT_V3_RUNNER_CONSOLE_VERSION}' = '3.1.1'
        '{XUNIT_RUNNER_VISUALSTUDIO_VERSION}' = '3.1.1'
        '{BENCHMARKDOTNET_VERSION}' = '0.15.3'
        '{CODEBELT_BOOTSTRAPPER_CONSOLE_VERSION}' = '1.0.0'
        '{CODEBELT_BOOTSTRAPPER_WEB_VERSION}' = '1.0.0'
        '{CODEBELT_BOOTSTRAPPER_WORKER_VERSION}' = '1.0.0'
        '{CODEBELT_SHAREDKERNEL_VERSION}' = '1.0.0'
        '{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}' = '10.0.0'
        '{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}' = '10.0.0'
        '{MICROSOFT_EXTENSIONS_HOSTING_VERSION}' = '10.0.0'
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

Add-ValidationResult -Results $results -Name 'App skill collects target framework and conditional web_variant' -Action {
    $forms = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/FORMS.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle '### target_framework'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Newest generally supported .NET LTS channel'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle '### web_variant'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle '**show_when:** `app_host_types` includes `Web`'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Web API (Recommended)'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Empty Web'
    Assert-Contains -Name 'dotnet-new-app-slnx/FORMS.md' -Content $forms -Needle 'Web App / Razor'
}

Add-ValidationResult -Results $results -Name 'App skill documents web-family AppType mapping and package version resolution' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/SKILL.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle '## Step 3: Resolve Dynamic Dependency Versions'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Web` as the host family'
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
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{CODEBELT_BOOTSTRAPPER_WEB_VERSION}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}'
    Assert-Contains -Name 'app Directory.Packages.props' -Content $packages -Needle '{MICROSOFT_EXTENSIONS_HOSTING_VERSION}'
}

Add-ValidationResult -Results $results -Name 'App reference guide uses ROOT_NAMESPACE contract and web-family variant mapping' -Action {
    $guide = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/references/app.md' -GitRef $Ref
    Assert-NotContains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '{NS}'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '{ROOT_NAMESPACE}.{AppType}'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'Where `{AppType}` maps to the emitted project suffix:'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`web-api` (`Web API`)'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`web-mvc` (`MVC`)'
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle '`webapp` (`Web App / Razor`)'
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
    Assert-Contains -Name 'web-api/Program.minimal.cs' -Content $webApi -Needle 'builder.Services.AddControllers();'
    Assert-Contains -Name 'web-mvc/HomeController.cs' -Content $mvcController -Needle 'IActionResult Index()'
    Assert-Contains -Name 'web-mvc/Views/Home/Index.cshtml' -Content $mvcView -Needle 'starter MVC page'
    Assert-Contains -Name 'webapp/Pages/Index.cshtml' -Content $webAppPage -Needle 'starter Razor page'
    Assert-Contains -Name 'app shared README' -Content $readme -Needle 'src/{ROOT_NAMESPACE}.{AppType}/{ROOT_NAMESPACE}.{AppType}.csproj'
    Assert-NotContains -Name 'app shared README' -Content $readme -Needle 'src/{ROOT_NAMESPACE}.{SOLUTION_NAME}.App'
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
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle '{PROJECT_NAME}'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle '{DOCFX_TARGET_FRAMEWORK}'
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
