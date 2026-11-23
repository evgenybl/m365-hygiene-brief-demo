#requires -Version 7.1
<#
.SYNOPSIS
    Tests of the demo. Writes only into -OutDir, a folder that must not exist yet: the edge-case tables and answer
    texts are built there, and the shipped files are never changed. The API path is tested against a mock server
    on this computer; nothing leaves it.
.EXAMPLE
    pwsh -NoProfile -File Test-Demo.ps1 -OutDir <a new folder>
#>
param([Parameter(Mandatory)] [string] $OutDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutDir) { throw "OutDir must not exist: $OutDir" }
New-Item -ItemType Directory -Path $OutDir | Out-Null

$here = $PSScriptRoot
$users = Join-Path $here 'users.synthetic.csv'
$skus = Join-Path $here 'skus.synthetic.csv'
$step1 = Join-Path $here 'Get-TenantHygieneFindings.ps1'
$step2 = Join-Path $here 'New-ManagerBrief.ps1'
$script:pass = 0; $script:fail = 0
$script:printed = New-Object System.Collections.Generic.List[string]
function Check([string] $Name, [bool] $Ok) {
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" } else { $script:fail++; Write-Output "FAIL $Name" }
}
function Run-Pwsh([string[]] $ArgList) {
    $out = & pwsh -NoProfile -File @ArgList 2>&1
    $text = $out | Out-String
    $script:printed.Add($text)
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}
function Read-Json([string] $Path) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
function Get-Counts($Summary) { $c = @{}; foreach ($x in $Summary.rules) { $c[$x.id] = $x.count }; $c }

# A users table for one test, written into OutDir.
function New-Table([string] $Name, [string[]] $Rows) {
    $p = Join-Path $OutDir $Name
    $head = 'UserPrincipalName,DisplayName,Department,UserType,AccountEnabled,IsAdmin,MfaRegistered,CreatedDate,LastSignInDate,AssignedLicenses'
    Set-Content -LiteralPath $p -Encoding utf8 -Value (@($head) + $Rows)
    $p
}
function Invoke-Step1([string] $Name, [string] $Table, [string] $Skus = $skus) {
    $o = Join-Path $OutDir $Name
    $r = Run-Pwsh @($step1, '-UsersCsv', $Table, '-SkusCsv', $Skus, '-AsOf', '2026-11-21', '-OutDir', $o)
    $sum = if (Test-Path -LiteralPath (Join-Path $o 'findings-summary.json')) { Read-Json (Join-Path $o 'findings-summary.json') } else { $null }
    $rows = if (Test-Path -LiteralPath (Join-Path $o 'findings-admin.csv')) { @(Import-Csv -LiteralPath (Join-Path $o 'findings-admin.csv') -Encoding utf8) } else { @() }
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Dir = $o; Summary = $sum; Rows = $rows }
}
function Get-Flagged($Run, [string] $Rule) { @($Run.Rows | Where-Object Rule -eq $Rule | ForEach-Object { ($_.Upn -split '@')[0] }) }
# Step 2 on a model answer written into OutDir (the Recorded backend).
function Invoke-Step2([string] $Name, [string] $Answer, [string] $Summary = $sj, [string] $Table = $users) {
    $a = Join-Path $OutDir "$Name.md"
    Set-Content -LiteralPath $a -Encoding utf8 -NoNewline -Value $Answer
    $o = Join-Path $OutDir $Name
    $r = Run-Pwsh @($step2, '-SummaryJson', $Summary, '-UsersCsv', $Table, '-OutDir', $o, '-Recorded', $a)
    $rep = if (Test-Path -LiteralPath (Join-Path $o 'brief-report.json')) { Read-Json (Join-Path $o 'brief-report.json') } else { $null }
    $brief = if (Test-Path -LiteralPath (Join-Path $o 'brief.md')) { Get-Content -LiteralPath (Join-Path $o 'brief.md') -Raw -Encoding utf8 } else { '' }
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Dir = $o; Report = $rep; Brief = $brief
        Problems = $(if ($rep) { @($rep.problems) -join ' | ' } else { '' }) }
}
# True when step 2 ran, refused the text for the given problem, and used the template.
function Test-Rejected($Run, [string] $Problem) {
    $Run.Code -eq 0 -and $null -ne $Run.Report -and $Run.Report.ai_text_accepted -eq $false -and
        $Run.Problems.Contains($Problem) -and $Run.Brief.Contains('Your decisions:')
}

