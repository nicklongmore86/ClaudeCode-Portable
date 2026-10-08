param(
    [ValidateSet('snapshot','diff')][string]$Action,
    [string]$Before,
    [string]$After
)
$ErrorActionPreference = 'Stop'

function ConvertTo-ExtendedPath([string]$Path) {
    if ($Path.StartsWith('\\?\')) { return $Path }
    $Path = [System.IO.Path]::GetFullPath($Path)
    if ($Path.StartsWith('\\.\')) { throw [NotSupportedException]::new('Device paths are not audit roots.') }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertTo-NormalPath([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Add-UnreadablePath([string]$Path) {
    [void]$script:unreadable.Add((ConvertTo-NormalPath $Path))
}

function Invoke-AuditPath([string]$Path, [scriptblock]$Read) {
    try {
        & $Read $Path
    } catch [ArgumentException], [NotSupportedException] {
        if (-not $Path.StartsWith('\\?\')) { throw }
        if (-not $script:warnedLegacyPaths) {
            Write-Warning 'Extended-length paths unsupported on this host; retrying normal paths. Long paths may be missed.'
            $script:warnedLegacyPaths = $true
        }
        & $Read (ConvertTo-NormalPath $Path)
    }
}

function Get-AuditChildren([string]$Path) {
    try {
        Invoke-AuditPath $Path {
            param($directoryPath)
            # Avoid the PowerShell 5.1 filesystem provider's MAX_PATH handling.
            ([System.IO.DirectoryInfo]::new($directoryPath)).GetFileSystemInfos()
        }
    } catch [System.IO.IOException], [UnauthorizedAccessException], [System.Security.SecurityException], [ArgumentException], [NotSupportedException] {
        # A failed directory read represents an unreadable subtree; its unseen
        # descendants cannot be counted individually.
        Add-UnreadablePath $Path
    }
}

function Get-AuditFileRow([System.IO.FileInfo]$File) {
    try {
        # Enumerated FileInfo objects already contain the metadata: no second stat.
        '{0}|{1}|{2}' -f (ConvertTo-NormalPath $File.FullName), $File.Length, $File.LastWriteTimeUtc.Ticks
    } catch [System.IO.IOException], [UnauthorizedAccessException], [System.Security.SecurityException], [ArgumentException], [NotSupportedException] {
        Add-UnreadablePath $File.FullName
    }
}

function Get-AuditRows([string]$Root) {
    try {
        $rootEntry = Invoke-AuditPath (ConvertTo-ExtendedPath $Root) {
            param($rootPath)
            if ([System.IO.File]::GetAttributes($rootPath) -band [System.IO.FileAttributes]::Directory) {
                [System.IO.DirectoryInfo]::new($rootPath)
            } else {
                [System.IO.FileInfo]::new($rootPath)
            }
        }
    } catch [System.IO.IOException], [UnauthorizedAccessException], [System.Security.SecurityException], [ArgumentException], [NotSupportedException] {
        Add-UnreadablePath $Root
        return
    }
    if ($rootEntry -is [System.IO.FileInfo]) {
        Get-AuditFileRow $rootEntry
        return
    }
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($rootEntry.FullName)
    while ($pending.Count -gt 0) {
        foreach ($entry in (Get-AuditChildren $pending.Pop())) {
            if ($entry -is [System.IO.DirectoryInfo]) {
                # Deliberately skip nested directory junctions/symlinks to avoid
                # cycles and leaving the roots. Windows PowerShell 5.1's
                # Get-ChildItem -Recurse can follow these; PowerShell 7 does not.
                if (-not ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $pending.Push($entry.FullName)
                }
            } else {
                Get-AuditFileRow $entry
            }
        }
    }
}

function Get-AuditProfileRoots {
    try {
        Get-AuditChildren (ConvertTo-ExtendedPath $env:USERPROFILE) |
            Where-Object { $_.Name.StartsWith('.') } | ForEach-Object { $_.FullName }
    } catch [System.IO.IOException], [UnauthorizedAccessException], [System.Security.SecurityException], [ArgumentException], [NotSupportedException] {
        Add-UnreadablePath $env:USERPROFILE
    }
}

if ($Action -eq 'snapshot' -and $Before) {
    $script:warnedLegacyPaths = $false
    $script:unreadable = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, "$env:SystemRoot\Temp")
    $roots += @(Get-AuditProfileRoots)
    $rows = foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        Get-AuditRows $root
    }
    $rows | Sort-Object -Unique | Set-Content -LiteralPath $Before -Encoding UTF8
    if ($script:unreadable.Count -gt 0) {
        Write-Warning ("Unreadable paths skipped: {0} (each failed directory read counts once, including its subtree)." -f $script:unreadable.Count)
    }
    Write-Host "Snapshot: $Before (unreadable paths skipped: $($script:unreadable.Count))"
} elseif ($Action -eq 'diff' -and $Before -and $After) {
    Compare-Object @(Get-Content -LiteralPath $Before) @(Get-Content -LiteralPath $After)
} else {
    throw 'Usage: audit.ps1 snapshot DRIVE-OUTPUT | diff BEFORE AFTER'
}
