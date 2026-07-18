# Parameter Form

`dotnet-benchmark` derives most decisions from the repository, the target type, and the user's request. Ask only unresolved fields, one at a time. Prefer the host's native structured input controls when available. If the host does not provide them, use the deterministic plain-text fallback below without changing field order or choices.

## Yolo mode override

Yolo mode is request syntax, not a field to ask about. Activate it only when the current request explicitly says `yolo`, `yolo mode`, `auto-proceed`, or clearly instructs the agent to use defaults without routine confirmation.

While yolo mode is active:

- skip `performance_intent` and use auto-discovery unless the request already specifies another intent;
- skip `workload_context` when repository evidence supports a defensible workload; state the chosen assumption and continue;
- show the candidate plan as a progress update, then skip `candidate_plan_confirmation` and treat its recommended default as accepted;
- skip `execution_depth` and use build, list, and dry execution;
- ask only when missing information creates material correctness/design risk with no safe default;
- require a separate explicit human instruction to start a full performance run. `yolo` by itself never selects the full-run option, and an agent recommendation never supplies that authority.

The override lasts for the current benchmark task only and does not waive correctness checks, repository policy, external-side-effect restrictions, or blockers.

## Fields

### sut_type

- **type:** text
- **prompt:** "Which type do you want to investigate? Use the namespace-qualified name if it may be ambiguous."
- **placeholder:** "e.g. Cuemon.DateSpan or Acme.Buffers.RingBuffer"
- **required:** true
- **description:** Skip this field when the user already named an unambiguous type. Resolve the declaration in source rather than relying only on the name.

### performance_intent

- **type:** single-choice
- **prompt:** "What should the benchmark investigation optimize for?"
- **choices:**
  - Auto-discover the highest-value performance questions (Recommended)
  - Compare current and candidate implementations
  - Characterize one specific member or operation
  - Establish a regression benchmark for a known workload
- **default:** Auto-discover the highest-value performance questions (Recommended)
- **required:** true
- **description:** Infer and skip this field when the request already states the operation, comparison, or regression goal. In yolo mode, skip it and use auto-discovery unless another intent is explicit. Auto-discovery ranks candidates from implementation, usage, tests, and any available profiling evidence; it does not claim a measured application bottleneck without profile or telemetry data.

### workload_context

- **type:** text
- **prompt:** "I could not infer a representative workload confidently. What inputs, sizes, frequency, and operating conditions matter in production?"
- **required:** false
- **description:** Show this field only when tests, call sites, documentation, or supplied profiling evidence do not establish a representative workload and choosing one would materially affect correctness. Offer the strongest repo-derived workload as a selectable recommended choice when one exists, plus the option to enter a custom value. In yolo mode, state and use the strongest defensible repo-derived workload; ask only when no safe choice exists.

### candidate_plan_confirmation

- **type:** single-choice
- **prompt:** "Use the proposed benchmark questions, workloads, and validation strategy?"
- **choices:**
  - Use the proposed plan (Recommended)
  - Adjust the selected operations or inputs
- **default:** Use the proposed plan (Recommended)
- **required:** true
- **description:** Present the evidence-backed experiment plan immediately before this field. Include selected and rejected candidates, comparable baseline/candidate pairs, parameter cases, correctness oracle, lifecycle risks, and whether the plan is exploratory or profile-backed. In yolo mode, present it as a progress update and skip this field by accepting the recommended choice.

### execution_depth

- **type:** single-choice
- **prompt:** "How far should validation run?"
- **choices:**
  - Build, list, and dry-execute the benchmark (Recommended)
  - Run the full performance benchmark after validation
- **default:** Build, list, and dry-execute the benchmark (Recommended)
- **required:** true
- **description:** A dry execution validates discovery and lifecycle but produces no trustworthy performance conclusion. A full run can be slow and machine-sensitive. In yolo mode, skip this field and select the recommended build/list/dry option. Only an explicit human instruction such as "run it fully now" or "measure it now" selects the full-run option; yolo, plan acceptance, or an agent recommendation is not enough.

## Presentation rules

1. Detect the yolo mode override before presenting any field. When active, skip the routine fields described above and continue autonomously; otherwise ask one field at a time and wait for the answer before presenting the next unresolved field.
2. Skip fields already answered by the conversation or reliable repository evidence. Do not ask the user to choose BenchmarkDotNet attributes, a "simple/complex" tier, or extra runtimes unless those choices are part of the user's goal.
3. When native controls are unavailable, start with `Field: <field-name>`, repeat the prompt verbatim, show numbered choices in declared order, and accept either a number or exact choice text.
4. For a text field with a repo-derived suggestion, show `1. Use "<derived value>" (Recommended)` and `2. Enter a custom value`. Do not fabricate a suggestion when the evidence is weak.
5. Present each default first and append `(Recommended)` when it is not already included. A blank response accepts the displayed default.
6. After each answer, restate the normalized value in one short line before continuing.
7. Before `candidate_plan_confirmation`, show the experiment plan produced after source inspection. This is the final design confirmation; do not ask a second generic confirmation afterward.
8. If the user chooses to adjust the plan, collect only the disputed operation or workload, revise the plan, and present `candidate_plan_confirmation` again.
