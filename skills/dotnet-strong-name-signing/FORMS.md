# Parameter Form

This form separates resolving values from approving the operation. The user's initial request supplies intent and possibly explicit values; it does not confirm the complete summary that will be presented afterward. Generating or writing the `.snk` file is a protected operation.

## Fields

### key_name
- **type:** text
- **computed_default:** Git repository root folder name (via `Split-Path -Leaf (git rev-parse --show-toplevel)`). Falls back to current folder name if not in a git repo.
- **description:** The `.snk` extension is added automatically. Typically matches the repository name.

### key_size
- **type:** single-choice
- **choices:** 1024 (default, matches sn.exe), 2048, 4096
- **default:** 1024

### output_dir
- **type:** text
- **computed_default:** Git repository root directory (via `git rev-parse --show-toplevel`). Falls back to current working directory if not in a git repo.
- **description:** Typically the repository root, so the key file lives alongside the solution file.

## Presentation Rules

1. Compute all defaults silently — do not ask each field one at a time.
2. Resolve the requested values and defaults, then present a single complete summary showing all values and explicitly ask for confirmation:
   ```
   Ready to generate strong name key:

     File:     {key_name}.snk
     Key size: {key_size}-bit RSA
     Location: {output_dir}

   Confirm these values to generate the key, or tell me which value to change.
   ```
3. After presenting the summary and confirmation request, stop. Do not generate, write, or modify the `.snk` file while waiting for the user's response. The initial request cannot satisfy this gate because it precedes the presented summary.
4. Treat only a subsequent response accepting the presented values as confirmation, then perform generation.
5. If the user wants to change a value, ask only for that specific field, recompute and present the complete updated summary, and obtain confirmation again before generation.
