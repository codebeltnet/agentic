param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$ProjectPath,
    [ValidateSet('Focused', 'Shared')]
    [string]$ExpectedWebPattern,
    [ValidateSet('Focused', 'Shared')]
    [string]$ExpectedApplicationPattern
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Resolve-ContainedPath {
    param([string]$Root, [string]$Path)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $resolvedRoot $Path }
    $resolvedCandidate = (Resolve-Path -LiteralPath $candidate).Path
    if (-not $resolvedCandidate.StartsWith($resolvedRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($resolvedCandidate, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' is outside repository root '$resolvedRoot'."
    }
    return $resolvedCandidate
}

function Convert-ToRelativePath {
    param([string]$Root, [string]$Path)
    return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Get-EvaluatedProperties {
    param([string]$Path)

    $arguments = @(
        'msbuild', $Path, '-nologo',
        '-getProperty:TargetFramework,TargetFrameworks,IsTestProject,OutputType,ManagePackageVersionsCentrally,UseMicrosoftTestingPlatformRunner,RootNamespace'
    )
    $output = @(& dotnet @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet msbuild property evaluation failed for '$Path' with exit code $LASTEXITCODE.`n$($output -join [Environment]::NewLine)"
    }
    try {
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json).Properties
    } catch {
        throw "dotnet msbuild did not return parseable JSON for '$Path'.`n$($output -join [Environment]::NewLine)"
    }
}

function Get-AncestorFiles {
    param([string]$StartDirectory, [string]$Root, [string]$Name)

    $files = [System.Collections.Generic.List[string]]::new()
    $current = [System.IO.DirectoryInfo]::new($StartDirectory)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $files.Add((Resolve-Path -LiteralPath $candidate).Path)
        }
        if ([string]::Equals($current.FullName.TrimEnd('\', '/'), $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $current.Parent
    }
    return @($files)
}

function Get-PackageNodes {
    param([string]$Path, [string]$NodeName)

    try { [xml]$xml = [System.IO.File]::ReadAllText($Path, $utf8NoBom) } catch { return @() }
    $nodes = @($xml.SelectNodes("//$NodeName"))
    return @($nodes | ForEach-Object {
        $versionNode = $_.SelectSingleNode('Version')
        $versionAttribute = [string]$_.GetAttribute('Version')
        $version = if ($null -ne $versionNode) { [string]$versionNode.InnerText } elseif (-not [string]::IsNullOrWhiteSpace($versionAttribute)) { $versionAttribute } else { $null }
        [pscustomobject]@{
            id = [string]$_.GetAttribute('Include')
            version = $version
            owner = $Path
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.id) })
}

function Get-ProjectReferencePaths {
    param([string]$Path)

    try { [xml]$xml = [System.IO.File]::ReadAllText($Path, $utf8NoBom) } catch { return @() }
    $directory = Split-Path -Path $Path -Parent
    return @($xml.SelectNodes('//ProjectReference') | ForEach-Object {
        $include = [string]$_.GetAttribute('Include')
        if ([string]::IsNullOrWhiteSpace($include)) { return }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $directory $include))
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
    } | Sort-Object -Unique)
}

function Get-SourceFiles {
    param([string]$Directory)
    return @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.cs' |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
        Sort-Object FullName)
}

function Test-GenericHostEntryPoint {
    param([string]$ProjectReference)

    $directory = Split-Path -Path $ProjectReference -Parent
    $source = (Get-SourceFiles -Directory $directory | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom) }) -join "`n"
    return $source -match 'Host\.Create(DefaultBuilder|ApplicationBuilder)|HostApplicationBuilder|WebApplication\.CreateBuilder|CreateHostBuilder\s*\(|:\s*(ConsoleProgram|MinimalConsoleProgram|WorkerProgram|MinimalWorkerProgram|WebProgram|MinimalWebProgram)'
}

function Test-WebEntryPoint {
    param([string]$ProjectReference)

    $projectText = [System.IO.File]::ReadAllText($ProjectReference, $utf8NoBom)
    $directory = Split-Path -Path $ProjectReference -Parent
    $source = (Get-SourceFiles -Directory $directory | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom) }) -join "`n"
    return $projectText -match 'Microsoft\.NET\.Sdk\.Web' -or $source -match 'WebApplication\.CreateBuilder|:\s*(WebProgram|MinimalWebProgram)'
}

