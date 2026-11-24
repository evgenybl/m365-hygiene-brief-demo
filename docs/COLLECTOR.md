# The collector: Export-TenantSnapshot.ps1

**Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.**

The collector reads a Microsoft 365 tenant through Microsoft Graph and writes the three tables that
`Get-TenantHygieneFindings.ps1` reads: users, licences and Conditional Access policies. It makes GET requests only, to the
five paths below and to the next-page links those answers return, and holds no command that changes a tenant. Every path,
query and property name here was copied from Microsoft's documentation pages, read on 24 November 2026; each page's own
"updated" date is given as the page states it. Where a page does not settle something, this file says so.

It has been run only against the local mock in `mock/graph/`, whose answers follow the shapes in the examples on these
pages, with invented accounts. What a first real run would have to check is listed at the end.

## The five requests

### 1. Users, with their last sign-in

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0 (updated 2026-05-14), https://learn.microsoft.com/en-us/graph/api/resources/user?view=graph-rest-1.0 (updated 2026-11-17), https://learn.microsoft.com/en-us/graph/api/resources/signinactivity?view=graph-rest-1.0 (updated 2025-07-05) |
| Request | `GET /v1.0/users?$select=id,userPrincipalName,displayName,department,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity&$top=500` |
| Properties used | `id`, `userPrincipalName`, `displayName`, `department`, `userType`, `accountEnabled`, `createdDateTime`, `assignedLicenses` (its `skuId`), `signInActivity.lastSuccessfulSignInDateTime` |
| Permission the page names | The list page gives its permissions "from least to most privileged": delegated `User.ReadBasic.All`, `User.Read.All`, ...; application `User.Read.All`, .... For sign-in activity: "Details for the **signInActivity** property require a Microsoft Entra ID P1 or P2 license and the `AuditLog.Read.All` permission." |
| Licence the page names | Microsoft Entra ID P1 or P2, for `signInActivity` |

What the pages settled:

- `signInActivity`, `accountEnabled`, `assignedLicenses`, `createdDateTime`, `department` and `userType` are returned
  only when selected ("Requires `$select` to retrieve").
- Page size: "The default and maximum page sizes are 100 and 999 user objects respectively, except when you specify
  `$select=signInActivity` or `$filter=signInActivity`. When `signInActivity` is selected or filtered on, the maximum page
  size is 500." Hence `$top=500`.
- The last sign-in is `lastSuccessfulSignInDateTime`: "Use this property if you need to determine when the account was
  truly accessed." `lastSignInDateTime` is not used, because it "records the last time a user attempted an interactive
  sign-in to the directory, whether the attempt was successful or not". The page also says of the successful one: "The
  data isn't backfilled for this property" (it is available "Effective December 1, 2023"). So an account whose last
  successful sign-in came before that date has no value here and is judged as never signed in: by R5 (or R4 for a guest)
  instead of R1. It is still flagged as unused; only the rule that names it changes.
- An empty value is written as no sign-in: the page's example shows `""` and `"0001-01-01T00:00:00Z"`, and the user page
  says `signInActivity` "isn't returned for a user who never signed in or last signed in before April 2020".
- `createdDateTime` "is `null` for some users created before June 2018 and on-premises users that were synced to Microsoft
  Entra ID before June 2018". Such a user is written as created on 2018-06-01, a date before which, on that statement,
  they were created; the snapshot report counts them. This is a reading of the page, not a fact the page states.

Not settled by the pages: whether delegated `User.ReadBasic.All` returns every property selected here. The collector is
written for a token with `User.Read.All` and `AuditLog.Read.All`.

### 2. Licences

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0 (updated 2026-06-19), https://learn.microsoft.com/en-us/graph/api/resources/assignedlicense?view=graph-rest-1.0 (updated 2024-11-21) |
| Request | `GET /v1.0/subscribedSkus?$select=skuId,skuPartNumber` |
| Properties used | `skuId`, `skuPartNumber`; on a user, `assignedLicenses[].skuId`, which "Corresponds to the **skuId** from subscribedSkus" |
| Permission the page names | `LicenseAssignment.Read.All` (least privileged, delegated and application) |
| Licence the page names | None |

