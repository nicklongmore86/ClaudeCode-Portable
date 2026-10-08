param(
    [ValidateSet('snapshot','diff')][string]$Action,
    [string]$Before,
    [string]$After
)
$ErrorActionPreference = 'Stop'
if ($Action -eq 'snapshot' -and $Before) {
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, "$env:SystemRoot\Temp")
    $roots += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith('.') } | ForEach-Object { $_.FullName })
    $rows = foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
    }
    $rows | Sort-Object -Unique | Set-Content -LiteralPath $Before -Encoding UTF8
    Write-Host "Snapshot: $Before (unreadable paths skipped)"
} elseif ($Action -eq 'diff' -and $Before -and $After) {
    Compare-Object @(Get-Content -LiteralPath $Before) @(Get-Content -LiteralPath $After)
} else {
    throw 'Usage: audit.ps1 snapshot DRIVE-OUTPUT | diff BEFORE AFTER'
}
