# .NET Segregated Static Assets Input Form

Collect only the fields that are still unresolved after running `segregate-assets.cs inspect` and reading the repository. Most fields have a computed or recommended default — present it first and accept a blank answer as acceptance. Prefer the host's native structured input controls when they are available; otherwise use the deterministic plain-text fallback described under **Presentation rules** without changing field order, defaults, recommended choices, or the final confirmation.

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
  - Cuemon App/Cdn tag helpers already present (Recommended when detected)
  - The application's own asset base-URL option/setting
  - No abstraction yet — introduce a minimal app-owned base-URL setting
- **default:** Auto-detected from inspection (Cuemon when `AppTagHelperOptions`/`CdnTagHelperOptions` are found; otherwise the app's own setting) (Recommended)
- **required:** true

### app_origin_port

- **type:** text
- **prompt:** Which host port should the local App Static Content Provider use?
- **choices:**
  - `8080` (Recommended)
  - A custom free port (resolve collisions against existing launchSettings/Compose)
- **default:** `8080` (Recommended)
- **required:** true

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
- Ask one unresolved field at a time. Never bundle multiple questions.
- Present the recommended/default choice first and suffix it with `(Recommended)`.
- For `web_project`, offer the discovered project names as selectable choices; when exactly one web project applies, select it without asking.
- For `cdn_equivalent`, always ask if it is unresolved — never assume shared assets belong in the application's wwwroot.
- For `text` fields with a computed default (ports, hosts), offer the computed value as a selectable choice alongside free text, and treat a blank response as accepting the shown value.
- If native structured input widgets are unavailable, follow this deterministic plain-text fallback instead of improvising your own questioning style: start immediately with `Field: <field-name>`, then a one-line prompt, then numbered choices (recommended first), and accept a blank reply as the default. Do not add a conversational preamble, and do not switch interaction styles mid-collection. Consistency matters more than creativity during parameter collection.
- Respect `show_when` conditions: skip `cdn_source`, `cdn_origin_port`, and `deployed_cdn_host` entirely when `cdn_equivalent` is `No`; skip `web_project` when only one web project exists.
- After all fields are resolved, summarize the exact project, App/CDN ports, deployed hosts, asset-configuration approach, and whether a production image will be built, then ask `confirmation`.
