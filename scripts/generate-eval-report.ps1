<#
.SYNOPSIS
    Generates a self-contained HTML review and benchmark report for a prepared eval package.

.DESCRIPTION
    Reads manifest.json, eval-metadata.json, and the two result files for every eval case. It never
    executes a model and never changes result files. The report is useful after an external harness
    has collected and graded the runs, but it also renders partial or ungraded packages honestly.

.PARAMETER IterationDirectory
    Prepared eval iteration containing manifest.json.

.PARAMETER OutputPath
    Optional HTML path. Defaults to report.html at the iteration root.

.PARAMETER BenchmarkPath
    Optional benchmark JSON path. Defaults to benchmark.json at the iteration root.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$IterationDirectory,

    [string]$OutputPath,

    [string]$BenchmarkPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing JSON file '$Path'."
    }

    return [System.IO.File]::ReadAllText($Path, $utf8NoBom) | ConvertFrom-Json
}

function Get-Property {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $Default
}

function HtmlEncode {
    param([object]$Value)

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

function Format-Number {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return '-'
    }

    return [string]$Value
}

function Format-Isolation {
    param([object]$Isolation)

    if ($null -eq $Isolation) {
        return 'not reported'
    }

    $fields = [ordered]@{
        fresh = 'fresh_context'
        home = 'isolated_home'
        cwd = 'isolated_cwd'
        sandbox = 'filesystem_sandbox'
        skill = 'candidate_skill_exposed'
        transcript = 'transcript_captured'
    }
    $parts = foreach ($label in $fields.Keys) {
        $value = Get-Property -Object $Isolation -Name $fields[$label]
        $mark = if ($null -eq $value) { '?' } elseif ([bool]$value) { 'Y' } else { 'N' }
        "$label=$mark"
    }

    return $parts -join ' '
}

