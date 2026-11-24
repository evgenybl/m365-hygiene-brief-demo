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

The tests also run on every push to `main` and on pull requests, on Linux and on Windows, together with the whole demo
and a comparison of `examples/` with what the demo writes (`.github/workflows/tests.yml`). On Linux the workflow writes
the examples again under another time zone and culture (`TZ`, `LANG`), which Linux honours and Windows does not.

## What they cover

- **The original five rules, on the original thirteen accounts** (`tests/thirteen/`): each count, the reclaimable total
  and its parts; the boundaries (90 days since sign-in is not stale and 91 is; a member or a guest created 30 days ago
  who never signed in is not flagged and 31 days is); a timestamp near midnight UTC and one with an offset; `true` and
  `false` in any letter case; a day-first date, a blank `AccountEnabled` and a mistyped `IsAdmin` each refused with the
  row number and nothing written; a clean tenant; the data without its R2 row; a decimal comma culture.
- **R6 to R8**: four holders of Global Administrator do not fire R6 and five do, a disabled one counting, and the limit
  is a parameter; R6 is one finding with no person in the summary. R7 counts only an enabled policy for all users and
  all resources that blocks Exchange ActiveSync and other clients and sets no other condition: report-only, disabled,
  "other" alone, "all" client types, one group, Office365 only, MFA instead of block, and a risk condition each fail to
  count. R8: a report-only policy created 30 days ago is not flagged and 31 days is, by its UTC date; enabled and disabled
  policies never are; each flagged policy is a stand-in.
- **The tables**: a role named for an account whose `IsAdmin` is false, a missing `AdminRoles` column, an unknown policy
  state, a policy date that is not ISO 8601, a cost written `1,5`, `-3`, `12.5.1` or empty, and a licence listed twice
  are refused. Costs are exact (0.1 + 0.2 is written 0.3). A cell that starts like a formula is written with a leading
  apostrophe.
- **The invented tenant**: every rule fires; the boundary accounts and policies are there; the shipped tables are byte
  for byte what the generator writes for the committed seed; another seed differs; the generator draws from its own
  generator.
- **The brief**: the two earlier real answers against the request they answered (one accepted and unchanged, one refused
  for the figure 5; the request's sha256 is the one they were recorded against; both earn "Recorded"); each kind of wrong
  text caught and the filled template used (an invented figure, a number at the start of a line, digit groups separated
  by a space, invented stand-ins, rule ids and policy stand-ins, a digit other than 0 to 9, a figure too long for a
  decimal, a name written five ways, an at sign, an empty answer); a personal value in the summary refused before
  sending; the constructed brief accepted against the shipped tenant with its label; a decision named twice, unknown, or
  left out; the label lost when the answer changes, when the meta file names another request, or when there is none;
  `-WriteRequest` writing exactly the request.
- **Add-RecordedBrief.ps1**: an answer given to another request refused; an answer with CRLF and non-ASCII bytes copied
  byte for byte, with its meta file; the recording earning "Recorded"; no overwrite.
- **The decisions**: bound to the summary's sha256; appended, the earlier answer unchanged; "yes" written Yes; a time with
  an offset kept as UTC; refused: a No without a reason, an empty name, a name starting with `=`, `+`, `-`, `@` or a tab,
  a name with a line break, an unknown decision, a time with no offset, a decision the summary does not ask, a decisions
  file for another summary, a brief folder whose summary changed; refusals leave the file as it was.
- **The work list**: only the decisions answered Yes (the last answer counts); the No and open ones named, with the
  reason; names from the administrator's file; the same list whatever the brief's text; refused for mixed folders.
- **The pages**: no name or address from the users table on the manager's page; the date, the data label, the brief's
  label, the findings, the decisions with who and when, or "open"; the administrator's page with its warning first; no
  script and no external file; a tag in a display name, in the model's text and in a typed name shown as text; refused
  when the brief was changed after it was checked, when the work list is older than the decisions, and when a name would
  reach the manager's page.
- **The live model path** against a local mock: the path, the version header, the key header, the token limit, no
  personal data in the body, the text accepted; an HTTP error, an answer cut off, an answer with no text and a
  connection error each refused with nothing written; a missing key refused; the request sent is exactly the one
  `-WriteRequest` writes.
- **The collector** against a local mock of Microsoft Graph: only GET requests, each to a path of the fixed list, the
  second page through its next link, the token in each request's header; the documented fields mapped and the stated
  choices made; its tables read by step 1 once the costs are typed in; a throttled answer waited for; refused with nothing
  written: an answer 403, a next link outside the list, throttling beyond the retries, a wait above the limit, a redirect,
  any host but Graph or this computer, no token. Neither placeholder key appears in any output.
- **The whole demo** under de-DE, every step OK and every file byte for byte the one in `examples/`; the nine cases of the
  failure gallery; the picture `docs/img/demo.svg` showing exactly the closing table a run prints.
- **The README**: every pasted output is what its command prints, run in a copy of the repository; every embedded image
  exists; no row of the table of what is real says Live; the collector is labelled Mock in the same words in the README,
  in `docs/COLLECTOR.md` and in the script.
- **Read-only by construction**: no script holds a tenant connect or change command, a mail command, or a web call other
  than the model API's POST and the collector's GET; the collector names no other method, follows no redirect and lists
  exactly five paths; the local mock listens on 127.0.0.1 only; no script reads the clock or the time zone except the
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
RESULT 193 passed, 0 failed
```

The result line of the same tests with PowerShell 7.4.6 on Windows (a portable copy first on the path, so that every
child step ran on it too), in another fresh clone the same day:

```text
RESULT 193 passed, 0 failed
```

The version CI uses on Linux and on Windows is printed by the workflow's first step.
