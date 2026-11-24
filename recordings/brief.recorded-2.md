We checked 60 user accounts and 7 sign-in policies in the Microsoft 365 tenant, as of 2026-11-21.

Security findings

- Administrator accounts with no second sign-in step (MFA): 2. An administrator account without a second step can be taken over with a stolen password.
- Global Administrator role: 5 accounts hold it, and the limit is 4. Every extra account with full control is another way in if one is compromised.
- Guest accounts with no sign-in for more than 90 days, or none on record: 2. Guest access that nobody uses is access nobody watches.
- Legacy sign-in protection: no enforced policy blocks legacy sign-in methods, and security defaults are off. Legacy methods skip the second step, so they are an open door. This finding is about the tenant's settings and policies, not a person. The policy policy-001 would block them, but it is still in report-only mode.
- Sign-in policies left in report-only mode for more than 30 days: 2. policy-001 has been in that mode for 45 days and policy-002 for 31 days. Report-only means the rule is watched but not enforced, so it protects no one. These are policies, not people.

Cost findings

- Enabled accounts with paid licences and no sign-in for more than 90 days: 7 accounts, costing 129.2 synthetic units a month. This is paid access that nobody appears to use.
- Disabled accounts that still hold paid licences: 2 accounts, costing 34.1 synthetic units a month. A disabled account should not be paying for licences.
- Licensed member accounts with no sign-in on record, created more than 30 days ago: 1 account, costing 6.1 synthetic units a month. Microsoft keeps no sign-in history before 1 December 2023, so a missing record can mean an earlier sign-in. Check before acting.

Total reclaimable monthly cost: 169.4 synthetic units. These units were invented for the demo. They are not real prices and not money.

Decisions for the administrator

D1 Should the administrator require every administrator account to register a second sign-in step (MFA)? Yes or no?
D2 Should the administrator review who holds the Global Administrator role and bring it down to 4 accounts or fewer? Yes or no?
D3 Should the administrator switch on policy-001, which is in report-only mode now, so that it blocks legacy authentication for all users? Yes or no?
D4 Should the administrator review each Conditional Access policy left in report-only mode, to switch it on or remove it (policy-001 is also in the question about legacy authentication)? Yes or no?
D5 Should the administrator remove the guest accounts that have no recent sign-in on record? Yes or no?
D6 Should the administrator review the unused licences and return the ones the review finds not needed? Yes or no?