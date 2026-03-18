---
name: git-nuget-release-notes
description: >
  Create or update per-package NuGet release notes from git history for
  .NET repositories that store cumulative
  `.nuget/<ProjectName>/PackageReleaseNotes.txt` files. Use this skill
  whenever the user asks for NuGet release notes, `PackageReleaseNotes.txt`,
  per-assembly or per-package release notes, or wants git commits turned
  into package release notes instead of a repo-wide changelog. Treat
  requests like "update PackageReleaseNotes.txt", "write NuGet release
  notes from git", "summarize this release per assembly", or "create
  missing package release notes under .nuget" as automatic triggers. The
  skill discovers packable `src/` projects, resolves concrete release
  version and availability per package, creates missing files when needed,
  preserves cumulative newest-first history, and avoids raw commit-log
  dumps or unsupported claims.
---

# Git NuGet Release Notes

This skill creates or updates cumulative
`.nuget/<ProjectName>/PackageReleaseNotes.txt` files for packable .NET
projects by reading git history and the actual project/package metadata.
It is intentionally closer to the package-note style used in codebelt
repositories than to a repo-wide `CHANGELOG.md`.

Read `references/package-release-notes-format.md` before writing any
release-note block.

## Non-Negotiable Rules

- Create or update `.nuget/<ProjectName>/PackageReleaseNotes.txt`
  directly, then stop for user review.
- Discover packable projects under `src/`; ignore `test/`, `tuning/`,
  `tooling/`, and projects that are explicitly non-packable.
- Prefer an existing `.nuget/<ProjectName>/` folder when one already
  exists for the packable project. If none exists, create
  `.nuget/<MSBuildProjectName>/PackageReleaseNotes.txt`.
- For repo-wide requests, every packable `src/` project should end up
  represented by a corresponding `PackageReleaseNotes.txt` file.
- Read full commit subjects and bodies before writing the package notes.
- Inspect the net diff too; do not classify a package from commit
  subjects alone.
- Use cumulative newest-first history.
- If the target version already exists at the top of the file, rewrite
  that block in place instead of duplicating it.
- If the target version is not present, prepend the new block above the
  older history.
- Normalize the block you write to `Version:` and `Availability:`.
- Always include `# ALM` in the block you write.
- Use only this section order when sections are populated:
  `ALM`, `Breaking Changes`, `New Features`, `Improvements`,
  `Bug Fixes`, `References`.
- Omit empty sections instead of emitting placeholders.
- Start every bullet with an all-caps action verb such as `ADDED`,
  `CHANGED`, `REMOVED`, `FIXED`, `EXTENDED`, `OPTIMIZED`, `MOVED`,
  `RENAMED`, `DEPRECATED`, or `REFACTORED`.
- Keep package/type/member identifiers exact where possible.
- Do not dump commit subjects verbatim into the release notes.
- Do not invent unsupported changes, package references, or availability.
- Ignore odd historical spacing such as non-breaking spaces in older
  entries; normalize only the block you are writing unless the user asks
  for a larger cleanup.

## Workflow

### Step 1: Resolve the source range

Use the most explicit range the user gave you.

- If the user named a range, branch comparison, base branch, or PR
  range, use that.
- Otherwise, compare the current branch to its upstream merge-base.
- If no upstream is configured, try `main`, then `master`.
- If no safe comparison point can be established, stop and ask for a
  base branch or range instead of guessing.

Helpful commands:

```bash
git status --short --branch
git rev-parse --abbrev-ref HEAD
git rev-parse --abbrev-ref --symbolic-full-name @{upstream}
git merge-base HEAD @{upstream}
git merge-base HEAD main
git merge-base HEAD master
```

### Step 2: Discover the target packages

Discover the packable `src/` projects that belong in `.nuget/`.

- Enumerate `src/**/*.csproj`.
- Exclude projects that live outside `src/` or are clearly test,
  benchmark, sample, or tooling projects.
- Exclude projects with `IsPackable` explicitly set to `false`.
- Keep project identity anchored to the packable project name or the
  existing `.nuget/<ProjectName>/` folder already used by the repo.
- When the user asked for repo-wide release notes coverage, ensure every
  packable project is represented. Otherwise, focus on the projects
  affected by the requested range.

Helpful commands:

```bash
rg --files src -g *.csproj
git diff --name-only <base>..HEAD -- src .nuget Directory.Build.props Directory.Build.targets Directory.Packages.props
```

### Step 3: Resolve the concrete release version

Each release-note block needs a real package version, not an
`[Unreleased]` placeholder.

Use this order:

