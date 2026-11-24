#requires -Version 7.4
<#
.SYNOPSIS
    Records a manager's answer to one decision of a brief, in decisions.json in the brief's folder.

.DESCRIPTION
    The decisions are the ones the findings summary carries (D1, D2 ...), fixed by Get-TenantHygieneFindings.ps1, not
    by a model, and the question it prints is the summary's own, never the brief's wording. An answer is Yes or No; a
    No needs a reason. The name is recorded as the person types it: it is not checked against any directory, and a name
    that is empty, starts like a spreadsheet formula (=, +, -, @), or holds a control character, a line break or an
    invisible format character (such as a right-to-left override) is refused. So is a reason that holds any of these.

    decisions.json is bound to the sha256 of the summary in the brief's folder: a decisions file written for another
    summary is refused, and so is a brief folder whose summary no longer has the sha256 its brief report holds. The
    file is checked before it is used (its shape, each answer's fields and values, and their order), and a file that
    fails is left as it is. Answers are appended and never rewritten; when an id is answered more than once, the last
    answer in the file counts, and an answer whose time is earlier than the last answer to the same id is refused, so
    the file's order is also the order in time. What it prints says how many answers the id now has, and the earlier
    ones.

    The time of the answer is -At (ISO 8601 with Z or an offset, kept as UTC); without it, the clock of this computer,
    in UTC. It writes decisions.json only. It changes nothing in any tenant.

.EXAMPLE
    pwsh -File Set-BriefDecision.ps1 -BriefDir out-demo/brief -Decision D2 -Answer Yes -By "Dana Manager" -At 2026-11-22T09:00:00Z
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BriefDir,
    [Parameter(Mandatory)] [ValidatePattern('^D[0-9]{1,3}$')] [string] $Decision,
    [Parameter(Mandatory)] [ValidateSet('Yes', 'No')] [string] $Answer,
    [Parameter(Mandatory)] [AllowEmptyString()] [string] $By,
    [string] $Reason = '',
    [string] $At = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

$answerWord = if ($Answer -eq 'Yes') { 'Yes' } else { 'No' }
if (-not (Test-TypedName $By)) {
    Stop-Refused 'the name must not be empty, start with =, +, - or @, hold a control character, a line break or an invisible format character, or be longer than 100 characters'
}
if (-not (Test-PlainText $Reason) -or $Reason.Length -gt 500) {
    Stop-Refused 'the reason must be plain text on one line (no control character, line break or invisible format character), at most 500 characters'
}
if ($answerWord -eq 'No' -and [string]::IsNullOrWhiteSpace($Reason)) { Stop-Refused 'a No needs a reason (-Reason)' }
$stamp = if ($At) { ConvertTo-UtcStamp $At } else { [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture) }
if (-not $stamp) { Stop-Refused 'At must be an ISO 8601 time with Z or an offset, such as 2026-11-22T09:00:00Z' }

$summaryPath = Join-Path $BriefDir 'findings-summary.json'
$reportPath = Join-Path $BriefDir 'brief-report.json'
foreach ($p in @($summaryPath, $reportPath)) { if (-not (Test-Path -LiteralPath $p)) { Stop-Refused "not a brief folder: $(Split-Path $p -Leaf) is missing" } }
$summarySha = Get-FileSha256 $summaryPath
if ((Get-Field (Read-JsonExact $reportPath) 'summary_sha256') -ne $summarySha) {
    Stop-Refused 'the summary in the brief folder is not the one the brief was written from'
}
$summary = Read-JsonExact $summaryPath
$decisions = @(@(Get-Field $summary 'decisions') | Where-Object { $_ })
$ids = @($decisions | ForEach-Object { $_['id'] })
if ($Decision -cnotin $ids) {
    Stop-Refused "$Decision is not a decision of this summary (its decisions: $(if ($ids.Count) { $ids -join ', ' } else { 'none' }))"
}
$question = @($decisions | Where-Object { $_['id'] -ceq $Decision })[0]['question']

$path = Join-Path $BriefDir 'decisions.json'
$answers = [System.Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $path) { foreach ($a in (Read-DecisionsFile $path $summarySha $ids)) { $answers.Add($a) } }
$before = @($answers | Where-Object { $_['decision'] -ceq $Decision })
if ($before.Count -and [string]::CompareOrdinal($stamp, $before[-1]['at']) -lt 0) {
    Stop-Refused "the time $stamp is earlier than the last answer to $Decision ($($before[-1]['at'])); answers are kept in the order they were given"
}
$answers.Add([ordered]@{ decision = $Decision; answer = $answerWord; by = $By.Trim(); at = $stamp; reason = $Reason.Trim() })

$history = Get-AnswerHistory $answers.ToArray()
$open = @($ids | Where-Object { -not $history.Contains($_) })
$doc = [ordered]@{ summary_sha256 = $summarySha; answers = $answers.ToArray() }
Write-TextFile $path ((ConvertTo-JsonText $doc) + "`n")
$earlier = Format-EarlierAnswers $history[$Decision]
Write-Output ('recorded {0} {1} at {2} | the question, from the summary: {3} | answers to {0}: {4}{5} | all answers {6} | open {7}' -f $Decision, $answerWord, $stamp,
    $question, $history[$Decision].Count, $(if ($earlier) { ', earlier: ' + $earlier } else { '' }), $answers.Count, $(if ($open.Count) { $open -join ' ' } else { 'none' }))
