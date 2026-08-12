---
name: dotnet-segregated-assets
description: >
  Migrate or configure an ASP.NET Core web application so developers keep authoring static files in the conventional wwwroot while deployed static content is served by Codebelt Static Content Provider (codebeltnet/web-cdn-origin:2.0.0), a separate asset host rather than the web app. Use when asked to segregate static assets, move wwwroot off the web app, stop shipping wwwroot with the app, or reconcile Cuemon App/CDN TagHelpers with a segregated topology. Reuse existing Cuemon or project abstractions, distinguish App assets from shared CDN assets, preserve Static Web Assets, and verify publish/local invariants deterministically. Do NOT use to build a general-purpose CDN or migrate non-ASP.NET static sites.
compatibility: >
  Requires the .NET SDK 10+ and PowerShell 7+. NuGet.org access is required when plan resolves an existing Cuemon package reference. Docker is optional (only for the local origin).
---

# .NET Segregated Static Assets

Keep `wwwroot` as the conventional, tooling-friendly authoring root while making the deployed web application stop serving and shipping its application-owned files. Deployed static content is delivered by Codebelt Static Content Provider (`codebeltnet/web-cdn-origin:2.0.0`) through a separate asset host, not by the ASP.NET Core business application.

The architecture is:

```text
Razor declares ownership:       app-* or cdn-*
Configuration declares location: current application, local segregated origin, or deployed host
web-cdn-origin declares delivery: static content only
```

## Runner boundary

The bundled .NET file-based program `scripts/segregate-assets.cs` is the deterministic inspection and verification layer. The agent is the orchestration and editing layer: it resolves repository conventions, makes semantic source/configuration edits, and verifies the result. The runner never edits or rewrites Razor, C#, project files, launch profiles, Dockerfiles, Compose, or documentation.

```text
dotnet run --file "<skill-root>/scripts/segregate-assets.cs" -- <command> [options]
```

Use `inspect` before changing anything, `plan` for a read-only ordered decision list, `verify` to publish into an isolated temporary directory and check local topology, and `--self-test` for the hermetic runner tests. When the selected project has an actual `Cuemon.AspNetCore.Razor.TagHelpers` package reference, `plan` discovers NuGet's package-content endpoint through the V3 service index, selects the highest stable version, and emits it in `resolvedNuGetPackages` plus the `nuget-package-version` decision. Prereleases are excluded. If NuGet cannot be queried, planning fails instead of copying a version from repository fixtures, examples, templates, or memory. Add `--json` when consuming results mechanically.

`inspect` reports candidate projects, risk signals, existing segregation, and asset-abstraction evidence including:

- Cuemon package references in the project or inherited build files, referenced projects, namespace imports, `AppTagHelperOptions`, `CdnTagHelperOptions`, `_ViewImports.cshtml` registration, and actual `app-*`/`cdn-*` elements;
- custom `AppAssetOptions`-style types, options registrations, Razor injections, and `GetUrl`/`GetAssetUrl`-style calls;
- coexistence of Cuemon and a competing custom abstraction;
- stale attribute-style syntax and cache-busting signals such as `asp-append-version` and `ICacheBusting`.

Use these facts to decide what the agent should edit. Do not turn the runner into a general source-code migration engine.

## Critical invariants

