Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PackageTreeIntegrity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Force | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $file.FullName).Replace('\', '/')
        $entries.Add("$relative`:$(Get-Sha256HexFromFile -Path $file.FullName)")
    }
    $joined = [string]::Join("`n", @($entries | Sort-Object))
    return [pscustomobject]@{
        Path = $resolvedRoot
        FileCount = $entries.Count
        Sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($joined))
    }
}

function Assert-PackageRunnerToolsIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $declared = Get-JsonProperty -Object $Manifest -Name 'runner_tools_integrity' -Default $null
    if ($null -eq $declared -or [string](Get-JsonProperty -Object $declared -Name 'schema' -Default '') -ne 'codebeltnet/agentic/package-tree-integrity/1') {
        throw 'manifest.json does not declare the versioned package-local Eval Runner tool integrity record.'
    }
    $runnerToolsRelative = [string](Get-JsonProperty -Object $Manifest -Name 'runner_tools' -Default '')
    $declaredPath = [string](Get-JsonProperty -Object $declared -Name 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace($runnerToolsRelative) -or $declaredPath -ne $runnerToolsRelative) {
        throw 'manifest.runner_tools_integrity.path does not match manifest.runner_tools.'
    }
    $runnerToolsPath = Resolve-ContainedPath -BasePath $IterationDirectory -RelativePath $runnerToolsRelative -FieldName 'runner_tools' -Kind Directory
    $actual = Get-PackageTreeIntegrity -Root $runnerToolsPath
    $declaredHash = [string](Get-JsonProperty -Object $declared -Name 'sha256' -Default '')
    $declaredCount = [int](Get-JsonProperty -Object $declared -Name 'file_count' -Default -1)
    if ($declaredHash -ne [string]$actual.Sha256 -or $declaredCount -ne [int]$actual.FileCount) {
        throw "Package-local Eval Runner tools changed after preparation (expected hash $declaredHash/$declaredCount files, found $($actual.Sha256)/$($actual.FileCount) files). Requires a fresh package."
    }
    return $actual
}
