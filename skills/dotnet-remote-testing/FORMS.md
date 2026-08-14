# .NET Remote Testing Input Form

This form is a **fallback for genuine ambiguity, not an intake checklist**. The default path collects nothing: a request to remote test is executed, not surveyed.

## Autonomy gate — evaluate before presenting any field

Present a field only when one of these is true:

1. The runner exited `SelectionRequired` (`16`) — present `environment`, restricted to the `candidates` it returned.
2. The developer explicitly asked to choose something ("let me pick the environment", "which options do I have?").
3. The developer supplied a value that is genuinely unusable (for example a project path that does not exist).

If none apply, run with the defaults — auto-resolved target, `Debug`, no coverage — and present **no** fields and **no** confirmation. A single applicable Docker environment in `testenvironments.json` is a resolved answer, not a question. Never walk the field list top-to-bottom to "gather requirements", and never ask `test_scope`, `configuration`, or `coverage` unprompted; those are defaults the developer overrides by saying so.

Prefer native structured controls when the host provides them; otherwise use the plain-text fallback below without changing field order, defaults, or the final confirmation.

## Fields

### environment

- **type:** single-choice
- **prompt:** Which environment should run the tests?
- **choices:** The `candidates` returned by the runner's `SelectionRequired` result — the configured Docker environments from `testenvironments.json`, or the Microsoft-derived environments (for example `dotnet-10-lts`, `dotnet-9-sts`, `dotnet-11-preview`) when no `testenvironments.json` exists
- **default:** The environment explicitly named by the user
- **required:** Only when the runner exits `SelectionRequired`. A single applicable Docker environment resolves automatically and is never asked.

### test_scope

- **type:** single-choice
- **prompt:** What should be tested?
- **choices:**
  - Entire solution / auto-resolved target (Recommended)
  - A specific project
  - A class or test filter
- **default:** Entire solution / auto-resolved target (Recommended)
- **required:** false — the default applies silently; ask only when the developer asks to narrow the run but does not say how

### project

- **type:** text
- **prompt:** Which project or solution should be tested (path relative to the source root)?
- **choices:**
  - The exact target returned by `remote-test.cs plan` (Recommended)
  - A custom project or solution path
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
- **required:** false — `Debug` applies silently unless the developer names a configuration

### coverage

- **type:** single-choice
- **prompt:** Collect code coverage? (Only when the project already supports it; packages are never added.)
- **choices:**
  - No (Recommended)
  - Yes
- **default:** No (Recommended)
- **required:** false — never ask; coverage is collected only when the developer requests it

### confirmation

- **type:** single-choice
- **prompt:** Run the tests using the summarized environment, target, configuration, and coverage plan?
- **choices:**
  - Yes (Recommended)
  - No
- **default:** Yes (Recommended)
- **required:** Only when at least one other field was presented. On the autonomous path there is nothing to confirm — the run is the answer.

## Presentation rules

- Clear the autonomy gate above before presenting anything. In practice most invocations present no fields at all.
- Infer explicit answers from the request and from the runner's own output; do not ask them again.
- Ask one unresolved field at a time. Never bundle multiple questions, and never turn a single blocking choice into a broader intake.
- Present the recommended/default choice first and suffix it with `(Recommended)`.
- For the `environment` field, offer the runner's `candidates` as selectable choices rather than free text. When exactly one environment applies, select it without asking.
- For `project`, offer the auto-resolved target as a selectable choice alongside a free-text path.
- In plain-text fallback mode, start immediately with `Field: <field-name>` and show numbered choices. Do not add a conversational preamble.
- If the user leaves a shown computed/default choice blank, accept it and continue.
- When fields were presented, summarize the exact environment, target, configuration, and coverage after they are resolved, then ask `confirmation`. When no field was presented, skip the summary and the confirmation and run.
