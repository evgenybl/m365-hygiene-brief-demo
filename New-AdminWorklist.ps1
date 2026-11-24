#requires -Version 7.4
<#
.SYNOPSIS
    Writes the administrator's work list from the manager's recorded decisions. It is a list for a person; it changes
    nothing.

.DESCRIPTION
    Only the rules of a decision answered Yes (its last answer) contribute: each of their accounts and tenant items, with
    the rule, what to review, the decision's id, and who answered and when. A decision answered No contributes
    nothing, and neither does one never answered; the list names both. Each decision is shown with its question as the
    findings summary holds it (never the brief's wording), with how many answers it has and the earlier ones. A rule
    the summary marks "not checked" is listed as such, with what was missing.

    The names come from the administrator's own file (findings-admin.csv in the findings folder), never from a model.
    The findings folder, the brief folder and decisions.json must all be about one summary: the summary in the brief
    folder must have the same sha256 as the one in the findings folder, and decisions.json must be bound to it and pass
    its checks (its shape, each answer's fields and values, and their order). Otherwise nothing is written (exit 2).

    It writes three files into a new folder: worklist.csv (for a spreadsheet; a cell that starts like a formula gets a
    leading apostrophe), worklist.md (to read; every value from a table or a person is escaped, so it shows as text and
    never as Markdown), and worklist.json (what the report pages read, with the sha256 of the summary and of the
    decisions file it was made from).

.EXAMPLE
    pwsh -File New-AdminWorklist.ps1 -FindingsDir out-demo/findings -BriefDir out-demo/brief -OutDir out-worklist
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $FindingsDir,
    [Parameter(Mandatory)] [string] $BriefDir,
    [Parameter(Mandatory)] [string] $OutDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }
$findingsSummary = Join-Path $FindingsDir 'findings-summary.json'
$briefSummary = Join-Path $BriefDir 'findings-summary.json'
$adminCsv = Join-Path $FindingsDir 'findings-admin.csv'
foreach ($p in @($findingsSummary, $briefSummary, $adminCsv)) { if (-not (Test-Path -LiteralPath $p)) { Stop-Refused "missing: $p" } }
$summarySha = Get-FileSha256 $findingsSummary
if ((Get-FileSha256 $briefSummary) -ne $summarySha) { Stop-Refused 'the brief folder holds another summary than the findings folder' }

$summary = Read-JsonExact $findingsSummary
$decisions = @(@(Get-Field $summary 'decisions') | Where-Object { $_ })
$decisionIds = @($decisions | ForEach-Object { $_['id'] })
$decisionsPath = Join-Path $BriefDir 'decisions.json'
$decisionsSha = ''
$history = [ordered]@{}
if (Test-Path -LiteralPath $decisionsPath) {
    $history = Get-AnswerHistory (Read-DecisionsFile $decisionsPath $summarySha $decisionIds)
    $decisionsSha = Get-FileSha256 $decisionsPath
}

# What to review, written as questions for the administrator: the work list asks, it does not order a change.
$review = @{
    R1 = 'Is the account still in use? If not, return its licence.'
    R2 = 'The account is disabled and still holds a licence: is the licence kept on purpose (for example for a mailbox that must stay)? If not, return it.'
    R3 = 'Can this administrator register a second sign-in step (MFA), or does the account still need its role?'
    R4 = 'Does the guest still need access? If not, remove the guest.'
    R5 = 'The account has no sign-in on record: is it needed? If not, return its licence.'
    R6 = 'Does this account need the Global Administrator role? Bring the holders down to the limit.'
    R7 = 'Is legacy authentication still in use (the sign-in logs show the client app)? If not, switch on a policy that blocks it, such as the report-only one named here.'
    R8 = 'Switch the policy on, or remove it?'
}
$rows = @(Import-Csv -LiteralPath $adminCsv -Encoding utf8)
$items = [System.Collections.Generic.List[object]]::new()
$yes = @(); $no = @(); $open = @()
foreach ($d in $decisions) {
    $list = @(if ($history.Contains($d['id'])) { $history[$d['id']] })
    if ($list.Count -eq 0) { $open += $d['id']; continue }
    $a = $list[$list.Count - 1]
    $earlier = Format-EarlierAnswers $list -WithReason
    if ($a['answer'] -ne 'Yes') {
        $no += [ordered]@{ decision = $d['id']; by = $a['by']; at = $a['at']; reason = $a['reason']; answers = $list.Count; earlier = $earlier }
        continue
    }
    $yes += $d['id']
    foreach ($rule in @($d['rules'])) {
        foreach ($r in @($rows | Where-Object { $_.Rule -eq $rule })) {
            $item = if ($r.Upn) { $r.Upn } elseif ($r.Scope -eq 'tenant') { '(the tenant)' } else { '(a policy)' }
            $items.Add([ordered]@{ Decision = $d['id']; Question = $d['question']; Rule = $rule; Scope = $r.Scope; Item = $item; Name = $r.Name; Detail = $r.Detail
                WhatToReview = $review[$rule]; DecidedBy = $a['by']; DecidedAt = $a['at']; Answers = $list.Count })
        }
    }
}
$notChecked = @(@($summary['rules']) | Where-Object { $_ -and $_.Contains('not_checked') } | ForEach-Object { [ordered]@{ rule = $_['id']; title = $_['title']; missing = $_['not_checked'] } })

$csv = ConvertTo-CsvText $items.ToArray() @('Decision', 'Question', 'Rule', 'Scope', 'Item', 'Name', 'Detail', 'WhatToReview', 'DecidedBy', 'DecidedAt', 'Answers')
$md = [System.Collections.Generic.List[string]]::new()
function MdText([object] $Value) { ConvertTo-MarkdownText $Value }
$md.Add('# Work list for the administrator')
$md.Add('')
$md.Add(('As of {0}. Made from the decisions recorded for the summary with sha256 {1}.' -f (MdText $summary['as_of']), $summarySha))
$md.Add('This is a list for a person to work through. Nothing here has been changed in any tenant, and this list changes nothing.')
$md.Add('Each question below is the findings summary''s own, fixed by the script; the brief''s wording of it is not used.')
$md.Add('')
foreach ($id in $yes) {
    $d = @($decisions | Where-Object { $_['id'] -eq $id })[0]
    $list = $history[$id]
    $a = $list[$list.Count - 1]
    $md.Add(('## {0}: Yes, by {1} at {2}' -f $id, (MdText $a['by']), (MdText $a['at'])))
    $md.Add('')
    $md.Add((MdText $d['question']))
    $md.Add('')
    $earlier = Format-EarlierAnswers $list -WithReason
    $md.Add(('Answers to {0}: {1}. {2}' -f $id, $list.Count, $(if ($earlier) { 'Earlier: ' + (MdText $earlier) + '. The last answer counts.' } else { 'This is the only one.' })))
    $md.Add('')
    foreach ($i in @($items | Where-Object { $_['Decision'] -eq $id })) {
        $who = if ($i['Name']) { '{0} ({1})' -f (MdText $i['Name']), (MdText $i['Item']) } else { MdText $i['Item'] }
        $detail = if ($i['Detail']) { ' ' + (MdText $i['Detail']) + '.' } else { '' }
        $md.Add(('- [ ] {0} {1}.{2} {3}' -f $i['Rule'], $who, $detail, (MdText $i['WhatToReview'])))
    }
    $md.Add('')
}
$md.Add('## Not on this list')
$md.Add('')
foreach ($n in $no) {
    $md.Add(('- {0}: answered No by {1} at {2}. Reason: {3} Answers to {0}: {4}{5}' -f $n['decision'], (MdText $n['by']), (MdText $n['at']), (MdText $n['reason']), $n['answers'],
        $(if ($n['earlier']) { '; earlier: ' + (MdText $n['earlier']) + '.' } else { '.' })))
}
foreach ($id in $open) { $md.Add(('- {0}: still open, no answer recorded.' -f $id)) }
if (-not ($no.Count + $open.Count)) { $md.Add('- Nothing: every decision was answered Yes.') }
if ($notChecked.Count) {
    $md.Add('')
    $md.Add('## Not checked')
    $md.Add('')
    foreach ($n in $notChecked) { $md.Add(('- {0} {1}: not checked, because {2}.' -f $n['rule'], (MdText $n['title']), (MdText $n['missing']))) }
}

$json = [ordered]@{
    summary_sha256 = $summarySha; decisions_sha256 = $decisionsSha
    yes = @($yes); no = @($no); open = @($open); not_checked = @($notChecked); items = $items.ToArray()
}

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'worklist.csv') $csv
Write-LineFile (Join-Path $OutDir 'worklist.md') $md.ToArray()
Write-TextFile (Join-Path $OutDir 'worklist.json') ((ConvertTo-JsonText $json) + "`n")
Write-Output ('work list items {0} | from {1} | answered No {2} | open {3}{4}' -f $items.Count,
    $(if ($yes.Count) { $yes -join ' ' } else { 'none' }), $(if ($no.Count) { ($no | ForEach-Object { $_['decision'] }) -join ' ' } else { 'none' }),
    $(if ($open.Count) { $open -join ' ' } else { 'none' }), $(if ($notChecked.Count) { ' | not checked ' + (($notChecked | ForEach-Object { $_['rule'] }) -join ' ') } else { '' }))
