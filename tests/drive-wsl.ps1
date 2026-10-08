$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'launch/lib/wsl.ps1')
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected <$Expected>, got <$Actual>" }
}
function Assert-Throws([scriptblock]$Body, [string]$Message) {
    try { & $Body | Out-Null } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure: $Message"
}

# Decode an actual UTF-16LE byte fixture through the same .NET reader as production.
$bytes = [Text.Encoding]::Unicode.GetBytes("Ubuntu`r`nDistro space`r`nDistro-$([char]0x00E9)`r`n")
$stream = [IO.MemoryStream]::new($bytes)
$reader = [IO.StreamReader]::new($stream, [Text.Encoding]::Unicode)
try {
    $names = @(ConvertFrom-WslList $reader.ReadToEnd())
    Assert-Equal $names.Count 3
    Assert-Equal $names[1] 'Distro space'
    Assert-Equal $names[2] "Distro-$([char]0x00E9)"
} finally { $reader.Dispose(); $stream.Dispose() }
Assert-Equal (@(ConvertFrom-WslList "`r`n").Count) 0
Assert-Equal (ConvertFrom-WslList "$([char]0xFEFF)Ubuntu`r`n") 'Ubuntu'
$names = @('Ubuntu', 'Ubuntu Custom', 'Debian')
$verbose = "  NAME             STATE       VERSION`r`n* Ubuntu Custom    Stopped     2`r`n  Debian           Running     2"
Assert-Equal (Select-WslDistro $names $verbose '') 'Ubuntu Custom'
Assert-Equal (Select-WslDistro $names $verbose 'Debian') 'Debian'
Assert-Equal (Select-WslDistro @('Debian') '' '') 'Debian'
Assert-Throws { Select-WslDistro @() '' '' } 'No WSL distro'
Assert-Throws { Select-WslDistro $names $verbose 'Missing' } 'not installed'
function Read-Host { return '3' }
Assert-Equal (Select-WslDistro $names '' '') 'Debian'
function Read-Host { return '0' }
Assert-Throws { Select-WslDistro $names '' '' } 'No valid'
function Read-Host { return 'not-a-number' }
Assert-Throws { Select-WslDistro $names '' '' } 'No valid'
Remove-Item Function:Read-Host

Assert-Equal (ConvertTo-WslArgument '') '""'
Assert-Equal (ConvertTo-WslArgument 'S:\Drive space\launch\linux.sh') '"S:\Drive space\launch\linux.sh"'
Assert-Equal (ConvertTo-WslArgument 'C:\project space\') '"C:\project space\\"'
Assert-Equal (ConvertTo-WslArgument 'say "hello"') '"say \"hello\""'
Assert-Equal (ConvertTo-WslArgument 'a\"b') '"a\\\"b"'
Assert-Equal (ConvertTo-WslArgument '$(touch nope); & stuff') '"$(touch nope); & stuff"'

# Stub only the external process boundary: exercise real discovery and dispatch.
$script:calls = [Collections.Generic.List[object]]::new()
$script:listCode = 0
$script:listOutput = "Ubuntu`r`nDebian`r`n"
$script:pathCode = 0
$script:pathOutput = '/custom mount/Shared drive/launch/linux.sh'
function Get-Command { [PSCustomObject]@{ Source='mock-wsl.exe' } }
function Invoke-WslProcess($Executable, [string[]]$Arguments, [switch]$Capture, [switch]$List) {
    $script:calls.Add([PSCustomObject]@{ Executable=$Executable; Arguments=$Arguments; Capture=$Capture.IsPresent; List=$List.IsPresent })
    if ($List) {
        $output = if ($Arguments[1] -eq '-q') { $script:listOutput } else { '* Ubuntu    Running    2' }
        return [PSCustomObject]@{ Code=$script:listCode; Output=$output; Error='' }
    }
    if ($Capture) { return [PSCustomObject]@{ Code=$script:pathCode; Output=$script:pathOutput; Error='' } }
    return 37
}
$before = $env:PORTABLE_AI_WSL_DISTRO
try {
    $env:PORTABLE_AI_WSL_DISTRO = 'Debian'
    $cli = @('codex', 'exec', 'spaces and "quotes"', '', '$(touch nope); & text', 'trailing\')
    Assert-Equal (Invoke-DriveWsl (Join-Path $repo 'launch') $cli) 37
    Assert-Equal $script:calls.Count 5
    Assert-Equal $script:calls[0].List $true
    Assert-Equal $script:calls[2].Arguments[1] 'Debian'
    Assert-Equal $script:calls[2].Arguments[5] (Join-Path $repo 'launch/linux.sh')
    Assert-Equal $script:calls[3].Arguments[5] (Get-Location).ProviderPath
    $last = $script:calls[4]
    Assert-Equal $last.Capture $false
    $expected = @('-d', 'Debian', '--cd', $script:pathOutput, '--exec', 'bash', $script:pathOutput) + $cli
    Assert-Equal ($last.Arguments | ConvertTo-Json -Compress) ($expected | ConvertTo-Json -Compress)
    $script:pathCode = 1
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'Cannot translate'
    $script:pathCode = 0
    $script:pathOutput = 'relative/path'
    Assert-Throws { ConvertTo-WslPath 'mock' 'Debian' 'S:\' } 'Cannot translate'
    $script:listCode = 1
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'Cannot list WSL'
    $script:listCode = 0
    $script:listOutput = ''
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'No WSL distro'
    function Get-Command { return $null }
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'wsl.exe missing'
} finally { $env:PORTABLE_AI_WSL_DISTRO = $before }
Write-Host 'WSL list decoding, selection, quoting, translation, argument/exit forwarding and failures passed.'
