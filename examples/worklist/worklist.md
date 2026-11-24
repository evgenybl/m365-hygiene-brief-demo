# Work list for the administrator

As of 2026-11-21. Made from the decisions recorded for the summary with sha256 230589ac56e5d22b4eac4bd2dfd80676f892a72d4ec2801765fcc0426be3548f.
This is a list for a person to work through. Nothing here has been changed in any tenant, and this list changes nothing.
Each question below is the findings summary's own, fixed by the script; the brief's wording of it is not used.

## D1: Yes, by Rina Manager (synthetic) at 2026-11-22T09:00:00Z

Should the administrator require every administrator account to register a second sign-in step (MFA)?

Answers to D1: 1. This is the only one.

- [ ] R3 Bina Bet (synthetic) (bina.bet@demo.example.com). Can this administrator register a second sign-in step (MFA), or does the account still need its role?
- [ ] R3 Roni Lamed (synthetic) (roni.lamed@demo.example.com). Can this administrator register a second sign-in step (MFA), or does the account still need its role?

## D2: Yes, by Rina Manager (synthetic) at 2026-11-22T09:01:00Z

Should the administrator review who holds the Global Administrator role and bring it down to 4 accounts or fewer?

Answers to D2: 1. This is the only one.

- [ ] R6 Bina Bet (synthetic) (bina.bet@demo.example.com). Holds Global Administrator (enabled); 5 accounts hold it, limit 4. Does this account need the Global Administrator role? Bring the holders down to the limit.
- [ ] R6 Rotem Samekh (synthetic) (rotem.samekh@demo.example.com). Holds Global Administrator (disabled); 5 accounts hold it, limit 4. Does this account need the Global Administrator role? Bring the holders down to the limit.
- [ ] R6 Adi Vav (synthetic) (adi.vav@demo.example.com). Holds Global Administrator (enabled); 5 accounts hold it, limit 4. Does this account need the Global Administrator role? Bring the holders down to the limit.
- [ ] R6 Ofir Resh (synthetic) (ofir.resh@demo.example.com). Holds Global Administrator (enabled); 5 accounts hold it, limit 4. Does this account need the Global Administrator role? Bring the holders down to the limit.
- [ ] R6 Roni Qof (synthetic) (roni.qof@demo.example.com). Holds Global Administrator (enabled); 5 accounts hold it, limit 4. Does this account need the Global Administrator role? Bring the holders down to the limit.

## D3: Yes, by Rina Manager (synthetic) at 2026-11-22T09:02:00Z

Should the administrator switch on policy-001, which is in report-only mode now, so that it blocks legacy authentication for all users?

Answers to D3: 1. This is the only one.

- [ ] R7 (the tenant). No enforced policy blocks legacy authentication, and security defaults are off; 7 policies checked; in report-only mode, would block it: Block legacy authentication (synthetic) (policy id 00000000-0000-4000-8000-000000000002, policy-001). Is legacy authentication still in use (the sign-in logs show the client app)? If not, switch on a policy that blocks it, such as the report-only one named here.

## D5: Yes, by Rina Manager (synthetic) at 2026-11-22T09:04:00Z

Should the administrator remove the guest accounts that have no recent sign-in on record?

Answers to D5: 1. This is the only one.

- [ ] R4 Tamar Tav (synthetic guest) (tamar.tav\_partner.example.com#EXT#@demo.example.com). Does the guest still need access? If not, remove the guest.
- [ ] R4 Keren Bet (synthetic guest) (keren.bet\_partner.example.com#EXT#@demo.example.com). Does the guest still need access? If not, remove the guest.

## Not on this list

- D4: answered No by Rina Manager (synthetic) at 2026-11-22T09:03:00Z. Reason: The policies stay in report-only mode until the help desk has read what they would block. Answers to D4: 1.
- D6: still open, no answer recorded.
