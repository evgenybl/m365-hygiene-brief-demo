# The tests

```text
pwsh -NoProfile -File Test-Demo.ps1
```

With no argument the tests run in a new temporary folder, which is removed when every check passed and kept, with its
name printed, when one failed. `-OutDir <a new folder>` runs them there and keeps it. The shipped files are never
changed: every edge-case table, wrong answer and broken folder is built in the test folder. The model API and Microsoft
Graph are tested against mock servers on this computer; nothing leaves it.

Every child step runs under the culture of the run that started it, so this tests every script under de-DE:

```text
pwsh -NoProfile -Command "[cultureinfo]::CurrentCulture = 'de-DE'; ./Test-Demo.ps1"
```

The workflow in `.github/workflows/tests.yml` is set to run them on every push to `main` and on pull requests, on Linux and
on Windows, together with the whole demo and a comparison of `examples/` with what the demo writes. On Linux it also
writes the examples again with `TZ` and `LANG` set to another time zone and culture, and runs the tests again under
de-DE (a decimal comma); each of those steps first checks that the culture and time zone it set are the ones in effect,
and fails if not.

## What they cover

- **The original five rules, on the original thirteen accounts** (`tests/thirteen/`): each count, the reclaimable total
  and its parts; the boundaries (90 days since sign-in is not stale and 91 is; a member or a guest created 30 days ago
  with no sign-in on record is not flagged and 31 days is); a timestamp near midnight UTC and one with an offset; `true`
  and `false` in any letter case; a day-first date, a blank `AccountEnabled` and a mistyped `IsAdmin` each refused with
  the row number and nothing written; a clean tenant; the data without its R2 row; a decimal comma culture.
- **The original command**, with the original ten columns and no policies or tenant table: the five counts as before,
  and R6, R7 and R8 "not checked", with what is missing, in the summary, the brief, the work list and both pages.
- **R6 to R8**: four holders of Global Administrator do not fire R6 and five do, a disabled one counting, and the limit
  is a parameter; R6 is one finding with no person in the summary; without the AdminRoles column it is not checked. R7
  counts only an enabled policy for all users and all resources that blocks Exchange ActiveSync and other clients and
  sets no other condition: report-only, disabled, "other" alone, "all" client types, one group, Office365 only, MFA
  instead of block, a risk condition, an excluded application and an application filter each fail to count. With
  security defaults on, R7 finds nothing; not read and no enforced policy, R7 is not checked, and so it is with an
  older policies table that lacks the two application columns (R8 is still checked). A report-only policy that
  would block legacy authentication is named by one stand-in in R7, R8 and the questions D3 and D4. R8: a report-only
  policy created 30 days ago is not flagged and 31 days is, by its UTC date; enabled and disabled policies never are;
  each flagged policy is a stand-in; one with no creation date is reported as "creation date unknown", with no age.
- **The tables**: a role named for an account whose `IsAdmin` is false, an unknown policy state, a policy date that is
  not ISO 8601, a cost written `1,5`, `-3`, `12.5.1` or empty, a licence listed twice, a tenant table value that is not
  true or false, a sign-in address listed twice (in any letter case), a policy id listed twice, a sign-in, creation or
  policy date after the as-of date, and a licence the licence table lacks on an account no rule flags are refused by
  row. A department that names a person of the table (a first name, a name in a phrase, another person's full name) and
  a licence name that does are refused by row, without printing the name; an account named after its department is
  not a person. Costs are exact (0.1 + 0.2 is written 0.3). A cell that starts like a formula is written with a leading
  apostrophe. The rule titles say what they judge: R3 enabled administrators only (a disabled one is left to R2 and R6),
  R4 and R5 "no sign-in on record", R8 "created more than 30 days ago and still in report-only mode"; the summary notes
  that the last sign-in is not backfilled before 1 December 2023.
- **The invented tenant**: every rule fires; the boundary accounts and policies are there; the shipped tables are byte
  for byte what the generator writes for the committed seed; another seed differs; the generator draws from its own
  generator.
- **The brief**: the earlier real answers against the requests they answered, each rebuilt from its stored prompt and
  summary (two to the first request: one accepted and unchanged, one refused for its list number 4 and the figure 5; two
  to the second: both accepted with no problem; all earn "Recorded"); each kind of wrong text caught and the filled
  template used (an invented figure, a number at the start of a line, a list number, digits glued to a product name,
  digit groups separated by a space, invented stand-ins, rule ids and policy stand-ins, a stand-in in another letter
  case, a digit other than 0 to 9, a superscript, a Roman numeral, a figure too long for a decimal, a name written five
  ways, an at sign, an empty answer); the exact product names not counted; a personal value in the summary refused before
  sending; the two recorded answers to today's request pass every check and earn "Recorded" (the first is the default
  brief); the constructed brief accepted against the shipped tenant; a decision named twice, unknown,
  left out, or named inside a sentence; the three edits an independent review made to a real answer (a question
  reworded, a question swapped and replaced, a question hidden behind "See note D6.") each refused; the label lost when
  the answer changes, when the meta file names another request, when there is none, when its date is not a date or its
  model name not a plain name; the live path refused for any address but the vendor's or this computer;
  `-WriteRequest` writing exactly the request.
