# .NET Segregated Static Assets Input Form

Collect only the fields that are still unresolved after running `segregate-assets.cs inspect` and reading the repository. Use the runner's Cuemon and custom-abstraction evidence to resolve `asset_configuration`; do not infer an abstraction from a filename alone. Most fields have a computed or recommended default — present it first and accept a blank answer as acceptance. Prefer the host's native structured input controls when they are available; otherwise use the deterministic plain-text fallback described under **Presentation rules** without changing field order, defaults, recommended choices, or the final confirmation.

The single question you must always resolve is `cdn_equivalent`. It changes whether a second local origin is provisioned and how shared assets are referenced, and it must never be assumed.

## Fields

### web_project

- **type:** single-choice
- **prompt:** Which web project should be segregated?
- **choices:** The `Microsoft.NET.Sdk.Web` projects reported by `segregate-assets.cs inspect`
- **default:** The single resolved web project, or the project named by the user (Recommended)
- **required:** true
- **show_when:** `inspect` reports classification `Ambiguous` (more than one web project)

### cdn_equivalent

- **type:** single-choice
- **prompt:** Does a shared CDN / reusable-asset equivalent exist for this application (fonts, icon libraries, JavaScript/CSS frameworks, design-system assets shared across applications)?
- **choices:**
  - No — only this application's own assets (Recommended)
  - Yes — a shared/CDN asset source exists
- **default:** No — only this application's own assets (Recommended)
- **required:** true

### cdn_source

- **type:** text
- **prompt:** Where does the shared/CDN asset content live today (repository, artifact, existing host, or local path)? Do not assume it belongs in this application's wwwroot.
- **default:** (none)
- **required:** false
- **show_when:** `cdn_equivalent` is `Yes`

### asset_configuration

- **type:** single-choice
- **prompt:** How are App/CDN asset URLs generated in this application?
- **choices:**
  - Cuemon App/CDN TagHelpers already present — reuse `AppTagHelperOptions`/`CdnTagHelperOptions` (Recommended when detected)
  - The application's own suitable asset base-URL option/setting
  - No suitable abstraction yet — introduce the smallest app-owned setting only if required
- **default:** Auto-detected from inspection using package/project references, namespace imports, options, `_ViewImports.cshtml`, and actual `app-*`/`cdn-*` markup (Recommended)
- **required:** true

When Cuemon is detected, do not select the non-Cuemon or new-abstraction choice merely because an earlier `AppAssetOptions`-style abstraction exists. Treat it as a migration input, classify its consumers as App or CDN, and remove it only after proving that no consumers remain.

### app_origin_port

- **type:** text
- **prompt:** Which host port should the local App Static Content Provider use?
- **choices:**
  - `8080` (Recommended)
  - A custom free port (resolve collisions against existing launchSettings/Compose)
- **default:** `8080` (Recommended)
- **required:** true

### web_host_port

- **type:** text
- **prompt:** Which host port should the Compose web service publish?
- **choices:**
  - The HTTP port already used by the ordinary Project profile's `applicationUrl` (Recommended)
  - A custom free port
- **default:** The ordinary Project profile's HTTP `applicationUrl` port (Recommended)
- **required:** true

Reusing the ordinary profile's HTTP port keeps ordinary and segregated Development on one origin, so bookmarks, redirect registrations, and cookie scopes survive the switch. Never substitute a round number such as `5000` for the derived value. Ask only when the project has no HTTP `applicationUrl` to derive from or the derived port collides with `app_origin_port`.

### visual_studio_compose

- **type:** single-choice
- **prompt:** Should Visual Studio start the application and asset origins together from one Docker Compose launch profile?
- **choices:**
  - Yes — add or reuse Visual Studio Docker Compose orchestration (Recommended)
  - No — run the complete `compose.assets.yml` topology from the command line without Visual Studio registration
- **default:** Yes when the repository has a solution file or an existing `.dcproj`; otherwise No (Recommended)
- **required:** false
- **show_when:** The repository has a solution file and the desired launch experience is unresolved

