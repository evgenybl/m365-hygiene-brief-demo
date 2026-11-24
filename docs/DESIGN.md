# Design: the decisions behind the scripts, and why

## The division of work

- **The script finds; the model words; a person decides; the administrator acts.** The eight rules are fixed code. The
  decisions a manager is asked (D1 to D6) are fixed by the same script, each with its question and the rules it covers,
  and a decision is asked only when one of its rules found something.
- **What the check on the decisions enforces, exactly.** Each decision of the summary must appear in the brief once, at
  the start of a line of its own (after an optional list marker or bold), followed by a separator and the summary's
  question word for word, with nothing else on that line but an optional closing "Yes or no?". A decision id anywhere
  else, an id the summary does not hold, a decision left out or named twice, or a question that differs by one word
  refuses the text. So the brief cannot reword, swap or hide a decision. It can still frame a decision unfairly in the
  sentences around it: the check does not read those.
- **The question shown for answering is always the summary's.** Both pages, what `Set-BriefDecision.ps1` prints, and the
  work list take each question from the findings summary, never from the brief, and say so; the brief's wording is
  checked against it but never used for a decision.
- **The work list follows only from answers.** A Yes puts that decision's accounts and items on the administrator's list,
  each as a question to review rather than an order; a No or no answer puts nothing there, and the list says so. Names
  come from the administrator's own file, never from the model. The list changes nothing: it is for a person to work
  through.
- **A rule that could not be checked says so.** When its input is missing (R6 without an AdminRoles column; R7, unless
  security defaults are on, without the policies table, with an older one that lacks the ExcludeApplications and
  ApplicationFilter columns, or without the tenant table when no enforced policy blocks legacy authentication; R8
  without the policies table), the summary gives it no count and a "not_checked" reason, and the brief, the pages and
  the work list show "not checked" and the reason, never 0. So the original two-table command still runs, and so does
  a policies table written before the two columns existed.

## One summary, bound end to end

Each later step checks that it is working on the same findings summary, by its sha256:

1. `New-ManagerBrief.ps1` copies the summary byte for byte into the brief folder and records its sha256, and the sha256
   of the brief it wrote, in `brief-report.json`.
2. `Set-BriefDecision.ps1` refuses a brief folder whose summary no longer has that sha256, and writes `decisions.json`
   bound to it. A decisions file for another summary is refused and left as it is.
3. `New-AdminWorklist.ps1` refuses unless the findings folder, the brief folder and the decisions file are about one
   summary, and records the sha256 of the summary and of the decisions file it used.
4. `New-HygieneReport.ps1` refuses a brief changed after it was checked, and a work list older than the decisions.

**The order of the answers, and what protects it.** Answers are appended to `decisions.json` and never rewritten, so the
file's order is the order they were given, and the last answer to an id counts. `Set-BriefDecision.ps1` refuses an answer
whose time is earlier than the last answer to the same id, so that order is also the order in time. Every script that
reads the file checks it first: its shape (an object with `summary_sha256` and `answers`, nothing else), each answer
(exactly `decision`, `answer`, `by`, `at` and `reason`; a decision of the summary; `Yes` or `No`; a name and a reason that
pass the same rules as when typed; a UTC time), and the order in time. A file that fails is refused and left as it is.
Every output that shows a decision shows how many answers it has and the earlier ones (who, when, what), so an
overridden answer is never hidden. What this does not protect: the file is not signed, so a person with access to it can
rewrite it whole, in a valid shape and order, and nothing here would tell.

## The label on the brief is earned

A saved answer has a meta file beside it. The pages say "Recorded" only when the meta file says origin "recorded", both
the answer's sha256 and the request's sha256 match the ones it holds, and its model name, date (`yyyy-MM-dd`) and
account of how the answer was obtained are well formed; "Constructed, not from a model" for a text written by hand to the
current request; otherwise "Unverified", with the reason. The hashes prove that the files are the ones recorded and that
the request is the one the script builds today. That the answer came from the named model rests on the word of whoever
recorded it. The label names the model and the date; the meta file's account of how the answer was obtained goes into
the brief's report and onto the pages.

The demo's brief is `recordings/brief.constructed.md`, written by hand to the current request and labelled
"Constructed, not from a model". The tests use it too, as a known text.

The real answers are in `recordings/earlier/`, each folder with the two files its request was built from (the prompt and
the summary); `recordings/earlier/README.md` names each request and its sha256. A test rebuilds each request from those
two files and checks its sha256, so the answers still earn their label against the request they answered. All four were
given the request through a Claude Code subagent, which also runs under its harness's own system prompt, so none is the
live path's call.

## Limits of the checks, seen in the real answers