# --- step 1 on the shipped data ------------------------------------------------------------------------------------
$f = Join-Path $OutDir 'findings'
$r = Run-Pwsh @($step1, '-UsersCsv', $users, '-SkusCsv', $skus, '-AsOf', '2026-11-21', '-OutDir', $f)
Check 'findings run exits 0' ($r.Code -eq 0)
$sum = Read-Json (Join-Path $f 'findings-summary.json')
$count = Get-Counts $sum
Check 'R1 stale licensed = 2' ($count['R1'] -eq 2)
Check 'R2 disabled licensed = 1' ($count['R2'] -eq 1)
Check 'R3 admins without MFA = 2' ($count['R3'] -eq 2)
Check 'R4 stale or never-used guests = 2' ($count['R4'] -eq 2)
Check 'R5 never signed in, older than 30 days = 1' ($count['R5'] -eq 1)
Check 'reclaimable synthetic cost = 390 (R1 230 + R2 100 + R5 60)' ($sum.reclaimable_monthly_cost_synthetic -eq 390)
$costRules = 0.0; foreach ($x in $sum.rules) { if ($x.id -in 'R1', 'R2', 'R5') { $costRules += $x.monthly_cost_synthetic } }
Check 'the three cost rules (R1, R2, R5) add up to the reclaimable total' ($costRules -eq $sum.reclaimable_monthly_cost_synthetic)
$admin = Import-Csv -LiteralPath (Join-Path $f 'findings-admin.csv') -Encoding utf8
Check 'shipped boundary: exactly 90 days since sign-in is not stale' (-not ($admin.Upn -contains 'lior.samekh@demo.example.com'))
Check 'an account 6 days old with no sign-in is not flagged' (-not ($admin.Upn -contains 'tal.kaf@demo.example.com'))
$sumText = Get-Content -LiteralPath (Join-Path $f 'findings-summary.json') -Raw -Encoding utf8
$names = foreach ($u in Import-Csv -LiteralPath $users -Encoding utf8) { $u.UserPrincipalName; ($u.DisplayName -replace '\(.*\)', '').Trim() }
Check 'the summary for the AI carries no name or address' (@($names | Where-Object { $sumText.Contains($_) }).Count -eq 0 -and -not $sumText.Contains('@'))
$key = Get-Content -LiteralPath (Join-Path $f 'key.local.json') -Raw | ConvertFrom-Json
Check 'the local key maps 8 stand-ins' (@($key.PSObject.Properties).Count -eq 8)
$r2 = Run-Pwsh @($step1, '-UsersCsv', $users, '-SkusCsv', $skus, '-AsOf', '2026-11-21', '-OutDir', $f)
Check 'an existing folder is never overwritten' ($r2.Code -ne 0)

