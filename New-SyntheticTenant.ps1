#requires -Version 7.4
<#
.SYNOPSIS
    Writes an invented Microsoft 365 tenant: a users table, a licence table and a Conditional Access policy table.

.DESCRIPTION
    Every account is invented, at demo.example.com, and every display name is marked "(synthetic)". The licence names
    and their costs are invented too: the costs are units made up for the demo, not prices and not money.

    The same seed, as-of date and account count give the same bytes on every machine and every PowerShell version: the
    random choices come from a small generator written here (a 32-bit linear congruential generator, integer
    arithmetic only), not from Get-Random or System.Random, and every file is written with LF line ends.

    The tenant is built so that every rule of Get-TenantHygieneFindings.ps1 fires at least once and each boundary case
    is present: a sign-in exactly 90 days before the as-of date and one 91 days before (also as timestamps near
    midnight UTC and with an offset), members and guests created 30 and 31 days before who never signed in, an account
    6 days old, five accounts holding Global Administrator, an administrator without MFA who is disabled, and policies
    in report-only mode created 30 and 31 days before. The other accounts are drawn by the generator.

    It writes four files into a new folder: users.synthetic.csv, skus.synthetic.csv, policies.synthetic.csv, and
    tenant-source.txt, which names the command that wrote them.

.EXAMPLE
    pwsh -File New-SyntheticTenant.ps1 -Seed 2026 -AsOf 2026-11-21 -OutDir <new folder>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateRange(0, 2147483647)] [int] $Seed,
    [Parameter(Mandatory)] [string] $AsOf,
    [Parameter(Mandatory)] [string] $OutDir,
    [ValidateRange(40, 500)] [int] $Accounts = 60
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }
$day0 = [datetime]::MinValue
if (-not ($AsOf -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($AsOf, 'yyyy-MM-dd', $inv, 'None', [ref]$day0))) {
    Stop-Refused 'AsOf must be a date written yyyy-MM-dd'
}

# The generator: state' = (1664525 * state + 1013904223) mod 2^32; a draw is the top 16 bits of the state.
$script:state = [long]$Seed % 4294967296L
function Get-Draw { $script:state = (1664525L * $script:state + 1013904223L) % 4294967296L; [int]($script:state -shr 16) }
function Get-Pick([int] $n) { (Get-Draw) % $n }
function Get-Range([int] $lo, [int] $hi) { $lo + (Get-Pick ($hi - $lo + 1)) }

function Get-Day([int] $daysBefore) { $day0.AddDays(-$daysBefore).ToString('yyyy-MM-dd', $inv) }
function Get-Stamp([int] $daysBefore, [string] $time) { $day0.AddDays(-$daysBefore).ToString('yyyy-MM-dd', $inv) + 'T' + $time }

$skus = @(
    [ordered]@{ SkuPartNumber = 'SYN_SUITE_PLUS'; MonthlyCostSynthetic = '21.40' }
    [ordered]@{ SkuPartNumber = 'SYN_SUITE_STANDARD'; MonthlyCostSynthetic = '12.70' }
    [ordered]@{ SkuPartNumber = 'SYN_SUITE_BASIC'; MonthlyCostSynthetic = '6.10' }
    [ordered]@{ SkuPartNumber = 'SYN_DIAGRAMS_ADDON'; MonthlyCostSynthetic = '9.35' }
)
$first = @('Adi', 'Amir', 'Bina', 'Dor', 'Eden', 'Gali', 'Hadar', 'Ido', 'Inbar', 'Lia', 'Maor', 'Neta', 'Ofir', 'Roni',
    'Shai', 'Tamar', 'Yael', 'Ziv', 'Noam', 'Keren', 'Itai', 'Sivan', 'Omri', 'Rotem')
$last = @('Alef', 'Bet', 'Gimel', 'Dalet', 'He', 'Vav', 'Zayin', 'Het', 'Tet', 'Yod', 'Kaf', 'Lamed', 'Mem', 'Nun',
    'Samekh', 'Ayin', 'Pe', 'Tsadi', 'Qof', 'Resh', 'Shin', 'Tav')
$departments = @('Finance', 'Sales', 'IT', 'Operations', 'Management', 'Marketing', 'Support', 'Legal')

