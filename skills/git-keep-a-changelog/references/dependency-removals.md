# Dependency removal disclosure

Readers scanning `Removed` need to discover which dependencies disappeared. A replacement explanation under `Changed` does not provide that inventory. Apply this to runtime, development, build, test, analyzer, and tool dependencies; test-only scope is context to disclose, not a reason to omit a removal.

## Establish package identity and scope

Use the cumulative manifest delta from Step 4b, including project files, shared imports, and central package declarations. Reconcile package identity across the relevant manifests at the base and final state, including approved pending changes. A deleted line alone is not proof that a dependency disappeared.

Discover manifests from committed, staged, unstaged, and untracked paths before this comparison. With all pending changes included, compare tracked manifests using `git diff <merge_base> -- <manifest-path>` and read untracked manifests directly. A two-commit `diff_range` cannot reveal pending-only removals. Yolo/auto includes those changes automatically; it skips confirmation, not discovery or removal disclosure. Reconcile against the final contents so a staged removal restored in the worktree is not reported, and a reference moved into an untracked imported file is not mistaken for a removed package.

- A dependency present at the base and absent from the final dependency declarations belongs under `Removed`. Name its exact package identifier. Group related removals in one bullet if every identifier remains explicit.
- If it survives for another project or target framework, describe the scope from which it was removed rather than claiming repository-wide removal.
- A reference moved from a project file into shared or central configuration is a move, not a removed dependency. Removing only an unused central version declaration does not prove removal of a runtime dependency; describe the declaration cleanup accurately when relevant.
- Omit temporary dependencies absent at both endpoints and removals reverted before the final state. An ordinary version upgrade is `Changed`, not removal of the old version.
- Distinguish direct dependency removal from transitive availability. Do not claim a package is absent from the resolved dependency graph without evidence for that graph.

The path-backed entity resolver classifies whole files and directories, not entries inside a manifest. A surviving `Directory.Build.props` classified as `Changed` cannot veto a package's `Removed` classification. Validate that package from its own manifest-level before/after evidence.

## Preserve replacement context

### Distinguish package switches from renames and upgrades

Package identifiers establish identity; similar spelling, a shared publisher, equal versions, or adjacent removed/added manifest lines do not prove a rename. Reserve rename wording for explicit publisher migration or package metadata evidence. Git file rename detection and commit wording alone cannot establish a package rename.

Compare versions within the same package identity. A new identifier at version 2.2.0 does not establish an upgrade from the outgoing package, even if its version is lower. A switch can coincide with a separately evidenced version upgrade; describe those facts separately. When identity continuity is unknown, say that the direct reference switched from package A to package B at its declared version, without inventing a rename, upgrade, or reason.

An integration, extension, umbrella, or metapackage can add capabilities while depending on the outgoing package. Inspect existing lockfiles, resolved assets, or the exact package version's dependency metadata before claiming transitive retention. Match the affected project and target framework; stale restore output is not proof of the final graph. If that evidence is unavailable, state only the direct-reference change. Do not infer transitive retention from a package name, or infer use of new APIs merely because the package makes them available.

For example, when manifests switch the direct reference from `ModelContextProtocol` 2.2.0 to `ModelContextProtocol.AspNetCore` 2.2.0 and the latter's package metadata confirms its dependency on the former:

```markdown
### Changed

- Switched the direct dependency to `ModelContextProtocol.AspNetCore` 2.2.0 to include ASP.NET Core integration capabilities.

### Removed

- Direct reference to `ModelContextProtocol`; it remains a transitive dependency through `ModelContextProtocol.AspNetCore`.
```

This is a dependency switch with added integration capabilities, not a package rename or version upgrade. The `Removed` disclosure concerns the direct reference only; it must not imply that the original package or its capabilities disappeared.

Keep a useful `Changed` bullet explaining a provider or tooling migration, and add a `Removed` bullet naming the outgoing dependencies. These describe the migration and its distinct package removals; the one-outcome rule does not suppress either. Avoid repeating the full migration narrative in both sections.

For example, when the manifests prove that test-only Coverlet references were replaced:

```markdown
### Changed

- Replaced Coverlet with Microsoft.Testing.Extensions.CodeCoverage for test coverage collection.

### Removed

- Removed `coverlet.collector` and `coverlet.msbuild` from test project dependencies.
```

State test/build-only scope when supported by conditions such as `IsTestProject` and asset metadata. Do not imply a library runtime or public API removal, invent consumer migration steps, or classify a release as major merely because `Removed` is populated.

## Verify before writing

Reconcile every surviving dependency removal against the target release's `Removed` section. Require each package identifier and any scope qualification needed for accuracy. Replacement prose under `Changed` alone fails this check. Preserve section order and punctuation, and consolidate existing removal bullets instead of appending duplicates on subsequent edits.

Check every rename, upgrade, and transitive-retention claim against its own evidence. Rewrite unsupported claims in existing draft bullets as well as newly generated text.
