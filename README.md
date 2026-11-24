# Microsoft 365 hygiene brief demo

**A manager gets a one-page brief in plain words about the organisation's Microsoft 365 accounts, and answers a few
yes-or-no questions. The administrator keeps the names and the details on their own computer, and gets a work list made
only from the questions the manager answered Yes.**

[![tests](https://github.com/evgenybl/m365-hygiene-brief-demo/actions/workflows/tests.yml/badge.svg)](https://github.com/evgenybl/m365-hygiene-brief-demo/actions/workflows/tests.yml)
![powershell](https://img.shields.io/badge/PowerShell-7.4%2B-blue)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![data](https://img.shields.io/badge/data-synthetic-lightgrey)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## The task

An organisation runs on Microsoft 365. Nobody looks regularly at who still holds a licence, which administrators have no
second factor, or which guests were forgotten. The administrator can read a findings table. The manager who has to
decide cannot, and should not have to.

Everything here runs on an invented organisation. Nothing was ever run against a real Microsoft 365 tenant (the
organisation's own space in Microsoft 365: its accounts, its licences, which are the paid seats, and its sign-in rules).

## What you see

The manager's page (`manager.html`) shows the brief, the findings by rule, and each decision with its answer. Its first
lines, from `examples/brief/brief.md`:

<!-- pasted: file examples/brief/brief.md -->
```text
*Constructed, not from a model: this text was written by hand to the request, so that the checks and the pages can be shown. A recorded model answer is meant to replace it.*

On 21 November 2026 we checked 60 user accounts and 7 sign-in policies in Microsoft 365 for security gaps and unused licences.

**Security findings, most urgent first**
```

This brief was written by hand to the current request and is labelled **Constructed** here and on the pages: the
answers recorded from a model so far answered an earlier request (see *What is real here*). The whole story ends in this
table, drawn from a real run:

![The closing table of the demo: each rule, its count, the manager's decision, and what reached the work list](docs/img/demo.svg)

## Try it in two minutes

PowerShell 7.4 or later; nothing to install. The tests were run here with PowerShell 7.7.0 and 7.4.6 on Windows. The workflow
in .github/workflows/tests.yml is set to run them on Linux and on Windows; its first step prints the PowerShell version of
each runner, and the badge above shows the result of its last run. Each command writes into a new folder and refuses to
write over one that exists.

The whole story, on the invented tenant in `data/`:

<!-- pasted: run -->
```text
$ pwsh -NoProfile -File Invoke-Demo.ps1
Microsoft 365 hygiene demo: synthetic data, as of 2026-11-21
findings    OK       users 60 | policies 7 | security defaults off | R1 7 | R2 2 | R3 2 | R4 2 | R5 1 | R6 1 | R7 1 | R8 2 | reclaimable (invented units) 169.4 | people flagged 14 | decisions D1 D2 D3 D4 D5 D6
brief       OK       backend Recorded | text accepted True | problems 0 | summary sent to the API False | Constructed, not from a model
decisions   OK       5 answers recorded: D1 Yes, D2 Yes, D3 Yes, D4 No, D5 Yes; D6 left open
work list   OK       work list items 10 | from D1 D2 D3 D5 | answered No D4 | open D6
pages       OK       pages manager.html (stand-ins only, may leave this computer) and admin.html (names; stays on this computer) | brief: Constructed, not from a model

rule  finding                                          count  decision answer  work list
R3    enabled administrator without MFA registered         2  D1       Yes     2 items
R6    more than 4 global administrators                    1  D2       Yes     5 items
R7    legacy authentication not blocked                    1  D3       Yes     1 item
R8    over 30 days old, still in report-only mode          2  D4       No      -
R4    guest, no sign-in for 90 days or none on record      2  D5       Yes     2 items
R1    licensed, no sign-in for over 90 days                7  D6       open    -
R2    disabled, still licensed                             2  D6       open    -
R5    licensed, no sign-in on record, over 30 days old     1  D6       open    -

reclaimable each month: 169.4 invented units (not money) | the work list changes nothing in any tenant
```

Then open `out-demo/pages/manager.html` in a browser. It shows the brief and where its text came from, the findings by
rule with their counts and invented costs, and each decision with its question, its answer, who gave it and when. The
administrator's page, with the names and the work list, is `out-demo/pages/admin.html` beside it.

### The tests, and one failure case

The tests (what they cover, and the last lines of a run, are in [docs/TESTS.md](docs/TESTS.md)):

```text
pwsh -NoProfile -File Test-Demo.ps1
```

One case of the failure gallery (all nine are below):

<!-- pasted: run -->
```text
$ pwsh -NoProfile -File Invoke-Demo.ps1 -Case bad-date
case bad-date: the second row of the users table has a day-first date, 21/08/2026
findings    OK       REFUSED (exit 2): row 2: LastSignInDate is not yyyy-MM-dd or an ISO 8601 timestamp with Z or an offset
result      OK       nothing written: yes
case bad-date: as expected
```

## How it works

```mermaid
flowchart LR
    X[Collector: GET only<br/>Mock, never run<br/>against a tenant] -.-> A
    A[Users, licences, policies<br/>and tenant tables] --> B[Eight fixed rules<br/>and the decisions<br/>D1 to D6]
    B --> C[Findings with names<br/>stay on this computer]
    B --> D[Summary with stand-ins<br/>user-001, policy-001 ...]
    D --> E[Model writes a brief<br/>for the manager]
    E --> F{Figures, stand-ins,<br/>decision lines and<br/>names checked}
    F -- passes --> G[The brief]
    F -- fails --> H[Fixed template with<br/>the script's own figures]
    G --> I[Manager answers<br/>Yes or No]
    H --> I
    I --> J[Work list for the<br/>administrator]
    C --> J
    J --> K[Two pages: the manager's,<br/>the administrator's]
```

1. **`Get-TenantHygieneFindings.ps1`** reads up to four tables: users, licences, Conditional Access policies (the sign-in
   rules of the tenant: who may sign in, from where, and with what proof), and a tenant table that says whether
   security defaults (Microsoft's built-in baseline, which also blocks legacy authentication) are on. It applies eight
   fixed rules and writes the administrator's file with names, and a summary for the model and the manager in which every
   person and policy is a stand-in. The summary also carries the decisions, fixed by the script: each has an id, a plain
   question and the rules it covers, and it is asked only when one of those rules found something. A rule whose table is
   missing is reported as "not checked", with what is missing, never as 0.
2. **`New-ManagerBrief.ps1`** sends only that summary to a model and checks the brief it gets back: every run of digits
   must be a figure of the summary, every stand-in and rule id the summary's own, every decision on a line of its own
   with the summary's question word for word, and no name, part of a name or address from the users table may appear.
   A brief that fails is not used; a fixed template is filled with the script's own figures instead, and the report says
   why.
3. **`Set-BriefDecision.ps1`** records the manager's answer to one decision (Yes, or No with a reason), with the name the
   person types and the time, bound to that exact summary. An answer that overrides an earlier one keeps the earlier one
   in the file, and every page and list shows both.
4. **`New-AdminWorklist.ps1`** writes the administrator's work list: the accounts and items of the decisions answered
   Yes, each as a question to review, and nothing else. It changes nothing in the tenant.
5. **`New-HygieneReport.ps1`** writes the two pages: the manager's, with stand-ins only, which may leave the computer; and
   the administrator's, with the names and the work list, which says at its top that it stays.

Every place that shows a decision to be answered or acted on (both pages, what `Set-BriefDecision.ps1` prints, the work
list) takes its question from the summary, never from the model's text, and says so.

`Export-TenantSnapshot.ps1` would fill the four tables from Microsoft Graph, with GET requests only, and is labelled:
**Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.** Each request,
the documentation page it was written from, the permission, the Microsoft Entra roles and the licence it needs are in
[docs/COLLECTOR.md](docs/COLLECTOR.md).

| Rule | What it finds | Why it matters |
|---|---|---|
| R1 | An enabled account with a licence (a paid seat) and no sign-in for more than 90 days | licence cost |
| R2 | A disabled account that still holds a licence | licence cost |
| R3 | An enabled administrator without MFA registered (multi-factor authentication: a second sign-in step, such as a prompt on a phone). Disabled accounts are not judged: Microsoft's registration report does not list them, so their MFA state is not known | security |
| R4 | An enabled guest with no sign-in for more than 90 days, or with no sign-in on record and invited more than 30 days ago | security |
| R5 | An enabled, licensed member with no sign-in on record, created more than 30 days ago | licence cost |
| R6 | More than 4 accounts hold the Global Administrator role, enabled or not (one finding about the tenant) | security |
| R7 | No enforced Conditional Access policy blocks legacy authentication (older sign-in methods that cannot ask for a second step) for all users and all resources, and security defaults are off (one finding about the tenant; a report-only policy that would block it is named) | security |
| R8 | A Conditional Access policy created more than 30 days ago and still in report-only mode (it records what it would do and enforces nothing), or in that mode with no creation date (reported as unknown, never given an age) | security |

A user with no sign-in on record is judged by R5 or R4, never by R1, so no one is counted twice for the same cost. "No
sign-in on record" can also mean an earlier sign-in: Microsoft Graph's last successful sign-in is not backfilled before
1 December 2023. A date is `yyyy-MM-dd`, or an ISO 8601 timestamp with `Z` or an offset, which counts as its UTC date, and
is never after the as-of date; any other value, a sign-in address or policy id listed twice, a licence the licence table
lacks, or a department that holds a part of a person's name stops the run with its row number, and nothing is written.
The limits (90, 30, 4, 30) are parameters. The costs are exact decimals in units invented for the demo. The reasons behind
each choice are in [docs/DESIGN.md](docs/DESIGN.md).

### What the checks did not catch in real answers

The real answers recorded so far answered earlier requests, and are kept in `recordings/earlier/` with the request each
answered. What the checks missed in them is in [docs/DESIGN.md](docs/DESIGN.md), under *Limits of the checks*. Answers to
the current request are still to be recorded; what reading them shows will be listed here.

## What is real here

| Path | Label | What was actually run |
|---|---|---|
| The eight rules and their refusals | Local | Run by the tests and the demo, on invented tables |
| The checks on the brief | Local | Run by the tests on 29 wrong texts, and on every saved answer |
| The decisions, the work list and the two pages | Local | Run by the tests and the demo |
| The brief the demo uses, `recordings/brief.constructed.md` | Constructed | Written by hand to the current request, not by a model, and labelled so on every page; used as a known text by the tests too |
| The four answers in `recordings/earlier/` | Recorded | Real answers of one small model (claude-haiku-5-5) to two earlier requests, two each. They were given the request through a Claude Code subagent, which also runs under its harness's own system prompt, so they are not the live path's call. A test rebuilds each request from the prompt and summary stored beside the answers and checks its sha256; that the model wrote them rests on the author's record |
| The live model path (`-Backend Anthropic`) | Mock | Run against a local mock of the Messages API only |
| The collector (`Export-TenantSnapshot.ps1`) | Mock | Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant |

This has not been run against a tenant.

**What a command you can run shows:** that the rules, the checks, the refusals, the decisions, the work list and the
pages behave as described, on the invented data; that `examples/` is exactly what the demo writes, in any culture; that
the collector sends only GET requests to its fixed paths, as a mock records them; that each recorded answer is the file
added and answers the request it names; that every command and .NET type the scripts name is on a committed list.

**What rests on the author's word:** that the recorded answers came from the model and by the route their meta files name;
and that neither the collector nor the live model path was ever run against the real services.

## What can go wrong, and what happens

Each case runs alone with `-Case <name>`, or all together:

<!-- pasted: run -->
```text
$ pwsh -NoProfile -File Invoke-Demo.ps1 -Case all
case clean-tenant: one account, signed in yesterday, MFA registered; legacy authentication blocked
findings    OK       users 1 | policies 1 | security defaults off | R1 0 | R2 0 | R3 0 | R4 0 | R5 0 | R6 0 | R7 0 | R8 0 | reclaimable (invented units) 0 | people flagged 0 | decisions none
result      OK       every count is 0, nothing is reclaimable, and no decision is asked
case clean-tenant: as expected
case bad-date: the second row of the users table has a day-first date, 21/08/2026
findings    OK       REFUSED (exit 2): row 2: LastSignInDate is not yyyy-MM-dd or an ISO 8601 timestamp with Z or an offset
result      OK       nothing written: yes
case bad-date: as expected
case invented-figure: the demo's brief, with a sentence added that holds a figure the summary does not hold
brief       OK       text refused: figures not in the summary: 500
result      OK       brief.md is the fixed template with the script's own figures, and brief-report.json says why
case invented-figure: as expected
case missing-decision: the demo's brief, with the line of decision D4 taken out
brief       OK       text refused: a decision left out: D4
result      OK       brief.md is the fixed template with the script's own figures, and brief-report.json says why
case missing-decision: as expected
case decision-no: D5 (remove the stale guests) is answered No; D1 (MFA for administrators) Yes
work list   OK       work list items 2 | from D1 | answered No D5 | open D2 D3 D4 D6
result      OK       rows for R4 (D5, No): 0 | rows for R3 (D1, Yes): 2
case decision-no: as expected
case other-summary: a decisions file written for one summary is put beside another
decision    OK       REFUSED (exit 2): decisions.json was written for another summary; it is left as it is
work list   OK       REFUSED (exit 2): decisions.json was written for another summary; it is left as it is
result      OK       the decisions file is byte for byte as it was: yes | no work list written: yes
case other-summary: as expected
case collector-throttled: the local Graph mock answers the licence request with 429 and Retry-After: 1, once
collector   OK       snapshot users 6 | licences 2 | policies 2 | security defaults off | GET requests 8 | throttled waits 1 | Mock: never run against a tenant
result      OK       requests the mock received: 8 GET, 0 other
case collector-throttled: as expected
case collector-403: the local Graph mock answers the users request with 403
collector   OK       REFUSED (exit 3): GET users answered HTTP 403; nothing was written
result      OK       requests the mock received: 1 GET, 0 other
case collector-403: as expected
case model-500: the live model path, against a local mock of the Messages API that answers 500
brief       OK       REFUSED (exit 3): the API call failed; nothing was written
result      OK       requests the mock received: 1; nothing written: yes
case model-500: as expected
cases 9 | as expected 9 | not as expected 0
```

"OK" on a line means the step ended as the case expects, a refusal included. The mocks listen on this computer only.

## Recording a real model answer

This is how the answers in `recordings/earlier/` were added, each to the request of its day. The request is the fixed
prompt and the stand-in summary, nothing else. This writes the current request to a file, exactly as it would be sent:

<!-- pasted: run -->
```text
$ pwsh -NoProfile -File New-ManagerBrief.ps1 -SummaryJson examples/findings/findings-summary.json -UsersCsv data/users.synthetic.csv -WriteRequest request.txt
wrote the request | bytes 6668 | sha256 e924e44d63b16df54fac0564c15c0e227d5ce5b3f70fb5d5703b814d21aae9de
```

Give that text, as the whole prompt, to a model; save its answer unedited; then add it with `Add-RecordedBrief.ps1`,
which copies the answer byte for byte, writes its meta file (origin "recorded", the model's name, how it was obtained,
the date), and refuses if the request file is not the request the script builds today:

```text
pwsh -NoProfile -File Add-RecordedBrief.ps1 -Answer answer.md -RequestFile request.txt -SummaryJson examples/findings/findings-summary.json -Model <model name> -Obtained "<how it was obtained>" -RecordedOn <yyyy-MM-dd> -Name brief.recorded
```

Then pass `-Recorded recordings/brief.recorded.md` to `New-ManagerBrief.ps1`; without it, the brief is the constructed
one, `recordings/brief.constructed.md`. The live path is `-Backend Anthropic`, with the key in the `ANTHROPIC_API_KEY`
environment variable; it is never printed or written, with `-Debug` or `-Verbose` too.

## Limits, stated plainly

- **Invented data, and not run against a tenant.** A real job adds the organisation's own data, the permissions to read
  it, and an agreement on how the data is handled. Sign-in data in a real tenant has gaps of its own. The rules would be
  tuned to the tenant.
- **R6 to R8 depend on tables a real tenant fills differently.** Role holders that are groups, eligible role
  assignments, policies scoped to groups or with user exclusions, and policies switched into report-only mode after they
  were created all need a person's reading; R8 counts days from a policy's creation, and reports a policy with no
  creation date as of unknown age.
- **The collector's first real run would have to confirm its permissions, its roles, its paging and its answers on a
  live tenant** (the list is at the end of [docs/COLLECTOR.md](docs/COLLECTOR.md)). It reads the documentation's account
  of each request, not a tenant.
- **A decision records the name a person types.** It is not checked against any directory and proves nothing about who
  typed it. The manager's page shows that name as typed, so a manager who is also in the users table appears there by name,
  as the one who decided. The order of the answers is the file's order, and a later answer may not carry an earlier time;
  a person who edits the file by hand can still rewrite it whole, and nothing here would tell.
- **The summary is pseudonymised, not anonymous.** It still carries each flagged person's department, licences and days
  since sign-in, and in a small tenant that can point to one person. A department is free text: the check that it names
  no one catches only the tenant's own people, by the words of their names and addresses, not a nickname or a role that
  points to one person. A name part that is also an everyday word (a person called Will) stops the manager's page.
- **The checks on the brief have gaps.** They do not catch a number written in words, a sentence the request asked for
  and the answer left out, a right number attached to the wrong finding, or a percentage or scale word around a valid
  number ("100%", "169.4 thousand"). They read the decision lines, not what the brief says around them. Only names the
  users table holds are looked for; a part of a name that the request itself uses as a word, and the number words one
  to ten, are not; nor, before sending, is a display name that is also a department name.
- **The label "Recorded" proves that the answer and the request are the ones in the meta file,** not who or what wrote
  the answer.
- **The live model path was tested against a local mock only**, not against the real service.
- **A few recorded briefs are not a measure of quality.** Whether the wording is right for a given manager is a person's
  call.
- **The costs are invented units.** No saving in money is shown or promised.
- This is a demonstration of a design, not a product and not a record of client work.

## How this was built

The rules follow the author's own earlier administration scripts and checklist, rewritten for this repository. The
design is in [docs/DESIGN.md](docs/DESIGN.md), the tests in [docs/TESTS.md](docs/TESTS.md), the collector's sources in
[docs/COLLECTOR.md](docs/COLLECTOR.md). `examples/` is the real output of the whole story; `Update-Examples.ps1` writes it
again, and the CI workflow is set to fail on any difference. The invented tenant in `data/` is what `New-SyntheticTenant.ps1` writes for the
seed named in `data/tenant-source.txt`.

## Usage conditions

- MIT licence: see [LICENSE](LICENSE). The software is provided as is, without warranty of any kind.
- All the data is invented: the people at demo.example.com, marked "(synthetic)", the licence names and the costs.
- This is an independent demo, not affiliated with or endorsed by Microsoft or Anthropic. Microsoft 365 and Entra are
  Microsoft's trademarks; Claude is Anthropic's.
- It has never been run against a tenant. Pointing the collector at one is the reader's own decision and responsibility.

## Author

Built by Evgeny Blekhman. Written with Claude Code under the author's direction.
[linkedin.com/in/evgeny-blekhman](https://www.linkedin.com/in/evgeny-blekhman/)
