# Production asset image, publish exclusion, and documentation

Two things happen at deployment: the application-owned static assets are shipped as their own immutable image based on `codebeltnet/web-cdn-origin:2.0.0`, and the deployed web application stops carrying a duplicate copy of those files.

## Runtime URL configuration

The Razor declaration stays the same across local and deployed topologies. With Cuemon, application-owned references use `app-*` helpers and shared references use `cdn-*` helpers. Deployment configuration supplies location through the already-bound `AppTagHelperOptions` and, when a shared surface exists, `CdnTagHelperOptions`:

```text
App: BaseUrl = assets.example.com, Scheme = Https
Cdn: BaseUrl = cdn.example.com, Scheme = Https
```

Use the exact configuration keys and binding shape already present in the application. Do not encode hostnames or environment names in Razor, create a second options hierarchy, or enable application-host fallback for CDN helpers. If no shared CDN equivalent exists, omit the CDN origin and configuration rather than reclassifying App assets.

When the application has no bound section yet, bind Cuemon's `AppTagHelperOptions` from `SegregatedAssets:App` and `CdnTagHelperOptions` from `SegregatedAssets:Cdn`. That section name is a location for the existing Cuemon options types, not a competing abstraction; what the skill forbids is a second options type or a parallel URL-generation hierarchy beside the Cuemon ones. Whichever section is actually bound is then the single source for the Compose environment keys (`<Section>__BaseUrl`, `<Section>__BaseUrlMode`, `<Section>__Scheme`), the deployed configuration, and the documentation, so all three always agree. Write the full shape into `appsettings.json` — `BaseUrlMode`, an empty `BaseUrl`, and `Scheme` — so the deployment knobs are discoverable rather than implied:

```json
{
  "SegregatedAssets": {
    "App": {
      "BaseUrlMode": "Automatic",
      "BaseUrl": "",
      "Scheme": "Https"
    }
  }
}
```

In ordinary Development, set `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic` and omit App `BaseUrl`, so the current application request supplies the location. In the root `<ordinary-project-profile>.Assets` Docker Compose profile, keep Automatic mode, provide the explicit host-only local App `BaseUrl`, and use `Scheme = ProtocolUriScheme.Http`; the explicit App host wins. In deployment, keep Automatic mode with the explicit HTTPS App host. Keep `CdnTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Configured` and provide an explicit CDN host wherever shared content exists.

## Derived asset image

