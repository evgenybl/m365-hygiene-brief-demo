# Design: the decisions behind the scripts, and why

## The division of work

- **The script finds; the model words; a person decides; the administrator acts.** The eight rules are fixed code. The
  decisions a manager is asked (D1 to D6) are fixed by the same script, each with the rules it covers, and a decision is
  asked only when one of its rules found something. The model only writes the brief around them, and the check proves
  that every decision id of the summary appears in it exactly once and that no other does. So a model cannot add, drop
  or merge a decision.
- **The work list follows only from answers.** A Yes puts that decision's accounts and items on the administrator's list;
  a No or no answer puts nothing there, and the list says so. Names come from the administrator's own file, never from
  the model. The list changes nothing: it is for a person to work through.

## One summary, bound end to end

Each later step checks that it is working on the same findings summary, by its sha256:

1. `New-ManagerBrief.ps1` copies the summary byte for byte into the brief folder and records its sha256, and the sha256
   of the brief it wrote, in `brief-report.json`.
2. `Set-BriefDecision.ps1` refuses a brief folder whose summary no longer has that sha256, and writes `decisions.json`
   bound to it. A decisions file for another summary is refused and left as it is. Answers are appended; the last answer
   for an id counts.
3. `New-AdminWorklist.ps1` refuses unless the findings folder, the brief folder and the decisions file are about one
   summary, and records the sha256 of the summary and of the decisions file it used.
4. `New-HygieneReport.ps1` refuses a brief changed after it was checked, and a work list older than the decisions.

## The label on the brief is earned

A saved answer has a meta file beside it. The pages say "Recorded" only when the meta file says origin "recorded" and both
the answer's sha256 and the request's sha256 match the ones it holds; "Constructed, not from a model" for a text written
by hand to the current request; otherwise "Unverified", with the reason. The hashes prove that the files are the ones
recorded and that the request is the one the script builds today. That the answer came from the named model rests on the
word of whoever recorded it. The label names the model and the date; the meta file's account of how the answer was
obtained goes into the brief's report and onto the pages.

The demo's brief is `recordings/brief.recorded.md`, a real answer of one small model (claude-haiku-5-5) to the request
the shipped data gives; `recordings/brief.recorded-2.md` is a second answer to the same request. Both were given the
request through a Claude Code subagent, which also runs under its harness's own system prompt, so neither is the live
path's call. Both pass every check, and a test checks that each still earns its label.

`recordings/brief.constructed.md` is written by hand and labelled "Constructed, not from a model". Only the tests use it,
as a known text: for the checks on decision ids, the label tests, the tests of `Add-RecordedBrief.ps1`, the tests of the
decisions, the work list and the pages, and as the reply of the mocked model API.

The two answers recorded for the earlier, five-rule request are kept in `recordings/earlier/` with the earlier prompt
and summary; a test rebuilds that request and checks its sha256, so they still earn their label against the request
they answered. One of them is refused by the figure check, which is kept as a lesson: the check prefers the fixed
template to a text it cannot confirm.

## Limits of the checks, seen in the two real answers

Both recorded answers to today's request pass every check. Read by a person, they show what the checks do not test.

<!-- quotes: recordings/brief.recorded.md -->
A sentence the request asks for can be missing. The first answer does not say that the finding about Global
Administrators names no person: "Global Administrator accounts: 5, where the limit is 4. Each extra top-level administrator is another way in and another person who can change everything."
It says so for the two policy findings: "This is a tenant-wide setting and names no person." and "These are policy settings and name no person."
The check has no rule for that sentence.

<!-- quotes: recordings/brief.recorded-2.md -->
A count written in words is not checked. The second answer writes most of its counts so: "Three administrator accounts have no second sign-in step (MFA) set up.",
"Five accounts", "Two guest accounts", "Seven enabled accounts". The figure check reads digits only, so those counts were
not checked by code.

<!-- quotes: recordings/brief.recorded.md -->
A reason given in the model's own words is not checked. The first answer: "a stolen password is enough to take over an account that can change the whole system".

