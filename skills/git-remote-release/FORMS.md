# Parameter Form

Collect input values, present a summary, and ask for confirmation before generating release notes.

## Fields

### compare_url
- **type:** text
- **required:** no
- **prompt:** Do you have a GitHub compare URL? (e.g. `https://github.com/owner/repo/compare/v1.0.0...v1.0.1`) When provided, all other fields are inferred automatically.

### repository
- **type:** text
- **required:** yes (unless compare_url is provided or using default resolution)
- **prompt:** Which GitHub repository? Use `owner/repo` format (e.g. `codebeltnet/agentic`).

### previous_ref
- **type:** text
- **required:** yes (unless compare_url is provided or using default resolution)
- **prompt:** What is the previous tag or branch to compare from? (e.g. `v1.0.0` or `main`)

### current_ref
- **type:** text
- **required:** yes (unless compare_url is provided or using default resolution)
- **prompt:** What is the current tag or branch to compare to? (e.g. `v1.0.1` or `feature/my-branch`)

## Presentation Rules

0. If the user provided no input at all (no URL, no repository, no tags or branches), skip this form entirely and proceed directly to the Default Resolution Behavior defined in `SKILL.md`. Do not prompt for individual fields.
1. If the user provided a compare URL, parse it and present the inferred values:
   ```
   Ready to generate release notes:
     Repository:  {owner}/{repo}
     Previous:    {previousRef}
     Current:     {currentRef}
   ```
2. If the user provided separate values, present them in the same summary format.
3. If any required value is missing and the user did provide partial input, ask for it individually before presenting the summary.
4. After confirmation, proceed immediately to data collection.
