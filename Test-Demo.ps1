#requires -Version 7.4
<#
.SYNOPSIS
    The tests of the demo. With no argument they run in a new temporary folder, which is removed when every check
    passed and kept (and named) when one failed. With -OutDir they run in that folder, which must not exist yet, and
    keep it. The edge-case tables and answer texts are built there; the shipped files are never changed. The model API
    and Microsoft Graph are tested against mock servers on this computer only; nothing leaves it.

    Every child step runs under this run's culture (lib/Invoke-Step.ps1), so a run started under de-DE tests every
    script under de-DE:  pwsh -NoProfile -Command "[cultureinfo]::CurrentCulture = 'de-DE'; ./Test-Demo.ps1"
.EXAMPLE
    pwsh -NoProfile -File Test-Demo.ps1
#>
param([string] $OutDir = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/LocalMock.ps1"

$keep = [bool]$OutDir
if (-not $OutDir) { $OutDir = Join-Path ([IO.Path]::GetTempPath()) ('m365-hygiene-tests-' + [guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $OutDir) { throw "OutDir must not exist: $OutDir" }
New-Item -ItemType Directory -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$here = $PSScriptRoot
$culture = [cultureinfo]::CurrentCulture.Name
$wrapper = Join-Path $here 'lib/Invoke-Step.ps1'
$users = Join-Path $here 'tests/thirteen/users.synthetic.csv'      # the original thirteen accounts, for the original tests
$skus = Join-Path $here 'tests/thirteen/skus.synthetic.csv'
$policiesClean = Join-Path $here 'tests/thirteen/policies.synthetic.csv'
$dataUsers = Join-Path $here 'data/users.synthetic.csv'             # the invented tenant the demo ships
$dataSkus = Join-Path $here 'data/skus.synthetic.csv'
$dataPolicies = Join-Path $here 'data/policies.synthetic.csv'
$step1 = Join-Path $here 'Get-TenantHygieneFindings.ps1'
$step2 = Join-Path $here 'New-ManagerBrief.ps1'
$decide = Join-Path $here 'Set-BriefDecision.ps1'
$worklistScript = Join-Path $here 'New-AdminWorklist.ps1'
$reportScript = Join-Path $here 'New-HygieneReport.ps1'
$collector = Join-Path $here 'Export-TenantSnapshot.ps1'
$generator = Join-Path $here 'New-SyntheticTenant.ps1'
$adder = Join-Path $here 'Add-RecordedBrief.ps1'
$demo = Join-Path $here 'Invoke-Demo.ps1'
$earlier = Join-Path $here 'recordings/earlier'
$mockLabel = 'Mock: written from Microsoft''s documentation, tested against a local mock, never run against a tenant'
$script:pass = 0; $script:fail = 0
$script:printed = New-Object System.Collections.Generic.List[string]
function Check([string] $Name, [bool] $Ok) {
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" } else { $script:fail++; Write-Output "FAIL $Name" }
}
# A child pwsh running one script under this run's culture; its first argument is the script.
function Run-Pwsh([string[]] $ArgList) {
    $a = @('-NoProfile', '-NonInteractive', '-File', $wrapper)
    if ($culture) { $a += @('-WrapCulture', $culture) }
    $a += @('-WrapScript') + $ArgList
    $out = & pwsh @a 2>&1
    $text = $out | Out-String
    $script:printed.Add($text)
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}
function Read-Json([string] $Path) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
function Get-Counts($Summary) { $c = @{}; foreach ($x in $Summary.rules) { $c[$x.id] = $x.count }; $c }
function Get-Text([string] $Path) { if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' } }

# A users table for one test, written into OutDir. A row written in the original ten columns gets an empty AdminRoles.
$head = 'UserPrincipalName,DisplayName,Department,UserType,AccountEnabled,IsAdmin,MfaRegistered,CreatedDate,LastSignInDate,AssignedLicenses,AdminRoles'
function New-Table([string] $Name, [string[]] $Rows) {
    $p = Join-Path $OutDir $Name
    $fixed = foreach ($r in $Rows) { if (($r -split ',').Count -eq 10) { $r + ',' } else { $r } }
    Set-Content -LiteralPath $p -Encoding utf8 -Value (@($head) + @($fixed))
    $p
}
$policyHead = 'PolicyId,DisplayName,State,CreatedDate,ClientAppTypes,IncludeUsers,IncludeApplications,GrantControls,OtherConditions'
function New-Policies([string] $Name, [string[]] $Rows) {
    $p = Join-Path $OutDir $Name
    Set-Content -LiteralPath $p -Encoding utf8 -Value (@($policyHead) + @($Rows))
    $p
}
function Invoke-Step1([string] $Name, [string] $Table, [string] $Skus = $skus, [string] $Policies = $policiesClean, [string[]] $More = @()) {
    $o = Join-Path $OutDir $Name
    $r = Run-Pwsh (@($step1, '-UsersCsv', $Table, '-SkusCsv', $Skus, '-PoliciesCsv', $Policies, '-AsOf', '2026-11-21', '-OutDir', $o) + $More)
    $sum = if (Test-Path -LiteralPath (Join-Path $o 'findings-summary.json')) { Read-Json (Join-Path $o 'findings-summary.json') } else { $null }
    $rows = if (Test-Path -LiteralPath (Join-Path $o 'findings-admin.csv')) { @(Import-Csv -LiteralPath (Join-Path $o 'findings-admin.csv') -Encoding utf8) } else { @() }
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Dir = $o; Summary = $sum; Rows = $rows }
}
function Get-Flagged($Run, [string] $Rule) { @($Run.Rows | Where-Object Rule -eq $Rule | ForEach-Object { ($_.Upn -split '@')[0] }) }
# Step 2 on a model answer written into OutDir (the Recorded backend).
function Invoke-Step2([string] $Name, [string] $Answer, [string] $Summary = $sj, [string] $Table = $users, [string[]] $More = @()) {
    $a = Join-Path $OutDir "$Name.md"
    Set-Content -LiteralPath $a -Encoding utf8 -NoNewline -Value $Answer
    $o = Join-Path $OutDir $Name
    $r = Run-Pwsh (@($step2, '-SummaryJson', $Summary, '-UsersCsv', $Table, '-OutDir', $o, '-Recorded', $a) + $More)
    $rep = if (Test-Path -LiteralPath (Join-Path $o 'brief-report.json')) { Read-Json (Join-Path $o 'brief-report.json') } else { $null }
    $brief = if (Test-Path -LiteralPath (Join-Path $o 'brief.md')) { Get-Content -LiteralPath (Join-Path $o 'brief.md') -Raw -Encoding utf8 } else { '' }
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Dir = $o; Report = $rep; Brief = $brief
        Problems = $(if ($rep) { @($rep.problems) -join ' | ' } else { '' }) }
}
# True when step 2 ran, refused the text for the given problem, and used the template.
function Test-Rejected($Run, [string] $Problem) {
    $Run.Code -eq 0 -and $null -ne $Run.Report -and $Run.Report.ai_text_accepted -eq $false -and
        $Run.Problems.Contains($Problem) -and $Run.Brief.Contains('Your decisions:')
}

# --- step 1 on the original thirteen accounts --------------------------------------------------------------------------
$f = Join-Path $OutDir 'findings'
$r = Run-Pwsh @($step1, '-UsersCsv', $users, '-SkusCsv', $skus, '-PoliciesCsv', $policiesClean, '-AsOf', '2026-11-21', '-OutDir', $f)
Check 'findings run exits 0' ($r.Code -eq 0)
$sum = Read-Json (Join-Path $f 'findings-summary.json')
$count = Get-Counts $sum
Check 'R1 stale licensed = 2' ($count['R1'] -eq 2)
Check 'R2 disabled licensed = 1' ($count['R2'] -eq 1)
Check 'R3 admins without MFA = 2' ($count['R3'] -eq 2)
Check 'R4 stale or never-used guests = 2' ($count['R4'] -eq 2)
Check 'R5 never signed in, older than 30 days = 1' ($count['R5'] -eq 1)
Check 'reclaimable synthetic cost = 390 (R1 230 + R2 100 + R5 60)' ($sum.reclaimable_monthly_cost_synthetic -eq 390)
$costRules = 0.0; foreach ($x in $sum.rules) { if ($x.id -in 'R1', 'R2', 'R5') { $costRules += $x.monthly_cost_synthetic } }
Check 'the three cost rules (R1, R2, R5) add up to the reclaimable total' ($costRules -eq $sum.reclaimable_monthly_cost_synthetic)
$admin = Import-Csv -LiteralPath (Join-Path $f 'findings-admin.csv') -Encoding utf8
Check 'shipped boundary: exactly 90 days since sign-in is not stale' (-not ($admin.Upn -contains 'lior.samekh@demo.example.com'))
Check 'an account 6 days old with no sign-in is not flagged' (-not ($admin.Upn -contains 'tal.kaf@demo.example.com'))
$sumText = Get-Content -LiteralPath (Join-Path $f 'findings-summary.json') -Raw -Encoding utf8
$names = foreach ($u in Import-Csv -LiteralPath $users -Encoding utf8) { $u.UserPrincipalName; ($u.DisplayName -replace '\(.*\)', '').Trim() }
Check 'the summary for the AI carries no name or address' (@($names | Where-Object { $sumText.Contains($_) }).Count -eq 0 -and -not $sumText.Contains('@'))
$key = Get-Content -LiteralPath (Join-Path $f 'key.local.json') -Raw | ConvertFrom-Json
Check 'the local key maps 8 stand-ins' (@($key.PSObject.Properties).Count -eq 8)
$r2 = Run-Pwsh @($step1, '-UsersCsv', $users, '-SkusCsv', $skus, '-PoliciesCsv', $policiesClean, '-AsOf', '2026-11-21', '-OutDir', $f)
Check 'an existing folder is never overwritten' ($r2.Code -ne 0)
Check 'R6, R7 and R8 find nothing in the thirteen accounts (two global administrators, legacy authentication blocked)' ($count['R6'] -eq 0 -and
    $count['R7'] -eq 0 -and $count['R8'] -eq 0)
Check 'the summary asks the decisions of the rules that found something, and only those: D1 (R3), D5 (R4), D6 (R1, R2, R5)' (
    (@($sum.decisions | ForEach-Object { $_.id }) -join ',') -eq 'D1,D5,D6')
Check 'the local key maps each stand-in to its sign-in address' ($key.'user-001' -eq 'ronit.gimel@demo.example.com')

# --- step 1 on edge-case tables, as of 2026-11-21 --------------------------------------------------------------------
$edge = Invoke-Step1 'edge' (New-Table 'edge.csv' @(
    's90@demo.example.com,Edge A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-23,M365_BUSINESS_STANDARD'
    's91@demo.example.com,Edge B (synthetic),Sales,Member,TRUE,false,TRUE,2024-01-10,2026-08-22,M365_BUSINESS_STANDARD'
    'n30@demo.example.com,Edge C (synthetic),Sales,Member,true,False,False,2026-10-22,,M365_BUSINESS_STANDARD'
    'n31@demo.example.com,Edge D (synthetic),Sales,Member,True,FALSE,False,2026-10-21,,M365_BUSINESS_STANDARD'
    'g1@demo.example.com,Guest E (synthetic guest),,Guest,True,False,False,2026-11-20,,'
    'g30@demo.example.com,Guest F (synthetic guest),,Guest,True,False,False,2026-10-22,,'
    'g31@demo.example.com,Guest G (synthetic guest),,Guest,True,False,False,2026-10-21,,'
    'z1@demo.example.com,Edge H (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-22T23:59:59Z,M365_BUSINESS_STANDARD'
    'z2@demo.example.com,Edge I (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-23T00:00:01Z,M365_BUSINESS_STANDARD'
    'o1@demo.example.com,Edge J (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-23T01:30:00+02:00,M365_BUSINESS_STANDARD'
    'a1@demo.example.com,Edge K (synthetic),IT,Member,tRuE,tRUE,fAlSe,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
$r1 = Get-Flagged $edge 'R1'; $r4 = Get-Flagged $edge 'R4'; $r5 = Get-Flagged $edge 'R5'
Check 'edge table: exits 0, and true and false are read in any letter case' ($edge.Code -eq 0 -and (Get-Flagged $edge 'R3') -contains 'a1')
Check 'boundary: 90 days since sign-in is not stale, 91 days is (R1)' ($r1 -notcontains 's90' -and $r1 -contains 's91')
Check 'boundary: a member created 30 days ago who never signed in is not flagged, 31 days ago is (R5)' ($r5 -notcontains 'n30' -and $r5 -contains 'n31')
Check 'R4: a guest invited yesterday or 30 days ago who never signed in is not flagged, 31 days ago is' ($r4 -notcontains 'g1' -and $r4 -notcontains 'g30' -and $r4 -contains 'g31')
Check 'a timestamp counts by its UTC date: 23:59:59Z is 91 days, 00:00:01Z the next day is 90, 01:30+02:00 is 91' ($r1 -contains 'z1' -and $r1 -notcontains 'z2' -and $r1 -contains 'o1')

$clean = Invoke-Step1 'clean' (New-Table 'clean.csv' @(
    'clean@demo.example.com,Clean A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
$c = if ($clean.Summary) { Get-Counts $clean.Summary } else { @{} }
Check 'a clean one-user tenant: exit 0, all eight counts 0, reclaimable 0, no decision asked' ($clean.Code -eq 0 -and $c.Count -eq 8 -and
    @($c.Values | Where-Object { $_ -ne 0 }).Count -eq 0 -and $clean.Summary.reclaimable_monthly_cost_synthetic -eq 0 -and @($clean.Summary.decisions).Count -eq 0)

$noR2 = Invoke-Step1 'no-r2' (New-Table 'no-r2.csv' @(Get-Content -LiteralPath $users -Encoding utf8 | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^maya\.he@' }))
$c = if ($noR2.Summary) { Get-Counts $noR2.Summary } else { @{} }
Check 'the shipped data without its R2 row: exit 0, R2 0, reclaimable 290' ($noR2.Code -eq 0 -and $c['R2'] -eq 0 -and $c['R1'] -eq 2 -and
    $noR2.Summary.reclaimable_monthly_cost_synthetic -eq 290)

$bad = Invoke-Step1 'day-first' (New-Table 'day-first.csv' @(
    'clean@demo.example.com,Clean A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'
    'dayfirst@demo.example.com,Day First (synthetic),Sales,Member,True,False,True,2024-01-10,21/08/2026,M365_BUSINESS_STANDARD'))
Check 'a day-first date is refused with its row number (exit 2), no name printed, nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'row 2:' -and
    $bad.Text -notmatch '(?i)dayfirst|day first' -and -not (Test-Path -LiteralPath $bad.Dir))
$bad = Invoke-Step1 'blank-enabled' (New-Table 'blank-enabled.csv' @(
    'blank@demo.example.com,Blank A (synthetic),Sales,Member,,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
Check 'a blank AccountEnabled is refused with its row number (exit 2), nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'row 1: AccountEnabled' -and
    -not (Test-Path -LiteralPath $bad.Dir))
$bad = Invoke-Step1 'typo-admin' (New-Table 'typo-admin.csv' @(
    'typo@demo.example.com,Typo A (synthetic),IT,Member,True,Ture,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
Check 'a mistyped IsAdmin is refused with its row number (exit 2), nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'row 1: IsAdmin' -and
    -not (Test-Path -LiteralPath $bad.Dir))

# The same step under a culture with a decimal comma, on a licence with a fractional cost.
$wrap = Join-Path $OutDir 'run-de-DE.ps1'
Set-Content -LiteralPath $wrap -Encoding utf8 -Value @(
    'param($Script, $UsersCsv, $SkusCsv, $PoliciesCsv, $OutDir)'
    '[cultureinfo]::CurrentCulture = [cultureinfo]::new(''de-DE'')'
    '''culture check '' + (1.5).ToString()'
    '& $Script -UsersCsv $UsersCsv -SkusCsv $SkusCsv -PoliciesCsv $PoliciesCsv -AsOf ''2026-11-21'' -OutDir $OutDir'
    'exit $LASTEXITCODE')
$fracSkus = Join-Path $OutDir 'skus-fraction.csv'
Set-Content -LiteralPath $fracSkus -Encoding utf8 -Value @('SkuPartNumber,MonthlyCostSynthetic', 'HALF_PLAN,12.5')
$fracUsers = New-Table 'fraction.csv' @('frac@demo.example.com,Frac A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-01-10,HALF_PLAN')
$de = Join-Path $OutDir 'de-DE'
$r = Run-Pwsh @($wrap, '-Script', $step1, '-UsersCsv', $fracUsers, '-SkusCsv', $fracSkus, '-PoliciesCsv', $policiesClean, '-OutDir', $de)
$deCsv = if (Test-Path -LiteralPath (Join-Path $de 'findings-admin.csv')) { Get-Content -LiteralPath (Join-Path $de 'findings-admin.csv') -Raw } else { '' }
Check 'under de-DE (decimal comma, checked in effect) the files carry 12.5, not 12,5' ($r.Code -eq 0 -and $r.Text.Contains('culture check 1,5') -and
    $deCsv.Contains('"12.5"') -and -not $deCsv.Contains('12,5') -and (Read-Json (Join-Path $de 'findings-summary.json')).reclaimable_monthly_cost_synthetic -eq 12.5)

# --- step 1: the three tenant rules, the role column, the policies table, exact costs ----------------------------------
function New-Admins([int] $Global, [string] $Name) {
    $rows = for ($i = 1; $i -le $Global; $i++) {
        $enabled = if ($i -eq 1) { 'False' } else { 'True' }
        "ga$i@demo.example.com,Global $i (synthetic),IT,Member,$enabled,True,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD,Global Administrator"
    }
    New-Table $Name (@($rows) + @('ua@demo.example.com,User Admin (synthetic),IT,Member,True,True,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD,User Administrator'))
}
$g4 = Invoke-Step1 'ga-4' (New-Admins 4 'ga-4.csv')
$g5 = Invoke-Step1 'ga-5' (New-Admins 5 'ga-5.csv')
Check 'boundary: 4 accounts holding Global Administrator (one of them disabled) do not fire R6, 5 do (limit 4)' ($g4.Code -eq 0 -and $g5.Code -eq 0 -and
    (Get-Counts $g4.Summary)['R6'] -eq 0 -and (Get-Counts $g5.Summary)['R6'] -eq 1)
$r6 = @($g5.Summary.rules | Where-Object id -eq 'R6')[0]
Check 'R6 is one finding about the tenant, with no person in the summary; the administrator''s file names the five holders' ($r6.scope -eq 'tenant' -and
    $r6.items[0].ref -eq 'tenant' -and $r6.items[0].global_administrators -eq 5 -and @($g5.Rows | Where-Object Rule -eq 'R6').Count -eq 5 -and
    -not (Get-Text (Join-Path $g5.Dir 'findings-summary.json')).Contains('@'))
$g5b = Invoke-Step1 'ga-5-limit-5' (New-Admins 5 'ga-5b.csv') -More @('-GlobalAdminMax', '5')
Check 'the limit is a parameter: with -GlobalAdminMax 5, five holders do not fire R6' ($g5b.Code -eq 0 -and (Get-Counts $g5b.Summary)['R6'] -eq 0)
$bad = Invoke-Step1 'roles-without-admin' (New-Table 'roles-without-admin.csv' @(
    'x@demo.example.com,X A (synthetic),IT,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD,Global Administrator'))
Check 'a role named for an account whose IsAdmin is false is refused with its row number (exit 2), nothing written' ($bad.Code -eq 2 -and
    $bad.Text -match 'row 1: AdminRoles' -and -not (Test-Path -LiteralPath $bad.Dir))
$noRoles = Join-Path $OutDir 'no-roles-column.csv'
Set-Content -LiteralPath $noRoles -Encoding utf8 -Value @(($head -replace ',AdminRoles$', ''), 'x@demo.example.com,X A (synthetic),IT,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD')
$bad = Invoke-Step1 'no-roles-column' $noRoles
Check 'a users table without the AdminRoles column is refused (exit 2), nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'no column AdminRoles' -and
    -not (Test-Path -LiteralPath $bad.Dir))

$oneUser = New-Table 'one-user.csv' @('one@demo.example.com,One A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD')
$legacy = '00000000-0000-4000-8000-0000000000b1,Block legacy (synthetic),{0},2025-01-15T08:00:00Z,{1},{2},{3},{4},{5}'
function Get-R7([string] $Name, [string] $State = 'enabled', [string] $Apps = 'exchangeActiveSync;other', [string] $Users = 'All', [string] $Resources = 'All',
    [string] $Grant = 'block', [string] $Other = '') {
    $run = Invoke-Step1 $Name $oneUser -Policies (New-Policies "$Name.csv" @(($legacy -f $State, $Apps, $Users, $Resources, $Grant, $Other)))
    if ($run.Code -eq 0) { (Get-Counts $run.Summary)['R7'] } else { -1 }
}
Check 'R7: an enabled policy for all users and all resources that blocks Exchange ActiveSync and other clients blocks legacy authentication (R7 0)' ((Get-R7 'r7-ok') -eq 0)
Check 'R7: the same policy in report-only mode, or disabled, does not (R7 1)' ((Get-R7 'r7-report' -State 'enabledForReportingButNotEnforced') -eq 1 -and
    (Get-R7 'r7-disabled' -State 'disabled') -eq 1)
Check 'R7: blocking only "other" clients, or "all" client types, does not count (R7 1)' ((Get-R7 'r7-other' -Apps 'other') -eq 1 -and (Get-R7 'r7-all' -Apps 'all') -eq 1)
Check 'R7: a policy for one group, or for Office365 only, does not count (R7 1)' ((Get-R7 'r7-group' -Users '') -eq 1 -and (Get-R7 'r7-o365' -Resources 'Office365') -eq 1)
Check 'R7: a policy that asks for MFA instead of blocking, or sets another condition (userRiskLevels), does not count (R7 1)' ((Get-R7 'r7-mfa' -Grant 'mfa') -eq 1 -and
    (Get-R7 'r7-risk' -Other 'userRiskLevels') -eq 1)
$empty = Invoke-Step1 'r7-no-policies' $oneUser -Policies (New-Policies 'no-policies.csv' @())
Check 'R7: a tenant with no policy at all fires R7, and the summary says how many policies were checked (0)' ($empty.Code -eq 0 -and (Get-Counts $empty.Summary)['R7'] -eq 1 -and
    $empty.Summary.policies_checked -eq 0)
$ro = '00000000-0000-4000-8000-0000000000c{0},Report-only {0} (synthetic),{1},{2},all,All,All,mfa,'
$r8 = Invoke-Step1 'r8' $oneUser -Policies (New-Policies 'r8.csv' @(($ro -f 1, 'enabledForReportingButNotEnforced', '2026-10-22'),
    ($ro -f 2, 'enabledForReportingButNotEnforced', '2026-10-21'), ($ro -f 3, 'enabledForReportingButNotEnforced', '2026-10-22T01:00:00+02:00'),
    ($ro -f 4, 'enabledForReportingButNotEnforced', '2026-10-22T01:00:00Z'), ($ro -f 5, 'enabled', '2025-01-01'), ($ro -f 6, 'disabled', '2025-01-01'),
    ($legacy -f 'enabled', 'exchangeActiveSync;other', 'All', 'All', 'block', '')))
$flagged8 = @($r8.Rows | Where-Object Rule -eq 'R8' | ForEach-Object { $_.Name })
Check 'boundary: a report-only policy created 30 days ago does not fire R8, 31 days ago does; a timestamp counts by its UTC date' ($r8.Code -eq 0 -and
    $flagged8 -contains 'Report-only 2 (synthetic)' -and $flagged8 -contains 'Report-only 3 (synthetic)' -and $flagged8 -notcontains 'Report-only 1 (synthetic)' -and
    $flagged8 -notcontains 'Report-only 4 (synthetic)' -and $flagged8.Count -eq 2)
Check 'R8: enabled and disabled policies are never flagged; each flagged policy is a stand-in (policy-001 ...) with no name in the summary' (
    $flagged8 -notcontains 'Report-only 5 (synthetic)' -and $flagged8 -notcontains 'Report-only 6 (synthetic)' -and
    (@($r8.Summary.rules | Where-Object id -eq 'R8')[0].items.ref -join ',') -eq 'policy-001,policy-002' -and -not (Get-Text (Join-Path $r8.Dir 'findings-summary.json')).Contains('Report-only'))
$r8u = Invoke-Step1 'r8-unknown' $oneUser -Policies (New-Policies 'r8-unknown.csv' @(($ro -f 1, 'enabledForReportingButNotEnforced', ''),
    ($ro -f 2, 'enabled', ''), ($legacy -f 'enabled', 'exchangeActiveSync;other', 'All', 'All', 'block', '')))
$r8i = if ($r8u.Summary) { @($r8u.Summary.rules | Where-Object id -eq 'R8')[0] } else { $null }
Check 'R8: a report-only policy with no creation date is reported as "creation date unknown", with no age; an enabled one with no date is not flagged' (
    $r8u.Code -eq 0 -and $r8i.count -eq 1 -and $null -eq $r8i.items[0].days_since_created -and $r8i.items[0].creation_date -eq 'unknown' -and
    $r8i.title -like '*, or with no creation date' -and @($r8u.Rows | Where-Object Rule -eq 'R8')[0].Detail -like '*report-only, creation date unknown')
$bad = Invoke-Step1 'bad-state' $oneUser -Policies (New-Policies 'bad-state.csv' @(($ro -f 1, 'on', '2026-10-22')))
Check 'a policy state other than enabled, disabled or enabledForReportingButNotEnforced is refused with its row (exit 2)' ($bad.Code -eq 2 -and
    $bad.Text -match 'policies row 1: State' -and -not (Test-Path -LiteralPath $bad.Dir))
$bad = Invoke-Step1 'bad-policy-date' $oneUser -Policies (New-Policies 'bad-policy-date.csv' @(($ro -f 1, 'disabled', '22.10.2026')))
Check 'a policy date that is not ISO 8601 is refused with its row (exit 2), nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'policies row 1: CreatedDate' -and
    -not (Test-Path -LiteralPath $bad.Dir))
foreach ($v in @('1,5', '-3', '12.5.1', '')) {
    $s = Join-Path $OutDir ('skus-bad-{0}.csv' -f [array]::IndexOf(@('1,5', '-3', '12.5.1', ''), $v))
    Set-Content -LiteralPath $s -Encoding utf8 -Value @('SkuPartNumber,MonthlyCostSynthetic', "M365_BUSINESS_STANDARD,""$v""")
    $bad = Invoke-Step1 ('cost-' + (Split-Path $s -LeafBase)) $oneUser -Skus $s
    Check "a cost written ""$v"" is refused with its row in the licence table (exit 2)" ($bad.Code -eq 2 -and $bad.Text -match 'licence table row 1' -and
        -not (Test-Path -LiteralPath $bad.Dir))
}
$dupSkus = Join-Path $OutDir 'skus-dup.csv'
Set-Content -LiteralPath $dupSkus -Encoding utf8 -Value @('SkuPartNumber,MonthlyCostSynthetic', 'M365_BUSINESS_STANDARD,60', 'M365_BUSINESS_STANDARD,61')
$bad = Invoke-Step1 'cost-dup' $oneUser -Skus $dupSkus
Check 'a licence listed twice in the licence table is refused (exit 2)' ($bad.Code -eq 2 -and $bad.Text -match 'listed twice')
$tenths = Join-Path $OutDir 'skus-tenths.csv'
Set-Content -LiteralPath $tenths -Encoding utf8 -Value @('SkuPartNumber,MonthlyCostSynthetic', 'TENTH_A,0.1', 'TENTH_B,0.2')
$exact = Invoke-Step1 'exact' (New-Table 'exact.csv' @('t1@demo.example.com,Tenth A (synthetic),Sales,Member,False,False,True,2024-01-10,2026-01-10,TENTH_A;TENTH_B')) -Skus $tenths
Check 'costs are exact decimals: 0.1 + 0.2 is written 0.3 in every file (floating point would give 0.30000000000000004)' ($exact.Code -eq 0 -and
    $exact.Summary.reclaimable_monthly_cost_synthetic -eq '0.3' -and $exact.Rows[0].MonthlyCost -eq '0.3' -and $exact.Text.Contains('reclaimable (invented units) 0.3 '))

$formula = Invoke-Step1 'formula' (New-Table 'formula.csv' @(
    'f1@demo.example.com,=HYPERLINK("x") (synthetic),+Sales,Member,False,False,True,2024-01-10,2026-01-10,M365_BUSINESS_STANDARD'))
$formulaCsv = Get-Text (Join-Path $formula.Dir 'findings-admin.csv')
Check 'a table cell that starts like a formula (=, +) is written to the administrator''s CSV with a leading apostrophe' ($formula.Code -eq 0 -and
    $formulaCsv.Contains('"''=HYPERLINK(""x"") (synthetic)"') -and $formulaCsv.Contains('"''+Sales"'))

# --- step 1 on the invented tenant the demo ships ------------------------------------------------------------------------
$df = Invoke-Step1 'data-findings' $dataUsers -Skus $dataSkus -Policies $dataPolicies
$dc = if ($df.Summary) { Get-Counts $df.Summary } else { @{} }
Check 'the shipped tenant: every one of the eight rules finds something' ($df.Code -eq 0 -and $dc.Count -eq 8 -and @($dc.Values | Where-Object { $_ -lt 1 }).Count -eq 0)
$exactSum = [decimal]0
foreach ($x in $df.Summary.rules) { if ($x.id -in 'R1', 'R2', 'R5') { foreach ($i in $x.items) { $exactSum += [decimal]::Parse($i.monthly_cost_synthetic, [cultureinfo]::InvariantCulture) } } }
Check 'the shipped tenant: the item costs add up exactly to the reclaimable total, as decimals' ($exactSum -eq [decimal]::Parse($df.Summary.reclaimable_monthly_cost_synthetic, [cultureinfo]::InvariantCulture))
$dUsers = @(Import-Csv -LiteralPath $dataUsers -Encoding utf8)
Check 'the shipped tenant: about sixty accounts, every one at demo.example.com and marked (synthetic)' ($dUsers.Count -ge 55 -and $dUsers.Count -le 65 -and
    @($dUsers | Where-Object { $_.UserPrincipalName -notlike '*@demo.example.com' -or $_.DisplayName -notmatch '\(synthetic( guest)?\)$' }).Count -eq 0)
$byUpn = @{}; foreach ($u in $dUsers) { $byUpn[$u.UserPrincipalName] = $u }
$dRows = $df.Rows
$signed90 = @($dUsers | Where-Object { $_.LastSignInDate -in '2026-08-23', '2026-08-23T00:00:01Z' -and $_.UserType -eq 'Member' -and $_.AssignedLicenses })
Check 'the shipped tenant holds the R1 boundary: licensed members who signed in exactly 90 days before are not flagged, at 91 days they are' ($signed90.Count -ge 1 -and
    @($signed90 | Where-Object { $_.UserPrincipalName -in @($dRows | Where-Object Rule -eq 'R1').Upn }).Count -eq 0 -and
    @($dRows | Where-Object { $_.Rule -eq 'R1' -and $_.DaysSinceSignIn -eq '91' }).Count -ge 2)
Check 'the shipped tenant holds the R5 and R4 boundaries: created 30 days before and never signed in is not flagged, 31 days is' (
    @($dUsers | Where-Object { $_.CreatedDate -eq '2026-10-22' -and -not $_.LastSignInDate }).Count -ge 2 -and
    @($dRows | Where-Object { $_.Rule -in 'R4', 'R5' -and $_.AccountAgeDays -eq '30' }).Count -eq 0 -and
    @($dRows | Where-Object { $_.Rule -eq 'R5' -and $_.AccountAgeDays -eq '31' }).Count -eq 1 -and @($dRows | Where-Object { $_.Rule -eq 'R4' -and $_.AccountAgeDays -eq '31' }).Count -eq 1)
Check 'the shipped tenant holds the R8 boundary (report-only policies created 30 and 31 days before) and five global administrators' (
    @($dRows | Where-Object { $_.Rule -eq 'R8' -and $_.Detail -match ', 31 days ago$' }).Count -eq 1 -and @($dRows | Where-Object { $_.Rule -eq 'R8' -and $_.Detail -match ', 30 days ago$' }).Count -eq 0 -and
    @($dRows | Where-Object Rule -eq 'R6').Count -eq 5)

# --- the synthetic tenant generator ---------------------------------------------------------------------------------
$source = (Get-Text (Join-Path $here 'data/tenant-source.txt')).Trim()
$m = [regex]::Match($source, '-Seed ([0-9]+) -AsOf ([0-9-]+) -Accounts ([0-9]+)$')
$gen = Join-Path $OutDir 'generated'
$r = Run-Pwsh @($generator, '-Seed', $m.Groups[1].Value, '-AsOf', $m.Groups[2].Value, '-Accounts', $m.Groups[3].Value, '-OutDir', $gen)
$same = $m.Success -and $r.Code -eq 0 -and @('users.synthetic.csv', 'skus.synthetic.csv', 'policies.synthetic.csv', 'tenant-source.txt' | Where-Object {
    (Get-FileSha256 (Join-Path $gen $_)) -ne (Get-FileSha256 (Join-Path $here "data/$_")) }).Count -eq 0
Check 'the shipped tables are byte for byte what New-SyntheticTenant.ps1 writes for the committed seed (data/tenant-source.txt)' $same
$gen2 = Join-Path $OutDir 'generated-other-seed'
$r = Run-Pwsh @($generator, '-Seed', '7', '-AsOf', $m.Groups[2].Value, '-OutDir', $gen2)
Check 'another seed gives another users table' ($r.Code -eq 0 -and (Get-FileSha256 (Join-Path $gen2 'users.synthetic.csv')) -ne (Get-FileSha256 $dataUsers))
# Read by the PowerShell parser, so that a comment cannot pass for code, nor code hide in a comment.
function Get-Ast([string] $Path) { [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null) }
function Get-Commands([string] $Path) { @((Get-Ast $Path).FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) }
$genAst = Get-Ast $generator
$genTypes = @($genAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] }, $true) | ForEach-Object { $_.TypeName.FullName })
$genStrings = @($genAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
Check 'the generator draws from its own generator: no Get-Random command and no System.Random type in its code' (@(Get-Commands $generator | Where-Object { $_.GetCommandName() -eq 'Get-Random' }).Count -eq 0 -and
    @($genTypes + $genStrings | Where-Object { $_ -in 'random', 'System.Random' }).Count -eq 0)
$r = Run-Pwsh @($generator, '-Seed', '1', '-AsOf', '2026-11-21', '-OutDir', $gen)
Check 'the generator never writes into an existing folder (exit 2)' ($r.Code -eq 2)

# --- step 2: the brief ---------------------------------------------------------------------------------------------
# The two earlier real answers, checked against the request they answered: the earlier prompt and the earlier
# summary of the thirteen accounts, as the first version of the scripts wrote them.
$earlierSummary = Join-Path $earlier 'findings-summary.json'
$earlierPrompt = Join-Path $earlier 'prompt-brief.txt'
$recordedText = Get-Content -LiteralPath (Join-Path $earlier 'recorded-brief.md') -Raw -Encoding utf8
$b1 = Join-Path $OutDir 'brief-recorded'
$r = Run-Pwsh @($step2, '-SummaryJson', $earlierSummary, '-UsersCsv', $users, '-OutDir', $b1, '-Prompt', $earlierPrompt, '-Recorded', (Join-Path $earlier 'recorded-brief.md'))
$rep = Read-Json (Join-Path $b1 'brief-report.json')
Check 'the recorded model brief passes the checks (the earlier answer, against the request it answered)' ($r.Code -eq 0 -and $rep.ai_text_accepted -eq $true)
Check 'the brief used is the model text, unchanged' ((Get-Content -LiteralPath (Join-Path $b1 'brief.md') -Raw -Encoding utf8) -ceq ($recordedText.Trim() + "`n"))
$meta = Read-Json (Join-Path $earlier 'original-meta.json')
Check 'the request built today has the sha256 the recorded answers were recorded against' ($rep.request_sha256 -eq $meta.request_sha256)
Check 'the report: no personal value in the request, summary not sent to the API (Recorded)' ($rep.personal_values_in_request -eq 0 -and $rep.summary_sent_to_api -eq $false)
Check 'the earlier answer earns the label Recorded: both hashes in its meta file match; the report says how it was obtained' ($rep.origin -eq 'recorded' -and
    $rep.origin_label -eq 'Recorded: claude-haiku-5-5, on 2026-11-23' -and $rep.obtained -eq 'a Claude Code subagent on that model, given the request text as its whole prompt')

$sj = Join-Path $f 'findings-summary.json'
$x = Invoke-Step2 'bad-figure' 'Found 2 administrators without MFA. You can save 500 units a month.'
Check 'an invented figure is caught (500)' (Test-Rejected $x 'figures not in the summary: 500')
Check 'the fallback is used, with the script''s own figures' (-not $x.Brief.Contains('500') -and $x.Brief.Contains('390') -and $x.Brief.Contains('2026-11-21'))
Check 'the fallback leaves no placeholder unfilled' (-not ($x.Brief -match '\{[a-z_0-9A-Z]+\}'))
Check 'the fallback asks the summary''s own decisions, D1, D5 and D6, each once' ((@([regex]::Matches($x.Brief, '\bD[0-9]+\b') | ForEach-Object Value) -join ',') -eq 'D1,D5,D6')
Check 'a number at the start of a line is caught (500)' (Test-Rejected (Invoke-Step2 'line-start' "The cost each month is`n500. Do you approve?") 'figures not in the summary: 500')
Check '"390 000" is caught (digit groups separated by a space)' (Test-Rejected (Invoke-Step2 'space-group' 'You can save 390 000 units a month.') 'digit groups separated by a space')
Check '"2 000" with a non-breaking space is caught' (Test-Rejected (Invoke-Step2 'nbsp-group' ('There are 2' + [char]0xA0 + '000 accounts.')) 'digit groups separated by a space')
$x = Invoke-Step2 'unknown-refs' 'Remove user-999 and user-500, both found under R9.'
Check 'invented stand-ins and rule ids are caught (user-999, user-500, R9)' ((Test-Rejected $x 'an unknown stand-in') -and $x.Problems.Contains('an unknown rule id'))
Check '"R9 000 a month" is caught (unknown rule id)' (Test-Rejected (Invoke-Step2 'r9' 'You can save R9 000 a month.') 'an unknown rule id')
$arabicIndic500 = [string][char]0x0665 + [char]0x0660 + [char]0x0660   # built from code points: the files stay ASCII
Check 'a digit other than 0 to 9 is caught' (Test-Rejected (Invoke-Step2 'other-digit' "You can save $arabicIndic500 units.") 'a digit other than 0 to 9')
Check 'a figure too long for a decimal is caught, and does not stop the check' (Test-Rejected (Invoke-Step2 'long-figure' ('Save ' + ('9' * 40) + ' units.')) 'figures not in the summary: 9999')
Check 'an invented policy stand-in is caught (policy-999)' (Test-Rejected (Invoke-Step2 'unknown-policy' 'Switch on policy-999.') 'an unknown stand-in')

Check 'a name in the model text is caught, and the text is not used' (Test-Rejected (Invoke-Step2 'named' 'The account of Ronit Gimel is not in use.') 'personal value')
$i = 0
foreach ($form in 'ronit gimel', 'Mr Gimel', 'Gimel, Ronit', 'Ronit.Gimel') {
    $i++
    Check "a name written as `"$form`" is caught" (Test-Rejected (Invoke-Step2 "named-$i" "The account of $form is not in use.") 'personal value')
}
# Run against the clean tenant's summary, which asks no decision, so that the at sign is the only problem.
$x = Invoke-Step2 'at-sign' 'Questions go to the help desk @ the front office.' (Join-Path $clean.Dir 'findings-summary.json')
Check 'an at sign (@) in the model text is caught' ((Test-Rejected $x 'an at sign (@) in the text') -and $x.Problems -eq 'an at sign (@) in the text')
Check 'an empty answer gives the template, with the problem "an empty text"' (Test-Rejected (Invoke-Step2 'empty' '') 'an empty text')

$b6 = Join-Path $OutDir 'brief-rejected-real'
$r = Run-Pwsh @($step2, '-SummaryJson', $earlierSummary, '-UsersCsv', $users, '-OutDir', $b6, '-Prompt', $earlierPrompt, '-Recorded', (Join-Path $earlier 'recorded-brief-rejected.md'))
$rep = Read-Json (Join-Path $b6 'brief-report.json')
$text = Get-Content -LiteralPath (Join-Path $b6 'brief.md') -Raw -Encoding utf8
Check 'the real answer that cites its own list numbers ("findings 3 to 5") is refused for the 5, and the template is used' ($rep.ai_text_accepted -eq $false -and
    ($rep.problems -join ' ') -eq 'figures not in the summary: 5' -and $text.Contains('Your decisions:'))
Check 'the refused real answer keeps its label: it was recorded, and its hashes match' ($rep.origin -eq 'recorded')

$leaky = Join-Path $OutDir 'summary-with-a-name.json'
$parts = $sumText -split '"department": "Sales"', 2
Set-Content -LiteralPath $leaky -Encoding utf8 -NoNewline -Value ($parts[0] + '"department": "ronit gimel"' + $parts[1])
$b7 = Join-Path $OutDir 'brief-leaky'
$r = Run-Pwsh @($step2, '-SummaryJson', $leaky, '-UsersCsv', $users, '-OutDir', $b7)
Check 'a personal value put into the summary is refused before sending (exit 2), nothing written' ($parts.Count -eq 2 -and $r.Code -eq 2 -and
    $r.Text -match 'would reach the model' -and -not (Test-Path -LiteralPath $b7))

$t = New-Table 'admin-finance.csv' @(
    'admin@demo.example.com,Tenant Admin (synthetic),IT,Member,True,True,False,2024-01-10,2026-11-19,M365_BUSINESS_PREMIUM'
    'finance@demo.example.com,Finance,Finance,Member,True,False,False,2024-01-10,,M365_BUSINESS_STANDARD')
$af = Invoke-Step1 'admin-finance-findings' $t
$x = Invoke-Step2 'admin-finance-brief' $recordedText (Join-Path $af.Dir 'findings-summary.json') $t
Check 'a tenant with an admin@ account and a display name "Finance" (also its department) can run step 2' ($af.Code -eq 0 -and
    (Get-Content -LiteralPath (Join-Path $af.Dir 'findings-summary.json') -Raw).Contains('"Finance"') -and $x.Code -eq 0 -and
    $null -ne $x.Report -and $x.Report.personal_values_in_request -eq 0)

# The decisions in the brief: each of the summary's ids exactly once, and no other.
$dsj = Join-Path $df.Dir 'findings-summary.json'
$constructedPath = Join-Path $here 'recordings/brief.constructed.md'
$constructed = Get-Text $constructedPath
$bc = Join-Path $OutDir 'brief-constructed'
$r = Run-Pwsh @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-OutDir', $bc, '-Recorded', $constructedPath)
$repc = Read-Json (Join-Path $bc 'brief-report.json')
$cmeta = Read-Json (Join-Path $here 'recordings/brief.constructed.meta.json')
Check 'the constructed brief passes the checks against the shipped tenant, and is labelled "Constructed, not from a model"' ($r.Code -eq 0 -and
    $repc.ai_text_accepted -eq $true -and $repc.origin_label -eq 'Constructed, not from a model' -and $constructed.Contains('Constructed, not from a model'))
Check 'the request built today has the sha256 the constructed brief was written against' ($repc.request_sha256 -eq $cmeta.request_sha256 -and $cmeta.origin -eq 'constructed')
Check 'the brief folder holds a byte-for-byte copy of the summary it was written from' ((Get-FileSha256 (Join-Path $bc 'findings-summary.json')) -eq (Get-FileSha256 $dsj))
# The two recorded answers to today's request. With no -Recorded, step 2 uses the first.
$i = 0
foreach ($rec in @('brief.recorded.md', 'brief.recorded-2.md')) {
    $i++
    $ro = Join-Path $OutDir "brief-real-$i"
    $a = @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-OutDir', $ro)
    if ($i -eq 2) { $a += @('-Recorded', (Join-Path $here "recordings/$rec")) }
    $r = Run-Pwsh $a
    $rr = if (Test-Path -LiteralPath (Join-Path $ro 'brief-report.json')) { Read-Json (Join-Path $ro 'brief-report.json') } else { $null }
    $rm = Read-Json (Join-Path $here ("recordings/" + [IO.Path]::ChangeExtension($rec, '.meta.json')))
    Check "the recorded answer $rec passes every check (0 problems) and earns the label Recorded against the request built today" ($r.Code -eq 0 -and
        $null -ne $rr -and $rr.answer_file -eq $rec -and $rr.ai_text_accepted -eq $true -and @($rr.problems).Count -eq 0 -and
        $rr.origin_label -eq 'Recorded: claude-haiku-5-5, on 2026-11-24' -and $rr.request_sha256 -eq $rm.request_sha256 -and $rr.obtained -eq $rm.obtained)
}
$x = Invoke-Step2 'decision-twice' ($constructed.Replace('- D2:', '- D1 and D2:')) $dsj $dataUsers
Check 'a decision named twice is caught (D1)' (Test-Rejected $x 'a decision named more than once: D1')
$x = Invoke-Step2 'decision-unknown' ($constructed + "`n- D9: Should the administrator delete everything? Yes or no.") $dsj $dataUsers
Check 'a decision the summary does not hold is caught (D9)' (Test-Rejected $x 'an unknown decision id')
$x = Invoke-Step2 'decision-left-out' (($constructed -split "`n" | Where-Object { $_ -notlike '- D4:*' }) -join "`n") $dsj $dataUsers
Check 'a decision left out is caught (D4), and the template asks all six' ((Test-Rejected $x 'a decision left out: D4') -and
    (@([regex]::Matches($x.Brief, '\bD[0-9]+\b') | ForEach-Object Value) -join ',') -eq 'D1,D2,D3,D4,D5,D6' -and -not ($x.Brief -match '\{[a-z_]+\}'))

# Where the text came from: the label is earned from the meta file's two hashes.
$lab = Join-Path $OutDir 'labels'; New-Item -ItemType Directory -Path $lab | Out-Null
function Get-Label([string] $Name, [string] $Answer, [string] $MetaJson) {
    $a = Join-Path $lab "$Name.md"
    [IO.File]::WriteAllText($a, $Answer)
    if ($MetaJson) { [IO.File]::WriteAllText((Join-Path $lab "$Name.meta.json"), $MetaJson) }
    $o = Join-Path $lab "$Name-out"
    $null = Run-Pwsh @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-OutDir', $o, '-Recorded', $a)
    if (Test-Path -LiteralPath (Join-Path $o 'brief-report.json')) { (Read-Json (Join-Path $o 'brief-report.json')).origin_label } else { '' }
}
$metaText = Get-Text (Join-Path $here 'recordings/brief.constructed.meta.json')
Check 'a changed answer loses its label: Unverified' ((Get-Label 'changed' ($constructed + ' ') $metaText) -like 'Unverified: the answer file does not have*')
Check 'an answer whose meta file names another request is Unverified' ((Get-Label 'other-request' $constructed ($metaText.Replace($cmeta.request_sha256, ('0' * 64)))) -like 'Unverified: the answer was given to another request*')
Check 'an answer with no meta file is Unverified' ((Get-Label 'no-meta' $constructed '') -eq 'Unverified: no meta file beside the answer')

# -WriteRequest: the exact request, for recording a real answer.
$reqFile = Join-Path $OutDir 'request.txt'
$r = Run-Pwsh @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-WriteRequest', $reqFile)
Check '-WriteRequest writes the request whose sha256 the brief report holds, and prints it' ($r.Code -eq 0 -and (Get-FileSha256 $reqFile) -eq $repc.request_sha256 -and
    $r.Text.Contains($repc.request_sha256))
$r = Run-Pwsh @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-WriteRequest', $reqFile)
Check '-WriteRequest never overwrites a file (exit 2)' ($r.Code -eq 2)

# --- Add-RecordedBrief.ps1 ------------------------------------------------------------------------------------------
$recDir = Join-Path $OutDir 'recordings'
$answerBytes = [byte[]](@([Text.Encoding]::UTF8.GetBytes($constructed.Replace("`n", "`r`n"))) + @(0xC3, 0xA9))
$answerFile = Join-Path $OutDir 'model-answer.md'
[IO.File]::WriteAllBytes($answerFile, $answerBytes)
$wrongReq = Join-Path $OutDir 'wrong-request.txt'
[IO.File]::WriteAllText($wrongReq, (Get-Text $reqFile) + ' ')
$r = Run-Pwsh @($adder, '-Answer', $answerFile, '-RequestFile', $wrongReq, '-SummaryJson', $dsj, '-Model', 'test-model', '-Obtained', 'typed by a test', '-RecordedOn', '2026-11-24', '-Name', 'trial', '-Into', $recDir)
Check 'Add-RecordedBrief refuses an answer given to another request (exit 2), and writes nothing' ($r.Code -eq 2 -and $r.Text -match 'another request' -and
    -not (Test-Path -LiteralPath (Join-Path $recDir 'trial.md')))
$r = Run-Pwsh @($adder, '-Answer', $answerFile, '-RequestFile', $reqFile, '-SummaryJson', $dsj, '-Model', 'test-model', '-Obtained', 'typed by a test', '-RecordedOn', '2026-11-24', '-Name', 'trial', '-Into', $recDir)
$tm = if (Test-Path -LiteralPath (Join-Path $recDir 'trial.meta.json')) { Read-Json (Join-Path $recDir 'trial.meta.json') } else { $null }
Check 'Add-RecordedBrief copies the answer byte for byte (CRLF and non-ASCII bytes kept) and writes origin, model and how it was obtained' ($r.Code -eq 0 -and
    (Get-FileSha256 (Join-Path $recDir 'trial.md')) -eq (Get-BytesSha256 $answerBytes) -and $null -ne $tm -and $tm.origin -eq 'recorded' -and
    $tm.model -eq 'test-model' -and $tm.obtained -eq 'typed by a test' -and $tm.request_sha256 -eq $repc.request_sha256)
$o = Join-Path $OutDir 'brief-trial'
$null = Run-Pwsh @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-OutDir', $o, '-Recorded', (Join-Path $recDir 'trial.md'))
$trialRep = Read-Json (Join-Path $o 'brief-report.json')
Check 'a recording added by the tool earns the label "Recorded", with the model and the date; the report says how it was obtained' ($trialRep.origin_label -eq
    'Recorded: test-model, on 2026-11-24' -and $trialRep.obtained -eq 'typed by a test')
$r = Run-Pwsh @($adder, '-Answer', $answerFile, '-RequestFile', $reqFile, '-SummaryJson', $dsj, '-Model', 'test-model', '-Obtained', 'again', '-RecordedOn', '2026-11-24', '-Name', 'trial', '-Into', $recDir)
Check 'Add-RecordedBrief never overwrites a recording (exit 2)' ($r.Code -eq 2 -and (Read-Json (Join-Path $recDir 'trial.meta.json')).obtained -eq 'typed by a test')

# --- the decisions, the work list -----------------------------------------------------------------------------------
function Decide([string] $Brief, [string] $Id, [string] $Answer, [string] $By = 'Test Manager (synthetic)', [string] $At = '2026-11-22T09:00:00Z', [string] $Reason = '') {
    Run-Pwsh @($decide, '-BriefDir', $Brief, '-Decision', $Id, '-Answer', $Answer, '-By', $By, '-At', $At, '-Reason', $Reason)
}
$r = Decide $bc 'D1' 'Yes'
$d1 = Read-JsonExact (Join-Path $bc 'decisions.json')
Check 'a decision is recorded in decisions.json, bound to the sha256 of the summary' ($r.Code -eq 0 -and $d1['summary_sha256'] -eq (Get-FileSha256 $dsj) -and
    @($d1['answers']).Count -eq 1 -and $d1['answers'][0]['by'] -eq 'Test Manager (synthetic)' -and $d1['answers'][0]['at'] -eq '2026-11-22T09:00:00Z')
$r = Decide $bc 'D2' 'yes' -At '2026-11-22T11:30:00+02:00'
$d2 = Read-JsonExact (Join-Path $bc 'decisions.json')
Check 'answers are appended and the earlier one is unchanged; "yes" is written Yes; a time with an offset is kept as UTC' ($r.Code -eq 0 -and @($d2['answers']).Count -eq 2 -and
    (ConvertTo-Json $d2['answers'][0] -Compress) -eq (ConvertTo-Json $d1['answers'][0] -Compress) -and $d2['answers'][1]['answer'] -eq 'Yes' -and
    $d2['answers'][1]['at'] -eq '2026-11-22T09:30:00Z')
$before = Get-FileSha256 (Join-Path $bc 'decisions.json')
$refusals = [ordered]@{
    'a No without a reason' = (Decide $bc 'D3' 'No')
    'an empty name' = (Decide $bc 'D3' 'Yes' -By '')
    'a name that starts with =' = (Decide $bc 'D3' 'Yes' -By '=cmd')
    'a name that starts with +' = (Decide $bc 'D3' 'Yes' -By '+1')
    'a name that starts with -' = (Decide $bc 'D3' 'Yes' -By '-1')
    'a name that starts with @' = (Decide $bc 'D3' 'Yes' -By '@x')
    'a name that starts with a tab' = (Decide $bc 'D3' 'Yes' -By "`tx")
    'a name with a line break' = (Decide $bc 'D3' 'Yes' -By "A`nB")
    'a decision the summary does not ask (D9)' = (Decide $bc 'D9' 'Yes')
    'a time with no offset' = (Decide $bc 'D3' 'Yes' -At '2026-11-22T09:00:00')
}
foreach ($k in $refusals.Keys) { Check "Set-BriefDecision refuses $k (exit 2)" ($refusals[$k].Code -eq 2) }
Check 'the refusals left decisions.json byte for byte as it was' ((Get-FileSha256 (Join-Path $bc 'decisions.json')) -eq $before)
$r = Decide (Join-Path $OutDir 'brief-recorded') 'D1' 'Yes'
Check 'a decision is refused for a summary that does not ask it (the earlier summary asks none)' ($r.Code -eq 2 -and $r.Text -match 'not a decision of this summary')

# A second brief folder, same summary, template brief: the work list must not depend on the brief's text.
$bt = Join-Path $OutDir 'brief-template'
$null = Run-Pwsh @($step2, '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-OutDir', $bt, '-Recorded', (Join-Path $OutDir 'empty.md'))
# The same answers in both folders (the constructed brief already holds D1 Yes at 09:00 and D2 Yes at 09:30 UTC).
$null = Decide $bt 'D1' 'Yes' -At '2026-11-22T09:00:00Z'
$null = Decide $bt 'D2' 'Yes' -At '2026-11-22T09:30:00Z'
foreach ($p in @($bc, $bt)) {
    $null = Decide $p 'D5' 'Yes' -At '2026-11-22T09:31:00Z'
    $null = Decide $p 'D5' 'No' -At '2026-11-22T09:32:00Z' -Reason 'Changed my mind.'
    $null = Decide $p 'D4' 'No' -At '2026-11-22T09:33:00Z' -Reason 'Later.'
}
$w1 = Join-Path $OutDir 'worklist-1'; $w2 = Join-Path $OutDir 'worklist-2'
$r = Run-Pwsh @($worklistScript, '-FindingsDir', $df.Dir, '-BriefDir', $bc, '-OutDir', $w1)
$wl = if ($r.Code -eq 0) { @(Import-Csv -LiteralPath (Join-Path $w1 'worklist.csv')) } else { @() }
$wmd = Get-Text (Join-Path $w1 'worklist.md')
Check 'the work list holds only the decisions answered Yes: D1 (R3) and D2 (R6); D5, whose last answer is No, and D4 (No) add nothing' ($r.Code -eq 0 -and
    (@($wl | ForEach-Object Decision | Select-Object -Unique) -join ',') -eq 'D1,D2' -and @($wl | Where-Object Rule -in 'R4', 'R8').Count -eq 0 -and
    @($wl | Where-Object Rule -eq 'R3').Count -eq 3 -and @($wl | Where-Object Rule -eq 'R6').Count -eq 5)
Check 'the work list says which decisions are No (with the reason) and which are still open, and that it changes nothing' ($wmd.Contains('D5: answered No') -and
    $wmd.Contains('Reason: Changed my mind.') -and $wmd.Contains('D3: still open') -and $wmd.Contains('D6: still open') -and $wmd.Contains('this list changes nothing'))
$adminNames = @{}; foreach ($row in $df.Rows) { $adminNames[$row.Upn] = $row.Name }
Check 'every name in the work list is the one in the administrator''s file, with who decided and when' (@($wl | Where-Object { $_.Item -like '*@*' -and $adminNames[$_.Item] -ne $_.Name }).Count -eq 0 -and
    @($wl | Where-Object { $_.DecidedBy -ne 'Test Manager (synthetic)' -or -not $_.DecidedAt }).Count -eq 0)
$r = Run-Pwsh @($worklistScript, '-FindingsDir', $df.Dir, '-BriefDir', $bt, '-OutDir', $w2)
Check 'the work list does not depend on the brief''s text: the template brief with the same decisions gives the same worklist.csv' ($r.Code -eq 0 -and
    (Get-FileSha256 (Join-Path $w1 'worklist.csv')) -eq (Get-FileSha256 (Join-Path $w2 'worklist.csv')))
$r = Run-Pwsh @($worklistScript, '-FindingsDir', $f, '-BriefDir', $bc, '-OutDir', (Join-Path $OutDir 'worklist-mixed'))
Check 'the work list is refused when the brief folder holds another summary than the findings folder (exit 2)' ($r.Code -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $OutDir 'worklist-mixed')))
$bo = Join-Path $OutDir 'brief-other'
$null = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $bo, '-Recorded', (Join-Path $OutDir 'empty.md'))
Copy-Item -LiteralPath (Join-Path $bc 'decisions.json') -Destination (Join-Path $bo 'decisions.json')
$beforeOther = Get-FileSha256 (Join-Path $bo 'decisions.json')
$r = Decide $bo 'D1' 'Yes'
$r2 = Run-Pwsh @($worklistScript, '-FindingsDir', $f, '-BriefDir', $bo, '-OutDir', (Join-Path $OutDir 'worklist-other'))
Check 'a decisions file for another summary is refused, by Set-BriefDecision and by New-AdminWorklist, and left unchanged' ($r.Code -eq 2 -and
    $r.Text -match 'another summary' -and $r2.Code -eq 2 -and (Get-FileSha256 (Join-Path $bo 'decisions.json')) -eq $beforeOther)
$edited = Join-Path $OutDir 'brief-edited'
Copy-Item -LiteralPath $bt -Destination $edited -Recurse
[IO.File]::WriteAllText((Join-Path $edited 'findings-summary.json'), (Get-Text (Join-Path $edited 'findings-summary.json')).Replace('"count": 7', '"count": 8'))
$r = Decide $edited 'D1' 'Yes'
Check 'a brief folder whose summary was changed after the brief was written is refused (exit 2)' ($r.Code -eq 2 -and $r.Text -match 'not the one the brief was written from')

# --- the report pages -----------------------------------------------------------------------------------------------
$pg = Join-Path $OutDir 'pages'
$r = Run-Pwsh @($reportScript, '-FindingsDir', $df.Dir, '-BriefDir', $bc, '-WorklistDir', $w1, '-UsersCsv', $dataUsers, '-DataKind', 'Synthetic', '-OutDir', $pg)
$mgr = Get-Text (Join-Path $pg 'manager.html'); $adm = Get-Text (Join-Path $pg 'admin.html')
$dataNames = foreach ($u in $dUsers) { $u.UserPrincipalName; ($u.DisplayName -replace '\(.*\)', '').Trim() }
Check 'the report writes two pages (exit 0)' ($r.Code -eq 0 -and $mgr -and $adm)
Check 'the manager''s page holds no name or sign-in address from the users table' (@($dataNames | Where-Object { $mgr -match ('(?i)(?<!\w)' + [regex]::Escape($_) + '(?!\w)') }).Count -eq 0 -and -not $mgr.Contains('@'))
Check 'the manager''s page holds the as-of date, "Synthetic data", the brief''s label, the findings by rule and the invented units' ($mgr.Contains('As of 2026-11-21') -and
    $mgr.Contains('Synthetic data') -and $mgr.Contains('Constructed, not from a model') -and $mgr.Contains('<td>R8</td>') -and $mgr.Contains('invented units'))
Check 'the manager''s page shows each decision with its answer, who and when, or "open"' ($mgr -match '<td>D1</td>.*?>Yes</td><td>Test Manager \(synthetic\)</td><td>2026-11-22T09:00:00Z</td>' -and
    $mgr -match '<td>D3</td>.*?>open</td>')
Check 'the administrator''s page says at its top that it stays on this computer, and holds the names and the work list' ($adm.IndexOf('For the administrator only') -lt $adm.IndexOf('<h1>') -and
    $adm.Contains($df.Rows[0].Upn) -and $adm.Contains('The work list') -and $adm.Contains('Changed my mind.'))
Check 'both pages are self-contained: no script, no external file, a content security policy' (@($mgr, $adm | Where-Object {
    $_ -match '(?i)<script|\ssrc=|<link|https?://' -or -not $_.Contains("Content-Security-Policy"" content=""default-src 'none'; style-src 'unsafe-inline'""") }).Count -eq 0)
# Escaping: a tag in a display name (administrator's page) and in the model's text (both pages).
$tagUsers = New-Table 'tag.csv' @('tag@demo.example.com,<b>Tag</b> Person (synthetic),Sales,Member,False,False,True,2024-01-10,2026-01-10,M365_BUSINESS_STANDARD')
$tf = Invoke-Step1 'tag-findings' $tagUsers
$tb = Join-Path $OutDir 'tag-brief'
[IO.File]::WriteAllText((Join-Path $OutDir 'tag-answer.md'), '<script>alert("x")</script> One licence to review. D6: Should the licences be reviewed? Yes or no.')
$null = Run-Pwsh @($step2, '-SummaryJson', (Join-Path $tf.Dir 'findings-summary.json'), '-UsersCsv', $tagUsers, '-OutDir', $tb, '-Recorded', (Join-Path $OutDir 'tag-answer.md'))
$tw = Join-Path $OutDir 'tag-worklist'
$null = Run-Pwsh @($decide, '-BriefDir', $tb, '-Decision', 'D6', '-Answer', 'Yes', '-By', '<i>Boss</i>', '-At', '2026-11-22T09:00:00Z')
$null = Run-Pwsh @($worklistScript, '-FindingsDir', $tf.Dir, '-BriefDir', $tb, '-OutDir', $tw)
$tp = Join-Path $OutDir 'tag-pages'
$r = Run-Pwsh @($reportScript, '-FindingsDir', $tf.Dir, '-BriefDir', $tb, '-WorklistDir', $tw, '-UsersCsv', $tagUsers, '-DataKind', 'Synthetic', '-OutDir', $tp)
$tmgr = Get-Text (Join-Path $tp 'manager.html'); $tadm = Get-Text (Join-Path $tp 'admin.html')
Check 'a tag in a display name, in the model''s text and in a typed name is shown as text, never as markup' ($r.Code -eq 0 -and
    $tadm.Contains('&lt;b&gt;Tag&lt;/b&gt; Person') -and -not $tadm.Contains('<b>Tag') -and $tmgr.Contains('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;') -and
    -not $tmgr.Contains('<script') -and $tmgr.Contains('&lt;i&gt;Boss&lt;/i&gt;') -and -not $tmgr.Contains('<i>Boss'))
# The integrity checks.
Copy-Item -LiteralPath $bc -Destination (Join-Path $OutDir 'brief-touched') -Recurse
Add-Content -LiteralPath (Join-Path $OutDir 'brief-touched/brief.md') -Value 'One more line.'
$r = Run-Pwsh @($reportScript, '-FindingsDir', $df.Dir, '-BriefDir', (Join-Path $OutDir 'brief-touched'), '-WorklistDir', $w1, '-UsersCsv', $dataUsers, '-DataKind', 'Synthetic', '-OutDir', (Join-Path $OutDir 'pages-touched'))
Check 'the pages are refused when brief.md was changed after it was checked (exit 2), nothing written' ($r.Code -eq 2 -and $r.Text -match 'changed after it was checked' -and
    -not (Test-Path -LiteralPath (Join-Path $OutDir 'pages-touched')))
$null = Decide $bc 'D6' 'Yes' -At '2026-11-22T10:00:00Z'
$r = Run-Pwsh @($reportScript, '-FindingsDir', $df.Dir, '-BriefDir', $bc, '-WorklistDir', $w1, '-UsersCsv', $dataUsers, '-DataKind', 'Synthetic', '-OutDir', (Join-Path $OutDir 'pages-stale'))
Check 'the pages are refused when a decision was recorded after the work list was made (exit 2)' ($r.Code -eq 2 -and $r.Text -match 'older than decisions.json')
# The name guard of the manager's page: a summary changed so that a rule title carries a name is refused.
$gd = Join-Path $OutDir 'guard'; Copy-Item -LiteralPath $df.Dir -Destination "$gd-findings" -Recurse; Copy-Item -LiteralPath $bt -Destination "$gd-brief" -Recurse
$bad = (Get-Text "$gd-findings/findings-summary.json").Replace('Disabled but still licensed', 'Disabled but still licensed, such as ' + ($dUsers[0].DisplayName -replace ' \(.*\)', ''))
foreach ($p in "$gd-findings/findings-summary.json", "$gd-brief/findings-summary.json") { [IO.File]::WriteAllText($p, $bad) }
$newSha = Get-FileSha256 "$gd-findings/findings-summary.json"
$oldSha = (Read-Json "$gd-brief/brief-report.json").summary_sha256
[IO.File]::WriteAllText("$gd-brief/brief-report.json", (Get-Text "$gd-brief/brief-report.json").Replace($oldSha, $newSha))
[IO.File]::WriteAllText("$gd-brief/decisions.json", (Get-Text "$gd-brief/decisions.json").Replace($oldSha, $newSha))
$r = Run-Pwsh @($worklistScript, '-FindingsDir', "$gd-findings", '-BriefDir', "$gd-brief", '-OutDir', "$gd-worklist")
$r = Run-Pwsh @($reportScript, '-FindingsDir', "$gd-findings", '-BriefDir', "$gd-brief", '-WorklistDir', "$gd-worklist", '-UsersCsv', $dataUsers, '-DataKind', 'Synthetic', '-OutDir', "$gd-pages")
Check 'the manager''s page is refused when a name from the users table would be on it (exit 2), nothing written' ($r.Code -eq 2 -and $r.Text -match 'would be on the manager' -and
    -not (Test-Path -LiteralPath "$gd-pages"))

# --- the API path, against a mock Messages API on this computer -----------------------------------------------------
# Serves one answer on a free local port while step 2 runs against it with -Backend Anthropic. It sends the request
# that the two earlier real answers answered (the earlier summary and prompt), so that the real answer is accepted.
function Invoke-WithMock([string] $Name, [int] $Status, [string] $Body) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $out = Join-Path $OutDir $Name
    $job = Start-Job -ScriptBlock {
        param($Step2, $Sj, $Users, $Out, $Port, $Prompt)
        & pwsh -NoProfile -NonInteractive -File $Step2 -SummaryJson $Sj -UsersCsv $Users -OutDir $Out -Backend Anthropic -ApiBase "http://127.0.0.1:$Port" -Prompt $Prompt 2>&1
        "EXIT $LASTEXITCODE"
    } -ArgumentList $step2, $earlierSummary, $users, $out, $port, $earlierPrompt
    $seen = ''
    $accept = $listener.AcceptTcpClientAsync()
    $got = $accept.Wait(60000)
    if ($got) {
        $client = $accept.Result
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 15000   # a stalled request fails the test instead of hanging it
            $buf = New-Object byte[] 65536; $ms = New-Object System.IO.MemoryStream
            do {
                $n = $stream.Read($buf, 0, $buf.Length); $ms.Write($buf, 0, $n)
                $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                $headEnd = $raw.IndexOf("`r`n`r`n")
                $done = $false
                if ($headEnd -ge 0 -and $raw -match '(?im)^content-length:\s*(\d+)') {
                    $done = ($ms.Length - [Text.Encoding]::UTF8.GetByteCount($raw.Substring(0, $headEnd + 4))) -ge [int]$Matches[1]
                }
            } while (-not $done -and $n -gt 0)
            $seen = $raw
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status Mock`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        } catch {
            $seen = "MOCK ERROR $($_.Exception.Message)"
        } finally {
            $client.Close()
        }
    }
    $listener.Stop()
    $null = Wait-Job -Job $job -Timeout 120
    $jobOut = Receive-Job -Job $job | Out-String
    Remove-Job -Job $job -Force
    $script:printed.Add($jobOut)
    [pscustomobject]@{ Got = $got; Seen = $seen; Out = $jobOut; Dir = $out }
}
function New-Reply([string] $StopReason, $Content) {
    @{ id = 'msg_test'; type = 'message'; role = 'assistant'; model = 'mock'; stop_reason = $StopReason; content = @($Content) } |
        ConvertTo-Json -Depth 5 -Compress
}

$savedKey = $env:ANTHROPIC_API_KEY   # the caller's own key, if any: never used here, restored at the end
$savedToken = $env:GRAPH_ACCESS_TOKEN
try {
    # A placeholder key for the mock. It is built from parts so that no key-shaped literal is in this file.
    $placeholder = 'unit' + '-' + 'test' + '-' + 'placeholder'
    $env:ANTHROPIC_API_KEY = $placeholder

    $m = Invoke-WithMock 'brief-api' 200 (New-Reply 'end_turn' @(@{ type = 'text'; text = $recordedText }))
    Check 'the API call reached the mock' $m.Got
    Check 'the API request goes to /v1/messages with the API version header' ($m.Seen -match '(?m)^POST /v1/messages HTTP/1\.1' -and $m.Seen -match '(?im)^anthropic-version:\s*2023-06-01')
    Check 'the API request carries a key header' ($m.Seen -match '(?im)^x-api-key:\s*\S+')
    Check 'the API request asks for up to 4096 tokens' ($m.Seen.Contains('"max_tokens":4096'))
    Check 'the API request body carries no name or address' (@($names | Where-Object { $m.Seen.Contains($_) }).Count -eq 0)
    $rep = if (Test-Path -LiteralPath (Join-Path $m.Dir 'brief-report.json')) { Read-Json (Join-Path $m.Dir 'brief-report.json') } else { $null }
    Check 'the API path ends with the model text accepted, and the report says the summary was sent to the API' ($m.Out -match 'EXIT 0' -and
        $null -ne $rep -and $rep.ai_text_accepted -eq $true -and $rep.backend -eq 'Anthropic' -and $rep.summary_sent_to_api -eq $true)

    $m = Invoke-WithMock 'brief-api-500' 500 '{"type":"error","error":{"type":"api_error","message":"mock failure"}}'
    Check 'an HTTP error from the API is refused (exit 3), nothing written' ($m.Got -and $m.Out -match 'EXIT 3' -and -not (Test-Path -LiteralPath $m.Dir))
    $m = Invoke-WithMock 'brief-api-cut' 200 (New-Reply 'max_tokens' @(@{ type = 'text'; text = 'A brief cut off in the' }))
    Check 'an API answer that stopped for max_tokens is refused (exit 3), nothing written' ($m.Got -and $m.Out -match 'EXIT 3' -and -not (Test-Path -LiteralPath $m.Dir))
    $m = Invoke-WithMock 'brief-api-notext' 200 (New-Reply 'end_turn' @())
    Check 'an API answer with no text block is refused (exit 3), nothing written' ($m.Got -and $m.Out -match 'EXIT 3' -and -not (Test-Path -LiteralPath $m.Dir))

    $closed = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $closed.Start(); $closedPort = ([System.Net.IPEndPoint]$closed.LocalEndpoint).Port; $closed.Stop()
    $b8 = Join-Path $OutDir 'brief-api-noconnect'
    $r = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $b8, '-Backend', 'Anthropic', '-ApiBase', "http://127.0.0.1:$closedPort")
    Check 'a connection error is refused (exit 3), nothing written' ($r.Code -eq 3 -and -not (Test-Path -LiteralPath $b8))

    # The live path sends exactly the request that -WriteRequest writes (the current prompt and the shipped tenant).
    $reply = New-Reply 'end_turn' @(@{ type = 'text'; text = $constructed })
    $ml = Invoke-WithLocalMock -Answer { param($Method, $Target) @{ Status = 200; Body = $reply } }.GetNewClosure() -PwshArgs @('-NonInteractive', '-File', $step2,
        '-SummaryJson', $dsj, '-UsersCsv', $dataUsers, '-OutDir', (Join-Path $OutDir 'brief-api-current'), '-Backend', 'Anthropic', '-ApiBase', '{base}')
    $script:printed.Add(($ml.Lines -join "`n"))
    $sent = if (@($ml.Requests).Count -eq 1) { ($ml.Requests[0].Body | ConvertFrom-Json).messages[0].content } else { '' }
    Check 'the live model path sends exactly the request -WriteRequest writes, and accepts a text that passes' ($ml.ExitCode -eq 0 -and $sent -ceq (Get-Text $reqFile) -and
        (Read-Json (Join-Path $OutDir 'brief-api-current/brief-report.json')).origin_label -eq 'Model API call (claude-haiku-5-5)')

    $env:ANTHROPIC_API_KEY = $null
    $b5 = Join-Path $OutDir 'brief-nokey'
    $r = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $b5, '-Backend', 'Anthropic', '-ApiBase', 'http://127.0.0.1:9')
    Check 'a missing key: a clear refusal (exit 2), nothing written' ($r.Code -eq 2 -and $r.Text -match 'no API key' -and -not (Test-Path -LiteralPath $b5))

    # --- the collector, against a mock of Microsoft Graph on this computer ---------------------------------------------
    $graphPlaceholder = 'unit' + '-' + 'graph' + '-' + 'placeholder'
    $env:GRAPH_ACCESS_TOKEN = $graphPlaceholder
    $graph = Join-Path $here 'mock/graph'
    function Invoke-Collector([string] $Name, [scriptblock] $Answer, [string[]] $More = @()) {
        $o = Join-Path $OutDir $Name
        $m = Invoke-WithLocalMock -Answer $Answer -PwshArgs (@('-NonInteractive', '-File', $collector, '-OutDir', $o, '-GraphBase', '{base}') + $More)
        $script:printed.Add(($m.Lines -join "`n"))
        [pscustomobject]@{ Code = $m.ExitCode; Text = ($m.Lines -join "`n"); Requests = @($m.Requests); Dir = $o }
    }
    $expected = @(
        '/v1.0/users?$select=id,userPrincipalName,displayName,department,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity&$top=500'
        '/v1.0/users?$select=id,userPrincipalName,displayName,department,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity&$top=500&$skiptoken=mock-page-2'
        '/v1.0/subscribedSkus?$select=skuId,skuPartNumber'
        "/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId%20eq%20'62e90394-69f5-4237-9190-012177145e10'&`$expand=principal"
        '/v1.0/reports/authenticationMethods/userRegistrationDetails'
        '/v1.0/identity/conditionalAccess/policies')
    $c1 = Invoke-Collector 'snapshot' (New-GraphMockAnswer -Folder $graph)
    Check 'the collector runs against the mock (exit 0), labelled Mock in what it prints and in its report' ($c1.Code -eq 0 -and $c1.Text.Contains('Mock: never run against a tenant') -and
        (Read-Json (Join-Path $c1.Dir 'snapshot-report.json')).label -eq $mockLabel)
    Check 'the mock recorded only GET requests, each to a path of the fixed list, the second users page through its next link' (@($c1.Requests | Where-Object Method -ne 'GET').Count -eq 0 -and
        (@($c1.Requests | ForEach-Object Target) -join "`n") -ceq ($expected -join "`n"))
    Check 'every request carried the token in an Authorization header, and nothing else carried it' (@($c1.Requests | Where-Object { $_.Headers['authorization'] -ne "Bearer $graphPlaceholder" }).Count -eq 0)
    $su = @(Import-Csv -LiteralPath (Join-Path $c1.Dir 'users.csv')); $sp = @(Import-Csv -LiteralPath (Join-Path $c1.Dir 'policies.csv'))
    $byU = @{}; foreach ($u in $su) { $byU[($u.UserPrincipalName -split '@')[0]] = $u }
    Check 'the collector maps the documented fields: Global Administrator from the role assignments, MFA from the registration report' ($su.Count -eq 6 -and
        $byU['mira.alef'].AdminRoles -eq 'Global Administrator' -and $byU['mira.alef'].IsAdmin -eq 'true' -and $byU['mira.alef'].MfaRegistered -eq 'true' -and
        $byU['vered.vav'].IsAdmin -eq 'true' -and $byU['vered.vav'].MfaRegistered -eq 'false' -and $byU['mira.alef'].AssignedLicenses -eq 'SYN_SUITE_PLUS')
    Check 'the collector''s stated choices: successful sign-ins only, a disabled user (not in the report) as MFA not registered, a missing creation date left empty' (
        $byU['ben.bet'].LastSignInDate -eq '' -and $byU['dvora.dalet'].MfaRegistered -eq 'false' -and $byU['dvora.dalet'].AdminRoles -eq 'Global Administrator' -and
        $byU['hen.he'].CreatedDate -eq '' -and (Read-Json (Join-Path $c1.Dir 'snapshot-report.json')).users_without_created_date_left_empty -eq 1 -and $byU['hen.he'].LastSignInDate -eq '2026-11-19T06:25:00Z' -and
        (Read-Json (Join-Path $c1.Dir 'snapshot-report.json')).global_administrator_holders_that_are_not_users -eq 1)
    Check 'the collector writes the policies with their other conditions (a risk-based block does not count as blocking legacy authentication)' ($sp.Count -eq 2 -and
        $sp[0].ClientAppTypes -eq 'exchangeActiveSync;other' -and $sp[0].State -eq 'enabledForReportingButNotEnforced' -and $sp[1].OtherConditions -eq 'userRiskLevels')
    $filled = Join-Path $OutDir 'snapshot-skus-filled.csv'
    Set-Content -LiteralPath $filled -Encoding utf8 -Value @('SkuPartNumber,MonthlyCostSynthetic', 'SYN_SUITE_PLUS,21.40', 'SYN_SUITE_STANDARD,12.70')
    $sf0 = Invoke-Step1 'snapshot-findings-nodate' (Join-Path $c1.Dir 'users.csv') -Skus $filled -Policies (Join-Path $c1.Dir 'policies.csv')
    Check 'step 1 refuses the collector''s user row that has no creation date, by its row number, rather than guess the date (exit 2)' ($sf0.Code -eq 2 -and
        $sf0.Text -match 'row 5: CreatedDate' -and -not (Test-Path -LiteralPath $sf0.Dir))
    $dated = Join-Path $OutDir 'snapshot-users-dated.csv'
    [IO.File]::WriteAllText($dated, (Get-Text (Join-Path $c1.Dir 'users.csv')).Replace('"Operations","Member","true","false","true","",', '"Operations","Member","true","false","true","2018-01-01",'))
    $sf = Invoke-Step1 'snapshot-findings' $dated -Skus $filled -Policies (Join-Path $c1.Dir 'policies.csv')
    $r = Invoke-Step1 'snapshot-findings-nocost' (Join-Path $c1.Dir 'users.csv') -Skus (Join-Path $c1.Dir 'skus.csv') -Policies (Join-Path $c1.Dir 'policies.csv')
    Check 'step 1 reads the collector''s tables once a person has typed the costs and the missing date; with the cost column left empty it refuses (exit 2)' ($sf.Code -eq 0 -and
        (Get-Counts $sf.Summary)['R7'] -eq 1 -and (Get-Counts $sf.Summary)['R8'] -eq 1 -and $r.Code -eq 2 -and $r.Text -match 'licence table row 1')
    $c2 = Invoke-Collector 'snapshot-throttled' (New-GraphMockAnswer -Folder $graph -Throttle licences)
    Check 'a throttled answer (429, Retry-After: 1) is waited for and tried again, and the run completes' ($c2.Code -eq 0 -and $c2.Text.Contains('throttled waits 1') -and
        @($c2.Requests | Where-Object Path -eq '/v1.0/subscribedSkus').Count -eq 2)
    $c3 = Invoke-Collector 'snapshot-403' (New-GraphMockAnswer -Folder $graph -Fail users)
    Check 'an answer 403 stops the collector (exit 3), nothing written' ($c3.Code -eq 3 -and $c3.Text -match 'HTTP 403' -and -not (Test-Path -LiteralPath $c3.Dir))
    $c4 = Invoke-Collector 'snapshot-badnext' (New-GraphMockAnswer -Folder $graph -BadNextLink)
    Check 'a next-page link to a path outside the fixed list stops the collector (exit 3), not followed, nothing written' ($c4.Code -eq 3 -and
        @($c4.Requests).Count -eq 1 -and -not (Test-Path -LiteralPath $c4.Dir))
    $always = { param($Method, $Target) @{ Status = 429; Headers = @{ 'Retry-After' = '1' }; Body = '{}' } }
    $c5 = Invoke-Collector 'snapshot-always-429' $always @('-MaxRetries', '1')
    Check 'a request still throttled after -MaxRetries stops the collector (exit 3), nothing written' ($c5.Code -eq 3 -and @($c5.Requests).Count -eq 2 -and -not (Test-Path -LiteralPath $c5.Dir))
    $long = { param($Method, $Target) @{ Status = 429; Headers = @{ 'Retry-After' = '1000' }; Body = '{}' } }
    $c6 = Invoke-Collector 'snapshot-long-wait' $long
    Check 'a wait longer than -MaxWaitSeconds stops the collector at once (exit 3)' ($c6.Code -eq 3 -and @($c6.Requests).Count -eq 1)
    $redirect = { param($Method, $Target) @{ Status = 302; Headers = @{ 'Location' = 'http://127.0.0.1:9/elsewhere' }; Body = '{}' } }
    $c7 = Invoke-Collector 'snapshot-redirect' $redirect
    Check 'a redirect is not followed: the collector stops (exit 3) after one request' ($c7.Code -eq 3 -and @($c7.Requests).Count -eq 1)
    $r = Run-Pwsh @($collector, '-OutDir', (Join-Path $OutDir 'snapshot-elsewhere'), '-GraphBase', 'https://graph.example.com')
    Check 'the collector refuses any address but Microsoft Graph or this computer (exit 2), so the token cannot be sent elsewhere' ($r.Code -eq 2)
    $env:GRAPH_ACCESS_TOKEN = $null
    $r = Run-Pwsh @($collector, '-OutDir', (Join-Path $OutDir 'snapshot-notoken'), '-GraphBase', 'http://127.0.0.1:9')
    Check 'the collector with no token: a clear refusal (exit 2), nothing written' ($r.Code -eq 2 -and $r.Text -match 'GRAPH_ACCESS_TOKEN' -and -not (Test-Path -LiteralPath (Join-Path $OutDir 'snapshot-notoken')))

    $withKey = @(Get-ChildItem -LiteralPath $OutDir -Recurse -File | Where-Object {
        $t = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8; $t -and ($t.Contains($placeholder) -or $t.Contains($graphPlaceholder)) })
    Check 'the API key placeholder appears in no output file and no printed output' ($withKey.Count -eq 0 -and
        @($script:printed | Where-Object { $_ -and $_.Contains($placeholder) }).Count -eq 0)
    Check 'the Graph token placeholder appears in no output file and no printed output' ($withKey.Count -eq 0 -and
        @($script:printed | Where-Object { $_ -and $_.Contains($graphPlaceholder) }).Count -eq 0)
} finally {
    $env:ANTHROPIC_API_KEY = $savedKey
    $env:GRAPH_ACCESS_TOKEN = $savedToken
}

# --- the whole demo, the failure gallery, the examples ------------------------------------------------------------
$demoOut = Join-Path $OutDir 'demo-de-DE'
$a = @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-WrapCulture', 'de-DE', '-WrapScript', $demo, '-OutDir', $demoOut)
$demoLines = @(& pwsh @a 2>&1 | ForEach-Object { [string]$_ })
$demoCode = $LASTEXITCODE
Check 'the whole demo runs under de-DE with every step OK (exit 0)' ($demoCode -eq 0 -and @($demoLines | Where-Object { $_ -match '^\S.{10} (OK|FAIL) ' -and $_ -notmatch ' OK ' }).Count -eq 0 -and
    @($demoLines | Where-Object { $_ -match '^\S.{10} OK ' }).Count -eq 5)
$exFiles = @(Get-ChildItem -LiteralPath (Join-Path $here 'examples') -Recurse -File | ForEach-Object { $_.FullName.Substring((Join-Path $here 'examples').Length) })
$deFiles = @(Get-ChildItem -LiteralPath $demoOut -Recurse -File | ForEach-Object { $_.FullName.Substring($demoOut.Length) })
$diff = @($exFiles | Where-Object { $_ -notin $deFiles -or (Get-FileSha256 (Join-Path $here "examples$_")) -ne (Get-FileSha256 (Join-Path $demoOut $_)) })
Check 'the whole demo under de-DE writes byte for byte the files in examples/ (same names, same bytes)' ($exFiles.Count -gt 10 -and $diff.Count -eq 0 -and $exFiles.Count -eq $deFiles.Count)
$r = Run-Pwsh @($demo, '-OutDir', $demoOut)
Check 'the demo never writes into an existing folder (exit 2)' ($r.Code -eq 2)
$casesOut = Join-Path $OutDir 'cases'
$a = @('-NoProfile', '-NonInteractive', '-File', $wrapper) + $(if ($culture) { @('-WrapCulture', $culture) } else { @() }) + @('-WrapScript', $demo, '-Case', 'all', '-OutDir', $casesOut)
$caseLines = @(& pwsh @a 2>&1 | ForEach-Object { [string]$_ })
Check 'the failure gallery: every one of the nine cases ends as expected' ($LASTEXITCODE -eq 0 -and $caseLines -contains 'cases 9 | as expected 9 | not as expected 0')
$svg = Get-Text (Join-Path $here 'docs/img/demo.svg')
$svgLines = @([regex]::Matches(($svg -split '<g ', 2)[-1], '<text x="[0-9.]+" y="[0-9.]+"(?: fill="#[0-9a-f]+")?>(.*?)</text>') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
$demoText = @(Get-Content -LiteralPath (Join-Path $demoOut 'demo-output.txt'))
$from = [array]::IndexOf($demoText, @($demoText | Where-Object { $_ -like 'rule *' })[0])
Check 'the picture docs/img/demo.svg shows exactly the closing table a run prints' ($from -gt 0 -and $svgLines.Count -gt 5 -and
    ($svgLines -join "`n") -ceq (($demoText[$from..($demoText.Count - 1)] | ForEach-Object { $_.TrimEnd() }) -join "`n"))

# --- the README: what it pastes is what the commands print ----------------------------------------------------------
$copy = Join-Path $OutDir 'repo-copy'
New-Item -ItemType Directory -Path $copy | Out-Null
foreach ($item in Get-ChildItem -LiteralPath $here -Force) {
    if ($item.Name -eq '.git' -or $item.Name -like 'out-*' -or $item.FullName -eq $OutDir) { continue }
    Copy-Item -LiteralPath $item.FullName -Destination $copy -Recurse
}
$readme = @(Get-Content -LiteralPath (Join-Path $here 'README.md') -Encoding utf8)
$blocks = [System.Collections.Generic.List[object]]::new()
$unmarked = 0
for ($i = 0; $i -lt $readme.Count; $i++) {
    if ($readme[$i] -notmatch '^```') { continue }
    $start = $i; $body = @()
    for ($i++; $i -lt $readme.Count -and $readme[$i] -notmatch '^```'; $i++) { $body += $readme[$i] }
    $marker = if ($start -gt 0 -and $readme[$start - 1] -match '^<!-- pasted: (.+) -->$') { $Matches[1] } else { '' }
    if (-not $marker -and $body.Count -and $body[0] -like '$ *') { $unmarked++ }
    if ($marker) { $blocks.Add([pscustomobject]@{ Marker = $marker; Body = $body; Line = $start + 1 }) }
}
Check 'every README block that shows a command and its output is marked as pasted, and so checked here' ($unmarked -eq 0 -and $blocks.Count -ge 4)
Push-Location -LiteralPath $copy
try {
    foreach ($b in $blocks) {
        if ($b.Marker -eq 'run') {
            $args2 = @(($b.Body[0].Substring(2)) -split ' +' | Select-Object -Skip 1)
            $lines = @(& pwsh @args2 2>&1 | ForEach-Object { ([string]$_).TrimEnd() })
            $want = @($b.Body | Select-Object -Skip 1 | ForEach-Object { $_.TrimEnd() })
            $okBlock = $want.Count -gt 0 -and $lines.Count -ge $want.Count -and (($lines[0..($want.Count - 1)]) -join "`n") -ceq ($want -join "`n")
            Check ("README line {0}: ""{1}"" prints what the README shows" -f $b.Line, $b.Body[0].Substring(2)) $okBlock
        } elseif ($b.Marker -match '^file (.+)$') {
            $fileLines = @(Get-Content -LiteralPath (Join-Path $copy $Matches[1]) -Encoding utf8)
            $okBlock = $b.Body.Count -gt 0 -and $fileLines.Count -ge $b.Body.Count -and (($fileLines[0..($b.Body.Count - 1)]) -join "`n") -ceq ($b.Body -join "`n")
            Check ("README line {0}: the lines shown are the first lines of {1}" -f $b.Line, $Matches[1]) $okBlock
        }
    }
} finally {
    Pop-Location
}
$readmeText = $readme -join "`n"
# A paragraph after "<!-- quotes: <file> -->" quotes that file: every "..." in it must be a slice of the file, exactly.
$quoteCount = 0; $badQuotes = [System.Collections.Generic.List[string]]::new()
foreach ($doc in @('README.md', 'docs/DESIGN.md')) {
    $lines = @(Get-Content -LiteralPath (Join-Path $here $doc) -Encoding utf8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\s*<!-- quotes: (\S+) -->\s*$') { continue }
        $source = Get-Text (Join-Path $here $Matches[1])
        $para = @(); for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j].Trim(); $j++) { $para += $lines[$j].Trim() }
        $quotes = @([regex]::Matches(($para -join ' '), '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        if (-not $source -or $quotes.Count -eq 0) { $badQuotes.Add("$doc line $($i + 1)") }
        foreach ($q in $quotes) { $quoteCount++; if (-not $source.Contains($q)) { $badQuotes.Add("$doc line $($i + 1): $q") } }
    }
}
Check 'every quote of a real answer in the README and docs/DESIGN.md is an exact slice of the file it names' ($quoteCount -ge 10 -and $badQuotes.Count -eq 0)
$images = @([regex]::Matches($readmeText, '!\[[^\]]*\]\(([^)\s]+)\)|<img [^>]*src="([^"]+)"') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } |
    Where-Object { $_ -notmatch '^https?://' })
Check 'every image the README embeds from the repository exists' ($images.Count -ge 1 -and @($images | Where-Object { -not (Test-Path -LiteralPath (Join-Path $here $_)) }).Count -eq 0)
$realRows = @($readme | Where-Object { $_ -match '^\| .+ \| (Local|Recorded|Constructed|Mock|Live)\b' })
Check 'the README''s table of what is real has no row marked Live, and says this has not been run against a tenant' ($realRows.Count -ge 5 -and
    @($realRows | Where-Object { $_ -match '\| Live\b' }).Count -eq 0 -and $readmeText.Contains('This has not been run against a tenant.'))
foreach ($p in @('README.md', 'docs/COLLECTOR.md', 'Export-TenantSnapshot.ps1')) {
    Check "the collector is labelled Mock in $p, in the same words" ((Get-Text (Join-Path $here $p)).Contains($mockLabel))
}

# --- read-only by construction, and what the files hold -------------------------------------------------------------
$scripts = @(Get-ChildItem -LiteralPath $here -Filter *.ps1 -File) + @(Get-ChildItem -LiteralPath (Join-Path $here 'lib') -Filter *.ps1 -File) |
    Where-Object { $_.Name -ne 'Test-Demo.ps1' }
$code = ($scripts | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$network = ($scripts | Where-Object { $_.Name -ne 'LocalMock.ps1' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
Check 'no Connect- cmdlet in any script' ($code -notmatch '(?i)\bConnect-\w')
Check 'no Set, New, Remove, Update, Add, Enable or Disable cmdlet of the Mg, Az, AzureAD, Msol, Mailbox, ADUser or DistributionGroup families in any script' (
    $code -notmatch '(?i)\b(Set|New|Remove|Update|Add|Enable|Disable)-(Mg|Az|Msol|\w*Mailbox|ADUser|\w*DistributionGroup)')
Check 'no Invoke-MgGraphRequest, Invoke-WebRequest or Send-MailMessage, and no web alias or .NET network class, in any script but the local mock' (
    $code -notmatch '(?i)Invoke-MgGraphRequest|Invoke-WebRequest|Send-MailMessage' -and $network -notmatch '(?i)\b(iwr|irm|curl|wget)\b|WebClient|HttpClient|SmtpClient|Sockets')
$rest = @(foreach ($s in $scripts) { foreach ($c in Get-Commands $s.FullName) { if ($c.GetCommandName() -in 'Invoke-RestMethod', 'irm') {
    $i = [array]::IndexOf(@($c.CommandElements | ForEach-Object { $_.Extent.Text }), '-Method')
    '{0}:{1}' -f $s.Name, $(if ($i -gt 0) { $c.CommandElements[$i + 1].Extent.Text } else { '(none)' }) } } })
Check 'exactly two Invoke-RestMethod commands in all scripts: the POST to the model API in step 2 and the GET of the collector' (
    $rest.Count -eq 2 -and $rest -ccontains 'Export-TenantSnapshot.ps1:Get' -and $rest -ccontains 'New-ManagerBrief.ps1:Post')
$cc = Get-Text $collector
Check 'the collector names no HTTP method but GET, and follows no redirect' ($cc -notmatch '(?i)-Method\s+(Post|Put|Patch|Delete|Head|Options|Merge)|CustomMethod|(?-i:\b(POST|PUT|PATCH|DELETE)\b)' -and
    $cc.Contains('-MaximumRedirection 0'))
$listed = @([regex]::Matches(($cc -split '\$Paths = \[ordered\]@\{', 2)[1].Split('}')[0], "(?m)^\s+\w+\s+=\s+[""'](.+)[""']\s*$") | ForEach-Object { $_.Groups[1].Value.Replace('$GlobalAdministratorRoleId', '62e90394-69f5-4237-9190-012177145e10').Replace('`$', '$') })
Check 'the collector''s fixed list holds exactly the five documented paths, and no other path is written in it' (($listed -join "`n") -ceq (@($expected | Where-Object { $_ -notmatch 'skiptoken' }) -join "`n") -and
    @([regex]::Matches($cc, "['""]/v1\.0/") ).Count -eq 5)
$mock = Get-Text (Join-Path $here 'lib/LocalMock.ps1')
Check 'the local mock listens on 127.0.0.1 only' ($mock.Contains('[System.Net.IPAddress]::Loopback, 0') -and $mock -notmatch 'IPAddress\]::(Any|IPv6Any|Parse)')
Check 'no script reads the clock or the time zone, except Set-BriefDecision''s documented default (the UTC time of an answer)' (
    @($scripts | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?i)Get-Date|\[datetime(offset)?\]::(Now|UtcNow|Today)|TimeZoneInfo|ToLocalTime' -and $_.Name -ne 'Set-BriefDecision.ps1' }).Count -eq 0 -and
    @([regex]::Matches((Get-Text $decide), '(?i)Get-Date|::(Now|UtcNow|Today)')).Count -eq 1)

$tracked = @(Get-ChildItem -LiteralPath $here -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($here.Length + 1) -replace '\\', '/'
    $rel -notmatch '^(\.git|out-[^/]*)/' -and -not $_.FullName.StartsWith($OutDir) -and $_.Extension -ne '.png' })
$nonAscii = @($tracked | Where-Object { @([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0 } | ForEach-Object Name)
Check 'every text file is ASCII' ($nonAscii.Count -eq 0)
$crlf = @($tracked | Where-Object { [IO.File]::ReadAllBytes($_.FullName) -contains 13 } | ForEach-Object Name)
Check 'every text file has LF line ends (no carriage return), and .gitattributes says so' ($crlf.Count -eq 0 -and (Get-Text (Join-Path $here '.gitattributes')).Contains('* text=auto eol=lf'))
$all = ($tracked | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
Check 'no file holds an absolute path of a computer' ($all -notmatch '(?<![A-Za-z])[A-Za-z]:[\\/][A-Za-z0-9_. -]+[\\/]' -and $all -notmatch '(?i)(?<![\w.])/(home|Users)/[a-z]')
$shapes = @(('sk' + '-ant-'), ('\bsk' + '-[A-Za-z0-9]{20}'), ('eyJ' + '[A-Za-z0-9_-]{20}'), ('gh' + 'p_[A-Za-z0-9]{20}'), ('xox' + '[bp]-'), ('AKI' + 'A[0-9A-Z]{16}'), (('-' * 5) + 'BEGIN' + ' [A-Z ]*PRIVATE KEY'))
Check 'no file holds a key-shaped or token-shaped literal' (@($shapes | Where-Object { $all -cmatch $_ }).Count -eq 0)
Check 'no line reads like an assigned credential (token, secret, password or key = a literal)' ($all -notmatch ('(?im)\b(token|secret|password|passwd|api[_-]?key)' + '\s*[:=]\s*[''"][^''"\s]+[''"]'))

$tests = Get-Text (Join-Path $here 'docs/TESTS.md')
$expectedLine = 'RESULT {0} passed, {1} failed' -f ($script:pass + 1), $script:fail
$pasted = @($tests -split "`n" | Where-Object { $_ -like 'RESULT *' } | ForEach-Object { $_.TrimEnd() })
Check 'docs/TESTS.md shows the result line of this run, pasted from a run (every result line it shows is this run''s)' ($pasted.Count -ge 1 -and
    @($pasted | Where-Object { $_ -cne $expectedLine }).Count -eq 0)

Write-Output ("RESULT {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) {
    Write-Output "the test folder is kept for inspection: $OutDir"
    exit 1
}
if (-not $keep -and $OutDir.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path -Leaf $OutDir) -like 'm365-hygiene-tests-*') {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
exit 0
