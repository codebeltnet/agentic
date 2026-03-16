# Parameter Form

Collect these parameters from the user before generating anything. Present each field **one at a time** using the agent's native input mechanism (e.g. `ask_user` with `choices`). Do not bundle multiple fields into a single message.

## Fields

### solution_name
- **type:** text
- **prompt:** "What is the solution/product name?"
- **placeholder:** "e.g. PaymentService"
- **required:** true

### root_namespace
- **type:** text
- **prompt:** "Root namespace prefix?"
- **placeholder:** "e.g. Acme, MyCompany"
- **default:** `{solution_name}`
- **required:** true

### target_framework
- **type:** text
- **prompt:** "Target framework?"
- **computed_default:** Newest generally supported .NET LTS channel from `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json` (filter `.NET` entries where `support-phase` is `active` or `maintenance`, then pick the highest `release-type: lts` channel and format it as `net{major}.0`).
- **placeholder:** "e.g. net10.0"
- **description:** Default to the newest generally supported .NET LTS for new apps based on the official releases index. Exclude preview channels. Allow a custom TFM when needed.
- **required:** true

### app_host_types
- **type:** multi-choice
- **prompt:** "What app host type(s) do you need?"
- **choices:**
  - Console
  - Web
  - Worker
- **required:** true (at least one)

### web_variant
- **type:** single-choice
- **prompt:** "Which web variant?"
- **show_when:** `app_host_types` includes `Web`
- **choices:**
  - Web API (Recommended)
  - Empty Web
  - MVC
  - Web App / Razor
- **default:** Web API
- **description:** Use `Web API` for HTTP APIs, `Empty Web` for a lean web host, `MVC` for controllers plus views, and `Web App / Razor` for Razor Pages.

### hosting_pattern
- **type:** single-choice
- **prompt:** "Which hosting pattern?"
- **choices:**
  - Minimal (Recommended)
  - Startup
- **default:** Minimal
- **description:** Minimal = Program.cs only. Startup = Program.cs + Startup.cs (classic hosting).

## Presentation Rules

1. Ask one field at a time — wait for the answer before presenting the next field.
2. For `single-choice` and `multi-choice` fields, present options as selectable choices — not as free text prompts.
3. When a field has a `default`, present it as the first choice and append "(Recommended)" if not already labeled.
4. For `text` fields with a computed default (e.g. `{solution_name}`), offer the computed value as a selectable choice alongside free text input.
5. For `target_framework`, offer the computed newest generally supported LTS value as the recommended choice before free text.
6. Only ask `web_variant` when `app_host_types` includes `Web`.
7. If the user explicitly says `web api`, `mvc`, `razor`, or `web app`, preselect `Web` and the matching `web_variant` instead of asking them to restate it.
8. After all fields are collected, present a summary and ask for confirmation before proceeding.
