# Static Web Assets compatibility guardrail

The safe migration is a *physical* `wwwroot` served by the application: plain files the developer authored. The dangerous migration is one that treats **generated** or **contributed** Static Web Assets as if they were plain physical files and either excludes them from publish or disables the Static Web Assets system. That can break Blazor runtime loading, Razor Class Library assets, scoped CSS, component JavaScript modules, and frontend-generated output. This guardrail keeps the skill from producing a partially broken migration.

## Detect before deciding

`segregate-assets.cs inspect` reports risk signals. Treat any of these as `RiskyGeneratedAssets` and do **not** apply a blanket `wwwroot` publish exclusion or disable Static Web Assets:

- `BLAZOR_WEBASSEMBLY` — `Microsoft.NET.Sdk.BlazorWebAssembly` or a `Microsoft.AspNetCore.Components.WebAssembly` reference. The published app depends on `_framework/` runtime assets.
- `BLAZOR_WEB_APP` — Razor components (`*.razor`) with `AddRazorComponents`/`MapRazorComponents` or a `Components.Web` reference. Depends on `_framework/blazor.web.js` and generated component assets.
- `RAZOR_CLASS_LIBRARY_ASSETS` — a referenced `Microsoft.NET.Sdk.Razor` project that contributes a `wwwroot`, published under `_content/<Library>/…`.
- `SCOPED_CSS` — `*.razor.css` / `*.cshtml.css` files, which the build bundles into a generated `<Project>.styles.css` static web asset.
- `RAZOR_COMPONENT_JS` — collocated `*.razor.js` JavaScript modules emitted as static web assets.
- `FRAMEWORK_ASSETS_REFERENCE` / `CONTENT_ASSETS_REFERENCE` — markup that references `_framework/` or `_content/` paths.
- `STATIC_WEB_ASSETS_DISABLED` — `StaticWebAssetsEnabled` is already globally disabled; this may already be breaking RCL/framework assets.
- `FRONTEND_BUILD_PIPELINE` — a `package.json` build (webpack/vite/rollup/esbuild/etc.) that generates the final `wwwroot`; the image must ship generated output, not source inputs.

You can also inspect manually for the same signals: `_framework`, `_content`, generated static web asset manifests, scoped CSS, component JS modules, and build-time frontend generation.

## Why the blanket approaches are wrong here

`<StaticWebAssetsEnabled>false</StaticWebAssetsEnabled>` is a global kill switch: it disables asset discovery, the manifest, and `MapStaticAssets`, so Razor Class Library (`_content/…`) and framework (`_framework/…`) assets stop being published too. A blanket `Content Update="wwwroot/**" CopyToPublishDirectory="Never"` is safe for a *physical* app `wwwroot`, but it does not, on its own, relocate generated framework/component assets to an external origin — those assets still need to be served for the app to run.

The empirical evidence in `references/production-image.md` shows the difference: the targeted exclusion removes the app's own `wwwroot/*` while a referenced RCL's `wwwroot/_content/<Lib>/…` survives in publish. That survival is correct and required — and it is exactly what a global disable would destroy.

## Safe outcomes

For a `Simple` classification (physical `wwwroot`, no risk signals), apply the standard App-asset segregation. Prefer limiting application-owned static serving to local Development when that can be done without changing unrelated behavior; the production invariant is that application-owned assets come from the external App host and are not duplicated into the web publish artifact.

For `RiskyGeneratedAssets`, decide whether a safe, deterministic segregation exists for that specific project:

- If the required generated output can be materialized into the external static-content artifact **and** the application's runtime references still resolve correctly (for example, the generated files are produced by the build and then packaged into the derived `web-cdn-origin` image with matching URLs), design that explicitly and verify it — do not improvise it as a side effect of a publish-exclusion glob.
- If that cannot be established safely and deterministically, **stop and report** that the project requires an explicit generated-static-assets segregation design rather than producing a partially broken migration. This is a successful safety outcome, not a skill failure. State which signals were found and what a correct design would need to preserve (`_framework`/`_content` resolution, scoped-CSS bundle, component JS modules, or the frontend build output).

## Never do this

- Never disable `StaticWebAssetsEnabled` globally to make a wwwroot exclusion "work".
- Never blindly delete `MapStaticAssets` or `UseStaticFiles`; understand what they serve first.
- Never exclude `_content`/`_framework` assets or treat them as app-owned files.
- Never force a migration through when the runner reports a risky scenario you cannot segregate safely — escalate instead.
