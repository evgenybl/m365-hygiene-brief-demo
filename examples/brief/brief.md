We checked the company's Microsoft 365 accounts and sign-in rules as of 2026-11-21: 60 user accounts and 7 sign-in rules.

**Security findings**

- Administrator accounts without a second sign-in step: 2. An administrator account can change a lot in the system, so a stolen password alone should never be enough to open it.
- Guest accounts with no recent sign-in: 2. Guests are outside people invited into the company system, and an unused guest account is still a way in to company information. One has no sign-in on record, and the other has not signed in for 120 days.
- Too many Global Administrator accounts: 1. This is a setting of the whole system, not a person. Five accounts hold the role, and the limit is 4. Each extra top-level administrator is another way in for an attacker.
- Older sign-in methods not blocked: 1. This is a setting of the whole system, not a person. Security defaults (Microsoft's built-in baseline protection) are off, and no enforced sign-in rule blocks older sign-in methods. One rule, policy-001, would block them but is in report-only mode, so it only tests and does not block. Older methods often skip the second check, so a leaked password can open an account.
- Sign-in rules left in report-only mode for more than 30 days: 2. These are rules, not people. policy-001 has been in report-only mode for 45 days and policy-002 for 31 days. Report-only rules record what they would do but stop nothing, so they give no protection.

**Cost findings**

- Enabled and licensed, with no sign-in for more than 90 days: 7 accounts, cost 129.2 synthetic units a month. The company pays for licences that nobody seems to use.
- Disabled but still licensed: 2 accounts, cost 34.1 synthetic units a month. Turned-off accounts still hold paid licences.
- Licensed member with no sign-in on record, created more than 30 days ago: 1 account, cost 6.1 synthetic units a month. Either the licence is unused or the record has a gap, so it needs a check.

A "no sign-in on record" does not prove an account was never used. The record does not go back before 1 December 2023, so an older sign-in may be missing.

**Total reclaimable cost**

169.4 synthetic units a month could be reclaimed. These units were invented for the demo. They are not real prices and not money.

**Decisions for you**

D1 Should the administrator require every administrator account to register a second sign-in step (MFA)? Yes or no?
D2 Should the administrator review who holds the Global Administrator role and bring it down to 4 accounts or fewer? Yes or no?
D3 Should the administrator switch on policy-001, which is in report-only mode now, so that it blocks legacy authentication for all users? Yes or no?
D4 Should the administrator review each Conditional Access policy left in report-only mode, to switch it on or remove it (policy-001 is also in the question about legacy authentication)? Yes or no?
D5 Should the administrator remove the guest accounts that have no recent sign-in on record? Yes or no?
D6 Should the administrator review the unused licences and return the ones the review finds not needed? Yes or no?