- Keep `wwwroot` as the authoring root and `/cdnroot` as the container content root. Do not resurrect `approot`.
- Exclude application-owned `wwwroot` from the deployed web application's publish artifact with targeted metadata: `<Content Update="wwwroot/**" CopyToPublishDirectory="Never" />`.
- Do not use `<StaticWebAssetsEnabled>false</StaticWebAssetsEnabled>` as a blanket solution. Preserve Blazor, RCL, framework, generated, and frontend Static Web Assets guards; stop for an explicit generated-static-assets design when those outputs cannot be safely materialized and verified.
- Static assets are served by `codebeltnet/web-cdn-origin:2.0.0`; local `/cdnroot` mounts remain read-only and the runtime remains non-root.
- App assets and shared CDN assets are separate concepts. Always determine whether a shared/CDN equivalent exists before deciding origins or markup. Never copy shared content into an application's `wwwroot`.
- Preserve ordinary Development. Segregated Development is opt-in through `http-segregated-assets`.
- Verification is deterministic and re-running the skill is idempotent. Never claim the publish invariant from an MSBuild declaration alone; run `verify --run-publish`.
- Do not add Cuemon merely to implement this skill when the application otherwise does not use it.
- When an existing NuGet package must be updated for the migration, use the exact latest-stable version emitted by the current `plan` run. Preserve Central Package Management by updating its existing `PackageVersion`; otherwise update the existing `PackageReference`. Never introduce an inline version beside CPM or fall back to a stale literal when NuGet resolution fails.

## Decision hierarchy for asset URL abstractions

Existing framework and project abstractions are preferred over skill-invented abstractions. Resolve the following order after `inspect`:

1. **Cuemon is already available.** Reuse `Cuemon.AspNetCore.Razor.TagHelpers`, `AppTagHelperOptions`, and `CdnTagHelperOptions`. For an actual package reference, take its version only from the current runner plan's NuGet-backed `resolvedNuGetPackages` result; a project-reference-only setup needs no NuGet version. Do not create `AppAssetOptions`, `SegregatedAssetsOptions`, another `GetAssetUrl()` abstraction, or a second configuration hierarchy. If a previous migration created a custom abstraction, migrate it away as described below.
2. **A suitable non-Cuemon abstraction exists.** Reuse it. Do not add Cuemon solely because the skill knows about it.
3. **No suitable abstraction exists.** Introduce only the smallest app-owned configuration mechanism needed by the existing application, and only after confirming that no framework/project abstraction is available.

When Cuemon is detected through multiple signals, use the referenced package/source to confirm its exact current configuration surface. The current public model exposes `TagHelperOptions.BaseUrlMode` with `TagHelperBaseUrlMode.Configured` and `TagHelperBaseUrlMode.Automatic`, alongside `BaseUrl` and `ProtocolUriScheme`. For App assets, set `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic`: an explicit App `BaseUrl` wins, while an absent App `BaseUrl` resolves against the active application request. Keep CDN assets explicitly configured with `CdnTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Configured` and an explicit CDN base. Cuemon does not inspect launch-profile names.

## App/CDN ownership and Razor migration

Classify every static reference by ownership before changing it.

App assets are owned by exactly one application: its CSS, JavaScript, branding, images, favicons, manifest, application fonts, and application-specific media. Shared CDN assets are reusable across applications: Bootstrap, Font Awesome, shared fonts, design-system packages, reusable JavaScript/CSS libraries, and common images. A file's current directory or URL shape does not establish ownership.

When Cuemon is available, use its current public custom-element syntax:

```html
<app-link rel="icon" href="favicon.svg" type="image/svg+xml" />
<app-link rel="mask-icon" href="mask-icon.svg" type="image/svg+xml" color="#000000" />
<app-link rel="apple-touch-icon" href="apple-touch-icon.png" type="image/png" />
<app-link rel="manifest" href="manifest.json" type="application/json" />
<app-link href="css/site.css" />
<app-script src="js/site.js"></app-script>
<app-image src="images/logo.svg" alt="Logo" />

<cdn-link href="packages/fontawesome/7.0.0/css/all.min.css" />
<cdn-link href="packages/bootstrap/5.3.3/css/bootstrap.min.css" />
<cdn-script src="packages/htmx/2.0.4/htmx.min.js"></cdn-script>
<cdn-image src="packages/shared/logo.svg" alt="Shared logo" />
```

