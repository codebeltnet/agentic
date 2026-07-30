param(
    [string]$Ref,
    [switch]$Full
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

function Get-TrackedRepoPaths {
    param(
        [string]$RepoRoot,
        [string]$GitRef
    )

    if ([string]::IsNullOrWhiteSpace($GitRef)) {
        $output = git -C $RepoRoot ls-files 2>$null
    } else {
        $output = git -C $RepoRoot ls-tree -r --name-only $GitRef 2>$null
    }

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate tracked repository files for validation.'
    }

    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
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

function Test-IsLocalShellPolicyScanCandidate {
    param([string]$RelativePath)

    $normalizedPath = $RelativePath -replace '\\', '/'
    if ($normalizedPath.StartsWith('./')) {
        $normalizedPath = $normalizedPath.Substring(2)
    }
    if ($normalizedPath -eq 'CHANGELOG.md') {
        return $false
    }

    if ($normalizedPath -eq 'scripts/validate-skill-templates.ps1') {
        return $false
    }

    if ($normalizedPath -like 'skills/skill-creator-agnostic/*') {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($normalizedPath).ToLowerInvariant()
    return @('.cs', '.json', '.md', '.ps1', '.yml', '.yaml') -contains $extension
}

function Get-LocalShellPolicyFindingsFromContentItems {
    param([object[]]$Items)

    $legacyShell = 'power' + 'shell'
    $legacyShellPattern = [regex]::Escape($legacyShell)

    $rules = @(
        [pscustomobject]@{
            Pattern = "(?i)\b$legacyShellPattern(?:\.exe)?\s+-"
            Message = 'Local command examples must use `pwsh` 7+ instead of the legacy executable.'
        }
        [pscustomobject]@{
            Pattern = "(?i)\bshell:\s*$legacyShellPattern(?:\.exe)?\b"
            Message = 'Workflow steps that explicitly choose a `pwsh`-style shell must use `pwsh`.'
        }
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Items)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.Path)) {
            continue
        }

        $relativePath = [string]$item.Path -replace '\\', '/'
        if ($relativePath.StartsWith('./')) {
            $relativePath = $relativePath.Substring(2)
        }
        if (-not (Test-IsLocalShellPolicyScanCandidate -RelativePath $relativePath)) {
            continue
        }

        $content = if ($null -eq $item.Content) { '' } else { [string]$item.Content }
        $lines = [regex]::Split($content, '\r?\n')

        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            $message = $null

            foreach ($rule in $rules) {
                if ($line -match $rule.Pattern) {
                    $message = $rule.Message
                    break
                }
            }

            if ($null -ne $message) {
                $findings.Add([pscustomobject]@{
                    Path = $relativePath
                    LineNumber = $index + 1
                    Line = $line
                    Message = $message
                })
            }
        }
    }

    return @($findings)
}

function Get-LocalShellPolicyFindings {
    param(
        [string]$RepoRoot,
        [string]$GitRef
    )

    $items = foreach ($path in Get-TrackedRepoPaths -RepoRoot $RepoRoot -GitRef $GitRef) {
        if (-not (Test-IsLocalShellPolicyScanCandidate -RelativePath $path)) {
            continue
        }

        [pscustomobject]@{
            Path = $path
            Content = Get-FileText -RepoRoot $RepoRoot -RelativePath $path -GitRef $GitRef
        }
    }

    return @(Get-LocalShellPolicyFindingsFromContentItems -Items $items)
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

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("[RUN] {0}" -f $Name)

    try {
        & $Action
        $stopwatch.Stop()
        $Results.Add([pscustomobject]@{
            Name = $Name
            Status = 'PASS'
            Details = ''
        })
        Write-Host ("[PASS] {0} ({1:n1}s)" -f $Name, $stopwatch.Elapsed.TotalSeconds)
    } catch {
        $stopwatch.Stop()
        $Results.Add([pscustomobject]@{
            Name = $Name
            Status = 'FAIL'
            Details = $_.Exception.Message
        })
        Write-Host ("[FAIL] {0} ({1:n1}s)" -f $Name, $stopwatch.Elapsed.TotalSeconds)
    }
}

function Get-ValidationParallelism {
    param(
        [int]$WorkItemCount,
        [int]$Maximum = 12
    )

    if ($WorkItemCount -le 0) {
        return 1
    }

    $processorCount = [System.Environment]::ProcessorCount
    return [Math]::Max(1, [Math]::Min($WorkItemCount, [Math]::Min($Maximum, $processorCount)))
}

