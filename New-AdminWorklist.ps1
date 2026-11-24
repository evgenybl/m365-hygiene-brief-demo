#requires -Version 7.4
<#
.SYNOPSIS
    Writes the administrator's work list from the manager's recorded decisions. It is a list for a person; it changes
    nothing.

.DESCRIPTION
    Only the rules of a decision answered Yes (its last answer) contribute: each of their accounts and tenant items, with
    the rule, what to review, the decision's id, and who answered and when. A decision answered No contributes
    nothing, and neither does one never answered; the list names both.

    The names come from the administrator's own file (findings-admin.csv in the findings folder), never from a model.
    The findings folder, the brief folder and decisions.json must all be about one summary: the summary in the brief
    folder must have the same sha256 as the one in the findings folder, and decisions.json must be bound to it.
    Otherwise nothing is written (exit 2).

    It writes three files into a new folder: worklist.csv (for a spreadsheet; a cell that starts like a formula gets a
    leading apostrophe), worklist.md (to read), and worklist.json (what the report pages read, with the sha256 of the
    summary and of the decisions file it was made from).

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
$decisionsPath = Join-Path $BriefDir 'decisions.json'
$decisionsSha = ''
$last = [ordered]@{}
if (Test-Path -LiteralPath $decisionsPath) {
    $doc = Read-JsonExact $decisionsPath
    if ((Get-Field $doc 'summary_sha256') -ne $summarySha) { Stop-Refused 'decisions.json was written for another summary' }
    $decisionsSha = Get-FileSha256 $decisionsPath
    foreach ($a in @(Get-Field $doc 'answers')) { if ($a) { $last[$a['decision']] = $a } }
}

$review = @{
    R1 = 'Is the account still in use? If not, return its licence.'
    R2 = 'The account is disabled: return its licence.'
    R3 = 'Register a second sign-in step (MFA) for this administrator, or remove the role.'
    R4 = 'Does the guest still need access? If not, remove the guest.'
    R5 = 'The account never signed in: is it needed? If not, return its licence.'
    R6 = 'Does this account need the Global Administrator role? Bring the holders down to the limit.'
    R7 = 'Enforce a Conditional Access policy that blocks legacy authentication (start it in report-only mode, then switch it on).'
    R8 = 'Switch the policy on, or remove it.'
}
$rows = @(Import-Csv -LiteralPath $adminCsv -Encoding utf8)
$items = [System.Collections.Generic.List[object]]::new()
$yes = @(); $no = @(); $open = @()
foreach ($d in $decisions) {
    $a = if ($last.Contains($d['id'])) { $last[$d['id']] } else { $null }
    if ($null -eq $a) { $open += $d['id']; continue }
    if ($a['answer'] -ne 'Yes') { $no += [ordered]@{ decision = $d['id']; by = $a['by']; at = $a['at']; reason = $a['reason'] }; continue }
    $yes += $d['id']
    foreach ($rule in @($d['rules'])) {
        foreach ($r in @($rows | Where-Object { $_.Rule -eq $rule })) {
            $item = if ($r.Upn) { $r.Upn } elseif ($r.Scope -eq 'tenant') { '(the tenant)' } else { '(a policy)' }
            $items.Add([ordered]@{ Decision = $d['id']; Rule = $rule; Scope = $r.Scope; Item = $item; Name = $r.Name; Detail = $r.Detail
                WhatToReview = $review[$rule]; DecidedBy = $a['by']; DecidedAt = $a['at'] })
        }
    }
}

$csv = ConvertTo-CsvText $items.ToArray() @('Decision', 'Rule', 'Scope', 'Item', 'Name', 'Detail', 'WhatToReview', 'DecidedBy', 'DecidedAt')
$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Work list for the administrator')
$md.Add('')
$md.Add(('As of {0}. Made from the decisions recorded for the summary with sha256 {1}.' -f $summary['as_of'], $summarySha))
$md.Add('This is a list for a person to work through. Nothing here has been changed in any tenant, and this list changes nothing.')
$md.Add('')
foreach ($id in $yes) {
    $d = @($decisions | Where-Object { $_['id'] -eq $id })[0]
    $a = $last[$id]
    $md.Add(('## {0}: Yes, by {1} at {2}' -f $id, $a['by'], $a['at']))
    $md.Add('')
    $md.Add($d['question'])
    $md.Add('')
    foreach ($i in @($items | Where-Object { $_['Decision'] -eq $id })) {
        $who = if ($i['Name']) { '{0} ({1})' -f $i['Name'], $i['Item'] } else { $i['Item'] }
        $detail = if ($i['Detail']) { ' ' + $i['Detail'] + '.' } else { '' }
        $md.Add(('- [ ] {0} {1}.{2} {3}' -f $i['Rule'], $who, $detail, $i['WhatToReview']))
    }
    $md.Add('')
}
$md.Add('## Not on this list')
$md.Add('')
foreach ($n in $no) { $md.Add(('- {0}: answered No by {1} at {2}. Reason: {3}' -f $n['decision'], $n['by'], $n['at'], $n['reason'])) }
foreach ($id in $open) { $md.Add(('- {0}: still open, no answer recorded.' -f $id)) }
if (-not ($no.Count + $open.Count)) { $md.Add('- Nothing: every decision was answered Yes.') }

$json = [ordered]@{
    summary_sha256 = $summarySha; decisions_sha256 = $decisionsSha
    yes = @($yes); no = @($no); open = @($open); items = $items.ToArray()
}

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'worklist.csv') $csv
Write-LineFile (Join-Path $OutDir 'worklist.md') $md.ToArray()
Write-TextFile (Join-Path $OutDir 'worklist.json') ((ConvertTo-JsonText $json) + "`n")
Write-Output ('work list items {0} | from {1} | answered No {2} | open {3}' -f $items.Count,
    $(if ($yes.Count) { $yes -join ' ' } else { 'none' }), $(if ($no.Count) { ($no | ForEach-Object { $_['decision'] }) -join ' ' } else { 'none' }),
    $(if ($open.Count) { $open -join ' ' } else { 'none' }))
