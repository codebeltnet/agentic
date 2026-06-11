# DocFX Overwrite Files Reference

Use this reference when creating, auditing, or repairing DocFX overwrite files for .NET API documentation.

Sources:

- https://dotnet.github.io/docfx/tutorial/intro_overwrite_files.html
- https://dotnet.github.io/docfx/reference/docfx-json-reference.html#overwrite

## Agent Summary

DocFX treats generated API metadata and Markdown content as models. An overwrite file is a Markdown file that updates a model by matching its `uid`; this lets documentation add or replace properties such as `summary`, `remarks`, `example`, conceptual content, and namespace-level guidance without editing generated metadata.

Every overwrite section starts with YAML front matter delimited by `---`. The front matter must include `uid`, and the value must match the generated model UID. Do not guess UIDs. Verify them from generated metadata, existing API pages, source conventions, DocFX output, or `docfx build --exportRawModel`.

The `*content` anchor maps the Markdown body following the YAML header into a chosen model property. For this skill, namespace overview pages normally use:

```markdown
---
uid: X.Y.Z
summary: *content
---
The `X.Y.Z` namespace contains types that ...
```

If `*content` is not used, DocFX assigns the Markdown body to the `conceptual` property. **Do not rely on this default for managed reference (API) pages.** When `conceptual` is set on a managed reference page, some DocFX templates suppress the auto-generated member tables (constructors, methods, properties), leaving only the custom content visible. Always use an explicit property mapping.

For **type-page and extension-method examples**, use the `example` array property instead of `summary`:

```markdown
---
uid: X.Y.Z.MyType
example:
- *content
---
The following example shows how to use `MyType`.

```csharp
using X.Y.Z;

var value = new MyType();
Console.WriteLine(value);
```
```

`example: - *content` maps the Markdown body to the first slot of the `example` string array. DocFX renders this as the "Examples" section on the type page **alongside** the auto-generated constructors, methods, and other members — it does not replace them. The `example` property has **Replace** overwrite behavior, so setting it via an overwrite replaces any example already present in generated metadata.

Do **not** include a `### Examples` heading in the body. DocFX adds the section header automatically from the template.

> The validator distinguishes two example forms by the front matter, not by headings in the body. Do not rely on a body heading to make the validator happy.
>
> **Form A — front matter `example: *content` (or the `- *content` list form).** This is the recommended form for type pages and extension-class pages. The body must contain at least one fenced `csharp` (or `cs`) block. Do **not** add a `## Example` or `### Example` heading; DocFX renders the section header automatically and a manual heading produces a duplicate "Examples" heading on the rendered page.
>
> **Form B — front matter `summary: *content`.** The body must contain a `## Example` or `### Example` heading followed by a fenced `csharp` (or `cs`) block. This form is only for the rare case where the example is embedded inside conceptual content.
>
> The validator recognizes Form A by the YAML anchor, not by a body heading; Form B by the body heading. Mixing them produces duplicate sections or validator failures.

Do **not** use `summary: *content` for type example files. That replaces only the summary text and does nothing to add a visible Examples section to the page.

DocFX applies overwrite models by `uid`. If the same `uid` appears more than once in one overwrite file, later sections in that same file override earlier sections. Across different overwrite files, ordering is not deterministic, so keep competing sections for the same `uid` together or consolidate them.

Overwrite models should follow the target model shape. Existing properties can be replaced or merged depending on the DocFX model rules; properties not already present can be added. For managed reference docs, common useful overwrite targets include `summary`, `remarks`, `example`, `exceptions`, `see`, `seealso`, and parameter descriptions under `syntax`. The official managed reference model lists `example` as an overwriteable property, so usage examples can be added through overwrite sections when generated metadata lacks them.

The `build.overwrite` entry in `docfx.json` tells DocFX which conceptual Markdown files contain overwrite sections. All relative paths in `docfx.json` are resolved relative to the directory containing `docfx.json`, not necessarily the repository root.

When a repository has no obvious overwrite location, inspect `docfx.json` first. Look at `build.content`, `build.overwrite`, `metadata.dest`, include paths, and existing Markdown layout before deciding where a new namespace page belongs.

If a public non-abstraction type lacks an example, create a matching type-UID overwrite section in a separate per-type Markdown file by default, and make sure that file is included by `build.overwrite` so the example appears on the generated type API page. In Codebelt repositories, keep type overwrite files under `.docfx/api/types/{TypeUid}.md`, such as `.docfx/api/types/X.Y.Z.Class1.md`, and namespace overview pages under `.docfx/api/namespaces/{Namespace}.md`. File location does not decide whether the page is a namespace page or a type page; the YAML front matter `uid` does. Keep both `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite`, exclude both `api/namespaces/**` and `api/types/**` from `build.content`, and do not use `api/**/*.md` under either section. If authored overwrite Markdown already exists directly under `.docfx/api/*.md`, move it into either `api/namespaces/` (for namespace UIDs) or `api/types/` (for type UIDs) without deleting the content. Namespace overview pages and `Extension Members` tables complement examples; they do not replace type-page examples.

## Practical Rules

- Run `agents.cs` before finishing so root `AGENTS.md` receives persistent DocFX maintenance guidance.
- Use overwrite files to complement generated API metadata, not to hide incorrect XML documentation.
- Correct bad XML comments at source when the generated summary is wrong.
- Use namespace overview pages for namespace fly-ins and extension-member tables.
- Keep examples and remarks close to the API item or namespace they explain.
- Create per-type overwrite files for missing concrete-type examples even when the repository currently has only namespace overview files.
- Keep namespace overview Markdown under `.docfx/api/namespaces/` and type overwrite Markdown under `.docfx/api/types/`. Move legacy `.docfx/api/*.md` files into the appropriate subdirectory: namespace UIDs go to `api/namespaces/`, type UIDs go to `api/types/`.
- Keep `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite` only; do not use `api/**/*.md` under `build.content` or `build.overwrite`.
- Add examples through overwrite sections when XML comments or generated metadata do not already provide developer-friendly examples.
- Preserve existing hand-written overwrite sections unless they are stale or contradictory.
- Prefer additive edits, but remove or revise contradictions.
- Re-run `docfx.cs` after edits so missing namespace pages, extension tables, availability, and sample compilation are checked deterministically.

## Section rendering order

Overwrite files control what content is merged into the DocFX model. DocFX templates control where each property renders on the output page. Do not attempt to fix the order of sections such as "Examples before See Also" through overwrite paths, body headings, or front matter — that order is determined by the active template. If section ordering is wrong, the fix belongs in the template, not in the overwrite file.