function Invoke-ThreadJobBatch {
    param(
        [object[]]$Items,
        [string]$Activity,
        [int]$ThrottleLimit,
        [scriptblock]$ScriptBlock,
        [switch]$UseProcessJobs
    )

    $pending = [System.Collections.Queue]::new()
    foreach ($item in $Items) {
        [void]$pending.Enqueue($item)
    }

    $active = @()
    $results = [System.Collections.Generic.List[object]]::new()
    $total = $Items.Count
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastHeartbeat = [DateTimeOffset]::UtcNow
    $useThreadJob = -not $UseProcessJobs -and $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)

    Write-Host ("[RUN] {0}: {1} work item(s), {2} worker(s)" -f $Activity, $total, $ThrottleLimit)

    while ($pending.Count -gt 0 -or $active.Count -gt 0) {
        while ($pending.Count -gt 0 -and $active.Count -lt $ThrottleLimit) {
            $item = $pending.Dequeue()
            if ($useThreadJob) {
                $active += Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $item
            } else {
                $active += Start-Job -ScriptBlock $ScriptBlock -ArgumentList $item
            }
        }

        $completed = @($active | Where-Object { $_.State -notin @('NotStarted', 'Running') })
        foreach ($job in $completed) {
            try {
                foreach ($result in @(Receive-Job -Job $job -ErrorAction Stop)) {
                    [void]$results.Add($result)
                }
            } catch {
                [void]$results.Add([pscustomobject]@{
                    Name = $job.Name
                    ExitCode = 1
                    Output = $_.Exception.Message
                    ElapsedSeconds = 0
                })
            } finally {
                Remove-Job -Job $job -Force
            }
        }

        if ($completed.Count -gt 0) {
            $completedIds = @($completed | ForEach-Object { $_.Id })
            $active = @($active | Where-Object { $completedIds -notcontains $_.Id })
        }

        $now = [DateTimeOffset]::UtcNow
        if (($now - $lastHeartbeat).TotalSeconds -ge 10) {
            $done = $results.Count
            Write-Host ("[WAIT] {0}: {1}/{2} done, {3} running, {4:n0}s elapsed" -f $Activity, $done, $total, $active.Count, $stopwatch.Elapsed.TotalSeconds)
            $lastHeartbeat = $now
        }

        if ($pending.Count -gt 0 -or $active.Count -gt 0) {
            Start-Sleep -Milliseconds 250
        }
    }

    $stopwatch.Stop()
    Write-Host ("[DONE] {0}: {1} work item(s) in {2:n1}s" -f $Activity, $total, $stopwatch.Elapsed.TotalSeconds)
    return @($results)
}

function Invoke-DotNetBuildsForValidation {
    param(
        [object[]]$BuildRequests
    )

    $parallelism = Get-ValidationParallelism -WorkItemCount $BuildRequests.Count -Maximum 12
    $buildResults = Invoke-ThreadJobBatch `
        -Items $BuildRequests `
        -Activity 'app smoke builds' `
        -ThrottleLimit $parallelism `
        -ScriptBlock {
            param($Request)

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $outputs = [System.Collections.Generic.List[string]]::new()
            $exitCode = 0
            foreach ($projectPath in @($Request.ProjectPaths)) {
                $output = & dotnet build $projectPath '--nologo' 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $exitCode = $LASTEXITCODE
                }

                $outputs.Add(("[{0}]`n{1}" -f $projectPath, ($output -join [Environment]::NewLine)))
            }
            $stopwatch.Stop()

            [pscustomobject]@{
                Name = $Request.CaseName
                ProjectPath = ($Request.ProjectPaths -join ', ')
                ExitCode = $exitCode
                Output = ($outputs -join ([Environment]::NewLine + [Environment]::NewLine))
                ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
            }
        }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($build in $buildResults) {
        $status = if ($build.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] app smoke build {1} ({2:n1}s)" -f $status, $build.Name, $build.ElapsedSeconds)
        if ($build.ExitCode -ne 0) {
            $failures.Add(("[{0}] dotnet build failed for {1}`n{2}" -f $build.Name, $build.ProjectPath, $build.Output))
        }
    }

    return @($failures)
}

function Invoke-ValidationScriptJobs {
    param(
        [object[]]$Scripts
    )

    $parallelism = Get-ValidationParallelism -WorkItemCount $Scripts.Count -Maximum 4
    $scriptResults = Invoke-ThreadJobBatch `
        -Items $Scripts `
        -Activity 'DocFX regression suites' `
        -ThrottleLimit $parallelism `
        -UseProcessJobs `
        -ScriptBlock {
            param($Script)

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $output = @()
            $exitCode = 1
            $dotnetHome = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-dotnet-home-' + [Guid]::NewGuid().ToString('N'))
            $oldDotNetCliHome = $env:DOTNET_CLI_HOME
            $oldXdgDataHome = $env:XDG_DATA_HOME

            try {
                New-Item -ItemType Directory -Path $dotnetHome -Force | Out-Null
                $env:DOTNET_CLI_HOME = $dotnetHome
                $env:XDG_DATA_HOME = Join-Path $dotnetHome 'share'

                $output = & $Script.Path 2>&1
                $exitCode = $LASTEXITCODE
            } finally {
                $env:DOTNET_CLI_HOME = $oldDotNetCliHome
                $env:XDG_DATA_HOME = $oldXdgDataHome
                if (Test-Path $dotnetHome) {
                    Remove-Item -Path $dotnetHome -Recurse -Force -ErrorAction SilentlyContinue
                }
                $stopwatch.Stop()
            }

            [pscustomobject]@{
                Name = $Script.Name
                ExitCode = $exitCode
                Output = ($output -join [Environment]::NewLine)
                ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
            }
        }

    return @($scriptResults)
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
            if ($eval.PSObject.Properties.Name -contains 'files' -and $null -ne $eval.files) {
                $fixturePaths = @($eval.files)

                foreach ($fixturePath in $fixturePaths) {
                    if ([string]::IsNullOrWhiteSpace([string]$fixturePath)) {
                        throw "$relativeEvalPath contains a blank files entry"
                    }

                    $normalizedFixturePath = ([string]$fixturePath).Trim() -replace '\\', '/'
                    if ($normalizedFixturePath.StartsWith('/')) {
                        throw "$relativeEvalPath contains an absolute files entry '$fixturePath'"
                    }
                    if ($normalizedFixturePath -match '^[A-Za-z]:/') {
                        throw "$relativeEvalPath contains a drive-qualified files entry '$fixturePath'"
                    }
                    if (($normalizedFixturePath -split '/') -contains '..') {
                        throw "$relativeEvalPath contains a parent-directory files entry '$fixturePath'"
                    }

                    $skillRelativeFixturePath = 'skills/{0}/{1}' -f $skillDir.Name, $normalizedFixturePath
                    [void](Get-FileText -RepoRoot $repoRoot -RelativePath $skillRelativeFixturePath -GitRef $Ref)
                }
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

Add-ValidationResult -Results $results -Name 'Active local shell guidance rejects only legacy PowerShell executable use' -Action {
    $findings = @(Get-LocalShellPolicyFindings -RepoRoot $repoRoot -GitRef $Ref)

    if ($findings.Count -gt 0) {
        $details = @(
            $findings | ForEach-Object {
                '{0}:{1}: {2}`n       {3}' -f $_.Path, $_.LineNumber, $_.Message, $_.Line.Trim()
            }
        )

        throw ("Legacy `powershell` executable usage is still present; update these lines:`n" + ($details -join "`n"))
    }
}

