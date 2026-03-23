# Windows and PowerShell Benchmarking Notes

Use this reference when building or repairing skill benchmarks on Windows, especially from PowerShell.

## UTF-8 Without BOM

Python JSON loaders and the Anthropic benchmark scripts expect normal UTF-8 text. PowerShell defaults are not always safe for that.

Prefer explicit writes such as:

```powershell
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
```

Do not assume `Set-Content`, redirection, or the shell default encoding will produce no-BOM UTF-8 on every machine or shell version.

When Python-based review tooling must read emoji-bearing files on Windows, prefer forcing UTF-8 mode for the child process too:

```powershell
$env:PYTHONUTF8 = "1"
python <script>.py
```

This avoids viewer and aggregation failures caused by the platform default code page.

## Count Pipeline Results Safely

When using `Where-Object` followed by `.Count`, wrap the pipeline in `@(...)` so the count is stable for zero, one, or many results.

```powershell
$passed = @($items | Where-Object { $_.passed }).Count
```

## Resolve Provider Paths Before .NET File APIs

If you feed PowerShell provider paths directly into .NET file APIs, normalize them first:

```powershell
$resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
```

That avoids surprises when the working directory or provider path is not what you think it is.

## Treat Native stderr Carefully

Some CLIs write warnings to stderr even when the exit code is zero.

- Capture the actual exit code.
- Do not assume "stderr means failure".
- If needed, invoke through a wrapper that preserves stdout/stderr and exposes the real process exit code.

## Pass CLI Prompts Safely

Some Windows shells and CLIs reparse prompt text in surprising ways.

- Prefer passing prompts as a single explicit argument array entry, or via stdin, instead of relying on shell-quoted inline strings.
- Be extra careful with prompts that include nested quotes, commit subjects, or fragments that look like flags.
- Before a long measured benchmark, do a tiny smoke run that confirms the runner accepts the chosen invocation shape.

If repeated runs suddenly start failing with CLI usage text or "unexpected argument" errors, suspect prompt parsing before suspecting the skill logic.

## Keep Raw Event Output

If the runner can emit JSONL or event-stream output, save it under `outputs/` even when a friendlier file such as `last-message.txt` is expected.

- Some runners write timing or event output reliably but may skip the convenience last-message file on some runs.
- In that case, recover the final assistant message from the last `agent_message` event instead of discarding the run.

## Keep Temp Paths Short

Deep temp paths plus nested benchmark folders can hit Windows path limits. Use short workspace names such as:

```powershell
$workspace = Join-Path $env:TEMP 'skill-creator-agnostic-workspace'
```

## Common Failure Symptoms

- `aggregate_benchmark.py` shows zero runs: check `run-N/` layout first.
- `aggregate_benchmark.py` shows zero runs even though the layout looks right: make sure the eval directory itself starts with `eval-`.
- `aggregate_benchmark.py` loads runs but reports zero pass rate: check `grading.json.summary`.
- Python throws JSON decode errors on otherwise normal files: suspect BOM or wrong encoding.
- The review viewer crashes on files that contain emoji: force UTF-8 for the Python process before blaming the JSON.
- The runner prints CLI usage or "unexpected argument" errors: suspect prompt parsing and switch to argument-array or stdin invocation.
- The viewer shows outputs but the benchmark panel is empty: suspect aggregation inputs, not the viewer.
