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

# A name typed by a person is refused when it is empty, starts like a spreadsheet formula, or holds a control character.
function Test-TypedName([string] $Name) {
    -not [string]::IsNullOrWhiteSpace($Name) -and $Name -notmatch '^\s*[=+\-@]' -and $Name -notmatch '[\x00-\x1F\x7F]' -and
        $Name.Trim().Length -le 100
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
