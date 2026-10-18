# OPTIONAL - run from an elevated (Administrator) PowerShell.
# Replaces the logon task with one that runs as SYSTEM at boot, so the server
# comes up after a reboot even if nobody logs in.
# NOTE: in this mode Chrome runs in a hidden service session - HEADLESS = false
# will NOT show a window on your desktop. Use register-browser.ps1 if you need that.

$Base = Split-Path $PSScriptRoot   # repo root
function Pick($f) {  # machine-specific variant: name_<COMPUTERNAME>.ext wins over name.ext
  $i = Get-Item $f; $c = Join-Path $i.DirectoryName ($i.BaseName + '_' + $env:COMPUTERNAME.ToUpper() + $i.Extension)
  if (Test-Path $c) { $c } else { $f } }
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Pick "$Base\browser\start-server.ps1")`"" `
    -WorkingDirectory $Base
# Start at boot, plus a watchdog every 5 minutes that restarts the task if it stopped
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$trigger = @((New-ScheduledTaskTrigger -AtStartup), $watchdog)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 4

Register-ScheduledTask -TaskName 'PlaywrightServer' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'house_browser: Playwright 1.63.0 remote Chrome server over Tailscale' | Out-Null
Write-Host "Scheduled task 'PlaywrightServer' registered (runs as SYSTEM at boot)."

& (Join-Path $Base 'browser\restart-server.ps1')
