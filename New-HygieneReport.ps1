#requires -Version 7.4
<#
.SYNOPSIS
    Writes two self-contained HTML pages: one for the manager (stand-ins only) and one for the administrator (names
    and the work list).

.DESCRIPTION
    manager.html  the as-of date; what the data is; where the brief's text came from; the brief (the checked text if
                  it passed, otherwise the fixed template, and which it is); the findings by rule with counts and
                  invented cost units, or "not checked" and what was missing; each decision with its question as the
                  findings summary holds it (never the brief's wording), its answer, who answered and when, how many
                  answers it has and the earlier ones, or "open". It holds stand-ins only and may leave this computer.
                  Before it is written, it is searched for every sign-in address and full display name in the users
                  table, and for every part of a person's name or address local part with three letters or more (as
                  whole words, any letter case; number words and accounts named after a department are left out); one
                  found anywhere except in a name a person typed for a decision stops the run (exit 2), names the
                  users table row it comes from, and nothing is written. The name typed for a decision is shown as
                  typed.
    admin.html    the same, with the names behind each finding, the reasons given for a No, and the work list. It says
                  at its top that it stays on this computer.

    Every text from a table, a model or a person is HTML-escaped; the pages hold no script, load no external file,
    and declare a content security policy that allows inline styles only. An answer's colour comes from a fixed list
    (Yes, No, open), never from the file.

    The folders must be about one summary: the findings folder's summary, the brief folder's copy of it, the work
    list and the decisions file it was made from are checked by sha256, and so is brief.md against its brief report;
    decisions.json is checked before it is used (its shape, each answer's fields and values, and their order). A
    mismatch stops the run (exit 2), and nothing is written.

.EXAMPLE
    pwsh -File New-HygieneReport.ps1 -FindingsDir out-demo/findings -BriefDir out-demo/brief -WorklistDir out-demo/worklist -UsersCsv data/users.synthetic.csv -DataKind Synthetic -OutDir out-pages
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $FindingsDir,
    [Parameter(Mandatory)] [string] $BriefDir,
    [Parameter(Mandatory)] [string] $WorklistDir,
    [Parameter(Mandatory)] [string] $UsersCsv,
    [Parameter(Mandatory)] [ValidateSet('Synthetic', 'TenantExport')] [string] $DataKind,
    [Parameter(Mandatory)] [string] $OutDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" }
$paths = [ordered]@{
    summary = Join-Path $FindingsDir 'findings-summary.json'; admin = Join-Path $FindingsDir 'findings-admin.csv'
    briefSummary = Join-Path $BriefDir 'findings-summary.json'; brief = Join-Path $BriefDir 'brief.md'
    report = Join-Path $BriefDir 'brief-report.json'; worklist = Join-Path $WorklistDir 'worklist.json'
}
foreach ($p in $paths.Values) { if (-not (Test-Path -LiteralPath $p)) { Stop-Refused "missing: $p" } }
$summarySha = Get-FileSha256 $paths.summary
if ((Get-FileSha256 $paths.briefSummary) -ne $summarySha) { Stop-Refused 'the brief folder holds another summary than the findings folder' }
$report = Read-JsonExact $paths.report
if ($report['summary_sha256'] -ne $summarySha) { Stop-Refused 'the brief report was written for another summary' }
$briefText = [IO.File]::ReadAllText((Resolve-FullPath $paths.brief), [Text.Encoding]::UTF8)
if ((Get-TextSha256 $briefText) -ne $report['brief_sha256']) { Stop-Refused 'brief.md was changed after it was checked' }
$worklist = Read-JsonExact $paths.worklist
if ($worklist['summary_sha256'] -ne $summarySha) { Stop-Refused 'the work list was made for another summary' }
$decisionsPath = Join-Path $BriefDir 'decisions.json'
$decisionsSha = if (Test-Path -LiteralPath $decisionsPath) { Get-FileSha256 $decisionsPath } else { '' }
if ($worklist['decisions_sha256'] -ne $decisionsSha) { Stop-Refused 'the work list is older than decisions.json; run New-AdminWorklist.ps1 again' }

$summary = Read-JsonExact $paths.summary
$adminRows = @(Import-Csv -LiteralPath $paths.admin -Encoding utf8)
$decisionIds = @(@($summary['decisions']) | Where-Object { $_ } | ForEach-Object { $_['id'] })
$history = [ordered]@{}
$allAnswers = @()
if ($decisionsSha) {
    $allAnswers = Read-DecisionsFile $decisionsPath $summarySha $decisionIds
    $history = Get-AnswerHistory $allAnswers
}

function Esc([object] $Text) { ConvertTo-HtmlText ([string]$Text) }

# The brief as HTML: every line is escaped first; only bold, italics, list items and paragraphs are then marked up.
function ConvertTo-BriefHtml([string] $Text) {
    $out = [System.Collections.Generic.List[string]]::new()
    $list = ''
    foreach ($raw in ($Text -replace "`r`n", "`n").Split("`n")) {
        $line = $raw.TrimEnd()
        $kind = if ($line -match '^\s*[-*] ') { 'ul' } elseif ($line -match '^\s*[0-9]+[.)] ') { 'ol' } else { '' }
        if ($list -and $kind -ne $list) { $out.Add("</$list>"); $list = '' }
        if (-not $line) { continue }
        $body = if ($kind) { $line -replace '^\s*([-*]|[0-9]+[.)]) ', '' } else { $line }
        $h = Esc $body
        $h = $h -replace '\*\*(.+?)\*\*', '<strong>$1</strong>' -replace '(?<![*\w])\*(?![*\s])(.+?)(?<![*\s])\*(?![*\w])', '<em>$1</em>'
        if ($kind) {
            if (-not $list) { $out.Add("<$kind>"); $list = $kind }
            $out.Add("<li>$h</li>")
        } else {
            $out.Add("<p>$h</p>")
        }
    }
    if ($list) { $out.Add("</$list>") }
    $out -join "`n"
}

$asOf = $summary['as_of']
$dataLabel = if ($DataKind -eq 'Synthetic') { 'Synthetic data: invented accounts at demo.example.com' } else { 'Data exported from a tenant' }
$originLabel = [string]$report['origin_label']
$obtained = [string]$report['obtained']
$howObtained = if ($obtained) { ' How it was obtained: ' + $obtained } else { '' }
$briefSource = if ($report['ai_text_accepted']) { 'The checked text. Origin: ' + $originLabel + '.' + $howObtained } else {
    'The fixed template, filled with the script''s own figures, because the text did not pass the checks (' + (@($report['problems']) -join '; ') + '). The text it replaced: ' + $originLabel }

$ruleRows = foreach ($r in @($summary['rules'])) {
    $who = switch ($r['scope']) { 'tenant' { 'the tenant (no person)' } 'policy' { 'policies (no person)' } default { 'accounts' } }
    $missing = if ($r.Contains('not_checked')) { $r['not_checked'] } else { $null }
    $countCell = if ($missing) { 'not checked: ' + $missing } else { [string]$r['count'] }
    $costCell = if ($missing) { '-' } else { [string]$r['monthly_cost_synthetic'] }
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class="n">{4}</td><td class="n">{5}</td></tr>' -f (Esc $r['id']), (Esc $r['title']),
        (Esc $r['kind']), (Esc $who), (Esc $countCell), (Esc $costCell)
}
$total = '<tr class="t"><td colspan="5">Reclaimable each month (licence cost rules R1, R2, R5)</td><td class="n">{0}</td></tr>' -f (Esc $summary['reclaimable_monthly_cost_synthetic'])

# An answer's class comes from this fixed list, never from the file.
$answerClass = @{ Yes = 'yes'; No = 'no' }
function Get-DecisionRows([bool] $WithReason) {
    foreach ($d in @($summary['decisions'])) {
        if (-not $d) { continue }
        $list = @(if ($history.Contains($d['id'])) { $history[$d['id']] })
        $a = if ($list.Count) { $list[$list.Count - 1] } else { $null }
        $answer = if ($a) { $a['answer'] } else { 'open' }
        $class = if ($a -and $answerClass.ContainsKey($a['answer'])) { $answerClass[$a['answer']] } else { 'open' }
        $by = if ($a) { $a['by'] } else { '' }
        $at = if ($a) { $a['at'] } else { '' }
        $count = $list.Count
        $earlier = if ($list.Count -gt 1) { Format-EarlierAnswers $list -WithReason:$WithReason } elseif ($list.Count -eq 1) { 'none' } else { '' }
        $row = '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class="a {3}">{4}</td><td>{5}</td><td>{6}</td><td class="n">{7}</td><td>{8}</td>' -f (Esc $d['id']),
            (Esc $d['question']), (Esc (@($d['rules']) -join ', ')), $class, (Esc $answer), (Esc $by), (Esc $at), (Esc $count), (Esc $earlier)
        if ($WithReason) { $row += '<td>{0}</td>' -f (Esc $(if ($a) { $a['reason'] } else { '' })) }
        $row + '</tr>'
    }
}
$noDecisions = '<p>No decision is asked: no rule found anything.</p>'

$style = @'
:root { color-scheme: light; }
body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; margin: 0; background: #ffffff; color: #1b1f24; line-height: 1.5; }
main { max-width: 960px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 1.6rem; margin: 0 0 4px; } h2 { font-size: 1.2rem; margin: 32px 0 8px; border-bottom: 1px solid #d0d7de; padding-bottom: 4px; }
.labels span { display: inline-block; border: 1px solid #d0d7de; border-radius: 12px; padding: 2px 10px; margin: 4px 6px 0 0; font-size: 0.85rem; background: #f6f8fa; }
.warn { background: #fff4e5; border: 1px solid #f0b37e; padding: 12px 16px; border-radius: 6px; font-weight: 600; }
.brief { border-left: 4px solid #0969da; padding: 4px 16px; background: #f6f8fa; }
.source { font-size: 0.9rem; color: #57606a; }
table { border-collapse: collapse; width: 100%; font-size: 0.92rem; display: block; overflow-x: auto; }
th, td { border: 1px solid #d0d7de; padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; } td.n { text-align: right; white-space: nowrap; } tr.t td { font-weight: 600; }
td.a.yes { color: #1a7f37; font-weight: 600; } td.a.no { color: #cf222e; font-weight: 600; } td.a.open { color: #9a6700; }
footer { margin-top: 40px; font-size: 0.8rem; color: #57606a; }
'@

# Nested arrays of lines, flattened to one list of lines.
function Expand-Lines($Items) { foreach ($i in @($Items)) { if ($i -is [System.Collections.IEnumerable] -and $i -isnot [string]) { Expand-Lines $i } elseif ($null -ne $i) { [string]$i } } }

function New-Page([string] $Title, [string] $Warning, [object[]] $Sections) {
    $labels = '<p class="labels"><span>As of {0}</span><span>{1}</span><span>Brief: {2}</span><span>Costs: invented units, not money</span></p>' -f (Esc $asOf),
        (Esc $dataLabel), (Esc $originLabel)
    @(
        '<!DOCTYPE html>'
        '<html lang="en">'
        '<head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">'
        "<title>$(Esc $Title)</title>"
        "<style>$style</style>"
        '</head>'
        '<body><main>'
        $(if ($Warning) { '<p class="warn">' + (Esc $Warning) + '</p>' })
        "<h1>$(Esc $Title)</h1>"
        $labels
        (Expand-Lines $Sections)
        ('<footer>Written by New-HygieneReport.ps1 from the findings summary with sha256 {0}. No saving in money is shown or promised.</footer>' -f (Esc $summarySha))
        '</main></body>'
        '</html>'
    ) | ForEach-Object { Expand-Lines $_ }
}

# Each part of a page is a section with an id, so that one part can be captured or linked on its own.
function New-Section([string] $Id, [object[]] $Lines) { @("<section id=`"$Id`">") + @(Expand-Lines $Lines) + @('</section>') }
$briefSection = New-Section 'brief' @('<h2>The brief</h2>', ('<p class="source">{0}</p>' -f (Esc $briefSource)), '<div class="brief">', (ConvertTo-BriefHtml $briefText), '</div>')
$findingsSection = New-Section 'findings' (@('<h2>Findings by rule</h2>', '<table><thead><tr><th>Rule</th><th>What it finds</th><th>Kind</th><th>About</th><th>Count</th><th>Invented units a month</th></tr></thead><tbody>') +
    @($ruleRows) + @($total, '</tbody></table>', ('<p class="source">{0}</p>' -f (Esc $summary['cost_note']))))
$decHead = '<table><thead><tr><th>Id</th><th>Question</th><th>Rules</th><th>Answer</th><th>By</th><th>When (UTC)</th><th>Answers</th><th>Earlier answers</th>{0}</tr></thead><tbody>'
$decNote = '<p class="source">Each question is the findings summary''s own, fixed by the script, not the brief''s wording. The last answer counts; the earlier ones are shown. A name is shown as the person typed it; it is not checked against any directory.</p>'
$managerDecisions = New-Section 'decisions' $(if (@($summary['decisions']).Count) { @('<h2>Decisions</h2>', ($decHead -f ''), @(Get-DecisionRows $false), '</tbody></table>',
    $decNote) } else { @('<h2>Decisions</h2>', $noDecisions) })
$manager = New-Page 'Microsoft 365 hygiene brief' '' (@($briefSection) + @($findingsSection) + @($managerDecisions) +
    @(New-Section 'about' @('<h2>About this page</h2>', '<p>People appear only as stand-ins (user-001 ...) and policies as policy-001 ... . The administrator keeps the names on a separate page that stays on their computer.</p>')))

# The manager's page may leave the computer: no address, full name or part of a person's name from the users table
# may be on it, except in a name a person typed for a decision, which is shown as typed.
$users = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
$departments = @($users | ForEach-Object { $_.Department } | Where-Object { $_ })
$scan = ($manager -join "`n")
foreach ($a in @($allAnswers)) { if ($a) { $scan = $scan.Replace((Esc $a['by']), ' ') } }
$scanText = [System.Net.WebUtility]::HtmlDecode(($scan -replace '<[^>]*>', ' '))
$foundRows = [System.Collections.Generic.List[int]]::new()
$row = 0
foreach ($u in $users) {
    $row++
    $src = Get-NameSource $u
    foreach ($v in @($src.Upn, $(if ($src.Name -notin $departments) { $src.Name }))) {
        if ($v -and [regex]::IsMatch($scanText, '(?<!\w)' + [regex]::Escape($v) + '(?!\w)', 'IgnoreCase, CultureInvariant') -and $row -notin $foundRows) { $foundRows.Add($row) }
    }
}
foreach ($r in @(Find-NameParts $scanText (Get-PersonNameParts $users))) { if ($r -notin $foundRows) { $foundRows.Add($r) } }
if ($foundRows.Count -gt 0) {
    Stop-Refused "a name, an address or a part of a name from the users table (row $(($foundRows | Sort-Object) -join ', ')) would be on the manager's page; nothing was written"
}

$nameRows = foreach ($r in $adminRows) {
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class="n">{4}</td><td>{5}</td><td class="n">{6}</td><td>{7}</td></tr>' -f (Esc $r.Rule),
        (Esc $r.Name), (Esc $r.Upn), (Esc $r.Department), (Esc $r.DaysSinceSignIn), (Esc $r.Licenses), (Esc $r.MonthlyCost), (Esc $r.Detail)
}
$workRows = foreach ($i in @($worklist['items'])) {
    if (-not $i) { continue }
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td class="n">{7}</td></tr>' -f (Esc $i['Decision']), (Esc $i['Rule']),
        (Esc $(if ($i['Name']) { '{0} ({1})' -f $i['Name'], $i['Item'] } else { $i['Item'] })), (Esc $i['Detail']), (Esc $i['WhatToReview']), (Esc $i['DecidedBy']),
        (Esc $i['DecidedAt']), (Esc $i['Answers'])
}
$notOnList = @(@($worklist['no']) | Where-Object { $_ } | ForEach-Object { '<li>{0}: answered No by {1} at {2}. Reason: {3} Answers: {4}{5}</li>' -f (Esc $_['decision']),
        (Esc $_['by']), (Esc $_['at']), (Esc $_['reason']), (Esc $_['answers']), (Esc $(if ($_['earlier']) { '; earlier: ' + $_['earlier'] + '.' } else { '.' })) }) +
    @(@($worklist['open']) | Where-Object { $_ } | ForEach-Object { '<li>{0}: still open, no answer recorded.</li>' -f (Esc $_) }) +
    @(@($worklist['not_checked']) | Where-Object { $_ } | ForEach-Object { '<li>{0}: not checked, because {1}.</li>' -f (Esc $_['rule']), (Esc $_['missing']) })
$adminSections = @($briefSection) + @($findingsSection) + @(New-Section 'names' (
    @('<h2>The findings with names</h2>', '<table><thead><tr><th>Rule</th><th>Name</th><th>Sign-in address</th><th>Department</th><th>Days since sign-in</th><th>Licences</th><th>Invented units</th><th>Detail</th></tr></thead><tbody>') +
    @($nameRows) + @('</tbody></table>'))) +
    @(New-Section 'decisions' $(if (@($summary['decisions']).Count) { @('<h2>Decisions</h2>', ($decHead -f '<th>Reason</th>'), @(Get-DecisionRows $true), '</tbody></table>', $decNote) } else { @('<h2>Decisions</h2>', $noDecisions) })) +
    @(New-Section 'worklist' (@('<h2>The work list</h2>', '<p>Only the decisions answered Yes (their last answer). It is a list for a person; nothing here has been changed in any tenant. Each decision''s question, as the summary holds it, is in the Decisions table above.</p>',
        '<table><thead><tr><th>Decision</th><th>Rule</th><th>Account or item</th><th>Detail</th><th>What to review</th><th>Decided by</th><th>When (UTC)</th><th>Answers</th></tr></thead><tbody>') +
    @($workRows) + @('</tbody></table>', '<h3>Not on the work list</h3>') +
    $(if ($notOnList.Count) { @('<ul>') + $notOnList + @('</ul>') } else { @('<p>Nothing: every decision was answered Yes.</p>') })))
$admin = New-Page 'Microsoft 365 hygiene brief: administrator' 'For the administrator only. This page holds names and sign-in addresses: keep it on this computer and do not send it.' $adminSections

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-LineFile (Join-Path $OutDir 'manager.html') @($manager)
Write-LineFile (Join-Path $OutDir 'admin.html') @($admin)
Write-Output ('pages manager.html (stand-ins only, may leave this computer) and admin.html (names; stays on this computer) | brief: {0}' -f
    $(if ($report['ai_text_accepted']) { $originLabel } else { 'the fixed template' }))
