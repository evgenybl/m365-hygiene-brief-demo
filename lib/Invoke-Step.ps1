# Runs one script of this repository in a child process with a given culture, so that a run started under one culture
# (de-DE, for example) runs every step under it too. It passes every other argument to the script and returns its exit
# code; an error that stops the script returns 1.
#
#   pwsh -NoProfile -File lib/Invoke-Step.ps1 -WrapCulture de-DE -WrapScript <script> <the script's own arguments>
param([string] $WrapCulture, [string] $WrapScript)
$ErrorActionPreference = 'Stop'
if ($WrapCulture) {
    [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo($WrapCulture)
    [cultureinfo]::CurrentUICulture = [cultureinfo]::GetCultureInfo($WrapCulture)
}
$global:LASTEXITCODE = 0
try {
    & $WrapScript @args
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
exit $LASTEXITCODE
