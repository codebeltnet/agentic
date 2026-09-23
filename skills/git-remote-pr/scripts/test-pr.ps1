$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("git-remote-pr-test-" + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$originalState = $env:PR_TEST_STATE
$originalRepo = $env:PR_TEST_REPO
$passes = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passes++
}
function Test-Git([string[]]$Arguments) {
    $output = @(& git @Arguments 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments[0]): $output" }
    return $output.Trim()
}
function Run-Prepare([string]$Output) {
    $lines = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'prepare-pr.ps1') -OutputDirectory $Output 2>&1)
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($lines | ForEach-Object { [string]$_ }) -join "`n" }
}
function Run-Execute([string]$Evidence, [string]$Body, [string]$Title) {
    $planned = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'make-plan.ps1') -EvidenceFile $Evidence -BodyFile $Body -Title $Title 2>&1)
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ code = $LASTEXITCODE; text = ($planned | ForEach-Object { [string]$_ }) -join "`n" } }
    $plan = Join-Path (Split-Path -Parent $Evidence) 'plan.json'
    $lines = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'execute-pr.ps1') -PlanFile $plan -Approved 2>&1)
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($lines | ForEach-Object { [string]$_ }) -join "`n" }
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $shim = Join-Path $root 'shim'
    $state = Join-Path $root 'state'
    $repo = Join-Path $root 'working repo'
    $bare = Join-Path $root 'remote.git'
    New-Item -ItemType Directory -Path $shim, $state, $repo | Out-Null
    $env:PR_TEST_STATE = $state
    $env:PR_TEST_REPO = $repo
    $fake = @'
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$state = $env:PR_TEST_STATE
$repo = $env:PR_TEST_REPO
$script:ghArgs = [string[]]$args
$log = Join-Path $state 'writes.log'
function Read-Pr {
    $path = Join-Path $state 'pr.json'
    if (Test-Path $path) {
        $pr = Get-Content $path -Raw | ConvertFrom-Json
        $remote = @(& git -C $repo ls-remote origin 'refs/heads/v0.10.2/service-update')
        if ($remote) { $pr.head.sha = ($remote[0] -split "`t")[0] }
        return $pr
    }
    return $null
}
function Save-Pr($pr) {
    [System.IO.File]::WriteAllText((Join-Path $state 'pr.json'), ($pr | ConvertTo-Json -Depth 12), $utf8)
}
function Out-Json($value) { $value | ConvertTo-Json -Depth 15 -Compress }
function Value-After([string]$flag) {
    $index = [Array]::IndexOf($script:ghArgs, $flag)
    if ($index -lt 0) { return $null }
    return $script:ghArgs[$index + 1]
}
try {
    if ($args[0] -eq 'auth') {
        if (Test-Path (Join-Path $state 'no-auth')) { throw 'Not logged in; run gh auth login' }
        'Logged in'; exit 0
    }
    if ($args[0] -eq 'api') {
        $endpoint = [string]$args[-1]
        if ($endpoint -eq 'user') { Out-Json @{login='reviewer'}; exit 0 }
        if ($endpoint -eq 'repos/acme/widget') { Out-Json @{full_name='acme/widget';default_branch=if(Test-Path (Join-Path $state 'default-develop')){'develop'}else{'main'};fork=$false;permissions=@{push= -not (Test-Path (Join-Path $state 'no-push'));pull=$true}}; exit 0 }
        if ($endpoint -eq 'repos/acme/widget-fork') {
            $value = @{full_name='acme/widget-fork';default_branch='main';fork=$true;permissions=@{push=$true;pull=$true}}
            if (-not (Test-Path (Join-Path $state 'no-parent'))) { $value.parent = @{full_name='acme/widget'} }
            Out-Json $value; exit 0
        }
        if ($endpoint -eq 'repos/acme/widget/assignees/reviewer') {
            if (Test-Path (Join-Path $state 'no-assignee')) { throw 'not assignable' }
            exit 0
        }
        if ($endpoint -match '^repos/acme/widget/pulls\?') {
            $pr = Read-Pr
            if ($pr) { '[' + (ConvertTo-Json -InputObject @($pr) -Depth 15 -Compress) + ']' } else { '[[]]' }
            exit 0
        }
        if ($endpoint -match '^repos/acme/widget/pulls/(\d+)/files\?') {
            $pr = Read-Pr
            $baseSha = (& git -C $repo rev-parse main).Trim()
            $headSha = (& git -C $repo rev-parse HEAD).Trim()
            $raw = @(& git -C $repo diff --name-status $baseSha $headSha)
            $files = @($raw | ForEach-Object {
                $parts = $_ -split "`t"
                $status = switch -Regex ($parts[0]) { '^A' {'added';break} '^D' {'removed';break} '^R' {'renamed';break} default {'modified'} }
                @{filename=$parts[-1]; status=$status; previous_filename=if($status -eq 'renamed'){$parts[1]}else{$null}}
            })
            if (Test-Path (Join-Path $state 'bad-files')) { $files = @() }
            '[' + (ConvertTo-Json -InputObject @($files) -Depth 15 -Compress) + ']'
            exit 0
        }
        if ($endpoint -match '^repos/acme/widget/pulls/(\d+)$') {
            $pr = Read-Pr
            $pr.head.sha = (& git -C $repo rev-parse HEAD).Trim()
            if (Test-Path (Join-Path $state 'bad-body')) { $pr.body = 'altered' }
            if (Test-Path (Join-Path $state 'bad-base')) { $pr.base.ref = 'other' }
            if (Test-Path (Join-Path $state 'bad-head')) { $pr.head.ref = 'other' }
            if (Test-Path (Join-Path $state 'bad-sha')) { $pr.head.sha = '0000000000000000000000000000000000000000' }
            Out-Json $pr; exit 0
        }
        if ($endpoint -match '^repos/acme/widget/issues/(\d+)$') {
            $pr = Read-Pr
            Out-Json @{assignees=@($pr.assignees)}; exit 0
        }
        throw "Unexpected API endpoint: $endpoint"
    }
    if ($args[0] -eq 'pr') {
        if ($args[1] -eq 'create') {
            Add-Content $log 'create'
            $pr = @{number=7;html_url='https://github.com/acme/widget/pull/7';state='open';title=(Value-After '--title');body=[System.IO.File]::ReadAllText((Value-After '--body-file'),$utf8);draft=($args -contains '--draft');base=@{ref=(Value-After '--base');sha=(& git -C $repo rev-parse main).Trim()};head=@{ref='v0.10.2/service-update';sha=(& git -C $repo rev-parse HEAD).Trim();repo=@{full_name='acme/widget'}};assignees=@()}
            Save-Pr $pr
            $pr.html_url; exit 0
        }
        if ($args[1] -eq 'edit') {
            $pr = Read-Pr
            if ($args -contains '--body-file') {
                Add-Content $log 'edit-body'
                $pr.body = [System.IO.File]::ReadAllText((Value-After '--body-file'),$utf8)
                $pr.title = Value-After '--title'
            }
            if ($args -contains '--add-assignee') {
                Add-Content $log 'assign'
                if (Test-Path (Join-Path $state 'reject-assignee')) { throw 'assignment rejected' }
                $pr.assignees = @(@{login=(Value-After '--add-assignee')})
            }
            Save-Pr $pr
            $pr.html_url; exit 0
        }
    }
    throw "Unexpected gh command: $($args -join ' ')"
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    $fakePath = Join-Path $shim 'fake-gh.ps1'
    [System.IO.File]::WriteAllText($fakePath, $fake, $utf8)
    if ($IsWindows) {
        Copy-Item -LiteralPath $fakePath -Destination (Join-Path $shim 'gh.ps1')
    } else {
        $shellPath = Join-Path $shim 'gh'
        [System.IO.File]::WriteAllText($shellPath, "#!/bin/sh`nexec pwsh -NoProfile -NonInteractive -File '$fakePath' `"`$@`"`n", $utf8)
        & chmod +x $shellPath
    }
    $env:PATH = $shim + [System.IO.Path]::PathSeparator + $originalPath
    Test-Git @('init', '--bare', $bare) | Out-Null
    Push-Location $repo
    try {
        Test-Git @('init', '-b', 'main') | Out-Null
        Test-Git @('config', 'user.email', 'test@example.invalid') | Out-Null
        Test-Git @('config', 'user.name', 'Not The GitHub User') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'base', $utf8)
        Test-Git @('add', 'a.txt') | Out-Null
        Test-Git @('commit', '-m', 'base') | Out-Null
        $url = 'https://github.com/acme/widget.git'
        Test-Git @('remote', 'add', 'origin', $url) | Out-Null
        $fileUrl = 'file:///' + $bare.Replace('\', '/').TrimStart('/')
        Test-Git @('config', "url.$fileUrl.insteadOf", $url) | Out-Null
        Test-Git @('push', '-u', 'origin', 'main') | Out-Null
        Test-Git @('switch', '-c', 'v0.10.2/service-update') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'feature', $utf8)
        Test-Git @('add', 'a.txt') | Out-Null
        Test-Git @('commit', '-m', 'Improve feature', '-m', 'Changes actual behavior') | Out-Null

        . (Join-Path $PSScriptRoot 'pr-common.ps1')
        Assert ((Get-PrTitle 'v0.10.2/service-update') -ceq 'V0.10.2/service update') 'Title normalization failed.'
        Assert ((Get-PrTitle 'v12.0.2/chore-work') -ceq 'V12.0.2/chore work') 'Title normalization for chore branch failed.'
        Assert ((Get-PrTitle 'v0.10.0/dotnet-nuget-update') -ceq 'V0.10.0/dotnet nuget update') 'Title normalization for NuGet branch failed.'
        Assert ((Get-PrTitle 'v1.0.0/add_CLIContext') -ceq 'V1.0.0/add CLIContext') 'Title normalization lost meaningful internal casing.'
        Assert (Test-EquivalentBranchNames 'v0.11.0/chore-and-git-remote-pr' 'v0.11.0/chore_and_git_remote_pr') 'Branch normalization should allow separator-only differences.'
        Assert (-not (Test-EquivalentBranchNames 'v0.11.0/chore-and-git-remote-pr' 'v0.10.2/service-update')) 'Branch normalization should not hide real mismatches.'
        $noUpstream = Run-Prepare (Join-Path $root 'no-upstream')
        Assert ($noUpstream.code -ne 0 -and $noUpstream.text -match 'no upstream tracking branch' -and $noUpstream.text -match 'set-upstream') 'Missing upstream tracking did not fail closed.'
        Assert (-not (Test-Git @('ls-remote', '--heads', 'origin', 'refs/heads/v0.10.2/service-update'))) 'Unexpected remote branch before upstream push.'
        Test-Git @('push', '-u', 'origin', 'HEAD') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'guide.md'), 'review guide', $utf8)
        Test-Git @('add', 'guide.md') | Out-Null
        Test-Git @('commit', '-m', 'Document review flow') | Out-Null
        Test-Git @('switch', '-c', 'v0.11.0/chore-and-git-remote-pr') | Out-Null
        Test-Git @('config', 'branch.v0.11.0/chore-and-git-remote-pr.remote', 'origin') | Out-Null
        Test-Git @('config', 'branch.v0.11.0/chore-and-git-remote-pr.merge', 'refs/heads/v0.10.2/service-update') | Out-Null
        $mismatch = Run-Prepare (Join-Path $root 'mismatch')
        Assert ($mismatch.code -ne 0 -and $mismatch.text.Contains("Local branch 'v0.11.0/chore-and-git-remote-pr'") -and $mismatch.text.Contains('origin/v0.10.2/service-update') -and $mismatch.text.Contains('git branch --set-upstream-to=origin/v0.11.0/chore-and-git-remote-pr')) 'Stale branch tracking mismatch did not fail closed.'
        Test-Git @('switch', 'v0.10.2/service-update') | Out-Null
        Test-Git @('branch', '-D', 'v0.11.0/chore-and-git-remote-pr') | Out-Null
        Test-Git @('branch', 'develop', 'main') | Out-Null
        Test-Git @('push', 'origin', 'develop') | Out-Null
        New-Item (Join-Path $state 'default-develop') -ItemType File | Out-Null
        $alternateBase = Run-Prepare (Join-Path $root 'alternate-base')
        Assert ($alternateBase.code -eq 0) "Non-main default preparation failed: $($alternateBase.text)"
        Assert ((Get-Content (($alternateBase.text | ConvertFrom-Json).evidence) -Raw | ConvertFrom-Json).base -eq 'develop') 'Repository default branch was assumed to be main.'
        Remove-Item (Join-Path $state 'default-develop')
        $forkUrl = 'https://github.com/acme/widget-fork.git'
        Test-Git @('config', '--add', "url.$fileUrl.insteadOf", $forkUrl) | Out-Null
        Test-Git @('remote', 'set-url', 'origin', $forkUrl) | Out-Null
        $fork = Run-Prepare (Join-Path $root 'fork')
        Assert ($fork.code -eq 0) "Unambiguous fork preparation failed: $($fork.text)"
        $forkEvidence = Get-Content (($fork.text | ConvertFrom-Json).evidence) -Raw | ConvertFrom-Json
        Assert ($forkEvidence.repository -eq 'acme/widget' -and $forkEvidence.head_repository -eq 'acme/widget-fork') 'Fork base/head repositories were not resolved.'
        New-Item (Join-Path $state 'no-parent') -ItemType File | Out-Null
        $noParent = Run-Prepare (Join-Path $root 'no-parent')
        Assert ($noParent.code -ne 0 -and $noParent.text -match 'Fork parent') 'Ambiguous fork parent was guessed.'
        Remove-Item (Join-Path $state 'no-parent')
        Test-Git @('remote', 'set-url', 'origin', $url) | Out-Null
        $prep = Run-Prepare (Join-Path $root 'prepared')
        Assert ($prep.code -eq 0) "Clean preparation failed: $($prep.text)"
        $paths = $prep.text | ConvertFrom-Json
        $evidence = Get-Content $paths.evidence -Raw | ConvertFrom-Json
        Assert ($evidence.push_required -and $evidence.action -eq 'CREATE') 'Tracked branch with local-only commits must preview CREATE and push.'
        Assert ($evidence.commit_count -eq 2 -and $evidence.changed_file_count -eq 2) 'Complete commit or file inventory missing.'
        Assert ($evidence.commits[0].message -match 'Changes actual behavior') 'Commit body missing.'
        Assert ((Get-Content $paths.patch -Raw) -match 'review guide') 'Final patch missing documentation change.'
        Assert (-not (Test-Path (Join-Path $state 'writes.log'))) 'Preparation performed a GH write.'
        $remoteBranchHead = ((Test-Git @('ls-remote', '--heads', 'origin', 'refs/heads/v0.10.2/service-update')) -split "`t")[0]
        Assert ($remoteBranchHead -and $remoteBranchHead -cne $evidence.head_sha) 'Preparation pushed the local-only commit.'

        New-Item (Join-Path $state 'no-auth') -ItemType File | Out-Null
        $noAuth = Run-Prepare (Join-Path $root 'no-auth')
        Assert ($noAuth.code -ne 0 -and $noAuth.text -match 'auth') 'Missing auth did not fail before mutation.'
        Remove-Item (Join-Path $state 'no-auth')
        New-Item (Join-Path $state 'no-assignee') -ItemType File | Out-Null
        $noAssignee = Run-Prepare (Join-Path $root 'no-assignee')
        Assert ($noAssignee.code -ne 0 -and $noAssignee.text -match 'not assignable') 'Ineligible assignee did not fail before mutation.'
        Remove-Item (Join-Path $state 'no-assignee')
        New-Item (Join-Path $state 'no-push') -ItemType File | Out-Null
        $noPush = Run-Prepare (Join-Path $root 'no-push')
        Assert ($noPush.code -ne 0 -and $noPush.text -match 'cannot push') 'Missing push permission did not fail.'
        Remove-Item (Join-Path $state 'no-push')
        Test-Git @('checkout', '--detach', 'HEAD') | Out-Null
        $detached = Run-Prepare (Join-Path $root 'detached')
        Assert ($detached.code -ne 0 -and $detached.text -match 'Detached HEAD') 'Detached HEAD did not block.'
        Test-Git @('switch', 'v0.10.2/service-update') | Out-Null
        Test-Git @('switch', 'main') | Out-Null
        $default = Run-Prepare (Join-Path $root 'default')
        Assert ($default.code -ne 0 -and $default.text -match 'base branch') 'Default branch did not block.'
        Test-Git @('switch', '-c', 'empty') | Out-Null
        Test-Git @('push', '-u', 'origin', 'HEAD') | Out-Null
        $empty = Run-Prepare (Join-Path $root 'empty')
        Assert ($empty.code -ne 0 -and $empty.text -match 'no changed files') 'Empty comparison did not block.'
        Test-Git @('switch', 'v0.10.2/service-update') | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $repo 'untracked.txt'), 'untracked', $utf8)
        $dirty = Run-Prepare (Join-Path $root 'dirty')
        Assert ($dirty.code -ne 0 -and $dirty.text -match 'untracked') 'Untracked file did not block.'
        Remove-Item (Join-Path $repo 'untracked.txt')
        [System.IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'uncommitted', $utf8)
        $trackedDirty = Run-Prepare (Join-Path $root 'tracked-dirty')
        Assert ($trackedDirty.code -ne 0 -and $trackedDirty.text -match 'uncommitted or untracked') 'Tracked modification did not block.'
        Test-Git @('restore', 'a.txt') | Out-Null
        $evidence.files | ForEach-Object { $_.theme = if ($_.path -eq 'guide.md') { 'Documentation' } else { 'Behavior' } }
        $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $paths.evidence -Encoding utf8
        $bodyPath = Join-Path (Split-Path $paths.evidence) 'body.md'
        [System.IO.File]::WriteAllText($bodyPath, "This pull request changes behavior and review guidance.`n`n**Behavior**`n`n- Updates the feature.`n`n**Documentation**`n`n- Adds review guidance.", $utf8)
        $planText = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'make-plan.ps1') -EvidenceFile $paths.evidence -BodyFile $bodyPath -Title 'V0.10.2/service update' 2>&1)
        Assert ($LASTEXITCODE -eq 0) "Read-only plan failed: $($planText -join ' ')"
        $plan = ($planText -join "`n") | ConvertFrom-Json
        Assert ($plan.push_required -and $plan.metadata_write -eq 'CREATE' -and $plan.assignment_write) 'Plan did not declare exact create writes.'
        Assert (-not (Test-Path (Join-Path $state 'writes.log'))) 'Planning made a GH write.'
        $planPath = Join-Path (Split-Path $paths.evidence) 'plan.json'
        $noApprovalLines = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'execute-pr.ps1') -PlanFile $planPath 2>&1)
        Assert ($LASTEXITCODE -ne 0 -and ($noApprovalLines -join "`n") -match 'approval') 'Execute accepted a plan without approval.'
        [System.IO.File]::AppendAllText($bodyPath, "`nAltered after preview.", $utf8)
        $tamperedLines = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'execute-pr.ps1') -PlanFile $planPath -Approved 2>&1)
        Assert ($LASTEXITCODE -ne 0 -and ($tamperedLines -join "`n") -match 'changed after the preview') 'Altered body passed the prepared plan hash.'
        Assert (-not (Test-Path (Join-Path $state 'writes.log'))) 'Withheld approval or changed body made a GH write.'
        [System.IO.File]::WriteAllText($bodyPath, "This pull request changes behavior and review guidance.`n`n**Behavior**`n`n- Updates the feature.`n`n**Documentation**`n`n- Adds review guidance.", $utf8)
        $wrong = Run-Execute $paths.evidence $bodyPath 'V0.10.2/service update'
        Assert ($wrong.code -eq 0) "Approved create failed: $($wrong.text)"
        $created = $wrong.text | ConvertFrom-Json
        Assert ($created.result -eq 'created' -and $created.assignee -eq 'reviewer') 'Create result or authenticated assignment wrong.'
        Assert ((Get-Content (Join-Path $state 'writes.log')).Count -eq 2) 'Expected only create and assignment GH writes.'
        Assert ((Test-Git @('ls-remote', '--heads', 'origin', 'refs/heads/v0.10.2/service-update')) -match (Test-Git @('rev-parse', 'HEAD'))) 'Remote branch SHA differs.'
        $second = Run-Prepare (Join-Path $root 'second')
        Assert ($second.code -eq 0) "Existing PR preparation failed: $($second.text)"
        $secondPaths = $second.text | ConvertFrom-Json
        $secondEvidence = Get-Content $secondPaths.evidence -Raw | ConvertFrom-Json
        Assert ($secondEvidence.action -eq 'UPDATE' -and -not $secondEvidence.push_required) 'Existing PR not reused.'
        $secondEvidence.files | ForEach-Object { $_.theme = if ($_.path -eq 'guide.md') { 'Documentation' } else { 'Behavior' } }
        $secondEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $secondPaths.evidence -Encoding utf8
        $secondBody = Join-Path (Split-Path $secondPaths.evidence) 'body.md'
        Copy-Item $bodyPath $secondBody
        $noOp = Run-Execute $secondPaths.evidence $secondBody 'V0.10.2/service update'
        Assert ($noOp.code -eq 0 -and $noOp.text -match 'already up to date') "No-op update failed: $($noOp.text)"
        Assert ((Get-Content (Join-Path $state 'writes.log')).Count -eq 2) 'No-op made a metadata write.'
        [System.IO.File]::WriteAllText((Join-Path $repo 'extra.txt'), 'more', $utf8)
        Test-Git @('add', 'extra.txt') | Out-Null
        Test-Git @('commit', '-m', 'Add extra result') | Out-Null
        $stale = Run-Execute $secondPaths.evidence $secondBody 'V0.10.2/service update'
        Assert ($stale.code -ne 0 -and $stale.text -match 'Material repository') 'Changed HEAD did not invalidate approval.'
        Assert ((Get-Content (Join-Path $state 'writes.log')).Count -eq 2) 'Stale approval made a GH write.'
        $third = Run-Prepare (Join-Path $root 'third')
        Assert ($third.code -eq 0) "New-commit preparation failed: $($third.text)"
        $thirdPaths = $third.text | ConvertFrom-Json
        $thirdEvidence = Get-Content $thirdPaths.evidence -Raw | ConvertFrom-Json
        Assert ($thirdEvidence.push_required -and $thirdEvidence.commit_count -eq 3 -and $thirdEvidence.changed_file_count -eq 3) 'Additional commit not inventoried.'
        $thirdEvidence.files | ForEach-Object { $_.theme = if ($_.path -eq 'guide.md') { 'Documentation' } else { 'Behavior' } }
        $thirdEvidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $thirdPaths.evidence -Encoding utf8
        $thirdBody = Join-Path (Split-Path $thirdPaths.evidence) 'body.md'
        [System.IO.File]::WriteAllText($thirdBody, "This pull request changes behavior and review guidance.`n`n**Behavior**`n`n- Updates the feature and extra result.`n`n**Documentation**`n`n- Adds review guidance.", $utf8)
        $update = Run-Execute $thirdPaths.evidence $thirdBody 'V0.10.2/service update'
        Assert ($update.code -eq 0 -and $update.text -match 'updated') "Existing PR refresh failed: $($update.text)"
        Assert ((Get-Content (Join-Path $state 'pr.json') -Raw | ConvertFrom-Json).body -ceq [System.IO.File]::ReadAllText($thirdBody, $utf8)) 'Existing body was not replaced in full.'
        New-Item (Join-Path $state 'bad-files') -ItemType File | Out-Null
        $fourth = Run-Prepare (Join-Path $root 'fourth')
        $fourthPaths = $fourth.text | ConvertFrom-Json
        $fourthEvidence = Get-Content $fourthPaths.evidence -Raw | ConvertFrom-Json
        $fourthEvidence.files | ForEach-Object { $_.theme = if ($_.path -eq 'guide.md') { 'Documentation' } else { 'Behavior' } }
        $fourthEvidence | ConvertTo-Json -Depth 20 | Set-Content $fourthPaths.evidence -Encoding utf8
        $fourthBody = Join-Path (Split-Path $fourthPaths.evidence) 'body.md'
        Copy-Item $thirdBody $fourthBody
        $bad = Run-Execute $fourthPaths.evidence $fourthBody 'V0.10.2/service update'
        Assert ($bad.code -ne 0 -and $bad.text -match 'GitHub lists' -and $bad.text -match '/pull/7') 'File mismatch did not fail with PR URL.'
        Remove-Item (Join-Path $state 'bad-files')
        New-Item (Join-Path $state 'bad-body') -ItemType File | Out-Null
        $badBody = Run-Execute $fourthPaths.evidence $fourthBody 'V0.10.2/service update'
        Assert ($badBody.code -ne 0 -and $badBody.text -match 'persisted title or complete body' -and $badBody.text -match '/pull/7') 'Body mismatch did not fail with PR URL.'
        Remove-Item (Join-Path $state 'bad-body')
        foreach ($marker in @('bad-base', 'bad-head', 'bad-sha')) {
            New-Item (Join-Path $state $marker) -ItemType File | Out-Null
            $mismatch = Run-Execute $fourthPaths.evidence $fourthBody 'V0.10.2/service update'
            Assert ($mismatch.code -ne 0 -and $mismatch.text -match 'Post-write verification' -and $mismatch.text -match '/pull/7') "$marker mismatch did not fail with PR URL."
            Remove-Item (Join-Path $state $marker)
        }
        $prStatePath = Join-Path $state 'pr.json'
        $prState = Get-Content $prStatePath -Raw | ConvertFrom-Json
        $prState.assignees = @()
        $prState | ConvertTo-Json -Depth 15 | Set-Content $prStatePath -Encoding utf8
        New-Item (Join-Path $state 'reject-assignee') -ItemType File | Out-Null
        $assignPrep = Run-Prepare (Join-Path $root 'assign-prep')
        Assert ($assignPrep.code -eq 0) 'Assignment retry preparation failed.'
        $assignPaths = $assignPrep.text | ConvertFrom-Json
        $assignEvidence = Get-Content $assignPaths.evidence -Raw | ConvertFrom-Json
        $assignEvidence.files | ForEach-Object { $_.theme = if ($_.path -eq 'guide.md') { 'Documentation' } else { 'Behavior' } }
        $assignEvidence | ConvertTo-Json -Depth 20 | Set-Content $assignPaths.evidence -Encoding utf8
        $assignBody = Join-Path (Split-Path $assignPaths.evidence) 'body.md'
        Copy-Item $thirdBody $assignBody
        $assignFail = Run-Execute $assignPaths.evidence $assignBody 'V0.10.2/service update'
        Assert ($assignFail.code -ne 0 -and $assignFail.text -match 'assignment rejected' -and $assignFail.text -match '/pull/7') 'Assignment failure did not expose partial PR URL.'
        Remove-Item (Join-Path $state 'reject-assignee')

        Test-Git @('switch', 'main') | Out-Null
        New-Item -ItemType Directory (Join-Path $repo '.github') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo '.github/pull_request_template.md'), "## Summary`n`n## Validation`n- [ ] Tests passed`n", $utf8)
        Test-Git @('add', '.github/pull_request_template.md') | Out-Null
        Test-Git @('commit', '-m', 'Add PR template') | Out-Null
        Test-Git @('push', 'origin', 'main') | Out-Null
        Test-Git @('switch', 'v0.10.2/service-update') | Out-Null
        $templated = Run-Prepare (Join-Path $root 'template')
        Assert ($templated.code -eq 0) "Default template preparation failed: $($templated.text)"
        $templatePaths = $templated.text | ConvertFrom-Json
        Assert ($templatePaths.template -and (Get-Content $templatePaths.template -Raw) -match 'Tests passed') 'Repository PR template was not collected.'

        $binaryPath = Join-Path $repo 'image.bin'
        [System.IO.File]::WriteAllBytes($binaryPath, [byte[]]@(0,1,2,3,4,5))
        Test-Git @('add', 'image.bin') | Out-Null
        Test-Git @('commit', '-m', 'Add binary asset') | Out-Null
        $binaryPrep = Run-Prepare (Join-Path $root 'binary')
        Assert ($binaryPrep.code -eq 0) "Binary preparation failed: $($binaryPrep.text)"
        $binaryEvidence = Get-Content (($binaryPrep.text | ConvertFrom-Json).evidence) -Raw | ConvertFrom-Json
        Assert (@($binaryEvidence.files | Where-Object { $_.path -eq 'image.bin' -and $_.binary }).Count -eq 1) 'Binary file was not marked in evidence.'

        $other = Join-Path $root 'other clone'
        Test-Git @('clone', $bare, $other) | Out-Null
        Test-Git @('-C', $other, 'config', 'user.email', 'other@example.invalid') | Out-Null
        Test-Git @('-C', $other, 'config', 'user.name', 'Other') | Out-Null
        Test-Git @('-C', $other, 'switch', 'v0.10.2/service-update') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $other 'remote.txt'), 'diverged', $utf8)
        Test-Git @('-C', $other, 'add', 'remote.txt') | Out-Null
        Test-Git @('-C', $other, 'commit', '-m', 'Remote-only commit') | Out-Null
        Test-Git @('-C', $other, 'push', 'origin', 'HEAD') | Out-Null
        $diverged = Run-Prepare (Join-Path $root 'diverged')
        Assert ($diverged.code -ne 0 -and $diverged.text -match 'diverged') 'Diverged remote did not fail closed.'
    } finally { Pop-Location }
    "PASS git-remote-pr deterministic tests ($passes assertions)"
} finally {
    $env:PATH = $originalPath
    $env:PR_TEST_STATE = $originalState
    $env:PR_TEST_REPO = $originalRepo
    if ($env:PR_TEST_KEEP) { Write-Host "TEST WORKSPACE: $root" }
    elseif (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
