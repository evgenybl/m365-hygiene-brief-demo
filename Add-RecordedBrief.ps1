#requires -Version 7.4
<#
.SYNOPSIS
    Adds a model answer to recordings/: copies it byte for byte and writes its meta file, after proving that the answer
    was given to the request this repository builds today.

.DESCRIPTION
    How a recording is made:
      1. New-ManagerBrief.ps1 -WriteRequest <file> writes the exact request text to a file.
      2. A person gives that text, as the whole prompt, to a model, and saves the model's answer unedited.
      3. This script compares the request file with the request built now from -SummaryJson and -Prompt. If their
         sha256 differ, it refuses (exit 2): the answer belongs to another request. Otherwise it copies the answer
         byte for byte to <Into>/<Name>.md and writes <Into>/<Name>.meta.json with origin "recorded", the model's
         name, how the answer was obtained, the date, the request's sha256 and the answer's sha256.

    New-ManagerBrief.ps1 labels a saved answer "Recorded" only when both hashes in its meta file still match and its
    model name, date and account of how it was obtained are well formed; this script refuses them otherwise.
    It never overwrites a recording, and it changes nothing else.

.EXAMPLE
    pwsh -File Add-RecordedBrief.ps1 -Answer answer.md -RequestFile request.txt -SummaryJson examples/findings/findings-summary.json -Model <model name> -Obtained "<how it was obtained>" -RecordedOn <yyyy-MM-dd> -Name brief.recorded
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Answer,
    [Parameter(Mandatory)] [string] $RequestFile,
    [Parameter(Mandatory)] [string] $SummaryJson,
    [Parameter(Mandatory)] [string] $Model,
    [Parameter(Mandatory)] [string] $Obtained,
    [Parameter(Mandatory)] [string] $RecordedOn,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$')] [string] $Name,
    [string] $Prompt = (Join-Path $PSScriptRoot 'prompt-brief.txt'),
    [string] $Into = (Join-Path $PSScriptRoot 'recordings')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"
$inv = [cultureinfo]::InvariantCulture

$d = [datetime]::MinValue
if (-not ($RecordedOn -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($RecordedOn, 'yyyy-MM-dd', $inv, 'None', [ref]$d))) {
    Stop-Refused 'RecordedOn must be a date written yyyy-MM-dd'
}
if ($Model -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$') { Stop-Refused 'Model must be a plain model name: letters, digits, dot, underscore, colon and hyphen' }
if ([string]::IsNullOrWhiteSpace($Obtained) -or -not (Test-PlainText $Obtained) -or $Obtained.Length -gt 1000) {
    Stop-Refused 'Obtained must be plain text on one line, at most 1000 characters'
}
$answerPath = Join-Path $Into ($Name + '.md')
$metaPath = Join-Path $Into ($Name + '.meta.json')
foreach ($p in @($answerPath, $metaPath)) { if (Test-Path -LiteralPath $p) { Stop-Refused "refusing to overwrite $(Split-Path $p -Leaf)" } }

$requestNow = New-BriefRequestText $SummaryJson $Prompt
$shaNow = Get-TextSha256 $requestNow
$shaGiven = Get-FileSha256 $RequestFile
if ($shaGiven -ne $shaNow) {
    Stop-Refused "the request file (sha256 $shaGiven) is not the request built now (sha256 $shaNow); the answer belongs to another request"
}
$bytes = [IO.File]::ReadAllBytes((Resolve-FullPath $Answer))
if ($bytes.Length -eq 0) { Stop-Refused 'the answer file is empty' }
$answerSha = Get-BytesSha256 $bytes

if (-not (Test-Path -LiteralPath $Into)) { New-Item -ItemType Directory -Path $Into | Out-Null }
[IO.File]::WriteAllBytes((Resolve-FullPath $answerPath), $bytes)
if ((Get-FileSha256 $answerPath) -ne $answerSha) { Stop-Refused 'the copy does not match the answer' 1 }
$meta = [ordered]@{
    origin = 'recorded'; model = $Model; obtained = $Obtained; recorded_on = $RecordedOn
    request_sha256 = $shaNow; answer_sha256 = $answerSha
    note = 'The answer is saved unedited. A test checks that the script still builds the request with this sha256.'
}
Write-TextFile $metaPath ((ConvertTo-JsonText $meta) + "`n")
Write-Output ('recorded {0} | answer sha256 {1} | request sha256 {2}' -f (Split-Path $answerPath -Leaf), $answerSha, $shaNow)
