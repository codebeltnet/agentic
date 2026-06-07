# Parameter Form

Collect input values, present a summary, and ask for confirmation before generating release notes.

## Fields

### compare_url
- **type:** text
- **required:** no
- **description:** A GitHub compare URL such as `https://github.com/owner/repo/compare/v1.0.0...v1.0.1`. When provided, all other fields are inferred automatically.

### repository
- **type:** text
- **required:** yes (unless compare_url is provided)
- **description:** The GitHub repository in `owner/repo` format (e.g. `codebeltnet/agentic`).

### previous_tag
- **type:** text
- **required:** yes (unless compare_url is provided)
- **description:** The earlier tag to compare from (e.g. `v1.0.0`).

### current_tag
- **type:** text
- **required:** yes (unless compare_url is provided)
- **description:** The later tag to compare to (e.g. `v1.0.1`).

## Presentation Rules

1. If the user provided a compare URL, parse it and present the inferred values:
   ```
   Ready to generate release notes:
     Repository:   {owner}/{repo}
     Previous tag: {previousTag}
     Current tag:  {currentTag}
   ```
2. If the user provided separate values, present them in the same summary format.
3. If any required value is missing, ask for it individually before presenting the summary.
4. After confirmation, proceed immediately to data collection.
