*Constructed, not from a model: this text was written by hand to the request, so that the checks and the pages can be shown. A recorded model answer is meant to replace it.*

On 21 November 2026 we checked 60 user accounts and 6 sign-in policies in Microsoft 365 for security gaps and unused licences.

**Security findings, most urgent first**

- **Administrators without a second sign-in step (MFA): 3 accounts** (user-005, user-008, user-010). An administrator account that is protected only by a password is the easiest way into the company's mail and files.
- **Too many global administrators: 5 accounts hold the role, and the limit set for this check is 4.** This is a setting of the tenant and names no person. Every extra global administrator is one more account that can change everything.
- **Old sign-in methods are not blocked.** No switched-on policy blocks legacy authentication, the older ways of signing in that cannot ask for a second step. This is a tenant setting and names no person.
- **Sign-in policies left in trial mode: 2 policies** (policy-001, created 45 days ago, and policy-002, created 31 days ago). In report-only mode a policy only records what it would have done; it protects nothing. No person is named here.
- **Guest accounts with no sign-in for more than 90 days, or never: 2 accounts** (user-001, user-004). Outside people who may no longer work with you can still reach company information.

**Cost findings**

- **Active accounts with a licence and no sign-in for more than 90 days: 7 accounts**, 129.2 units a month.
- **Disabled accounts that still hold a licence: 2 accounts** (user-010, user-012), 34.1 units a month.
- **A licensed account that never signed in, created more than 30 days ago: 1 account** (user-002), 6.1 units a month.

**Total reclaimable cost: 169.4 units a month.** These units were invented for this demo. They are not real prices, and no saving is promised.

**Decisions for you**

- D1: Should the administrator require every administrator account to register a second sign-in step (MFA)? Yes or no.
- D2: Should the administrator review who holds the Global Administrator role and bring it down to 4 accounts or fewer? Yes or no.
- D3: Should the administrator turn on a policy that blocks legacy authentication for all users? Yes or no.
- D4: Should the administrator review the policies left in report-only mode, to switch each one on or remove it? Yes or no.
- D5: Should the administrator remove the guest accounts that have not signed in? Yes or no.
- D6: Should the administrator review the unused licences and return the ones the review finds not needed? Yes or no.
