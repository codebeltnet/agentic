# .NET Test Input Form

Collect only unresolved fields. Prefer native structured controls when the host provides them. Otherwise use the plain-text fallback below without changing field order or defaults.

## Fields

### project_selection

- **type:** single-choice
- **prompt:** Which test project should be bootstrapped or refactored?
- **choices:** Dynamically list discovered test `.csproj` files relative to the repository root
- **default:** The only discovered test project, or the project explicitly named by the user (Recommended)
- **required:** true

### operation_mode

- **type:** single-choice
- **prompt:** Should the selected project be bootstrapped or refactored?
- **choices:**
  - Refactor an existing test project (Recommended when the project exists and contains tests)
  - Bootstrap test coverage (Recommended when no selected test project exists or it has no behavior tests)
- **default:** Compute from the selected project
- **required:** true

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

### application_adaptation

- **type:** single-choice
- **prompt:** If a console or worker executable has no Generic Host seam, may the application bootstrap be adapted?
- **choices:**
  - Test code only; report the required application adaptation (Recommended)
  - Application and test code are both in scope
- **default:** Test code only; report the required application adaptation (Recommended)
- **required:** true
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
- **show_when:** `test_role` is `ASP.NET Core functional test` or `Console or worker functional test`, and repository evidence does not already decide focused versus shared ownership

### confirmation

- **type:** single-choice
- **prompt:** Apply the summarized project, mode, role, host-ownership, package-owner, and application-scope plan?
- **choices:**
  - Yes (Recommended)
  - No
- **default:** Yes (Recommended)
- **required:** true

## Presentation rules

- Infer explicit answers from the request and inspection output; do not ask them again.
- Ask one unresolved field at a time.
- Present the recommended/default choice first and suffix it with `(Recommended)`.
- In plain-text fallback mode, start immediately with `Field: <field-name>` and show numbered choices. Do not add a conversational preamble.
- If the user leaves a shown computed/default choice blank, accept it and continue.
- After all fields are resolved, summarize the exact project, mode, role, host ownership, package owner, detected blockers, and application adaptation scope, then ask `confirmation`.
