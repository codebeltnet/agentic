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

- Keep `wwwroot` as the conventional authoring root and `/cdnroot` as the container content root. The asset-image input must be reproducible from a clean checkout: do not ignore the only source copy. A tracked repository-level asset root is a valid alternative only when the ordinary application web root, Docker build context, CI inputs, and verification are changed together. Do not resurrect `approot`.
- Exclude application-owned `wwwroot` from the deployed web application's publish artifact with targeted metadata: `<Content Update="wwwroot/**" CopyToPublishDirectory="Never" />`.
- Do not use `<StaticWebAssetsEnabled>false</StaticWebAssetsEnabled>` as a blanket solution. Preserve Blazor, RCL, framework, generated, and frontend Static Web Assets guards; stop for an explicit generated-static-assets design when those outputs cannot be safely materialized and verified.
- Static assets are served by `codebeltnet/web-cdn-origin:2.0.0`; local asset content is supplied by `Assets.Dockerfile` or an explicit read-only `/cdnroot` mount, and the runtime remains non-root.
- File placement is part of the contract. `Dockerfile`, `LocalDevelopment.Dockerfile`, and `Assets.Dockerfile` live beside the web `.csproj`; `compose.assets.yml`, `.dockerignore`, `docker-compose.dcproj`, and the Compose `launchSettings.json` live at the repository root. Never place a Dockerfile at the repository root for this topology.
- Write every generated file from the literal template in `assets/`, substituting the documented placeholders. Do not reconstruct a Dockerfile, Compose file, `.dcproj`, or launch profile from memory.
- Both application Dockerfiles are artifact-first: they package an already-published `artifacts/publish/` directory and never restore, build, or publish source. An SDK stage, a `dotnet build`/`dotnet publish` step, a `RUN adduser` block, or an `mcr.microsoft.com` runtime tag in either file is a defect.
- When repository CI builds the application container, it must also build or validate `Assets.Dockerfile` from the same commit. A locally working asset image that hosted CI never constructs is not a proven deployment artifact. Adding an artifact-first `Dockerfile` also obliges you to add the CI job that publishes the artifact it copies.
- App assets and shared CDN assets are separate concepts. Always determine whether a shared/CDN equivalent exists before deciding origins or markup. Never copy shared content into an application's `wwwroot`.
- Preserve ordinary Development through the existing Project profile. Name the root Docker Compose profile by appending `.Assets` to that ordinary profile name, for example `BingeKinLanding.WebApp` becomes `BingeKinLanding.WebApp.Assets`.
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

When Cuemon is available, treat each TagHelper class's `HtmlTargetElement` attribute as the selector contract; never infer a selector from the class name. The current public selectors are `app-link`, `app-script`, `app-img`, `cdn-link`, `cdn-script`, and `cdn-img`:

```html
<app-link rel="icon" href="favicon.svg" type="image/svg+xml" />
<app-link rel="mask-icon" href="mask-icon.svg" type="image/svg+xml" color="#000000" />
<app-link rel="apple-touch-icon" href="apple-touch-icon.png" type="image/png" />
<app-link rel="manifest" href="manifest.json" type="application/json" />
<app-link href="css/site.css" />
<app-script src="js/site.js"></app-script>
<app-img src="images/logo.svg" alt="Logo" />

<cdn-link href="packages/fontawesome/7.0.0/css/all.min.css" />
<cdn-link href="packages/bootstrap/5.3.3/css/bootstrap.min.css" />
<cdn-script src="packages/htmx/2.0.4/htmx.min.js"></cdn-script>
<cdn-img src="packages/shared/logo.svg" alt="Shared logo" />
```

These elements preserve meaningful attributes such as `as`, `crossorigin`, `color`, `rel`, and `type`. Do not document or emit attribute-style substitutes that the referenced package does not expose. Never mechanically convert every reference to App or every external-looking reference to CDN; determine ownership and use the corresponding helper.