The page says the method "supports only the `$select` OData query parameter". Graph holds no price: the collector writes
the licence names with an empty cost column, for the administrator to fill in with their own units.

### 3. Who holds Global Administrator

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments?view=graph-rest-1.0 (updated 2025-07-23); also read: https://learn.microsoft.com/en-us/graph/api/directoryrole-list?view=graph-rest-1.0 (updated 2026-05-14) and https://learn.microsoft.com/en-us/graph/api/directoryrole-list-members?view=graph-rest-1.0 (updated 2025-07-23) |
| Request | `GET /v1.0/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '62e90394-69f5-4237-9190-012177145e10'&$expand=principal` (the spaces are sent as `%20`) |
| Properties used | `principalId`, `principal` and its `@odata.type` |
| Permission the page names | `RoleManagement.Read.Directory`, first in its list "from least to most privileged", delegated and application |
| Licence the page names | None |

Why this API: both directory role pages begin "Microsoft recommends that you use the unified RBAC API instead of this
API." The request is the role assignments page's first example. The role's id comes from two pages: the directory roles
page's example lists `"displayName": "Global Administrator"` with `"roleTemplateId": "62e90394-69f5-4237-9190-012177145e10"`,
and the role assignments example filters `roleDefinitionId` on that id.

A holder that is not a user (the example shows `#microsoft.graph.user`; a group can hold a role) is counted in the snapshot
report and not expanded into its members. Not settled by the page: whether eligible assignments (Privileged Identity
Management) appear in this list.

### 4. MFA registration

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/authenticationmethodsroot-list-userregistrationdetails?view=graph-rest-1.0 (updated 2025-07-23), https://learn.microsoft.com/en-us/graph/api/resources/userregistrationdetails?view=graph-rest-1.0 (updated 2025-12-03), https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-methods-activity (updated 2026-11-17) |
| Request | `GET /v1.0/reports/authenticationMethods/userRegistrationDetails` |
| Properties used | `id`, `isMfaRegistered`, `isAdmin` |
| Permission the page names | `AuditLog.Read.All` (least privileged, delegated and application) |
| Licence the page names | The resource page sends the reader to "Authentication Methods Activity: Permissions and licenses", which says: "A Microsoft Entra ID P1 or P2 license is required to access Usage and insights." It does not name this API in that sentence. |

What the pages settled:

- `isMfaRegistered`: "Indicates whether the user has registered a strong authentication method for multifactor
  authentication. The method may not necessarily be allowed by the authentication methods policy."
- `isAdmin`: "Indicates whether the user has an admin role in the tenant." The collector writes IsAdmin true when this is
  true or when the user holds Global Administrator.
- "This method doesn't work for disabled users." The activity page: soft-deleted users "are not listed in user
  registration details. Same for disabled users." So a user missing from the report is written as MFA not registered,
  and a disabled administrator is flagged by R3, which judges administrators "enabled or not".
- "The report updates for most users in the tenant in 36 hours."

### 5. Conditional Access policies

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-list-policies?view=graph-rest-1.0 (updated 2025-07-23), and the resource pages for conditionalAccessPolicy (updated 2026-06-20), conditionalAccessConditionSet (2025-12-03), conditionalAccessUsers (2024-11-21), conditionalAccessApplications (2025-03-20) and conditionalAccessGrantControls (2026-04-28), at https://learn.microsoft.com/en-us/graph/api/resources/conditionalaccesspolicy?view=graph-rest-1.0 and the same address with conditionalaccessconditionset, conditionalaccessusers, conditionalaccessapplications, conditionalaccessgrantcontrols |
| Request | `GET /v1.0/identity/conditionalAccess/policies` |
| Properties used | `id`, `displayName`, `state`, `createdDateTime`, `conditions.clientAppTypes`, `conditions.users.includeUsers`, `conditions.applications.includeApplications`, `grantControls.builtInControls`, and whether any of `userRiskLevels`, `signInRiskLevels`, `servicePrincipalRiskLevels`, `insiderRiskLevels`, `platforms`, `locations`, `devices`, `clientApplications`, `authenticationFlows` is set |
| Permission the page names | `Policy.Read.All` (least privileged, delegated and application) |
| Licence | Not on the list page. https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview (updated 2026-04-28): "Using this feature requires Microsoft Entra ID P1 licenses." and "Customers with Microsoft 365 Business Premium licenses can also use Conditional Access features." |

