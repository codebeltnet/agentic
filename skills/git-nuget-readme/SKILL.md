---
name: git-nuget-readme
description: >
  Use when the user wants to create or refresh a NuGet-facing `README.md` for a .NET package, grounded in the packable `src/` project and current repository changes. Do not use for general repository docs, DocFX API pages, changelogs, or release notes.
---

# Git NuGet README

This skill creates or updates a package-facing `README.md` for a .NET repository by combining git history, actual project/package metadata, and concrete source-level capabilities. It improves the developer experience by pulling install guidance, package value, and a quick start closer to the top while keeping branding and tone derived from the current repository rather than from any hardcoded ecosystem template.

Read `references/nuget-readme-blueprint.md` before writing or rewriting the README.

## Non-Negotiable Rules

- Create or update `README.md` directly, then stop for user review.
- Anchor the README to the real advertised packable project or package, not to a vague repo-wide theme.
- Discover packable projects under `src/`; ignore `test/`, `tuning/`, `tooling/`, and projects that are explicitly non-packable.
- If the target project is ambiguous, stop and ask instead of guessing.
- Read full commit subjects and bodies before refreshing README copy.
- Inspect the net diff too; do not write the README from commit subjects alone.
- When feasible, inspect unit or functional tests associated with the advertised package and use them as supporting hints for scenarios, examples, or capability wording.
- Ground every capability claim in actual source, project metadata, existing docs, relevant tests, or the current diff.
- Use the exact project/package/assembly name the README is advertising.
- Derive branding, owner naming, and repo voice from the current repo, package metadata, and existing README when present.
- Never inject ecosystem- or vendor-specific branding such as `Codebelt` unless the current repository already uses it explicitly.
- Keep the tone forthcoming, concrete, and developer-first.
- Make the package easy to evaluate quickly: value proposition, install path, supported frameworks, docs, and a small getting-started example should be easy to find.
- Do not fabricate badges, benchmarks, stars, docs URLs, compatibility, or package relationships.
- Preserve useful stable sections such as contributing, license, documentation, or badge groups when they are still accurate.
- Prefer improving and reorganizing an existing README over replacing it wholesale when stable sections can be kept.
- Do not dump commit subjects verbatim into the README.
- Do not write generic AI-marketing copy such as "powerful solution", "seamless integration", or "cutting-edge toolkit" unless the concrete substance is immediately explained.

## Workflow

### Step 1: Resolve the advertised project

Identify which packable project the README is meant to advertise.

Use this order:

1. Explicit project, package, or assembly named by the user.
2. Existing README title/package focus if it is already clearly scoped.
3. The primary packable project under `src/` that matches the repo name, package ID, or solution identity.

If multiple packable projects could plausibly own the README and the repo does not already make the primary one obvious, stop and ask which package the README should center.

Helpful commands:

```bash
git status --short --branch
rg --files src -g *.csproj
rg -n "<PackageId>|<AssemblyName>|<Description>|<TargetFramework|<TargetFrameworks>|<IsPackable>" src
```

### Step 2: Resolve the source range

Use the most explicit range the user gave you.

- If the user named a branch comparison, PR range, or base branch, use that.
- Otherwise, compare the current branch to its upstream merge-base.
- If no upstream exists, try `main`, then `master`.
- If no safe comparison point can be established, stop and ask for a base branch or range instead of guessing.

Helpful commands:

```bash
git rev-parse --abbrev-ref HEAD
git rev-parse --abbrev-ref --symbolic-full-name @{upstream}
git merge-base HEAD @{upstream}
git merge-base HEAD main
git merge-base HEAD master
```

### Step 3: Gather package metadata and README anchors

Collect the concrete facts the README should advertise.

- Project/package/assembly name
- Package ID
- Repo owner or organization naming when relevant
- Description and repository/project URLs from the project when present
- Target framework(s)
- Existing docs or DocFx links when present
- Existing README sections worth preserving
- Existing title/branding conventions already used by the repo
- Real package relationships if this is an umbrella/meta package

Prefer explicit project metadata over inference. When a docs site or package URL cannot be proven from the repo, omit it instead of inventing it. Apply the same rule to branding: use the repository's actual identity, not a remembered template from another ecosystem.