These elements preserve meaningful attributes such as `as`, `crossorigin`, `color`, `rel`, and `type`. Do not document or emit attribute-style substitutes that the referenced package does not expose. Never mechanically convert every reference to App or every external-looking reference to CDN; determine ownership and use the corresponding helper.

For an existing manual URL expression such as an injected options object's `GetUrl` call, locate all consumers, classify each path, migrate the Razor semantically, and then remove redundant Razor injections, DI/options registrations, and obsolete configuration only when it is proven exclusive to the old abstraction. Delete `AppAssetOptions` only after no consumers remain. Do not leave two URL-generation systems behind.

Inspect cache busting during this migration. Preserve the application's existing `asp-append-version`, Cuemon `ICacheBusting`, content-addressed filenames, or other versioning behavior. Do not blindly place Microsoft's `asp-append-version` on a Cuemon custom element and assume the Microsoft TagHelper will process it. Do not introduce a second cache-busting mechanism; report any case that requires an explicit design decision.

When the referenced Cuemon TagHelpers API exposes the enhanced `CacheBustingTagHelper` path, its App/CDN link, script, and image helpers receive an optional `ICacheBusting` service through DI. The helper resolves the configured or request-derived base URL through the current `ViewContext` — including the request scheme, host, and `PathBase` — and appends the version query consistently. Automatic mode still gives an explicit `BaseUrl` precedence, and helper paths should be asset-relative (`css/site.css`) rather than another URL-composition expression. If the application already registers `ICacheBusting` — including an existing `AddAssemblyCacheBusting()`, `AddDynamicCacheBusting()`, or `AddCacheBusting<T>()` registration — preserve that registration and let the Cuemon helper consume it. Do not add a cache-busting registration or the `Cuemon.Extensions.AspNetCore` package merely to implement segregation. Before emitting `BaseUrlMode`, `TagHelperBaseUrlMode`, or this enhanced cache-busting behavior, verify that the referenced Cuemon package or source actually exposes those members; report an upgrade/version decision instead of inventing a compatibility abstraction.

## Configuration and topology

Configuration declares location; Razor declares ownership. Do not encode deployment hostnames or environment names in Razor.

### Ordinary Development

Do not modify the existing ordinary Development profile merely to support segregation. For Cuemon App assets, set `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic` through normal application configuration and leave App `BaseUrl` absent. The same `<app-link>`, `<app-script>`, and `<app-image>` markup then resolves against the application itself:

```text
browser -> application -> normal wwwroot
```

For a non-Cuemon abstraction, preserve its existing current-host/default behavior instead of adding segregation-specific settings to ordinary Development.

### Segregated Development

Keep or add the opt-in `http-segregated-assets` profile. It should override only the segregated topology. For Cuemon, bind the existing `AppTagHelperOptions` section with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, host-only `BaseUrl = localhost:<app-origin-port>`, and `Scheme = ProtocolUriScheme.Http`; adapt environment-variable names to the application's existing binding structure. The application profile itself must be HTTP. When a local shared origin exists, bind `CdnTagHelperOptions` with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, host-only `BaseUrl = localhost:<cdn-origin-port>`, and `Scheme = ProtocolUriScheme.Http`.

Never emit a protocol-relative or HTTPS URL to an HTTP-only local origin. Do not add a second `SegregatedAssets` hierarchy beside existing Cuemon sections. A `commandName: Project` profile sets application configuration; it does not start sidecars.

The local topology is:

```text
browser -> ASP.NET Core application
browser -> http://localhost:<app-origin-port> -> web-cdn-origin:2.0.0 -> application wwwroot (read-only)
browser -> http://localhost:<cdn-origin-port> -> web-cdn-origin:2.0.0 -> shared CDN root (read-only, only when applicable)
```

Use `compose.assets.yml` when a dedicated Compose file fits the repository, invoke it explicitly with `docker compose -f compose.assets.yml ...`, and preserve an existing orchestration mechanism when it already expresses the topology cleanly. Use the hardened posture from `references/local-development.md`.

