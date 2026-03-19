# Parameter Form

Collect these parameters from the user before generating anything. Present each field **one at a time** using the agent's native input mechanism (e.g. `ask_user` with `choices`) when the host supports it. If native structured input widgets are unavailable, fall back to the deterministic plain-text interaction format described in the presentation rules below. Do not bundle multiple fields into a single message.

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
- **description:** Present `{solution_name}` as the recommended namespace prefix. If the user leaves this field blank after seeing that default, accept `{solution_name}` and continue instead of asking again.
- **required:** true

### target_framework
- **type:** text
- **prompt:** "Target framework?"
- **computed_default:** Newest generally supported .NET LTS channel from `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json` (filter `.NET` entries where `support-phase` is `active` or `maintenance`, then pick the highest `release-type: lts` channel and format it as `net{major}.0`).
- **placeholder:** "e.g. net10.0"
- **description:** Offer every generally supported non-preview .NET LTS and STS channel from the official releases index so the user can choose any actively supported track. Present the newest LTS first as the recommended option, but keep older supported LTS and current STS choices available. Allow a custom TFM when needed.
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
2. Prefer the host's native structured input controls for every field when they are available.
3. If native structured input controls are unavailable, use this exact plain-text fallback:
   - Start with `Field: <field-name>`
   - Repeat the field prompt verbatim from this file
   - For `single-choice` and `multi-choice`, show a numbered option list and let the user answer with the number or the exact option text
   - For `text` fields with a `default` or `computed_default`, show `1. Use "<value>" (Recommended)` and `2. Enter a custom value`
   - After the user answers, restate the normalized value in one short line before moving on
4. For `single-choice` and `multi-choice` fields, present options as selectable choices when possible — otherwise use the numbered plain-text fallback above instead of an open free-text prompt.
5. When a field has a `default`, present it as the first choice and append "(Recommended)" if not already labeled.
6. For `text` fields with a computed default (e.g. `{solution_name}`), offer the computed value as a selectable choice alongside free text input.
7. If a field with a `default` or `computed_default` is shown to the user and they leave it blank, treat that as accepting the presented recommended value. Do not ask a second clarification question just because the typed response was empty.
8. For `target_framework`, compute one quick-pick suggestion per generally supported non-preview `.NET` channel from `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json`, sorted newest to oldest before free text:
   - Present the newest supported LTS channel first and mark it as recommended (for example `net10.0` as of March 16, 2026)
   - Include every other supported LTS and STS channel as additional selectable choices (for example `net9.0` and `net8.0` as of March 16, 2026)
   - Label each quick-pick with its support track (`LTS` or `STS`) so the user can make an informed choice
9. Only ask `web_variant` when `app_host_types` includes `Web`.
10. If the user explicitly says `web api`, `mvc`, `razor`, or `web app`, preselect `Web` and the matching `web_variant` instead of asking them to restate it.
11. If the user explicitly says `console` or `worker`, preselect that host type and skip asking `app_host_types` again unless the user clearly requested multiple host types.
12. In plain-text fallback mode, do not add a conversational preamble before a field. Start immediately with `Field: <field-name>`.
13. After all fields are collected, present a summary and ask for confirmation before proceeding.
