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

### app_host_types
- **type:** multi-choice
- **prompt:** "What app host type(s) do you need?"
- **choices:**
  - Console
  - Web API
  - Worker
- **required:** true (at least one)

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
5. After all fields are collected, present a summary and ask for confirmation before proceeding.
