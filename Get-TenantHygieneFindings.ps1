#requires -Version 7.4
<#
.SYNOPSIS
    Step 1: Microsoft 365 tenant hygiene findings from a user table, a licence table and, when given, a Conditional
    Access policy table and a tenant table.

.DESCRIPTION
    Reads a flattened user table of the kind an administrator assembles from Microsoft Graph, where the sign-in
    activity, the licence assignments, the administrator roles and the MFA registration details come from different
    sources; a licence table; and, optionally, a table of the tenant's Conditional Access policies (the sign-in rules of
    a Microsoft 365 tenant) and a tenant table that says whether security defaults are on. Export-TenantSnapshot.ps1
    (Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant) writes all
    four in this shape. The licence names and costs in the shipped files are invented.

    It applies eight fixed, auditable rules and writes three files into a new folder:
      findings-admin.csv     for the administrator, on this computer only: names and sign-in addresses
      findings-summary.json  for the AI step and the manager: the same findings, pseudonymised. Every person is
                             replaced by a stand-in (user-001 ...) and every policy by policy-001 ..., but each
                             flagged person's department, licences and days since sign-in remain, and in a small
                             tenant they can point to one person. It also carries the decisions a manager is asked.
      key.local.json         the local key (stand-in -> address or policy id), which never leaves this computer

    The rules (the as-of date is a parameter, so a run is repeatable):
      R1 enabled, licensed, last sign-in more than 90 days ago                        (licence cost)
      R2 disabled, still licensed                                                     (licence cost)
      R3 enabled administrator without MFA registered. Disabled accounts are not
         judged: Microsoft's registration report does not list disabled users, so
         their MFA state is not known (a disabled administrator is still counted by
         R6, and by R2 when licensed)                                                 (security)
      R4 enabled guest: last sign-in more than 90 days ago, or no sign-in on record
         and created more than 30 days ago                                            (security)
      R5 enabled, licensed member with no sign-in on record, created more than 30
         days ago                                                                     (licence cost)
      R6 more accounts hold the Global Administrator role than the limit (4), enabled
         or not; one finding about the tenant, with no person in it                   (security, tenant)
      R7 legacy authentication is not blocked: no enforced (enabled) Conditional Access
         policy blocks it, and security defaults are off. A policy blocks it when it
         includes all users and all resources, excludes no resource and uses no
         resource filter, its client app types include both exchangeActiveSync and
         other, its grant control is block, and it sets no other condition (excluded
         users are allowed). A policy that would block it but is in report-only mode
         is named by its stand-in, so that the decisions on R7 and R8 speak of the
         same policy; one finding about the tenant                                    (security, tenant)
      R8 a policy created more than 30 days ago and still in report-only mode
         (enabledForReportingButNotEnforced), or in that mode with no creation date,
         which is reported as unknown and never given an age; one finding per policy,
         with no person in it                                                         (security, policy)
    A user with no sign-in on record is judged by R5 or R4, never by R1, so no one is counted twice for the same cost.
    A last successful sign-in read from Microsoft Graph is not backfilled before 1 December 2023, so "no sign-in on
    record" can also mean an earlier last sign-in; the summary says so.

    A rule whose input is missing is not checked, and the summary, the brief, the pages and the work list say "not
    checked" and what is missing, never a count of 0: R6 without an AdminRoles column; R7, unless security defaults
    are on, without a policies table, with one that lacks the ExcludeApplications and ApplicationFilter columns (an
    older table), or without a tenant table when no enforced policy blocks legacy authentication; R8 without a
    policies table.

    The decisions are fixed here, not by a model: D1 (R3), D2 (R6), D3 (R7), D4 (R8), D5 (R4), D6 (R1, R2, R5). A
    decision is in the summary only when one of its rules found something.

    Input: a date is yyyy-MM-dd, or an ISO 8601 timestamp with Z or an offset, which counts as its UTC date, and is not
    after the as-of date. AccountEnabled, IsAdmin and MfaRegistered are true or false, in any letter case. AdminRoles
    lists role names separated by ";", and a role there needs IsAdmin true. A cost is a decimal number with "." as the
    separator. Each licence a user holds must be in the licence table. A sign-in address and a policy id may each appear
    once. A department or a licence name must not hold a part of a name or sign-in address of a person in the users
    table (three letters or more, any letter case; an account named after a department is not a person here): these
    reach the summary. Any other value is refused (exit 2) with its row number (the first row after the header is row
    1), and nothing is written. A user's CreatedDate is required; a policy's CreatedDate may be empty (unknown). Costs
    are exact decimals throughout.

    It reads files only. It connects to no tenant and changes nothing.

