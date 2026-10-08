# All environment overrides are returned as data, then supplied to CreateProcess.
function Get-DriveEnvironment($Shared, $Native, $Target) {
    $bin = Join-Path $Native "bin\$Target"
    if (!(Test-Path -LiteralPath $bin -PathType Container)) { throw "Missing binaries: $bin" }
    $childEnv = @{}
    [Environment]::GetEnvironmentVariables().GetEnumerator() | ForEach-Object { $childEnv[$_.Key] = $_.Value }
    foreach ($key in @('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','OPENAI_API_KEY','ANTHROPIC_BASE_URL','OPENAI_BASE_URL','CLAUDE_CODE_OAUTH_TOKEN')) { $childEnv.Remove($key) }
    $paths = @{
        CLAUDE_CONFIG_DIR='state\claude'; CLAUDE_CODE_TMPDIR='tmp'
        CODEX_HOME='state\codex'; CODEX_SQLITE_HOME='state\codex'
        TMPDIR='tmp'; TEMP='tmp'; TMP='tmp'
        XDG_CONFIG_HOME='state\xdg\config'; XDG_CACHE_HOME='state\xdg\cache'
        XDG_DATA_HOME='state\xdg\data'; XDG_STATE_HOME='state\xdg\state'
        HOME='state\home'; USERPROFILE='state\home'
        APPDATA='state\appdata'; LOCALAPPDATA='state\localappdata'
        PORTABLE_AI_DATA_DIR='state\dashboard'
    }
    foreach ($key in $paths.Keys) {
        $path = Join-Path $Native $paths[$key]
        [IO.Directory]::CreateDirectory($path) | Out-Null
        $childEnv[$key] = $path
    }
    foreach ($key in @('DISABLE_AUTOUPDATER','DISABLE_UPDATES','DISABLE_TELEMETRY','DISABLE_ERROR_REPORTING','PORTABLE_AI_NO_OPEN')) { $childEnv[$key] = '1' }
    $childEnv.CLAUDE_CODE_GIT_BASH_PATH = Join-Path $Native 'tools\portable-git\bin\bash.exe'
    $childEnv.PORTABLE_AI_CLAUDE_EXECUTABLE = Join-Path $bin 'claude.exe'
    $childEnv.PORTABLE_AI_RUNTIME_DIR = Join-Path $Native 'tools\dashboard-runtime'
    $childEnv.PATH = "$bin;$bin\codex\bin;$bin\codex\codex-path;$bin\node;$Native\tools\portable-git\cmd;" + $childEnv.PATH
    $token = Join-Path $Shared 'credentials\claude-oauth-token'
    if (Test-Path -LiteralPath $token) { $childEnv.CLAUDE_CODE_OAUTH_TOKEN = [IO.File]::ReadAllText($token).Replace("`r", '').Replace("`n", '').Trim() }
    return $childEnv
}

function Find-DriveNative {
    $volumes = @(Get-Volume -FileSystemLabel AI-WIN -ErrorAction Stop | Where-Object { $_.DriveLetter })
    if ($volumes.Count -ne 1) { throw 'Mount exactly one AI-WIN volume with a drive letter using Disk Management.' }
    if ($volumes[0].FileSystem -ne 'NTFS') { throw 'AI-WIN must use NTFS.' }
    return "$($volumes[0].DriveLetter):\"
}

function Enter-DriveLock($Shared) {
    $credentials = Join-Path $Shared 'credentials'
    [IO.Directory]::CreateDirectory($credentials) | Out-Null
    $lock = Join-Path $credentials 'codex-auth.lock'
    # CreateDirectory succeeds if already present: use Win32's atomic result.
    if (![DriveChild]::CreateDirectory($lock, [IntPtr]::Zero)) {
        throw "Codex is locked: $lock. After a crash, check all hosts for active sessions before removing it."
    }
    [IO.File]::WriteAllText((Join-Path $lock 'owner'), "$env:COMPUTERNAME $PID")
    return $lock
}

function Invoke-DriveCodex($Shared, $Bin, $ChildEnv, [string[]]$CliArgs) {
    $lock = Enter-DriveLock $Shared
    $authoritative = Join-Path $Shared 'credentials\codex-auth.json'
    $local = Join-Path $ChildEnv.CODEX_HOME 'auth.json'
    $ready = $false
    $synced = $true
    try {
        if (Test-Path -LiteralPath $authoritative) { Copy-Item -LiteralPath $authoritative -Destination $local -Force }
        elseif (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
        $config = @'
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
[analytics]
enabled = false
[feedback]
enabled = false
'@
        [IO.File]::WriteAllText((Join-Path $ChildEnv.CODEX_HOME 'config.toml'), $config)
        $ready = $true
        return Invoke-DriveChild (Join-Path $Bin 'codex\bin\codex.exe') (@('--no-daemon') + $CliArgs) $ChildEnv
    } finally {
        if ($ready -and (Test-Path -LiteralPath $local)) {
            try {
                if (!(Test-Path -LiteralPath $authoritative) -or (Get-Item -LiteralPath $local).LastWriteTimeUtc -gt (Get-Item -LiteralPath $authoritative).LastWriteTimeUtc) {
                    $next = Join-Path $lock 'auth.next'
                    Copy-Item -LiteralPath $local -Destination $next -Force
                    Move-Item -LiteralPath $next -Destination $authoritative -Force
                }
            } catch { $synced = $false; throw "Auth sync failed; lock retained at $lock for recovery." }
        }
        if ($synced) {
            Remove-Item -LiteralPath (Join-Path $lock 'owner') -Force
            Remove-Item -LiteralPath $lock -Force
        }
    }
}

function Invoke-DriveChild($Executable, [string[]]$CliArgs, $ChildEnv) {
    if (!(Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Missing executable: $Executable; provision this architecture first." }
    return [DriveChild]::Run($Executable, $CliArgs, $ChildEnv, (Get-Location).ProviderPath)
}
