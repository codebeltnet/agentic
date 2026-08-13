# App assets versus CDN assets

This distinction is the heart of the skill. Two static-asset roles can look similar on disk but have different owners, lifecycles, and delivery surfaces. Decide ownership before choosing a Razor helper or an origin.

## App assets

App assets are application-specific files owned by exactly one application: its CSS and JavaScript, images and branding, favicons, manifests, application-specific fonts, and application media. Their source normally stays in that web project's `wwwroot`, because it is the conventional, tooling-friendly authoring location understood by editors, hot reload, and the SDK. After deployment, the files are served from a separately built and deployed `codebeltnet/web-cdn-origin:2.0.0` image on a host tied to that application.

When `Cuemon.AspNetCore.Razor.TagHelpers` is already available, use the public Cuemon App helpers and bind `AppTagHelperOptions`. Treat each helper's `HtmlTargetElement` attribute as authoritative: the current App selectors are `app-link`, `app-script`, and `app-img`.

```html
<app-link rel="stylesheet" href="css/site.css" />
<app-link rel="preload" href="fonts/antonio-latin.woff2" as="font" type="font/woff2" crossorigin />
<app-link rel="icon" href="favicon.svg" type="image/svg+xml" />
<app-link rel="mask-icon" href="mask-icon.svg" type="image/svg+xml" color="#000000" />
<app-link rel="apple-touch-icon" href="apple-touch-icon.png" type="image/png" />
<app-link rel="manifest" href="manifest.json" type="application/json" />
<app-script src="js/site.js"></app-script>
<app-img src="images/logo.svg" alt="Logo" />
```

These elements declare App ownership in Razor. Do not replace them with a custom `GetUrl()` helper, injected `AppAssetOptions`, or an application-specific URL builder when Cuemon is already present.

## CDN assets

CDN assets are reusable static content consumed by multiple applications: common fonts, icon libraries, JavaScript libraries and packages, CSS frameworks, shared design-system assets, reusable images, and other organization-wide, versioned frontend dependencies. They must not be copied into every application's `wwwroot`. They normally have a separate source repository or artifact and may ultimately be fronted by a true CDN, with `web-cdn-origin` as the origin behind it.

When a shared equivalent exists, use Cuemon's CDN helpers and bind `CdnTagHelperOptions`. The current CDN selectors are `cdn-link`, `cdn-script`, and `cdn-img`.

```html
<cdn-link href="packages/fontawesome/7.0.0/css/all.min.css" />
<cdn-link href="packages/bootstrap/5.3.3/css/bootstrap.min.css" />
<cdn-script src="packages/htmx/2.0.4/htmx.min.js"></cdn-script>
<cdn-img src="shared/brand-mark.svg" alt="Organization mark" />
```

Use the corresponding CDN helper for the element type. Do not mechanically convert every static reference to an App helper or every external-looking reference to a CDN helper. Determine who owns the file and where its canonical source lives. If no CDN equivalent exists, do not create a CDN origin or manufacture CDN configuration.

## Decision precedence

Existing framework and project abstractions are preferred over skill-invented abstractions:

1. If Cuemon is already available, reuse its App/CDN helpers and `AppTagHelperOptions`/`CdnTagHelperOptions`. If an earlier migration created `AppAssetOptions`, `SegregatedAssetsOptions`, `GetUrl()`, or similar, migrate its consumers by ownership and remove the abstraction only after proving that no consumers remain.
2. If Cuemon is absent but a suitable project asset abstraction exists, reuse that abstraction. Do not add Cuemon solely because this skill knows about it.
3. If neither exists, introduce only the smallest app-owned configuration mechanism required by the repository's existing architecture.

The runner reports package/project references, namespace imports, options types, `_ViewImports.cshtml` registrations, actual Cuemon elements, custom option types, URL calls, Razor injections, legacy attribute syntax, and whether Cuemon and a competing abstraction coexist. The runner does not rewrite Razor or C#; the agent performs the semantic migration.

## NuGet package version policy