.EXAMPLE
    pwsh -File Get-TenantHygieneFindings.ps1 -UsersCsv data/users.synthetic.csv -SkusCsv data/skus.synthetic.csv -PoliciesCsv data/policies.synthetic.csv -TenantCsv data/tenant.synthetic.csv -AsOf 2026-11-21 -OutDir <new folder>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UsersCsv,
    [Parameter(Mandatory)] [string] $SkusCsv,
    [string] $PoliciesCsv = '',
    [string] $TenantCsv = '',
    [Parameter(Mandatory)] [string] $AsOf,
    [Parameter(Mandatory)] [string] $OutDir,
    [ValidateRange(0, 3650)] [int] $StaleDays = 90,
    [ValidateRange(0, 3650)] [int] $NewAccountGraceDays = 30,
    [ValidateRange(0, 10000)] [int] $GlobalAdminMax = 4,
    [ValidateRange(0, 3650)] [int] $ReportOnlyMaxDays = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }
$asOfDate = [datetime]::MinValue
if (-not ($AsOf -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($AsOf, 'yyyy-MM-dd', $inv, 'None', [ref]$asOfDate))) {
    Stop-Refused 'AsOf must be a date written yyyy-MM-dd'
}

Assert-CsvColumns $UsersCsv @('UserPrincipalName', 'DisplayName', 'Department', 'UserType', 'AccountEnabled', 'IsAdmin',
    'MfaRegistered', 'CreatedDate', 'LastSignInDate', 'AssignedLicenses') 'users table'
$hasRoles = 'AdminRoles' -cin @(Get-CsvColumns $UsersCsv)
Assert-CsvColumns $SkusCsv @('SkuPartNumber', 'MonthlyCostSynthetic') 'licence table'
$hasPolicies = [bool]$PoliciesCsv
$hasAppColumns = $false
if ($hasPolicies) {
    Assert-CsvColumns $PoliciesCsv @('PolicyId', 'DisplayName', 'State', 'CreatedDate', 'ClientAppTypes', 'IncludeUsers',
        'IncludeApplications', 'GrantControls', 'OtherConditions') 'policies table'
    # A policies table written before these two columns existed can still be read: R8 does not need them, and R7 says
    # it was not checked, since it cannot tell whether a policy covers all resources.
    $policyColumns = @(Get-CsvColumns $PoliciesCsv)
    $hasAppColumns = 'ExcludeApplications' -cin $policyColumns -and 'ApplicationFilter' -cin $policyColumns
}
$securityDefaults = 'not read'
if ($TenantCsv) {
    Assert-CsvColumns $TenantCsv @('SecurityDefaultsEnabled') 'tenant table'
    $tenantRows = @(Import-Csv -LiteralPath $TenantCsv -Encoding utf8)
    if ($tenantRows.Count -ne 1) { Stop-Refused 'the tenant table must hold exactly one row' }
    $v = [string]$tenantRows[0].SecurityDefaultsEnabled
    if ($v -match '^(true|false)$') { $securityDefaults = if ($v -eq 'true') { 'on' } else { 'off' } }
    elseif ($v) { Stop-Refused 'tenant table row 1: SecurityDefaultsEnabled must be true, false or empty' }
}

