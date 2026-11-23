#requires -Version 7.1
<#
.SYNOPSIS
    Step 2: an AI-written brief for a non-technical manager, from the pseudonymised findings summary.

.DESCRIPTION
    Builds the model request from prompt-brief.txt and findings-summary.json. Before anything is sent, it refuses
    (exit 2) if a full sign-in address or a full display name from the user table appears in the request, as a whole
    word in any letter case. A display name that is also a department name in the table (an account named after its
    team) is not looked for there, because the summary carries department names on purpose.

    It gets the text from a backend and checks it. The text is used only if:
      - every number written in digits appears in the summary. A line that starts with a single digit 1 to 9, then
        "." or ")", then a space, starts an ordered list, and that digit is not counted. A date counts as its parts.
      - every stand-in (user-NNN) and every rule id (R1 ...) in it is one of the summary's own;
      - no two digit groups are separated only by a space, and every digit is one of 0 to 9;
      - it holds no "@" and no name or sign-in address from the user table: each full display name, address and
        local part, and each part of a name or local part with three letters or more, looked for as a whole word in
        any letter case. A word that occurs as a whole word in the request itself, or a number word from one to
        ten, is not looked for: a brief is expected to use it.
    It does not catch a number written in words, a right number attached to the wrong finding, or a percentage or
    scale word around a valid number. It catches only names that the user table holds.

    A text that passes becomes brief.md. A text that fails is not used: brief.md is filled from
    fallback-brief.tmpl with the script's own figures, and the report lists what failed.

    Backends: Recorded (a saved model answer) or Anthropic (the Messages API; the key is read from the
    ANTHROPIC_API_KEY environment variable and is never printed or written). With Anthropic, the request (the fixed
    prompt and the stand-in summary) is all that is sent; a failed call, or an answer that did not end normally, is
    refused (exit 3) and nothing is written. Neither backend e-mails or posts the brief anywhere.

.EXAMPLE
    pwsh -File New-ManagerBrief.ps1 -SummaryJson <findings folder>\findings-summary.json -UsersCsv users.synthetic.csv -OutDir <new folder>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SummaryJson,
    [Parameter(Mandatory)] [string] $UsersCsv,
    [Parameter(Mandatory)] [string] $OutDir,
    [ValidateSet('Recorded', 'Anthropic')] [string] $Backend = 'Recorded',
    [string] $Recorded = (Join-Path $PSScriptRoot 'recorded-brief.md'),
    [string] $Prompt = (Join-Path $PSScriptRoot 'prompt-brief.txt'),
    [string] $FallbackTemplate = (Join-Path $PSScriptRoot 'fallback-brief.tmpl'),
    [string] $Model = 'claude-haiku-5-5',
    [string] $ApiBase = 'https://api.anthropic.com'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

function Stop-Refused([string] $Message, [int] $Code) {
    [Console]::Error.WriteLine("REFUSED: $Message")
    exit $Code
}
function Test-Word([string] $Text, [string] $Value) {
    [regex]::IsMatch($Text, '(?<!\w)' + [regex]::Escape($Value) + '(?!\w)', 'IgnoreCase')
}
function Get-Field($Object, [string] $Name) { if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } }

if (Test-Path -LiteralPath $OutDir) { Stop-Refused "refusing to write into an existing folder: $OutDir" 2 }

$summaryText = Get-Content -LiteralPath $SummaryJson -Raw -Encoding utf8
$summary = $summaryText | ConvertFrom-Json
$compact = $summary | ConvertTo-Json -Depth 6 -Compress
$promptText = (Get-Content -LiteralPath $Prompt -Raw -Encoding utf8).Trim() -replace "`r`n", "`n"
$request = $promptText + "`n`nThe summary:`n`n" + $compact

# What is looked for. Before sending: each full sign-in address and display name. In the model's text: also each
# local part and each part of three letters or more, except words that the request itself carries and number words.
$rows = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
$departments = @($rows | ForEach-Object { $_.Department } | Where-Object { $_ })
$numberWords = 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten'
$sendWatch = New-Object System.Collections.Generic.List[string]
$textWatch = New-Object System.Collections.Generic.List[string]
foreach ($u in $rows) {
    $name = ($u.DisplayName -replace '\(.*\)', '').Trim()
    $local = ($u.UserPrincipalName -split '@')[0]
    if ($u.UserPrincipalName) { $sendWatch.Add($u.UserPrincipalName) }
    if ($name -and $name -notin $departments) { $sendWatch.Add($name) }
    $parts = @("$name $local" -split '[^\p{L}]+' | Where-Object { $_.Length -ge 3 })
    foreach ($v in @($u.UserPrincipalName, $name, $local) + $parts) {
        if ($v -and $v -notin $numberWords -and -not (Test-Word $request $v)) { $textWatch.Add($v) }
    }
}
$leaks = @($sendWatch | Where-Object { Test-Word $request $_ })
if ($leaks.Count -gt 0) { Stop-Refused "$($leaks.Count) personal value(s) would reach the model; nothing was sent" 2 }

