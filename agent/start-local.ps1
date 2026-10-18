# Runs agent\local.js forever. local.js exits on purpose after a dashboard "Rebuild" that changed local code,
# and this loop starts it again with the new code. Output goes to logs\local_jobs.log.
$Base = Split-Path $PSScriptRoot   # repo root
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
function Pick($f) {  # machine-specific variant: name_<COMPUTERNAME>.ext wins over name.ext
  $i = Get-Item $f; $c = Join-Path $i.DirectoryName ($i.BaseName + '_' + $env:COMPUTERNAME.ToUpper() + $i.Extension)
  if (Test-Path $c) { $c } else { $f } }
New-Item -ItemType Directory -Force (Join-Path $Base 'logs') | Out-Null
$Log = Join-Path $Base 'logs\local_jobs.log'
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 5MB) { Move-Item $Log "$Log.old" -Force }
$Node = Join-Path $Base 'node\node.exe'   # portable Node if present, else the system one
if (-not (Test-Path $Node)) { $Node = (Get-Command node).Source }
Set-Location $Base
while ($true) {
  # children of a previous local.js can outlive it; clear them so there is never a duplicate collector
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'live_collector|keep_bottom' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  & $Node (Pick (Join-Path $PSScriptRoot 'local.js')) *>> $Log
  Start-Sleep -Seconds 2
}