This field controls only the IDE registration layer — `docker-compose.dcproj`, the root `launchSettings.json`, `DockerComposeProjectPath`, and solution registration. It never controls the artifact-first contract. `Dockerfile`, `LocalDevelopment.Dockerfile`, `Assets.Dockerfile`, `LocalPublishDirectory`, the guarded publish target, the root `.dockerignore`, and the CI publish plus image builds are required whenever `compose.assets.yml` is created, because `compose.assets.yml` builds the web service from `LocalDevelopment.Dockerfile` regardless of which client starts it.

### cdn_origin_port

- **type:** text
- **prompt:** Which host port should the local CDN Static Content Provider use?
- **choices:**
  - `8081` (Recommended)
  - A custom free port different from the App origin port
- **default:** `8081` (Recommended)
- **required:** false
- **show_when:** `cdn_equivalent` is `Yes`

### deployed_app_host

- **type:** text
- **prompt:** What is the deployed App asset host (HTTPS), if known? Used only for deployed configuration.
- **default:** (leave as a documented placeholder such as `assets.example.com` when unknown)
- **required:** false

### deployed_cdn_host

- **type:** text
- **prompt:** What is the deployed shared/CDN asset host (HTTPS), if known?
- **default:** (leave as a documented placeholder such as `cdn.example.com` when unknown)
- **required:** false
- **show_when:** `cdn_equivalent` is `Yes`

### production_image

- **type:** single-choice
- **prompt:** Build a derived `codebeltnet/web-cdn-origin:2.0.0` production asset image for this application's assets?
- **choices:**
  - Yes — add a derived asset image (Recommended)
  - No — configuration and local topology only
- **default:** Yes — add a derived asset image (Recommended)
- **required:** true

### confirmation

- **type:** single-choice
- **prompt:** Apply App-asset segregation (and CDN provisioning when applicable) using the summarized project, ports, hosts, and configuration, then verify the publish invariant?
- **choices:**
  - Yes (Recommended)
  - No
- **default:** Yes (Recommended)
- **required:** true

## Presentation rules

- Run `segregate-assets.cs inspect` first and infer explicit answers from its output and the repository; do not ask questions the inspection already answers.
- Treat `assetAbstractions.cuemon` and `assetAbstractions.custom` as evidence. If both are present, plan a semantic migration and cleanup; do not leave two URL-generation systems behind.
- Ask one unresolved field at a time. Never bundle multiple questions.
- Present the recommended/default choice first and suffix it with `(Recommended)`.
- For `web_project`, offer the discovered project names as selectable choices; when exactly one web project applies, select it without asking.
- For `cdn_equivalent`, always ask if it is unresolved — never assume shared assets belong in the application's wwwroot.
- For `text` fields with a computed default (ports, hosts), offer the computed value as a selectable choice alongside free text, and treat a blank response as accepting the shown value.
- Derive `web_host_port` from the ordinary Project profile's HTTP `applicationUrl` before asking, and skip the field entirely when that port exists and does not collide with `app_origin_port`.
- If native structured input widgets are unavailable, follow this deterministic plain-text fallback instead of improvising your own questioning style: start immediately with `Field: <field-name>`, then a one-line prompt, then numbered choices (recommended first), and accept a blank reply as the default. Do not add a conversational preamble, and do not switch interaction styles mid-collection. Consistency matters more than creativity during parameter collection.
- Respect `show_when` conditions: skip `cdn_source`, `cdn_origin_port`, and `deployed_cdn_host` entirely when `cdn_equivalent` is `No`; skip `web_project` when only one web project exists.
- After all fields are resolved, summarize the exact project, web and App/CDN ports, deployed hosts, asset-configuration approach, any competing abstraction cleanup, Visual Studio Compose choice, and whether a production image will be built, then ask `confirmation`. Include the resolved file locations in the summary so a wrong Dockerfile placement is visible before anything is written.
