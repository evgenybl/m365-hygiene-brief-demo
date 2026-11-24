#requires -Version 7.4
<#
.SYNOPSIS
    Records a manager's answer to one decision of a brief, in decisions.json in the brief's folder.

.DESCRIPTION
    The decisions are the ones the findings summary carries (D1, D2 ...), fixed by Get-TenantHygieneFindings.ps1, not
    by a model. An answer is Yes or No; a No needs a reason. The name is recorded as the person types it: it is not
    checked against any directory, and a name that is empty, starts like a spreadsheet formula (=, +, -, @) or holds a
    control character is refused.

    decisions.json is bound to the sha256 of the summary in the brief's folder: a decisions file written for another
    summary is refused, and so is a brief folder whose summary no longer has the sha256 its brief report holds.
    Answers are appended and never rewritten; when an id is answered more than once, the last answer counts.

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
    Stop-Refused 'the name must not be empty, start with =, +, - or @, hold a control character, or be longer than 100 characters'
}
if ($Reason -match '[\x00-\x09\x0B-\x1F\x7F]' -or $Reason.Length -gt 500) { Stop-Refused 'the reason must be plain text, at most 500 characters' }
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
$ids = @(@(Get-Field $summary 'decisions') | Where-Object { $_ } | ForEach-Object { $_['id'] })
if ($Decision -cnotin $ids) {
    Stop-Refused "$Decision is not a decision of this summary (its decisions: $(if ($ids.Count) { $ids -join ', ' } else { 'none' }))"
}

$path = Join-Path $BriefDir 'decisions.json'
$answers = [System.Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $path) {
    try { $old = Read-JsonExact $path } catch { Stop-Refused 'decisions.json is not valid JSON; it is left as it is' }
    if ((Get-Field $old 'summary_sha256') -ne $summarySha) { Stop-Refused 'decisions.json was written for another summary; it is left as it is' }
    foreach ($a in @(Get-Field $old 'answers')) {
        if ($null -eq $a) { continue }
        foreach ($k in 'decision', 'answer', 'by', 'at', 'reason') {
            if ($a -isnot [System.Collections.IDictionary] -or -not $a.Contains($k)) { Stop-Refused "decisions.json holds an answer without '$k'; it is left as it is" }
        }
        $answers.Add($a)
    }
}
$answers.Add([ordered]@{ decision = $Decision; answer = $answerWord; by = $By.Trim(); at = $stamp; reason = $Reason.Trim() })

$last = @{}
foreach ($a in $answers) { $last[$a['decision']] = $a['answer'] }
$open = @($ids | Where-Object { -not $last.ContainsKey($_) })
$doc = [ordered]@{ summary_sha256 = $summarySha; answers = $answers.ToArray() }
Write-TextFile $path ((ConvertTo-JsonText $doc) + "`n")
Write-Output ('recorded {0} {1} at {2} | answers {3} | open {4}' -f $Decision, $answerWord, $stamp, $answers.Count,
    $(if ($open.Count) { $open -join ' ' } else { 'none' }))