$taken = @{}
function New-Person([bool] $Guest) {
    for ($try = 0; $try -lt 1000; $try++) {
        $f = $first[(Get-Pick $first.Count)]; $l = $last[(Get-Pick $last.Count)]
        $local = ('{0}.{1}' -f $f, $l).ToLowerInvariant()
        $upn = if ($Guest) { '{0}_partner.example.com#EXT#@demo.example.com' -f $local } else { '{0}@demo.example.com' -f $local }
        if (-not $taken.ContainsKey($upn)) {
            $taken[$upn] = $true
            return [pscustomobject]@{ Upn = $upn; Name = ('{0} {1} ({2})' -f $f, $l, $(if ($Guest) { 'synthetic guest' } else { 'synthetic' })) }
        }
    }
    throw 'the name pools are too small for this many accounts'
}
function New-Account([string] $Department, [string] $Type, [bool] $Enabled, [string[]] $Roles, [bool] $Mfa, [int] $CreatedBefore,
    [string] $LastSignIn, [string[]] $Licenses) {
    $p = New-Person ($Type -eq 'Guest')
    [ordered]@{
        UserPrincipalName = $p.Upn; DisplayName = $p.Name; Department = $Department; UserType = $Type
        AccountEnabled = $(if ($Enabled) { 'True' } else { 'False' }); IsAdmin = $(if (@($Roles).Count) { 'True' } else { 'False' })
        MfaRegistered = $(if ($Mfa) { 'True' } else { 'False' }); CreatedDate = (Get-Day $CreatedBefore); LastSignInDate = $LastSignIn
        AssignedLicenses = (@($Licenses) -join ';'); AdminRoles = (@($Roles) -join ';')
    }
}

$ga = @('Global Administrator')
$planted = @(
    # Five holders of Global Administrator (R6, limit 4); one without MFA (R3); one disabled, without MFA and licensed (R3, R2).
    New-Account 'IT' 'Member' $true $ga $true 1500 (Get-Day 1) @('SYN_SUITE_PLUS')
    New-Account 'IT' 'Member' $true $ga $false 900 (Get-Day 2) @('SYN_SUITE_PLUS')
    New-Account 'Management' 'Member' $true $ga $true 2000 (Get-Day 5) @('SYN_SUITE_PLUS')
    New-Account 'Operations' 'Member' $false $ga $false 1200 (Get-Day 200) @('SYN_SUITE_PLUS')
    New-Account 'IT' 'Member' $true $ga $true 800 (Get-Day 60) @()
    # Other administrators: one without MFA (R3), one with.
    New-Account 'Support' 'Member' $true @('User Administrator') $false 400 (Get-Day 3) @('SYN_SUITE_STANDARD')
    New-Account 'IT' 'Member' $true @('Exchange Administrator') $true 600 (Get-Day 10) @('SYN_SUITE_STANDARD')
    # R1 boundary: 90 days is not stale, 91 days is; timestamps count by their UTC date.
    New-Account 'Sales' 'Member' $true @() $true 700 (Get-Day 90) @('SYN_SUITE_STANDARD')
    New-Account 'Sales' 'Member' $true @() $true 700 (Get-Day 91) @('SYN_SUITE_STANDARD')
    New-Account 'Marketing' 'Member' $true @() $true 700 (Get-Stamp 91 '23:59:59Z') @('SYN_SUITE_PLUS', 'SYN_DIAGRAMS_ADDON')
    New-Account 'Finance' 'Member' $true @() $true 700 (Get-Stamp 90 '00:00:01Z') @('SYN_SUITE_STANDARD')
    New-Account 'Support' 'Member' $true @() $true 700 (Get-Stamp 90 '01:30:00+02:00') @('SYN_SUITE_BASIC')
    # R2: disabled and licensed; a disabled account with no licence is not a finding.
    New-Account 'Legal' 'Member' $false @() $true 900 (Get-Day 150) @('SYN_SUITE_STANDARD')
    New-Account 'Sales' 'Member' $false @() $true 900 (Get-Day 300) @()
    # R5 boundary: created 30 days ago and never signed in is not flagged, 31 days is; an account 6 days old is not.
    New-Account 'Operations' 'Member' $true @() $false 30 '' @('SYN_SUITE_BASIC')
    New-Account 'Finance' 'Member' $true @() $false 31 '' @('SYN_SUITE_BASIC')
    New-Account 'Marketing' 'Member' $true @() $false 6 '' @('SYN_SUITE_STANDARD')
    # R4: guests invited 1 and 30 days ago with no sign-in are not flagged, 31 days ago is; a stale guest is; a guest
    # who signed in recently is not; a disabled stale guest is not.
    New-Account '' 'Guest' $true @() $false 1 '' @()
    New-Account '' 'Guest' $true @() $false 30 '' @()
    New-Account '' 'Guest' $true @() $false 31 '' @()
    New-Account '' 'Guest' $true @() $false 300 (Get-Day 120) @()
    New-Account '' 'Guest' $true @() $true 300 (Get-Day 10) @()
    New-Account '' 'Guest' $false @() $false 400 (Get-Day 200) @()
)

