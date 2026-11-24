# The collector: Export-TenantSnapshot.ps1

**Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.**

The collector reads a Microsoft 365 tenant through Microsoft Graph and writes the four tables that
`Get-TenantHygieneFindings.ps1` reads: users, licences, Conditional Access policies, and a tenant table that says whether
security defaults are on. It makes GET requests only, to the six paths below and to the next-page links those answers
return, and holds no command that changes a tenant. Every path, query and property name here was copied from
Microsoft's documentation pages, read on 24 November 2026; each page's own "updated" date is given as the page states it.
Where a page does not settle something, this file says so.

It has been run only against the local mock in `mock/graph/`, whose answers follow the shapes in the examples on these
pages, with invented accounts. What a first real run would have to check is listed at the end.

For each request: the permission the page names, and the Microsoft Entra roles it names for a delegated token (a token
that acts for a signed-in person, who must then hold one of those roles); an application token needs the permission only.

## The six requests

### 1. Users, with their last sign-in

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0 (updated 2026-05-14), https://learn.microsoft.com/en-us/graph/api/resources/user?view=graph-rest-1.0 (updated 2026-11-17), https://learn.microsoft.com/en-us/graph/api/resources/signinactivity?view=graph-rest-1.0 (updated 2025-07-05) |
| Request | `GET /v1.0/users?$select=id,userPrincipalName,displayName,department,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity&$top=500` |
| Properties used | `id`, `userPrincipalName`, `displayName`, `department`, `userType`, `accountEnabled`, `createdDateTime`, `assignedLicenses` (its `skuId`), `signInActivity.lastSuccessfulSignInDateTime` |
| Permission the page names | The list page gives its permissions "from least to most privileged": delegated `User.ReadBasic.All`, `User.Read.All`, ...; application `User.Read.All`, .... For sign-in activity: "Details for the **signInActivity** property require a Microsoft Entra ID P1 or P2 license and the `AuditLog.Read.All` permission." |
| Roles the page names (delegated) | None. It says: "Guests can't call this API." |
| Licence the page names | Microsoft Entra ID P1 or P2, for `signInActivity` |

What the pages settled:

- `signInActivity`, `accountEnabled`, `assignedLicenses`, `createdDateTime`, `department` and `userType` are returned
  only when selected ("Requires `$select` to retrieve").
- Page size: "The default and maximum page sizes are 100 and 999 user objects respectively, except when you specify
  `$select=signInActivity` or `$filter=signInActivity`. When `signInActivity` is selected or filtered on, the maximum page
  size is 500." Hence `$top=500`.
- The last sign-in is `lastSuccessfulSignInDateTime`: "Use this property if you need to determine when the account was
  truly accessed." `lastSignInDateTime` is not used, because it "records the last time a user attempted an interactive
  sign-in to the directory, whether the attempt was successful or not". The page also says of the successful one:
  "Effective December 1, 2023, the **lastSuccessfulSignInDateTime** property is available" and "The data isn't
  backfilled for this property". So an account whose last successful sign-in came before that date has no value here:
  the rules say "no sign-in on record", not "never signed in", and judge it by R5 (or R4 for a guest) instead of R1. It
  is still flagged as unused; only the rule that names it changes, and the summary carries the note.
- An empty value is written as no sign-in: the page's example shows `""` and `"0001-01-01T00:00:00Z"`, and the user page
  says `signInActivity` "isn't returned for a user who never signed in or last signed in before April 2020".
- `createdDateTime` "is `null` for some users created before June 2018 and on-premises users that were synced to Microsoft
  Entra ID before June 2018". Such a user's CreatedDate is left empty, and the snapshot report counts them. No date is
  written in its place: `Get-TenantHygieneFindings.ps1` then refuses that row, with its row number, so that a person
  supplies the date from another source or removes the row.
- A guest's address has the form the list page shows, "AdeleV\_adatum.com#EXT#@contoso.com"; the name checks take the
  part before the home domain as the guest's local part.