# --- step 1 on edge-case tables, as of 2026-11-21 --------------------------------------------------------------------
$edge = Invoke-Step1 'edge' (New-Table 'edge.csv' @(
    's90@demo.example.com,Edge A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-23,M365_BUSINESS_STANDARD'
    's91@demo.example.com,Edge B (synthetic),Sales,Member,TRUE,false,TRUE,2024-01-10,2026-08-22,M365_BUSINESS_STANDARD'
    'n30@demo.example.com,Edge C (synthetic),Sales,Member,true,False,False,2026-10-22,,M365_BUSINESS_STANDARD'
    'n31@demo.example.com,Edge D (synthetic),Sales,Member,True,FALSE,False,2026-10-21,,M365_BUSINESS_STANDARD'
    'g1@demo.example.com,Guest E (synthetic guest),,Guest,True,False,False,2026-11-20,,'
    'g30@demo.example.com,Guest F (synthetic guest),,Guest,True,False,False,2026-10-22,,'
    'g31@demo.example.com,Guest G (synthetic guest),,Guest,True,False,False,2026-10-21,,'
    'z1@demo.example.com,Edge H (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-22T23:59:59Z,M365_BUSINESS_STANDARD'
    'z2@demo.example.com,Edge I (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-23T00:00:01Z,M365_BUSINESS_STANDARD'
    'o1@demo.example.com,Edge J (synthetic),Sales,Member,True,False,True,2024-01-10,2026-08-23T01:30:00+02:00,M365_BUSINESS_STANDARD'
    'a1@demo.example.com,Edge K (synthetic),IT,Member,tRuE,tRUE,fAlSe,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
$r1 = Get-Flagged $edge 'R1'; $r4 = Get-Flagged $edge 'R4'; $r5 = Get-Flagged $edge 'R5'
Check 'edge table: exits 0, and true and false are read in any letter case' ($edge.Code -eq 0 -and (Get-Flagged $edge 'R3') -contains 'a1')
Check 'boundary: 90 days since sign-in is not stale, 91 days is (R1)' ($r1 -notcontains 's90' -and $r1 -contains 's91')
Check 'boundary: a member created 30 days ago who never signed in is not flagged, 31 days ago is (R5)' ($r5 -notcontains 'n30' -and $r5 -contains 'n31')
Check 'R4: a guest invited yesterday or 30 days ago who never signed in is not flagged, 31 days ago is' ($r4 -notcontains 'g1' -and $r4 -notcontains 'g30' -and $r4 -contains 'g31')
Check 'a timestamp counts by its UTC date: 23:59:59Z is 91 days, 00:00:01Z the next day is 90, 01:30+02:00 is 91' ($r1 -contains 'z1' -and $r1 -notcontains 'z2' -and $r1 -contains 'o1')

$clean = Invoke-Step1 'clean' (New-Table 'clean.csv' @(
    'clean@demo.example.com,Clean A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
$c = if ($clean.Summary) { Get-Counts $clean.Summary } else { @{} }
Check 'a clean one-user tenant: exit 0, all five counts 0, reclaimable 0' ($clean.Code -eq 0 -and $c.Count -eq 5 -and
    @($c.Values | Where-Object { $_ -ne 0 }).Count -eq 0 -and $clean.Summary.reclaimable_monthly_cost_synthetic -eq 0)

$noR2 = Invoke-Step1 'no-r2' (New-Table 'no-r2.csv' @(Get-Content -LiteralPath $users -Encoding utf8 | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^maya\.he@' }))
$c = if ($noR2.Summary) { Get-Counts $noR2.Summary } else { @{} }
Check 'the shipped data without its R2 row: exit 0, R2 0, reclaimable 290' ($noR2.Code -eq 0 -and $c['R2'] -eq 0 -and $c['R1'] -eq 2 -and
    $noR2.Summary.reclaimable_monthly_cost_synthetic -eq 290)

$bad = Invoke-Step1 'day-first' (New-Table 'day-first.csv' @(
    'clean@demo.example.com,Clean A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'
    'dayfirst@demo.example.com,Day First (synthetic),Sales,Member,True,False,True,2024-01-10,21/08/2026,M365_BUSINESS_STANDARD'))
Check 'a day-first date is refused with its row number (exit 2), no name printed, nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'row 2:' -and
    $bad.Text -notmatch '(?i)dayfirst|day first' -and -not (Test-Path -LiteralPath $bad.Dir))
$bad = Invoke-Step1 'blank-enabled' (New-Table 'blank-enabled.csv' @(
    'blank@demo.example.com,Blank A (synthetic),Sales,Member,,False,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
Check 'a blank AccountEnabled is refused with its row number (exit 2), nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'row 1: AccountEnabled' -and
    -not (Test-Path -LiteralPath $bad.Dir))
$bad = Invoke-Step1 'typo-admin' (New-Table 'typo-admin.csv' @(
    'typo@demo.example.com,Typo A (synthetic),IT,Member,True,Ture,True,2024-01-10,2026-11-20,M365_BUSINESS_STANDARD'))
Check 'a mistyped IsAdmin is refused with its row number (exit 2), nothing written' ($bad.Code -eq 2 -and $bad.Text -match 'row 1: IsAdmin' -and
    -not (Test-Path -LiteralPath $bad.Dir))

# The same step under a culture with a decimal comma, on a licence with a fractional cost.
$wrap = Join-Path $OutDir 'run-de-DE.ps1'
Set-Content -LiteralPath $wrap -Encoding utf8 -Value @(
    'param($Script, $UsersCsv, $SkusCsv, $OutDir)'
    '[cultureinfo]::CurrentCulture = [cultureinfo]::new(''de-DE'')'
    '''culture check '' + (1.5).ToString()'
    '& $Script -UsersCsv $UsersCsv -SkusCsv $SkusCsv -AsOf ''2026-11-21'' -OutDir $OutDir'
    'exit $LASTEXITCODE')
$fracSkus = Join-Path $OutDir 'skus-fraction.csv'
Set-Content -LiteralPath $fracSkus -Encoding utf8 -Value @('SkuPartNumber,MonthlyCostSynthetic', 'HALF_PLAN,12.5')
$fracUsers = New-Table 'fraction.csv' @('frac@demo.example.com,Frac A (synthetic),Sales,Member,True,False,True,2024-01-10,2026-01-10,HALF_PLAN')
$de = Join-Path $OutDir 'de-DE'
$r = Run-Pwsh @($wrap, '-Script', $step1, '-UsersCsv', $fracUsers, '-SkusCsv', $fracSkus, '-OutDir', $de)
$deCsv = if (Test-Path -LiteralPath (Join-Path $de 'findings-admin.csv')) { Get-Content -LiteralPath (Join-Path $de 'findings-admin.csv') -Raw } else { '' }
Check 'under de-DE (decimal comma, checked in effect) the files carry 12.5, not 12,5' ($r.Code -eq 0 -and $r.Text.Contains('culture check 1,5') -and
    $deCsv.Contains('"12.5"') -and -not $deCsv.Contains('12,5') -and (Read-Json (Join-Path $de 'findings-summary.json')).reclaimable_monthly_cost_synthetic -eq 12.5)

# --- step 2: the brief ---------------------------------------------------------------------------------------------
$sj = Join-Path $f 'findings-summary.json'
$recordedText = Get-Content -LiteralPath (Join-Path $here 'recorded-brief.md') -Raw -Encoding utf8
$b1 = Join-Path $OutDir 'brief-recorded'
$r = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $b1)
$rep = Read-Json (Join-Path $b1 'brief-report.json')
Check 'the recorded model brief passes the checks' ($r.Code -eq 0 -and $rep.ai_text_accepted -eq $true)
Check 'the brief used is the model text, unchanged' ((Get-Content -LiteralPath (Join-Path $b1 'brief.md') -Raw -Encoding utf8) -ceq ($recordedText.Trim() + "`n"))
$meta = Read-Json (Join-Path $here 'recorded-brief.meta.json')
Check 'the request built today has the sha256 the recorded answers were recorded against' ($rep.request_sha256 -eq $meta.request_sha256)
Check 'the report: no personal value in the request, summary not sent to the API (Recorded)' ($rep.personal_values_in_request -eq 0 -and $rep.summary_sent_to_api -eq $false)

$x = Invoke-Step2 'bad-figure' 'Found 2 administrators without MFA. You can save 500 units a month.'
Check 'an invented figure is caught (500)' (Test-Rejected $x 'figures not in the summary: 500')
Check 'the fallback is used, with the script''s own figures' (-not $x.Brief.Contains('500') -and $x.Brief.Contains('390') -and $x.Brief.Contains('2026-11-21'))
Check 'the fallback leaves no placeholder unfilled' (-not ($x.Brief -match '\{[a-z_0-9A-Z]+\}'))
Check 'a number at the start of a line is caught (500)' (Test-Rejected (Invoke-Step2 'line-start' "The cost each month is`n500. Do you approve?") 'figures not in the summary: 500')
Check '"390 000" is caught (digit groups separated by a space)' (Test-Rejected (Invoke-Step2 'space-group' 'You can save 390 000 units a month.') 'digit groups separated by a space')
Check '"2 000" with a non-breaking space is caught' (Test-Rejected (Invoke-Step2 'nbsp-group' ('There are 2' + [char]0xA0 + '000 accounts.')) 'digit groups separated by a space')
$x = Invoke-Step2 'unknown-refs' 'Remove user-999 and user-500, both found under R9.'
Check 'invented stand-ins and rule ids are caught (user-999, user-500, R9)' ((Test-Rejected $x 'an unknown stand-in') -and $x.Problems.Contains('an unknown rule id'))
Check '"R9 000 a month" is caught (unknown rule id)' (Test-Rejected (Invoke-Step2 'r9' 'You can save R9 000 a month.') 'an unknown rule id')
$arabicIndic500 = [string][char]0x0665 + [char]0x0660 + [char]0x0660   # built from code points: the files stay ASCII
Check 'a digit other than 0 to 9 is caught' (Test-Rejected (Invoke-Step2 'other-digit' "You can save $arabicIndic500 units.") 'a digit other than 0 to 9')

Check 'a name in the model text is caught, and the text is not used' (Test-Rejected (Invoke-Step2 'named' 'The account of Ronit Gimel is not in use.') 'personal value')
$i = 0
foreach ($form in 'ronit gimel', 'Mr Gimel', 'Gimel, Ronit', 'Ronit.Gimel') {
    $i++
    Check "a name written as `"$form`" is caught" (Test-Rejected (Invoke-Step2 "named-$i" "The account of $form is not in use.") 'personal value')
}
$x = Invoke-Step2 'at-sign' 'Questions go to the help desk @ the front office.'
Check 'an at sign (@) in the model text is caught' ((Test-Rejected $x 'an at sign (@) in the text') -and $x.Problems -eq 'an at sign (@) in the text')
Check 'an empty answer gives the template, with the problem "an empty text"' (Test-Rejected (Invoke-Step2 'empty' '') 'an empty text')

$b6 = Join-Path $OutDir 'brief-rejected-real'
$r = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $b6, '-Recorded', (Join-Path $here 'recorded-brief-rejected.md'))
$rep = Read-Json (Join-Path $b6 'brief-report.json')
$text = Get-Content -LiteralPath (Join-Path $b6 'brief.md') -Raw -Encoding utf8
Check 'the real answer that cites its own list numbers ("findings 3 to 5") is refused for the 5, and the template is used' ($rep.ai_text_accepted -eq $false -and
    ($rep.problems -join ' ') -eq 'figures not in the summary: 5' -and $text.Contains('Your decisions:'))

$leaky = Join-Path $OutDir 'summary-with-a-name.json'
$parts = $sumText -split '"department": "Sales"', 2
Set-Content -LiteralPath $leaky -Encoding utf8 -NoNewline -Value ($parts[0] + '"department": "ronit gimel"' + $parts[1])
$b7 = Join-Path $OutDir 'brief-leaky'
$r = Run-Pwsh @($step2, '-SummaryJson', $leaky, '-UsersCsv', $users, '-OutDir', $b7)
Check 'a personal value put into the summary is refused before sending (exit 2), nothing written' ($parts.Count -eq 2 -and $r.Code -eq 2 -and
    $r.Text -match 'would reach the model' -and -not (Test-Path -LiteralPath $b7))

$t = New-Table 'admin-finance.csv' @(
    'admin@demo.example.com,Tenant Admin (synthetic),IT,Member,True,True,False,2024-01-10,2026-11-19,M365_BUSINESS_PREMIUM'
    'finance@demo.example.com,Finance,Finance,Member,True,False,False,2024-01-10,,M365_BUSINESS_STANDARD')
$af = Invoke-Step1 'admin-finance-findings' $t
$x = Invoke-Step2 'admin-finance-brief' $recordedText (Join-Path $af.Dir 'findings-summary.json') $t
Check 'a tenant with an admin@ account and a display name "Finance" (also its department) can run step 2' ($af.Code -eq 0 -and
    (Get-Content -LiteralPath (Join-Path $af.Dir 'findings-summary.json') -Raw).Contains('"Finance"') -and $x.Code -eq 0 -and
    $null -ne $x.Report -and $x.Report.personal_values_in_request -eq 0)

# --- the API path, against a mock Messages API on this computer -----------------------------------------------------
# Serves one answer on a free local port while step 2 runs against it with -Backend Anthropic.
function Invoke-WithMock([string] $Name, [int] $Status, [string] $Body) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $out = Join-Path $OutDir $Name
    $job = Start-Job -ScriptBlock {
        param($Step2, $Sj, $Users, $Out, $Port)
        & pwsh -NoProfile -File $Step2 -SummaryJson $Sj -UsersCsv $Users -OutDir $Out -Backend Anthropic -ApiBase "http://127.0.0.1:$Port" 2>&1
        "EXIT $LASTEXITCODE"
    } -ArgumentList $step2, $sj, $users, $out, $port
    $seen = ''
    $accept = $listener.AcceptTcpClientAsync()
    $got = $accept.Wait(60000)
    if ($got) {
        $client = $accept.Result
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 15000   # a stalled request fails the test instead of hanging it
            $buf = New-Object byte[] 65536; $ms = New-Object System.IO.MemoryStream
            do {
                $n = $stream.Read($buf, 0, $buf.Length); $ms.Write($buf, 0, $n)
                $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                $headEnd = $raw.IndexOf("`r`n`r`n")
                $done = $false
                if ($headEnd -ge 0 -and $raw -match '(?im)^content-length:\s*(\d+)') {
                    $done = ($ms.Length - [Text.Encoding]::UTF8.GetByteCount($raw.Substring(0, $headEnd + 4))) -ge [int]$Matches[1]
                }
            } while (-not $done -and $n -gt 0)
            $seen = $raw
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status Mock`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        } catch {
            $seen = "MOCK ERROR $($_.Exception.Message)"
        } finally {
            $client.Close()
        }
    }
    $listener.Stop()
    $null = Wait-Job -Job $job -Timeout 120
    $jobOut = Receive-Job -Job $job | Out-String
    Remove-Job -Job $job -Force
    $script:printed.Add($jobOut)
    [pscustomobject]@{ Got = $got; Seen = $seen; Out = $jobOut; Dir = $out }
}
function New-Reply([string] $StopReason, $Content) {
    @{ id = 'msg_test'; type = 'message'; role = 'assistant'; model = 'mock'; stop_reason = $StopReason; content = @($Content) } |
        ConvertTo-Json -Depth 5 -Compress
}

$savedKey = $env:ANTHROPIC_API_KEY   # the caller's own key, if any: never used here, restored at the end
try {
    # A placeholder key for the mock. It is built from parts so that no key-shaped literal is in this file.
    $placeholder = 'unit' + '-' + 'test' + '-' + 'placeholder'
    $env:ANTHROPIC_API_KEY = $placeholder

    $m = Invoke-WithMock 'brief-api' 200 (New-Reply 'end_turn' @(@{ type = 'text'; text = $recordedText }))
    Check 'the API call reached the mock' $m.Got
    Check 'the API request goes to /v1/messages with the API version header' ($m.Seen -match '(?m)^POST /v1/messages HTTP/1\.1' -and $m.Seen -match '(?im)^anthropic-version:\s*2023-06-01')
    Check 'the API request carries a key header' ($m.Seen -match '(?im)^x-api-key:\s*\S+')
    Check 'the API request asks for up to 4096 tokens' ($m.Seen.Contains('"max_tokens":4096'))
    Check 'the API request body carries no name or address' (@($names | Where-Object { $m.Seen.Contains($_) }).Count -eq 0)
    $rep = if (Test-Path -LiteralPath (Join-Path $m.Dir 'brief-report.json')) { Read-Json (Join-Path $m.Dir 'brief-report.json') } else { $null }
    Check 'the API path ends with the model text accepted, and the report says the summary was sent to the API' ($m.Out -match 'EXIT 0' -and
        $null -ne $rep -and $rep.ai_text_accepted -eq $true -and $rep.backend -eq 'Anthropic' -and $rep.summary_sent_to_api -eq $true)

    $m = Invoke-WithMock 'brief-api-500' 500 '{"type":"error","error":{"type":"api_error","message":"mock failure"}}'
    Check 'an HTTP error from the API is refused (exit 3), nothing written' ($m.Got -and $m.Out -match 'EXIT 3' -and -not (Test-Path -LiteralPath $m.Dir))
    $m = Invoke-WithMock 'brief-api-cut' 200 (New-Reply 'max_tokens' @(@{ type = 'text'; text = 'A brief cut off in the' }))
    Check 'an API answer that stopped for max_tokens is refused (exit 3), nothing written' ($m.Got -and $m.Out -match 'EXIT 3' -and -not (Test-Path -LiteralPath $m.Dir))
    $m = Invoke-WithMock 'brief-api-notext' 200 (New-Reply 'end_turn' @())
    Check 'an API answer with no text block is refused (exit 3), nothing written' ($m.Got -and $m.Out -match 'EXIT 3' -and -not (Test-Path -LiteralPath $m.Dir))

    $closed = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $closed.Start(); $closedPort = ([System.Net.IPEndPoint]$closed.LocalEndpoint).Port; $closed.Stop()
    $b8 = Join-Path $OutDir 'brief-api-noconnect'
    $r = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $b8, '-Backend', 'Anthropic', '-ApiBase', "http://127.0.0.1:$closedPort")
    Check 'a connection error is refused (exit 3), nothing written' ($r.Code -eq 3 -and -not (Test-Path -LiteralPath $b8))

    $env:ANTHROPIC_API_KEY = $null
    $b5 = Join-Path $OutDir 'brief-nokey'
    $r = Run-Pwsh @($step2, '-SummaryJson', $sj, '-UsersCsv', $users, '-OutDir', $b5, '-Backend', 'Anthropic', '-ApiBase', 'http://127.0.0.1:9')
    Check 'a missing key: a clear refusal (exit 2), nothing written' ($r.Code -eq 2 -and $r.Text -match 'no API key' -and -not (Test-Path -LiteralPath $b5))

    $withKey = @(Get-ChildItem -LiteralPath $OutDir -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8) -like "*$placeholder*" })
    Check 'the API key placeholder appears in no output file and no printed output' ($withKey.Count -eq 0 -and
        @($script:printed | Where-Object { $_.Contains($placeholder) }).Count -eq 0)
} finally {
    $env:ANTHROPIC_API_KEY = $savedKey
}

# --- read-only by construction -------------------------------------------------------------------------------------
$code = (Get-Content -LiteralPath $step1 -Raw) + "`n" + (Get-Content -LiteralPath $step2 -Raw)
Check 'no Connect- cmdlet in either script' ($code -notmatch '(?i)\bConnect-\w')
Check 'no Set, New, Remove, Update, Add, Enable or Disable cmdlet of the Mg, Az, AzureAD, Msol, Mailbox, ADUser or DistributionGroup families' (
    $code -notmatch '(?i)\b(Set|New|Remove|Update|Add|Enable|Disable)-(Mg|Az|Msol|\w*Mailbox|ADUser|\w*DistributionGroup)')
Check 'no Invoke-MgGraphRequest, Invoke-WebRequest or Send-MailMessage, and no web alias or .NET network class' (
    $code -notmatch '(?i)Invoke-MgGraphRequest|Invoke-WebRequest|Send-MailMessage|\b(iwr|irm|curl|wget)\b|WebClient|HttpClient|SmtpClient|Sockets')
Check 'exactly one Invoke-RestMethod in the two scripts together (the API call in step 2)' ([regex]::Matches($code, '(?i)Invoke-RestMethod').Count -eq 1 -and
    (Get-Content -LiteralPath $step2 -Raw) -match 'Invoke-RestMethod -Method Post')

Write-Output ("RESULT {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