Add-ValidationResult -Results $results -Name 'Local shell policy scanner rejects legacy executable invocations and allows valid terminology' -Action {
    $legacyShell = 'power' + 'shell'
    $legacyExe = $legacyShell + '.exe'
    $fence = [string]([char]96) * 3

    $cases = @(
        [pscustomobject]@{
            Name = 'maintained skill legacy command'
            Path = 'skills/example/case-01.md'
            Content = "$legacyShell -NoProfile -File ./scripts/example.ps1"
            ExpectViolation = $true
        }
        [pscustomobject]@{
            Name = 'case-variant legacy command'
            Path = 'skills/example/case-02.md'
            Content = ('PoWeR' + 'ShElL -NoProfile -File ./scripts/example.ps1')
            ExpectViolation = $true
        }
        [pscustomobject]@{
            Name = 'legacy executable command'
            Path = 'skills/example/case-03.md'
            Content = "$legacyExe -Command Get-ChildItem"
            ExpectViolation = $true
        }
        [pscustomobject]@{
            Name = 'pwsh script command'
            Path = 'skills/example/case-04.md'
            Content = 'pwsh -NoProfile -File ./scripts/example.ps1'
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'bash command'
            Path = 'skills/example/case-05.md'
            Content = 'bash ./scripts/example.sh'
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'workflow bash shell'
            Path = '.github/workflows/case-06.yml'
            Content = 'shell: bash'
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'workflow pwsh shell'
            Path = '.github/workflows/case-07.yml'
            Content = 'shell: pwsh'
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'powershell fence'
            Path = 'skills/example/case-08.md'
            Content = $fence + 'powershell' + [Environment]::NewLine + '$value = 1' + [Environment]::NewLine + $fence
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'PowerShell session prose'
            Path = 'skills/example/case-09.md'
            Content = 'Use a PowerShell session if that is the host the user already chose.'
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'released changelog exclusion'
            Path = 'CHANGELOG.md'
            Content = "$legacyShell -File ./scripts/example.ps1"
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'obsolete skill exclusion'
            Path = 'skills/skill-creator-agnostic/SKILL.md'
            Content = "$legacyShell -File ./scripts/example.ps1"
            ExpectViolation = $false
        }
        [pscustomobject]@{
            Name = 'legacy workflow shell'
            Path = '.github/workflows/case-11.yml'
            Content = "shell: $legacyShell"
            ExpectViolation = $true
        }
    )

    $items = foreach ($case in $cases) {
        [pscustomobject]@{
            Path = $case.Path
            Content = $case.Content
        }
    }

    $findings = Get-LocalShellPolicyFindingsFromContentItems -Items $items

    foreach ($case in $cases) {
        $caseFindings = @($findings | Where-Object { $_.Path -eq $case.Path })

        if ($case.ExpectViolation -and $caseFindings.Count -eq 0) {
            throw "Expected a finding for '$($case.Name)' but none was reported."
        }

        if (-not $case.ExpectViolation -and $caseFindings.Count -gt 0) {
            throw "Expected no finding for '$($case.Name)' but found: $($caseFindings[0].Message)"
        }
    }
}

