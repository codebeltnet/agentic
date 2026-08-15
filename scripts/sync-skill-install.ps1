param(
    [string[]]$Skill,
    [switch]$VerifyOnly,
    [switch]$Prune
)

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# Build output is regenerated per location, so its hashes never match across installs. Comparing it
# would bury real drift under noise and push agents back to fragile per-file copying.
$excludePattern = '(^|/)(bin|obj)/'

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# HostRoot is the tool's own directory. Its absence means the tool is not installed on this machine and
# there is genuinely nothing to sync; a missing skill directory *under* an installed tool is drift.
function Get-InstallRoot {
    param([string]$SkillName)

    $home_ = [Environment]::GetFolderPath('UserProfile')
    return @(
        [pscustomobject]@{ HostRoot = (Join-Path $home_ '.claude'); Path = (Join-Path $home_ ".claude/skills/$SkillName") },
        [pscustomobject]@{ HostRoot = (Join-Path $home_ '.agents'); Path = (Join-Path $home_ ".agents/skills/$SkillName") },
        [pscustomobject]@{ HostRoot = (Join-Path $home_ '.gemini/antigravity-cli'); Path = (Join-Path $home_ ".gemini/antigravity-cli/skills/$SkillName") }
    )
}

function Get-RelativeFile {
    param([string]$Root)

    if (-not (Test-Path $Root)) {
        return @()
    }

    $base = (Resolve-Path $Root).Path.TrimEnd('\', '/')
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object { $_.FullName.Substring($base.Length + 1).Replace('\', '/') } |
        Where-Object { $_ -notmatch $excludePattern })
}

function Sync-SkillTree {
    param(
        [string]$SourceRoot,
        [string]$InstallRoot,
        [string[]]$RelativeFile
    )

    foreach ($rel in $RelativeFile) {
        $destination = Join-Path $InstallRoot $rel
        $destinationDir = Split-Path -Parent $destination
        if (-not (Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
        }

        Copy-Item -LiteralPath (Join-Path $SourceRoot $rel) -Destination $destination -Force
    }
}

function Test-SkillTree {
    param(
        [string]$SourceRoot,
        [string]$InstallRoot,
        [string[]]$RelativeFile
    )

    $drift = @()

    foreach ($rel in $RelativeFile) {
        $expected = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $rel) -Algorithm SHA256).Hash
        $destination = Join-Path $InstallRoot $rel
        $actual = if (Test-Path -LiteralPath $destination) {
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        }
        else {
            'MISSING'
        }

        if ($actual -ne $expected) {
            $drift += "  DRIFT   $rel"
        }
    }

    # A rename or deletion in the repository leaves the old file behind in an install, where a stale
    # skill keeps loading it. Extras are drift too, not cosmetic residue.
    foreach ($rel in (Get-RelativeFile -Root $InstallRoot)) {
        if ($RelativeFile -notcontains $rel) {
            if ($Prune) {
                Remove-Item -LiteralPath (Join-Path $InstallRoot $rel) -Force
            }
            else {
                $drift += "  EXTRA   $rel"
            }
        }
    }

    return $drift
}

$repoRoot = Get-RepoRoot
$skillsRoot = Join-Path $repoRoot 'skills'

if (-not $Skill -or $Skill.Count -eq 0) {
    $Skill = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | ForEach-Object { $_.Name })
}

$totalDrift = 0

foreach ($name in $Skill) {
    $sourceRoot = Join-Path $skillsRoot $name
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        Write-Host "[SKIP] $name (not a repo-managed skill)"
        continue
    }

    $relativeFile = Get-RelativeFile -Root $sourceRoot

    foreach ($install in (Get-InstallRoot -SkillName $name)) {
        $installRoot = $install.Path

        if (-not (Test-Path -LiteralPath $install.HostRoot)) {
            Write-Host "[SKIP] $name -> $installRoot (host tool not installed)"
            continue
        }

        # An installed host with no copy of the skill used to be skipped, which let a run where nothing
        # was ever installed still report "verified, 0 drift". A sync creates the install; a verify fails.
        if (-not (Test-Path -LiteralPath $installRoot)) {
            if ($VerifyOnly) {
                Write-Host "[FAIL] $name -> $installRoot (not installed)"
                $totalDrift += 1
                continue
            }

            New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        }

        if (-not $VerifyOnly) {
            Sync-SkillTree -SourceRoot $sourceRoot -InstallRoot $installRoot -RelativeFile $relativeFile
        }

        $drift = @(Test-SkillTree -SourceRoot $sourceRoot -InstallRoot $installRoot -RelativeFile $relativeFile)
        $totalDrift += $drift.Count

        if ($drift.Count -eq 0) {
            Write-Host "[PASS] $name -> $installRoot ($($relativeFile.Count) files identical)"
        }
        else {
            Write-Host "[FAIL] $name -> $installRoot ($($drift.Count) drifted)"
            $drift | ForEach-Object { Write-Host $_ }
        }
    }
}

Write-Host ''
if ($totalDrift -eq 0) {
    Write-Host "Install sync: verified, 0 drift."
    exit 0
}

Write-Host "Install sync: $totalDrift drifted entr$(if ($totalDrift -eq 1) { 'y' } else { 'ies' })."
exit 1
