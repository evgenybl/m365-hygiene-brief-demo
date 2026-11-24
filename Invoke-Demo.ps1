#requires -Version 7.4
<#
.SYNOPSIS
    Runs the whole story on the invented tenant into a new folder, one line per step, or one case of the failure
    gallery.

.DESCRIPTION
    The story, on data/ (an invented tenant, as of 2026-11-21):
      1 findings   Get-TenantHygieneFindings.ps1: the eight rules, the administrator's file, the summary
      2 brief      New-ManagerBrief.ps1 with its default answer, recordings/brief.constructed.md, written by hand to the
                   request and labelled "Constructed, not from a model" (as its meta file earns)
      3 decisions  Set-BriefDecision.ps1: five answers typed for an invented manager, one decision left open
      4 work list  New-AdminWorklist.ps1: the accounts and items of the decisions answered Yes
      5 pages      New-HygieneReport.ps1: the manager's page and the administrator's page
    It ends with a table: each rule, its count, its decision, the answer (with the number of answers when there is
    more than one), and what reached the work list. The dates and times are fixed, so the output is the same on every
    day, in every time zone and every culture.

    -Case runs one case of the failure gallery instead (or "all" of them), each into its own folder:
      clean-tenant         a tenant with nothing to find: every count is 0 and no decision is asked
      bad-date             a day-first date in a row: refused with the row number, nothing written
      invented-figure      a brief with a figure not in the summary: the template is used, and the report says why
      missing-decision     a brief that leaves a decision out: refused, the template is used
      decision-no          a decision answered No: its accounts are absent from the work list
      other-summary        a decisions file written for another summary: refused
      collector-throttled  the collector against the local mock, which answers 429 once: waited for, then completed
      collector-403        the collector against a mock that answers 403: stopped, nothing written
      model-500            the live model path against a mock that answers 500: stopped, nothing written
    The mocks run on this computer only (lib/LocalMock.ps1); nothing leaves it. The collector, Export-TenantSnapshot.ps1,
    is labelled: Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.

    Each step runs in a child process under the culture of this run (lib/Invoke-Step.ps1). The exit code is 0 when
    every step, or every case, ended as expected.

.EXAMPLE
    pwsh -File Invoke-Demo.ps1
.EXAMPLE
    pwsh -File Invoke-Demo.ps1 -Case bad-date
