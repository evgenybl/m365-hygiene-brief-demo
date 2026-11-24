#requires -Version 7.4
<#
.SYNOPSIS
    Step 2: a brief for a non-technical manager, written by a model from the pseudonymised findings summary and
    checked before use.

.DESCRIPTION
    Builds the model request from prompt-brief.txt and findings-summary.json. Before anything is sent or written, it
    refuses (exit 2) if a full sign-in address or a full display name from the user table appears in the request, as a
    whole word in any letter case. A display name that is also a department name in the table (an account named after
    its team) is not looked for there, because the summary carries department names on purpose.

    With -WriteRequest <file>, it writes the request text to that file (UTF-8, exactly the bytes that would be sent),
    prints its sha256 and stops: that file is what a person gives a model to record an answer (see
    Add-RecordedBrief.ps1).

    Otherwise it gets the text from a backend and checks it. The text is used only if:
      - every number written in digits appears in the summary. A line that starts with a single digit 1 to 9, then
        "." or ")", then a space, starts an ordered list, and that digit is not counted. A date counts as its parts.
      - every stand-in (user-NNN, policy-NNN) and every rule id (R1 ...) in it is one of the summary's own;
      - every decision id of the summary (D1 ...) appears in it exactly once, and no other decision id does;
      - no two digit groups are separated only by a space, and every digit is one of 0 to 9;
      - it holds no "@" and no name or sign-in address from the user table: each full display name, address and
        local part, and each part of a name or local part with three letters or more, looked for as a whole word in
        any letter case. A word that occurs as a whole word in the request itself, or a number word from one to
        ten, is not looked for: a brief is expected to use it.
    It does not catch a number written in words, a right number attached to the wrong finding, or a percentage or
    scale word around a valid number. It catches only names that the user table holds.

    A text that passes becomes brief.md. A text that fails is not used: brief.md is filled from
    fallback-brief.tmpl with the script's own figures and the summary's own decisions, and the report lists what failed.

    Backends: Recorded (a saved answer) or Anthropic (the Messages API; the key is read from the ANTHROPIC_API_KEY
    environment variable and is never printed or written). With Anthropic, the request (the fixed prompt and the
    stand-in summary) is all that is sent; a failed call, or an answer that did not end normally, is refused (exit 3)
    and nothing is written. Neither backend e-mails or posts the brief anywhere.

    Where a saved answer came from is stated by its meta file (the answer's name with .meta.json), and the label is
    earned: "Recorded" only when the meta file says origin "recorded" and both the answer's sha256 and the request's
    sha256 match the ones it holds (the label names the model and the date; how the answer was obtained goes into the
    report); "Constructed, not from a model" when it says origin "constructed" and both match; otherwise "Unverified",
    with the reason. The default answer is recordings/brief.recorded.md, a recorded answer to the request the shipped
    data gives.

    It writes brief.md, brief-report.json and a byte-for-byte copy of the summary (findings-summary.json) into a new
    folder, so that the decisions recorded later are bound to the exact summary the brief was written from.

.EXAMPLE
    pwsh -File New-ManagerBrief.ps1 -SummaryJson <findings folder>/findings-summary.json -UsersCsv data/users.synthetic.csv -OutDir <new folder>
.EXAMPLE
    pwsh -File New-ManagerBrief.ps1 -SummaryJson examples/findings/findings-summary.json -UsersCsv data/users.synthetic.csv -WriteRequest request.txt
#>
[CmdletBinding(DefaultParameterSetName = 'Brief')]
param(
    [Parameter(Mandatory)] [string] $SummaryJson,
    [Parameter(Mandatory)] [string] $UsersCsv,
    [Parameter(Mandatory, ParameterSetName = 'Brief')] [string] $OutDir,
    [Parameter(Mandatory, ParameterSetName = 'Request')] [string] $WriteRequest,
    [Parameter(ParameterSetName = 'Brief')] [ValidateSet('Recorded', 'Anthropic')] [string] $Backend = 'Recorded',
    [Parameter(ParameterSetName = 'Brief')] [string] $Recorded = (Join-Path $PSScriptRoot 'recordings/brief.recorded.md'),
    [Parameter(ParameterSetName = 'Brief')] [string] $RecordedMeta = '',
    [string] $Prompt = (Join-Path $PSScriptRoot 'prompt-brief.txt'),
    [Parameter(ParameterSetName = 'Brief')] [string] $FallbackTemplate = (Join-Path $PSScriptRoot 'fallback-brief.tmpl'),
    [Parameter(ParameterSetName = 'Brief')] [string] $Model = 'claude-haiku-5-5',
    [Parameter(ParameterSetName = 'Brief')] [string] $ApiBase = 'https://api.anthropic.com'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

function Test-Word([string] $Text, [string] $Value) {
    [regex]::IsMatch($Text, '(?<!\w)' + [regex]::Escape($Value) + '(?!\w)', 'IgnoreCase, CultureInvariant')
}

$target = if ($PSCmdlet.ParameterSetName -eq 'Request') { $WriteRequest } else { $OutDir }
if (Test-Path -LiteralPath $target) { Stop-Refused "refusing to write over an existing file or folder: $target" 2 }

$summaryText = Get-Content -LiteralPath $SummaryJson -Raw -Encoding utf8
$summary = $summaryText | ConvertFrom-Json
$request = New-BriefRequestText $SummaryJson $Prompt

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
$sha = Get-TextSha256 $request

if ($PSCmdlet.ParameterSetName -eq 'Request') {
    Write-TextFile $WriteRequest $request
    Write-Output ('wrote the request | bytes {0} | sha256 {1}' -f [Text.Encoding]::UTF8.GetByteCount($request), $sha)
    exit 0
}

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

# Where the text came from, and the label it has earned.
$answerSha = ''
$obtained = $null
if ($Backend -eq 'Recorded') {
    $answer = Get-Content -LiteralPath $Recorded -Raw -Encoding utf8
    if ($null -eq $answer) { $answer = '' }
    $answerSha = Get-FileSha256 $Recorded
    $metaPath = if ($RecordedMeta) { $RecordedMeta } else { [IO.Path]::ChangeExtension($Recorded, '.meta.json') }
    $origin = 'unverified'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        $label = 'Unverified: no meta file beside the answer'
    } else {
        $meta = Read-JsonExact $metaPath
        if ((Get-Field $meta 'request_sha256') -ne $sha) {
            $label = 'Unverified: the answer was given to another request (its meta file holds another request sha256)'
        } elseif ((Get-Field $meta 'answer_sha256') -ne $answerSha) {
            $label = 'Unverified: the answer file does not have the sha256 its meta file holds'
        } elseif ((Get-Field $meta 'origin') -eq 'recorded') {
            $origin = 'recorded'
            $label = 'Recorded: {0}, on {1}' -f (Get-Field $meta 'model'), (Get-Field $meta 'recorded_on')
            $obtained = Get-Field $meta 'obtained'
        } elseif ((Get-Field $meta 'origin') -eq 'constructed') {
            $origin = 'constructed'
            $label = 'Constructed, not from a model'
        } else {
            $label = 'Unverified: the meta file names no known origin'
        }
    }
} else {
    $answer = Invoke-AnthropicMessage $request
    $origin = 'live'
    $label = "Model API call ($Model)"
}

# The numbers written in digits (0 to 9 only), after stand-ins, rule and decision ids, the product name and
# ordered-list markers.
function Get-Figures([string] $Text) {
    $t = $Text -creplace '(user|policy)-[0-9]+', ' ' -creplace '\b[RD][0-9]+\b', ' ' -creplace 'Microsoft 365|M365', ' ' -replace '(?m)^[1-9][.)] (?=[^0-9])', ' '
    $t = $t -replace '[0-9]{4}-[0-9]{2}-[0-9]{2}', { ($_.Value -split '-') -join ' ' }
    # Each figure as an exact decimal written canonically ("390.00" and "390" are one figure); a figure too long for a
    # decimal stays as written, and so is never one of the summary's own.
    $out = foreach ($m in [regex]::Matches($t, '[0-9][0-9,]*(?:\.[0-9]+)?')) {
        $v = $m.Value -replace ',', ''
        $d = [decimal]0
        if ([decimal]::TryParse($v, [Globalization.NumberStyles]::AllowDecimalPoint, $inv, [ref]$d)) { Format-Units $d } else { $v }
    }
    @($out | Select-Object -Unique)
}

$allowed = Get-Figures $summaryText
$refs = @($summary.rules | ForEach-Object { $_.items } | ForEach-Object { Get-Field $_ 'ref' })
$ruleIds = @($summary.rules | ForEach-Object { $_.id })
$decisions = @(Get-Field $summary 'decisions' | Where-Object { $_ })
$decisionIds = @($decisions | ForEach-Object { $_.id })
$problems = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($answer)) {
    $problems.Add('an empty text')
} else {
    $extra = @(Get-Figures $answer | Where-Object { $_ -cnotin $allowed })
    if ($extra.Count -gt 0) { $problems.Add('figures not in the summary: ' + ($extra -join ', ')) }
    if (@([regex]::Matches($answer, '(user|policy)-[0-9]+') | Where-Object { $_.Value -notin $refs }).Count) { $problems.Add('an unknown stand-in') }
    if (@([regex]::Matches($answer, '\bR[0-9]+\b') | Where-Object { $_.Value -notin $ruleIds }).Count) { $problems.Add('an unknown rule id') }
    $said = @([regex]::Matches($answer, '\bD[0-9]+\b') | ForEach-Object { $_.Value })
    $left = @($decisionIds | Where-Object { $_ -cnotin $said })
    if ($left.Count -gt 0) { $problems.Add('a decision left out: ' + ($left -join ', ')) }
    $twice = @($decisionIds | Where-Object { $d = $_; @($said | Where-Object { $_ -ceq $d }).Count -gt 1 })
    if ($twice.Count -gt 0) { $problems.Add('a decision named more than once: ' + ($twice -join ', ')) }
    if (@($said | Where-Object { $_ -cnotin $decisionIds }).Count) { $problems.Add('an unknown decision id') }
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
    # The template, filled with the summary's own figures and decisions, security findings first.
    $isCost = { param($r) $k = Get-Field $r 'kind'; if ($k) { $k -eq 'cost' } else { $r.id -in 'R1', 'R2', 'R5' } }
    $ordered = @($summary.rules | Where-Object { -not (& $isCost $_) }) + @($summary.rules | Where-Object { & $isCost $_ })
    $findings = foreach ($r in $ordered) {
        $note = switch (Get-Field $r 'scope') { 'tenant' { ' (a tenant setting; no person is named)' } 'policy' { ' (policies; no person is named)' } default { '' } }
        '- {0} {1}: {2}{3}' -f $r.id, $r.title, $r.count, $note
    }
    $asks = if ($decisions.Count) { foreach ($d in $decisions) { '- {0} {1} Yes / No' -f $d.id, $d.question } } else { '- None: no rule found anything.' }
    $brief = (Get-Content -LiteralPath $FallbackTemplate -Raw -Encoding utf8) -replace "`r`n", "`n"
    $values = [ordered]@{
        '{as_of}' = $summary.as_of; '{users_checked}' = $summary.users_checked
        '{reclaim}' = $summary.reclaimable_monthly_cost_synthetic
        '{findings}' = (@($findings) -join "`n"); '{decisions}' = (@($asks) -join "`n")
    }
    foreach ($k in $values.Keys) { $brief = $brief.Replace($k, [string]$values[$k]) }
}