function Get-RunData {
    param(
        [string]$EvalDirectory,
        [string]$Configuration,
        [object]$Metadata
    )

    $fileName = if ($Configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
    $path = Join-Path (Join-Path $EvalDirectory 'results') $fileName
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    $result = Read-JsonFile -Path $path
    $output = [string](Get-Property -Object $result -Name 'output' -Default '')
    $outputFiles = @(Get-Property -Object $result -Name 'output_files' -Default @())
    $grading = @(Get-Property -Object $result -Name 'grading' -Default @())
    $graded = @($grading | Where-Object { $null -ne (Get-Property -Object $_ -Name 'passed') })
    $passed = @($graded | Where-Object { [bool](Get-Property -Object $_ -Name 'passed') }).Count
    $hasOutput = -not [string]::IsNullOrWhiteSpace($output) -or $outputFiles.Count -gt 0
    $status = if (-not $hasOutput) { 'not run' } elseif ($graded.Count -eq 0) { 'collected, not graded' } elseif ($passed -eq $graded.Count -and $graded.Count -eq @($Metadata.assertions).Count) { 'all assertions passed' } else { 'reviewed' }

    return [pscustomobject]@{
        Configuration = $Configuration
        Result = $result
        Output = $output
        OutputFiles = $outputFiles
        Grading = $grading
        Graded = $graded.Count
        Passed = $passed
        Total = @($Metadata.assertions).Count
        HasOutput = $hasOutput
        Status = $status
        Model = [string](Get-Property -Object $result -Name 'model' -Default '')
        Provider = [string](Get-Property -Object $result -Name 'provider' -Default '')
        Harness = [string](Get-Property -Object $result -Name 'harness' -Default '')
        Duration = Get-Property -Object $result -Name 'duration_seconds'
        Tokens = Get-Property -Object $result -Name 'total_tokens'
        ToolCalls = Get-Property -Object $result -Name 'tool_calls'
        Transcript = [string](Get-Property -Object $result -Name 'transcript' -Default '')
        Notes = [string](Get-Property -Object $result -Name 'notes' -Default '')
        Isolation = Get-Property -Object $result -Name 'isolation' -Default $null
    }
}

function New-GradeMarkup {
    param([object]$Grading)

    if (@($Grading).Count -eq 0) {
        return '<p class="muted">No formal grading was recorded.</p>'
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($grade in @($Grading)) {
        $passed = Get-Property -Object $grade -Name 'passed'
        $class = if ($null -eq $passed) { 'pending' } elseif ([bool]$passed) { 'pass' } else { 'fail' }
        $label = if ($null -eq $passed) { 'pending' } elseif ([bool]$passed) { 'passed' } else { 'failed' }
        [void]$builder.AppendLine("<li class='$class'><span class='grade-badge'>$label</span><span><strong>$(HtmlEncode (Get-Property -Object $grade -Name 'text' -Default 'Assertion'))</strong><br><span class='evidence'>$(HtmlEncode (Get-Property -Object $grade -Name 'evidence' -Default 'No evidence recorded.'))</span></span></li>")
    }

    return "<ul class='grades'>$($builder.ToString())</ul>"
}

function New-RunMarkup {
    param(
        [object]$Run,
        [object]$Metadata,
        [string]$EvalName,
        [string]$Configuration
    )

    $title = if ($Configuration -eq 'with_skill') { 'with skill' } else { 'without skill' }
    if ($null -eq $Run) {
        return "<article class='run-panel missing'><header><div><span class='eyebrow'>$title</span><h3>Not run</h3></div><span class='status-pill missing'>missing</span></header><p class='muted'>No result file was produced for this configuration.</p></article>"
    }

    $model = if ([string]::IsNullOrWhiteSpace($Run.Model)) { 'model not recorded' } else { "$($Run.Model)$(if ([string]::IsNullOrWhiteSpace($Run.Provider)) { '' } else { " · $($Run.Provider)" })" }
    $output = if ([string]::IsNullOrWhiteSpace($Run.Output)) { '<span class="muted">No model response recorded.</span>' } else { "<pre class='output-text'>$(HtmlEncode $Run.Output)</pre>" }
    $files = if ($Run.OutputFiles.Count -eq 0) { '' } else { '<div class="file-list"><span class="eyebrow">Output files</span><ul>' + (($Run.OutputFiles | ForEach-Object { "<li><code>$(HtmlEncode $_)</code></li>" }) -join '') + '</ul></div>' }
    $notes = if ([string]::IsNullOrWhiteSpace($Run.Notes)) { '' } else { "<p class='notes'><span class='eyebrow'>Notes</span>$(HtmlEncode $Run.Notes)</p>" }
    $statusClass = if ($Run.Status -eq 'all assertions passed') { 'pass' } elseif ($Run.Status -eq 'reviewed') { 'reviewed' } elseif ($Run.Status -eq 'not run') { 'missing' } else { 'pending' }
    $gradeSummary = if ($Run.Graded -eq 0) { 'not graded' } else { "$($Run.Passed)/$($Run.Graded) passed" }
    $transcript = if ([string]::IsNullOrWhiteSpace($Run.Transcript)) { 'not recorded' } else { 'recorded' }

    return @"
<article class="run-panel">
  <header><div><span class="eyebrow">$title</span><h3>$($Run.Status)</h3><p class="model">$(HtmlEncode $model)</p></div><span class="status-pill $statusClass">$(HtmlEncode $Run.Status)</span></header>
  <div class="metrics"><span><b>Grades</b>$gradeSummary</span><span><b>Duration</b>$(Format-Number $Run.Duration)s</span><span><b>Tokens</b>$(Format-Number $Run.Tokens)</span><span><b>Tools</b>$(Format-Number $Run.ToolCalls)</span></div>
  <div class="output-block"><span class="eyebrow">Response</span>$output</div>
  $files
  <details><summary>Formal grades</summary>$(New-GradeMarkup -Grading $Run.Grading)</details>
  <details><summary>Isolation and evidence</summary><p><code>$(HtmlEncode (Format-Isolation $Run.Isolation))</code><br>Transcript: $transcript</p></details>
  $notes
  <label class="review-note">Review note<textarea data-feedback-key="$(HtmlEncode "$EvalName-$Configuration")" placeholder="Optional note for this run"></textarea></label>
</article>
"@
}

$iterationPath = (Resolve-Path -LiteralPath $IterationDirectory).Path
$manifest = Read-JsonFile -Path (Join-Path $iterationPath 'manifest.json')
$skillName = [string]$manifest.skill_name
$iterationNumber = [string]$manifest.iteration
$rows = [System.Collections.Generic.List[object]]::new()
$runRows = [System.Collections.Generic.List[object]]::new()

foreach ($entry in @($manifest.evals)) {
    $evalDirectory = Join-Path $iterationPath ([string]$entry.directory)
    $metadata = Read-JsonFile -Path (Join-Path $evalDirectory 'eval-metadata.json')
    $withSkill = Get-RunData -EvalDirectory $evalDirectory -Configuration 'with_skill' -Metadata $metadata
    $withoutSkill = Get-RunData -EvalDirectory $evalDirectory -Configuration 'without_skill' -Metadata $metadata
    $rows.Add([pscustomobject]@{
        Entry = $entry
        Metadata = $metadata
        WithSkill = $withSkill
        WithoutSkill = $withoutSkill
    })

    foreach ($run in @($withSkill, $withoutSkill)) {
        if ($null -eq $run) {
            continue
        }
        $runRows.Add([ordered]@{
            eval_id = [int]$entry.eval_id
            eval_name = [string]$entry.eval_name
            configuration = $run.Configuration
            model = $run.Model
            provider = $run.Provider
            result = [ordered]@{
                pass_rate = if ($run.Graded -eq 0) { $null } else { [math]::Round($run.Passed / $run.Graded, 4) }
                passed = $run.Passed
                graded = $run.Graded
                assertions = $run.Total
                duration_seconds = $run.Duration
                total_tokens = $run.Tokens
                tool_calls = $run.ToolCalls
            }
        })
    }
}

$allRuns = @($rows | ForEach-Object { @($_.WithSkill, $_.WithoutSkill) } | Where-Object { $null -ne $_ })
$completedRuns = @($allRuns | Where-Object { $_.HasOutput }).Count
$gradedAssertions = @($allRuns | ForEach-Object { $_.Graded } | Measure-Object -Sum).Sum
$passedAssertions = @($allRuns | ForEach-Object { $_.Passed } | Measure-Object -Sum).Sum
$totalAssertions = @($allRuns | ForEach-Object { $_.Total } | Measure-Object -Sum).Sum
$passRate = if ($gradedAssertions -eq 0) { $null } else { [math]::Round($passedAssertions / $gradedAssertions, 4) }

$benchmark = [ordered]@{
    schema = 'codebeltnet/agentic/eval-benchmark/1'
    skill_name = $skillName
    iteration = [int]$manifest.iteration
    generated_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    summary = [ordered]@{
        evals = @($rows).Count
        expected_runs = @($rows).Count * 2
        completed_runs = $completedRuns
        graded_assertions = $gradedAssertions
        passed_assertions = $passedAssertions
        total_assertions = $totalAssertions
        pass_rate = $passRate
    }
    runs = @($runRows)
}

$benchmarkOutput = if ([string]::IsNullOrWhiteSpace($BenchmarkPath)) { Join-Path $iterationPath 'benchmark.json' } else { $BenchmarkPath }
Write-Utf8File -Path $benchmarkOutput -Content (($benchmark | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

$html = [System.Text.StringBuilder]::new()
[void]$html.AppendLine('<!doctype html>')
[void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$html.AppendLine("<title>Eval review · $(HtmlEncode $skillName) · iteration $(HtmlEncode $iterationNumber)</title>")
[void]$html.AppendLine(@'
<style>
:root{color-scheme:dark;--bg:#101216;--panel:#181b22;--panel2:#20242d;--text:#f2f4f8;--muted:#9da5b4;--line:#303642;--accent:#82aaff;--green:#69d49b;--red:#ff7e86;--yellow:#f4c76b;--shadow:0 18px 50px #0005}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 90% -10%,#28345b 0,transparent 35%),var(--bg);color:var(--text);font:15px/1.55 Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif}main{max-width:1440px;margin:0 auto;padding:42px 28px 80px}.hero{display:flex;justify-content:space-between;gap:28px;align-items:flex-end;margin-bottom:28px}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:11px;color:var(--muted);font-weight:700}.hero h1{font-size:clamp(30px,5vw,54px);line-height:1.05;margin:10px 0 8px;letter-spacing:-.04em}.hero p{margin:0;color:var(--muted)}.hero-mark{font-size:44px;color:var(--accent);opacity:.9}.summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:28px}.stat,.run-panel,.eval-card{background:linear-gradient(145deg,#1c2028,#15181e);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow)}.stat{padding:18px}.stat b{display:block;font-size:28px;letter-spacing:-.03em}.stat span{color:var(--muted);font-size:12px}.tabs{display:flex;gap:8px;border-bottom:1px solid var(--line);margin-bottom:22px}.tab{background:none;border:0;color:var(--muted);padding:12px 4px;margin-right:18px;cursor:pointer;font:inherit;border-bottom:2px solid transparent}.tab.active{color:var(--text);border-color:var(--accent)}.tab-panel{display:none}.tab-panel.active{display:block}.eval-card{padding:22px;margin:0 0 18px}.eval-heading{display:flex;justify-content:space-between;align-items:flex-start;gap:14px;margin-bottom:18px}.eval-heading h2{margin:4px 0;font-size:22px}.eval-heading p{margin:0;color:var(--muted)}.run-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.run-panel{padding:18px;box-shadow:none;background:var(--panel)}.run-panel header{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.run-panel h3{margin:4px 0 2px;font-size:19px}.model{color:var(--muted);margin:0;font-size:12px;overflow-wrap:anywhere}.status-pill,.grade-badge{display:inline-block;border-radius:999px;padding:4px 9px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.06em}.pass{color:var(--green)}.fail{color:var(--red)}.pending{color:var(--yellow)}.reviewed{color:var(--accent)}.missing{color:var(--muted)}.status-pill{background:#ffffff0b}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;border-top:1px solid var(--line);border-bottom:1px solid var(--line);margin:15px 0;padding:11px 0}.metrics span{font-size:12px;color:var(--muted)}.metrics b{display:block;color:var(--text);font-size:10px;text-transform:uppercase;letter-spacing:.08em}.output-block{margin:16px 0}.output-text{max-height:360px;overflow:auto;background:#0c0e12;border:1px solid #252a34;border-radius:10px;padding:13px;white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.55 ui-monospace,SFMono-Regular,Consolas,monospace}.muted{color:var(--muted)}details{border-top:1px solid var(--line);padding:11px 0}summary{cursor:pointer;color:var(--muted)}.grades{list-style:none;padding:0;margin:12px 0 0;display:grid;gap:10px}.grades li{display:grid;grid-template-columns:70px 1fr;gap:10px;align-items:start;font-size:13px}.grades .grade-badge{justify-self:start}.grades .pass .grade-badge{background:#69d49b18}.grades .fail .grade-badge{background:#ff7e8618}.grades .pending .grade-badge{background:#f4c76b18}.evidence{color:var(--muted);font-size:12px}.file-list ul{margin:6px 0 14px;padding-left:18px}.notes{color:var(--muted);font-size:13px}.review-note{display:block;margin-top:15px;color:var(--muted);font-size:12px}.review-note textarea{display:block;width:100%;min-height:64px;margin-top:6px;background:#0c0e12;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:9px;font:inherit;resize:vertical}.benchmark-table{width:100%;border-collapse:collapse;background:var(--panel);border-radius:14px;overflow:hidden}.benchmark-table th,.benchmark-table td{text-align:left;padding:12px;border-bottom:1px solid var(--line);font-size:13px}.benchmark-table th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em}.benchmark-table tr:last-child td{border-bottom:0}code{font:12px ui-monospace,SFMono-Regular,Consolas,monospace;color:#c5d4ff}.footer{margin-top:34px;color:var(--muted);font-size:12px}@media(max-width:900px){.summary,.run-grid{grid-template-columns:1fr 1fr}.hero{align-items:flex-start;flex-direction:column}}@media(max-width:560px){main{padding:28px 15px 60px}.summary,.run-grid{grid-template-columns:1fr}.metrics{grid-template-columns:repeat(2,1fr)}}
</style>
'@)
[void]$html.AppendLine('</head><body><main>')
[void]$html.AppendLine("<section class='hero'><div><span class='eyebrow'>Portable eval review</span><h1>$(HtmlEncode $skillName)</h1><p>Iteration $(HtmlEncode $iterationNumber) · $(HtmlEncode $iterationPath)</p></div><div class='hero-mark'>↗</div></section>")
[void]$html.AppendLine("<section class='summary'><div class='stat'><b>$(@($rows).Count)</b><span>eval cases</span></div><div class='stat'><b>$completedRuns / $($rows.Count * 2)</b><span>runs completed</span></div><div class='stat'><b>$(if ($null -eq $passRate) { '-' } else { "{0:P0}" -f $passRate })</b><span>graded pass rate</span></div><div class='stat'><b>$passedAssertions / $gradedAssertions</b><span>assertions passed</span></div></section>")
[void]$html.AppendLine('<nav class="tabs"><button class="tab active" data-tab="outputs">Outputs</button><button class="tab" data-tab="benchmark">Benchmark</button></nav>')
[void]$html.AppendLine('<section id="outputs" class="tab-panel active">')

foreach ($row in $rows) {
    $metadata = $row.Metadata
    [void]$html.AppendLine("<article class='eval-card'><div class='eval-heading'><div><span class='eyebrow'>Eval $([int]$row.Entry.eval_id)</span><h2>$(HtmlEncode $row.Entry.eval_name)</h2><p>$(HtmlEncode $metadata.prompt)</p></div><span class='status-pill'>$(if ($null -ne $row.WithSkill -and $null -ne $row.WithoutSkill) { 'paired' } else { 'partial' })</span></div><div class='run-grid'>")
    [void]$html.AppendLine((New-RunMarkup -Run $row.WithSkill -Metadata $metadata -EvalName ([string]$row.Entry.eval_name) -Configuration 'with_skill'))
    [void]$html.AppendLine((New-RunMarkup -Run $row.WithoutSkill -Metadata $metadata -EvalName ([string]$row.Entry.eval_name) -Configuration 'without_skill'))
    [void]$html.AppendLine('</div></article>')
}

[void]$html.AppendLine('</section><section id="benchmark" class="tab-panel"><div class="eval-card"><div class="eval-heading"><div><span class="eyebrow">Quality and runtime</span><h2>Benchmark</h2><p>Formal grades and harness telemetry recorded in the result files.</p></div></div><table class="benchmark-table"><thead><tr><th>Eval</th><th>Configuration</th><th>Model</th><th>Grade</th><th>Duration</th><th>Tokens</th><th>Tools</th></tr></thead><tbody>')
foreach ($row in $rows) {
    foreach ($configuration in @('with_skill', 'without_skill')) {
        $run = if ($configuration -eq 'with_skill') { $row.WithSkill } else { $row.WithoutSkill }
        if ($null -eq $run) {
            [void]$html.AppendLine("<tr><td>$(HtmlEncode $row.Entry.eval_name)</td><td>$configuration</td><td>-</td><td>missing</td><td>-</td><td>-</td><td>-</td></tr>")
            continue
        }
        $grade = if ($run.Graded -eq 0) { 'not graded' } else { "$($run.Passed)/$($run.Graded)" }
        $modelCell = if ([string]::IsNullOrWhiteSpace($run.Model)) { '-' } else { $run.Model }
        [void]$html.AppendLine("<tr><td>$(HtmlEncode $row.Entry.eval_name)</td><td>$configuration</td><td>$(HtmlEncode $modelCell)</td><td>$grade</td><td>$(Format-Number $run.Duration)</td><td>$(Format-Number $run.Tokens)</td><td>$(Format-Number $run.ToolCalls)</td></tr>")
    }
}
[void]$html.AppendLine('</tbody></table></div></section><p class="footer">Generated by the portable eval package. Review notes are kept in this browser via local storage and are not written back to the package.</p></main>')
[void]$html.AppendLine(@'
<script>
const tabs=[...document.querySelectorAll('.tab')], panels=[...document.querySelectorAll('.tab-panel')];
tabs.forEach(tab=>tab.addEventListener('click',()=>{tabs.forEach(x=>x.classList.toggle('active',x===tab));panels.forEach(x=>x.classList.toggle('active',x.id===tab.dataset.tab));}));
document.querySelectorAll('textarea[data-feedback-key]').forEach(box=>{const key='eval-review:'+box.dataset.feedbackKey;box.value=localStorage.getItem(key)||'';box.addEventListener('input',()=>localStorage.setItem(key,box.value));});
</script></body></html>
'@)

$htmlOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $iterationPath 'report.html' } else { $OutputPath }
Write-Utf8File -Path $htmlOutput -Content $html.ToString()

Write-Host "Wrote $htmlOutput"
Write-Host "Wrote $benchmarkOutput"