Add-ValidationResult -Results $results -Name 'Repository docs define the local shell execution policy' -Action {
    $agents = Get-FileText -RepoRoot $repoRoot -RelativePath 'AGENTS.md' -GitRef $Ref
    $contributing = Get-FileText -RepoRoot $repoRoot -RelativePath 'CONTRIBUTING.md' -GitRef $Ref

    Assert-Contains -Name 'AGENTS.md' -Content $agents -Needle '## Local Shell Execution'
    Assert-Contains -Name 'AGENTS.md' -Content $agents -Needle 'Agents may use any appropriate local shell.'
    Assert-Contains -Name 'AGENTS.md' -Content $agents -Needle 'use PowerShell 7+ through `pwsh`; never invoke `powershell` or `powershell.exe`'
    Assert-Contains -Name 'CONTRIBUTING.md' -Content $contributing -Needle 'pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1'
    Assert-Contains -Name 'CONTRIBUTING.md' -Content $contributing -Needle 'pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1 -Ref HEAD'
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
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'pwsh -NoProfile -File "<skill-root>/scripts/resolve-package-versions.ps1" -TargetFramework <TargetFramework>'
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'pwsh -NoProfile -File "<skill-root>/scripts/restore-missing-shared-assets.ps1"'
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
    Assert-Contains -Name 'dotnet-new-app-slnx/SKILL.md' -Content $skill -Needle 'Every file listed in `assets/shared.manifest.json` exists in the generated repo at its declared relative path'
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
    Assert-Contains -Name 'dotnet-new-app-slnx/references/app.md' -Content $guide -Needle 'pwsh -NoProfile -File "<skill-root>/scripts/resolve-package-versions.ps1" -TargetFramework {TARGET_FRAMEWORK}'
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
    Assert-Contains -Name 'app shared copy guidance' -Content (Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-app-slnx/references/app.md' -GitRef $Ref) -Needle 'manually restore the missing files directly from the repository source tree'
    Assert-Contains -Name 'lib shared copy guidance' -Content (Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/references/library.md' -GitRef $Ref) -Needle 'manually restore the missing files directly from the repository source tree'
}

Add-ValidationResult -Results $results -Name 'Library skill documents PROJECT_NAME and DOCFX target framework' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-new-lib-slnx/SKILL.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'current working directory'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle '{PROJECT_NAME}'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle '{DOCFX_TARGET_FRAMEWORK}'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'pwsh -NoProfile -File "<skill-root>/scripts/restore-missing-shared-assets.ps1"'
    Assert-Contains -Name 'dotnet-new-lib-slnx/SKILL.md' -Content $skill -Needle 'In PowerShell, prefer .NET file APIs'
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
    Assert-Contains -Name 'dotnet-new-lib-slnx/references/library.md' -Content $guide -Needle 'Recommended PowerShell approach for rewritten templates:'
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

Add-ValidationResult -Results $results -Name 'dotnet-benchmark enforces valid, proportionate experiments and preserves honest comparison semantics' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/SKILL.md' -GitRef $Ref
    $forms = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/FORMS.md' -GitRef $Ref
    $candidateSelection = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/references/candidate-selection.md' -GitRef $Ref
    $experimentDesign = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/references/experiment-design.md' -GitRef $Ref
    $benchmarkEssentials = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/references/benchmarkdotnet-essentials.md' -GitRef $Ref
    $runnerPreflight = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/references/runner-preflight.md' -GitRef $Ref
    $comparison = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/assets/comparison-benchmark.cs' -GitRef $Ref
    $operation = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/assets/operation-benchmark.cs' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/evals/evals.json' -GitRef $Ref
    $fixtureFiles = Get-RepoFileList -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/evals/files' -GitRef $Ref
    $validateSkillScript = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-benchmark/scripts/validate-skill.ps1' -GitRef $Ref

    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'A microbenchmark measures a suspected cost under a defined workload; it does not prove that the type is an application bottleneck.'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Do not use construction as the baseline for formatting, equality, hashing, parsing, or another unrelated operation.'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Read `references/candidate-selection.md`'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Read `references/experiment-design.md`'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle '--list flat'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle '--job dry'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'pwsh -NoProfile -File "<skill-root>/scripts/check-benchmark-requirements.ps1" -RepoRoot "<repo-root>"'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle '#### Yolo mode'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Start a full performance run only after an explicit human instruction to run it now.'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Yolo never authorizes a full performance run.'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'read `references/runner-preflight.md`'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'reports.wouldSkipRequestedBenchmark'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'complete BenchmarkDotNet summary'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'When a parameter is only size or payload'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Semantic preflight'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'independently derived exact expected result'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'Successful execution is not a correctness oracle.'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'do the baseline and candidate perform equivalent consumer-visible work over identical logical input?'
    Assert-Contains -Name 'dotnet-benchmark/SKILL.md' -Content $skill -Needle 'After the first valid full result'
    Assert-Contains -Name 'dotnet-benchmark/FORMS.md' -Content $forms -Needle 'Auto-discover the highest-value performance questions (Recommended)'
    Assert-Contains -Name 'dotnet-benchmark/FORMS.md' -Content $forms -Needle '### candidate_plan_confirmation'
    Assert-Contains -Name 'dotnet-benchmark/FORMS.md' -Content $forms -Needle '## Yolo mode override'
    Assert-Contains -Name 'dotnet-benchmark/FORMS.md' -Content $forms -Needle 'skip `candidate_plan_confirmation`'
    Assert-Contains -Name 'dotnet-benchmark/FORMS.md' -Content $forms -Needle 'explicit human instruction to start a full performance run'
    Assert-Contains -Name 'candidate-selection.md' -Content $candidateSelection -Needle '## Candidate matrix'
    Assert-Contains -Name 'candidate-selection.md' -Content $candidateSelection -Needle '## Profiling-first gate'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle '## Correctness oracle'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle 'Do not compare unrelated operations.'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle '## Workload invariants'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle '## Benchmark validity gate'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle '## Deferred execution and terminal operations'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle '## Semantic preflight'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle 'Successful execution is not a correctness oracle.'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle 'do the baseline and candidate perform equivalent consumer-visible work over identical logical input?'
    Assert-Contains -Name 'experiment-design.md' -Content $experimentDesign -Needle 'Do not benchmark a homogeneous all-match store and call it type filtering unless the all-match path is the actual subject.'
    Assert-Contains -Name 'benchmarkdotnet-essentials.md' -Content $benchmarkEssentials -Needle 'one warmup iteration plus controlled iteration counts'
    Assert-Contains -Name 'benchmarkdotnet-essentials.md' -Content $benchmarkEssentials -Needle '## Deferred pipelines and terminal operations'
    Assert-Contains -Name 'benchmarkdotnet-essentials.md' -Content $benchmarkEssentials -Needle '## Result-validity gate'
    Assert-Contains -Name 'runner-preflight.md' -Content $runnerPreflight -Needle 'SkipBenchmarksWithReports = true'
    Assert-Contains -Name 'runner-preflight.md' -Content $runnerPreflight -Needle 'Anti-thrashing rule'
    Assert-Contains -Name 'runner-preflight.md' -Content $runnerPreflight -Needle 'pwsh -NoProfile -File "<skill-root>/scripts/check-benchmark-requirements.ps1" -RepoRoot "<repo-root>" -BenchmarkType <Namespace.TypeBenchmark>'
    Assert-Contains -Name 'validate-skill.ps1' -Content $validateSkillScript -Needle 'if ([string]::IsNullOrWhiteSpace($SkillRoot))'
    Assert-Contains -Name 'validate-skill.ps1' -Content $validateSkillScript -Needle 'Harness detector validation requires pwsh 7+'
    Assert-Contains -Name 'comparison-benchmark.cs' -Content $comparison -Needle '{EQUIVALENCE_CHECK}'
    Assert-Contains -Name 'comparison-benchmark.cs' -Content $comparison -Needle 'Baseline = true'
    Assert-Contains -Name 'operation-benchmark.cs' -Content $operation -Needle 'Do not add Baseline = true merely to produce a ratio column.'
    Assert-NotContains -Name 'operation-benchmark.cs measured method' -Content ($operation -replace '// Do not add Baseline = true merely to produce a ratio column\.', '') -Needle 'Baseline = true'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'RouteMatcher.IsMatch'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'cannot prove whether file I/O or JSON parsing dominates'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'ThreadingDiagnoser'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'YOLO mode:'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'Acme.Core.ParserBenchmark-report-github.md'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'LegacyAliasQuery benchmark and summary'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'InMemoryTestStore benchmark'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'LowSelectivity, HalfMatches, and AllMatch'
    Assert-Contains -Name 'dotnet-benchmark/evals/evals.json' -Content $evals -Needle 'TraitFilter helper only runs in test discovery'
    if (@($fixtureFiles | Where-Object { $_ -match '(^|/)(obj|bin|BenchmarkDotNet\.Artifacts)(/|$)' }).Count -gt 0) {
        throw 'dotnet-benchmark eval fixtures must not include obj/, bin/, or BenchmarkDotNet.Artifacts paths'
    }
}

Add-ValidationResult -Results $results -Name 'Agent Smith protects informational and multi-target EditorConfig remediation' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/agent-smith/SKILL.md' -GitRef $Ref
    $reference = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/agent-smith/references/dotnet-editorconfig-conformance.md' -GitRef $Ref
    $skillAuthoring = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/agent-smith/references/skill-authoring.md' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/agent-smith/evals/evals.json' -GitRef $Ref
    $repair = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/agent-smith/scripts/repair-roslyn-multiproject-artifacts.ps1' -GitRef $Ref
    $repairTests = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/agent-smith/scripts/test-repair-roslyn-multiproject-artifacts.ps1' -GitRef $Ref

    Assert-Contains -Name 'agent-smith/SKILL.md' -Content $skill -Needle 'every discovery, investigation, retry, and final `dotnet format` command must include both `--severity info` and `--verify-no-changes`'
    Assert-Contains -Name 'agent-smith/SKILL.md' -Content $skill -Needle 'scripts/repair-roslyn-multiproject-artifacts.ps1'
    Assert-Contains -Name 'agent-smith/SKILL.md' -Content $skill -Needle 'Always analyze the task graph for safe parallelism and concurrency.'
    Assert-Contains -Name 'agent-smith/SKILL.md' -Content $skill -Needle '**Be concise. Sacrifice grammar for the sake of concision.**'
    Assert-Contains -Name 'skill-authoring.md' -Content $skillAuthoring -Needle 'Batch independent retrieval through one multi-call request where the tool supports it.'
    Assert-Contains -Name 'skill-authoring.md' -Content $skillAuthoring -Needle 'Choose C# and .NET by default for non-trivial reusable scripts'
    Assert-Contains -Name 'skill-authoring.md' -Content $skillAuthoring -Needle '## Required authoring feedback'
    Assert-Contains -Name 'skill-authoring.md' -Content $skillAuthoring -Needle 'Microsoft''s official .NET support policy'
    Assert-Contains -Name 'skill-authoring.md' -Content $skillAuthoring -Needle 'Optimizing skill descriptions'
    Assert-Contains -Name 'skill-authoring.md' -Content $skillAuthoring -Needle 'Evaluating skill output quality'
    Assert-Contains -Name 'dotnet-editorconfig-conformance.md' -Content $reference -Needle 'dotnet format style "<solution-or-project>"'
    Assert-Contains -Name 'dotnet-editorconfig-conformance.md' -Content $reference -Needle '`dotnet format` defaults to severity `warn`'
    Assert-Contains -Name 'dotnet-editorconfig-conformance.md' -Content $reference -Needle 'Directory application is all-or-nothing at preflight'
    Assert-Contains -Name 'dotnet-editorconfig-conformance.md' -Content $reference -Needle "git grep -n -F 'Unmerged change from project'"
    Assert-Contains -Name 'agent-smith/evals/evals.json' -Content $evals -Needle 'finish fixing all IDE0161 findings in MultiTargeted.sln'
    Assert-Contains -Name 'agent-smith/evals/evals.json' -Content $evals -Needle 'fetches twelve independent service endpoints sequentially'
    Assert-Contains -Name 'repair-roslyn-multiproject-artifacts.ps1' -Content $repair -Needle 'function Test-LinePrefix'
    Assert-Contains -Name 'repair-roslyn-multiproject-artifacts.ps1' -Content $repair -Needle "pattern = 'whole-document-namespace-conversion'"
    Assert-Contains -Name 'repair-roslyn-multiproject-artifacts.ps1' -Content $repair -Needle "pattern = 'unrecognized'"
    Assert-Contains -Name 'repair-roslyn-multiproject-artifacts.ps1' -Content $repair -Needle '$Apply -and -not $hasUnsafeArtifact'
    Assert-Contains -Name 'test-repair-roslyn-multiproject-artifacts.ps1' -Content $repairTests -Needle 'Directory apply partially repaired a file despite an unsafe sibling artifact.'
    Assert-Contains -Name 'test-repair-roslyn-multiproject-artifacts.ps1' -Content $repairTests -Needle 'An unsupported localized artifact should fail closed.'

    $repairTestPath = Join-Path $repoRoot 'skills/agent-smith/scripts/test-repair-roslyn-multiproject-artifacts.ps1'
    & pwsh -NoProfile -File $repairTestPath
    if ($LASTEXITCODE -ne 0) {
        throw "Agent Smith Roslyn multi-project artifact repair tests failed with exit code $LASTEXITCODE."
    }
}

