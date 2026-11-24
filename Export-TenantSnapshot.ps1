#requires -Version 7.4
<#
.SYNOPSIS
    Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.
    Reads a Microsoft 365 tenant through Microsoft Graph, with GET requests only, and writes the four input tables of
    Get-TenantHygieneFindings.ps1.

.DESCRIPTION
    It makes GET requests to a fixed list of six paths, written from Microsoft's documentation pages (named, with the
    permission, the Microsoft Entra roles and the licence each needs, in docs/COLLECTOR.md), and to the next-page links
    those answers return:
      users             /v1.0/users with $select (signInActivity included) and $top=500
      licences          /v1.0/subscribedSkus with $select
      roles             /v1.0/roleManagement/directory/roleAssignments, filtered on the Global Administrator role
                        (62e90394-69f5-4237-9190-012177145e10), with $expand=principal
      registration      /v1.0/reports/authenticationMethods/userRegistrationDetails
      policies          /v1.0/identity/conditionalAccess/policies
      securityDefaults  /v1.0/policies/identitySecurityDefaultsEnforcementPolicy (one object: isEnabled)
    It sends nothing else and holds no command that changes a tenant.

    The access token is read from the GRAPH_ACCESS_TOKEN environment variable, never from a parameter; it is never
    printed or written, with -Debug and -Verbose too: every web call is made with both switched off. -GraphBase may be
    https://graph.microsoft.com or a server on this computer (127.0.0.1 or localhost, for the tests); any other address
    is refused, so the token cannot be sent elsewhere.

    Each answer must have the shape the documentation shows: a collection page is a JSON object with a "value" array,
    and the security defaults answer a JSON object with a true or false "isEnabled". Anything else (an HTML page, an
    error object, an empty body) stops the run (exit 3). Paging: each @odata.nextLink is followed as a whole, as the
    documentation says, but only when it points to the same scheme, host and path as the request it came from;
    otherwise the run stops. Throttling: an answer 429 is waited for and tried again, at most -MaxRetries times: for
    Retry-After seconds, or 1, 2, 4 ... seconds without that header. A Retry-After that is not a whole number of
    seconds, or that asks for more than -MaxWaitSeconds, stops the run at once and says so. Any other answer that is not
    a success stops the run (exit 3). Everything is held in memory until every request has succeeded, so a stop
    writes nothing.

    It writes users.csv, skus.csv (the licence names; the cost column is left empty for the administrator to fill in
    with their own units), policies.csv, tenant.csv and snapshot-report.json into a new folder.

    Mapping choices, each stated in docs/COLLECTOR.md: the last sign-in is signInActivity.lastSuccessfulSignInDateTime
    (successful sign-ins only, not backfilled before 1 December 2023); a user missing from the registration report (the
    documentation says it does not list disabled users) is written as MFA not registered, and step 1's R3 judges enabled
    administrators only for that reason; IsAdmin comes from the report's isAdmin or from holding Global Administrator; a
    user or a policy with no createdDateTime (the documentation says this happens for some users created before June
    2018) gets an empty cell, never an invented date, and the report counts such users. Step 1 then refuses a user row
    with no creation date, by its row number, so that a person supplies it; a report-only policy with none is reported
    by R8 as of unknown age. A policy's excluded applications and its application filter are written in their own
    columns, because a policy that excludes a resource does not cover all resources.

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
# -Debug and -Verbose would print each request's headers, the token among them: they are switched off for this script,
# and every web call below is made with -Debug:$false -Verbose:$false as well.
$DebugPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

$GlobalAdministratorRoleId = '62e90394-69f5-4237-9190-012177145e10'
# The only paths this script requests. Every request it sends is a GET to one of these, or to a next-page link with
# the same scheme, host and path.
$Paths = [ordered]@{
    users            = '/v1.0/users?$select=id,userPrincipalName,displayName,department,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity&$top=500'
    licences         = '/v1.0/subscribedSkus?$select=skuId,skuPartNumber'
    roles            = "/v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId%20eq%20'$GlobalAdministratorRoleId'&`$expand=principal"
    registration     = '/v1.0/reports/authenticationMethods/userRegistrationDetails'
    policies         = '/v1.0/identity/conditionalAccess/policies'
    securityDefaults = '/v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
}
$Collections = @('users', 'licences', 'roles', 'registration', 'policies')

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }
$base = $GraphBase.TrimEnd('/')
if ($base -cne 'https://graph.microsoft.com' -and $base -notmatch '^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$') {
    Stop-Refused 'GraphBase must be https://graph.microsoft.com, or http://127.0.0.1:<port> for a local test server'
}
$token = $env:GRAPH_ACCESS_TOKEN
if (-not $token) { Stop-Refused 'no access token in the GRAPH_ACCESS_TOKEN environment variable' }

