# Compatibility entry; downloads happen only on the prep machine.
& (Join-Path $PSScriptRoot '..\launch\windows.ps1') @args
exit $LASTEXITCODE
