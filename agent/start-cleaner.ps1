# Runs chrome_cleaner.js forever (restarts it if it exits), logging to chrome_cleaner.log.
$Base = Split-Path $PSScriptRoot
$Log = Join-Path $Base 'chrome_cleaner.log'
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 5MB) { Move-Item $Log "$Log.old" -Force }
$Node = Join-Path $Base 'node\node.exe'
if (-not (Test-Path $Node)) { $Node = (Get-Command node -ErrorAction SilentlyContinue).Source }
Set-Location $Base
while ($true) { & $Node (Join-Path $PSScriptRoot 'chrome_cleaner.js') *>> $Log; Start-Sleep -Seconds 5 }