function Get-HostPattern {
    param([string]$ProjectReference)

    $directory = Split-Path -Path $ProjectReference -Parent
    $source = (Get-SourceFiles -Directory $directory | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom) }) -join "`n"
    foreach ($pattern in @('MinimalConsoleProgram', 'MinimalWorkerProgram', 'MinimalWebProgram', 'ConsoleProgram', 'WorkerProgram', 'WebProgram')) {
        if ($source -match ":\s*$pattern(?:\s*<|\b)") { return $pattern }
    }
    if ($source -match 'WebApplication\.CreateBuilder') { return 'ASP.NET Core minimal host' }
    if ($source -match 'Host\.Create(DefaultBuilder|ApplicationBuilder)|HostApplicationBuilder|CreateHostBuilder\s*\(') { return 'Generic Host' }
    return $null
}

$repoRootPath = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern) -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
    throw 'ExpectedWebPattern requires one selected ProjectPath so unrelated test projects cannot affect the postcondition.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern) -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
    throw 'ExpectedApplicationPattern requires one selected ProjectPath so unrelated test projects cannot affect the postcondition.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern) -and -not [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern)) {
    throw 'ExpectedWebPattern and ExpectedApplicationPattern are mutually exclusive.'
}
$projects = if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    @(Get-ChildItem -LiteralPath $repoRootPath -Recurse -File -Filter '*.csproj' |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
        Sort-Object FullName |
        Where-Object {
            $text = [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom)
            $_.BaseName -match '(Tests?|FunctionalTests)$' -or $text -match '<IsTestProject>\s*true\s*</IsTestProject>|PackageReference[^>]+Include="(?:xunit|xunit\.v3)"'
        } |
        Select-Object -ExpandProperty FullName)
} else {
    @((Resolve-ContainedPath -Root $repoRootPath -Path $ProjectPath))
}

if (@($projects).Count -eq 0) { throw "No test projects were found under '$repoRootPath'." }

