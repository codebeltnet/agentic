# .NET Remote Testing Input Form

Collect only the fields that are still unresolved after inspecting the request and the repository. Most remote-test requests are fully determined and need **no** questions — for example, "remote test this solution" against a repository with a single applicable environment. Prefer native structured controls when the host provides them; otherwise use the plain-text fallback below without changing field order, defaults, or the final confirmation.

## Fields

### environment

- **type:** single-choice
- **prompt:** Which environment should run the tests?
- **choices:** Dynamically list the environments from `remote-test.cs list` — the configured Docker environments from `testenvironments.json`, or the Microsoft-derived environments (for example `dotnet-10-lts`, `dotnet-9-sts`, `dotnet-11-preview`) when no `testenvironments.json` exists
- **default:** The only applicable Docker environment, or the environment explicitly named by the user (Recommended)
- **required:** true

### test_scope

- **type:** single-choice
- **prompt:** What should be tested?
- **choices:**
  - Entire solution / auto-resolved target (Recommended)
  - A specific project
  - A class or test filter
- **default:** Entire solution / auto-resolved target (Recommended)
- **required:** true

### project

- **type:** text
- **prompt:** Which project or solution should be tested (path relative to the source root)?
- **default:** Auto-resolved (root solution, single solution, or single project)
- **required:** false
- **show_when:** `test_scope` is `A specific project`

### filter

- **type:** text
- **prompt:** Which `dotnet test` filter or fully-qualified test name should be run?
- **default:** (none)
- **required:** false
- **show_when:** `test_scope` is `A class or test filter`

### configuration

- **type:** single-choice
- **prompt:** Which build configuration?
- **choices:**
  - Debug (Recommended)
  - Release
- **default:** Debug (Recommended)
- **required:** true

### coverage

- **type:** single-choice
- **prompt:** Collect code coverage? (Only when the project already supports it; packages are never added.)
- **choices:**
  - No (Recommended)
  - Yes
- **default:** No (Recommended)
- **required:** true

### confirmation

- **type:** single-choice
- **prompt:** Run the tests using the summarized environment, target, configuration, and coverage plan?
- **choices:**
  - Yes (Recommended)
  - No
- **default:** Yes (Recommended)
- **required:** true

## Presentation rules

- Infer explicit answers from the request and from `remote-test.cs list`/`plan`; do not ask them again.
- Ask one unresolved field at a time. Never bundle multiple questions.
- Present the recommended/default choice first and suffix it with `(Recommended)`.
- For the `environment` field, offer the discovered environment names as selectable choices rather than free text. When exactly one environment applies, select it without asking.
- For `project`, offer the auto-resolved target as a selectable choice alongside a free-text path.
- In plain-text fallback mode, start immediately with `Field: <field-name>` and show numbered choices. Do not add a conversational preamble.
- If the user leaves a shown computed/default choice blank, accept it and continue.
- After all fields are resolved, summarize the exact environment, target, configuration, and coverage, then ask `confirmation`.