<!-- quotes: recordings/brief.recorded-2.md -->
The second: "they give a false sense of protection". Both are reasonable, and nobody verified them.

No code check was added for these: they are about meaning, and a rule for one wording would miss the next. A manager's
brief is read by a person before it reaches the manager, because the checks prove only what they test (figures written
in digits, ids, stand-ins and names), not that each sentence is right or complete.

## People and places in the outputs

- The summary for the model, and the manager's page, carry stand-ins (`user-001`, `policy-001`), never a name or an
  address. A finding about the tenant (R6, R7) or about a policy (R8) has no person in it.
- The manager's page is searched for every address and full display name of the users table before it is written; one
  found stops the run. The name a person typed for a decision is shown as typed, and is the one exception, so a manager
  who is also in the table appears as the one who decided.
- Every text from a table, a model or a person is HTML-escaped. The pages hold no script and load nothing, and declare a
  content security policy that allows inline styles only.
- A CSV cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return is written with a leading apostrophe, so a
  spreadsheet does not read it as a formula. A typed name that starts like a formula is refused outright.

## Numbers, dates and the same bytes everywhere

- **Costs are exact decimals.** The tables are parsed as `[decimal]` with the invariant culture, and the JSON files carry
  costs as decimal strings (`"169.4"`): `ConvertTo-Json` writes a whole decimal as `390.0`, and `ConvertFrom-Json` reads a
  number with a fraction as floating point. A test shows 0.1 + 0.2 written as 0.3.
- **Times are read exactly.** `ConvertFrom-Json` turns an ISO 8601 timestamp into a DateTime, so files that hold times
  (decisions, meta files, the work list) are read with `System.Text.Json`, which keeps strings as strings.
- **"Today" is always a parameter.** The as-of date, the generator's date and the time of each decision in the demo are
  given, so the examples are the same on every day and in every time zone. The one read of the clock is the default time
  of a decision typed without `-At`, and it is in UTC.
- **Culture.** Every parse and print of a number or a date names the invariant culture. Each step of the demo and of the
  tests runs in a child process under the culture of the run that started it (`lib/Invoke-Step.ps1`), so a run started
  under de-DE tests every script under de-DE. A test compares the whole demo under de-DE with `examples/`, byte for byte.
- **Files.** Every file is written as UTF-8 without a byte order mark and with LF line ends; `.gitattributes` keeps them
  so. Sorting that reaches an output follows the input's order or an ordinal comparison, never the culture's.
- **The invented tenant** comes from `New-SyntheticTenant.ps1`, with its own 32-bit generator in integer arithmetic, so
  the same seed gives the same bytes on every machine and PowerShell version. A test regenerates `data/` and compares.

## The rules that are new here

- **R6** counts every account holding Global Administrator, enabled or not: a disabled holder still holds the role.
- **R7** follows the policy Microsoft's page describes for blocking legacy authentication (see `COLLECTOR.md`): enabled,
  all users, all resources, Exchange ActiveSync and other clients, block, and no other condition. A risk-based block for
  all users does not count, because it blocks only when the risk condition holds; the policies table carries the other
  conditions for that reason.
- **R8** counts days from the policy's creation date, the only date the policy holds; a policy switched into report-only
  mode later is counted from its creation. A policy with no creation date is reported as of unknown age; no date is
  invented for it.

## The collector

GET only, to a fixed list of five paths written from the documentation, plus the next-page links those answers return,
and only when such a link keeps the same host and path. Redirects are not followed. The token goes only to Microsoft
Graph or to this computer. Everything is held in memory until every request has succeeded, so a stop writes nothing.
Throttling is waited for, a bounded number of times. Tests read the script to prove the method and the paths, and run it
against a local mock that records every request it receives.

## Failing closed

Every script computes everything before it creates its output folder, refuses to write into an existing one, and exits
with 2 on a refusal (with the row number for a table) and 3 when a call to an outside service fails. Nothing is written
on either.