The collector is written for a token with `User.Read.All` and `AuditLog.Read.All`; whether less would do is in the last
section.

### 2. Licences

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0 (updated 2026-06-19), https://learn.microsoft.com/en-us/graph/api/resources/assignedlicense?view=graph-rest-1.0 (updated 2024-11-21) |
| Request | `GET /v1.0/subscribedSkus?$select=skuId,skuPartNumber` |
| Properties used | `skuId`, `skuPartNumber`; on a user, `assignedLicenses[].skuId`, which "Corresponds to the **skuId** from subscribedSkus" |
| Permission the page names | `LicenseAssignment.Read.All` (least privileged, delegated and application) |
| Roles the page names (delegated) | "Dynamics 365 Business Central Administrator - read only standard properties", "Global Reader", "Directory Readers", for "delegated access using work or school accounts where the signed-in user is acting on another user" |
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
| Roles the page names (delegated) | "Directory Readers", "Global Reader", "Privileged Role Administrator" |
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
| Roles the page names (delegated) | "Reports Reader", "Security Reader", "Security Administrator", "Global Reader" |
| Licence the page names | The resource page sends the reader to "Authentication Methods Activity: Permissions and licenses", which says: "A Microsoft Entra ID P1 or P2 license is required to access Usage and insights." It does not name this API in that sentence. |

What the pages settled:

- `isMfaRegistered`: "Indicates whether the user has registered a strong authentication method for multifactor
  authentication. The method may not necessarily be allowed by the authentication methods policy."
- `isAdmin`: "Indicates whether the user has an admin role in the tenant." The collector writes IsAdmin true when this is
  true or when the user holds Global Administrator.
- "This method doesn't work for disabled users." The activity page: soft-deleted users "are not listed in user
  registration details. Same for disabled users." So a user missing from the report is written as MFA not registered,
  and R3 judges enabled administrators only: for a disabled one, the MFA state is not known.
- "The report updates for most users in the tenant in 36 hours."

### 5. Conditional Access policies

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-list-policies?view=graph-rest-1.0 (updated 2025-07-23), and the resource pages for conditionalAccessPolicy (updated 2026-06-20), conditionalAccessConditionSet (2025-12-03), conditionalAccessUsers (2024-11-21), conditionalAccessApplications (2025-03-20) and conditionalAccessGrantControls (2026-04-28), at https://learn.microsoft.com/en-us/graph/api/resources/conditionalaccesspolicy?view=graph-rest-1.0 and the same address with conditionalaccessconditionset, conditionalaccessusers, conditionalaccessapplications, conditionalaccessgrantcontrols |
| Request | `GET /v1.0/identity/conditionalAccess/policies` |
| Properties used | `id`, `displayName`, `state`, `createdDateTime`, `conditions.clientAppTypes`, `conditions.users.includeUsers`, `conditions.applications.includeApplications`, `conditions.applications.excludeApplications`, `conditions.applications.applicationFilter`, `grantControls.builtInControls`, and whether any of `userRiskLevels`, `signInRiskLevels`, `servicePrincipalRiskLevels`, `insiderRiskLevels`, `platforms`, `locations`, `devices`, `clientApplications`, `authenticationFlows` is set |
| Permission the page names | `Policy.Read.All` (least privileged, delegated and application) |
| Roles the page names (delegated) | "Global Secure Access Administrator - read standard properties", "Security Reader - read standard properties", "Security Administrator - read standard properties", "Global Reader", "Conditional Access Administrator" |
| Licence | Not on the list page. https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview (updated 2026-04-28): "Using this feature requires Microsoft Entra ID P1 licenses." and "Customers with Microsoft 365 Business Premium licenses can also use Conditional Access features." |

What the pages settled:

- `state`: "The possible values are: `enabled`, `disabled`, `enabledForReportingButNotEnforced`."
- `clientAppTypes`: "The possible values are: `all`, `browser`, `mobileAppsAndDesktopClients`, `exchangeActiveSync`,
  `easSupported`, `other`." `includeUsers` may be "`None`, `All`, or `GuestsOrExternalUsers`"; `includeApplications` may
  be `All`; `builtInControls` may be `block`, `mfa`, ....
