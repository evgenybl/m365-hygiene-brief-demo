#requires -Version 7.4
<#
.SYNOPSIS
    Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.
    Reads a Microsoft 365 tenant through Microsoft Graph, with GET requests only, and writes the three input tables of
    Get-TenantHygieneFindings.ps1.

.DESCRIPTION
    It makes GET requests to a fixed list of five paths, written from Microsoft's documentation pages (named, with the
    permission and the licence each needs, in docs/COLLECTOR.md), and to the next-page links those answers return:
      users         /v1.0/users with $select (signInActivity included) and $top=500
      licences      /v1.0/subscribedSkus with $select
      roles         /v1.0/roleManagement/directory/roleAssignments, filtered on the Global Administrator role
                    (62e90394-69f5-4237-9190-012177145e10), with $expand=principal
      registration  /v1.0/reports/authenticationMethods/userRegistrationDetails
      policies      /v1.0/identity/conditionalAccess/policies
    It sends nothing else and holds no command that changes a tenant.

    The access token is read from the GRAPH_ACCESS_TOKEN environment variable, never from a parameter; it is never
    printed or written. -GraphBase may be https://graph.microsoft.com or a server on this computer (127.0.0.1 or
    localhost, for the tests); any other address is refused, so the token cannot be sent elsewhere.

    Paging: each @odata.nextLink is followed as a whole, as the documentation says, but only when it points to the
    same host and the same path as the request it came from; otherwise the run stops. Throttling: an answer 429 is
    waited for (Retry-After seconds, or 1, 2, 4 ... seconds without that header) and tried again, at most -MaxRetries
    times, and never longer than -MaxWaitSeconds at once. Any other answer that is not a success stops the run (exit
    3). Everything is held in memory until every request has succeeded, so a stop writes nothing.

    It writes users.csv, skus.csv (the licence names; the cost column is left empty for the administrator to fill in
    with their own units), policies.csv and snapshot-report.json into a new folder.

    Mapping choices, each stated in docs/COLLECTOR.md: the last sign-in is signInActivity.lastSuccessfulSignInDateTime
    (successful sign-ins only); a user missing from the registration report (the documentation says it does not list
    disabled users) is written as MFA not registered; IsAdmin comes from the report's isAdmin or from holding Global
    Administrator; a user with no createdDateTime (the documentation says this happens for some users created before
    June 2018) is written as created on 2018-06-01, and counted in the report.

.EXAMPLE
    pwsh -File Export-TenantSnapshot.ps1 -OutDir <new folder>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutDir,
    [string] $GraphBase = 'https://graph.microsoft.com',
    [ValidateRange(0, 10)] [int] $MaxRetries = 3,
    [ValidateRange(1, 600)] [int] $MaxWaitSeconds = 120
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

$GlobalAdministratorRoleId = '62e90394-69f5-4237-9190-012177145e10'
# The only paths this script requests. Every request it sends is a GET to one of these, or to a next-page link with
# the same host and path.
$Paths = [ordered]@{
    users        = '/v1.0/users?$select=id,userPrincipalName,displayName,department,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity&$top=500'
    licences     = '/v1.0/subscribedSkus?$select=skuId,skuPartNumber'
    roles        = "/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId%20eq%20'$GlobalAdministratorRoleId'&`$expand=principal"
    registration = '/v1.0/reports/authenticationMethods/userRegistrationDetails'
    policies     = '/v1.0/identity/conditionalAccess/policies'
}

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }
$base = $GraphBase.TrimEnd('/')
if ($base -cne 'https://graph.microsoft.com' -and $base -notmatch '^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$') {
    Stop-Refused 'GraphBase must be https://graph.microsoft.com, or http://127.0.0.1:<port> for a local test server'
}
$token = $env:GRAPH_ACCESS_TOKEN
if (-not $token) { Stop-Refused 'no access token in the GRAPH_ACCESS_TOKEN environment variable' }
$baseUri = [uri]$base