$script:requestCount = 0
$script:waits = 0
# One GET, with the throttling loop. Returns the parsed answer of a success; stops the run on anything else.
function Invoke-GraphGet([string] $Name, [string] $Url) {
    $try = 0
    while ($true) {
        $script:requestCount++
        $status = 0; $headers = $null
        try {
            $resp = Invoke-RestMethod -Method Get -Uri $Url -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck -MaximumRedirection 0 `
                -StatusCodeVariable status -ResponseHeadersVariable headers -TimeoutSec 100 -Debug:$false -Verbose:$false
        } catch {
            Stop-Refused "GET $Name failed: $($_.Exception.Message.Replace($token, '[token]')); nothing was written" 3
        }
        if ($status -ne 429) { break }
        $try++
        if ($try -gt $MaxRetries) { Stop-Refused "GET $Name was still throttled after $MaxRetries retries; nothing was written" 3 }
        $after = if ($headers -and $headers.ContainsKey('Retry-After')) { [string]@($headers['Retry-After'])[0] } else { $null }
        if ($null -eq $after) {
            $wait = [long][math]::Pow(2, $try - 1)
        } elseif ($after.Trim() -match '^[0-9]{1,18}$') {
            $wait = [long]$after.Trim()
        } else {
            Stop-Refused "GET $Name was throttled with a Retry-After the collector cannot read as a number of seconds; nothing was written" 3
        }
        if ($wait -gt $MaxWaitSeconds) { Stop-Refused "GET $Name asked for a wait of $wait seconds, above -MaxWaitSeconds ($MaxWaitSeconds); nothing was written" 3 }
        $script:waits++
        Start-Sleep -Seconds $wait
    }
    if ($status -lt 200 -or $status -gt 299) { Stop-Refused "GET $Name answered HTTP $status; nothing was written" 3 }
    $resp
}

# A JSON object, as Invoke-RestMethod parses one: anything else (a string, an empty body) is not.
function Test-JsonObject($Value) { $null -ne $Value -and $Value -is [System.Management.Automation.PSCustomObject] }

function Get-GraphObject([string] $Name) {
    $resp = Invoke-GraphGet $Name ($base + $Paths[$Name])
    if (-not (Test-JsonObject $resp)) { Stop-Refused "GET $Name answered with something that is not a JSON object; nothing was written" 3 }
    $resp
}

function Get-GraphCollection([string] $Name) {
    $url = $base + $Paths[$Name]
    $first = [uri]$url
    $items = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    while ($url) {
        $pages++
        if ($pages -gt 1000) { Stop-Refused "GET $Name returned more than 1000 pages; nothing was written" 3 }
        $resp = Invoke-GraphGet $Name $url
        # A page is a JSON object with a "value" array, as the documentation shows; an HTML page, an error object or
        # an empty body is not, and stops the run rather than pass for an empty collection.
        $prop = if (Test-JsonObject $resp) { $resp.PSObject.Properties['value'] } else { $null }
        if ($null -eq $prop -or $prop.Value -isnot [array]) {
            Stop-Refused "GET $Name answered with something that is not a collection page (a JSON object with a value array); nothing was written" 3
        }
        foreach ($v in $prop.Value) { if ($null -ne $v) { $items.Add($v) } }
        $next = Get-Field $resp '@odata.nextLink'
        $url = $null
        if ($next) {
            $n = $null
            if (-not [uri]::TryCreate([string]$next, [UriKind]::Absolute, [ref]$n) -or $n.Scheme -cne $first.Scheme -or
                $n.Authority -cne $first.Authority -or $n.AbsolutePath -cne $first.AbsolutePath -or $n.UserInfo) {
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
foreach ($k in $Collections) { $got[$k] = Get-GraphCollection $k }
$sd = Get-GraphObject 'securityDefaults'
$sdProp = $sd.PSObject.Properties['isEnabled']
if ($null -eq $sdProp -or $sdProp.Value -isnot [bool]) {
    Stop-Refused 'GET securityDefaults answered without a true or false isEnabled; nothing was written' 3
}
$securityDefaultsEnabled = [bool]$sdProp.Value

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
    if (-not $created) { $noCreated++ }
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
    $apps = Get-Field $c 'applications'
    $filter = Get-Field $apps 'applicationFilter'
    [ordered]@{
        PolicyId = Get-Field $p 'id'; DisplayName = Get-Field $p 'displayName'; State = Get-Field $p 'state'
        CreatedDate = (ConvertTo-Stamp (Get-Field $p 'createdDateTime')); ClientAppTypes = Join-List (Get-Field $c 'clientAppTypes')
        IncludeUsers = Join-List (Get-Field (Get-Field $c 'users') 'includeUsers')
        IncludeApplications = Join-List (Get-Field $apps 'includeApplications')
        ExcludeApplications = Join-List (Get-Field $apps 'excludeApplications')
        ApplicationFilter = $(if ($filter) { '{0}: {1}' -f (Get-Field $filter 'mode'), (Get-Field $filter 'rule') } else { '' })
        GrantControls = Join-List (Get-Field (Get-Field $p 'grantControls') 'builtInControls'); OtherConditions = ($set -join ';')
    }
})
$skus = @(foreach ($s in $got.licences.Items) { [ordered]@{ SkuPartNumber = Get-Field $s 'skuPartNumber'; MonthlyCostSynthetic = '' } })
$tenant = @([ordered]@{ SecurityDefaultsEnabled = $(if ($securityDefaultsEnabled) { 'true' } else { 'false' }) })

$report = [ordered]@{
    label = 'Mock: written from Microsoft''s documentation, tested against a local mock, never run against a tenant'
    requests = @($Paths.Keys | ForEach-Object { [ordered]@{ name = $_; method = 'GET'; path = $Paths[$_]
        pages = $(if ($got.Contains($_)) { $got[$_].Pages } else { 1 }) } })
    users = @($users).Count; licences = @($skus).Count; policies = @($policies).Count
    security_defaults_enabled = $securityDefaultsEnabled
    global_administrator_holders_that_are_not_users = $nonUserHolders
    users_not_in_the_registration_report = $notInReport
    users_without_created_date_left_empty = $noCreated
    throttled_waits = $script:waits
}

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'users.csv') (ConvertTo-CsvText @($users) @('UserPrincipalName', 'DisplayName', 'Department', 'UserType',
    'AccountEnabled', 'IsAdmin', 'MfaRegistered', 'CreatedDate', 'LastSignInDate', 'AssignedLicenses', 'AdminRoles'))
Write-TextFile (Join-Path $OutDir 'skus.csv') (ConvertTo-CsvText @($skus) @('SkuPartNumber', 'MonthlyCostSynthetic'))
Write-TextFile (Join-Path $OutDir 'policies.csv') (ConvertTo-CsvText @($policies) @('PolicyId', 'DisplayName', 'State', 'CreatedDate',
    'ClientAppTypes', 'IncludeUsers', 'IncludeApplications', 'ExcludeApplications', 'ApplicationFilter', 'GrantControls', 'OtherConditions'))
Write-TextFile (Join-Path $OutDir 'tenant.csv') (ConvertTo-CsvText @($tenant) @('SecurityDefaultsEnabled'))
Write-TextFile (Join-Path $OutDir 'snapshot-report.json') ((ConvertTo-JsonText $report) + "`n")
Write-Output ('snapshot users {0} | licences {1} | policies {2} | security defaults {3} | GET requests {4} | throttled waits {5} | Mock: never run against a tenant' -f
    @($users).Count, @($skus).Count, @($policies).Count, $(if ($securityDefaultsEnabled) { 'on' } else { 'off' }), $script:requestCount, $script:waits)
