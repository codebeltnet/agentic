# App assets versus CDN assets

This distinction is the heart of the skill. Two static-asset roles look similar on disk but have different owners, lifecycles, and deployment surfaces. Getting the role right determines where an asset is authored, whether it may live in an application's `wwwroot`, and which host serves it in production.

## App assets

App assets are application-specific files owned by exactly one application: its own CSS and JavaScript, images and branding, favicons, and any application-specific fonts or media. Their source normally stays in the web project's `wwwroot`, because that is the conventional, tooling-friendly authoring location that editors, hot reload, and the SDK already understand. What changes is delivery: after deployment these assets are served from a separately built and deployed static-content image based on `codebeltnet/web-cdn-origin:2.0.0`, on a host tied to that application (for example an assets host). They change on the application's own lifecycle.

Conceptually this is Cuemon's `AppTagHelperOptions` and the `app-*` tag helpers (`AppImageTagHelper`, `AppLinkTagHelper`, `AppScriptTagHelper`, used through `app-src`/`app-href`): assets that live outside the application process but are tied to that one application.

## CDN assets

CDN assets are reusable static content consumed by multiple applications: common fonts, icon libraries, JavaScript libraries and packages, CSS frameworks, shared design-system assets, reusable images, and other organization-wide, versioned frontend dependencies. They must **not** be copied into every application's `wwwroot`. They usually have their own source repository or artifact, and they may ultimately be fronted by a true CDN (CloudFront, Cloudflare, Azure Front Door, Google Cloud CDN) with `web-cdn-origin` as the origin behind it.

Conceptually this is Cuemon's `CdnTagHelperOptions` and the `cdn-*` tag helpers: assets on a surface that has a CDN role.

Always ask whether a CDN/shared equivalent exists (see `FORMS.md`). If none exists, configure only App-asset segregation. If one exists, find its existing source and configuration and reference it; never duplicate it into the application's `wwwroot`.

## Mapping to a URL-generation abstraction

The skill only needs an abstraction that turns an asset path into a base-qualified URL whose base differs between local Development and deployment. Adapt to whatever the application already uses. **Do not add a Cuemon dependency to an application that does not already use it** merely to implement this skill.

### When Cuemon tag helpers are already present

`Cuemon.AspNetCore.Razor.TagHelpers` exposes an abstract `TagHelperOptions` with two properties that matter here:

- `Scheme` — a `ProtocolUriScheme` of `None`, `Http`, `Https`, or `Relative`. The default is `Relative`, which formats the base URL as protocol-relative (`//host/…`). `Http` formats as `http://host/…`, `Https` as `https://host/…`, and `None` as a bare `host/…`.
- `BaseUrl` — the host (and optional path) portion, for example `localhost:8080` or `assets.example.com`.

`AppTagHelperOptions` configures the `app-*` helpers and `CdnTagHelperOptions` configures the `cdn-*` helpers. Both default to `Scheme = Relative` and `BaseUrl = null`.

Configure them like this:

- **App, local Development (segregated profile):** `BaseUrl = localhost:<app-port>`, `Scheme = Http`. Setting the scheme explicitly to `Http` is critical: the default `Relative` scheme emits `//localhost:<app-port>/…`, which a browser resolves using the page's scheme. On an HTTPS page that becomes `https://localhost:<app-port>/…` and fails against an HTTP-only local origin. Keep the segregated application profile itself HTTP so there is no mixed-content mismatch.
- **CDN, local Development:** `BaseUrl = localhost:<cdn-port>`, `Scheme = Http` — but only when a CDN equivalent exists and its content is available locally.
- **Deployed (App and CDN):** absolute HTTPS URLs — `BaseUrl = assets.example.com` / `cdn.example.com`, `Scheme = Https`.

Bind these from configuration so the launch profile's environment variables drive the local values and deployed configuration supplies the HTTPS values.

### When Cuemon is not used

Configure the application's own asset base-URL abstraction instead — an options/setting the app already reads to prefix asset URLs (for example a `SegregatedAssets:App:BaseUrl` and `SegregatedAssets:App:Scheme` pair, or the equivalent the app already has). Drive the local value from the segregated launch profile's environment variables (`http://localhost:<app-port>`) and supply the deployed HTTPS value from deployed configuration. Introduce only a minimal app-owned setting; do not add a second competing asset-configuration system.

## Why segregate at all

The motivation is architectural, not a browser-connection trick. Segregating static delivery gives you segregation of duties (static delivery is isolated from application and business logic and its failure modes), independent deployment and scaling for assets, explicit and correct cache behavior on a dedicated surface, origin/CDN offloading so the application stays small and cheap, reusable shared assets, and a reduced application artifact surface.

The design serves architecture, operability, and edge caching through independent deployment, explicit cache policy, and origin offloading.