function Invoke-AnthropicMessage([string] $Text) {
    $key = $env:ANTHROPIC_API_KEY
    if (-not $key) { Stop-Refused 'no API key in ANTHROPIC_API_KEY; use -Backend Recorded, or set the variable' 2 }
    $body = @{ model = $Model; max_tokens = 4096; messages = @(@{ role = 'user'; content = $Text }) } | ConvertTo-Json -Depth 5 -Compress
    $headers = @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri ($ApiBase.TrimEnd('/') + '/v1/messages') -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    } catch {
        Stop-Refused "the API call failed: $($_.Exception.Message); nothing was written" 3
    }
    $stop = Get-Field $resp 'stop_reason'
    if ($stop -ne 'end_turn') { Stop-Refused "the API answer did not end normally (stop_reason: $stop); nothing was written" 3 }
    $texts = @(Get-Field $resp 'content' | Where-Object { (Get-Field $_ 'type') -eq 'text' } | ForEach-Object { Get-Field $_ 'text' })
    if ($texts.Count -eq 0) { Stop-Refused 'the API answer carried no text block; nothing was written' 3 }
    $texts -join ''
}

$answer = if ($Backend -eq 'Recorded') { Get-Content -LiteralPath $Recorded -Raw -Encoding utf8 } else { Invoke-AnthropicMessage $request }

# The numbers written in digits (0 to 9 only), after stand-ins, rule ids, the product name and ordered-list markers.
function Get-Figures([string] $Text) {
    $t = $Text -creplace 'user-[0-9]+', ' ' -creplace '\bR[0-9]+\b', ' ' -creplace 'Microsoft 365|M365', ' ' -replace '(?m)^[1-9][.)] (?=[^0-9])', ' '
    $t = $t -replace '[0-9]{4}-[0-9]{2}-[0-9]{2}', { ($_.Value -split '-') -join ' ' }
    @([regex]::Matches($t, '[0-9][0-9,]*(?:\.[0-9]+)?') | ForEach-Object { [double]($_.Value -replace ',', '') }) | Sort-Object -Unique
}

$allowed = Get-Figures $summaryText
$refs = @($summary.rules | ForEach-Object { $_.items } | ForEach-Object { $_.ref })
$ruleIds = @($summary.rules | ForEach-Object { $_.id })
$problems = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($answer)) {
    $problems.Add('an empty text')
} else {
    $extra = @(Get-Figures $answer | Where-Object { $_ -notin $allowed })
    if ($extra.Count -gt 0) { $problems.Add('figures not in the summary: ' + (($extra | ForEach-Object { $_.ToString($inv) }) -join ', ')) }
    if (@([regex]::Matches($answer, 'user-[0-9]+') | Where-Object { $_.Value -notin $refs }).Count) { $problems.Add('an unknown stand-in') }
    if (@([regex]::Matches($answer, '\bR[0-9]+\b') | Where-Object { $_.Value -notin $ruleIds }).Count) { $problems.Add('an unknown rule id') }
    if ($answer -match '[0-9][ \xA0]+[0-9]') { $problems.Add('digit groups separated by a space') }
    if ($answer -match '[\p{Nd}-[0-9]]') { $problems.Add('a digit other than 0 to 9') }
    $named = @($textWatch | Where-Object { Test-Word $answer $_ })
    if ($named.Count -gt 0) { $problems.Add("$($named.Count) personal value(s) in the text") }
    if ($answer.Contains('@')) { $problems.Add('an at sign (@) in the text') }
}

$accepted = $problems.Count -eq 0
if ($accepted) {
    $brief = $answer.Trim() + "`n"
} else {
    $count = @{}
    foreach ($r in $summary.rules) { $count[$r.id] = $r.count }
    $brief = (Get-Content -LiteralPath $FallbackTemplate -Raw -Encoding utf8)
    $values = @{
        '{as_of}' = $summary.as_of; '{users_checked}' = $summary.users_checked
        '{stale_days}' = $summary.thresholds.stale_days; '{grace_days}' = $summary.thresholds.new_account_grace_days
        '{reclaim}' = $summary.reclaimable_monthly_cost_synthetic
        '{R1}' = $count['R1']; '{R2}' = $count['R2']; '{R3}' = $count['R3']; '{R4}' = $count['R4']; '{R5}' = $count['R5']
    }
    foreach ($k in $values.Keys) { $brief = $brief.Replace($k, [string]$values[$k]) }
}

New-Item -ItemType Directory -Path $OutDir | Out-Null
Set-Content -LiteralPath (Join-Path $OutDir 'brief.md') -Value $brief -Encoding utf8 -NoNewline
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($request))).Replace('-', '').ToLower()
$report = [ordered]@{
    backend = $Backend; model = $(if ($Backend -eq 'Recorded') { 'recorded:' + (Split-Path $Recorded -Leaf) } else { $Model })
    request_sha256 = $sha; personal_values_in_request = $leaks.Count
    ai_text_accepted = $accepted; problems = @($problems); summary_sent_to_api = ($Backend -eq 'Anthropic')
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'brief-report.json') -Encoding utf8
Write-Output ('backend {0} | AI text accepted {1} | problems {2} | summary sent to the API {3}' -f $Backend, $accepted, $problems.Count, $report.summary_sent_to_api)