$reports = foreach ($project in $projects) {
    if ([System.IO.Path]::GetExtension($project) -ne '.csproj') { throw "Selected project is not a .csproj: $project" }
    $projectDirectory = Split-Path -Path $project -Parent
    $properties = Get-EvaluatedProperties -Path $project
    $sourceFiles = @(Get-SourceFiles -Directory $projectDirectory)
    $sourceRecords = @($sourceFiles | ForEach-Object {
        [pscustomobject]@{
            path = Convert-ToRelativePath -Root $repoRootPath -Path $_.FullName
            lines = [System.IO.File]::ReadAllLines($_.FullName, $utf8NoBom)
            text = [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom)
        }
    })
    $combinedSource = (@($sourceRecords | ForEach-Object { $_.text }) -join "`n")

    $centralFiles = @(Get-AncestorFiles -StartDirectory $projectDirectory -Root $repoRootPath -Name 'Directory.Packages.props')
    $buildPropsFiles = @(Get-AncestorFiles -StartDirectory $projectDirectory -Root $repoRootPath -Name 'Directory.Build.props')
    $centralVersions = @{}
    foreach ($centralFile in @($centralFiles | Sort-Object { $_.Length })) {
        foreach ($node in Get-PackageNodes -Path $centralFile -NodeName 'PackageVersion') {
            $centralVersions[$node.id] = $node
        }
    }
    $packageReferences = [System.Collections.Generic.List[object]]::new()
    foreach ($owner in @($project) + @($buildPropsFiles)) {
        foreach ($node in Get-PackageNodes -Path $owner -NodeName 'PackageReference') {
            $central = if ($centralVersions.ContainsKey($node.id)) { $centralVersions[$node.id] } else { $null }
            $packageReferences.Add([pscustomobject]@{
                id = $node.id
                version = if ($node.version) { $node.version } elseif ($central) { $central.version } else { $null }
                referenceOwner = Convert-ToRelativePath -Root $repoRootPath -Path $owner
                versionOwner = if ($node.version) { Convert-ToRelativePath -Root $repoRootPath -Path $owner } elseif ($central) { Convert-ToRelativePath -Root $repoRootPath -Path $central.owner } else { $null }
                ownership = if ($node.version) { 'project-or-import' } elseif ($central) { 'central' } else { 'unresolved-or-transitive' }
            })
        }
    }
    $packages = @($packageReferences | Sort-Object id, referenceOwner -Unique)
    $packageIds = @($packages | ForEach-Object { $_.id })

    $webUsages = [System.Collections.Generic.List[object]]::new()
    $focusedWebUsages = [System.Collections.Generic.List[object]]::new()
    $sharedWebUsages = [System.Collections.Generic.List[object]]::new()
    $focusedApplicationUsages = [System.Collections.Generic.List[object]]::new()
    $sharedApplicationUsages = [System.Collections.Generic.List[object]]::new()
    $managedWebFixtureUsages = [System.Collections.Generic.List[object]]::new()
    $blockingWebFixtureUsages = [System.Collections.Generic.List[object]]::new()
    $managedApplicationFixtureUsages = [System.Collections.Generic.List[object]]::new()
    $blockingApplicationFixtureUsages = [System.Collections.Generic.List[object]]::new()
    $hostTestOwnerships = [System.Collections.Generic.List[object]]::new()
    $directWebHostConstructions = [System.Collections.Generic.List[object]]::new()
    $inheritance = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $sourceRecords) {
        $hostTestFields = [regex]::Matches($record.text, '\bIHostTest\s+(?<name>_[A-Za-z_][A-Za-z0-9_]*)\s*(?:[;=])')
        foreach ($fieldMatch in $hostTestFields) {
            $fieldName = $fieldMatch.Groups['name'].Value
            $escapedFieldName = [regex]::Escape($fieldName)
            $hostTestOwnerships.Add([pscustomobject]@{
                path = $record.path
                field = $fieldName
                synchronousDispose = $record.text -match "${escapedFieldName}\s*\.\s*Dispose\s*\("
                asynchronousDispose = $record.text -match "${escapedFieldName}\s*\.\s*DisposeAsync\s*\("
                synchronousHook = $record.text -match '\bOnDisposeManagedResources\s*\('
                asynchronousHook = $record.text -match '\bOnDisposeManagedResourcesAsync\s*\('
            })
        }
        for ($index = 0; $index -lt $record.lines.Count; $index++) {
            $line = $record.lines[$index]
            if ($line -match '\bWebApplicationFactory(?:\s*<|\b)') {
                $webUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '\bWebApplicationTestFactory\s*\.\s*Create\s*<') {
                $focusedWebUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match ':\s*WebApplicationTest\s*<') {
                $sharedWebUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '\bApplicationTestFactory\s*\.\s*Create\s*<') {
                $focusedApplicationUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match ':\s*ApplicationTest\s*<') {
                $sharedApplicationUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '(?<!Blocking)ManagedWebApplicationFixture\s*<') {
                $managedWebFixtureUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '\bBlockingManagedWebApplicationFixture\s*<') {
                $blockingWebFixtureUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '(?<!Blocking)ManagedApplicationFixture\s*<') {
                $managedApplicationFixtureUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '\bBlockingManagedApplicationFixture\s*<') {
                $blockingApplicationFixtureUsages.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '\bWebApplication\s*\.\s*CreateBuilder\s*\(' -or
                $line -match '\bWebHost\s*\.\s*CreateDefaultBuilder\s*\(' -or
                $line -match '\bHost\s*\.\s*Create(?:DefaultBuilder|ApplicationBuilder)\s*\(' -or
                $line -match '\bnew\s+(?:WebHostBuilder|HostBuilder|TestServer)\s*\(' -or
                $line -match '\bUseTestServer\s*\(') {
                $directWebHostConstructions.Add([pscustomobject]@{ path = $record.path; line = $index + 1; text = $line.Trim() })
            }
            if ($line -match '\bclass\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)[^:\r\n]*:\s*(?<base>[^\{]+)') {
                $inheritance.Add([pscustomobject]@{ path = $record.path; line = $index + 1; type = $Matches.name; baseTypes = $Matches.base.Trim() })
            }
        }
    }

    $projectReferences = @(Get-ProjectReferencePaths -Path $project)
    $referencedHosts = @($projectReferences | ForEach-Object {
        $referencedProjectText = [System.IO.File]::ReadAllText($_, $utf8NoBom)
        [pscustomobject]@{
            path = Convert-ToRelativePath -Root $repoRootPath -Path $_
            genericHost = Test-GenericHostEntryPoint -ProjectReference $_
            webHost = Test-WebEntryPoint -ProjectReference $_
            hostPattern = Get-HostPattern -ProjectReference $_
            executable = $referencedProjectText -match '<OutputType>\s*Exe\s*</OutputType>|Microsoft\.NET\.Sdk\.(?:Worker|Web)'
        }
    })

    $isWeb = $webUsages.Count -gt 0 -or
        $packageIds -contains 'Microsoft.AspNetCore.Mvc.Testing' -or
        $packageIds -contains 'Microsoft.AspNetCore.TestHost' -or
        $packageIds -contains 'Codebelt.Extensions.Xunit.Hosting.AspNetCore' -or
        $combinedSource -match '\b(WebApplicationTestFactory|WebApplicationTest<|TestServer)\b' -or
        @($referencedHosts | Where-Object webHost).Count -gt 0
    $isApplication = -not $isWeb -and (
        $combinedSource -match '\b(ApplicationTestFactory|ApplicationTest<|ManagedApplicationFixture|BlockingManagedApplicationFixture)\b' -or
        @($referencedHosts | Where-Object genericHost).Count -gt 0 -or
        @($referencedHosts | Where-Object executable).Count -gt 0 -or
        $combinedSource -match '\b(IHostedService|BackgroundService)\b'
    )
    $role = if ($isWeb) { 'ASP.NET Core functional test' } elseif ($isApplication) { 'Console or worker functional test' } else { 'Ordinary unit test' }

    $xunitGeneration = if ($packageIds -contains 'xunit.v3' -or $combinedSource -match '\bXunit\.v3\b') {
        'v3'
    } elseif ($packageIds -contains 'xunit' -or $packageIds -contains 'xunit.core' -or $combinedSource -match '\bXunit\.Abstractions\b') {
        'v2'
    } else {
        'unknown'
    }

    $frameworks = if (-not [string]::IsNullOrWhiteSpace([string]$properties.TargetFrameworks)) {
        @(([string]$properties.TargetFrameworks).Split(';', [System.StringSplitOptions]::RemoveEmptyEntries))
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$properties.TargetFramework)) {
        @([string]$properties.TargetFramework)
    } else { @() }

    $blockers = [System.Collections.Generic.List[string]]::new()
    if ($role -eq 'Console or worker functional test' -and $referencedHosts.Count -gt 0 -and @($referencedHosts | Where-Object genericHost).Count -eq 0) {
        $blockers.Add('The referenced executable does not expose a detectable Generic Host entry point. Test-only scope must report the required application-host adaptation; application scope must adapt bootstrap before using ApplicationTestFactory.')
    }
    if ($role -eq 'Console or worker functional test' -and $projectReferences.Count -eq 0 -and $combinedSource -notmatch '\b(ApplicationTestFactory|ApplicationTest<)\b') {
        $blockers.Add('No referenced executable or existing Codebelt application-test entry point was found for the console/worker functional-test role.')
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern)) {
        if ($role -ne 'ASP.NET Core functional test') {
            $blockers.Add("The requested $ExpectedWebPattern web postcondition cannot be applied because the selected project was classified as '$role'.")
        }
        if ($webUsages.Count -gt 0) {
            $blockers.Add('The selected web migration still contains WebApplicationFactory. Removing every selected legacy factory is required.')
        }
        if ($directWebHostConstructions.Count -gt 0) {
            $blockers.Add('The selected web migration constructs a replacement host in test code. Bootstrap the production entry point through the selected Codebelt web-test abstraction instead of replaying Program, WebApplication.CreateBuilder, or TestServer setup.')
        }
        if ($blockingWebFixtureUsages.Count -gt 0) {
            $blockers.Add('The selected web migration still uses deprecated BlockingManagedWebApplicationFixture. Replace it with entrypoint-owned ManagedWebApplicationFixture; the blocking type is scheduled for removal.')
        }
        if ($managedWebFixtureUsages.Count -eq 0) {
            $blockers.Add('The selected web migration must explicitly use ManagedWebApplicationFixture<TEntryPoint> so the application entry point owns startup.')
        }
        foreach ($ownership in $hostTestOwnerships) {
            if (-not $ownership.synchronousDispose -or -not $ownership.asynchronousDispose -or -not $ownership.synchronousHook -or -not $ownership.asynchronousHook) {
                $blockers.Add("The focused harness '$($ownership.path)' owns $($ownership.field) but does not dispose it through both synchronous and asynchronous Test disposal hooks.")
            }
        }
        if ($ExpectedWebPattern -eq 'Focused' -and $focusedWebUsages.Count -eq 0) {
            $blockers.Add('The focused web postcondition requires at least one WebApplicationTestFactory.Create<TEntryPoint> call in the selected project.')
        }
        if ($ExpectedWebPattern -eq 'Shared' -and $sharedWebUsages.Count -eq 0) {
            $blockers.Add('The shared web postcondition requires a test class derived from WebApplicationTest<TEntryPoint, TFixture> in the selected project.')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern)) {
        if ($role -ne 'Console or worker functional test') {
            $blockers.Add("The requested $ExpectedApplicationPattern application postcondition cannot be applied because the selected project was classified as '$role'.")
        }
        if ($directWebHostConstructions.Count -gt 0) {
            $blockers.Add('The selected application migration constructs a replacement host in test code. Bootstrap the production entry point through the selected Codebelt application-test abstraction instead of replaying Program or Generic Host setup.')
        }
        if ($blockingApplicationFixtureUsages.Count -gt 0) {
            $blockers.Add('The selected application migration still uses deprecated BlockingManagedApplicationFixture. Replace it with entrypoint-owned ManagedApplicationFixture; the blocking type is scheduled for removal.')
        }
        if ($managedApplicationFixtureUsages.Count -eq 0) {
            $blockers.Add('The selected application migration must explicitly use ManagedApplicationFixture<TEntryPoint> so the application entry point owns startup.')
        }
        foreach ($ownership in $hostTestOwnerships) {
            if (-not $ownership.synchronousDispose -or -not $ownership.asynchronousDispose -or -not $ownership.synchronousHook -or -not $ownership.asynchronousHook) {
                $blockers.Add("The focused harness '$($ownership.path)' owns $($ownership.field) but does not dispose it through both synchronous and asynchronous Test disposal hooks.")
            }
        }
        if ($ExpectedApplicationPattern -eq 'Focused' -and $focusedApplicationUsages.Count -eq 0) {
            $blockers.Add('The focused application postcondition requires at least one ApplicationTestFactory.Create<TEntryPoint> call in the selected project.')
        }
        if ($ExpectedApplicationPattern -eq 'Shared' -and $sharedApplicationUsages.Count -eq 0) {
            $blockers.Add('The shared application postcondition requires a test class derived from ApplicationTest<TEntryPoint, TFixture> in the selected project.')
        }
    }

    $recommendations = [System.Collections.Generic.List[string]]::new()
    # The managed fixtures this skill targets were introduced in Codebelt xUnit 11.1.0. A project pinned below that
    # floor restores fine and reports no usage problem, then fails to compile the moment the pattern is written, so
    # surface the required bump as evidence during inspection instead of as a build error after the edits.
    $managedFixtureFloor = [version]'11.1.0'
    foreach ($package in $packages) {
        if ($package.id -notmatch '^Codebelt\.Extensions\.Xunit(\.App|\.Hosting(\.AspNetCore)?)?$') { continue }
        $normalizedVersion = ([string]$package.version -split '-', 2)[0]
        $parsedVersion = $null
        if (-not [version]::TryParse($normalizedVersion, [ref]$parsedVersion)) { continue }
        if ($parsedVersion -lt $managedFixtureFloor) {
            $recommendations.Add("Raise $($package.id) from $($package.version) to at least $managedFixtureFloor in $($package.versionOwner); ManagedWebApplicationFixture and ManagedApplicationFixture do not exist below that version, so the required pattern cannot compile until the version is raised.")
        }
    }
    if ($xunitGeneration -eq 'v2') { $recommendations.Add('Modernize the selected project to xUnit v3 and Microsoft Testing Platform while preserving target frameworks and package ownership.') }
    if ([string]$properties.UseMicrosoftTestingPlatformRunner -ne 'true') { $recommendations.Add('Enable UseMicrosoftTestingPlatformRunner for the selected xUnit v3 test project, preferably in its existing shared test-project property owner.') }
    if ($webUsages.Count -gt 0) { $recommendations.Add('Replace every selected WebApplicationFactory usage and preserve configuration, start behavior, clients, services, disposal, and isolation.') }
    if ($blockingWebFixtureUsages.Count -gt 0) { $recommendations.Add('Replace deprecated BlockingManagedWebApplicationFixture usage with entrypoint-owned ManagedWebApplicationFixture; the blocking type is scheduled for removal.') }
    if ($blockingApplicationFixtureUsages.Count -gt 0) { $recommendations.Add('Replace deprecated BlockingManagedApplicationFixture usage with entrypoint-owned ManagedApplicationFixture; the blocking type is scheduled for removal.') }
    switch ($role) {
        'Ordinary unit test' { $recommendations.Add('Use Test or an established Test-derived base with ITestOutputHelper.') }
        'ASP.NET Core functional test' { $recommendations.Add('Use WebApplicationTestFactory with an explicit ManagedWebApplicationFixture for focused ownership or WebApplicationTest with ManagedWebApplicationFixture for shared fixture ownership.') }
        'Console or worker functional test' { $recommendations.Add('Use ApplicationTestFactory with an explicit ManagedApplicationFixture for focused ownership or ApplicationTest with ManagedApplicationFixture for shared fixture ownership.') }
    }

    [pscustomobject]@{
        project = Convert-ToRelativePath -Root $repoRootPath -Path $project
        role = $role
        frameworks = @($frameworks)
        xunitGeneration = $xunitGeneration
        properties = [ordered]@{
            isTestProject = [string]$properties.IsTestProject
            outputType = [string]$properties.OutputType
            useMicrosoftTestingPlatformRunner = [string]$properties.UseMicrosoftTestingPlatformRunner
            managePackageVersionsCentrally = [string]$properties.ManagePackageVersionsCentrally
            rootNamespace = [string]$properties.RootNamespace
        }
        packageOwnership = $packages
        inheritance = @($inheritance | Sort-Object path, line)
        webApplicationFactoryUsages = @($webUsages | Sort-Object path, line)
        focusedWebApplicationTestFactoryUsages = @($focusedWebUsages | Sort-Object path, line)
        sharedWebApplicationTestUsages = @($sharedWebUsages | Sort-Object path, line)
        focusedApplicationTestFactoryUsages = @($focusedApplicationUsages | Sort-Object path, line)
        sharedApplicationTestUsages = @($sharedApplicationUsages | Sort-Object path, line)
        managedWebApplicationFixtureUsages = @($managedWebFixtureUsages | Sort-Object path, line)
        blockingManagedWebApplicationFixtureUsages = @($blockingWebFixtureUsages | Sort-Object path, line)
        managedApplicationFixtureUsages = @($managedApplicationFixtureUsages | Sort-Object path, line)
        blockingManagedApplicationFixtureUsages = @($blockingApplicationFixtureUsages | Sort-Object path, line)
        hostTestOwnerships = @($hostTestOwnerships | Sort-Object path, field)
        directWebHostConstructions = @($directWebHostConstructions | Sort-Object path, line)
        referencedApplications = @($referencedHosts | Sort-Object path)
        recommendations = @($recommendations)
        blockers = @($blockers)
    }
}

$result = [ordered]@{
    repoRoot = $repoRootPath
    expectedWebPattern = $ExpectedWebPattern
    expectedApplicationPattern = $ExpectedApplicationPattern
    projectCount = @($reports).Count
    projects = @($reports)
}

$result | ConvertTo-Json -Depth 8
if ((-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern) -or -not [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern)) -and @($reports | Where-Object { $_.blockers.Count -gt 0 }).Count -gt 0) {
    exit 2
}