1. Explicit version provided by the user.
2. Branch prefix such as `v0.3.1/feature-name` -> `0.3.1`.
3. Evaluated package version from the project if it is concrete and safe
   to use.

If you cannot determine a safe concrete version, stop and ask instead of
guessing.

Do not infer a version by bumping the previous entry manually unless the
user explicitly asked you to choose the next version.

### Step 4: Resolve the availability line

Derive `Availability:` from the package's target frameworks.

- Read `TargetFramework` or `TargetFrameworks` from the project and any
  inherited repo-level props when needed.
- Preserve the project order when rendering frameworks.
- Convert TFMs to the human-readable style used by the existing files.
- Join the final list with commas and `and`.

Examples:

- `net10.0;net9.0` -> `.NET 10 and .NET 9`
- `net10.0;net9.0;netstandard2.0` ->
  `.NET 10, .NET 9 and .NET Standard 2.0`
- `net10.0;net9.0;netstandard2.1;netstandard2.0` ->
  `.NET 10, .NET 9, .NET Standard 2.1 and .NET Standard 2.0`

Do not guess availability from memory if the project file or evaluated
MSBuild properties can answer it.

### Step 5: Inspect the actual package changes

For each target package, read enough history and diff to understand the
real release story for that package.

- Read the full commit bodies for the selected range.
- Inspect the net diff for the package's project folder plus shared
  packaging/build files that materially affect that package.
- Include shared files such as `Directory.Packages.props`,
  `Directory.Build.props`, `Directory.Build.targets`, and
  `.nuget/<ProjectName>/` when they affect the package.
- Prefer the net effect over the implementation path when there are
  fixups or reversals.

Helpful commands:

```bash
git log --reverse --format=medium <range> -- <paths>
git log --reverse --stat --format=medium <range> -- <paths>
git diff --stat <base>..HEAD -- <paths>
git diff <base>..HEAD -- <paths>
```

### Step 6: Classify the content into the package-note format

Use the normalized section order from
`references/package-release-notes-format.md`.

Classification guidance:

- `# ALM`:
  dependency upgrades, TFM support added/removed, packaging metadata
  changes, or other release-engineering/package-management changes.
- `# Breaking Changes`:
  incompatible renames, removals, moved APIs, changed contracts, or
  behavior that requires consumer action.
- `# New Features`:
  additive new APIs, capabilities, packages, or newly exposed options.
- `# Improvements`:
  non-breaking enhancements such as `CHANGED`, `EXTENDED`,
  `OPTIMIZED`, `DEPRECATED`, or other refinements.
- `# Bug Fixes`:
  defects corrected for existing behavior.
- `# References`:
  package IDs only, and only when the package is an umbrella/meta package
  or the existing file already carries a references section the current
  release should preserve.

Prefer a minimal truthful block over an inflated one. ALM-only releases
are valid when the real change was only dependency or TFM maintenance.

### Step 7: Write or update PackageReleaseNotes.txt

Write the block in this normalized shape:

```text
Version: 0.3.1
Availability: .NET 10 and .NET 9

# ALM
- CHANGED Dependencies have been upgraded to the latest compatible versions for all supported target frameworks (TFMs)

# New Features
- ADDED ...
```

Editing rules:

- If the file is missing, create it with the new block only.
- If the top block already targets the resolved version, replace that
  top block in place and leave older history below it intact.
- If the top block targets an older version, prepend the new block and a
  blank line before the existing history.
- Preserve older release blocks below the edited one unless the user
  explicitly asked for a historical cleanup.
- Keep bullets concise, concrete, and single-line unless a longer line is
  genuinely needed for clarity.
- Do not add decorative Markdown, tables, or changelog callouts.

### Step 8: Stop after the edit

After updating the relevant `PackageReleaseNotes.txt` files, stop and let
the user review them. Do not commit, tag, push, pack, or publish unless
the user asks.

## Good Output Characteristics

- Reads like curated package release notes, not a repo-wide changelog.
- Keeps one truthful release block per package/version.
- Uses concrete package/type/member names and namespaces.
- Writes the newest release first while preserving older history.
- Keeps ALM details explicit when dependencies or TFMs changed.
- Creates missing files when the package should be represented.
- Keeps availability aligned with actual target frameworks.

## Bad Output Characteristics

- Writing one repo-level summary and copying it into every package file.
- Using `Unreleased` or omitting the concrete version line.
- Guessing availability instead of reading project metadata.
- Dumping commit subjects line by line into the file.
- Creating empty headings or filler bullets like "misc updates".
- Claiming breaking changes, fixes, or references not supported by git
  and the project/package metadata.
