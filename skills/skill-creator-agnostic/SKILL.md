---
name: skill-creator-agnostic
description: >
  DEPRECATED — no longer maintained and scheduled for removal in 1.0.0. Use only when the user explicitly invokes `skill-creator-agnostic` or asks about its status. Redirect skill creation, modification, evaluation, and benchmarking to Anthropic's `skill-creator` plus repository `AGENTS.md`.
disable-model-invocation: true
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
