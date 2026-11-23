#requires -Version 7.1
<#
.SYNOPSIS
    Step 1: Microsoft 365 tenant hygiene findings from a user table (synthetic data only).

.DESCRIPTION
    Reads a flattened user table of the kind an administrator assembles from Microsoft Graph, where the sign-in
    activity, the licence assignments, the administrator roles and the MFA registration details come from four
    different sources. The licence names and costs in the synthetic files are invented.

    It applies five fixed, auditable rules and writes three files into a new folder:
      findings-admin.csv     for the administrator, on this computer only: names and sign-in addresses
      findings-summary.json  for the AI step: the same findings, pseudonymised. Every person is replaced by a
                             stand-in (user-001 ...), but each flagged person's department, licences and days since
                             sign-in remain, and in a small tenant they can point to one person.
      key.local.json         the local key (stand-in -> address), which never leaves this computer

    The rules (the as-of date is a parameter, so a run is repeatable):
      R1 enabled, licensed, last sign-in more than 90 days ago                        (licence cost)
      R2 disabled, still licensed                                                     (licence cost)
      R3 administrator without MFA registered, enabled or not                         (security)
      R4 enabled guest: last sign-in more than 90 days ago, or never signed in and
         created more than 30 days ago                                                (security)
      R5 enabled, licensed member who never signed in, created more than 30 days ago  (licence cost)
    A user with no sign-in at all is judged by R5 or R4, never by R1, so no one is counted twice for the same cost.

    Input: a date is yyyy-MM-dd, or an ISO 8601 timestamp with Z or an offset, which counts as its UTC date.
    AccountEnabled, IsAdmin and MfaRegistered are true or false, in any letter case. Any other value is refused
    (exit 2) with its row number (the first row after the header is row 1), and nothing is written.

    It reads files only. It connects to no tenant and changes nothing.

.EXAMPLE
    pwsh -File Get-TenantHygieneFindings.ps1 -UsersCsv users.synthetic.csv -SkusCsv skus.synthetic.csv -AsOf 2026-11-21 -OutDir <new folder>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UsersCsv,
    [Parameter(Mandatory)] [string] $SkusCsv,
    [Parameter(Mandatory)] [datetime] $AsOf,
    [Parameter(Mandatory)] [string] $OutDir,
    [int] $StaleDays = 90,
    [int] $NewAccountGraceDays = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

function Stop-Refused([string] $Message) {
    [Console]::Error.WriteLine("REFUSED: $Message")
    exit 2
}

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }

$users = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
$cost = @{}
foreach ($s in Import-Csv -LiteralPath $SkusCsv -Encoding utf8) { $cost[$s.SkuPartNumber] = [double]$s.MonthlyCostSynthetic }