$users = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
$policies = @(if ($hasPolicies) { Import-Csv -LiteralPath $PoliciesCsv -Encoding utf8 })
$cost = @{}
$skuRow = 0
foreach ($s in Import-Csv -LiteralPath $SkusCsv -Encoding utf8) {
    $skuRow++
    if ($s.MonthlyCostSynthetic -notmatch '^[0-9]{1,15}(\.[0-9]{1,10})?$') {
        Stop-Refused "licence table row ${skuRow}: MonthlyCostSynthetic must be a number such as 12.5, with a dot and no sign"
    }
    if ($cost.ContainsKey($s.SkuPartNumber)) { Stop-Refused "licence table row ${skuRow}: licence $($s.SkuPartNumber) is listed twice" }
    $cost[$s.SkuPartNumber] = [decimal]::Parse($s.MonthlyCostSynthetic, [Globalization.NumberStyles]::AllowDecimalPoint, $inv)
}

function Get-Licenses([string] $text) { @($text -split ';' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
function Get-LicenseCost([string[]] $skus) { $sum = [decimal]0; foreach ($k in $skus) { $sum += $cost[$k] }; $sum }
function Get-Bool([string] $value, [string] $column, [int] $row) {
    if ($value -notmatch '^(true|false)$') { Stop-Refused "row ${row}: $column must be true or false" }
    $value -eq 'true'
}
function Get-Day([string] $value, [string] $column, [int] $row, [string] $table = '') {
    $d = $null
    $p = [datetime]::MinValue
    $o = [datetimeoffset]::MinValue
    if ($value -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($value, 'yyyy-MM-dd', $inv, 'None', [ref]$p)) { $d = $p }
    elseif ($value -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$' -and
        [datetimeoffset]::TryParse($value, $inv, 'None', [ref]$o)) { $d = $o.UtcDateTime.Date }
    else { Stop-Refused "${table}row ${row}: $column is not yyyy-MM-dd or an ISO 8601 timestamp with Z or an offset" }
    if ($d -gt $asOfDate) { Stop-Refused "${table}row ${row}: $column is after the as-of date" }
    $d
}
function Get-CostSum($items) { $s = [decimal]0; foreach ($x in $items) { $s += $x.MonthlyCost }; $s }
function Split-List([string] $text) { @($text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$rules = [ordered]@{
    R1 = 'Enabled and licensed, no sign-in for more than {0} days' -f $StaleDays
    R2 = 'Disabled but still licensed'
    R3 = 'Enabled administrator without MFA registered'
    R4 = 'Guest with no sign-in for more than {0} days, or none on record' -f $StaleDays
    R5 = 'Licensed member with no sign-in on record, created more than {0} days ago' -f $NewAccountGraceDays
    R6 = 'More than {0} accounts hold the Global Administrator role' -f $GlobalAdminMax
    R7 = 'No enforced Conditional Access policy blocks legacy authentication, and security defaults are off'
    R8 = 'Conditional Access policy created more than {0} days ago and still in report-only mode' -f $ReportOnlyMaxDays
}
$kind = @{ R1 = 'cost'; R2 = 'cost'; R3 = 'security'; R4 = 'security'; R5 = 'cost'; R6 = 'security'; R7 = 'security'; R8 = 'security' }
$scope = @{ R1 = 'account'; R2 = 'account'; R3 = 'account'; R4 = 'account'; R5 = 'account'; R6 = 'tenant'; R7 = 'tenant'; R8 = 'policy' }

# A department or a licence name reaches the summary, so it must not name a person of the users table.
$personParts = Get-PersonNameParts $users
$seenUpn = @{}
$row = 0
foreach ($u in $users) {
    $row++
    if (-not $u.UserPrincipalName) { Stop-Refused "row ${row}: UserPrincipalName is empty" }
    $k = $u.UserPrincipalName.ToLowerInvariant()
    if ($seenUpn.ContainsKey($k)) { Stop-Refused "row ${row}: the same UserPrincipalName as row $($seenUpn[$k])" }
    $seenUpn[$k] = $row
    foreach ($col in 'Department', 'AssignedLicenses') {
        $from = @(Find-NameParts ([string]$u.$col) $personParts)
        if ($from.Count) { Stop-Refused "row ${row}: $col holds a part of the name or sign-in address in row $($from -join ', '); it would reach the summary" }
    }
    foreach ($l in Get-Licenses $u.AssignedLicenses) { if (-not $cost.ContainsKey($l)) { Stop-Refused "row ${row}: no cost row for licence $l" } }
}

$found = New-Object System.Collections.Generic.List[object]
$globalAdmins = New-Object System.Collections.Generic.List[object]
$row = 0
foreach ($u in $users) {
    $row++
    $lic = @(Get-Licenses $u.AssignedLicenses)
    $enabled = Get-Bool $u.AccountEnabled 'AccountEnabled' $row
    $admin = Get-Bool $u.IsAdmin 'IsAdmin' $row
    $mfa = Get-Bool $u.MfaRegistered 'MfaRegistered' $row
    $roles = @(if ($hasRoles) { Split-List $u.AdminRoles })
    if ($roles.Count -gt 0 -and -not $admin) { Stop-Refused "row ${row}: AdminRoles names a role but IsAdmin is false" }
    $guest = $u.UserType -eq 'Guest'
    $daysSince = if ($u.LastSignInDate) { [int]($asOfDate - (Get-Day $u.LastSignInDate 'LastSignInDate' $row)).TotalDays } else { $null }
    $age = [int]($asOfDate - (Get-Day $u.CreatedDate 'CreatedDate' $row)).TotalDays
    $never = $null -eq $daysSince
    $stale = -not $never -and $daysSince -gt $StaleDays
    $pastGrace = $age -gt $NewAccountGraceDays
    $hits = @()
    if ($enabled -and $lic.Count -gt 0 -and $stale) { $hits += 'R1' }
    if (-not $enabled -and $lic.Count -gt 0) { $hits += 'R2' }
    if ($enabled -and $admin -and -not $mfa) { $hits += 'R3' }
    if ($guest -and $enabled -and ($stale -or ($never -and $pastGrace))) { $hits += 'R4' }
    if (-not $guest -and $enabled -and $lic.Count -gt 0 -and $never -and $pastGrace) { $hits += 'R5' }
    foreach ($r in $hits) {
        $found.Add([pscustomobject]@{
            Rule = $r; Upn = $u.UserPrincipalName; Name = $u.DisplayName; Department = $u.Department
            DaysSinceSignIn = $daysSince; AccountAgeDays = $age; Licenses = $lic
            MonthlyCost = $(if ($r -in @('R1', 'R2', 'R5')) { Get-LicenseCost $lic } else { [decimal]0 })
        })
    }
    if ($roles -contains 'Global Administrator') {
        $globalAdmins.Add([pscustomobject]@{ Upn = $u.UserPrincipalName; Name = $u.DisplayName; Department = $u.Department; Enabled = $enabled })
    }
}

# The policies table: R7 (is legacy authentication blocked?) and R8 (report-only policies left too long).
$states = @('enabled', 'disabled', 'enabledForReportingButNotEnforced')
$blockers = 0
$wouldBlock = New-Object System.Collections.Generic.List[object]
$reportOnly = New-Object System.Collections.Generic.List[object]
$seenPolicy = @{}
$prow = 0
foreach ($p in $policies) {
    $prow++
    if (-not $p.PolicyId) { Stop-Refused "policies row ${prow}: PolicyId is empty" }
    if ($seenPolicy.ContainsKey($p.PolicyId)) { Stop-Refused "policies row ${prow}: the same PolicyId as policies row $($seenPolicy[$p.PolicyId])" }
    $seenPolicy[$p.PolicyId] = $prow
    if ($p.State -notin $states) { Stop-Refused "policies row ${prow}: State must be enabled, disabled or enabledForReportingButNotEnforced" }
    $created = if ($p.CreatedDate) { Get-Day $p.CreatedDate 'CreatedDate' $prow 'policies ' } else { $null }
    $days = if ($null -ne $created) { [int]($asOfDate - $created).TotalDays } else { $null }
    $apps = @(Split-List $p.ClientAppTypes)
    $legacy = ('exchangeActiveSync' -in $apps) -and ('other' -in $apps)
    $covers = $hasAppColumns -and $legacy -and ('All' -in @(Split-List $p.IncludeUsers)) -and ('All' -in @(Split-List $p.IncludeApplications)) -and
        @(Split-List $p.ExcludeApplications).Count -eq 0 -and -not ([string]$p.ApplicationFilter).Trim() -and
        ('block' -in @(Split-List $p.GrantControls)) -and @(Split-List $p.OtherConditions).Count -eq 0
    if ($covers -and $p.State -eq 'enabled') { $blockers++ }
    if ($covers -and $p.State -eq 'enabledForReportingButNotEnforced') { $wouldBlock.Add([pscustomobject]@{ PolicyId = $p.PolicyId; Name = $p.DisplayName }) }
    # A report-only policy with no creation date is reported as such, never given an invented age.
    if ($p.State -eq 'enabledForReportingButNotEnforced' -and ($null -eq $days -or $days -gt $ReportOnlyMaxDays)) {
        $reportOnly.Add([pscustomobject]@{ PolicyId = $p.PolicyId; Name = $p.DisplayName; Days = $days
            Created = $(if ($null -ne $created) { $created.ToString('yyyy-MM-dd', $inv) } else { '' }) })
    }
}
if (@($reportOnly | Where-Object { $null -eq $_.Days }).Count) { $rules['R8'] += ', or in report-only mode with no creation date' }

# What each rule could not check, for want of its input. A rule not checked has no count, never a count of 0.
$notChecked = @{}
if (-not $hasRoles) { $notChecked['R6'] = 'the users table has no AdminRoles column' }
if (-not $hasPolicies) { $notChecked['R8'] = 'no policies table was given' }
if ($securityDefaults -ne 'on') {
    if (-not $hasPolicies) {
        $notChecked['R7'] = $(if ($securityDefaults -eq 'off') { 'no policies table was given' } else { 'no policies table and no tenant table were given' })
    } elseif (-not $hasAppColumns) {
        $notChecked['R7'] = 'the policies table has no ExcludeApplications or ApplicationFilter column, so whether a policy covers all resources is not known'
    } elseif ($blockers -eq 0 -and $securityDefaults -eq 'not read') {
        $notChecked['R7'] = 'no tenant table was given, so whether security defaults are on is not known'
    }
}

$r6 = -not $notChecked.ContainsKey('R6') -and $globalAdmins.Count -gt $GlobalAdminMax
$r7 = -not $notChecked.ContainsKey('R7') -and $securityDefaults -eq 'off' -and $blockers -eq 0
if (-not $r7) { $wouldBlock.Clear() }

# Stand-ins: one per person, in order of first appearance, stable across rules; one per policy that R7 or R8 names,
# in the order of the policies table, so that both rules give a policy the same stand-in.
$ref = [ordered]@{}
foreach ($f in $found) { if (-not $ref.Contains($f.Upn)) { $ref[$f.Upn] = 'user-{0:D3}' -f ($ref.Count + 1) } }
$people = $ref.Count
$named = @($wouldBlock | ForEach-Object PolicyId) + @($reportOnly | ForEach-Object PolicyId)
$policyRef = [ordered]@{}
foreach ($p in $policies) { if ($p.PolicyId -in $named -and -not $policyRef.Contains($p.PolicyId)) { $policyRef[$p.PolicyId] = 'policy-{0:D3}' -f ($policyRef.Count + 1) } }
$wouldBlockRefs = @($wouldBlock | ForEach-Object { $policyRef[$_.PolicyId] })

# Everything is computed before the output folder is created, so a refusal or an error leaves nothing behind.
# Numbers are written with the invariant culture, so the files do not depend on the machine's settings.
$adminRows = New-Object System.Collections.Generic.List[object]
foreach ($f in $found) {
    $adminRows.Add([ordered]@{ Rule = $f.Rule; Upn = $f.Upn; Name = $f.Name; Department = $f.Department
        DaysSinceSignIn = $f.DaysSinceSignIn; AccountAgeDays = $f.AccountAgeDays; Licenses = ($f.Licenses -join ';')
        MonthlyCost = (Format-Units $f.MonthlyCost); Scope = 'account'; Detail = '' })
}
if ($r6) {
    foreach ($g in $globalAdmins) {
        $adminRows.Add([ordered]@{ Rule = 'R6'; Upn = $g.Upn; Name = $g.Name; Department = $g.Department; MonthlyCost = '0'; Scope = 'tenant'
            Detail = ('Holds Global Administrator ({0}); {1} accounts hold it, limit {2}' -f $(if ($g.Enabled) { 'enabled' } else { 'disabled' }),
                $globalAdmins.Count, $GlobalAdminMax) })
    }
}
if ($r7) {
    $detail = 'No enforced policy blocks legacy authentication, and security defaults are off; {0} policies checked' -f $policies.Count
    if ($wouldBlock.Count) {
        $detail += '; in report-only mode, would block it: ' + (@($wouldBlock | ForEach-Object { '{0} (policy id {1}, {2})' -f $_.Name, $_.PolicyId, $policyRef[$_.PolicyId] }) -join '; ')
    }
    $adminRows.Add([ordered]@{ Rule = 'R7'; MonthlyCost = '0'; Scope = 'tenant'; Detail = $detail })
}
foreach ($p in $reportOnly) {
    $adminRows.Add([ordered]@{ Rule = 'R8'; Name = $p.Name; MonthlyCost = '0'; Scope = 'policy'
        Detail = $(if ($null -eq $p.Days) { 'Policy id {0} ({1}); report-only, creation date unknown' -f $p.PolicyId, $policyRef[$p.PolicyId] } else {
            'Policy id {0} ({1}); report-only, created {2}, {3} days ago' -f $p.PolicyId, $policyRef[$p.PolicyId], $p.Created, $p.Days }) })
}
$adminColumns = @('Rule', 'Upn', 'Name', 'Department', 'DaysSinceSignIn', 'AccountAgeDays', 'Licenses', 'MonthlyCost', 'Scope', 'Detail')
$adminCsv = ConvertTo-CsvText $adminRows.ToArray() $adminColumns

$summaryRules = foreach ($r in $rules.Keys) {
    if ($notChecked.ContainsKey($r)) {
        [ordered]@{ id = $r; title = $rules[$r]; kind = $kind[$r]; scope = $scope[$r]; count = $null; not_checked = $notChecked[$r]
            monthly_cost_synthetic = $null; items = @() }
        continue
    }
    $items = @(switch ($r) {
        'R6' { if ($r6) { [ordered]@{ ref = 'tenant'; global_administrators = $globalAdmins.Count; limit = $GlobalAdminMax } } }
        'R7' { if ($r7) { [ordered]@{ ref = 'tenant'; policies_checked = $policies.Count; security_defaults = $securityDefaults
                    report_only_policies_that_would_block_it = $wouldBlockRefs } } }
        'R8' { foreach ($p in $reportOnly) { if ($null -eq $p.Days) { [ordered]@{ ref = $policyRef[$p.PolicyId]; days_since_created = $null; creation_date = 'unknown' } }
            else { [ordered]@{ ref = $policyRef[$p.PolicyId]; days_since_created = $p.Days } } } }
        default {
            foreach ($x in @($found | Where-Object Rule -eq $r)) {
                [ordered]@{ ref = $ref[$x.Upn]; department = $(if ($x.Department) { $x.Department } else { '(guest)' })
                    days_since_sign_in = $x.DaysSinceSignIn; licenses = $x.Licenses; monthly_cost_synthetic = (Format-Units $x.MonthlyCost) }
            }
        }
    })
    [ordered]@{
        id = $r; title = $rules[$r]; kind = $kind[$r]; scope = $scope[$r]; count = $items.Count
        monthly_cost_synthetic = (Format-Units (Get-CostSum @($found | Where-Object Rule -eq $r)))
        items = $items
    }
}
$reclaim = Get-CostSum @($found | Where-Object { $_.Rule -in 'R1', 'R2', 'R5' })
$count = @{}; foreach ($x in $summaryRules) { $count[$x.id] = $x.count }

$d3 = switch ($wouldBlockRefs.Count) {
    0 { 'Should the administrator turn on a Conditional Access policy that blocks legacy authentication for all users?' }
    1 { 'Should the administrator switch on {0}, which is in report-only mode now, so that it blocks legacy authentication for all users?' -f $wouldBlockRefs[0] }
    default { 'Should the administrator switch on one of {0}, which are in report-only mode now, so that legacy authentication is blocked for all users?' -f ($wouldBlockRefs -join ' and ') }
}
$both = @($reportOnly | ForEach-Object { $policyRef[$_.PolicyId] } | Where-Object { $_ -in $wouldBlockRefs })
$d4 = if ($both.Count) {
    'Should the administrator review each Conditional Access policy left in report-only mode, to switch it on or remove it ({0} {1} also in the question about legacy authentication)?' -f ($both -join ' and '), $(if ($both.Count -eq 1) { 'is' } else { 'are' })
} else { 'Should the administrator review each Conditional Access policy left in report-only mode, to switch it on or remove it?' }
$decisionDefs = @(
    [ordered]@{ id = 'D1'; question = 'Should the administrator require every administrator account to register a second sign-in step (MFA)?'; rules = @('R3') }
    [ordered]@{ id = 'D2'; question = ('Should the administrator review who holds the Global Administrator role and bring it down to {0} accounts or fewer?' -f $GlobalAdminMax); rules = @('R6') }
    [ordered]@{ id = 'D3'; question = $d3; rules = @('R7') }
    [ordered]@{ id = 'D4'; question = $d4; rules = @('R8') }
    [ordered]@{ id = 'D5'; question = 'Should the administrator remove the guest accounts that have no recent sign-in on record?'; rules = @('R4') }
    [ordered]@{ id = 'D6'; question = 'Should the administrator review the unused licences and return the ones the review finds not needed?'; rules = @('R1', 'R2', 'R5') }
)
$decisions = @($decisionDefs | Where-Object { $d = $_; @($d.rules | Where-Object { $count[$_] -gt 0 }).Count -gt 0 })

$summary = [ordered]@{
    as_of = $asOfDate.ToString('yyyy-MM-dd', $inv); users_checked = $users.Count
    policies_checked = $(if ($hasPolicies) { $policies.Count } else { $null }); security_defaults = $securityDefaults
    thresholds = [ordered]@{ stale_days = $StaleDays; new_account_grace_days = $NewAccountGraceDays
        global_admin_limit = $GlobalAdminMax; report_only_days = $ReportOnlyMaxDays }
    cost_note = 'synthetic units, invented for the demo; not a vendor price and not money'
    sign_in_note = 'A last successful sign-in read from Microsoft Graph is not backfilled before 1 December 2023, so no sign-in on record can also mean an earlier last sign-in.'
    reclaimable_monthly_cost_synthetic = (Format-Units $reclaim)
    rules = @($summaryRules)
    decisions = $decisions
}
$summaryJson = ConvertTo-JsonText $summary
$key = [ordered]@{}
foreach ($k in $ref.Keys) { $key[$ref[$k]] = $k }
foreach ($k in $policyRef.Keys) { $key[$policyRef[$k]] = $k }
$keyJson = ConvertTo-JsonText $key

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'findings-admin.csv') $adminCsv
Write-TextFile (Join-Path $OutDir 'findings-summary.json') ($summaryJson + "`n")
Write-TextFile (Join-Path $OutDir 'key.local.json') ($keyJson + "`n")

$counts = ($summaryRules | ForEach-Object { if ($null -eq $_.count) { '{0} not checked' -f $_.id } else { '{0} {1}' -f $_.id, $_.count } }) -join ' | '
$ids = if ($decisions.Count) { ($decisions | ForEach-Object { $_.id }) -join ' ' } else { 'none' }
Write-Output ('users {0} | policies {1} | security defaults {2} | {3} | reclaimable (invented units) {4} | people flagged {5} | decisions {6}' -f
    $users.Count, $(if ($hasPolicies) { $policies.Count } else { 'not given' }), $securityDefaults, $counts, (Format-Units $reclaim), $people, $ids)