Add-ValidationResult -Results $results -Name 'Strong-name skill matches FORMS summary flow and 1024-bit default' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/dotnet-strong-name-signing/SKILL.md' -GitRef $Ref
    Assert-Contains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'compute the defaults silently, and present a single summary for confirmation'
    Assert-Contains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'default: 1024'
    Assert-Contains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'Run this PowerShell command block with `pwsh` 7+ in the target directory:'
    Assert-NotContains -Name 'dotnet-strong-name-signing/SKILL.md' -Content $skill -Needle 'default: 4096'
}

Add-ValidationResult -Results $results -Name 'Git visual commits skill enforces subject, identity, and grouping locks' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/SKILL.md' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/evals/evals.json' -GitRef $Ref
    $commitLanguage = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/references/commit-language.md' -GitRef $Ref
    $subjectValidator = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/scripts/validate-commit-subject.ps1' -GitRef $Ref
    $subjectTests = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-visual-commits/scripts/test-commit-subject.ps1' -GitRef $Ref

    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'automatic trigger for this skill, not as a casual hint.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Full-Skill Read and Subject Lock'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Before running any Git command or composing a subject, read this `SKILL.md` completely from the first line through EOF.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If a tool truncates the file, continue from the first unread line until EOF before proceeding.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'The first visible character after the emoji and its single separator space must be lowercase.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'scripts/validate-commit-subject.ps1'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'The validator must exit successfully.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '`yolo` and `auto` do not bypass the full-read or subject-validation locks.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'run `scripts/validate-commit-subject.ps1` for every exact subject'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Run `scripts/validate-commit-subject.ps1` again against the exact subject that will be passed to Git.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'git log -1 --format=%s'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Identity Lock'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Never silently downgrade a requested `git bot commit` to `git commit`.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If the required `git bot` alias is unavailable, halt and report that exact blocker instead of falling back to human identity.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Direct Git Execution Rule'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'prefer direct shell or terminal execution of git commands over wrapper tools'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Fail-Fast Tool Validation'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Pivot immediately to a direct shell or terminal git path instead of retrying with the same broken wrapper.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Recovery Safety Rule'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Prefer non-destructive recovery first: targeted unstaging, precise re-staging, or `git stash`'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '`yolo` / `auto` skips user confirmation only.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If the user did **not** say `yolo` or `auto`, and session-level auto mode is not already enabled, do **not** run any commit command yet.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Commit Language Lock'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Resolve that path from this skill''s own bundled `references/` directory or installed skill folder first.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If the current repository has no `references/commit-language.md` file but the bundled skill reference is available, that is **not** a blocker.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Default to `<emoji> <short description>`.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Do not add a prefix after the emoji unless the user explicitly asked for a combo with conventional commits or conventional prefixes.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'After every commit, run:'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'git log -1 --format="%an <%ae>"'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'git log -1 --format=%B'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If the body contains literal escape sequences such as `\n` instead of real line breaks'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Do **not** hard-wrap commit bodies at 72 characters; keep short bodies as normal prose'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '### Umbrella Commit Rejection'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'skill instructions (`SKILL.md`, `FORMS.md`, `references/`, `evals/`)'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Read `references/commit-language.md` before choosing a prefix or emoji.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Treat `references/commit-language.md` as a bundled skill resource path, not as a repository-relative path.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'That reference now defines prefixes as opt-in.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Treat community health, changelog, and release-status communication as'
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
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**Dependency/version baselines**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**Package/publish metadata**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**Documentation publishing**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**Community health/release communication**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Temporal proximity is not a grouping signal.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '#### Release-adjacent splitting rule'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Concrete example: if one diff updates `Directory.Build.targets`, `Directory.Packages.props`, or `testenvironments.json`,'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'Keep `.nuget/*/PackageReleaseNotes.txt` with the'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'The rule is the abstraction: split by purpose and audience, not by the fact that the changes landed together.'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'do not collapse "new skill introduced" and "existing skill refactored" into one commit'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle '**New repo-managed skill**'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'a newly introduced `skills/<name>/` folder and its local `evals/` or `references/`'
    Assert-Contains -Name 'git-visual-commits/SKILL.md' -Content $skill -Needle 'If a commit both introduces a brand-new skill and refactors an existing skill to support it, prefer separate commits.'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle '### Allowed Prefixes'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle '### Emoji Selection'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle 'Gitmoji First, Fallback Second'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle '#### Fallback: Extended Emoji Reference'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle 'Community health, changelog, release-status communication'
    Assert-Contains -Name 'git-visual-commits/references/commit-language.md' -Content $commitLanguage -Needle 'package release-note metadata'

    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle "[ValidateSet('Forbidden', 'Required')]"
    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle '[System.Globalization.StringInfo]::ParseCombiningCharacters($Subject).Count'
    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle 'Use exactly one ASCII space between the emoji and the following text.'
    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle "elseif (`$description -cnotmatch '^\p{Ll}')"
    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle 'is not an approved entry in the bundled commit-language reference.'
    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle '$maxLength = 70'
    Assert-Contains -Name 'git-visual-commits/scripts/validate-commit-subject.ps1' -Content $subjectValidator -Needle 'the maximum is $maxLength.'
    Assert-Contains -Name 'git-visual-commits/scripts/test-commit-subject.ps1' -Content $subjectTests -Needle 'reported screenshot regression'
    Assert-Contains -Name 'git-visual-commits/scripts/test-commit-subject.ps1' -Content $subjectTests -Needle '💬 Update changelog'
    Assert-Contains -Name 'git-visual-commits/scripts/test-commit-subject.ps1' -Content $subjectTests -Needle '💬  update changelog'
    Assert-Contains -Name 'git-visual-commits/scripts/test-commit-subject.ps1' -Content $subjectTests -Needle '📋 Update CHANGELOG for v10.0.10'

    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not let yolo collapse multiple semantic intents into one umbrella commit'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Verifies the commit author after commit and confirms it matches bot identity'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Verifies the stored commit body does not contain literal \\n escape sequences'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not hard-wrap a short commit body mid-sentence just to satisfy a column limit'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'stops with a clear alias-missing error instead of silently falling back to human identity'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Treats a newly introduced skill folder as a separate repo capability intent'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Separates new skill introduction from existing skill refactor work'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not use same-round timing as a reason to merge everything into one commit'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'community health or changelog commit based on commit-language.md instead of a generic docs emoji'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Presents the grouping as high-level semantic intents rather than a brittle filename-only rule'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Treats a wrong-author first attempt as a tool-path failure instead of retrying multiple times with the same wrapper'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Prefers non-destructive recovery such as inspecting git state or using stash before broad restore or reset commands'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not add conventional prefixes after the emoji when the user did not explicitly ask for that combo'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Classifies an existing skill wording or contract reorganization as refactor intent instead of guessing new-feature or configuration intent'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Treats emoji plus conventional-prefix formatting as opt-in rather than default'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Treats the absence of yolo or auto as a requirement to stop for approval before any commit command runs'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Separates .nuget package release notes into the package or publish metadata commit'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'package release notes or package metadata work instead of the community-health emoji'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Treats references/commit-language.md as a bundled skill resource rather than a repo-root path by default'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Does not report a blocker solely because the current repository lacks a top-level references directory'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Reads SKILL.md completely through EOF before any staging or commit command'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Rejects the proposed subject because 📋 is absent from the approved commit-language table'
    Assert-Contains -Name 'git-visual-commits/evals/evals.json' -Content $evals -Needle 'Runs scripts/validate-commit-subject.ps1 before showing the corrected subject and again immediately before passing it to Git'
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
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Read `references/commit-language.md` before choosing any emoji or optional prefix.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Default to emoji plus description only.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Favor readable GitHub and terminal output over cleverness.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Do not treat the result as a changelog entry or a dump of commit subjects.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Return grouped lines only, never a title or body.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Keep every output line at or below 72 characters.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Do not invent unsupported changes.'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'A bare invocation such as `git-visual-squash-summary` or `/git-visual-squash-summary` is itself a complete request'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'Do not open with "What would you like me to summarize?"'
    Assert-Contains -Name 'git-visual-squash-summary/SKILL.md' -Content $skill -Needle 'If a retained line is mainly changelog, community-health, or release-status communication, prefer'
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
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Defaults to emoji plus description lines without adding conventional prefixes'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'If a retained line is mainly changelog or release-status communication, prefers'
    Assert-Contains -Name 'git-visual-squash-summary/evals/evals.json' -Content $evals -Needle 'Treats a bare skill invocation as a complete request to summarize the current branch'
}

