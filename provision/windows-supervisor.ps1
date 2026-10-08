param([Parameter(Mandatory=$true)][string]$Native)
$ErrorActionPreference = 'Stop'
$tools = Join-Path $Native 'tools'
[IO.Directory]::CreateDirectory($tools) | Out-Null
Add-Type -Path (Join-Path $PSScriptRoot '..\launch\lib\DriveChild.cs') -OutputAssembly (Join-Path $tools 'DriveChild.dll') -OutputType Library
Write-Host 'Windows process supervisor prepared.'