The two answers to the second earlier request pass every check, the stricter ones of today included. Read by a person,
they show what the checks do not test.

<!-- quotes: recordings/earlier/second-request/brief.recorded.md -->
A sentence the request asks for can be missing. The first answer does not say that the finding about Global
Administrators names no person: "Global Administrator accounts: 5, where the limit is 4. Each extra top-level administrator is another way in and another person who can change everything."
It says so for the two policy findings: "This is a tenant-wide setting and names no person." and "These are policy settings and name no person."
The check has no rule for that sentence.

<!-- quotes: recordings/earlier/second-request/brief.recorded-2.md -->
A count written in words is not checked. The second answer writes most of its counts so: "Three administrator accounts have no second sign-in step (MFA) set up.",
"Five accounts", "Two guest accounts", "Seven enabled accounts". The figure check reads digits only, so those counts were
not checked by code.

<!-- quotes: recordings/earlier/second-request/brief.recorded.md -->
A reason given in the model's own words is not checked. The first answer: "a stolen password is enough to take over an account that can change the whole system".

<!-- quotes: recordings/earlier/second-request/brief.recorded-2.md -->
The second: "they give a false sense of protection". Both are reasonable, and nobody verified them.

<!-- quotes: recordings/earlier/first-request/recorded-brief.md -->
A list number can pass by luck. The accepted answer to the first request numbers its decisions with digits, as in
"1. Do you approve requiring a second sign-in check (MFA)"; a digit at the start of a line now counts as a figure, and
the 1, 2 and 3 pass only because the summary of that request holds those numbers. The other answer to that request is
refused for its list number 4 and for a 5 it cites from its own list.

No code check was added for the meaning of a sentence: a rule for one wording would miss the next. A manager's brief is
read by a person before it reaches the manager, because the checks prove only what they test (figures written in digits,
ids, the decision lines, stand-ins and names), not that each sentence is right or complete.

## People and places in the outputs

- The summary for the model, and the manager's page, carry stand-ins (`user-001`, `policy-001`), never a name or an
  address. A finding about the tenant (R6, R7) or about a policy (R8) has no person in it.
- A department and a licence name reach the summary, so step 1 refuses a row whose department or licence name holds a
  part of the name or sign-in address of any person in the users table (each word of three letters or more of the
  display name, without a note in brackets, and of the address before the at sign; for a guest, before its home domain;
  any letter case; the number words one to ten left out), and names the rows. An account whose display name is a
  department's name (an account named after its team) is not a person here. The limit: a department is free text, and
  this catches only the tenant's own people, by the words of their names, not a nickname or a role.
- The manager's page is searched, before it is written, for every address, full display name and name part of the users
  table; one found stops the run and names the row, not the name. The names a person typed for a decision are the one
  exception, so a manager who is also in the table appears as the one who decided. A name part that is also an everyday
  word on the page (a person called Will) stops the page too: the check prefers a refusal to a guess.
- Every text from a table, a model or a person is HTML-escaped on the pages, and Markdown-escaped in the work list. The
  pages hold no script and load nothing, and declare a content security policy that allows inline styles only. An
  answer's colour on the pages comes from a fixed list, never from the file.
- A typed name or reason is refused when it holds a control character, a line break or an invisible format character
  (such as a right-to-left override), so it cannot forge a line of the work list or reorder what a reader sees.
- A CSV cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return is written with a leading apostrophe, so a
  spreadsheet does not read it as a formula. A typed name that starts like a formula is refused outright.

## Numbers, dates and the same bytes everywhere

- **The figure check.** Every run of digits in the brief is a figure, and must be a number the summary holds: at the
  start of a line, glued to a word, in a date (counted as its parts). Only a stand-in, a rule id, a decision id at the
  start of its decision line, and the exact product names "Microsoft 365" and "M365" are left out, so "Microsoft 3657"
  and "M36590" are figures. A numeric character other than 0 to 9 (another script's digits, a superscript, a Roman
  numeral) refuses the text.
- **Costs are exact decimals.** The tables are parsed as `[decimal]` with the invariant culture, and the JSON files carry
  costs as decimal strings (`"169.4"`): `ConvertTo-Json` writes a whole decimal as `390.0`, and `ConvertFrom-Json` reads a
  number with a fraction as floating point. A test shows 0.1 + 0.2 written as 0.3.
- **Times are read exactly.** `ConvertFrom-Json` turns an ISO 8601 timestamp into a DateTime, so files that hold times
  (decisions, meta files, the work list) are read with `System.Text.Json`, which keeps strings as strings.