### Deployment

Deployment configuration supplies the external HTTPS locations. For Cuemon App assets, configure the existing `AppTagHelperOptions` binding with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, the deployed App asset host, and `Scheme = ProtocolUriScheme.Https`; configure `CdnTagHelperOptions` with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, the deployed shared/CDN host, and `Scheme = ProtocolUriScheme.Https` only when a shared equivalent exists. The same Razor markup then resolves to the configured hosts. CDN assets must never fall back to the application host.

## Static Web Assets and production image

Read `references/static-web-assets-guardrail.md` before applying the publish exclusion. For a simple physical `wwwroot`, add the targeted metadata, preserve existing `MapStaticAssets`/`UseStaticFiles` behavior unless a safe local-only adjustment is proven, and build the final asset output before packaging it.

Use a derived PascalCase `<something>.Dockerfile` — canonically `Assets.Dockerfile` — selected explicitly with Docker `--file`:

```dockerfile
FROM codebeltnet/web-cdn-origin:2.0.0

COPY --chown=65532:65532 ./wwwroot/ /cdnroot/
```

Do not override the base image's `/cdnroot`, port, runtime user (`65532`), or working directory without evidence. If a frontend build generates `wwwroot`, package the generated output, not source inputs, and preserve the existing CI/CD artifact flow.

## Workflow

1. Run `inspect --repo-root <root> --json` and read `FORMS.md` plus the relevant references. Resolve ambiguous projects and the required CDN-equivalent question.
2. Stop for `RiskyGeneratedAssets` unless a complete generated-output design and runtime URL behavior can be established. Never bypass the guardrail to make the simple template fit.
3. Run `plan --repo-root <root> --project <project> --json`, adding `--cdn-equivalent` when selected. For an existing Cuemon package reference, require the NuGet-backed latest-stable result and use its exact version; stop on dependency-resolution failure.
4. Resolve the abstraction hierarchy and classify App versus CDN references. Use the agent to edit source/configuration; the runner remains non-mutating.
5. Apply targeted publish metadata, the opt-in local profile, the local read-only origin(s), production asset image, and documentation idempotently.
6. Run `verify --run-publish --check-local --json` against the selected project. It must prove application-owned `wwwroot` files are absent from the web publish artifact while permitted `_content`/`_framework` assets remain and local origins are scheme-safe/hardened.
7. Re-run `inspect`/`plan` to confirm no duplicate items, profiles, services, Dockerfiles, ports, competing asset configuration, or stale package versions were introduced.

## Boundaries

- Keep `wwwroot` as the authoring root and `/cdnroot` as the delivery root; never resurrect `approot`.
- Preserve the framework, RCL, generated, scoped-CSS, component-JavaScript, and frontend Static Web Assets pipeline.
- Keep App and shared CDN ownership explicit; never duplicate shared content into an application's `wwwroot`.
- Reuse existing Cuemon or project abstractions, and add no dependency solely for this migration.
- Resolve versions for existing package references from NuGet.org during the current plan, exclude prereleases, preserve the repository's package-management owner, and fail closed rather than guessing.
- Keep sidecar startup explicit, verification output isolated, and runner behavior deterministic and non-mutating.
- Escalate generated-static-assets scenarios when a complete external artifact and runtime URL design cannot be proven.

## References

- `FORMS.md` — unresolved inputs and deterministic one-field-at-a-time collection.
- `references/app-vs-cdn.md` — ownership, verified Cuemon custom-element mapping, Automatic/App/CDN configuration semantics, and cache-busting guidance.
- `references/local-development.md` — ordinary versus opt-in segregated Development and the local Static Content Provider topology.
- `references/production-image.md` — derived image, publish exclusion, deployment configuration, CI/CD artifact integration, and documentation template.
- `references/static-web-assets-guardrail.md` — Blazor, RCL, generated, scoped-CSS, component-JS, and frontend-build safety handling.
