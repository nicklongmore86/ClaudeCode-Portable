param([Parameter(Position=0)][string]$Action='menu', [Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArgs)
$ErrorActionPreference = 'Stop'
Set-PSDebug -Off
. (Join-Path $PSScriptRoot 'lib\windows.ps1')
$shared = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\wsl.ps1')
$nativeReady = $false
$result = 0
while ($true) {
    $selected = $Action
    if ($Action -eq 'menu') {
        Write-Host "`n1 Claude Code`n2 Codex`n3 Dashboard`n4 Login setup`n5 Audit`n7 WSL mode`n6 Exit"
        $selected = Read-Host 'Choose'
    }
    try {
        if ($selected -in '1','claude','2','codex','3','dashboard','4','login','5','audit') {
            if (!$nativeReady) {
                $native = Find-DriveNative
                $architecture = $env:PROCESSOR_ARCHITEW6432
                if (!$architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
                $arch = switch ($architecture) { 'AMD64' {'x64'} 'ARM64' {'arm64'} default {throw "Unsupported CPU: $architecture"} }
                $bin = Join-Path $native "bin\win32-$arch"
                # Provisioning compiles this small supervisor DLL on a Windows prep machine.
                # Loading it avoids Add-Type compiler temp writes on target hosts (PowerShell 5).
                Add-Type -Path (Join-Path $native 'tools\DriveChild.dll')
                $nativeReady = $true
            }
            $childEnv = Get-DriveEnvironment $shared $native "win32-$arch"
        }
        switch ($selected) {
            {$_ -in '1','claude'} {
                if (!(Test-Path -LiteralPath $childEnv.CLAUDE_CODE_GIT_BASH_PATH)) { throw 'Portable Git is missing; complete provisioning first.' }
                $result = Invoke-DriveChild (Join-Path $bin 'claude.exe') $CliArgs $childEnv
            }
            {$_ -in '2','codex'} { $result = Invoke-DriveCodex $shared $bin $childEnv $CliArgs }
            {$_ -in '3','dashboard'} { $result = Invoke-DriveChild (Join-Path $bin 'node\node.exe') (@((Join-Path $native 'tools\dashboard\tools\launcher.mjs'),'dashboard') + $CliArgs) $childEnv }
            {$_ -in '4','login'} {
                $login = Read-Host 'Login: 1 Claude subscription, 2 Codex device, 3 Codex browser'
                switch ($login) {
                    '1' {
                        $loginEnv = $childEnv.Clone(); $loginEnv.Remove('CLAUDE_CODE_OAUTH_TOKEN')
                        $result = Invoke-DriveChild (Join-Path $bin 'claude.exe') @('setup-token') $loginEnv
                        if ($result -ne 0) { throw 'Claude setup-token failed; no token saved.' }
                        $secret = Read-Host 'Paste token (hidden)' -AsSecureString
                        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
                        try {
                            $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr).Replace("`r", '').Replace("`n", '').Trim()
                            if (!$token) { throw 'Empty token; nothing saved.' }
                            $credentials = Join-Path $shared 'credentials'
                            [IO.Directory]::CreateDirectory($credentials) | Out-Null
                            $next = Join-Path $credentials 'claude-oauth-token.next'
                            [IO.File]::WriteAllText($next, $token)
                            Move-Item -LiteralPath $next -Destination (Join-Path $credentials 'claude-oauth-token') -Force
                        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $token=$null; $secret.Dispose() }
                    }
                    '2' { $result = Invoke-DriveCodex $shared $bin $childEnv @('login','--device-auth') }
                    '3' { $result = Invoke-DriveCodex $shared $bin $childEnv @('login') }
                    default { throw 'Unknown login option' }
                }
            }
            {$_ -in '5','audit'} {
                $auditArgs = $CliArgs
                if ($Action -eq 'menu') {
                    $logs = Join-Path $shared 'logs'
                    [IO.Directory]::CreateDirectory($logs) | Out-Null
                    switch (Read-Host 'Audit: 1 Before snapshot, 2 After snapshot, 3 Diff') {
                        '1' { $auditArgs = @('snapshot', (Join-Path $logs 'before.txt')) }
                        '2' { $auditArgs = @('snapshot', (Join-Path $logs 'after.txt')) }
                        '3' { $auditArgs = @('diff', (Join-Path $logs 'before.txt'), (Join-Path $logs 'after.txt')) }
                        default { throw 'Unknown audit option' }
                    }
                }
                & (Join-Path $shared 'tools\audit\audit.ps1') @auditArgs
            }
            {$_ -in '7','wsl'} { $result = Invoke-DriveWsl $PSScriptRoot $CliArgs }
            {$_ -in '6','exit'} { exit 0 }
            default { throw 'Choose claude, codex, dashboard, login, audit, wsl or exit' }
        }
    } catch { Write-Error $_ -ErrorAction Continue; $result = 1 }
    if ($Action -ne 'menu') { exit $result }
}
