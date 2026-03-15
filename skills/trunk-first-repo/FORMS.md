# Parameter Form

Collect these parameters from the user before initializing the repository. Present each field **one at a time** using the agent's native input mechanism (e.g. `ask_user` with `choices`). Do not bundle multiple fields into a single message.

## Fields

### version_prefix
- **type:** single-choice
- **prompt:** "What stage is this project?"
- **choices:**
  - v0.1.0 — MVP (Recommended)
  - v0.0.1 — PoC / Experimental
  - v1.0.0 — Production-grade
- **default:** v0.1.0
- **description:** The version prefix signals the project's maturity. v0.0.1 = throwaway prototype. v0.1.0 = building something real but still finding its shape. v1.0.0 = confident in the API/contracts, ready for consumers.

### branch_context
- **type:** text
- **prompt:** "Short context for this feature branch?"
- **placeholder:** "e.g. init-api, add-auth, setup-infra"
- **default:** "init"
- **required:** true

### remote_origin
- **type:** text
- **prompt:** "Remote URL?"
- **required:** false
- **description:** Skip if not ready yet. Can be added later with `git remote add origin <url>`.

## Presentation Rules

1. Ask one field at a time — wait for the answer before presenting the next field.
2. For `single-choice` and `multi-choice` fields, present options as selectable choices — not as free text prompts.
3. When a field has a `default`, present it as the first choice and append "(Recommended)" if not already labeled.
4. For `text` fields with a computed default, offer the computed value as a selectable choice alongside free text input.
5. After all fields are collected, present a summary and ask for confirmation before proceeding.
