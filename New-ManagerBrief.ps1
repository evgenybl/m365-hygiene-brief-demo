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
      - every run of digits in it is a number the summary holds. Digits count wherever they are: at the start of a
        line, inside a word ("Microsoft 3657"), in a date (which counts as its parts). Only three things are not
        counted: a stand-in (user-NNN, policy-NNN), a rule id (R1 ...), and a decision id at the start of its own
        decision line; and the exact product names "Microsoft 365" and "M365";
      - every stand-in and every rule id in it is one of the summary's own (a stand-in in any letter case);
      - every decision of the summary is on a line of its own, exactly once: the line starts with the id (after an
        optional list marker or bold), then a separator, then the summary's question word for word, and nothing else
        but an optional closing "Yes or no?". A decision id anywhere else, an id the summary does not hold, a decision
        left out or named twice, or a question that differs by one word refuses the text. So the brief cannot reword,
        swap or hide a decision; what it says around the decisions is not checked;
      - no two digit groups are separated only by a space, and every numeric character is one of 0 to 9;
      - it holds no "@" and no name or sign-in address from the user table: each full display name, address and
        local part, and each part of a name or local part with three letters or more, looked for as a whole word in
        any letter case. A word that occurs as a whole word in the request itself, or a number word from one to
        ten, is not looked for: a brief is expected to use it.
    It does not catch a number written in words, a right number attached to the wrong finding, or a percentage or
    scale word around a valid number. It catches only names that the user table holds.

    A text that passes becomes brief.md. A text that fails is not used: brief.md is filled from
    fallback-brief.tmpl with the script's own figures and the summary's own decisions, and the report lists what failed.
    A rule the summary marks "not checked" is shown so, with what was missing, never as a count of 0.

    Backends: Recorded (a saved answer) or Anthropic (the Messages API; the key is read from the ANTHROPIC_API_KEY
    environment variable and is never printed or written, with -Debug and -Verbose too). With Anthropic, the request
    (the fixed prompt and the stand-in summary) is all that is sent, to https://api.anthropic.com or to a server on this
    computer (for the tests) and nowhere else; a redirect is not followed; a failed call, a redirect, or an answer that
    did not end normally is refused (exit 3) and nothing is written. Neither backend e-mails or posts the brief anywhere.

    Where a saved answer came from is stated by its meta file (the answer's name with .meta.json), and the label is
    earned: "Recorded" only when the meta file says origin "recorded", both the answer's sha256 and the request's sha256
    match the ones it holds, and its model name, date (yyyy-MM-dd) and account of how the answer was obtained are well
    formed (the label names the model and the date; how the answer was obtained goes into the report); "Constructed,
    not from a model" when it says origin "constructed" and both hashes match; otherwise "Unverified", with the reason.
    The default answer is recordings/brief.constructed.md, written by hand to the request the shipped data gives; the
    answers recorded from a model to earlier requests are in recordings/earlier/.

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
    [Parameter(ParameterSetName = 'Brief')] [string] $Recorded = (Join-Path $PSScriptRoot 'recordings/brief.constructed.md'),
    [Parameter(ParameterSetName = 'Brief')] [string] $RecordedMeta = '',
    [string] $Prompt = (Join-Path $PSScriptRoot 'prompt-brief.txt'),
    [Parameter(ParameterSetName = 'Brief')] [string] $FallbackTemplate = (Join-Path $PSScriptRoot 'fallback-brief.tmpl'),
    [Parameter(ParameterSetName = 'Brief')] [string] $Model = 'claude-haiku-5-5',
    [Parameter(ParameterSetName = 'Brief')] [string] $ApiBase = 'https://api.anthropic.com'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# -Debug and -Verbose would print the request's headers, the key among them: they are switched off for this script,
# and the web call below is made with -Debug:$false -Verbose:$false as well.
$DebugPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

function Test-Word([string] $Text, [string] $Value) {
    [regex]::IsMatch($Text, '(?<!\w)' + [regex]::Escape($Value) + '(?!\w)', 'IgnoreCase, CultureInvariant')
}

$target = if ($PSCmdlet.ParameterSetName -eq 'Request') { $WriteRequest } else { $OutDir }
if (Test-Path -LiteralPath $target) { Stop-Refused "refusing to write over an existing file or folder: $target" 2 }
$apiRoot = $ApiBase.TrimEnd('/')
if ($apiRoot -cne 'https://api.anthropic.com' -and $apiRoot -notmatch '^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$') {
    Stop-Refused 'ApiBase must be https://api.anthropic.com, or http://127.0.0.1:<port> for a local test server' 2
}

$summaryText = Get-Content -LiteralPath $SummaryJson -Raw -Encoding utf8
$summary = $summaryText | ConvertFrom-Json
$request = New-BriefRequestText $SummaryJson $Prompt

# What is looked for. Before sending: each full sign-in address and display name. In the model's text: also each
# local part and each part of three letters or more, except words that the request itself carries and number words.
$rows = @(Import-Csv -LiteralPath $UsersCsv -Encoding utf8)
$departments = @($rows | ForEach-Object { $_.Department } | Where-Object { $_ })
$sendWatch = New-Object System.Collections.Generic.List[string]
$textWatch = New-Object System.Collections.Generic.List[string]
foreach ($u in $rows) {
    $src = Get-NameSource $u
    if ($src.Upn) { $sendWatch.Add($src.Upn) }
    if ($src.Name -and $src.Name -notin $departments) { $sendWatch.Add($src.Name) }
    foreach ($v in @($src.Upn, $src.Name, $src.Local) + @($src.Parts)) {
        if ($v -and $v -notin $script:NumberWords -and -not (Test-Word $request $v)) { $textWatch.Add($v) }
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
        # No redirect is followed: an answer 3xx is an error here, so the key and the summary go nowhere else.
        $resp = Invoke-RestMethod -Method Post -Uri ($apiRoot + '/v1/messages') -Headers $headers -MaximumRedirection 0 `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60 -Debug:$false -Verbose:$false
    } catch {
        Stop-Refused "the API call failed: $($_.Exception.Message.Replace($key, '[key]')); nothing was written" 3
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
$meta = $null
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
        $metaModel = [string](Get-Field $meta 'model'); $metaOn = [string](Get-Field $meta 'recorded_on'); $metaHow = [string](Get-Field $meta 'obtained')
        $metaDay = [datetime]::MinValue
        if ((Get-Field $meta 'request_sha256') -ne $sha) {
            $label = 'Unverified: the answer was given to another request (its meta file holds another request sha256)'
        } elseif ((Get-Field $meta 'answer_sha256') -ne $answerSha) {
            $label = 'Unverified: the answer file does not have the sha256 its meta file holds'
        } elseif ((Get-Field $meta 'origin') -eq 'recorded') {
            if ($metaModel -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$') {
                $label = 'Unverified: the meta file does not hold a plain model name'
            } elseif (-not ($metaOn -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($metaOn, 'yyyy-MM-dd', $inv, 'None', [ref]$metaDay))) {
                $label = 'Unverified: the meta file''s date is not a date written yyyy-MM-dd'
            } elseif ([string]::IsNullOrWhiteSpace($metaHow) -or -not (Test-PlainText $metaHow) -or $metaHow.Length -gt 1000) {
                $label = 'Unverified: the meta file does not say, in plain text on one line, how the answer was obtained'
            } else {
                $origin = 'recorded'
                $label = 'Recorded: {0}, on {1}' -f $metaModel, $metaOn
                $obtained = $metaHow
            }
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

# A decision line: the id at the start of a line (after an optional list marker or bold), a separator, the question.
$decisionLine = '^[ \t]*(?:[-*+][ \t]+)?(?:\*\*)?(?<id>D[0-9]+)(?:\*\*)?(?:[ \t]*[:.)\p{Pd}][ \t]*|[ \t]+)(?<rest>.*?)[ \t]*$'
$closer = '(?i)[ \t]*\(?[ \t]*(?:yes or no|yes/no|yes / no)[ \t]*[?.]?[ \t]*\)?$'

# The numbers written in digits (0 to 9). Removed first, and only these: stand-ins, rule ids, a decision id at the
# start of its decision line (in the summary, every decision id), and the exact product names Microsoft 365 and M365.
function Get-Figures([string] $Text, [switch] $Summary) {
    $lines = foreach ($line in ($Text -split "`r?`n")) {
        if ($Summary) { $line -creplace '\bD[0-9]+\b', ' ' }
        else {
            $m = [regex]::Match($line, $decisionLine)
            if ($m.Success) { $g = $m.Groups['id']; $line.Substring(0, $g.Index) + ' ' + $line.Substring($g.Index + $g.Length) } else { $line }
        }
    }
    $t = ($lines -join "`n") -replace '(?i)\b(user|policy)-[0-9]+\b', ' ' -creplace '\bR[0-9]+\b', ' ' -creplace '\bMicrosoft 365(?![0-9A-Za-z])', ' ' -creplace '\bM365\b', ' '
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

$allowed = Get-Figures $summaryText -Summary
$refs = @($summary.rules | ForEach-Object { $_.items } | ForEach-Object { Get-Field $_ 'ref' }) +
    @($summary.rules | ForEach-Object { $_.items } | ForEach-Object { Get-Field $_ 'report_only_policies_that_would_block_it' } | Where-Object { $_ })
$ruleIds = @($summary.rules | ForEach-Object { $_.id })
$decisions = @(Get-Field $summary 'decisions' | Where-Object { $_ })
$decisionIds = @($decisions | ForEach-Object { $_.id })
$questions = @{}; foreach ($d in $decisions) { $questions[$d.id] = $d.question }
$problems = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($answer)) {
    $problems.Add('an empty text')
} else {
    $extra = @(Get-Figures $answer | Where-Object { $_ -cnotin $allowed })
    if ($extra.Count -gt 0) { $problems.Add('figures not in the summary: ' + ($extra -join ', ')) }
    if (@([regex]::Matches($answer, '(?i)\b(user|policy)-[0-9]+') | Where-Object { $_.Value -cnotin $refs }).Count) { $problems.Add('an unknown stand-in') }
    if (@([regex]::Matches($answer, '\bR[0-9]+\b') | Where-Object { $_.Value -cnotin $ruleIds }).Count) { $problems.Add('an unknown rule id') }
    # The decisions: each id once, on its own line, with the summary's question word for word.
    $said = @([regex]::Matches($answer, '\bD[0-9]+\b') | ForEach-Object { $_.Value })
    $onLine = @{}
    $wrongQuestion = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($answer -split "`r?`n")) {
        $m = [regex]::Match($line, $decisionLine)
        if (-not $m.Success) { continue }
        $id = $m.Groups['id'].Value
        $onLine[$id] = 1 + $(if ($onLine.ContainsKey($id)) { $onLine[$id] } else { 0 })
        $rest = $m.Groups['rest'].Value -replace $closer, ''
        if ($questions.ContainsKey($id) -and $rest -cne $questions[$id] -and $id -cnotin $wrongQuestion) { $wrongQuestion.Add($id) }
    }
    $left = @($decisionIds | Where-Object { $_ -cnotin $said })
    if ($left.Count -gt 0) { $problems.Add('a decision left out: ' + ($left -join ', ')) }
    $twice = @($decisionIds | Where-Object { $d = $_; @($said | Where-Object { $_ -ceq $d }).Count -gt 1 })
    if ($twice.Count -gt 0) { $problems.Add('a decision named more than once: ' + ($twice -join ', ')) }
    if (@($said | Where-Object { $_ -cnotin $decisionIds }).Count) { $problems.Add('an unknown decision id') }
    $outside = @($said | Select-Object -Unique | Where-Object { $d = $_; @($said | Where-Object { $_ -ceq $d }).Count -gt $(if ($onLine.ContainsKey($d)) { $onLine[$d] } else { 0 }) })
    if ($outside.Count -gt 0) { $problems.Add('a decision id outside its own line: ' + ($outside -join ', ')) }
    if ($wrongQuestion.Count -gt 0) { $problems.Add('a decision whose question is not the summary''s: ' + ($wrongQuestion -join ', ')) }
    if ($answer -match '[0-9][ \xA0]+[0-9]') { $problems.Add('digit groups separated by a space') }
    if ($answer -match '[\p{N}-[0-9]]') { $problems.Add('a digit other than 0 to 9') }
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
        $missing = Get-Field $r 'not_checked'
        if ($missing) { '- {0} {1}: not checked ({2})' -f $r.id, $r.title, $missing; continue }
        $note = switch (Get-Field $r 'scope') { 'tenant' { ' (a tenant setting; no person is named)' } 'policy' { ' (policies; no person is named)' } default { '' } }
        '- {0} {1}: {2}{3}' -f $r.id, $r.title, $r.count, $note
    }
    $asks = if ($decisions.Count) { foreach ($d in $decisions) { '{0} {1} Yes or no?' -f $d.id, $d.question } } else { '- None: no rule found anything.' }
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
    backend = $Backend; model = $(if ($origin -eq 'recorded') { $metaModel } elseif ($origin -eq 'live') { $Model } else { $null })
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