- **Add-RecordedBrief.ps1**: an answer given to another request refused; an answer with CRLF and non-ASCII bytes copied
  byte for byte, with its meta file; the recording earning "Recorded"; no overwrite.
- **The decisions**: bound to the summary's sha256; appended, the earlier answer unchanged; "yes" written Yes; a time with
  an offset kept as UTC; the summary's question and the number of answers printed; an overriding answer printed with
  the earlier one; refused: a No without a reason, an empty name, a name starting with `=`, `+`, `-`, `@` or a tab, a
  name with a line break or a right-to-left override, a reason with a line break or a zero-width space, an unknown
  decision, a time with no offset, a time earlier than the last answer to the same decision, a decisions file for
  another summary, a brief folder whose summary changed; refusals leave the file as it was. A hand-edited
  `decisions.json` (an answer that is not Yes or No, an unknown field, answers that are not a list, answers out of
  order, a time in another format, a name with a line break) is refused by every script that reads it, and left as it
  is.
- **The work list**: only the decisions answered Yes (the last answer counts); the No and open ones named, with the
  reason and the earlier answers; each question the summary's own; names from the administrator's file; the same list
  whatever the brief's text; refused for mixed folders.
- **The pages**: no name, address or name part from the users table on the manager's page; the date, the data label,
  the brief's label, the findings, the decisions with the summary's questions, who and when, the number of answers and
  the earlier ones, or "open"; the administrator's page with its warning first; no script and no external file; a tag in
  every field of every table that reaches an output, in the model's text and in every field of a decision shown as text
  on both pages and in the work list, never as markup; refused when the brief was changed after it was checked, when the
  work list is older than the decisions, and when a name or only a part of a name would reach the manager's page.
- **The live model path** against a local mock: the path, the version header, the key header, the token limit, no
  personal data in the body, the text accepted; an HTTP error, an answer cut off, an answer with no text, a redirect
  (whose target, a second listener, receives nothing) and a connection error each refused with nothing written; a
  missing key refused; the request sent is exactly the one `-WriteRequest` writes; run with `-Debug` and `-Verbose`, no
  output on any stream holds the key.
- **The collector** against a local mock of Microsoft Graph: only GET requests, each to a path of the fixed list, the
  second page through its next link, the token in each request's header; the documented fields mapped and the stated
  choices made (a missing creation date left empty, and that row refused by step 1 until a person types the date;
  excluded applications, the application filter and security defaults written); its tables read by step 1 once the
  costs and the date are typed in; a throttled answer waited for; refused with nothing written: an answer 403, an
  answer 200 that is an HTML page, an error object or an empty body, a security defaults answer without `isEnabled`, a
  next link outside the list, to another host or to another scheme (a second listener receives nothing), throttling
  beyond the retries, a wait above the limit, a Retry-After too long, written as a date or negative, a redirect, any
  host but Graph or this computer, no token; run with `-Debug` and `-Verbose`, no output holds the token. Neither
  placeholder key appears in any output.
- **The whole demo** under de-DE, every step OK and every file byte for byte the one in `examples/`; the nine cases of the
  failure gallery; the picture `docs/img/demo.svg` showing exactly the closing table a run prints.
- **The README**: every pasted output is what its command prints, run in a copy of the repository; the number of wrong
  texts it states is the number this run fed to the checks; every embedded image exists, and the picture of the manager's page has a
  caption that says how it was made and is a PNG of the size the caption gives; every quote of a real answer
  in the README and in `docs/DESIGN.md` is an exact slice of the file it names; no row of the table of what is real says
  Live; the collector is labelled Mock in the same words in the README, in `docs/COLLECTOR.md`, in the collector section
  of `docs/DESIGN.md`, and in the header of every script that mentions the collector.
- **What the code can call**: every command and .NET type each script names, read by the PowerShell parser, is on the
  committed list `tests/allowed-commands.txt`, and the list holds nothing else; the list names no Graph, Azure, Entra,
  Exchange or mail command and no web client type; exactly two web calls (the model API's POST and the collector's GET),
  neither following a redirect and both with `-Debug` and `-Verbose` off; the collector names no other method and lists
  exactly six paths; the local mock listens on 127.0.0.1 only; no script reads the clock or the time zone except the
  default time of a decision.
- **The files**: every file ASCII with LF line ends; no absolute path of a computer; no key-shaped or token-shaped
  literal; no line that reads like an assigned credential.

## The last lines of a run

Pasted from a run of `pwsh -NoProfile -File Test-Demo.ps1` with PowerShell 7.7.0 on Windows, in a fresh clone, on
24 November 2026. A test checks that the result line below is the result line of the run that reads it.

```text
PASS no file holds a key-shaped or token-shaped literal
PASS no line reads like an assigned credential (token, secret, password or key = a literal)
PASS docs/TESTS.md shows the result line of this run, pasted from a run (every result line it shows is this run's)
RESULT 271 passed, 0 failed
```

The result line of the same tests with PowerShell 7.4.6 on Windows (a portable copy first on the path, so that every
child step ran on it too), in a copy of the working tree the same day:

```text
RESULT 271 passed, 0 failed
```

The version CI uses on Linux and on Windows is printed by the workflow's first step.