Helpful commands:

```bash
rg -n "<PackageId>|<Title>|<Description>|<PackageProjectUrl>|<RepositoryUrl>|<AssemblyName>" src README.md Directory.Build.props Directory.Build.targets
rg -n "DocFx|docfx|nuget.org|PackageReference" README.md .docfx src
git remote -v
```

### Step 4: Inspect the actual project changes and capabilities

Understand what the package really offers and what changed in the chosen range.

- Read full commit bodies for the selected range.
- Inspect the net diff for the target project plus shared packaging or docs files that materially affect the package.
- Inspect the main source folders to confirm the real capability areas.
- When the repo has corresponding unit or functional tests for the advertised package, inspect those tests too for user-facing examples, realistic scenarios, or terminology the README can reuse honestly.
- Prefer the net effect over the implementation path when there are fixups or reversals.

Helpful commands:

```bash
git log --reverse --format=medium <range> -- <paths>
git log --reverse --stat --format=medium <range> -- <paths>
git diff --stat <base>..HEAD -- <paths>
git diff <base>..HEAD -- <paths>
rg -n "namespace |public (class|interface|struct|record|enum)|extension" src/<ProjectName>
rg --files test -g *Tests*.cs
rg -n "<ProjectName>|<PackageId>|namespace " test
```

### Step 5: Draft the README from the blueprint

Use the structure and tone from `references/nuget-readme-blueprint.md`.

Default shape:

1. Title and existing badge strip when the repo already uses one
2. Short "About" or value proposition section
3. Supported framework statement
4. Why pick this package / key capabilities
5. Installation or package section
6. Quick start or minimal example when the codebase justifies it
7. Documentation link when available
8. Contributing and license

Strong README characteristics:

- The first screen tells the developer what the package is for and why they might choose it.
- The copy speaks to actual scenarios, not abstract superlatives.
- The title and tone match the repo's own identity instead of importing branding from unrelated repositories.
- Installation is easy to find.
- The example is minimal, truthful, and uses real types or namespaces.
- When feasible, the example or scenario wording is reinforced by associated unit or functional tests rather than invented usage.
- Supported frameworks are explicit.
- The README sounds welcoming and opinionated without overselling.

### Step 6: Preserve and improve intelligently

When the repo already has a README, keep the accurate parts and improve the experience:

- Preserve badges, contributing, license, and docs links when still valid.
- Reorder sections when that improves first-time package evaluation.
- Tighten vague copy into concrete benefits and scenarios.
- Replace stale claims with current, source-backed wording.
- Avoid deleting useful historical context unless it is clearly wrong or the user asked for a leaner rewrite.

### Step 7: Write the README.md

Write or update `README.md` directly.

Editing rules:

- Keep headings concise and scan-friendly.
- Prefer short paragraphs and flat bullets.
- Put installation before deeper reference material.
- If you include a code example, keep it small and runnable-looking.
- Use fenced code blocks with language tags.
- Keep product/package names exact.
- Link to real docs or package pages only when the repo supports them.
- Keep org or vendor naming repo-derived. If the current repo never says `by <owner>` or uses a branded suffix, do not add one just because another repo family does.

### Step 8: Stop after the edit

After updating `README.md`, stop and let the user review it. Do not commit, tag, push, pack, or publish unless the user asks.

## Good Output Characteristics

- Reads like a package README a developer would want to skim before installing.
- Leads with a clear value proposition and concrete capability areas.
- Makes install, supported frameworks, and docs easy to find.
- Uses real package names, namespaces, and examples from the codebase.
- Adapts branding and heading style from repo metadata instead of hardcoding another ecosystem's naming pattern.
- Preserves stable repo sections while improving adoption-oriented copy.
- Sounds welcoming and credible rather than generic or overhyped.

## Bad Output Characteristics

- A README that could apply to almost any .NET library.
- Claims about performance, reliability, compatibility, or integrations that are not proven by the repo.
- Hiding installation or framework support deep in the file.
- Generic marketing phrases with no technical substance.
- Injecting branding, docs hostnames, or title conventions copied from a different repo family.
- Examples that invent APIs, namespaces, or package IDs.
- Blindly replacing an existing good badge/docs/contributing structure with a totally different template.
