# A local HTTP server for the tests and the failure gallery. It listens on 127.0.0.1 only, on a free port chosen by the
# system, answers each request from a script block, records every request it receives (method, target and headers),
# and stops when the child process it serves has ended. Nothing it serves leaves this computer. It defines functions
# only; it is dot-sourced by Test-Demo.ps1 and Invoke-Demo.ps1, never by a script that reads a tenant.
#
# Its Microsoft Graph answers serve the collector, Export-TenantSnapshot.ps1, which is labelled: Mock: written from
# Microsoft's documentation, tested against a local mock, never run against a tenant.

function Invoke-WithLocalMock {
    param(
        # param($Method, $Target, $Headers, $Body, $Count): returns @{ Status = <int>; Headers = @{...}; Body = <string> }.
        # $Count is the number of requests already received for the same path.
        [Parameter(Mandatory)] [scriptblock] $Answer,
        # The arguments for a child pwsh; '{base}' in any of them becomes the server's address, http://127.0.0.1:<port>.
        [Parameter(Mandatory)] [string[]] $PwshArgs,
        [int] $TimeoutSec = 180
    )
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $base = 'http://127.0.0.1:' + ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $childArgs = @($PwshArgs | ForEach-Object { $_.Replace('{base}', $base) })
    $job = Start-Job -ScriptBlock {
        param([string[]] $ArgList)
        & pwsh -NoProfile @ArgList 2>&1 | ForEach-Object { [string]$_ }
        "EXIT $LASTEXITCODE"
    } -ArgumentList (, $childArgs)
    $requests = [System.Collections.Generic.List[object]]::new()
    $perPath = @{}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $pending = $listener.AcceptTcpClientAsync()
    try {
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSec) {
            if (-not $pending.Wait(200)) {
                if ($job.State -notin 'Running', 'NotStarted') { break }
                continue
            }
            $client = $pending.Result
            $pending = $listener.AcceptTcpClientAsync()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 15000
                $buf = New-Object byte[] 65536
                $ms = New-Object System.IO.MemoryStream
                $headEnd = -1; $need = -1
                do {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -gt 0) { $ms.Write($buf, 0, $n) }
                    $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                    if ($headEnd -lt 0) { $headEnd = $raw.IndexOf("`r`n`r`n") }
                    if ($headEnd -ge 0 -and $need -lt 0) {
                        $need = if ($raw.Substring(0, $headEnd) -match '(?im)^content-length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
                    }
                    $have = if ($headEnd -ge 0) { $ms.Length - [Text.Encoding]::UTF8.GetByteCount($raw.Substring(0, $headEnd + 4)) } else { 0 }
                } while ($n -gt 0 -and -not ($headEnd -ge 0 -and $have -ge $need))
                $lines = $raw.Substring(0, [math]::Max($headEnd, 0)).Split("`r`n")
                $method, $target = ($lines[0] -split ' ')[0, 1]
                $headers = @{}
                foreach ($h in $lines | Select-Object -Skip 1) { if ($h -match '^([^:]+):\s*(.*)$') { $headers[$Matches[1].ToLowerInvariant()] = $Matches[2] } }
                $body = if ($headEnd -ge 0) { $raw.Substring($headEnd + 4) } else { '' }
                $path = ($target -split '\?')[0]
                $count = if ($perPath.ContainsKey($path)) { $perPath[$path] } else { 0 }
                $perPath[$path] = $count + 1
                $requests.Add([pscustomobject]@{ Method = $method; Target = $target; Path = $path; Headers = $headers; Body = $body })
                $reply = & $Answer $method $target $headers $body $count
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$reply.Body.Replace('{base}', $base))
                $extra = ''
                if ($reply.ContainsKey('Headers') -and $reply.Headers) { foreach ($k in $reply.Headers.Keys) { $extra += "${k}: $($reply.Headers[$k])`r`n" } }
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $($reply.Status) Mock`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`n${extra}Connection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            } catch {
                $requests.Add([pscustomobject]@{ Method = 'MOCK ERROR'; Target = $_.Exception.Message; Path = ''; Headers = @{}; Body = '' })
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
    }
    $null = Wait-Job -Job $job -Timeout 120
    $out = @(Receive-Job -Job $job)
    Remove-Job -Job $job -Force
    $code = if ($out.Count -and $out[-1] -match '^EXIT (-?\d+)$') { [int]$Matches[1] } else { -1 }
    [pscustomobject]@{ Requests = $requests.ToArray(); Lines = @($out | Select-Object -SkipLast 1); ExitCode = $code; Base = $base }
}

# The answers of a Microsoft Graph mock, from the JSON files in mock/graph (shaped as the documentation's examples
# show). -Throttle answers the first request for that collection with 429 and Retry-After: 1. -Fail answers that
# collection with the given status. -BadNextLink makes the first users page point to a path outside the fixed list.
function New-GraphMockAnswer {
    param([string] $Folder, [string] $Throttle = '', [string] $Fail = '', [int] $FailStatus = 403, [switch] $BadNextLink)
    $files = @{
        '/v1.0/users' = 'users-page-1.json'; '/v1.0/subscribedSkus' = 'subscribedSkus.json'
        '/v1.0/roleManagement/directory/roleAssignments' = 'roleAssignments.json'
        '/v1.0/reports/authenticationMethods/userRegistrationDetails' = 'userRegistrationDetails.json'
        '/v1.0/identity/conditionalAccess/policies' = 'policies.json'
        '/v1.0/policies/identitySecurityDefaultsEnforcementPolicy' = 'securityDefaults.json'
    }
    $names = @{ users = '/v1.0/users'; licences = '/v1.0/subscribedSkus'; roles = '/v1.0/roleManagement/directory/roleAssignments'
        registration = '/v1.0/reports/authenticationMethods/userRegistrationDetails'; policies = '/v1.0/identity/conditionalAccess/policies'
        securityDefaults = '/v1.0/policies/identitySecurityDefaultsEnforcementPolicy' }
    $throttlePath = if ($Throttle) { $names[$Throttle] } else { '' }
    $failPath = if ($Fail) { $names[$Fail] } else { '' }
    {
        param($Method, $Target, $Headers, $Body, $Count)
        $path = ($Target -split '\?')[0]
        if ($Method -ne 'GET' -or -not $files.ContainsKey($path)) {
            return @{ Status = 404; Body = '{"error":{"code":"mock_not_found","message":"The mock has no answer for this request."}}' }
        }
        if ($path -eq $throttlePath -and $Count -eq 0) {
            return @{ Status = 429; Headers = @{ 'Retry-After' = '1' }; Body = '{"error":{"code":"TooManyRequests","message":"Please retry again later."}}' }
        }
        if ($path -eq $failPath) {
            return @{ Status = $FailStatus; Body = '{"error":{"code":"mock_refused","message":"The mock refuses this request."}}' }
        }
        $file = if ($path -eq '/v1.0/users' -and $Target.Contains('skiptoken=mock-page-2')) { 'users-page-2.json' } else { $files[$path] }
        $text = [IO.File]::ReadAllText((Join-Path $Folder $file))
        if ($BadNextLink -and $file -eq 'users-page-1.json') { $text = $text.Replace('{base}/v1.0/users?', '{base}/v1.0/groups?') }
        @{ Status = 200; Body = $text }
    }.GetNewClosure()
}
