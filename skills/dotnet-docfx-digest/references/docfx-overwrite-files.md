# DocFX Overwrite Files Reference

Use this reference when creating, auditing, or repairing DocFX overwrite files for .NET API documentation.

Sources:

- https://dotnet.github.io/docfx/tutorial/intro_overwrite_files.html
- https://dotnet.github.io/docfx/reference/docfx-json-reference.html#overwrite

## Agent Summary

DocFX treats generated API metadata and Markdown content as models. An overwrite file is a Markdown file that updates a model by matching its `uid`; this lets documentation add or replace properties such as `summary`, `remarks`, examples, conceptual content, and namespace-level guidance without editing generated metadata.

Every overwrite section starts with YAML front matter delimited by `---`. The front matter must include `uid`, and the value must match the generated model UID. Do not guess UIDs. Verify them from generated metadata, existing API pages, source conventions, DocFX output, or `docfx build --exportRawModel`.

The `*content` anchor maps the Markdown body following the YAML header into a chosen model property. For this skill, namespace overview pages normally use:

```markdown
---
uid: X.Y.Z
summary: *content
---
The `X.Y.Z` namespace contains types that ...
```

If `*content` is not used, DocFX assigns the Markdown body to the default conceptual content property. Prefer `summary: *content` for namespace fly-ins and other summary replacements that should flow into generated API pages.

DocFX applies overwrite models by `uid`. If the same `uid` appears more than once in one overwrite file, later sections in that same file override earlier sections. Across different overwrite files, ordering is not deterministic, so keep competing sections for the same `uid` together or consolidate them.

Overwrite models should follow the target model shape. Existing properties can be replaced or merged depending on the DocFX model rules; properties not already present can be added. For managed reference docs, common useful overwrite targets include `summary`, `remarks`, `example`, `exceptions`, `see`, `seealso`, and parameter descriptions under `syntax`.

The `build.overwrite` entry in `docfx.json` tells DocFX which conceptual Markdown files contain overwrite sections. All relative paths in `docfx.json` are resolved relative to the directory containing `docfx.json`, not necessarily the repository root.

When a repository has no obvious overwrite location, inspect `docfx.json` first. Look at `build.content`, `build.overwrite`, `metadata.dest`, include paths, and existing Markdown layout before deciding where a new namespace page belongs.

## Practical Rules

- Run `agents.cs` before finishing so root `AGENTS.md` receives persistent DocFX maintenance guidance.
- Use overwrite files to complement generated API metadata, not to hide incorrect XML documentation.
- Correct bad XML comments at source when the generated summary is wrong.
- Use namespace overview pages for namespace fly-ins and extension-member tables.
- Keep examples and remarks close to the API item or namespace they explain.
- Preserve existing hand-written overwrite sections unless they are stale or contradictory.
- Prefer additive edits, but remove or revise contradictions.
- Re-run `docfx.cs` after edits so missing namespace pages, extension tables, availability, and sample compilation are checked deterministically.
