[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflow = [IO.File]::ReadAllText((Join-Path $repoRoot '.github/workflows/validate-skill-templates.yml'))
$entries = @([regex]::Matches($workflow, '\{ name: (?<name>[\w-]+), script: (?<script>[\w/.-]+), suite: (?<suite>\w+) \}') | ForEach-Object {
    [pscustomobject]@{ Name = $_.Groups['name'].Value; Script = $_.Groups['script'].Value; Suite = $_.Groups['suite'].Value }
})
if ($entries.Count -eq 0) { throw 'The CI validation matrix has no literal suite entries.' }
if (@($entries.Name | Sort-Object -Unique).Count -ne $entries.Count) { throw 'CI suite names must be unique.' }

foreach ($script in @('scripts/validate-skill-templates.ps1', 'scripts/eval-runners/tests/test-runner-conformance.ps1', 'scripts/eval-runners/tests/test-integrity-finalization.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $script), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Cannot parse '$script'." }
    $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Suite' })[0]
    $attribute = @($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0]
    $expected = @($attribute.PositionalArguments | ForEach-Object { $_.SafeGetValue() } | Where-Object { $_ -ne 'All' })
    if ($script -eq 'scripts/validate-skill-templates.ps1') {
        # These two aggregate groups are expanded into their own test suites.
        $expected = @($expected | Where-Object { $_ -notin @('Conformance', 'Integrity') })
        $groups = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-ValidationResult' }, $true) | ForEach-Object {
            $elements = $_.CommandElements
            for ($index = 0; $index -lt $elements.Count; $index++) {
                if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -eq 'Group') { $elements[$index + 1].SafeGetValue() }
            }
        })
        foreach ($group in $groups) {
            if ($group -notin @($expected + 'Conformance' + 'Integrity')) { throw "Unscheduled validation group '$group'." }
        }
    }
    $actual = @($entries | Where-Object Script -eq $script | ForEach-Object Suite)
    if (@(Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)).Count) { throw "CI does not schedule every suite exactly once for '$script'." }
}
if ($workflow -notmatch '(?m)^  validate-skill-templates:' -or $workflow -notmatch 'needs: validate' -or $workflow -notmatch "VALIDATION_RESULT -ne 'success'") { throw 'The required aggregate check must reject failed, skipped, or cancelled suites.' }
Write-Output 'CI suite coverage: PASS'
