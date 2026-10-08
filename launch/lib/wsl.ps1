# Windows PowerShell 5-compatible WSL entrypoint; no compiler or temporary files.
function ConvertTo-WslArgument([AllowEmptyString()][string]$Value) {
    # Windows CommandLineToArgvW quoting, including embedded quotes and trailing \.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function ConvertFrom-WslBytes([byte[]]$Bytes, [switch]$List) {
    # WSL diagnostics can be UTF-16LE even when the Linux command emits UTF-8.
    $unicode = $List -or ($Bytes -contains 0) -or ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254)
    $encoding = if ($unicode) { [Text.Encoding]::Unicode } else { [Text.Encoding]::UTF8 }
    return $encoding.GetString($Bytes).TrimStart([char]0xFEFF)
}

function Format-WslFailure($Result) {
    $details = @($Result.Output, $Result.Error) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
    return "WSL helper exited with code $($Result.Code)." + "`n" + ($details -join "`n")
}

function Invoke-WslProcess($Executable, [string[]]$Arguments, [switch]$Capture, [switch]$List, [int]$TimeoutMilliseconds=60000) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-WslArgument $_ }) -join ' ')
    if ($Capture) {
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # Remove the optional UTF-8 override only from this child's environment.
        $info.EnvironmentVariables.Remove('WSL_UTF8')
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $outBuffer = New-Object IO.MemoryStream
    $errBuffer = New-Object IO.MemoryStream
    try {
        [void]$process.Start()
        if ($Capture) {
            # The inbox WSL stub must never consume a console key to install WSL.
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.BaseStream.CopyToAsync($outBuffer)
            $stderr = $process.StandardError.BaseStream.CopyToAsync($errBuffer)
            $timedOut = !$process.WaitForExit($TimeoutMilliseconds)
            if ($timedOut) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
            # Bound draining too: a descendant might retain a pipe after exit.
            $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)
            $output = ConvertFrom-WslBytes $outBuffer.ToArray() -List:$List
            $errorText = ConvertFrom-WslBytes $errBuffer.ToArray()
            if ($timedOut -or !$drained) {
                return [PSCustomObject]@{ Code=124; Output=$output; Error=($errorText + "`nWSL helper timed out. Check WSL with the host owner before retrying.") }
            }
            return [PSCustomObject]@{ Code=$process.ExitCode; Output=$output; Error=$errorText }
        }
        # Only the actual session inherits stdin and waits without a timeout.
        $process.WaitForExit()
        return $process.ExitCode
    } finally { $process.Dispose(); $outBuffer.Dispose(); $errBuffer.Dispose() }
}

function Find-WslExecutable {
    $command = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    # WOW64 redirects System32 for 32-bit PowerShell; Sysnative bypasses it.
    if ($env:windir) {
        $sysnative = Join-Path $env:windir 'Sysnative/wsl.exe'
        if (Test-Path -LiteralPath $sysnative -PathType Leaf) { return $sysnative }
    }
    throw 'WSL is unavailable (wsl.exe missing). Ask the host owner to prepare WSL2 and a Linux distro first, then retry. The launcher installs nothing.'
}

function ConvertFrom-WslList([string]$Text) {
    # The byte decoder removes a BOM; tolerate one in other callers too.
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

function Assert-Wsl2Distro([string[]]$Names, [string]$VerboseList, [string]$Distro) {
    foreach ($line in (ConvertFrom-WslList $VerboseList)) {
        foreach ($name in ($Names | Sort-Object Length -Descending)) {
            if ($line -match ('^\*?\s*' + [regex]::Escape($name) + '\s+.+\s+([12])\s*$')) {
                if ($name -eq $Distro) {
                    if ($Matches[1] -ne '2') { throw "Distro '$Distro' uses WSL1. Select an existing WSL2 distro with PORTABLE_AI_WSL_DISTRO or ask the host owner to prepare one. The launcher does not convert distros." }
                    return
                }
                break
            }
        }
    }
    throw "Cannot determine the WSL version of '$Distro'. Check wsl.exe -l -v with the host owner."
}

function ConvertTo-WslPath($Executable, $Distro, [string]$WindowsPath) {
    # --exec bypasses the distro shell: paths/args are data, never shell code.
    $translated = Invoke-WslProcess $Executable @('-d', $Distro, '--exec', 'wslpath', '-a', $WindowsPath) -Capture
    $path = $translated.Output.TrimEnd("`r", "`n")
    if ($translated.Code -ne 0 -or !$path.StartsWith('/') -or $path.Contains("`n") -or $path.Contains("`r")) {
        throw "Cannot translate '$WindowsPath' in WSL distro '$Distro'. Ensure the drive/project is accessible there and wslpath is available.`n$(Format-WslFailure $translated)"
    }
    return $path
}

function Invoke-DriveWsl($LauncherDirectory, [string[]]$CliArgs) {
    $executable = Find-WslExecutable
    Write-Host 'Starting WSL... Checking installed distros (up to 60 seconds per helper call).'
    $listing = Invoke-WslProcess $executable @('-l', '-q') -Capture -List
    if ($listing.Code -ne 0) { throw "Cannot list WSL distros. Ask the host owner to check WSL2 and an installed distro with wsl.exe -l -v. The launcher installs nothing.`n$(Format-WslFailure $listing)" }
    $names = @(ConvertFrom-WslList $listing.Output)
    if (!$names.Count) { throw "No WSL distro is installed. Ask the host owner to prepare a WSL2 distro first. The launcher installs nothing.`n$(Format-WslFailure $listing)" }
    $verbose = Invoke-WslProcess $executable @('-l', '-v') -Capture -List
    if ($verbose.Code -ne 0) { throw "Cannot inspect WSL distros. Check wsl.exe -l -v with the host owner.`n$(Format-WslFailure $verbose)" }
    $distro = Select-WslDistro $names $verbose.Output $env:PORTABLE_AI_WSL_DISTRO
    Assert-Wsl2Distro $names $verbose.Output $distro
    $linux = Join-Path $LauncherDirectory 'linux.sh'
    if (!(Test-Path -LiteralPath $linux -PathType Leaf)) { throw "Missing Linux launcher: $linux. Restore AI-SHARED/launch from the provisioned drive." }
    Write-Host "Starting WSL distro '$distro'..."
    $linuxPath = ConvertTo-WslPath $executable $distro $linux
    $workingDirectory = ConvertTo-WslPath $executable $distro (Get-Location).ProviderPath
    $reachable = Invoke-WslProcess $executable @('-d', $distro, '--exec', 'test', '-f', $linuxPath) -Capture
    if ($reachable.Code -ne 0) {
        throw "Linux launcher is not reachable in '$distro': $linuxPath. Attach the drive before starting WSL, or ask the host owner to mount it with drvfs. With the host owner's agreement, wsl --shutdown then retry can refresh drive visibility; this stops ALL running distros and their work.`n$(Format-WslFailure $reachable)"
    }
    # An absent argument list must not become a single empty argument; preserve
    # deliberately supplied empty strings and all other caller arguments.
    $forwarded = @($CliArgs | Where-Object { $null -ne $_ })
    # Inherit console handles for menus, login prompts and Ctrl+C; never capture.
    return Invoke-WslProcess $executable (@('-d', $distro, '--cd', $workingDirectory, '--exec', 'bash', $linuxPath) + $forwarded)
}
