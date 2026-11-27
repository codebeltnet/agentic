function Get-EvalDependencyTreeHash {
    param([Parameter(Mandatory)][string]$Root)

    $entries = foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Dependency contains an unsupported link: $($item.FullName)" }
        if ($item.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
        "$relative`:$(Get-Sha256HexFromFile -Path $item.FullName)"
    }
    Get-Sha256HexFromBytes -Bytes ([Text.Encoding]::UTF8.GetBytes((@($entries | Sort-Object) -join "`n")))
}

function Assert-EvalStagedDependencies {
    param([string]$RunRoot, [object]$Contract)

    $requirements = Get-JsonProperty -Object $Contract -Name 'prerequisites'
    if ($null -eq $requirements) { return }
    $expected = [Collections.Generic.List[string]]::new()
    $candidate = [string](Get-JsonProperty -Object $Contract -Name 'skillDirectory' -Default '')
    if ($candidate -like 'dependencies/*') { $expected.Add($candidate) }
    foreach ($dependency in @(Get-JsonProperty -Object $requirements -Name 'skills' -Default @())) {
        if ($dependency.path -notmatch '^dependencies/[a-z0-9][a-z0-9-]*$' -or
            $dependency.path -eq ('dependencies/' + $Contract.candidateSkillName) -or $expected.Contains($dependency.path)) {
            throw "Invalid staged skill prerequisite '$($dependency.path)'."
        }
        $expected.Add($dependency.path)
        $path = Resolve-ContainedPath -BasePath $RunRoot -RelativePath $dependency.path -FieldName 'skill prerequisite' -Kind Directory
        if ((Get-EvalDependencyTreeHash -Root $path) -ne $dependency.sha256) { throw "Staged skill prerequisite hash mismatch: $($dependency.path)" }
    }
    foreach ($asset in @(Get-JsonProperty -Object $requirements -Name 'downloads' -Default @())) {
        if ($asset.path -notmatch '^dependencies/tools/[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid staged file prerequisite '$($asset.path)'." }
        $path = Resolve-ContainedPath -BasePath $RunRoot -RelativePath $asset.path -FieldName 'file prerequisite' -Kind File
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-Sha256HexFromFile -Path $path) -ne $asset.sha256) {
            throw "Staged file prerequisite hash mismatch: $($asset.path)"
        }
    }
    $dependencyRoot = Join-Path $RunRoot 'dependencies'
    if (Test-Path -LiteralPath $dependencyRoot) {
        if ((Get-Item -LiteralPath $dependencyRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Staged dependencies must be ordinary directories.' }
        foreach ($item in Get-ChildItem -LiteralPath $dependencyRoot -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or (-not $item.PSIsContainer) -or
                ($item.Name -ne 'tools' -and -not $expected.Contains("dependencies/$($item.Name)"))) {
                throw "Undeclared staged dependency '$($item.Name)'."
            }
            if ($item.Name -eq 'tools') {
                $downloadPaths = @(Get-JsonProperty -Object $requirements -Name 'downloads' -Default @() | ForEach-Object path)
                foreach ($tool in Get-ChildItem -LiteralPath $item.FullName -Force) {
                    if ($tool.PSIsContainer -or "dependencies/tools/$($tool.Name)" -cnotin $downloadPaths) { throw "Undeclared staged tool '$($tool.Name)'." }
                }
            }
        }
    }
}