$script:requestCount = 0
$script:waits = 0
function Get-GraphCollection([string] $Name) {
    $url = $base + $Paths[$Name]
    $path = ([uri]$url).AbsolutePath
    $items = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    while ($url) {
        $pages++
        if ($pages -gt 1000) { Stop-Refused "GET $Name returned more than 1000 pages; nothing was written" 3 }
        $try = 0
        while ($true) {
            $script:requestCount++
            $status = 0; $headers = $null
            try {
                $resp = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck -MaximumRedirection 0 `
                    -StatusCodeVariable status -ResponseHeadersVariable headers -TimeoutSec 100
            } catch {
                Stop-Refused "GET $Name failed: $($_.Exception.Message); nothing was written" 3
            }
            if ($status -ne 429) { break }
            $try++
            if ($try -gt $MaxRetries) { Stop-Refused "GET $Name was still throttled after $MaxRetries retries; nothing was written" 3 }
            $after = if ($headers -and $headers['Retry-After']) { [string]@($headers['Retry-After'])[0] } else { '' }
            $wait = if ($after -match '^[0-9]{1,6}$') { [int]$after } else { [int][math]::Pow(2, $try - 1) }
            if ($wait -gt $MaxWaitSeconds) { Stop-Refused "GET $Name asked for a wait of $wait seconds, above -MaxWaitSeconds; nothing was written" 3 }
            $script:waits++
            Start-Sleep -Seconds $wait
        }
        if ($status -lt 200 -or $status -gt 299) { Stop-Refused "GET $Name answered HTTP $status; nothing was written" 3 }
        foreach ($v in @(Get-Field $resp 'value')) { if ($null -ne $v) { $items.Add($v) } }
        $next = Get-Field $resp '@odata.nextLink'
        $url = $null
        if ($next) {
            $n = $null
            if (-not [uri]::TryCreate([string]$next, [UriKind]::Absolute, [ref]$n) -or $n.Scheme -ne $baseUri.Scheme -or
                $n.Authority -ne $baseUri.Authority -or $n.AbsolutePath -ne $path) {
                Stop-Refused "GET $Name returned a next-page link outside the fixed list; nothing was written" 3
            }
            $url = [string]$next
        }
    }
    [pscustomobject]@{ Items = $items.ToArray(); Pages = $pages }
}

# A timestamp as Graph sends it, written as UTC to the second; empty for no value and for 0001-01-01.
function ConvertTo-Stamp($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { $u = if ($Value.Kind -eq 'Unspecified') { [datetime]::SpecifyKind($Value, 'Utc') } else { $Value.ToUniversalTime() } }
    elseif ($Value -is [datetimeoffset]) { $u = $Value.UtcDateTime }
    else {
        $s = [string]$Value
        if (-not $s) { return '' }
        $o = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($s, $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$o)) { return '' }
        $u = $o.UtcDateTime
    }
    if ($u.Year -le 1) { return '' }
    $u.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv)
}
function Join-List($Value) { (@($Value) | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ }) -join ';' }
function Get-Bool($Value) { if ($Value -eq $true) { 'true' } else { 'false' } }

$got = [ordered]@{}
foreach ($k in $Paths.Keys) { $got[$k] = Get-GraphCollection $k }

$skuName = @{}
foreach ($s in $got.licences.Items) { $skuName[[string](Get-Field $s 'skuId')] = [string](Get-Field $s 'skuPartNumber') }
$registration = @{}
foreach ($r in $got.registration.Items) { $registration[[string](Get-Field $r 'id')] = $r }
$globalAdmins = @{}
$nonUserHolders = 0
foreach ($a in $got.roles.Items) {
    $p = Get-Field $a 'principal'
    if ($p -and (Get-Field $p '@odata.type') -eq '#microsoft.graph.user') { $globalAdmins[[string](Get-Field $a 'principalId')] = $true } else { $nonUserHolders++ }
}

$noCreated = 0; $notInReport = 0
$users = @(foreach ($u in $got.users.Items) {
    $id = [string](Get-Field $u 'id')
    $reg = if ($registration.ContainsKey($id)) { $registration[$id] } else { $notInReport++; $null }
    $isGa = $globalAdmins.ContainsKey($id)
    $created = ConvertTo-Stamp (Get-Field $u 'createdDateTime')
    if (-not $created) { $noCreated++; $created = '2018-06-01' }
    $licences = @(@(Get-Field $u 'assignedLicenses') | Where-Object { $_ } | ForEach-Object {
        $sku = [string](Get-Field $_ 'skuId'); if ($skuName.ContainsKey($sku) -and $skuName[$sku]) { $skuName[$sku] } else { $sku } })
    [ordered]@{
        UserPrincipalName = Get-Field $u 'userPrincipalName'; DisplayName = Get-Field $u 'displayName'; Department = Get-Field $u 'department'
        UserType = Get-Field $u 'userType'; AccountEnabled = Get-Bool (Get-Field $u 'accountEnabled')
        IsAdmin = Get-Bool ($isGa -or ($reg -and (Get-Field $reg 'isAdmin') -eq $true))
        MfaRegistered = Get-Bool ($reg -and (Get-Field $reg 'isMfaRegistered') -eq $true)
        CreatedDate = $created; LastSignInDate = (ConvertTo-Stamp (Get-Field (Get-Field $u 'signInActivity') 'lastSuccessfulSignInDateTime'))
        AssignedLicenses = ($licences -join ';'); AdminRoles = $(if ($isGa) { 'Global Administrator' } else { '' })
    }
})
$other = @('userRiskLevels', 'signInRiskLevels', 'servicePrincipalRiskLevels', 'insiderRiskLevels', 'platforms', 'locations', 'devices',
    'clientApplications', 'authenticationFlows')
$policies = @(foreach ($p in $got.policies.Items) {
    $c = Get-Field $p 'conditions'
    $set = @($other | Where-Object { $v = Get-Field $c $_; $null -ne $v -and @($v | Where-Object { $null -ne $_ -and "$_" -ne '' }).Count -gt 0 })
    [ordered]@{
        PolicyId = Get-Field $p 'id'; DisplayName = Get-Field $p 'displayName'; State = Get-Field $p 'state'
        CreatedDate = (ConvertTo-Stamp (Get-Field $p 'createdDateTime')); ClientAppTypes = Join-List (Get-Field $c 'clientAppTypes')
        IncludeUsers = Join-List (Get-Field (Get-Field $c 'users') 'includeUsers')
        IncludeApplications = Join-List (Get-Field (Get-Field $c 'applications') 'includeApplications')
        GrantControls = Join-List (Get-Field (Get-Field $p 'grantControls') 'builtInControls'); OtherConditions = ($set -join ';')
    }
})
$skus = @(foreach ($s in $got.licences.Items) { [ordered]@{ SkuPartNumber = Get-Field $s 'skuPartNumber'; MonthlyCostSynthetic = '' } })

$report = [ordered]@{
    label = 'Mock: written from Microsoft''s documentation, tested against a local mock, never run against a tenant'
    requests = @($Paths.Keys | ForEach-Object { [ordered]@{ name = $_; method = 'GET'; path = $Paths[$_]; pages = $got[$_].Pages } })
    users = @($users).Count; licences = @($skus).Count; policies = @($policies).Count
    global_administrator_holders_that_are_not_users = $nonUserHolders
    users_not_in_the_registration_report = $notInReport
    users_without_created_date_written_as_2018_06_01 = $noCreated
    throttled_waits = $script:waits
}

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'users.csv') (ConvertTo-CsvText @($users) @('UserPrincipalName', 'DisplayName', 'Department', 'UserType',
    'AccountEnabled', 'IsAdmin', 'MfaRegistered', 'CreatedDate', 'LastSignInDate', 'AssignedLicenses', 'AdminRoles'))
Write-TextFile (Join-Path $OutDir 'skus.csv') (ConvertTo-CsvText @($skus) @('SkuPartNumber', 'MonthlyCostSynthetic'))
Write-TextFile (Join-Path $OutDir 'policies.csv') (ConvertTo-CsvText @($policies) @('PolicyId', 'DisplayName', 'State', 'CreatedDate',
    'ClientAppTypes', 'IncludeUsers', 'IncludeApplications', 'GrantControls', 'OtherConditions'))
Write-TextFile (Join-Path $OutDir 'snapshot-report.json') ((ConvertTo-JsonText $report) + "`n")
Write-Output ('snapshot users {0} | licences {1} | policies {2} | GET requests {3} | throttled waits {4} | Mock: never run against a tenant' -f
    @($users).Count, @($skus).Count, @($policies).Count, $script:requestCount, $script:waits)
