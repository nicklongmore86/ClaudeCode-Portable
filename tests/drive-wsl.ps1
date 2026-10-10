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

# Exercise the production decoder with real UTF-16LE/UTF-8 byte fixtures.
$sample = "Ubuntu`r`nDistro space`r`nDistro-$([char]0x00E9)`r`n"
$names = @(ConvertFrom-WslList (ConvertFrom-WslBytes ([Text.Encoding]::Unicode.GetBytes($sample)) -List))
Assert-Equal $names.Count 3
Assert-Equal $names[1] 'Distro space'
Assert-Equal $names[2] "Distro-$([char]0x00E9)"
foreach ($encoding in @([Text.Encoding]::Unicode, [Text.Encoding]::UTF8)) {
    Assert-Equal (ConvertFrom-WslBytes ($encoding.GetBytes($sample))) $sample
}
Assert-Equal (ConvertFrom-WslBytes ([byte[]]@())) ''

# Run the REAL process boundary before mocking it. Node is the harmless echo
# child; stdin must already be EOF, stdout/stderr have different encodings,
# Windows argument quoting must round-trip, and exit status must survive.
$node = $env:PORTABLE_AI_TEST_NODE
if (!$node) { $node = (Get-Command node -CommandType Application -ErrorAction Stop).Source }
$fixture = Join-Path $PSScriptRoot 'wsl-process-fixture.mjs'
$roundTrip = @('', 'space argument', 'say "hello"', 'C:\trailing space\', 'a\"b', "non-ASCII-$([char]0x00E9)", ("'&;" + '$()'))
foreach ($encodings in @(@('utf8', 'utf16le'), @('utf16le', 'utf8'))) {
    $result = Invoke-WslProcess $node (@($fixture, $encodings[0], $encodings[1], 'echo') + $roundTrip) -Capture -List:($encodings[0] -eq 'utf16le')
    Assert-Equal $result.Code 23
    $echo = $result.Output | ConvertFrom-Json
    Assert-Equal $echo.stdin ''
    Assert-Equal ($echo.args | ConvertTo-Json -Compress) ($roundTrip | ConvertTo-Json -Compress)
    Assert-Equal $result.Error "Kernel update needed; VM platform disabled; no distros. $([char]0x00E9)`n"
}
$result = Invoke-WslProcess $node @($fixture, 'utf8', 'utf16le', 'wait') -Capture -TimeoutMilliseconds 1000
Assert-Equal $result.Code 124
if ($result.Error -notlike '*timed out*' -or $result.Error -notlike '*Kernel update needed*') { throw 'Timeout lost diagnostics' }
Assert-Equal (Invoke-WslProcess $node @('-e', 'process.exit(29)')) 29

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
$script:verboseOutput = "* Ubuntu    Running    2`r`n  Debian    Stopped    2"
$script:verboseCode = 0
$script:pathCode = 0
$script:pathOutput = '/custom mount/Shared drive/launch/linux.sh'
$script:reachableCode = 0
$script:diagnostic = 'Kernel update needed / VM platform disabled / no distros'
function Get-Command { [PSCustomObject]@{ Source='mock-wsl.exe' } }
function Invoke-WslProcess($Executable, [string[]]$Arguments, [switch]$Capture, [switch]$List) {
    $script:calls.Add([PSCustomObject]@{ Executable=$Executable; Arguments=$Arguments; Capture=$Capture.IsPresent; List=$List.IsPresent })
    if ($List) {
        if ($Arguments[1] -eq '-q') { return [PSCustomObject]@{ Code=$script:listCode; Output=$script:listOutput; Error=$script:diagnostic } }
        return [PSCustomObject]@{ Code=$script:verboseCode; Output=$script:verboseOutput; Error=$script:diagnostic }
    }
    if ($Capture) {
        if ($Arguments[3] -eq 'test') { return [PSCustomObject]@{ Code=$script:reachableCode; Output='reachability output'; Error=$script:diagnostic } }
        return [PSCustomObject]@{ Code=$script:pathCode; Output=$script:pathOutput; Error=$script:diagnostic }
    }
    return 37
}
# Mock registry reads, never use or modify the test host's registrations.
$script:registrationMode = 'registered'
$script:registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
function Test-Path($LiteralPath, $PathType) {
    if ($LiteralPath -eq $script:registryPath) { return $script:registrationMode -ne 'missing' }
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
}
function Get-ChildItem($LiteralPath) {
    Assert-Equal $LiteralPath $script:registryPath
    if ($script:registrationMode -eq 'denied') { throw 'registry access denied' }
    if ($script:registrationMode -ne 'empty') { [PSCustomObject]@{ PSPath='mock-registration' } }
}
function Get-ItemProperty($LiteralPath) {
    Assert-Equal $LiteralPath 'mock-registration'
    if ($script:registrationMode -eq 'nameless') { return [PSCustomObject]@{} }
    return [PSCustomObject]@{ DistributionName='Debian' }
}
foreach ($mode in @('missing', 'empty', 'nameless', 'denied')) {
    $script:registrationMode = $mode
    $script:calls.Clear()
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') $null } 'No wsl.exe process was started'
    Assert-Equal $script:calls.Count 0
}
$script:registrationMode = 'registered'
$before = $env:PORTABLE_AI_WSL_DISTRO
$beforeWindir = $env:windir
try {
    $env:PORTABLE_AI_WSL_DISTRO = 'Debian'
    $cli = @('codex', 'exec', 'spaces and "quotes"', '', '$(touch nope); & text', 'trailing\')
    Assert-Equal (Invoke-DriveWsl (Join-Path $repo 'launch') $cli) 37
    Assert-Equal $script:calls.Count 6
    Assert-Equal $script:calls[0].List $true
    Assert-Equal $script:calls[2].Arguments[1] 'Debian'
    Assert-Equal $script:calls[2].Arguments[5] (Join-Path $repo 'launch/linux.sh')
    Assert-Equal $script:calls[3].Arguments[5] (Get-Location).ProviderPath
    Assert-Equal $script:calls[4].Arguments[3] 'test'
    $last = $script:calls[5]
    Assert-Equal $last.Capture $false
    $expected = @('-d', 'Debian', '--cd', $script:pathOutput, '--exec', 'bash', $script:pathOutput) + $cli
    Assert-Equal ($last.Arguments | ConvertTo-Json -Compress) ($expected | ConvertTo-Json -Compress)
    foreach ($emptyArgs in @($null, @())) {
        $script:calls.Clear()
        Assert-Equal (Invoke-DriveWsl (Join-Path $repo 'launch') $emptyArgs) 37
        $last = $script:calls[$script:calls.Count - 1]
        Assert-Equal $last.Arguments.Count 7
        Assert-Equal $last.Arguments[-1] $script:pathOutput
    }
    # Bare/menu invocation explicitly passes null; no spurious empty argument.
    $script:calls.Clear()
    Assert-Equal (Invoke-DriveWsl (Join-Path $repo 'launch') $null) 37
    Assert-Equal $script:calls[5].Arguments.Count 7
    Assert-Equal $script:calls[5].Arguments[-1] $script:pathOutput

    $script:verboseOutput = "* Ubuntu    Running    1`r`n  Debian    Stopped    1"
    foreach ($override in @('', 'Debian')) {
        $env:PORTABLE_AI_WSL_DISTRO = $override
        $script:calls.Clear()
        Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') $null } 'uses WSL1'
        Assert-Equal $script:calls.Count 2 # No wslpath, state setup or session.
    }
    $env:PORTABLE_AI_WSL_DISTRO = 'Debian'
    $script:verboseOutput = "* Ubuntu    Running    2`r`n  Debian    Stopped    2"
    Assert-Throws { Assert-Wsl2Distro @('Debian') 'Debian Stopped unknown' 'Debian' } 'Cannot determine'
    Assert-Wsl2Distro @('Ubuntu', 'Ubuntu Custom') "* Ubuntu Custom    Running    1`r`n  Ubuntu    Stopped    2" 'Ubuntu'

    $script:reachableCode = 1
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'stops ALL running distros'
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } $script:diagnostic
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'reachability output'
    $script:reachableCode = 0
    $script:pathCode = 1
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } $script:diagnostic
    $script:pathCode = 0
    $script:pathOutput = 'relative/path'
    Assert-Throws { ConvertTo-WslPath 'mock' 'Debian' 'S:\' } 'Cannot translate'
    $script:listCode = 1
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } $script:diagnostic
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'Ubuntu'
    $script:listCode = 0
    $script:verboseCode = 1
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } $script:diagnostic
    $script:verboseCode = 0
    $script:listOutput = ''
    Assert-Throws { Invoke-DriveWsl (Join-Path $repo 'launch') @() } 'No WSL distro'

    # Simulate WOW64 without a host write or dependence on the host's windir.
    function Get-Command { return $null }
    $env:windir = $repo
    $script:sysnativeExists = $true
    function Test-Path($LiteralPath, $PathType) {
        Assert-Equal $LiteralPath (Join-Path $repo 'Sysnative/wsl.exe')
        return $script:sysnativeExists
    }
    Assert-Equal (Find-WslExecutable) (Join-Path $repo 'Sysnative/wsl.exe')
    $script:sysnativeExists = $false
    Assert-Throws { Find-WslExecutable } 'wsl.exe missing'
} finally {
    $env:PORTABLE_AI_WSL_DISTRO = $before
    $env:windir = $beforeWindir
    Remove-Item Function:Test-Path -ErrorAction SilentlyContinue
}
Write-Host 'WSL real process boundary, decoding, selection, quoting, preflight, argument/exit forwarding and failures passed.'