- **"Today" is always a parameter.** The as-of date, the generator's date and the time of each decision in the demo are
  given, so the examples are the same on every day and in every time zone. The one read of the clock is the default time
  of a decision typed without `-At`, and it is in UTC. A date after the as-of date is refused.
- **Culture.** Every parse and print of a number or a date names the invariant culture. Each step of the demo and of the
  tests runs in a child process under the culture of the run that started it (`lib/Invoke-Step.ps1`), so a run started
  under de-DE tests every script under de-DE. A test compares the whole demo under de-DE with `examples/`, byte for byte.
- **Files.** Every file is written as UTF-8 without a byte order mark and with LF line ends; `.gitattributes` keeps them
  so. Sorting that reaches an output follows the input's order or an ordinal comparison, never the culture's.
- **The invented tenant** comes from `New-SyntheticTenant.ps1`, with its own 32-bit generator in integer arithmetic, so
  the same seed gives the same bytes on every machine and PowerShell version. A test regenerates `data/` and compares.

## The rules that are new here, and the wording of the old ones

- **R3 judges enabled administrators only.** Microsoft's registration report "doesn't work for disabled users", so for a
  disabled administrator the MFA state is not known; calling it "without MFA" would claim what the data cannot show. A
  disabled administrator is still counted by R6 when it holds Global Administrator, and by R2 when it holds a licence.
- **"No sign-in on record", not "never signed in".** The collector reads the last successful sign-in, which Microsoft
  Graph does not backfill before 1 December 2023: an account with no sign-in on record may have been used before that.
  R4 and R5 say so, and the summary carries the note.
- **R6** counts every account holding Global Administrator, enabled or not: a disabled holder still holds the role.
- **R7** says whether legacy authentication is blocked at all: no enforced (enabled) Conditional Access policy blocks it,
  and security defaults, which block it too ("After security defaults are enabled in your tenant, all authentication
  requests made by an older protocol will be blocked", in Microsoft's page), are off. A policy blocks it when it follows
  the policy Microsoft's page describes (see `COLLECTOR.md`): all users, all resources with none excluded and no resource
  filter, Exchange ActiveSync and other clients, block, and no other condition. A risk-based block for all users does
  not count, because it blocks only when the risk condition holds; a policy that excludes an application, or selects
  resources by a filter, does not cover all resources. A policy that would block it but is in report-only mode is named
  by its stand-in in R7's finding and in the question D3, and R8, which also lists it, gives it the same stand-in, so
  D3 and D4 are seen to be about the same policy.
- **R8** counts days from the policy's creation date, the only date the policy holds; a policy switched into report-only
  mode later is counted from its creation. A policy with no creation date is reported as of unknown age; no date is
  invented for it.
- Rows that contradict each other are refused by number: a sign-in address or a policy id listed twice, a licence the
  licence table lacks (on any row, flagged or not), a date after the as-of date.

## The collector

**Mock: written from Microsoft's documentation, tested against a local mock, never run against a tenant.**

GET only, to a fixed list of six paths written from the documentation, plus the next-page links those answers return,
and only when such a link keeps the same scheme, host and path. Redirects are not followed. The token goes only to
Microsoft Graph or to this computer, and is never printed, `-Debug` and `-Verbose` included: the web call is made with
both switched off. Each answer must have the shape the documentation shows (a collection page with a `value` array; the
security defaults object with a true or false `isEnabled`); an HTML page, an error object or an empty body stops the run
rather than pass for an empty collection. Throttling is waited for, a bounded number of times; a Retry-After that asks
for more than the limit, or that is not a number of seconds, stops the run at once and says so. Everything is held in
memory until every request has succeeded, so a stop writes nothing. Tests read the script to prove the method and the
paths, and run it against a local mock that records every request it receives.

## What the code can call

Rather than a list of forbidden commands, which a new command slips past, the tests hold the list of what is allowed.
For every script, the PowerShell parser lists each command it names, each call through `&` or `.` whose target is not a
plain name, each type or COM name given to `New-Object`, and each .NET type it uses for a static member, a cast or a
parameter. The tests compare that with the committed `tests/allowed-commands.txt`: a command or type that is not on the
list fails them, and so does a line of the list the code no longer needs. The list itself holds no Microsoft Graph,
Azure, Entra, Exchange or mail command and no web client type. What this proves: the scripts name nothing beyond the
list, so adding a tenant-changing command or another web client takes a deliberate change to the list. What it does not
prove: what an allowed object could reach by reflection, which the list cannot see. The two web calls are checked apart:
one POST to the model API and one GET in the collector, neither following a redirect.

## Failing closed

Every script computes everything before it creates its output folder, refuses to write into an existing one, and exits
with 2 on a refusal (with the row number for a table) and 3 when a call to an outside service fails. Nothing is written
on either.
