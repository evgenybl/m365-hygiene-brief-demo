The check covered 60 user accounts and 6 sign-in policies, as of 2026-11-21.

**Security findings**

- Administrator accounts without a second sign-in step: 3. Without that second step, a stolen password is enough to take over an account that can change the whole system.
- Guest accounts with no sign-in for more than 90 days, or never: 2. Old outside accounts that are still open are an unnecessary way in.
- Global Administrator accounts: 5, where the limit is 4. Each extra top-level administrator is another way in and another person who can change everything.
- No enabled sign-in policy blocks legacy sign-in methods. These older methods skip the second step, so they get around the protections the business relies on. This is a tenant-wide setting and names no person.
- Sign-in policies left in report-only mode for more than 30 days: 2 (policy-001 at 45 days, policy-002 at 31 days). A report-only policy records what it would block but blocks nothing, so the protection is not actually active. These are policy settings and name no person.

**Cost findings**

- Enabled accounts with no sign-in for more than 90 days that still carry a paid licence: 7 accounts, 129.2 units a month. Paid seats are going unused.
- Disabled accounts that still carry a paid licence: 2 accounts, 34.1 units a month.
- Licensed accounts that never signed in, created more than 30 days ago: 1 account, 6.1 units a month.

The total reclaimable monthly cost is 169.4 synthetic units. The units were invented for the demo. They are not real prices and not money.

**Decisions**

D1 Should the administrator require every administrator account to register a second sign-in step (MFA)?
D2 Should the administrator review who holds the Global Administrator role and bring it down to 4 accounts or fewer?
D3 Should the administrator turn on a Conditional Access policy that blocks legacy authentication for all users?
D4 Should the administrator review each Conditional Access policy left in report-only mode, to switch it on or remove it?
D5 Should the administrator remove the guest accounts that have not signed in?
D6 Should the administrator review the unused licences and return the ones the review finds not needed?