What the pages settled:

- `state`: "The possible values are: `enabled`, `disabled`, `enabledForReportingButNotEnforced`."
- `clientAppTypes`: "The possible values are: `all`, `browser`, `mobileAppsAndDesktopClients`, `exchangeActiveSync`,
  `easSupported`, `other`." `includeUsers` may be "`None`, `All`, or `GuestsOrExternalUsers`"; `includeApplications` may
  be `All`; `builtInControls` may be `block`, `mfa`, ....
- R7's definition follows https://learn.microsoft.com/en-us/entra/identity/conditional-access/policy-block-legacy-authentication
  (updated 2026-03-25): include "All users", "All resources", "Check only the boxes **Exchange ActiveSync clients** and
  **Other clients**", "select **Block access**". That page also recommends excluding emergency access accounts, so an
  exclusion does not stop a policy from counting. A policy that sets another condition (a risk level, a location, a
  platform ...) blocks only part of the sign-ins, so it does not count.
- R8 counts days from `createdDateTime`: the resource holds `createdDateTime` and `modifiedDateTime`, and no date of a
  switch into report-only mode.

## Paging, throttling, errors

- Paging, https://learn.microsoft.com/en-us/graph/paging (updated 2025-08-06): "Use the entire URL in the
  `@odata.nextLink` property in a GET request to retrieve the next page of results." and "Don't try to extract the
  `$skiptoken` or `$skip` value and use it in a different request." The collector follows each link as a whole, until
  no link is returned, and refuses a link whose host or path differs from the request it came from.
- Throttling, https://learn.microsoft.com/en-us/graph/throttling (updated 2025-08-06): Graph "Returns HTTP status code
  **429 Too Many Requests**", and the advice is "Wait the number of seconds specified in the `Retry-After` header" and
  retry; "If no `Retry-After` header is provided by the response, we recommend implementing an exponential backoff retry
  policy." The collector does that, but a bounded number of times (`-MaxRetries`, default 3) and never for longer than
  `-MaxWaitSeconds` (default 120) at once: those bounds are this repository's choice, not the page's.
- Any other answer that is not a success, a failed connection, or a redirect, stops the run (exit 3) and nothing is
  written.

## The token

The token is read from the `GRAPH_ACCESS_TOKEN` environment variable, never from a parameter, and never printed or
written. How to obtain one is outside this repository. `-GraphBase` accepts `https://graph.microsoft.com`, or a server on
this computer for the tests, and nothing else, so the token cannot be sent to another host.

## What a first real run would have to check

- That a token with `User.Read.All`, `AuditLog.Read.All`, `LicenseAssignment.Read.All`, `RoleManagement.Read.Directory`
  and `Policy.Read.All` is enough, and whether fewer would do (for example `User.ReadBasic.All`, delegated).
- That paging works over more than one real page, with `$top=500`.
- How the answers look in a tenant without Microsoft Entra ID P1 or P2: the pages name the licence, not the answer.
- Whether eligible role assignments appear in the role assignment list, and how a group holding the role should count.
- The value shapes: a missing `signInActivity`, an empty or `0001-01-01` date, a `null` `createdDateTime`, a disabled user
  missing from the registration report.
- National clouds are not supported: `-GraphBase` refuses any host but `graph.microsoft.com`.
