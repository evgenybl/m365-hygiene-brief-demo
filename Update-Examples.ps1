#requires -Version 7.4
<#
.SYNOPSIS
    Writes examples/ again: the whole story of Invoke-Demo.ps1 on the shipped data, with its fixed dates and times.

.DESCRIPTION
    It removes the folder named examples beside this script, and only that folder, then runs Invoke-Demo.ps1 into it
    in this process, so the run keeps this session's culture. The files must come out byte for byte the same on every
    machine, day, time zone and culture; the CI workflow runs this script and fails on any difference with git.

.EXAMPLE
    pwsh -File Update-Examples.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Demo.ps1'))) { throw 'run this file from the repository' }
$examples = Join-Path $PSScriptRoot 'examples'
if ((Split-Path -Leaf $examples) -cne 'examples' -or (Split-Path -Parent $examples) -ne $PSScriptRoot) { throw 'unexpected examples path' }
if (Test-Path -LiteralPath $examples) { Remove-Item -LiteralPath $examples -Recurse -Force }

Push-Location -LiteralPath $PSScriptRoot
try {
    & (Join-Path $PSScriptRoot 'Invoke-Demo.ps1') -OutDir 'examples'
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
