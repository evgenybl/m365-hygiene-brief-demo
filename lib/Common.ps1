# Shared helpers, dot-sourced by the scripts of this repository. It defines functions only: it reads nothing, writes
# nothing and connects to nothing when it is loaded.
#
# Every file is written as UTF-8 without a byte order mark and with LF line ends, so the same run gives the same bytes
# on Windows, Linux and macOS. Numbers and dates are parsed and printed with the invariant culture.

$script:Inv = [cultureinfo]::InvariantCulture

function Stop-Refused([string] $Message, [int] $Code = 2) {
    [Console]::Error.WriteLine("REFUSED: $Message")
    exit $Code
}

# A path as the file system sees it, relative to the PowerShell location (the .NET file calls use the process folder).
function Resolve-FullPath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-TextFile([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText((Resolve-FullPath $Path), ($Text -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Write-LineFile([string] $Path, [string[]] $Lines) {
    Write-TextFile $Path ((@($Lines) -join "`n") + "`n")
}

function Get-BytesSha256([byte[]] $Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-TextSha256([string] $Text) { Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($Text)) }
function Get-FileSha256([string] $Path) { Get-BytesSha256 ([IO.File]::ReadAllBytes((Resolve-FullPath $Path))) }

# JSON as text: two-space indentation from ConvertTo-Json, LF line ends.
function ConvertTo-JsonText($Value) {
    (ConvertTo-Json -InputObject $Value -Depth 10) -replace "`r`n", "`n"
}

# JSON read exactly: strings stay strings (ConvertFrom-Json turns an ISO 8601 timestamp into a DateTime), whole
# numbers become [long] and other numbers [decimal], never floating point. Objects become ordered dictionaries.
function ConvertFrom-JsonElement($Element) {
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $h = [ordered]@{}
            foreach ($p in $Element.EnumerateObject()) { $h[$p.Name] = ConvertFrom-JsonElement $p.Value }
            return $h
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($x in $Element.EnumerateArray()) { $list.Add((ConvertFrom-JsonElement $x)) }
            return , $list.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            $l = 0L
            if ($Element.TryGetInt64([ref]$l)) { return $l }
            return $Element.GetDecimal()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}
function Read-JsonExact([string] $Path) {
    $text = [IO.File]::ReadAllText((Resolve-FullPath $Path), [Text.Encoding]::UTF8)
    $doc = [System.Text.Json.JsonDocument]::Parse($text)
    try { ConvertFrom-JsonElement $doc.RootElement } finally { $doc.Dispose() }
}

# Invented cost units: an exact decimal, printed with the invariant culture and never in exponent form.
function Format-Units([decimal] $Value) { $Value.ToString('0.############################', $script:Inv) }

# A field of a dictionary or an object, or $null when it has none (strict mode refuses a missing name otherwise).
function Get-Field($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    $null
}

# A CSV cell that a spreadsheet could read as a formula is written with a leading apostrophe.
function Protect-CsvCell([string] $Value) {
    if ($Value -match '^[=+\-@\t\r]') { "'" + $Value } else { $Value }
}

# CSV as text: every field quoted, quotes doubled, formula-like cells protected, LF line ends.
function ConvertTo-CsvText([object[]] $Rows, [string[]] $Columns) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((@($Columns | ForEach-Object { '"' + $_ + '"' }) -join ','))
    foreach ($r in @($Rows)) {
        $cells = foreach ($c in $Columns) {
            $v = Get-Field $r $c
            $s = if ($null -eq $v) { '' } else { [string]$v }
            '"' + (Protect-CsvCell $s).Replace('"', '""') + '"'
        }
        $lines.Add(($cells -join ','))
    }
    ($lines -join "`n") + "`n"
}

# The column names of a CSV file, from its first line, so that a table with no rows is checked too.
function Get-CsvColumns([string] $Path) {
    $first = @(Get-Content -LiteralPath $Path -TotalCount 1 -Encoding utf8)
    if ($first.Count -eq 0) { return @() }
    @(($first[0] -replace ('^' + [char]0xFEFF), '') -split ',' | ForEach-Object { $_.Trim().Trim('"') })
}
function Assert-CsvColumns([string] $Path, [string[]] $Required, [string] $What) {
    $have = Get-CsvColumns $Path
    $missing = @($Required | Where-Object { $_ -cnotin $have })
    if ($missing.Count -gt 0) { Stop-Refused "the $What has no column $($missing -join ', ')" }
}

function ConvertTo-HtmlText([string] $Text) { [System.Net.WebUtility]::HtmlEncode($Text) }

# Plain text: no control character (a line break or a tab included), no invisible format character (the
# bidirectional controls and the zero-width characters are format characters), and no line or paragraph separator.
function Test-PlainText([string] $Text) { $Text -notmatch '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' }

# A name typed by a person is refused when it is empty, starts like a spreadsheet formula, or is not plain text.
function Test-TypedName([string] $Name) {
    -not [string]::IsNullOrWhiteSpace($Name) -and $Name -notmatch '^\s*[=+\-@]' -and (Test-PlainText $Name) -and
        $Name.Trim().Length -le 100
}

# Text for a Markdown file: the characters that start a link, an emphasis, inline HTML, a table cell, an entity or
# inline code are escaped with a backslash, and a line break becomes a space, so a value read from a table or typed by
# a person is shown as text and never as markup.
function ConvertTo-MarkdownText([object] $Value) {
    $s = ([string]$Value) -replace '[\r\n]+', ' '
    [regex]::Replace($s, '[\\`*_\[\]<>&|~!$]', { param($m) '\' + $m.Value })
}

# The number words one to ten: a brief is expected to use them, so they are never taken for part of a name.
$script:NumberWords = @('one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten')

# What of a user row can name a person: the display name without a note in brackets, the sign-in address, the part of
# the address before the at sign (for a guest, written name_home.domain#EXT#@..., the part before its home domain),
# and every part of the name or of that local part, split at each character that is not a letter, with three letters
# or more and not a number word.
function Get-NameSource($Row) {
    $name = ([string]$Row.DisplayName -replace '\(.*\)', '').Trim()
    $upn = [string]$Row.UserPrincipalName
    $local = ($upn -split '@')[0]
    if ($local -match '(?i)#EXT#$') {
        $local = $local -replace '(?i)#EXT#$', ''
        $i = $local.LastIndexOf('_')
        if ($i -gt 0) { $local = $local.Substring(0, $i) }
    }
    $parts = @("$name $local" -split '[^\p{L}]+' | Where-Object { $_.Length -ge 3 -and $_ -notin $script:NumberWords } | Select-Object -Unique)
    [pscustomobject]@{ Name = $name; Upn = $upn; Local = $local; Parts = $parts }
}

# The name parts of the people in a users table, each with the first row it comes from (the first row after the
# header is row 1). An account whose display name is also a department name of the table (an account named after its
# team) is not a person here.
function Get-PersonNameParts([object[]] $Rows) {
    $departments = @{}
    foreach ($r in $Rows) { if ($r.Department) { $departments[([string]$r.Department).Trim().ToLowerInvariant()] = $true } }
    $parts = @{}
    $row = 0
    foreach ($r in $Rows) {
        $row++
        $src = Get-NameSource $r
        if ($src.Name -and $departments.ContainsKey($src.Name.ToLowerInvariant())) { continue }
        foreach ($p in $src.Parts) { $k = $p.ToLowerInvariant(); if (-not $parts.ContainsKey($k)) { $parts[$k] = $row } }
    }
    $parts
}

# The words of a text that are name parts: each word (split at every character that is not a letter) looked up in
# the table Get-PersonNameParts returns, in any letter case. Returns the rows they come from.
function Find-NameParts([string] $Text, [hashtable] $Parts) {
    @($Text -split '[^\p{L}]+' | Where-Object { $_ -and $Parts.ContainsKey($_.ToLowerInvariant()) } | ForEach-Object { $Parts[$_.ToLowerInvariant()] } | Select-Object -Unique)
}

# decisions.json, read and checked before it is used. Its shape: an object with summary_sha256 and answers, nothing
# else; each answer an object with decision, answer, by, at and reason, nothing else. Each value: a decision of the
# summary; Yes or No; a typed name (Test-TypedName); a UTC time written yyyy-MM-ddTHH:mm:ssZ; a plain-text reason of
# at most 500 characters, required for a No. The order: the answers are in the order they were recorded, and an answer
# whose time is earlier than an earlier answer to the same decision is refused. Anything else stops the run (exit 2)
# and leaves the file as it is. Returns the answers in the file's order.
function Read-DecisionsFile([string] $Path, [string] $SummarySha, [string[]] $DecisionIds) {
    $what = 'decisions.json'
    try { $doc = Read-JsonExact $Path } catch { Stop-Refused "$what is not valid JSON; it is left as it is" }
    if ($doc -isnot [System.Collections.IDictionary]) { Stop-Refused "$what is not a JSON object; it is left as it is" }
    $extra = @($doc.Keys | Where-Object { $_ -cnotin 'summary_sha256', 'answers' })
    if ($extra.Count) { Stop-Refused "$what holds a field it should not ($($extra -join ', ')); it is left as it is" }
    if ($doc['summary_sha256'] -isnot [string] -or $doc['answers'] -isnot [array]) { Stop-Refused "$what lacks summary_sha256 or answers; it is left as it is" }
    if ($doc['summary_sha256'] -ne $SummarySha) { Stop-Refused "$what was written for another summary; it is left as it is" }
    $fields = @('decision', 'answer', 'by', 'at', 'reason')
    $lastAt = @{}
    $out = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($a in $doc['answers']) {
        $n++
        $bad = "$what, answer ${n}:"
        if ($a -isnot [System.Collections.IDictionary]) { Stop-Refused "$bad not an object; it is left as it is" }
        $keys = @($a.Keys)
        $odd = @($keys | Where-Object { $_ -cnotin $fields }) + @($fields | Where-Object { $_ -cnotin $keys })
        if ($odd.Count) { Stop-Refused "$bad its fields must be exactly $($fields -join ', '); it is left as it is" }
        if (@($fields | Where-Object { $a[$_] -isnot [string] }).Count) { Stop-Refused "$bad every field must be text; it is left as it is" }
        if ($a['decision'] -cnotin $DecisionIds) { Stop-Refused "$bad $($a['decision']) is not a decision of this summary; it is left as it is" }
        if ($a['answer'] -cnotin 'Yes', 'No') { Stop-Refused "$bad the answer must be Yes or No; it is left as it is" }
        if (-not (Test-TypedName $a['by'])) { Stop-Refused "$bad the name is not one Set-BriefDecision.ps1 accepts; it is left as it is" }
        if ($a['at'] -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' -or (ConvertTo-UtcStamp $a['at']) -cne $a['at']) {
            Stop-Refused "$bad the time must be written yyyy-MM-ddTHH:mm:ssZ; it is left as it is"
        }
        if (-not (Test-PlainText $a['reason']) -or $a['reason'].Length -gt 500) { Stop-Refused "$bad the reason must be plain text of at most 500 characters; it is left as it is" }
        if ($a['answer'] -eq 'No' -and [string]::IsNullOrWhiteSpace($a['reason'])) { Stop-Refused "$bad a No without a reason; it is left as it is" }
        $id = $a['decision']
        if ($lastAt.ContainsKey($id) -and [string]::CompareOrdinal($a['at'], $lastAt[$id]) -lt 0) {
            Stop-Refused "$bad its time is earlier than an earlier answer to $id; it is left as it is"
        }
        $lastAt[$id] = $a['at']
        $out.Add($a)
    }
    , $out.ToArray()
}

# The answers to each decision, in the file's order: id -> list of answers (the last one counts).
function Get-AnswerHistory([object[]] $Answers) {
    $h = [ordered]@{}
    foreach ($a in @($Answers)) {
        if ($null -eq $a) { continue }
        if (-not $h.Contains($a['decision'])) { $h[$a['decision']] = [System.Collections.Generic.List[object]]::new() }
        $h[$a['decision']].Add($a)
    }
    $h
}

# The earlier answers to one decision (all but the last), as text: "Yes by <name> at <time>; No by ...".
function Format-EarlierAnswers($List, [switch] $WithReason) {
    $items = @($List)
    if ($items.Count -le 1) { return '' }
    (@($items[0..($items.Count - 2)] | ForEach-Object {
        $t = '{0} by {1} at {2}' -f $_['answer'], $_['by'], $_['at']
        if ($WithReason -and $_['reason']) { $t += ' (reason: ' + $_['reason'] + ')' }
        $t }) -join '; ')
}

# The text sent to the model: the fixed prompt, then the summary as compact JSON.
function New-BriefRequestText([string] $SummaryPath, [string] $PromptPath) {
    $summaryText = Get-Content -LiteralPath $SummaryPath -Raw -Encoding utf8
    $compact = $summaryText | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress
    $promptText = (Get-Content -LiteralPath $PromptPath -Raw -Encoding utf8).Trim() -replace "`r`n", "`n"
    $promptText + "`n`nThe summary:`n`n" + $compact
}

# A timestamp typed or read for a decision: ISO 8601 with Z or an offset, kept as UTC to the second.
function ConvertTo-UtcStamp([string] $Value) {
    $o = [datetimeoffset]::MinValue
    if ($Value -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$' -and
        [datetimeoffset]::TryParse($Value, $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$o)) {
        return $o.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv)
    }
    $null
}
