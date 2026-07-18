<#
.SYNOPSIS
    Detects missing shared scaffold assets (including dotfiles) and restores them
    directly from the upstream repository.

.DESCRIPTION
    Reads assets/shared.manifest.json, checks each required path relative to the
    skill root, and downloads any missing file from the authoritative GitHub source.
    Exits with code 1 if upstream fetch fails for any file.

.PARAMETER SkillRoot
    Absolute path to the installed skill directory (parent of assets/).
    Defaults to the directory containing this script's parent.

.PARAMETER DryRun
    Report missing files without downloading them.

.EXAMPLE
    # Restore missing files into the installed skill copy
    pwsh -NoProfile -File <skill-root>/scripts/restore-missing-shared-assets.ps1

    # Preview what is missing without restoring
    pwsh -NoProfile -File <skill-root>/scripts/restore-missing-shared-assets.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $SkillRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $SkillRoot 'assets/shared.manifest.json'
if (-not (Test-Path $manifestPath)) {
    Write-Error "Manifest not found at: $manifestPath"
    exit 1
}

$manifest    = Get-Content $manifestPath -Raw | ConvertFrom-Json
$repoUrl     = $manifest.upstream.repo      # e.g. https://github.com/codebeltnet/agentic
$branch      = $manifest.upstream.branch    # e.g. main
$remoteRoot  = $manifest.upstream.root      # e.g. skills/dotnet-new-app-slnx/assets/shared
$localRoot   = Join-Path $SkillRoot 'assets/shared'

# Build raw-content base URL
$rawBase = $repoUrl -replace 'https://github.com', 'https://raw.githubusercontent.com'
$rawBase = "$rawBase/$branch/$remoteRoot"

$missing  = [System.Collections.Generic.List[string]]::new()
$restored = [System.Collections.Generic.List[string]]::new()
$failed   = [System.Collections.Generic.List[string]]::new()

foreach ($file in $manifest.files) {
    $localPath = Join-Path $localRoot $file
    if (-not (Test-Path $localPath)) {
        $missing.Add($file)
    }
}

if ($missing.Count -eq 0) {
    Write-Host "✅ All shared assets present — nothing to restore." -ForegroundColor Green
    exit 0
}

Write-Host "⚠️  Missing shared assets ($($missing.Count)):" -ForegroundColor Yellow
$missing | ForEach-Object { Write-Host "   - $_" }

if ($DryRun) {
    Write-Host "`n[DryRun] No files downloaded." -ForegroundColor Cyan
    exit 0
}

Write-Host "`nRestoring from upstream: $repoUrl (branch: $branch)" -ForegroundColor Cyan

foreach ($file in $missing) {
    $url       = "$rawBase/$file"
    $dest      = Join-Path $localRoot $file
    $destDir   = Split-Path $dest -Parent

    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    try {
        Write-Host "  ↓ $file" -NoNewline
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        $restored.Add($file)
        Write-Host " ✓" -ForegroundColor Green
    }
    catch {
        $failed.Add($file)
        Write-Host " ✗ ($($_.Exception.Message))" -ForegroundColor Red
    }
}

if ($restored.Count -gt 0) {
    Write-Host "`n✅ Restored $($restored.Count) file(s)." -ForegroundColor Green
}

if ($failed.Count -gt 0) {
    Write-Host "❌ Failed to restore $($failed.Count) file(s):" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "   - $_" }
    exit 1
}
