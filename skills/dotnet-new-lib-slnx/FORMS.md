# Parameter Form

Collect these parameters from the user before generating anything. Present each field **one at a time** using the agent's native input mechanism (e.g. `ask_user` with `choices`) when the host supports it. If native structured input widgets are unavailable, fall back to the deterministic plain-text interaction format described in the presentation rules below. Do not bundle multiple fields into a single message.

## Fields

### solution_name
- **type:** text
- **prompt:** "What is the solution/product name?"
- **placeholder:** "e.g. MyLibrary"
- **required:** true

### root_namespace
- **type:** text
- **prompt:** "Root namespace prefix?"
- **placeholder:** "e.g. Acme, MyCompany"
- **default:** `{solution_name}`
- **description:** Present `{solution_name}` as the recommended namespace prefix. If the user leaves this field blank after seeing that default, accept `{solution_name}` and continue instead of asking again.
- **required:** true

### author
- **type:** text
- **prompt:** "Author name? (for NuGet metadata and git)"
- **computed_default:** Git user name (via `git config user.name`). Falls back to asking the user if not configured.
- **required:** true

### author_email
- **type:** text
- **prompt:** "Author email? (for NuGet metadata and signing conditions)"
- **computed_default:** Git user email (via `git config user.email`). Falls back to asking the user if not configured.
- **required:** true

### company_or_person
- **type:** text
- **prompt:** "Company or person name? (for copyright and NuGet metadata)"
- **default:** `{author}`
- **description:** Use the company name when publishing under an organization, or reuse the author name for solo/independent packages.
- **required:** true

### copyright_year
- **type:** text
- **prompt:** "Copyright year?"
- **default:** current year (from system time)
- **required:** true

### repository_url
- **type:** text
- **prompt:** "Source repository URL? (GitHub)"
- **computed_default:** `https://github.com/OWNER/{root-folder-name}` where `{root-folder-name}` is resolved from the git repository root folder name (via `Split-Path -Leaf (git rev-parse --show-toplevel)`). Falls back to the current folder name if not in a git repo.
- **description:** Source code repository shown as the package's repository/source link. Example: `https://github.com/codebeltnet/savvyio`.
- **required:** true

### package_project_url
- **type:** text
- **prompt:** "Project website/docs URL? (shown as 'Project website' on NuGet)"
- **computed_default:** `repository_url`
- **description:** Present the collected `repository_url` as the recommended value so the user can accept it or replace it with a dedicated website/docs URL. Example: accept `https://github.com/codebeltnet/savvyio` for simple packages, or replace it with `https://www.savvyio.net/`.
- **required:** true

### target_frameworks
- **type:** text
- **prompt:** "Target frameworks? (semicolon-separated)"
- **computed_default:** Newest generally supported .NET LTS channel from `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json` (filter `.NET` entries where `support-phase` is `active` or `maintenance`, then pick the highest `release-type: lts` channel and format it as `net{major}.0`).
- **placeholder:** "e.g. net10.0"
- **description:** Default to the newest generally supported .NET LTS for new libraries based on the official releases index, but also offer every other generally supported non-preview .NET LTS and STS channel so the user can choose any actively supported track. Also offer an expanded compatibility preset built from all generally supported `.NET` channels in that same index, sorted newest to oldest and formatted as semicolon-separated TFMs. Exclude preview channels. Allow custom TFMs when needed.
- **required:** true

### benchmark_runner_project_name
- **type:** text
- **prompt:** "Benchmark runner project name?"
- **default:** `benchmark-runner`
- **description:** Solution-level tooling project that hosts `Program.cs` for BenchmarkDotNet runs. Keep the default unless the repo already uses another tooling naming convention.
- **required:** true

### strong_name_signing
- **type:** single-choice
- **prompt:** "Enable assembly signing (.snk)?"
- **choices:**
  - Yes (Recommended)
  - No
- **default:** Yes
- **description:** Signing requires committing a key file to the repository.

### sonarcloud_org
- **type:** text
- **prompt:** "SonarCloud organization slug?"
- **required:** false
- **description:** Skip if not using SonarCloud.

### sonarcloud_key
- **type:** text
- **prompt:** "SonarCloud project key?"
- **required:** false
- **description:** Only needed if SonarCloud org was provided.

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
6. For `text` fields with a computed default (e.g. `{solution_name}` or `repository_url`), offer the computed value as a selectable choice alongside free text input.
7. If a field with a `default` or `computed_default` is shown to the user and they leave it blank, treat that as accepting the presented recommended value. Do not ask a second clarification question just because the typed response was empty.
8. For `target_frameworks`, compute quick-pick suggestions from `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json`:
   - Recommended: newest generally supported LTS channel only (for example `net10.0` as of March 16, 2026)
   - Include one additional single-target quick-pick for every other supported LTS or STS channel, sorted newest to oldest and labeled with its support track (for example `net9.0` and `net8.0` as of March 16, 2026)
   - Expanded scope: all generally supported `.NET` channels, newest to oldest, excluding preview channels (for example `net10.0;net9.0;net8.0` as of March 16, 2026)
9. After all fields are collected, present a summary and ask for confirmation before proceeding.