#>
[CmdletBinding()]
param(
    [string] $OutDir = '',
    [ValidateSet('clean-tenant', 'bad-date', 'invented-figure', 'missing-decision', 'decision-no', 'other-summary',
        'collector-throttled', 'collector-403', 'model-500', 'all')] [string] $Case = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/LocalMock.ps1"

$here = $PSScriptRoot
$culture = [cultureinfo]::CurrentCulture.Name
$asOf = '2026-11-21'
$data = Join-Path $here 'data'
$users = Join-Path $data 'users.synthetic.csv'
$skus = Join-Path $data 'skus.synthetic.csv'
$policies = Join-Path $data 'policies.synthetic.csv'
$tenant = Join-Path $data 'tenant.synthetic.csv'
$script:printed = [System.Collections.Generic.List[string]]::new()
# A printed line goes straight to standard output, so that a function's return value is only what it returns.
function Say([string] $Line) { $script:printed.Add($Line); [Console]::Out.WriteLine($Line) }

# The arguments of a child pwsh that runs one script of this repository under this run's culture.
function Get-StepArgs([string] $Script, [string[]] $Arguments) {
    $a = @('-File', (Join-Path $here 'lib/Invoke-Step.ps1'))
    if ($culture) { $a += @('-WrapCulture', $culture) }
    $a + @('-WrapScript', (Join-Path $here $Script)) + $Arguments
}
function Invoke-DemoStep([string] $Script, [string[]] $Arguments) {
    $argList = Get-StepArgs $Script $Arguments
    $out = @(& pwsh -NoProfile @argList 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
}
function Get-Refusal($Run) {
    $line = @($Run.Lines | Where-Object { $_ -like 'REFUSED: *' } | Select-Object -First 1)
    if ($line.Count) { $line[0].Substring(9) -replace 'the API call failed: .*; nothing was written', 'the API call failed; nothing was written' } else { '' }
}
function New-Folder([string] $Path) {
    if (Test-Path -LiteralPath $Path) { Stop-Refused "refusing to write into an existing folder: $Path" }
    New-Item -ItemType Directory -Path $Path | Out-Null
}
function Format-Step([string] $Name, [bool] $Ok, [string] $Detail) { '{0,-11} {1,-8} {2}' -f $Name, $(if ($Ok) { 'OK' } else { 'FAIL' }), $Detail }

# --- the story ------------------------------------------------------------------------------------------------------
function Invoke-Story([string] $Dir) {
    New-Folder $Dir
    $f = Join-Path $Dir 'findings'; $b = Join-Path $Dir 'brief'; $w = Join-Path $Dir 'worklist'; $p = Join-Path $Dir 'pages'
    $ok = $true
    Say ('Microsoft 365 hygiene demo: synthetic data, as of {0}' -f $asOf)
    $r = Invoke-DemoStep 'Get-TenantHygieneFindings.ps1' @('-UsersCsv', $users, '-SkusCsv', $skus, '-PoliciesCsv', $policies, '-TenantCsv', $tenant, '-AsOf', $asOf, '-OutDir', $f)
    $ok = $ok -and $r.Code -eq 0; Say (Format-Step 'findings' ($r.Code -eq 0) $r.Text)
    $r = Invoke-DemoStep 'New-ManagerBrief.ps1' @('-SummaryJson', (Join-Path $f 'findings-summary.json'), '-UsersCsv', $users, '-OutDir', $b)
    $ok = $ok -and $r.Code -eq 0; Say (Format-Step 'brief' ($r.Code -eq 0) $r.Text)
    $manager = 'Rina Manager (synthetic)'
    $answers = @(
        , @('D1', 'Yes', '2026-11-22T09:00:00Z', '')
        , @('D2', 'Yes', '2026-11-22T09:01:00Z', '')
        , @('D3', 'Yes', '2026-11-22T09:02:00Z', '')
        , @('D4', 'No', '2026-11-22T09:03:00Z', 'The policies stay in report-only mode until the help desk has read what they would block.')
        , @('D5', 'Yes', '2026-11-22T09:04:00Z', ''))
    $recorded = 0
    foreach ($a in $answers) {
        $r = Invoke-DemoStep 'Set-BriefDecision.ps1' @('-BriefDir', $b, '-Decision', $a[0], '-Answer', $a[1], '-By', $manager, '-At', $a[2], '-Reason', $a[3])
        if ($r.Code -eq 0) { $recorded++ } else { $ok = $false }
    }
    Say (Format-Step 'decisions' ($recorded -eq $answers.Count) ('{0} answers recorded: {1}; D6 left open' -f $recorded,
        (($answers | ForEach-Object { '{0} {1}' -f $_[0], $_[1] }) -join ', ')))
    $r = Invoke-DemoStep 'New-AdminWorklist.ps1' @('-FindingsDir', $f, '-BriefDir', $b, '-OutDir', $w)
    $ok = $ok -and $r.Code -eq 0; Say (Format-Step 'work list' ($r.Code -eq 0) $r.Text)
    $r = Invoke-DemoStep 'New-HygieneReport.ps1' @('-FindingsDir', $f, '-BriefDir', $b, '-WorklistDir', $w, '-UsersCsv', $users, '-DataKind', 'Synthetic', '-OutDir', $p)
    $ok = $ok -and $r.Code -eq 0; Say (Format-Step 'pages' ($r.Code -eq 0) $r.Text)
    if (-not $ok) { return $false }

    # The closing table, from the files the steps wrote.
    $summary = Read-JsonExact (Join-Path $f 'findings-summary.json')
    $list = Read-JsonExact (Join-Path $w 'worklist.json')
    $ids = @(@($summary['decisions']) | Where-Object { $_ } | ForEach-Object { $_['id'] })
    $history = Get-AnswerHistory (Read-DecisionsFile (Join-Path $b 'decisions.json') (Get-FileSha256 (Join-Path $f 'findings-summary.json')) $ids)
    $t = $summary['thresholds']
    $short = @{
        R3 = 'enabled administrator without MFA registered'
        R6 = 'more than {0} global administrators' -f $t['global_admin_limit']
        R7 = 'legacy authentication not blocked'
        R8 = 'created more than {0} days ago, still report-only' -f $t['report_only_days']
        R4 = 'guest, no sign-in for {0} days or none on record' -f $t['stale_days']
        R1 = 'licensed, no sign-in for over {0} days' -f $t['stale_days']
        R2 = 'disabled, still licensed'
        R5 = 'licensed, no sign-in on record, over {0} days old' -f $t['new_account_grace_days']
    }
    Say ''
    Say ('{0,-5} {1,-48} {2,5}  {3,-8} {4,-7} {5}' -f 'rule', 'finding', 'count', 'decision', 'answer', 'work list')
    $order = @('R3', 'R6', 'R7', 'R8', 'R4', 'R1', 'R2', 'R5')
    foreach ($id in $order) {
        $rule = @($summary['rules'] | Where-Object { $_['id'] -eq $id })[0]
        $d = @(@($summary['decisions']) | Where-Object { $_ -and $id -in @($_['rules']) })
        $did = if ($d.Count) { $d[0]['id'] } else { '-' }
        $answer = '-'
        if ($d.Count -and $history.Contains($did)) {
            $h = $history[$did]
            $answer = $h[$h.Count - 1]['answer'] + $(if ($h.Count -gt 1) { ' ({0} answers)' -f $h.Count } else { '' })
        } elseif ($d.Count) { $answer = 'open' }
        $n = @(@($list['items']) | Where-Object { $_ -and $_['Rule'] -eq $id }).Count
        $items = if ($n -eq 1) { '1 item' } elseif ($n) { "$n items" } else { '-' }
        $count = if ($null -eq $rule['count']) { 'not checked' } else { $rule['count'] }
        Say ('{0,-5} {1,-48} {2,5}  {3,-8} {4,-7} {5}' -f $id, $short[$id], $count, $did, $answer, $items)
    }
    Say ''
    Say ('reclaimable each month: {0} invented units (not money) | the work list changes nothing in any tenant' -f $summary['reclaimable_monthly_cost_synthetic'])
    Write-LineFile (Join-Path $Dir 'demo-output.txt') $script:printed.ToArray()
    $true
}

# --- the failure gallery ----------------------------------------------------------------------------------------------
$userHead = 'UserPrincipalName,DisplayName,Department,UserType,AccountEnabled,IsAdmin,MfaRegistered,CreatedDate,LastSignInDate,AssignedLicenses,AdminRoles'
$policyHead = 'PolicyId,DisplayName,State,CreatedDate,ClientAppTypes,IncludeUsers,IncludeApplications,ExcludeApplications,ApplicationFilter,GrantControls,OtherConditions'
$blockLegacy = '00000000-0000-4000-8000-00000000a001,Block legacy authentication (synthetic),enabled,2025-01-15T08:00:00Z,exchangeActiveSync;other,All,All,,,block,'

function Invoke-Findings([string] $Dir, [string] $Users, [string] $Policies = $policies) {
    Invoke-DemoStep 'Get-TenantHygieneFindings.ps1' @('-UsersCsv', $Users, '-SkusCsv', $skus, '-PoliciesCsv', $Policies, '-TenantCsv', $tenant, '-AsOf', $asOf, '-OutDir', $Dir)
}
function Invoke-Brief([string] $Findings, [string] $Dir, [string] $Answer = '') {
    $a = @('-SummaryJson', (Join-Path $Findings 'findings-summary.json'), '-UsersCsv', $users, '-OutDir', $Dir)
    if ($Answer) { $a += @('-Recorded', $Answer) }
    Invoke-DemoStep 'New-ManagerBrief.ps1' $a
}
$defaultBrief = [IO.File]::ReadAllText((Join-Path $here 'recordings/brief.constructed.md'))

function Invoke-Case([string] $Name, [string] $Dir) {
    New-Folder $Dir
    $in = Join-Path $Dir 'input'; New-Item -ItemType Directory -Path $in | Out-Null
    $f = Join-Path $Dir 'findings'; $b = Join-Path $Dir 'brief'
    switch ($Name) {
        'clean-tenant' {
            Say 'case clean-tenant: one account, signed in yesterday, MFA registered; legacy authentication blocked'
            Write-LineFile (Join-Path $in 'users.csv') @($userHead, 'clean@demo.example.com,Clean Account (synthetic),Sales,Member,true,false,true,2024-01-10,2026-11-20,SYN_SUITE_STANDARD,')
            Write-LineFile (Join-Path $in 'policies.csv') @($policyHead, $blockLegacy)
            $r = Invoke-Findings $f (Join-Path $in 'users.csv') (Join-Path $in 'policies.csv')
            Say (Format-Step 'findings' ($r.Code -eq 0) $r.Text)
            $s = if ($r.Code -eq 0) { Read-JsonExact (Join-Path $f 'findings-summary.json') } else { $null }
            $ok = $null -ne $s -and @($s['rules'] | Where-Object { $_['count'] -ne 0 }).Count -eq 0 -and @($s['decisions']).Count -eq 0 -and
                $s['reclaimable_monthly_cost_synthetic'] -eq '0'
            Say (Format-Step 'result' $ok 'every count is 0, nothing is reclaimable, and no decision is asked')
            return $ok
        }
        'bad-date' {
            Say 'case bad-date: the second row of the users table has a day-first date, 21/08/2026'
            Write-LineFile (Join-Path $in 'users.csv') @($userHead,
                'one@demo.example.com,One Account (synthetic),Sales,Member,true,false,true,2024-01-10,2026-11-20,SYN_SUITE_STANDARD,',
                'two@demo.example.com,Two Account (synthetic),Sales,Member,true,false,true,2024-01-10,21/08/2026,SYN_SUITE_STANDARD,')
            $r = Invoke-Findings $f (Join-Path $in 'users.csv')
            $ok = $r.Code -eq 2 -and (Get-Refusal $r) -like 'row 2: LastSignInDate *' -and -not (Test-Path -LiteralPath $f)
            Say (Format-Step 'findings' $ok ('REFUSED (exit {0}): {1}' -f $r.Code, (Get-Refusal $r)))
            Say (Format-Step 'result' $ok ('nothing written: {0}' -f $(if (Test-Path -LiteralPath $f) { 'no' } else { 'yes' })))
            return $ok
        }
        { $_ -in 'invented-figure', 'missing-decision' } {
            if ($Name -eq 'invented-figure') {
                Say 'case invented-figure: the demo''s brief, with a sentence added that holds a figure the summary does not hold'
                $text = $defaultBrief.Replace('These units were invented for this demo.', 'You will save 500 units a month. These units were invented for this demo.')
                $want = 'figures not in the summary: 500'
            } else {
                Say 'case missing-decision: the demo''s brief, with the line of decision D4 taken out'
                $text = ($defaultBrief -split "`n" | Where-Object { $_ -notlike '- D4 *' }) -join "`n"
                $want = 'a decision left out: D4'
            }
            Write-TextFile (Join-Path $in 'answer.md') $text
            $r = Invoke-Findings $f $users
            $r2 = Invoke-Brief $f $b (Join-Path $in 'answer.md')
            $rep = if (Test-Path -LiteralPath (Join-Path $b 'brief-report.json')) { Read-JsonExact (Join-Path $b 'brief-report.json') } else { $null }
            $ok = $r.Code -eq 0 -and $r2.Code -eq 0 -and $null -ne $rep -and -not $rep['ai_text_accepted'] -and $want -in @($rep['problems']) -and
                [IO.File]::ReadAllText((Join-Path $b 'brief.md')).Contains('Your decisions:')
            Say (Format-Step 'brief' $ok ('text refused: {0}' -f $(if ($rep) { @($rep['problems']) -join '; ' } else { '' })))
            Say (Format-Step 'result' $ok 'brief.md is the fixed template with the script''s own figures, and brief-report.json says why')
            return $ok
        }
        'decision-no' {
            Say 'case decision-no: D5 (remove the stale guests) is answered No; D1 (MFA for administrators) Yes'
            $r = Invoke-Findings $f $users
            $r2 = Invoke-Brief $f $b
            $r3 = Invoke-DemoStep 'Set-BriefDecision.ps1' @('-BriefDir', $b, '-Decision', 'D1', '-Answer', 'Yes', '-By', 'Rina Manager (synthetic)', '-At', '2026-11-22T09:00:00Z')
            $r4 = Invoke-DemoStep 'Set-BriefDecision.ps1' @('-BriefDir', $b, '-Decision', 'D5', '-Answer', 'No', '-By', 'Rina Manager (synthetic)', '-At', '2026-11-22T09:05:00Z',
                '-Reason', 'The guests are partners in a project that restarts next month.')
            $w = Join-Path $Dir 'worklist'
            $r5 = Invoke-DemoStep 'New-AdminWorklist.ps1' @('-FindingsDir', $f, '-BriefDir', $b, '-OutDir', $w)
            $rows = if ($r5.Code -eq 0) { @(Import-Csv -LiteralPath (Join-Path $w 'worklist.csv')) } else { @() }
            $ok = @(@($r, $r2, $r3, $r4, $r5) | Where-Object { $_.Code -ne 0 }).Count -eq 0 -and @($rows | Where-Object Rule -eq 'R4').Count -eq 0 -and
                @($rows | Where-Object Rule -eq 'R3').Count -gt 0
            Say (Format-Step 'work list' ($r5.Code -eq 0) $r5.Text)
            Say (Format-Step 'result' $ok ('rows for R4 (D5, No): {0} | rows for R3 (D1, Yes): {1}' -f @($rows | Where-Object Rule -eq 'R4').Count,
                @($rows | Where-Object Rule -eq 'R3').Count))
            return $ok
        }
        'other-summary' {
            Say 'case other-summary: a decisions file written for one summary is put beside another'
            $f2 = Join-Path $Dir 'findings-clean'; $b2 = Join-Path $Dir 'brief-clean'
            Write-LineFile (Join-Path $in 'users.csv') @($userHead, 'admin@demo.example.com,Admin Account (synthetic),IT,Member,true,true,false,2024-01-10,2026-11-20,SYN_SUITE_STANDARD,')
            $r = Invoke-Findings $f $users
            $r2 = Invoke-Brief $f $b
            $r3 = Invoke-DemoStep 'Set-BriefDecision.ps1' @('-BriefDir', $b, '-Decision', 'D1', '-Answer', 'Yes', '-By', 'Rina Manager (synthetic)', '-At', '2026-11-22T09:00:00Z')
            $r4 = Invoke-Findings $f2 (Join-Path $in 'users.csv')
            $r5 = Invoke-Brief $f2 $b2
            Copy-Item -LiteralPath (Join-Path $b 'decisions.json') -Destination (Join-Path $b2 'decisions.json')
            $before = Get-FileSha256 (Join-Path $b2 'decisions.json')
            $r6 = Invoke-DemoStep 'Set-BriefDecision.ps1' @('-BriefDir', $b2, '-Decision', 'D1', '-Answer', 'Yes', '-By', 'Rina Manager (synthetic)', '-At', '2026-11-22T09:10:00Z')
            $w = Join-Path $Dir 'worklist'
            $r7 = Invoke-DemoStep 'New-AdminWorklist.ps1' @('-FindingsDir', $f2, '-BriefDir', $b2, '-OutDir', $w)
            $same = (Get-FileSha256 (Join-Path $b2 'decisions.json')) -eq $before
            $ok = @(@($r, $r2, $r3, $r4, $r5) | Where-Object { $_.Code -ne 0 }).Count -eq 0 -and $r6.Code -eq 2 -and $r7.Code -eq 2 -and -not (Test-Path -LiteralPath $w) -and $same
            Say (Format-Step 'decision' ($r6.Code -eq 2) ('REFUSED (exit {0}): {1}' -f $r6.Code, (Get-Refusal $r6)))
            Say (Format-Step 'work list' ($r7.Code -eq 2) ('REFUSED (exit {0}): {1}' -f $r7.Code, (Get-Refusal $r7)))
            Say (Format-Step 'result' $ok ('the decisions file is byte for byte as it was: {0} | no work list written: {1}' -f $(if ($same) { 'yes' } else { 'no' }), $(if (Test-Path -LiteralPath $w) { 'no' } else { 'yes' })))
            return $ok
        }
        { $_ -in 'collector-throttled', 'collector-403' } {
            $throttled = $Name -eq 'collector-throttled'
            Say $(if ($throttled) { 'case collector-throttled: the local Graph mock answers the licence request with 429 and Retry-After: 1, once' }
                else { 'case collector-403: the local Graph mock answers the users request with 403' })
            $answer = if ($throttled) { New-GraphMockAnswer -Folder (Join-Path $here 'mock/graph') -Throttle licences } else { New-GraphMockAnswer -Folder (Join-Path $here 'mock/graph') -Fail users }
            $snap = Join-Path $Dir 'snapshot'
            $saved = $env:GRAPH_ACCESS_TOKEN
            try {
                $env:GRAPH_ACCESS_TOKEN = 'demo' + '-' + 'placeholder'
                $m = Invoke-WithLocalMock -Answer $answer -PwshArgs (Get-StepArgs 'Export-TenantSnapshot.ps1' @('-OutDir', $snap, '-GraphBase', '{base}'))
            } finally { $env:GRAPH_ACCESS_TOKEN = $saved }
            $gets = @($m.Requests | Where-Object Method -eq 'GET').Count
            $others = @($m.Requests | Where-Object Method -ne 'GET').Count
            if ($throttled) {
                $ok = $m.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $snap 'users.csv')) -and $others -eq 0
                Say (Format-Step 'collector' $ok (@($m.Lines) -join ' '))
            } else {
                $run = [pscustomobject]@{ Lines = $m.Lines }
                $ok = $m.ExitCode -eq 3 -and -not (Test-Path -LiteralPath $snap) -and $others -eq 0
                Say (Format-Step 'collector' $ok ('REFUSED (exit {0}): {1}' -f $m.ExitCode, (Get-Refusal $run)))
            }
            Say (Format-Step 'result' $ok ('requests the mock received: {0} GET, {1} other' -f $gets, $others))
            return $ok
        }
        'model-500' {
            Say 'case model-500: the live model path, against a local mock of the Messages API that answers 500'
            $r = Invoke-Findings $f $users
            $answer = { param($Method, $Target) @{ Status = 500; Body = '{"type":"error","error":{"type":"api_error","message":"mock failure"}}' } }
            $saved = $env:ANTHROPIC_API_KEY
            try {
                $env:ANTHROPIC_API_KEY = 'demo' + '-' + 'placeholder'
                $m = Invoke-WithLocalMock -Answer $answer -PwshArgs (Get-StepArgs 'New-ManagerBrief.ps1' @('-SummaryJson', (Join-Path $f 'findings-summary.json'),
                    '-UsersCsv', $users, '-OutDir', $b, '-Backend', 'Anthropic', '-ApiBase', '{base}'))
            } finally { $env:ANTHROPIC_API_KEY = $saved }
            $run = [pscustomobject]@{ Lines = $m.Lines }
            $ok = $r.Code -eq 0 -and $m.ExitCode -eq 3 -and -not (Test-Path -LiteralPath $b) -and @($m.Requests).Count -eq 1
            Say (Format-Step 'brief' $ok ('REFUSED (exit {0}): {1}' -f $m.ExitCode, (Get-Refusal $run)))
            Say (Format-Step 'result' $ok ('requests the mock received: {0}; nothing written: {1}' -f @($m.Requests).Count, $(if (Test-Path -LiteralPath $b) { 'no' } else { 'yes' })))
            return $ok
        }
    }
}

if (-not $Case) {
    $dir = if ($OutDir) { $OutDir } else { 'out-demo' }
    $ok = Invoke-Story $dir
    exit $(if ($ok) { 0 } else { 1 })
}
$names = @(if ($Case -eq 'all') { @('clean-tenant', 'bad-date', 'invented-figure', 'missing-decision', 'decision-no', 'other-summary',
    'collector-throttled', 'collector-403', 'model-500') } else { $Case })
$root = if ($OutDir) { $OutDir } elseif ($Case -eq 'all') { 'out-cases' } else { "out-case-$Case" }
if ($Case -eq 'all') { New-Folder $root }
$good = 0
foreach ($n in $names) {
    $dir = if ($Case -eq 'all') { Join-Path $root $n } else { $root }
    $ok = Invoke-Case $n $dir
    if ($ok) { $good++ }
    Say ('case {0}: {1}' -f $n, $(if ($ok) { 'as expected' } else { 'NOT as expected' }))
}
if ($Case -eq 'all') { Say ('cases {0} | as expected {1} | not as expected {2}' -f $names.Count, $good, ($names.Count - $good)) }
exit $(if ($good -eq $names.Count) { 0 } else { 1 })