An existing `Cuemon.AspNetCore.Razor.TagHelpers` package reference is a live dependency, so its migration version comes from NuGet.org at plan time rather than from a repository example or previously observed value. The runner discovers `PackageBaseAddress/3.0.0` through `https://api.nuget.org/v3/index.json`, reads the package version index once, excludes prereleases, selects the highest stable semantic version, and records the exact version and source under `resolvedNuGetPackages` and the `nuget-package-version` plan decision.

Preserve the repository's package-version owner. When Central Package Management is active, update the existing `PackageVersion` in `Directory.Packages.props` and keep the project `PackageReference` versionless. Otherwise, update the existing `PackageReference`. A project-reference-only Cuemon setup has no NuGet version to resolve. If NuGet resolution fails or returns no stable version, stop without proposing a package edit; do not fall back to a literal from a template, fixture, example, or memory. The later restore/publish verification remains responsible for proving that the current package is compatible with the selected project.

## Configuration declares location

Razor declares ownership; configuration declares location; `web-cdn-origin` declares delivery of static content only:

```text
Razor:         app-* or cdn-*
Configuration: current application, local segregated origin, or deployed host
Delivery:      web-cdn-origin:2.0.0 serves the static-content root
```

The current public Cuemon API exposes `TagHelperOptions.BaseUrlMode` with `TagHelperBaseUrlMode.Configured` and `TagHelperBaseUrlMode.Automatic`, plus `BaseUrl` and `ProtocolUriScheme`. Set `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic`: an explicit App `BaseUrl` wins; when App `BaseUrl` is absent, Automatic resolves against the active application request. Cuemon does not inspect launch-profile names.

For the segregated local profile, configure the App option with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, host-only `BaseUrl = localhost:<app-port>`, and explicit `Scheme = ProtocolUriScheme.Http`. Configure the CDN option with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, its own host-only `BaseUrl = localhost:<cdn-port>`, and `Scheme = ProtocolUriScheme.Http` only when a CDN equivalent exists. Never use a protocol-relative or HTTPS URL for an HTTP-only local origin.

For deployment, configure the App option with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, the external host, and HTTPS scheme, for example `BaseUrl = assets.example.com` and `Scheme = ProtocolUriScheme.Https`. Configure the CDN option with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, the deployed shared host, and `Scheme = ProtocolUriScheme.Https`. CDN helpers must remain explicitly tied to the CDN surface; they must never fall back to the application host.

When Cuemon is absent, apply the same ownership and location rules to the suitable existing project abstraction. Do not create a second configuration hierarchy beside `AppTagHelperOptions`/`CdnTagHelperOptions` or beside a project abstraction that already owns this concern.

## Cache busting

Before changing Razor, inspect whether the application uses Microsoft's `asp-append-version`, Cuemon `ICacheBusting`, content-addressed filenames, or another existing mechanism. Do not assume Microsoft's TagHelper will process `asp-append-version` on a Cuemon custom element, and do not introduce a second cache-busting system. Preserve behavior where the current combination is proven; if migration requires a cache-busting design decision, report it as explicit follow-up rather than silently changing the URL contract.

When the referenced Cuemon package/source exposes the enhanced `CacheBustingTagHelper` API, App and CDN link, script, and image helpers receive an optional DI-provided `ICacheBusting` service. The helper uses the current `ViewContext` request — scheme, host, and `PathBase` — for Automatic resolution and appends the version query after resolving the base URL. An explicit `BaseUrl` wins, and migrated helper paths should remain asset-relative (`css/site.css`) rather than another URL-composition expression. Preserve an existing `AddAssemblyCacheBusting()`, `AddDynamicCacheBusting()`, or `AddCacheBusting<T>()` registration when one already exists; do not add a cache-busting package or registration solely for segregation. Verify the referenced package/source before emitting `BaseUrlMode`, `TagHelperBaseUrlMode`, or the enhanced cache-busting setup, because a Cuemon package reference alone does not prove that a planned API is available.

## Why segregate at all

The motivation is architectural, not a browser-connection trick. Segregating static delivery gives static content independent deployment and scaling, explicit cache behavior, origin offloading, reusable shared assets, and a reduced application artifact surface while keeping the developer-friendly `wwwroot` authoring workflow.
