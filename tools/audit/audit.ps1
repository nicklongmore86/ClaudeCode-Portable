param(
    [ValidateSet('snapshot','diff')][string]$Action,
    [string]$Before,
    [string]$After
)
$ErrorActionPreference = 'Stop'

function ConvertTo-ExtendedPath([string]$Path) {
    if ($Path.StartsWith('\\?\')) { return $Path }
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

function Get-AuditChildren([string]$Path) {
    try {
        # Avoid the PowerShell 5.1 filesystem provider's MAX_PATH handling.
        # Keep the extended prefix throughout traversal, including metadata reads.
        $directory = [System.IO.DirectoryInfo]::new($Path)
        $directory.GetFileSystemInfos()
    } catch {
        # A failed directory read represents an unreadable subtree; its unseen
        # descendants cannot be counted individually.
        Add-UnreadablePath $Path
    }
}

function Get-AuditRows([string]$Root) {
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push((ConvertTo-ExtendedPath $Root))
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        try {
            $attributes = [System.IO.File]::GetAttributes($path)
            if ($attributes -band [System.IO.FileAttributes]::Directory) {
                foreach ($entry in (Get-AuditChildren $path)) {
                    # Like Get-ChildItem -Recurse, do not follow nested directory
                    # junctions/symlinks (cycles and paths outside the roots).
                    if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -and
                        ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                        continue
                    }
                    $pending.Push($entry.FullName)
                }
            } else {
                $file = [System.IO.FileInfo]::new($path)
                '{0}|{1}|{2}' -f (ConvertTo-NormalPath $path), $file.Length, $file.LastWriteTimeUtc.Ticks
            }
        } catch {
            Add-UnreadablePath $path
        }
    }
}

if ($Action -eq 'snapshot' -and $Before) {
    $script:unreadable = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, "$env:SystemRoot\Temp")
    $roots += @(Get-AuditChildren (ConvertTo-ExtendedPath $env:USERPROFILE) |
        Where-Object { $_.Name.StartsWith('.') } | ForEach-Object { $_.FullName })
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