New-Item -ItemType Directory -Path $OutDir | Out-Null
Write-TextFile (Join-Path $OutDir 'brief.md') $brief
[IO.File]::WriteAllBytes((Resolve-FullPath (Join-Path $OutDir 'findings-summary.json')), [IO.File]::ReadAllBytes((Resolve-FullPath $SummaryJson)))
$report = [ordered]@{
    backend = $Backend; model = $(if ($origin -eq 'recorded') { Get-Field $meta 'model' } elseif ($origin -eq 'live') { $Model } else { $null })
    answer_file = $(if ($Backend -eq 'Recorded') { Split-Path $Recorded -Leaf } else { $null })
    origin = $origin; origin_label = $label; obtained = $obtained; answer_sha256 = $answerSha
    request_sha256 = $sha; personal_values_in_request = $leaks.Count
    ai_text_accepted = $accepted; problems = @($problems)
    brief_source = $(if ($accepted) { 'the checked text' } else { 'the fixed template' })
    brief_sha256 = (Get-TextSha256 ($brief -replace "`r`n", "`n")); summary_sha256 = (Get-FileSha256 $SummaryJson)
    decisions = @($decisionIds); summary_sent_to_api = ($Backend -eq 'Anthropic')
}
Write-TextFile (Join-Path $OutDir 'brief-report.json') ((ConvertTo-JsonText $report) + "`n")
Write-Output ('backend {0} | text accepted {1} | problems {2} | summary sent to the API {3} | {4}' -f $Backend, $accepted, $problems.Count,
    $report.summary_sent_to_api, $label)