Add-ValidationResult -Results $results -Name 'Git keep a changelog skill updates CHANGELOG.md from git history' -Action {
    $skill = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/SKILL.md' -GitRef $Ref
    $forms = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/FORMS.md' -GitRef $Ref
    $evals = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/evals/evals.json' -GitRef $Ref
    $scopeResolver = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/scripts/resolve-release-scope.ps1' -GitRef $Ref
    $scopeResolverTests = Get-FileText -RepoRoot $repoRoot -RelativePath 'skills/git-keep-a-changelog/scripts/test-resolve-release-scope.ps1' -GitRef $Ref

    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Create or update `CHANGELOG.md` directly, then stop for user review.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'If `CHANGELOG.md` does not exist, create a compliant one before'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Read full commit subjects and bodies before writing the changelog.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'If the current branch starts with a version hint such as `v0.3.0/`,'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Otherwise, target `## [Unreleased]`.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Always write a release highlight immediately below the target heading.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'The release highlight must explicitly classify the release as `major`,'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle '## Mandatory Checkpoints'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'These checkpoints cannot be skipped or bypassed'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle '## User Intent vs. Mandatory Gates'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'The Step 3 confirmation gate exists to prevent silent inclusion'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Use the standard Keep a Changelog section order:'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Preserve natural line breaks and readable prose. Do not apply any fixed'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'End each bullet with `,` and end the last bullet in each section with'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle '### Step 3: Confirm Pending Worktree Changes (MANDATORY GATE)'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'This is a required checkpoint. Do not proceed to Step 4 until this step is complete.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'you must ask a direct confirmation question before drafting the changelog entry.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Do not skip this question.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Wait for the user''s explicit response before proceeding to Step 4.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle '### Step 3b: Verify Release Isolation'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Require `base_history_bleed` to be `false`.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Do not append `^` or widen either range for a concrete release.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'The comparison boundary is always excluded from a branch-derived release'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Yolo/auto changes pending-worktree handling only.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Do not dump commit subjects verbatim into the changelog.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'If `CHANGELOG.md` is missing, create it with the standard title,'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Always maintain the Keep a Changelog compare-link footer at the bottom of the file.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'On every edit, verify that the compare-link footer exists at the bottom of the file.'
    Assert-Contains -Name 'git-keep-a-changelog/SKILL.md' -Content $skill -Needle 'Do not commit, tag, push, or create a release unless the user asks.'

    Assert-Contains -Name 'git-keep-a-changelog/FORMS.md' -Content $forms -Needle 'This is the mandatory Step 3 confirmation gate for concrete releases.'
    Assert-Contains -Name 'git-keep-a-changelog/FORMS.md' -Content $forms -Needle 'I found pending changes not yet committed for release `{release_label}`: `{staged_count}` staged, `{unstaged_count}` unstaged, `{untracked_count}` untracked. Include them in the changelog draft? Yes / No / Custom'
    Assert-Contains -Name 'git-keep-a-changelog/FORMS.md' -Content $forms -Needle 'Do not skip this gate when the target is a concrete release'

    Assert-Contains -Name 'git-keep-a-changelog/scripts/resolve-release-scope.ps1' -Content $scopeResolver -Needle '$historyRange = "$baseCommit..$headCommit"'
    Assert-Contains -Name 'git-keep-a-changelog/scripts/resolve-release-scope.ps1' -Content $scopeResolver -Needle '$diffRange = "$mergeBase..$headCommit"'
    Assert-Contains -Name 'git-keep-a-changelog/scripts/resolve-release-scope.ps1' -Content $scopeResolver -Needle 'base_history_bleed = $false'
    Assert-Contains -Name 'git-keep-a-changelog/scripts/test-resolve-release-scope.ps1' -Content $scopeResolverTests -Needle 'the tagged previous release bled into the new release scope'

    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Updates CHANGELOG.md directly instead of only drafting notes in chat'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Reads full commit subjects and bodies before writing the release entry'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Treats a leading branch version such as v0.3.0/ as a release hint'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Uses full commit bodies rather than relying on subject lines alone'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Preserves natural prose wrapping instead of forcing any fixed column width'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Ends bullets with commas and ends the final bullet in each section with a period'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Creates CHANGELOG.md when it does not already exist'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Treats the pending-worktree question as a mandatory gate before Step 4 for a concrete release'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Does not let user intent bypass the mandatory pending-worktree confirmation gate for a concrete release'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Inserts the compare-link footer at the bottom when it is missing from an existing changelog'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Treats the merge-base as an excluded boundary rather than the first commit of the concrete release'
    Assert-Contains -Name 'git-keep-a-changelog/evals/evals.json' -Content $evals -Needle 'Does not let yolo mode widen committed history or include the v10.0.9 boundary commit'

    if ([string]::IsNullOrWhiteSpace($Ref)) {
        & (Join-Path $repoRoot 'skills/git-keep-a-changelog/scripts/test-resolve-release-scope.ps1') | Out-Null
    }
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
        $buildRequests = [System.Collections.Generic.List[object]]::new()

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

            [void]$buildRequests.Add([pscustomobject]@{
                CaseName = $case.Name
                ProjectPaths = @($projectPath, $testProjectPath)
            })
        }

        foreach ($buildFailure in @(Invoke-DotNetBuildsForValidation -BuildRequests @($buildRequests))) {
            if (-not [string]::IsNullOrWhiteSpace($buildFailure)) {
                $failures.Add($buildFailure)
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

if ($Full) {
    $docfxScriptResults = Invoke-ValidationScriptJobs -Scripts @(
        [pscustomobject]@{
            Name = 'DocFX digest rejects metadata scaffolds and accepts scenario-led documentation'
            Path = Join-Path $repoRoot 'skills/dotnet-docfx-digest/scripts/test-quality.ps1'
        }
        [pscustomobject]@{
            Name = 'DocFX digest project-scoped packets, dry run, families, and overwrite writer behave deterministically'
            Path = Join-Path $repoRoot 'skills/dotnet-docfx-digest/scripts/test-project-scoped.ps1'
        }
    )

    foreach ($docfxScriptResult in $docfxScriptResults) {
        if ($docfxScriptResult.ExitCode -eq 0) {
            $results.Add([pscustomobject]@{
                Name = $docfxScriptResult.Name
                Status = 'PASS'
                Details = ''
            })
            Write-Host ("[PASS] {0} ({1:n1}s)" -f $docfxScriptResult.Name, $docfxScriptResult.ElapsedSeconds)
        } else {
            $results.Add([pscustomobject]@{
                Name = $docfxScriptResult.Name
                Status = 'FAIL'
                Details = $docfxScriptResult.Output
            })
            Write-Host ("[FAIL] {0} ({1:n1}s)" -f $docfxScriptResult.Name, $docfxScriptResult.ElapsedSeconds)
        }
    }
} else {
    Write-Host '[SKIP] DocFX digest regression suites (use -Full to run skills/dotnet-docfx-digest/scripts/test-quality.ps1 and test-project-scoped.ps1)'
}

$passed = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$label = if ([string]::IsNullOrWhiteSpace($Ref)) { 'WORKTREE' } else { $Ref }
$mode = if ($Full) { 'FULL' } else { 'FAST' }

Write-Host ("Validation target: {0}" -f $label)
Write-Host ("Validation mode: {0}" -f $mode)
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