- The applications of a policy (the conditionalAccessApplications page): `excludeApplications` is "The list of client IDs
  (**appId**) explicitly excluded from the policy" (or `Office365`, `MicrosoftAdminPortals`), and `applicationFilter` is
  a "Filter that defines the dynamic-application-syntax rule to include/exclude cloud applications." A policy that
  excludes any application, or that uses an application filter, does not apply to all resources, so it does not count
  as blocking legacy authentication for all of them. The collector writes both in their own columns.
- R7's definition follows https://learn.microsoft.com/en-us/entra/identity/conditional-access/policy-block-legacy-authentication
  (updated 2026-03-25): "Under **Include**, select **All users**", "select **All resources (formerly 'All cloud apps')**",
  "Check only the boxes **Exchange ActiveSync clients** and **Other clients**", "select **Block access**". That page
  also says "Microsoft recommends you exclude at least one account to prevent yourself from being locked out due to
  misconfiguration", so an excluded user does not stop a policy from counting. A policy that sets another condition (a
  risk level, a location, a platform ...) blocks only part of the sign-ins, so it does not count. The page puts a new
  policy in report-only mode first: "This policy is put in to Report-only mode to start so administrators can determine
  the impact they have on existing users." So a report-only policy that would otherwise count is named in R7's finding
  and in its question, rather than counted as blocking.
- The same page: "Customers without licenses that include Conditional Access can make use of security defaults to block
  legacy authentication." Hence the sixth request.
- R8 counts days from `createdDateTime`: the resource holds `createdDateTime` and `modifiedDateTime`, and no date of a
  switch into report-only mode. A policy whose `createdDateTime` is missing gets an empty cell, and R8 reports it, if it is
  in report-only mode, as of unknown age; no age is invented for it.

### 6. Security defaults

