---
name: dotnet-segregated-assets
description: >
  Migrate or configure an ASP.NET Core web application so developers keep authoring static files in the conventional wwwroot, while deployed static content is served by Codebelt Static Content Provider (codebeltnet/web-cdn-origin:2.0.0), a separate asset host rather than the web app. Use when asked to segregate static assets, move wwwroot off the web app, serve static files from a separate asset host, or stop shipping wwwroot with the app. Distinguishes App assets (app-owned, from wwwroot) from shared CDN assets, adds an http-segregated-assets launch profile, derives a production asset image, and excludes app-owned wwwroot from publish with targeted MSBuild metadata rather than disabling Static Web Assets globally. Escalates risky Blazor, RCL, and generated Static Web Assets scenarios. Do NOT use to build a general-purpose CDN or migrate non-ASP.NET static sites.
compatibility: >
  Requires the .NET SDK 10+ and PowerShell 7+. Docker is optional (only for the local origin).
---

# .NET Segregated Static Assets

Keep the developer experience developers already know — author static files in `wwwroot` — while making the **deployed** web application stop serving and stop shipping those files. In production the static content is delivered by **Codebelt Static Content Provider** (`codebeltnet/web-cdn-origin:2.0.0`), a separately built and deployed asset host, not by the ASP.NET Core business application.

The one invariant everything else follows from:

> `wwwroot` remains the application's conventional static-content **authoring root**, but it is **not** part of the deployed web application's static-content serving responsibility.

## Architecture: you orchestrate, the runner inspects and verifies

The bundled .NET file-based program `scripts/segregate-assets.cs` is the **deterministic layer**. You are the **orchestration layer**: understand intent, resolve the repository's real conventions, make the edits, and resolve the App-vs-CDN semantic choices. Route inspection and verification through the runner instead of guessing:

```
dotnet run --file "<skill-root>/scripts/segregate-assets.cs" -- <command> [options]
```

Commands: `inspect` (discover web projects, classify static-asset topology, detect risky Static Web Assets, report existing segregation), `plan` (resolve the target project, ports, and the ordered decision list without writing files), `verify` (publish to an isolated temp directory and prove app-owned `wwwroot` is absent, plus validate the local origin topology), and `--self-test`. Add `--json` to any command for machine-readable output. The runner never edits the repository — it inspects and verifies; **you** apply edits using the literal templates in `references/`, adapted to the project.

## Critical

- **Do not replace `wwwroot`.** Developers keep authoring there. Never introduce an `approot`, `cdnroot`, or `staticroot` source folder for app-owned assets, and never resurrect the removed 1.4 `ADD approot` / `WORKDIR /cdnroot` Dockerfile pattern. Version 2.0 owns its `/cdnroot`, port, runtime user, and working directory.
- **Exclude app-owned `wwwroot` from publish with targeted metadata, not a global kill switch.** Prefer `<Content Update="wwwroot/**" CopyToPublishDirectory="Never" />`. Do **not** default to `StaticWebAssetsEnabled` = false: that also drops Razor Class Library (`_content/…`) and framework (`_framework/…`) assets and can break the app. See `references/static-web-assets-guardrail.md`.
- **Never claim a declaration works because it looks right — prove it.** Application-owned files from source `wwwroot` must be absent from the publish artifact. Confirm with `verify --run-publish` against an isolated temp output; never write verification output into the repository.
- **App is not CDN.** App assets are app-owned and authored in `wwwroot`; CDN assets are shared across applications and must never be duplicated into an application's `wwwroot`. Always ask whether a CDN/shared-asset equivalent exists (`FORMS.md`).
- **Keep local URLs scheme-safe.** The local origin speaks HTTP on a host port. Point App asset URLs at `http://localhost:<port>` from an HTTP application profile. Never emit a protocol-relative (`//localhost:<port>`) or `https://localhost:<port>` URL that an HTTPS page would turn into an HTTPS request against an HTTP-only origin.
- **Motivation is architectural, not a connection trick.** The value is segregation of duties, independent deployment and scaling, explicit cache behavior, origin/CDN offloading, and a reduced application artifact — **not** HTTP/1.x domain sharding or extra browser connection parallelism (which is counter-productive on HTTP/2 and HTTP/3).

