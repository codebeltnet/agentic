# Production asset image, publish exclusion, and documentation

Two things happen at deployment: the application-owned static assets are shipped as their own immutable image based on `codebeltnet/web-cdn-origin:2.0.0`, and the deployed web application stops carrying a duplicate copy of those files.

## Derived asset image

Name the derived Dockerfile `<something>.Dockerfile` with a PascalCase `<something>` prefix. For this skill the canonical name is `Assets.Dockerfile`. Docker documents this convention for distinct Dockerfiles and the `--file` option for selecting a non-default filename; use `docker build --file Assets.Dockerfile ...` or the equivalent Compose `dockerfile: Assets.Dockerfile` setting. Do not use `Dockerfile.assets` or the lowercase `assets.Dockerfile` form. See the [Dockerfile overview](https://docs.docker.com/build/concepts/dockerfile/).

When application-owned assets ship as a container image, use `web-cdn-origin:2.0.0` as the base. The normal derived image is conceptually no more complicated than copying the final `wwwroot` output into the image's content root:

```dockerfile
FROM codebeltnet/web-cdn-origin:2.0.0

COPY --chown=65532:65532 ./wwwroot/ /cdnroot/
```

Version 2.0 owns its `/cdnroot`, its port (`8080`), its runtime user (`65532`), and its application working directory. Do not override them without a demonstrated requirement, and prefer `COPY` over `ADD` when no `ADD` behavior is needed. Adapt only the source path and ownership when actual build conventions require it.

Do **not** reintroduce the old 1.4 pattern (setting `ASPNETCORE_HTTP_PORTS`, `WORKDIR /cdnroot`, and `ADD approot .`). Version 2.0 already establishes those conventions, and re-declaring them fights the base image.

If the application's frontend build generates the final files rather than storing them directly in source `wwwroot`, identify and preserve that generation pipeline and build it before the image is assembled: the image must contain the **actual final asset output**, not stale source inputs.

## CI/CD integration

Where CI/CD already builds once and promotes artifacts, preserve that model. Static assets can be emitted as their own build artifact and subsequently packaged into the Static Content Provider image, rather than being rebuilt during image publication. Document the integration point (where the asset artifact is produced and where it is packaged), but do not redesign CI/CD unless explicitly asked.

## Excluding application-owned wwwroot from web publish

The deployed web application must not carry a duplicate copy of its application-owned `wwwroot` files. Prefer **targeted** handling of the application's own `wwwroot` using supported MSBuild item metadata:

```xml
<ItemGroup>
  <Content Update="wwwroot/**" CopyToPublishDirectory="Never" />
</ItemGroup>
```

Do **not** default to `<StaticWebAssetsEnabled>false</StaticWebAssetsEnabled>`. That global switch disables the entire Static Web Assets system, which also drops assets supplied by Razor Class Libraries (`_content/…`) and framework assets (`_framework/…`) and can break application or framework functionality. The targeted `Content Update` item only affects the application's own `wwwroot`; Razor Class Library and framework static web assets keep flowing to publish through their own items.

Do not assume the declaration is sufficient merely because it looks correct — the interaction between the `Content` items and the Static Web Assets publish pipeline must be confirmed empirically.

### Verified behavior

Against a conventional `Microsoft.NET.Sdk.Web` application on .NET 10 that calls `MapStaticAssets`:

- **Baseline (no exclusion):** `dotnet publish` produces `publish/wwwroot/…` containing every `wwwroot` file plus pre-compressed `.br`/`.gz` variants and a `*.staticwebassets.endpoints.json` manifest — the duplicate copy to eliminate.
- **With `Content Update="wwwroot/**" CopyToPublishDirectory="Never"`:** `publish/wwwroot` is absent entirely; the endpoints manifest remains but is empty (`{"Version":1,"ManifestType":"Publish","Endpoints":[]}`). App-owned assets are gone, and the Static Web Assets system stays enabled.
- **Same exclusion with a referenced Razor Class Library:** the app's own `wwwroot/*` is absent, while the RCL's `wwwroot/_content/<Lib>/…` (and its `.br`/`.gz`) **survives** in publish. This is exactly the outcome the global disable would wrongly destroy.

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
read-only bind mount
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
