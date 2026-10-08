# Windows PowerShell 5-compatible WSL entrypoint; no compiler or temporary files.
function ConvertTo-WslArgument([AllowEmptyString()][string]$Value) {
    # Windows CommandLineToArgvW quoting, including embedded quotes and trailing \.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-WslProcess($Executable, [string[]]$Arguments, [switch]$Capture, [switch]$List) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-WslArgument $_ }) -join ' ')
    if ($Capture) {
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # WSL's own list output is UTF-16LE; Linux command output is UTF-8.
        # Remove the optional UTF-8 override only from this child's environment.
        $info.EnvironmentVariables.Remove('WSL_UTF8')
        $encoding = if ($List) { [Text.Encoding]::Unicode } else { [Text.Encoding]::UTF8 }
        $info.StandardOutputEncoding = $encoding
        $info.StandardErrorEncoding = $encoding
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        if ($Capture) {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
        }
        $process.WaitForExit()
        if ($Capture) {
            return [PSCustomObject]@{ Code=$process.ExitCode; Output=$stdout.Result; Error=$stderr.Result }
        }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function ConvertFrom-WslList([string]$Text) {
    # StreamReader handles an optional BOM; tolerate one in test/other callers too.
    $Text.TrimStart([char]0xFEFF) -split '\r?\n' | ForEach-Object {
        $name = $_.Trim()
        if ($name) { $name }
    }
}

function Select-WslDistro([string[]]$Names, [string]$VerboseList, [string]$Override) {
    if (!$Names.Count) { throw 'No WSL distro is installed. Ask the host owner to prepare a WSL2 distro first, then retry. The launcher installs nothing.' }
    if ($Override) {
        if ($Names -notcontains $Override) { throw "PORTABLE_AI_WSL_DISTRO '$Override' is not installed. Choose an installed distro using wsl.exe -l -q." }
        return $Override
    }
    foreach ($line in (ConvertFrom-WslList $VerboseList)) {
        foreach ($name in ($Names | Sort-Object Length -Descending)) {
            # Match the default marker and exact name, independent of UI language.
            if ($line -match ('^\*\s+' + [regex]::Escape($name) + '\s+.+\s+[12]\s*$')) { return $name }
        }
    }
    if ($Names.Count -eq 1) { return $Names[0] }
    for ($i = 0; $i -lt $Names.Count; $i++) { Write-Host "$($i + 1) $($Names[$i])" }
    $choice = Read-Host 'No default WSL distro found. Choose a number (or set PORTABLE_AI_WSL_DISTRO)'
    $index = 0
    if (![int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $Names.Count) { throw 'No valid WSL distro selected.' }
    return $Names[$index - 1]
}

function ConvertTo-WslPath($Executable, $Distro, [string]$WindowsPath) {
    # --exec bypasses the distro shell: paths/args are data, never shell code.
    $translated = Invoke-WslProcess $Executable @('-d', $Distro, '--exec', 'wslpath', '-a', $WindowsPath) -Capture
    $path = $translated.Output.TrimEnd("`r", "`n")
    if ($translated.Code -ne 0 -or !$path.StartsWith('/') -or $path.Contains("`n") -or $path.Contains("`r")) {
        throw "Cannot translate '$WindowsPath' in WSL distro '$Distro'. Ensure the drive/project is accessible there and wslpath is available."
    }
    return $path
}

function Invoke-DriveWsl($LauncherDirectory, [string[]]$CliArgs) {
    $command = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$command) { throw 'WSL is unavailable (wsl.exe missing). Ask the host owner to prepare WSL2 and a Linux distro first, then retry. The launcher installs nothing.' }
    $executable = $command.Source
    $listing = Invoke-WslProcess $executable @('-l', '-q') -Capture -List
    if ($listing.Code -ne 0) { throw 'Cannot list WSL distros. Ask the host owner to check WSL2 and an installed distro with wsl.exe -l -v, then retry. The launcher installs nothing.' }
    $names = @(ConvertFrom-WslList $listing.Output)
    $verbose = Invoke-WslProcess $executable @('-l', '-v') -Capture -List
    if ($verbose.Code -ne 0) { throw 'Cannot inspect WSL distros. Check wsl.exe -l -v with the host owner before retrying.' }
    $distro = Select-WslDistro $names $verbose.Output $env:PORTABLE_AI_WSL_DISTRO
    $linux = Join-Path $LauncherDirectory 'linux.sh'
    if (!(Test-Path -LiteralPath $linux -PathType Leaf)) { throw "Missing Linux launcher: $linux. Restore AI-SHARED/launch from the provisioned drive." }
    $linuxPath = ConvertTo-WslPath $executable $distro $linux
    $workingDirectory = ConvertTo-WslPath $executable $distro (Get-Location).ProviderPath
    # Inherit console handles for menus, login prompts and Ctrl+C; never capture.
    return Invoke-WslProcess $executable (@('-d', $distro, '--cd', $workingDirectory, '--exec', 'bash', $linuxPath) + $CliArgs)
}
