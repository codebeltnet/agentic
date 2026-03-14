# Parameter Form

Collect these parameters from the user before generating anything. Present each field **one at a time** using the agent's native input mechanism (e.g. `ask_user` with `choices`). Do not bundle multiple fields into a single message.

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
- **required:** true

### project_names
- **type:** text
- **prompt:** "Library project name(s)?"
- **placeholder:** "e.g. {Namespace}, {Namespace}.Extensions.Logging"
- **description:** Comma-separated if multiple. Each becomes a separate project under src/.
- **required:** true (at least one)

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

### company
- **type:** text
- **prompt:** "Company name? (for copyright and NuGet metadata)"
- **required:** true

### copyright_year
- **type:** text
- **prompt:** "Copyright year?"
- **default:** current year (from system time)
- **required:** true

### package_url
- **type:** text
- **prompt:** "Product/documentation URL?"
- **default:** `https://github.com/{owner}/{repo}` (derived from repository_url)
- **required:** true

### repository_url
- **type:** text
- **prompt:** "GitHub repository URL?"
- **required:** true

### target_frameworks
- **type:** text
- **prompt:** "Target frameworks? (semicolon-separated)"
- **placeholder:** "e.g. net10.0;net9.0"
- **default:** "net10.0;net9.0"
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
2. For `single-choice` and `multi-choice` fields, present options as selectable choices — not as free text prompts.
3. When a field has a `default`, present it as the first choice and append "(Recommended)" if not already labeled.
4. For `text` fields with a computed default (e.g. `{solution_name}`), offer the computed value as a selectable choice alongside free text input.
5. After all fields are collected, present a summary and ask for confirmation before proceeding.