Name the derived Dockerfile `<something>.Dockerfile` with a PascalCase `<something>` prefix. For this skill the canonical name is `Assets.Dockerfile`. Select it with `docker build --file Assets.Dockerfile ...` or the equivalent Compose `dockerfile: Assets.Dockerfile` setting. When a dedicated local Compose file is used, name it `compose.assets.yml`. See the [Dockerfile overview](https://docs.docker.com/build/concepts/dockerfile/).

`Assets.Dockerfile` lives **beside the web `.csproj`**, in the same directory as the `wwwroot` it packages, together with `Dockerfile` and `LocalDevelopment.Dockerfile`. Its build context is that project directory, which is what keeps the copy expression the single relative line below instead of a path that reaches across the repository. `references/local-development.md` holds the full placement table; `assets/Assets.Dockerfile` holds the literal template.

When application-owned assets ship as a container image, use `web-cdn-origin:2.0.0` as the base. The normal derived image is conceptually no more complicated than copying the final `wwwroot` output into the image's content root:

```dockerfile
FROM codebeltnet/web-cdn-origin:2.0.0

COPY --chown=65532:65532 ./wwwroot/ /cdnroot/
```

Version 2.0 owns its `/cdnroot`, its port (`8080`), its runtime user (`65532`), and its application working directory. Do not override them without a demonstrated requirement, and prefer `COPY` over `ADD` when no `ADD` behavior is needed. Adapt only the source path and ownership when actual build conventions require it.

Use the base image's established port, `/cdnroot`, runtime user, and working directory so the derived asset image remains compatible with the published origin contract.

If the application's frontend build generates the final files rather than storing them directly in source `wwwroot`, identify and preserve that generation pipeline and build it before the image is assembled: the image must contain the **actual final asset output**, not stale source inputs.

The Docker build input must be reproducible from a clean checkout. Do not ignore the only `wwwroot` source while relying on `COPY ./wwwroot/ /cdnroot/`; that leaves local files which work only on the current machine. Keep the source tracked, use Git LFS for large binary assets, or materialize it from an immutable pinned artifact before `docker build`. A tracked repository-level asset root can provide stronger physical separation from the application project, but the application's ordinary web root, Docker build context, CI inputs, and verification must all point to that same root.

## CI/CD integration

Where CI/CD already builds once and promotes artifacts, preserve that model. Static assets can be emitted as their own build artifact and subsequently packaged into the Static Content Provider image, rather than being rebuilt during image publication. When repository CI builds the application container, add a separate build or validation for `Assets.Dockerfile` from the same commit; deployment must not depend on an image that only local Compose has ever constructed. When Visual Studio Compose requires an application container, use the same artifact-first boundary for the application: CI publishes to `artifacts/publish/`, production `Dockerfile` copies that directory into a shell-less DHI ASP.NET Core runtime, and `LocalDevelopment.Dockerfile` copies the same directory into the matching ASP.NET `-dev` runtime for Visual Studio. The `-dev` runtime supplies development utilities but is not an SDK. Neither Dockerfile compiles source; the web project's guarded local build hook supplies the artifact for Visual Studio. Document the integration points, but do not redesign CI/CD unless explicitly asked.

Adding the artifact-first `Dockerfile` therefore obliges you to add its producer in the same change. An image whose only instruction is `COPY artifacts/publish/ .` is inert in a clean hosted checkout unless a CI job publishes to that exact path first, so the CI extension is part of the deliverable rather than optional follow-up.

Do not wait to be asked for it. A repository author migrating to segregated assets is thinking about static files, not about the fact that an artifact-first image needs an artifact producer; that gap is exactly the kind of thing the skill exists to close. GitHub Actions is the assumed delivery surface, so there are only two cases:

1. **A workflow exists.** Append the two jobs in `assets/ci-artifact-jobs.yml` to it. `publish` runs `dotnet publish --output artifacts/publish` and uploads it; `docker-build` downloads the same artifact and builds **both** `Dockerfile` and `Assets.Dockerfile` from that one commit. Keep the repository's existing reusable `build` and `test` jobs and chain the new jobs behind them with `needs:` rather than replacing anything. A workflow that only builds and tests still has no producer — it needs the publish job.
2. **No workflow exists.** Create `.github/workflows/ci-pipeline.yml` from `assets/ci-pipeline.yml` and say plainly in the summary that the repository had no pipeline and now has one, so the addition is a visible decision rather than a silent one.

Name which one you did in the final summary. The failure this prevents is a green local Compose run beside a production image that no hosted build has ever constructed.

## Excluding application-owned wwwroot from web publish

The deployed web application must not carry a duplicate copy of its application-owned `wwwroot` files. Prefer **targeted** handling of the application's own `wwwroot` using supported MSBuild item metadata:

```xml
<ItemGroup>
  <Content Update="wwwroot/**" CopyToPublishDirectory="Never" />
</ItemGroup>
```

Keep the Static Web Assets pipeline active for Razor Class Library (`_content/…`) and framework (`_framework/…`) content. The targeted `Content Update` item affects only the application's own `wwwroot`; contributed and framework static web assets continue through their own publish items.

Do not assume the declaration is sufficient merely because it looks correct — the interaction between the `Content` items and the Static Web Assets publish pipeline must be confirmed empirically.

### Verified behavior

Against a conventional `Microsoft.NET.Sdk.Web` application on .NET 10 that calls `MapStaticAssets`:

- `Content Update="wwwroot/**" CopyToPublishDirectory="Never"` removes application-owned files from the publish artifact while leaving the Static Web Assets manifest available.
- A referenced Razor Class Library's `wwwroot/_content/<Lib>/…` assets and their compressed variants remain in publish.
- Framework assets remain available through the framework Static Web Assets pipeline.

## Verifying the publish invariant

Prove the invariant instead of trusting the declaration. `verify` publishes to an isolated temporary directory and asserts application-owned `wwwroot` files are absent (shared `_content`/`_framework` assets may remain):

```
dotnet run --file "<skill-root>/scripts/segregate-assets.cs" -- verify --repo-root "<root>" -p "<web.csproj>" --run-publish --check-local --json
```

The required invariant for a supported ordinary MVC/Razor application is: **application-owned files from source `wwwroot` are absent from the deployed web application publish artifact.** Never write verification output into the repository — the runner publishes into a temp directory it owns and removes.

## ASP.NET Core static serving

Inspect how the application currently serves static assets — `MapStaticAssets`, `UseStaticFiles`, custom file providers or endpoints, Blazor static assets, Razor Class Library assets, generated/scoped CSS, and frontend-generated assets — before changing anything. Do not mechanically delete static-file calls. For ordinary MVC/Razor applications, prefer limiting application-owned static serving to local Development when that can be done safely and without changing unrelated behavior. The production invariant that matters is that application-owned assets are requested from the external App asset host and are not deployed as duplicate files with the web application. Generated Static Web Assets scenarios are handled in `references/static-web-assets-guardrail.md`.

## Documentation template

Update the application's documentation to state that deployed static content is intentionally served by Codebelt Static Content Provider rather than the ASP.NET Core business application, and that `wwwroot` remains in the project specifically because it is the conventional, tooling-friendly authoring location. Document both workflows:

```text
Normal Development
developer edits wwwroot
        |
        v
application's normal Development experience

Segregated Development
developer edits wwwroot
        |
        v
Assets.Dockerfile build (or an explicit read-only /cdnroot mount)
        |
        v
web-cdn-origin:2.0.0
        |
        v
browser requests external App asset URL

Deployment
wwwroot / static asset artifact
        |
        v
derived web-cdn-origin image
        |
        v
asset host / optional CDN
```

When a shared CDN asset source exists, show it as a separate parallel flow (shared-cdn-root -> web-cdn-origin image / CDN) rather than merging it with the App asset flow.
