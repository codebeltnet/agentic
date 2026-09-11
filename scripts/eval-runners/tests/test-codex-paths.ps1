[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../runner-common.ps1')

# Load only the path/evidence functions; never start the authenticated adapter.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../codex/runner.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Codex runner did not parse.' }
$names = @('ConvertTo-CodexComparablePath', 'ConvertTo-CodexComparableText', 'Get-CodexAmbientSkillRoot', 'Test-CodexTextReferencesRoot', 'Test-CodexPathInsideComparableRoot', 'Update-CodexNativeSkillRuntimeAccessEvidence')
foreach ($name in $names) {
    $definition = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definition.Count -ne 1) { throw "Missing unique function '$name'." }
    Invoke-Expression $definition[0].Extent.Text
}

$ambient = Join-Path ([IO.Path]::GetTempPath()) 'ambient user/.agents/skills/candidate/SKILL.md'
$staged = Join-Path ([IO.Path]::GetTempPath()) 'isolated-run/skill/candidate'
$comparable = ConvertTo-CodexComparablePath $ambient
if ((ConvertTo-CodexComparablePath $comparable) -cne $comparable) { throw 'Path normalization must be idempotent.' }
if (-not (Test-CodexPathInsideComparableRoot $staged (Join-Path $staged 'FORMS.md'))) { throw 'Staged descendants must remain inside their root.' }
if (Test-CodexPathInsideComparableRoot $staged ($staged + '-other/FORMS.md')) { throw 'A sibling prefix is not a descendant.' }

if ($IsWindows) {
    Add-Type -Namespace AgenticPathTests -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetShortPathName(string path, System.Text.StringBuilder buffer, uint size);
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathName(string path, System.Text.StringBuilder buffer, uint size);
'@
    # TEMP itself can contain a short user-profile component. Derive the
    # expected long spelling with Win32, independently of the helper under test.
    $buffer = [Text.StringBuilder]::new(32768)
    $length = [AgenticPathTests.Native]::GetLongPathName([IO.Path]::GetTempPath(), $buffer, $buffer.Capacity)
    if ($length -eq 0 -or $length -ge $buffer.Capacity) { throw 'Cannot resolve the temporary directory long path.' }
    $tempRoot = $buffer.ToString().TrimEnd('\', '/')
    $pathRoot = Join-Path $tempRoot ('agentic-paths-' + [guid]::NewGuid().ToString('N'))
    try {
        $directory = [IO.Directory]::CreateDirectory((Join-Path $pathRoot 'long directory [literal] æ')).FullName
        $file = Join-Path $directory 'long filename [literal].json'
        [IO.File]::WriteAllText($file, '{}')
        $missing = Join-Path $directory 'missing parent/child/file.json'
        foreach ($path in @($directory, $file, $missing, [IO.Path]::GetPathRoot($directory))) {
            if ((Expand-WindowsShortPath $path) -cne [IO.Path]::GetFullPath($path)) { throw "Long path spelling changed: $path" }
        }
        if ((Expand-WindowsShortPath (Join-Path $directory '../long directory [literal] æ')) -cne $directory) { throw 'Relative components must normalize.' }

        $shortCases = 0
        foreach ($path in @($directory, $file, $env:ProgramFiles)) {
            $buffer = [Text.StringBuilder]::new(32768)
            $length = [AgenticPathTests.Native]::GetShortPathName($path, $buffer, $buffer.Capacity)
            if ($length -eq 0 -or $length -ge $buffer.Capacity) { throw "Cannot query short path: $path" }
            $short = $buffer.ToString()
            if ($short -ieq $path) { continue } # Volumes may have 8.3 creation disabled.
            if (-not (Test-ExactObservedPath -Expected $path -Observed $short)) { throw "Short path must match its long spelling: $short" }
            if ([IO.Directory]::Exists($path)) {
                $suffix = 'missing parent/child/file.json'
                if (-not (Test-ExactObservedPath -Expected (Join-Path $path $suffix) -Observed (Join-Path $short $suffix))) { throw 'A missing tail must retain expansion of its existing short parent.' }
            }
            $shortCases++
        }
        Write-Output "Windows path compatibility: PASS; $shortCases native short-path cases"
    } finally {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($pathRoot)) -ne $tempRoot) { throw 'Path fixture cleanup must stay under the temporary directory.' }
        if (Test-Path -LiteralPath $pathRoot) { Remove-Item -LiteralPath $pathRoot -Recurse -Force }
    }
}

foreach ($access in @('command', 'file')) {
    $isolation = [ordered]@{ ambient_skill_paths_observed = @($ambient); failures = @() }
    $parameters = @{ NativeSkillIsolation = $isolation; AllowedStagedSkillRoot = $staged }
    if ($access -eq 'command') {
        $parameters.Commands = @(@{ command = "Get-Content -Raw '$ambient'"; status = 'completed'; exit_code = 0 })
    } else {
        $parameters.Files = @(@{ type = 'file_change'; changes = @(@{ path = $ambient }) })
    }
    $result = Update-CodexNativeSkillRuntimeAccessEvidence @parameters
    if ($result.Evidence.failures -notcontains 'ambient_skill_access_detected') { throw "Ambient $access access must fail closed." }
}
$isolation = [ordered]@{ ambient_skill_paths_observed = @($ambient, (Join-Path $staged 'SKILL.md')); failures = @() }
$result = Update-CodexNativeSkillRuntimeAccessEvidence -NativeSkillIsolation $isolation -AllowedStagedSkillRoot $staged -Commands @(@{ command = "Get-Content '$(Join-Path $staged 'FORMS.md')'" })
if ($result.Evidence.ambient_skill_accesses_detected.Count -ne 0) { throw 'Staged candidate access must remain allowed.' }
Write-Output 'Codex path isolation: PASS'