## Step 1: Inspect before changing anything

```
dotnet run --file "<skill-root>/scripts/segregate-assets.cs" -- inspect --repo-root "<root>" [--project <path>] --json
```

The runner returns candidate web projects, the resolved target, a `classification`, risk signals, and existing-segregation flags. Act on the classification:

| Classification | Meaning | What you do |
|---|---|---|
| `Simple` | Physical `wwwroot`, no risky generated assets | Apply App-asset segregation (Steps 3–6). |
| `RiskyGeneratedAssets` | Blazor/RCL/scoped-CSS/frontend-build/etc. detected | **Stop and escalate** (Step 2 guardrail). Do not blanket-exclude. |
| `AlreadySegregated` | Publish exclusion + segregated profile present | Reconcile idempotently — do not duplicate. |
| `Ambiguous` | Multiple web projects | Ask which project; pass `--project`. |
| `NoWwwroot` | Web app without `wwwroot` | Only configure CDN consumption if a CDN equivalent exists. |
| `NotAWebApp` | No `Microsoft.NET.Sdk.Web` project | Confirm the target repository. |

## Step 2: Collect intent and honor the guardrail

Read `FORMS.md` and infer what you can. The one question you must always resolve is whether a **CDN/shared-asset equivalent exists** — because it changes whether you provision a second origin and how shared assets are referenced. Never assume shared assets belong in the application's `wwwroot`.

If `inspect` reports `RiskyGeneratedAssets`, treat it as a **compatibility guardrail**. A blanket `wwwroot` publish exclusion or a global Static Web Assets disable can break Blazor Web Apps, Blazor WebAssembly, `_framework`/`_content` assets, Razor Class Libraries, scoped CSS, component JS modules, or frontend-generated output. If you cannot establish a safe, deterministic way to materialize the required generated output into the external asset artifact while preserving correct runtime references, **stop and report that the project needs an explicit generated-static-assets segregation design.** That is a successful safety outcome, not a failure. Details: `references/static-web-assets-guardrail.md`.

## Step 3: Segregate App assets

For a `Simple` project, apply these idempotently (skip any the runner already reports as present). All literal templates live in `references/` — read them and adapt paths, ports, and naming to the repository's conventions rather than copying blindly.

1. **Exclude app-owned `wwwroot` from web publish** — add the targeted `Content Update="wwwroot/**" CopyToPublishDirectory="Never"` item to the web project. (`references/production-image.md`)
2. **Add a segregated launch profile** — a new `http-segregated-assets` profile that keeps the app in Development but points App asset URLs at the local origin over HTTP. Preserve the ordinary Development profile untouched. (`references/local-development.md`)
3. **Provide a local Static Content Provider** — run `codebeltnet/web-cdn-origin:2.0.0` mounting the app's existing `wwwroot` into `/cdnroot` **read-only**, on a host port, with a hardened posture (non-root, read-only root filesystem where practical, no privileged mode, no Docker socket, no extra capabilities, only the required port). Prefer a tiny dedicated Compose file unless the repo already has an orchestration mechanism to extend. (`references/local-development.md`)

## Step 4: Configure App URL generation

Adapt to the application's existing URL-generation abstraction; do **not** add a Cuemon dependency just to implement this skill.

- **If Cuemon `AppTagHelperOptions`/`CdnTagHelperOptions` are already present:** set App local `BaseUrl` to the local App origin (`localhost:<app-port>`) with `Scheme = Http`; set CDN local `BaseUrl` to the local shared origin with `Scheme = Http` when a CDN equivalent exists; use `Scheme = Https` absolute URLs for deployed configuration. The default `Scheme = Relative` emits protocol-relative `//` URLs — unsafe against an HTTP-only local origin, so make the local scheme explicit.
- **If Cuemon is not used:** configure the application's own asset base-URL setting (for example a `SegregatedAssets:App:BaseUrl` / `:Scheme` option the app already reads, or its equivalent) and drive it from the launch profile's environment variables.

