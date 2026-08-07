---
name: skill-creator-agnostic
description: >
  DEPRECATED — no longer maintained and scheduled for removal in 1.0.0. Retained only for backward compatibility. Do not use for new skill creation, modification, or benchmarking. Use Anthropic's `skill-creator` directly and apply this repository's skill-authoring rules from `AGENTS.md` instead.
---

# Skill Creator Agnostic

> [!CAUTION]
> **Deprecated / obsolete.**
> **No longer maintained.**
> **Scheduled for removal in 1.0.0.**
> **Do not use for new skill work.**
> Use Anthropic `skill-creator` + `AGENTS.md` instead.

This skill is now only a deprecation shim. It exists so older installs and direct invocations get redirected to the supported workflow instead of continuing to expose an obsolete companion implementation.

## Redirect behavior

If this skill is invoked, it should do only the following:

1. State that `skill-creator-agnostic` is deprecated, obsolete, and no longer maintained.
2. State that it remains only for backward compatibility and will be removed in **1.0.0**.
3. Redirect new skill creation, modification, and benchmarking work to Anthropic's `skill-creator`.
4. Apply the repository-specific skill-authoring, evaluation, sync, and validation rules from `AGENTS.md`.
5. Do not continue or recommend the historical `skill-creator-agnostic` workflow as an alternative implementation.
