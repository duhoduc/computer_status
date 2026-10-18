# Restart the Playwright server, e.g. after changing HEADLESS in server.js.
# Usage:  powershell -ExecutionPolicy Bypass -File C:\computer_status\restart-server.ps1

$Base = $PSScriptRoot

Stop-ScheduledTask -TaskName 'PlaywrightServer' -ErrorAction SilentlyContinue

# Stop any leftover launcher / node / Chrome processes started from this folder
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like "*$Base*" -and $_.CommandLine -notlike '*live_collector*' -and $_.CommandLine -notlike '*chrome_cleaner*' -and $_.CommandLine -notlike '*start-local*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

Start-ScheduledTask -TaskName 'PlaywrightServer'

# Wait up to 30s for the server to report ready
$log = Join-Path $Base 'server.log'
$deadline = (Get-Date).AddSeconds(30)
$startLines = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
while ((Get-Date) -lt $deadline) {
    $new = if (Test-Path $log) { Get-Content $log | Select-Object -Skip $startLines } else { @() }
    $ready = $new | Where-Object { $_ -match 'Chrome ready' } | Select-Object -Last 1
    if ($ready) { Write-Host $ready; exit 0 }
    Start-Sleep -Milliseconds 500
}
Write-Host "Server did not report ready within 30s. Check $log"
exit 1