See `references/app-vs-cdn.md`.

## Step 5: CDN assets (only when an equivalent exists)

If a shared CDN equivalent exists, determine its existing source/configuration. When its content is locally available, provision a **second** local origin on a different host port:

```
localhost:<app-port> -> web-cdn-origin:2.0.0 -> <app>/wwwroot
localhost:<cdn-port> -> web-cdn-origin:2.0.0 -> <shared-cdn-root>
```

Point CDN asset URLs at that origin locally and at the shared/CDN host in deployment. Never copy CDN assets into the application's `wwwroot`.

## Step 6: Build the production asset image and verify

Add a derived image that ships the **actual final asset output** (run the frontend build first if the app generates its `wwwroot`):

Name the derived Dockerfile `<something>.Dockerfile` with a PascalCase `<something>` prefix. For this skill, use `Assets.Dockerfile`. This follows Docker's documented convention for distinct Dockerfiles; select the non-default file explicitly with `--file` (or the equivalent Compose `dockerfile` property). Do not use `Dockerfile.assets` or the lowercase `assets.Dockerfile` form.

```dockerfile
FROM codebeltnet/web-cdn-origin:2.0.0

COPY --chown=65532:65532 ./wwwroot/ /cdnroot/
```

Do not override the base image's `/cdnroot`, port, runtime user (`65532`), or working directory without a demonstrated requirement, and prefer `COPY` over `ADD`. Where CI/CD already builds once and promotes artifacts, emit the static assets as their own artifact and package them into the image rather than rebuilding. Document the integration point; do not redesign CI/CD. (`references/production-image.md`)

Then prove the invariant:

```
dotnet run --file "<skill-root>/scripts/segregate-assets.cs" -- verify --repo-root "<root>" -p "<web.csproj>" --run-publish --check-local --json
```

`verify` must report the app-owned `wwwroot` files ABSENT from the publish artifact (shared `_content`/`_framework` assets are allowed to remain) and the local topology as scheme-safe and hardened.

## Step 7: Document the two workflows

Update the application's documentation to state that deployed static content is intentionally served by Codebelt Static Content Provider, not the ASP.NET Core business application, and that `wwwroot` remains because it is the conventional, tooling-friendly authoring location. Show Normal Development, Segregated Development, and Deployment flows (and a separate parallel flow for shared CDN assets when one exists). Template in `references/production-image.md`.

## Idempotency

Running the skill again on a configured app must not create duplicate MSBuild items, launch profiles, Compose services, Dockerfiles, or documentation sections, must not increment ports unnecessarily, and must not overwrite customized URLs or introduce a competing asset-configuration system. Use `inspect` to detect existing segregation and reconcile it.

## What this skill must never do

- Replace `wwwroot` with an `approot`/`cdnroot` source folder, or reintroduce the 1.4 `ADD approot` pattern.
- Default to `StaticWebAssetsEnabled` = false, or blindly delete `MapStaticAssets`/`UseStaticFiles` without analysis.
- Duplicate CDN/shared assets into the application's `wwwroot`, or conflate App and CDN assets.
- Add a Cuemon dependency to a project that does not already use it.
- Claim a `commandName: Project` launch profile starts sidecar containers, or claim the separation improves performance through domain sharding.
- Write verification output into the repository, or force a partially broken migration when a generated-static-assets design is required.

## References

- `references/app-vs-cdn.md` — App vs CDN semantics, Cuemon tag-helper mapping, and the architectural motivation.
- `references/local-development.md` — the segregated launch profile and the local Static Content Provider (Compose) topology and security posture.
- `references/production-image.md` — the derived `web-cdn-origin` image, publish exclusion, CI/CD integration, and the documentation template.
- `references/static-web-assets-guardrail.md` — detecting and safely handling Blazor/RCL/generated Static Web Assets scenarios.
