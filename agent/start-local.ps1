# Local-machine jobs in one supervised service: live metrics collector + chromium cleaner.
# (The remote browser server is separate on purpose: start-server.ps1 / server.js.)
$Base = Split-Path $PSScriptRoot
$Node = Join-Path $Base 'node\node.exe'
if (-not (Test-Path $Node)) { $Node = (Get-Command node -ErrorAction SilentlyContinue).Source }
$Log = Join-Path $Base 'local_jobs.log'
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 5MB) { Move-Item $Log "$Log.old" -Force }
Set-Location $Base

$jobs = @(
  @{ name = 'collector'; exe = 'powershell.exe'; args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\live_collector.ps1`"" },
  @{ name = 'cleaner';   exe = $Node;            args = "`"$PSScriptRoot\chrome_cleaner.js`"" }
)
function Start-Job2($j) {
  $j.proc = Start-Process -FilePath $j.exe -ArgumentList $j.args -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $Base "local_$($j.name).log") -RedirectStandardError (Join-Path $Base "local_$($j.name).err.log")
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  started $($j.name) pid $($j.proc.Id)" | Out-File $Log -Append -Encoding utf8
}
foreach ($j in $jobs) { Start-Job2 $j }
while ($true) {   # restart whichever job dies; each is independent of the other
  Start-Sleep -Seconds 5
  foreach ($j in $jobs) { if ($j.proc.HasExited) { Start-Sleep 2; Start-Job2 $j } }
}