| | |
|---|---|
| Pages | https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults (updated 2026-10-16), https://learn.microsoft.com/en-us/graph/api/resources/identitysecuritydefaultsenforcementpolicy?view=graph-rest-1.0 (updated 2024-11-27), https://learn.microsoft.com/en-us/graph/api/identitysecuritydefaultsenforcementpolicy-get?view=graph-rest-1.0 (updated 2025-07-23) |
| Request | `GET /v1.0/policies/identitySecurityDefaultsEnforcementPolicy` (the page's request is "GET /policies/identitySecurityDefaultsEnforcementPolicy", and its example uses `/v1.0`) |
| Property used | `isEnabled`: "If set to `true`, Microsoft Entra security defaults are enabled for the tenant." |
| Permission the page names | `Policy.Read.All` (least privileged, delegated and application; higher privileged: "Not available.") |
| Roles the page names (delegated) | None. (The security defaults page says that to configure them, a person "must be assigned at least the Conditional Access Administrator role"; that is about changing them, which the collector never does.) |
| Licence | The security defaults page's table: "Required licenses", "None" for security defaults, "At least Microsoft Entra ID P1" for Conditional Access |

What the pages settled:

- Security defaults block legacy authentication: "After security defaults are enabled in your tenant, all
  authentication requests made by an older protocol will be blocked." So R7 does not fire when they are on.
- They are not used with Conditional Access policies: "Organizations that choose to implement Conditional Access
  policies that replace security defaults must disable security defaults." The collector reads the setting rather than
  infer it from the policies.
- The answer is one object, not a collection: the example is an object with `description`, `displayName`, `id` and
  `isEnabled`. The collector requires a true or false `isEnabled` and stops otherwise; the mock's answer has the
  example's shape.

## Paging, throttling, shapes, errors

- Paging, https://learn.microsoft.com/en-us/graph/paging (updated 2025-08-06): "Use the entire URL in the
  `@odata.nextLink` property in a GET request to retrieve the next page of results." and "Don't try to extract the
  `$skiptoken` or `$skip` value and use it in a different request." The collector follows each link as a whole, until
  no link is returned, and refuses a link whose scheme, host or path differs from the request it came from.
- Throttling, https://learn.microsoft.com/en-us/graph/throttling (updated 2025-08-06): Graph "Returns HTTP status code
  **429 Too Many Requests**", and the advice is "Wait the number of seconds specified in the `Retry-After` header" and
  retry; "If no `Retry-After` header is provided by the response, we recommend implementing an exponential backoff retry
  policy." The collector does that, but a bounded number of times (`-MaxRetries`, default 3) and never for longer than
  `-MaxWaitSeconds` (default 120) at once: those bounds are this repository's choice, not the page's. A Retry-After that
  asks for more than `-MaxWaitSeconds`, or that is not a whole number of seconds (an HTTP date, a negative number),
  stops the run at once and says why.
- Shapes: every collection page must be a JSON object with a `value` array, as each page's example shows. An answer 200
  that is an HTML page, an error object or an empty body stops the run, rather than pass for an empty collection.
- Any other answer that is not a success, a failed connection, or a redirect, stops the run (exit 3) and nothing is
  written.

## The token

The token is read from the `GRAPH_ACCESS_TOKEN` environment variable, never from a parameter, and never printed or
written: the web call runs with `-Debug:$false -Verbose:$false`, and the script switches both preferences off, because
with `-Debug` PowerShell prints each request's headers, the token among them. How to obtain a token is outside this
repository. `-GraphBase` accepts `https://graph.microsoft.com`, or a server on this computer for the tests, and nothing
else, so the token cannot be sent to another host.

## Not settled by the documentation, to be checked on a first real run

Each point below is something the pages read do not settle. Nothing here guesses the answer; each is to be checked on a
first run against a real tenant.

- **Whether the delegated permission named is enough.** The users list page gives `User.ReadBasic.All` first among the
  delegated permissions, "from least to most privileged", but does not say whether it returns every property selected
  here (`accountEnabled`, `assignedLicenses`, `createdDateTime`, `department`, `userType` and `signInActivity`, which each
  require `$select`). The collector is written for `User.Read.All` and `AuditLog.Read.All`.
- **Which role a delegated token needs for the users list and for security defaults.** Neither page names one; the
  other four pages do (above).
- **Whether eligible role assignments appear in the list.** The role assignments page does not say whether eligible
  assignments (Privileged Identity Management) are part of `roleManagement/directory/roleAssignments`. R6 counts only
  what the list holds, and a group that holds the role is counted in the snapshot report, not expanded into its members.
- **Whether the licence sentence covers the registration report's API.** The resource page points to "Authentication
  Methods Activity: Permissions and licenses", which says "A Microsoft Entra ID P1 or P2 license is required to access
  Usage and insights." It does not name the `userRegistrationDetails` API in that sentence, and the API page names no
  licence.
- **The missing `createdDateTime`.** The user page says it "is `null` for some users created before June 2018 and
  on-premises users that were synced to Microsoft Entra ID before June 2018". The collector writes an empty cell for such
  a user, not a date, because any date written there would be an assumption the data cannot back; step 1 then refuses
  the row by its number, so that a person supplies the date. A policy with no `createdDateTime` gets an empty cell too,
  and R8 reports it as of unknown age.
- **Excluded users and groups.** R7 lets a policy exclude users, as the legacy authentication page recommends for
  emergency accounts; how many it excludes is not judged, and a policy that excludes most users would still count.
- **The other answers of a real tenant:** a token with the five application permissions above (`User.Read.All`,
  `AuditLog.Read.All`, `LicenseAssignment.Read.All`, `RoleManagement.Read.Directory`, `Policy.Read.All`); paging over more
  than one real page with `$top=500`; how the answers look in a tenant without Microsoft Entra ID P1 or P2 (the pages name
  the licence, not the answer); and the value shapes of a missing `signInActivity`, an empty or `0001-01-01` date, and a
  disabled user missing from the registration report.
- National clouds are not supported: `-GraphBase` refuses any host but `graph.microsoft.com`.
