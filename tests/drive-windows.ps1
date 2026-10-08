# Run with pwsh -NoProfile -File tests/drive-windows.ps1 on a Windows prep host.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath $repo -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors | Out-String) }
}
. (Join-Path $repo 'launch/lib/windows.ps1')
$testRoot = Join-Path $repo ('.drive-test-' + [Guid]::NewGuid().ToString('N'))
try {
    $shared = Join-Path $testRoot 'shared'
    $native = Join-Path $testRoot 'native space'
    [IO.Directory]::CreateDirectory((Join-Path $native 'bin/win32-x64')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $shared 'credentials')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $shared 'credentials/claude-oauth-token'), 'fake-token')
    $before = [Environment]::GetEnvironmentVariables()
    $envMap = Get-DriveEnvironment $shared $native 'win32-x64'
    if ($envMap.CODEX_HOME -ne (Join-Path $native 'state/codex')) { throw 'Wrong CODEX_HOME' }
    if ($envMap.CLAUDE_CODE_OAUTH_TOKEN -ne 'fake-token') { throw 'Token not loaded' }
    foreach ($key in @('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','OPENAI_API_KEY','ANTHROPIC_BASE_URL','OPENAI_BASE_URL')) {
        if ($envMap.ContainsKey($key)) { throw "Inherited credential: $key" }
    }
    foreach ($key in $before.Keys) {
        if ([Environment]::GetEnvironmentVariable($key) -ne $before[$key]) { throw "Host environment changed: $key" }
    }
    function Get-Volume { param($FileSystemLabel) if ($FileSystemLabel -ne 'AI-WIN') { throw 'Wrong label' }; [PSCustomObject]@{DriveLetter='W'; FileSystem='NTFS'} }
    if ((Find-DriveNative) -ne 'W:\') { throw 'Wrong volume discovery' }
    function Get-Volume { param($FileSystemLabel) @([PSCustomObject]@{DriveLetter='W';FileSystem='NTFS'},[PSCustomObject]@{DriveLetter='X';FileSystem='NTFS'}) }
    $rejected = $false
    try { Find-DriveNative | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Duplicate labels accepted' }
    # Compilation validates the process supervisor without starting a CLI.
    Add-Type -Path (Join-Path $repo 'launch/lib/DriveChild.cs')
    if ([DriveChild]::Quote('space argument') -ne '"space argument"') { throw 'Argument quoting failed' }
    Write-Host 'PowerShell parsing, child environment, volume discovery and supervisor compilation passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