For an existing manual URL expression such as an injected options object's `GetUrl` call, locate all consumers, classify each path, migrate the Razor semantically, and then remove redundant Razor injections, DI/options registrations, and obsolete configuration only when it is proven exclusive to the old abstraction. Delete `AppAssetOptions` only after no consumers remain. Do not leave two URL-generation systems behind.

Inspect cache busting during this migration. Preserve the application's existing `asp-append-version`, Cuemon `ICacheBusting`, content-addressed filenames, or other versioning behavior. Do not blindly place Microsoft's `asp-append-version` on a Cuemon custom element and assume the Microsoft TagHelper will process it. Do not introduce a second cache-busting mechanism; report any case that requires an explicit design decision.

When the referenced Cuemon TagHelpers API exposes the enhanced `CacheBustingTagHelper` path, its App/CDN link, script, and image helpers receive an optional `ICacheBusting` service through DI. The helper resolves the configured or request-derived base URL through the current `ViewContext` — including the request scheme, host, and `PathBase` — and appends the version query consistently. Automatic mode still gives an explicit `BaseUrl` precedence, and helper paths should be asset-relative (`css/site.css`) rather than another URL-composition expression. If the application already registers `ICacheBusting` — including an existing `AddAssemblyCacheBusting()`, `AddDynamicCacheBusting()`, or `AddCacheBusting<T>()` registration — preserve that registration and let the Cuemon helper consume it. Do not add a cache-busting registration or the `Cuemon.Extensions.AspNetCore` package merely to implement segregation. Before emitting `BaseUrlMode`, `TagHelperBaseUrlMode`, or this enhanced cache-busting behavior, verify that the referenced Cuemon package or source actually exposes those members; report an upgrade/version decision instead of inventing a compatibility abstraction.

## Configuration and topology

Configuration declares location; Razor declares ownership. Do not encode deployment hostnames or environment names in Razor.

### Ordinary Development

Do not modify the existing ordinary Development profile merely to support segregation. For Cuemon App assets, set `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic` through normal application configuration and leave App `BaseUrl` absent. The same `<app-link>`, `<app-script>`, and `<app-img>` markup then resolves against the application itself:

```text
browser -> application -> normal wwwroot
```

For a non-Cuemon abstraction, preserve its existing current-host/default behavior instead of adding segregation-specific settings to ordinary Development.

### Segregated Development

Keep ordinary Development on the existing project launch profile, which serves `wwwroot` directly. Add the opt-in `<ordinary-project-profile>.Assets` profile only on the root Docker Compose launch surface; do not add a redundant project-level profile with the same name. Prefer an exact project-name `commandName: Project` profile; otherwise use the sole Project profile, falling back to the `.csproj` stem when the project launch surface is absent or ambiguous. Put the segregated settings in the Compose web service environment. For Cuemon, bind the existing `AppTagHelperOptions` section with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, host-only `BaseUrl = localhost:<app-origin-port>`, and `Scheme = ProtocolUriScheme.Http`. When a local shared origin exists, bind `CdnTagHelperOptions` with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, host-only `BaseUrl = localhost:<cdn-origin-port>`, and `Scheme = ProtocolUriScheme.Http`.

Reuse whatever configuration section the application already binds. When none exists, bind the Cuemon options types from `SegregatedAssets:App` and `SegregatedAssets:Cdn`; that is a location for the existing Cuemon types, not a second abstraction. What is forbidden is a parallel options type or URL-generation hierarchy beside `AppTagHelperOptions`/`CdnTagHelperOptions`. Derive the Compose environment keys, deployed configuration, and documentation from whichever section is actually bound so all three agree.

