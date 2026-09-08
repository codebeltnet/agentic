---
name: dotnet-nuget-update
description: >
  Use when the user wants to update, audit, or check NuGet package dependencies
  in a .NET repository. Handles both central package management
  (Directory.Packages.props) and project-level PackageReference. Invoke as
  "dotnet-nuget-update" for interactive normal mode (auto-applies patch/minor,
  asks about majors) or "dotnet-nuget-update yolo" for silent patch/minor-only
  mode. Use any time packages need updating, versions need auditing, or the
  user asks about outdated dependencies.
---

# .NET NuGet Update

Use this skill when a .NET repository needs a complete dependency audit or a controlled package update pass.

## Start with the audit, not intuition

Your first deterministic step is:

```powershell
pwsh -NoProfile -File "<skill-root>/scripts/Get-DependencyAudit.ps1" -RepoRoot "<repo-root>"
```

Use `scripts/Get-DependencyAudit.ps1 -RepoRoot <path>` to enumerate every declaration before touching anything. The skill is complete only when every declared package version is accounted for.

The bundled scripts do the mechanical work:

- `scripts/Get-DependencyAudit.ps1` enumerates and classifies each declaration.
- `scripts/Get-PackageGraph.ps1` exposes the central-package condition graph.
- `scripts/Get-TargetFrameworks.ps1` exposes the repository TFM matrix.
- `scripts/Resolve-NuGetVersion.ps1` and `scripts/Compare-Version.ps1` investigate one package or version pair.
- `scripts/Apply-PackageUpdates.ps1` performs the minimal structural edit.
- `scripts/Get-NuGetSources.ps1` shows configured package feeds without exposing secrets.

The agent orchestrates. The scripts own the deterministic enumeration, comparison, and file edits.

## Two modes

### Normal mode

Normal mode is for an attended update run.

1. Audit the whole graph first.
2. Auto-apply only `revision`, `patch`, `minor`, and same-major `prerelease` steps.
3. Do not interrupt the user for each package.
4. Batch all `major` candidates into one approval question after the full audit is complete.
5. Preserve any deliberately held pins and explain why they were held.

### Yolo mode

Yolo mode means no approval prompts, not broader authority.

1. Audit the whole graph first.
2. Auto-apply only `revision`, `patch`, `minor`, and same-major `prerelease` steps.
3. Hold all `major` candidates.
4. Report the held majors explicitly at the end.

Yolo never means “apply majors silently,” and it never means commit or push anything.

## The complete-audit invariant

The audit is not optional scaffolding. It is the work list.

For every run, ensure the summary closes:

- `declared`
- `current`
- `auto`
- `approval`
- `unresolved`

The invariant is:

```text
current + auto + approval + unresolved == declared
```

Do not report the repository as updated unless every declaration is in exactly one bucket. A package that appears under two different conditions is two declarations and must produce two audit rows.

## TFM-band rule

Conditional central package graphs are load-bearing. Never flatten them.

If a declaration lives under a modern .NET TFM condition and its pinned major matches that band, keep resolution inside that band.

Examples:

- `$(TargetFramework.StartsWith('net9'))` + `Microsoft.Extensions.Logging` `9.0.0` → resolve within `9.x`
- `$(TargetFramework.StartsWith('net10'))` + `Microsoft.EntityFrameworkCore` `10.0.0` → resolve within `10.x`
- `$(TargetFramework.StartsWith('net9'))` + `Asp.Versioning.Http` `8.1.0` → no band restriction, because package major `8` does not match band `9`
- `$(TargetFramework.StartsWith('net10')) OR $(TargetFramework.StartsWith('net11'))` + `10.0.0` → resolve within `10.x`, because `10` is one of the declared bands and matches the pinned major

The band rule is a compatibility safeguard, not a guess about package policy.

## Stable versus prerelease intent

Infer package intent from the pin unless the user asks for something else.

- If the pinned version is stable, prefer stable candidates only.
- If the pinned version is prerelease, allow prerelease candidates for that package.
- If the caller explicitly requests prerelease review, use `-IncludePrerelease`.
- Same-major prerelease movement is an `auto` class, not an approval class.

That means `1.0.0-rc.1` → `1.0.0-rc.2` is a `prerelease` bump and may be auto-applied, while `13.0.3` → `14.0.0` remains `approval`.

## History first: comments and past decisions

Before changing a held or surprising pin, inspect its context.

1. Read the adjacent XML comment through the audit `note` field.
2. Treat comments as maintainer intent, not decoration.
3. Review file or repository history when the pin looks deliberate or compatibility-sensitive.
4. If an `auto` candidate has a note, pause and read it before applying the update.

A version comparison can tell you what is newer. It cannot tell you why a repository deliberately stayed behind.

## Structural editing only

NuGet props files and project files are structured XML, so edit them structurally and minimally.

Use `scripts/Apply-PackageUpdates.ps1` to update only the targeted declaration. Preserve:

- conditions and item-group boundaries,
- comments and blank lines,
- package ordering,
- indentation,
- encoding,
- existing line endings.

Do not rewrite the file wholesale. Change only the relevant `Version` attribute or project-level `<PackageReference Version="...">` value.

## Central package management and project-level references

Handle both repository styles.

### Central package management

When `Directory.Packages.props` exists:

- inspect it with `scripts/Get-PackageGraph.ps1`,
- audit it with `scripts/Get-DependencyAudit.ps1`,
- apply updates through `scripts/Apply-PackageUpdates.ps1`.

### Project-level package references

When the repository does not use central package management:

- audit explicit project-level `PackageReference` versions,
- update only the affected `.csproj` files,
- preserve unrelated project content.

Do not invent central package management for a repository that does not already use it.

## Dirty working trees and conflicts

Treat in-place dependency work as a surgical edit in a potentially dirty repository.

- Do not overwrite a declaration whose current file value no longer matches the audited `from` version.
- If `scripts/Apply-PackageUpdates.ps1` reports `conflict`, stop and report it instead of guessing.
- Leave unrelated dirty files alone.
- Re-run the audit after applying updates when the repository state changed materially.

A conflict is evidence that the file changed after the audit. Respect that evidence.

## Validation

Prefer the smallest deterministic validation that proves the update is safe.

1. Discover target frameworks with `scripts/Get-TargetFrameworks.ps1 -RepoRoot <path>`.
   The static scanner resolves project properties through the nearest Directory.Build.props/targets and recursive explicit imports. It inventories declarations without evaluating MSBuild conditions or SDK imports; verify conditional results and unresolved tokens with project-specific MSBuild evaluation before selecting validation commands.
2. If source selection matters, inspect feeds with `scripts/Get-NuGetSources.ps1`.
3. Run the narrowest restore, build, or test command that covers the affected projects and target frameworks.
4. If the repository already has a targeted test or validation command, use it rather than inventing one.

If no code changed because every declaration was already current, say so and report the audit summary anyway.

## Reporting

The final report must contain:

1. Repository path and whether it used central or project-level package management.
2. Audit summary with `declared/current/auto/approval/unresolved` counts.
3. Every package actually updated, including condition or file context.
4. Every major candidate held for approval or yolo holdback.
5. Every unresolved package.
6. Every note-bearing declaration that was held or required human review.
7. Validation commands run and their outcomes.
8. Any conflicts or manual follow-up required.

If nothing changed, say that explicitly and still include the complete audit summary.
