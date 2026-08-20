# .NET Test Input Form

This form is a fallback for genuine ambiguity, not an intake step. `scripts/inspect-dotnet-tests.ps1` already answers every field below from the repository, so in the normal case you run it, resolve the fields from its JSON, and never open this file. The mapping from inspector output to field is in `SKILL.md` Step 1.

Ask a field only when the inspector's evidence leaves it genuinely open. When that happens, ask that one field on its own, say what made it ambiguous, and keep the resolved fields silent — re-asking something the JSON already stated reads as if the inspection never ran.

Prefer native structured controls when the host provides them. Otherwise use the plain-text fallback below without changing field order or defaults.

## Fields

### project_selection

- **type:** single-choice
- **prompt:** Which test project should be bootstrapped or refactored?
- **choices:** Dynamically list discovered test `.csproj` files relative to the repository root
- **default:** The only discovered test project, or the project explicitly named by the user (Recommended)
- **required:** true
- **resolved_by:** the request naming a project, or `projects[]` holding exactly one

### operation_mode

- **type:** single-choice
- **prompt:** Should the selected project be bootstrapped or refactored?
- **choices:**
  - Refactor an existing test project (Recommended when the project exists and contains tests)
  - Bootstrap test coverage (Recommended when no selected test project exists or it has no behavior tests)
- **default:** Compute from the selected project
- **required:** true
- **resolved_by:** tests present in the selected project (refactor) or absent (bootstrap) — a repository fact, never a preference to poll

### test_role

- **type:** single-choice
- **prompt:** Which test role should the selected project use?
- **choices:**
  - Auto-classify from repository evidence (Recommended)
  - Ordinary unit test
  - ASP.NET Core functional test
  - Console or worker functional test
- **default:** Auto-classify from repository evidence (Recommended)
- **required:** true
- **resolved_by:** `projects[].role`

### application_adaptation

- **type:** single-choice
- **prompt:** If a console or worker executable has no Generic Host seam, may the application bootstrap be adapted?
- **choices:**
  - Test code only; report the required application adaptation (Recommended)
  - Application and test code are both in scope
- **default:** Test code only; report the required application adaptation (Recommended)
- **required:** true
- **resolved_by:** `referencedApplications[].genericHost` — when true, no adaptation is needed and the field does not apply
- **show_when:** `test_role` is `Console or worker functional test`, or auto-classification reports a missing Generic Host blocker

### host_ownership

- **type:** single-choice
- **prompt:** Which lifecycle should own the functional-test host?
- **choices:**
  - Auto-classify from current factory/fixture usage and isolation requirements (Recommended)
  - Focused ownership per test or narrow test harness
  - Shared xUnit class fixture
- **default:** Auto-classify from current factory/fixture usage and isolation requirements (Recommended)
- **required:** true
- **resolved_by:** existing usage — a factory per test method is focused; `IClassFixture` or one shared host is shared
- **show_when:** `test_role` is `ASP.NET Core functional test` or `Console or worker functional test`, and repository evidence does not already decide focused versus shared ownership

### confirmation

- **type:** single-choice
- **prompt:** Apply the summarized project, mode, role, host-ownership, package-owner, and application-scope plan?
- **choices:**
  - Yes (Recommended)
  - No
- **default:** Yes (Recommended)
- **required:** true
- **resolved_by:** the request itself; ask only when mutation would exceed the scope it authorized

## Presentation rules

- `required: true` means the field must be **settled** before mutation, not that it must be asked. A field settled from inspector evidence is satisfied.
- Infer explicit answers from the request and inspection output; do not ask them again.
- Ask one unresolved field at a time.
- Present the recommended/default choice first and suffix it with `(Recommended)`.
- In plain-text fallback mode, start immediately with `Field: <field-name>` and show numbered choices. Do not add a conversational preamble.
- If the user leaves a shown computed/default choice blank, accept it and continue.
- After all fields are resolved, summarize the exact project, mode, role, host ownership, package owner, detected blockers, and application adaptation scope, then ask `confirmation`.