function Get-Licenses([string] $text) { @($text -split ';' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
function Get-LicenseCost([string[]] $skus, [int] $row) {
    $sum = 0.0
    foreach ($k in $skus) {
        if (-not $cost.ContainsKey($k)) { Stop-Refused "row ${row}: no cost row for licence $k" }
        $sum += $cost[$k]
    }
    $sum
}
function Get-Bool([string] $value, [string] $column, [int] $row) {
    if ($value -notmatch '^(true|false)$') { Stop-Refused "row ${row}: $column must be true or false" }
    $value -eq 'true'
}
function Get-Day([string] $value, [string] $column, [int] $row) {
    $d = [datetime]::MinValue
    if ($value -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($value, 'yyyy-MM-dd', $inv, 'None', [ref]$d)) { return $d }
    $o = [datetimeoffset]::MinValue
    if ($value -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$' -and
        [datetimeoffset]::TryParse($value, $inv, 'None', [ref]$o)) { return $o.UtcDateTime.Date }
    Stop-Refused "row ${row}: $column is not yyyy-MM-dd or an ISO 8601 timestamp with Z or an offset"
}
function Get-CostSum($items) { $s = 0.0; foreach ($x in $items) { $s += $x.MonthlyCost }; $s }

$asOfDate = $AsOf.Date
$rules = [ordered]@{
    R1 = 'Enabled and licensed, no sign-in for more than {0} days' -f $StaleDays
    R2 = 'Disabled but still licensed'
    R3 = 'Administrator without MFA registered'
    R4 = 'Guest with no sign-in for more than {0} days, or never' -f $StaleDays
    R5 = 'Licensed member who never signed in, created more than {0} days ago' -f $NewAccountGraceDays
}
$found = New-Object System.Collections.Generic.List[object]
$row = 0
foreach ($u in $users) {
    $row++
    $lic = @(Get-Licenses $u.AssignedLicenses)
    $enabled = Get-Bool $u.AccountEnabled 'AccountEnabled' $row
    $admin = Get-Bool $u.IsAdmin 'IsAdmin' $row
    $mfa = Get-Bool $u.MfaRegistered 'MfaRegistered' $row
    $guest = $u.UserType -eq 'Guest'
    $daysSince = if ($u.LastSignInDate) { [int]($asOfDate - (Get-Day $u.LastSignInDate 'LastSignInDate' $row)).TotalDays } else { $null }
    $age = [int]($asOfDate - (Get-Day $u.CreatedDate 'CreatedDate' $row)).TotalDays
    $never = $null -eq $daysSince
    $stale = -not $never -and $daysSince -gt $StaleDays
    $pastGrace = $age -gt $NewAccountGraceDays
    $hits = @()
    if ($enabled -and $lic.Count -gt 0 -and $stale) { $hits += 'R1' }
    if (-not $enabled -and $lic.Count -gt 0) { $hits += 'R2' }
    if ($admin -and -not $mfa) { $hits += 'R3' }
    if ($guest -and $enabled -and ($stale -or ($never -and $pastGrace))) { $hits += 'R4' }
    if (-not $guest -and $enabled -and $lic.Count -gt 0 -and $never -and $pastGrace) { $hits += 'R5' }
    foreach ($r in $hits) {
        $found.Add([pscustomobject]@{
            Rule = $r; Upn = $u.UserPrincipalName; Name = $u.DisplayName; Department = $u.Department
            DaysSinceSignIn = $daysSince; AccountAgeDays = $age; Licenses = $lic
            MonthlyCost = $(if ($r -in @('R1', 'R2', 'R5')) { Get-LicenseCost $lic $row } else { 0.0 })
        })
    }
}

# Stand-ins: one per person, in order of first appearance, stable across rules.
$ref = [ordered]@{}
foreach ($f in $found) { if (-not $ref.Contains($f.Upn)) { $ref[$f.Upn] = 'user-{0:D3}' -f ($ref.Count + 1) } }

# Everything is computed before the output folder is created, so a refusal or an error leaves nothing behind.
# Numbers are written with the invariant culture, so the files do not depend on the machine's settings.
$adminCsv = @($found | Select-Object Rule, Upn, Name, Department, DaysSinceSignIn, AccountAgeDays,
    @{ n = 'Licenses'; e = { $_.Licenses -join ';' } }, @{ n = 'MonthlyCost'; e = { $_.MonthlyCost.ToString($inv) } } | ConvertTo-Csv)
if ($adminCsv.Count -eq 0) { $adminCsv = @('"Rule","Upn","Name","Department","DaysSinceSignIn","AccountAgeDays","Licenses","MonthlyCost"') }

$summaryRules = foreach ($r in $rules.Keys) {
    $items = @($found | Where-Object Rule -eq $r)
    [ordered]@{
        id = $r; title = $rules[$r]; count = $items.Count
        monthly_cost_synthetic = Get-CostSum $items
        items = @($items | ForEach-Object {
            [ordered]@{ ref = $ref[$_.Upn]; department = $(if ($_.Department) { $_.Department } else { '(guest)' })
                days_since_sign_in = $_.DaysSinceSignIn; licenses = $_.Licenses; monthly_cost_synthetic = $_.MonthlyCost }
        })
    }
}
$reclaim = Get-CostSum @($found | Where-Object { $_.Rule -in 'R1', 'R2', 'R5' })
$summary = [ordered]@{
    as_of = $asOfDate.ToString('yyyy-MM-dd', $inv); users_checked = $users.Count
    thresholds = [ordered]@{ stale_days = $StaleDays; new_account_grace_days = $NewAccountGraceDays }
    cost_note = 'synthetic units, invented for the demo; not a vendor price'
    reclaimable_monthly_cost_synthetic = $reclaim
    rules = @($summaryRules)
}
$summaryJson = $summary | ConvertTo-Json -Depth 6
$keyJson = $ref | ConvertTo-Json

New-Item -ItemType Directory -Path $OutDir | Out-Null
Set-Content -LiteralPath (Join-Path $OutDir 'findings-admin.csv') -Value $adminCsv -Encoding utf8
Set-Content -LiteralPath (Join-Path $OutDir 'findings-summary.json') -Value $summaryJson -Encoding utf8
Set-Content -LiteralPath (Join-Path $OutDir 'key.local.json') -Value $keyJson -Encoding utf8

$counts = ($summaryRules | ForEach-Object { '{0} {1}' -f $_.id, $_.count }) -join ' | '
Write-Output ('users {0} | {1} | reclaimable (synthetic units) {2} | people flagged {3}' -f $users.Count, $counts, $reclaim.ToString($inv), $ref.Count)
