As of 21 November 2026, the check reviewed 60 accounts and 6 sign-in policies in the Microsoft 365 tenant.

Security findings

Three administrator accounts have no second sign-in step (MFA) set up. An administrator account controls the whole company system, so a password alone is weak protection for it.

Five accounts hold the Global Administrator role, which is above the limit of 4. Each extra account with that role is another way in for an attacker. This finding is about the tenant's role settings and names no person.

The check found no enabled sign-in policy that blocks legacy authentication, the older sign-in methods that skip the second step. This is a tenant-wide setting and names no person.

Two guest accounts (outside users) have not signed in for more than 90 days, or have never signed in. Unused outside access is a route into company information that nobody is watching.

Two sign-in policies were created more than 30 days ago and are still in report-only mode. Report-only policies record what they would do but block nothing, so they give a false sense of protection. These findings are about the policies and name no person.

Cost findings

Seven enabled accounts hold paid licences but have not signed in for more than 90 days. Each one costs money every month with no use.

Two disabled accounts still hold paid licences. A disabled account cannot be used, so its licences are pure cost.

One licensed member has never signed in, although the account was created more than 30 days ago. The licence is paid for with no use.

Total reclaimable cost: 169.4 synthetic units per month. These units were invented for the demo. They are not real prices and not money.

Decisions for you, in order. Each can be answered yes or no.

D1 - Should the administrator require every administrator account to register a second sign-in step (MFA)? Yes or no?
D2 - Should the administrator review who holds the Global Administrator role and bring it down to 4 accounts or fewer? Yes or no?
D3 - Should the administrator turn on a Conditional Access policy that blocks legacy authentication for all users? Yes or no?
D4 - Should the administrator review each Conditional Access policy left in report-only mode, to switch it on or remove it? Yes or no?
D5 - Should the administrator remove the guest accounts that have not signed in? Yes or no?
D6 - Should the administrator review the unused licences and return the ones the review finds not needed? Yes or no?