Never emit a protocol-relative or HTTPS URL to an HTTP-only local origin. A `commandName: Project` profile does not start sidecars, so the segregated path is the complete Compose topology. `compose.assets.yml` directly builds the web service with `LocalDevelopment.Dockerfile` and the asset service with `Assets.Dockerfile`; do not add `DockerfileFile` or `BuildingInsideVisualStudio`. The two services use different build contexts — repository root for the web service so `artifacts/publish/` resolves, project directory for the asset service so `wwwroot` resolves. Keep the service names `web-app` and `app-assets`, omit the obsolete top-level `version:` key, and add no custom `networks:` block. Publish the web service on the ordinary Project profile's HTTP `applicationUrl` port so both Development modes share one origin; do not invent a round number such as `5000`. Add `labels: { com.microsoft.visual-studio.project-name: "" }` to the asset service. The empty association keeps Visual Studio from applying the web project's debugger bootstrap to the build-backed asset container, so do not add `docker-compose.vs.release.yml`.

Whenever `compose.assets.yml` exists, the local web image is artifact-first: define `LocalPublishDirectory` and `DockerfileContext` in the web `.csproj`, publish there from a guarded non-CI, non-design-time post-build target, add the root `.dockerignore` without excluding `artifacts/`, add `artifacts/` to `.gitignore`, and publish the same artifact explicitly in CI alongside both image builds. Production `Dockerfile` uses the newest compatible shell-less `dhi.io/aspnetcore` Alpine runtime; `LocalDevelopment.Dockerfile` uses the matching `dhi.io/aspnetcore:<channel>-alpine<version>-dev` runtime. The ASP.NET `-dev` image supplies development utilities and debugger prerequisites but is not a .NET SDK image. Neither Dockerfile compiles source; copy published files for user `65532`.

Visual Studio one-click Compose adds the IDE registration on top: add or reuse a `Microsoft.Docker.Sdk` `.dcproj`, point `DockerComposeBaseFilePath` at `compose.assets`, use `DockerDevelopmentMode=Regular`, associate the web project through `DockerComposeProjectPath` plus `DockerDefaultTargetOS` and a `Microsoft.VisualStudio.Azure.Containers.Tools.Targets` reference, add the root `DockerCompose` profile, register the Compose project in the solution, and start the application service with debugging plus asset origins without debugging. Preserve an existing Visual Studio Compose project and its conventions.

The local topology is:

```text
browser -> ASP.NET Core application
browser -> http://localhost:<app-origin-port> -> Assets.Dockerfile -> web-cdn-origin:2.0.0 -> application wwwroot snapshot
browser -> http://localhost:<cdn-origin-port> -> web-cdn-origin:2.0.0 -> shared CDN root (only when applicable)
```

Use `compose.assets.yml` when a dedicated Compose file fits the repository, invoke it explicitly with `docker compose -f compose.assets.yml ...`, and preserve an existing orchestration mechanism when it already expresses the topology cleanly. A `Docker` launch profile runs one project container and does not consume this Compose file; Visual Studio Compose integration uses `commandName: DockerCompose` on the `.dcproj` launch surface. Use the hardened posture from `references/local-development.md`.

### Deployment

Deployment configuration supplies the external HTTPS locations. For Cuemon App assets, configure the existing `AppTagHelperOptions` binding with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, the deployed App asset host, and `Scheme = ProtocolUriScheme.Https`; configure `CdnTagHelperOptions` with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, the deployed shared/CDN host, and `Scheme = ProtocolUriScheme.Https` only when a shared equivalent exists. The same Razor markup then resolves to the configured hosts. CDN assets must never fall back to the application host.

## Static Web Assets and production image

Read `references/static-web-assets-guardrail.md` before applying the publish exclusion. For a simple physical `wwwroot`, add the targeted metadata, preserve existing `MapStaticAssets`/`UseStaticFiles` behavior unless a safe local-only adjustment is proven, and build the final asset output before packaging it.