function Get-EvalReadinessProbes {
    param([Parameter(Mandatory)][object]$Run)

    $requirements = Get-JsonProperty -Object $Run.Contract -Name 'prerequisites'
    $environment = New-RunnerShellEnvironment -Run $Run
    $pairs = foreach ($key in $environment.Keys) {
        if ($key -in @('PATH', 'PATHEXT')) { continue }
        "'{0}'='{1}'" -f $key, ([string]$environment[$key]).Replace("'", "''")
    }
    $environmentCheck = @'
$expected = @{ ENVIRONMENT_PAIRS }
foreach ($name in $expected.Keys) {
    if ([Environment]::GetEnvironmentVariable($name) -cne $expected[$name]) { throw "Missing or unexpected environment value: $name" }
}
foreach ($name in 'OPENAI_API_KEY', 'CODEX_API_KEY', 'ANTHROPIC_API_KEY', 'GH_TOKEN', 'GITHUB_TOKEN', 'CODEX_HOME', 'NODE_PATH') {
    if ([Environment]::GetEnvironmentVariable($name)) { throw "Unexpected shell variable: $name" }
}
foreach ($path in ($env:PATH -split [IO.Path]::PathSeparator)) {
    if (-not [IO.Path]::IsPathFullyQualified($path)) { throw "PATH contains a relative or empty entry: $path" }
}
if ($IsWindows -and @('.EXE', '.CMD' | Where-Object { $_ -notin ($env:PATHEXT -split ';') }).Count -gt 0) { throw 'PATHEXT cannot discover Windows executables.' }
if ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath()) -ne $env:TEMP) { throw 'OS temporary directory differs from the isolated TEMP path.' }
'@
    # PowerShell uses the Unix temp API, which reads TMPDIR, and the Windows
    # temp API, which reads TMP/TEMP. All three point to the same directory.
    [ordered]@{
        id = 'isolated-shell-environment'
        script = $environmentCheck.Replace('ENVIRONMENT_PAIRS', ($pairs -join '; '))
        command = @('pwsh', '-NoProfile', '-NonInteractive', '-Command', '<verify isolated environment>')
        expected = ''
        timeoutMs = 8000
    }

    foreach ($probe in @(Get-JsonProperty -Object $requirements -Name 'probes' -Default @())) {
        $id = [string]$probe.id
        $command = @($probe.command | ForEach-Object { ([string]$_).Replace('{run}', $Run.RunRoot) })
        $executables = @(Get-JsonProperty -Object $requirements -Name 'executables' -Default @())
        if ($id -notmatch '^[a-z0-9][a-z0-9-]*$' -or $command.Count -eq 0 -or $command[0] -notin $executables) {
            throw "Invalid readiness probe '$id'. The executable must be declared in prerequisites.executables."
        }
        $match = [string](Get-JsonProperty -Object $probe -Name 'outputPattern' -Default '')
        if ($match) { [void][regex]::new($match, [Text.RegularExpressions.RegexOptions]::Multiline, [TimeSpan]::FromSeconds(1)) }
        $timeoutMs = [int](Get-JsonProperty -Object $probe -Name 'timeoutMs' -Default 10000)
        if ($timeoutMs -lt 1 -or $timeoutMs -gt 90000) { throw "Invalid timeoutMs for readiness probe '$id'." }
        $quoted = @($command | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
        [ordered]@{
            id = $id
            script = '$ErrorActionPreference = "Stop"; & ' + ($quoted -join ' ') + '; exit $LASTEXITCODE'
            command = $command
            expected = $match
            timeoutMs = $timeoutMs
        }
    }
}

function New-EvalReadinessObservation {
    param([Parameter(Mandatory)][object]$Probe, [object]$Response)

    $result = Get-JsonProperty -Object $Response -Name 'result'
    $exit = Get-JsonProperty -Object $result -Name 'exitCode'
    $stdout = [string](Get-JsonProperty -Object $result -Name 'stdout')
    $stderr = [string](Get-JsonProperty -Object $result -Name 'stderr')
    $matched = -not $Probe.expected -or [regex]::IsMatch($stdout, $Probe.expected, [Text.RegularExpressions.RegexOptions]::Multiline, [TimeSpan]::FromSeconds(1))
    $passed = $null -ne $exit -and $exit -eq 0 -and $matched
    $diagnostic = if ($null -eq $exit) {
        'No exit status from the native command transport. Verify runner command/exec support.'
    } elseif ($exit -ne 0) {
        if ($stderr) { $stderr.Trim() } else { $stdout.Trim() }
    } elseif (-not $matched) {
        "Output did not match $($Probe.expected). Observed: $($stdout.Trim())"
    } else {
        $stdout.Trim()
    }
    [ordered]@{
        id = $Probe.id
        command = @($Probe.command)
        exit_code = $exit
        status = if ($passed) { 'ready' } else { 'infrastructure_blocked' }
        diagnostic = $diagnostic.Substring(0, [Math]::Min($diagnostic.Length, 2000))
    }
}

function Get-ObservedSkillReferenceReads {
    param([object[]]$Commands, [string]$SkillRoot)

    if (-not $SkillRoot -or -not (Test-Path -LiteralPath (Join-Path $SkillRoot 'references') -PathType Container)) { return }
    foreach ($resource in Get-ChildItem -LiteralPath (Join-Path $SkillRoot 'references') -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($SkillRoot, $resource.FullName).Replace('\', '/')
        $pathPattern = '(?i)(?:^|[/\s''"])' + [regex]::Escape($relative) + '(?=$|[\s''";|)])'
        foreach ($command in $Commands) {
            $text = ([string](Get-JsonProperty -Object $command -Name 'command')).Replace('\', '/')
            if ((Get-JsonProperty -Object $command -Name 'exit_code') -eq 0 -and
                (Get-JsonProperty -Object $command -Name 'output_bytes' -Default 0) -gt 0 -and
                $text -match '(?i)\b(Get-Content|cat|sed|head|tail|bat|gc|type)\b[^;|\r\n]*' -and
                $Matches[0] -match $pathPattern) {
                $relative
                break
            }
        }
    }
}