$all = [System.Collections.Generic.List[object]]::new()
foreach ($a in $planted) { $all.Add($a) }
while ($all.Count -lt $Accounts) {
    $dept = $departments[(Get-Pick $departments.Count)]
    $lic = @(switch (Get-Pick 10) { { $_ -lt 3 } { 'SYN_SUITE_PLUS' } { $_ -ge 3 -and $_ -lt 8 } { 'SYN_SUITE_STANDARD' } default { 'SYN_SUITE_BASIC' } })
    if ((Get-Pick 8) -eq 0) { $lic += 'SYN_DIAGRAMS_ADDON' }
    $signIn = if ((Get-Pick 10) -eq 0) { Get-Day (Get-Range 100 400) } else { Get-Day (Get-Range 0 80) }
    $all.Add((New-Account $dept 'Member' $true @() ((Get-Pick 100) -lt 85) (Get-Range 100 2000) $signIn $lic))
}
# A shuffle (Fisher-Yates) with the same generator, so the planted rows do not sit together.
for ($i = $all.Count - 1; $i -gt 0; $i--) { $j = Get-Pick ($i + 1); $t = $all[$i]; $all[$i] = $all[$j]; $all[$j] = $t }

$pid0 = '00000000-0000-4000-8000-0000000000'
$policies = @(
    [ordered]@{ PolicyId = "${pid0}01"; DisplayName = 'Require MFA for administrators (synthetic)'; State = 'enabled'
        CreatedDate = (Get-Stamp 420 '09:00:00Z'); ClientAppTypes = 'all'; IncludeUsers = ''; IncludeApplications = 'All'; GrantControls = 'mfa'; OtherConditions = '' }
    [ordered]@{ PolicyId = "${pid0}02"; DisplayName = 'Block legacy authentication (synthetic)'; State = 'enabledForReportingButNotEnforced'
        CreatedDate = (Get-Stamp 45 '10:15:00Z'); ClientAppTypes = 'exchangeActiveSync;other'; IncludeUsers = 'All'; IncludeApplications = 'All'; GrantControls = 'block'; OtherConditions = '' }
    [ordered]@{ PolicyId = "${pid0}03"; DisplayName = 'Require a compliant device for Finance (synthetic)'; State = 'enabledForReportingButNotEnforced'
        CreatedDate = (Get-Stamp 30 '23:00:00Z'); ClientAppTypes = 'all'; IncludeUsers = ''; IncludeApplications = 'All'; GrantControls = 'compliantDevice'; OtherConditions = '' }
    [ordered]@{ PolicyId = "${pid0}04"; DisplayName = 'Terms of use for guests (synthetic)'; State = 'enabledForReportingButNotEnforced'
        CreatedDate = (Get-Stamp 31 '07:00:00Z'); ClientAppTypes = 'all'; IncludeUsers = 'GuestsOrExternalUsers'; IncludeApplications = 'All'; GrantControls = 'mfa'; OtherConditions = '' }
    [ordered]@{ PolicyId = "${pid0}05"; DisplayName = 'Old pilot: block legacy authentication for IT (synthetic)'; State = 'disabled'
        CreatedDate = (Get-Stamp 700 '12:00:00Z'); ClientAppTypes = 'exchangeActiveSync;other'; IncludeUsers = ''; IncludeApplications = 'All'; GrantControls = 'block'; OtherConditions = '' }
    [ordered]@{ PolicyId = "${pid0}06"; DisplayName = 'Block sign-in for high-risk users (synthetic)'; State = 'enabled'
        CreatedDate = (Get-Stamp 300 '08:30:00Z'); ClientAppTypes = 'exchangeActiveSync;other'; IncludeUsers = 'All'; IncludeApplications = 'All'; GrantControls = 'block'; OtherConditions = 'userRiskLevels' }
)

$userColumns = @('UserPrincipalName', 'DisplayName', 'Department', 'UserType', 'AccountEnabled', 'IsAdmin', 'MfaRegistered', 'CreatedDate',
    'LastSignInDate', 'AssignedLicenses', 'AdminRoles')
$policyColumns = @('PolicyId', 'DisplayName', 'State', 'CreatedDate', 'ClientAppTypes', 'IncludeUsers', 'IncludeApplications', 'GrantControls', 'OtherConditions')
$usersText = ConvertTo-CsvText $all.ToArray() $userColumns
$skusText = ConvertTo-CsvText $skus @('SkuPartNumber', 'MonthlyCostSynthetic')
$policiesText = ConvertTo-CsvText $policies $policyColumns
$source = 'Written by New-SyntheticTenant.ps1 -Seed {0} -AsOf {1} -Accounts {2}' -f $Seed, $AsOf, $Accounts

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'users.synthetic.csv') $usersText
Write-TextFile (Join-Path $OutDir 'skus.synthetic.csv') $skusText
Write-TextFile (Join-Path $OutDir 'policies.synthetic.csv') $policiesText
Write-LineFile (Join-Path $OutDir 'tenant-source.txt') @($source)
Write-Output ('accounts {0} | licences {1} | policies {2} | seed {3} | as of {4}' -f $all.Count, $skus.Count, $policies.Count, $Seed, $AsOf)
