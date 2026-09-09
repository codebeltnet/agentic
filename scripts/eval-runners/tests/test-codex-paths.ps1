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
$names = @('ConvertTo-CodexConfigStringLiteral', 'Get-CodexSanitizedShellPath', 'Get-CodexShellEnvironmentPolicySet', 'Add-CodexShellEnvironmentPolicyConfigArguments', 'ConvertTo-CodexComparablePath', 'ConvertTo-CodexComparableText', 'Get-CodexAmbientSkillRoot', 'Test-CodexTextReferencesRoot', 'Test-CodexPathInsideComparableRoot', 'Update-CodexNativeSkillRuntimeAccessEvidence')
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

$windowsGit = 'C:\Program Files\Git\cmd'
$windowsPath = Get-CodexSanitizedShellPath -Platform windows -GitDirectory $windowsGit -WindowsRoot 'C:\Windows'
if ($windowsPath -cne "C:\Windows\System32;$windowsGit") { throw "Windows sanitized PATH was '$windowsPath'." }
if ($windowsPath -match [regex]::Escape('C:\host-only\bin')) { throw 'Windows sanitized PATH exposed an arbitrary host-only directory.' }
$linuxPath = Get-CodexSanitizedShellPath -Platform linux -GitDirectory '/opt/git/bin'
if ($linuxPath -cne '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/git/bin') { throw "Linux sanitized PATH was '$linuxPath'." }
$macPath = Get-CodexSanitizedShellPath -Platform macos -GitDirectory '/usr/bin'
if ($macPath -cne '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin') { throw "macOS sanitized PATH should deduplicate /usr/bin but was '$macPath'." }
$configArgs = [System.Collections.Generic.List[string]]::new()
Add-CodexShellEnvironmentPolicyConfigArguments -Arguments $configArgs -ShellEnvironmentSet ([ordered]@{ PATH = $windowsPath; SystemRoot = 'C:\Windows'; ComSpec = 'C:\Windows\System32\cmd.exe'; PATHEXT = '.COM;.EXE;.BAT;.CMD' }) -SwitchName '--config'
if (@($configArgs | Where-Object { $_ -eq 'shell_environment_policy.inherit=none' }).Count -ne 1) { throw 'Codex config args must keep shell environment inheritance disabled.' }
if (@($configArgs | Where-Object { $_ -eq ('shell_environment_policy.set.PATH="' + $windowsPath.Replace('\', '\\') + '"') }).Count -ne 1) { throw 'Codex config args must set the sanitized child PATH.' }

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
