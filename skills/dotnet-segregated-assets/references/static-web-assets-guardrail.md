# Static Web Assets compatibility guardrail

A supported simple migration has a physical `wwwroot` served by the application: plain files the developer authored. Projects that produce or contribute generated Static Web Assets require an explicit asset-artifact design. Their framework assets, Razor Class Library content, scoped CSS, component JavaScript modules, and frontend-generated output must remain available to the application.

Cuemon ownership helpers do not change this boundary. Migrate only application-owned references to `app-*` and shared references to `cdn-*` after classifying them. Do not mechanically convert `_framework`, `_content`, generated manifest entries, RCL assets, or component output to a Cuemon App/CDN helper, and do not treat a Cuemon package reference as permission to disable Static Web Assets.

## Detect before deciding

`segregate-assets.cs inspect` reports risk signals. Treat any of these as `RiskyGeneratedAssets` and preserve the complete generated-asset pipeline:

- `BLAZOR_WEBASSEMBLY` — `Microsoft.NET.Sdk.BlazorWebAssembly` or a `Microsoft.AspNetCore.Components.WebAssembly` reference. The published app depends on `_framework/` runtime assets.
- `BLAZOR_WEB_APP` — Razor components (`*.razor`) with `AddRazorComponents`/`MapRazorComponents` or a `Components.Web` reference. The app depends on `_framework/blazor.web.js` and generated component assets.
- `RAZOR_CLASS_LIBRARY_ASSETS` — a referenced `Microsoft.NET.Sdk.Razor` project that contributes a `wwwroot`, published under `_content/<Library>/…`.
- `SCOPED_CSS` — `*.razor.css` / `*.cshtml.css` files, which the build bundles into a generated `<Project>.styles.css` static web asset.
- `RAZOR_COMPONENT_JS` — collocated `*.razor.js` JavaScript modules emitted as static web assets.
- `FRAMEWORK_ASSETS_REFERENCE` / `CONTENT_ASSETS_REFERENCE` — markup that references `_framework/` or `_content/` paths.
- `STATIC_WEB_ASSETS_CONFIGURATION` — project-level Static Web Assets configuration requires review before segregation.
- `FRONTEND_BUILD_PIPELINE` — a `package.json` build (webpack/vite/rollup/esbuild/etc.) that generates the final `wwwroot`; the image must ship generated output, not source inputs.

You can also inspect manually for the same signals: `_framework`, `_content`, generated static web asset manifests, scoped CSS, component JS modules, and build-time frontend generation.

## Required handling

The targeted `Content Update="wwwroot/**" CopyToPublishDirectory="Never"` item applies only to application-owned physical `wwwroot` content. Razor Class Library assets, framework assets, generated component assets, and frontend output continue through their respective publish and serving pipelines.

When a project has Cuemon TagHelpers, its `app-*` and `cdn-*` markup still declares ownership only. It does not move or rewrite generated Static Web Assets. Preserve the existing framework and RCL references and verify the publish artifact before making any external-host change.

The empirical evidence in `references/production-image.md` confirms the expected result: application-owned `wwwroot/*` is absent from the web publish artifact while a referenced RCL's `wwwroot/_content/<Lib>/…` remains available. That separation is required for the application to run correctly.

## Safe outcomes

For a `Simple` classification (physical `wwwroot`, no risk signals), apply the standard App-asset segregation. Prefer limiting application-owned static serving to local Development when that can be done without changing unrelated behavior; the production invariant is that application-owned assets come from the external App host and are not duplicated into the web publish artifact.

For `RiskyGeneratedAssets`, decide whether a safe, deterministic segregation exists for that specific project:

- If the required generated output can be materialized into the external static-content artifact **and** the application's runtime references still resolve correctly (for example, the generated files are produced by the build and then packaged into the derived `web-cdn-origin` image with matching URLs), design that explicitly and verify it.
- If that cannot be established safely and deterministically, **stop and report** that the project requires an explicit generated-static-assets segregation design rather than producing a partially broken migration. State which signals were found and what a correct design would need to preserve (`_framework`/`_content` resolution, scoped-CSS bundle, component JS modules, or the frontend build output).

## Boundaries

- Keep the complete Static Web Assets pipeline available to framework and contributed content.
- Inspect `MapStaticAssets`, `UseStaticFiles`, custom providers, and endpoints before changing serving behavior.
- Keep `_content` and `_framework` assets distinct from application-owned `wwwroot` content.
- Escalate projects whose generated output cannot be materialized and verified as a complete external asset artifact.