Use a derived PascalCase `<something>.Dockerfile` — canonically `Assets.Dockerfile` — placed beside the web `.csproj` and selected explicitly with Docker `--file`:

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
5. Apply targeted publish metadata, the root opt-in Compose profile, the local origin(s), production asset image, and documentation idempotently. Write each file from its `assets/` template into the location fixed by the placement table in `references/local-development.md`. Whenever `compose.assets.yml` is created, this always includes artifact-first `Dockerfile` and `LocalDevelopment.Dockerfile` beside the `.csproj`, `Assets.Dockerfile` beside the `wwwroot` it packages, `.csproj` `LocalPublishDirectory` and `DockerfileContext`, the guarded local publish target, the root `.dockerignore`, `artifacts/` in `.gitignore`, direct Dockerfile selection with per-service build contexts in `compose.assets.yml`, the asset service's empty `com.microsoft.visual-studio.project-name` label, and the CI publish plus both image builds. When Visual Studio one-click Compose is selected, additionally include `.dcproj`, `DockerComposeProjectPath`, Compose launch settings, and solution registration. Remove a redundant project-level legacy segregated profile and remove `docker-compose.vs.release.yml` when it only repaired debugger injection.
6. Run `verify --run-publish --check-local --json` against the selected project. It must prove application-owned `wwwroot` files are absent from the web publish artifact while permitted `_content`/`_framework` assets remain, the asset source is reproducible from versioned or pinned input, repository CI does not omit `Assets.Dockerfile` from its container build surface, the asset service opts out of Visual Studio project association, local origins are scheme-safe/hardened, and the artifact-first contract holds — Dockerfiles beside the project, no SDK stage or `dotnet build`/`dotnet publish` in either application Dockerfile, a root `.dockerignore` that keeps `artifacts/`, a declared `LocalPublishDirectory` with a guarded publish target, no obsolete Compose `version:` key, and a CI job that publishes the artifact those Dockerfiles copy. If one-click Visual Studio Compose was requested and Visual Studio plus Docker are available, press F5 on the Compose profile and require Run mode, a live `vsdbg --interpreter=vscode` process with the application as its child, no debugger bootstrap in the asset container, and HTTP 200 responses from both the web app and asset origin. A `.dcproj` build or Compose CLI smoke test is not proof of debugger attachment.
7. Re-run `inspect`/`plan` to confirm no duplicate items, profiles, services, Dockerfiles, ports, competing asset configuration, or stale package versions were introduced.

## Boundaries

- Keep the asset source reproducible from a clean checkout. Prefer tracked `wwwroot`; when separation inside the repository is intentional, move it to a tracked repository-level asset root and change the application's web root, Docker context, CI inputs, and verification as one design. Never ignore the sole source or resurrect `approot`.
- Preserve the framework, RCL, generated, scoped-CSS, component-JavaScript, and frontend Static Web Assets pipeline.
- Keep App and shared CDN ownership explicit; never duplicate shared content into an application's `wwwroot`.
- Reuse existing Cuemon or project abstractions, and add no dependency solely for this migration.
- Resolve versions for existing package references from NuGet.org during the current plan, exclude prereleases, preserve the repository's package-management owner, and fail closed rather than guessing.
- Keep sidecar startup explicit, verification output isolated, and runner behavior deterministic and non-mutating.
- Generate infrastructure files from the `assets/` templates at their fixed locations; never improvise a Dockerfile, Compose file, `.dcproj`, or launch profile, and never let an application Dockerfile compile source.
- Escalate generated-static-assets scenarios when a complete external artifact and runtime URL design cannot be proven.

## References

- `assets/` — literal templates for every generated file: `Dockerfile`, `LocalDevelopment.Dockerfile`, `Assets.Dockerfile`, `compose.assets.yml`, `.dockerignore`, `docker-compose.dcproj`, `launchSettings.json`, `LocalPublishTarget.targets`, and `ci-artifact-jobs.yml`.
- `FORMS.md` — unresolved inputs and deterministic one-field-at-a-time collection.
- `references/app-vs-cdn.md` — ownership, verified Cuemon custom-element mapping, Automatic/App/CDN configuration semantics, and cache-busting guidance.
- `references/local-development.md` — ordinary versus opt-in segregated Development and the local Static Content Provider topology.
- `references/production-image.md` — derived image, publish exclusion, deployment configuration, CI/CD artifact integration, and documentation template.
- `references/static-web-assets-guardrail.md` — Blazor, RCL, generated, scoped-CSS, component-JS, and frontend-build safety handling.
