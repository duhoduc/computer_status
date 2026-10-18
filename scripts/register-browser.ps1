# (Re)create the scheduled task "PlaywrightServer" so the server starts when you log in.
# No admin rights needed. Usage:
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\scripts\register-browser.ps1

$Base = Split-Path $PSScriptRoot   # repo root
$User = "$env:USERDOMAIN\$env:USERNAME"

function Pick($f) {  # machine-specific variant: name_<COMPUTERNAME>.ext wins over name.ext
  $i = Get-Item $f; $c = Join-Path $i.DirectoryName ($i.BaseName + '_' + $env:COMPUTERNAME.ToUpper() + $i.Extension)
  if (Test-Path $c) { $c } else { $f } }
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Pick "$Base\browser\start-server.ps1")`"" `
    -WorkingDirectory $Base
# Start at logon, plus a watchdog every 5 minutes that restarts the task if it stopped
# (MultipleInstances IgnoreNew makes the watchdog a no-op while the server is running).
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$trigger = @((New-ScheduledTaskTrigger -AtLogOn -User $User), $watchdog)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 4

Register-ScheduledTask -TaskName 'PlaywrightServer' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'house_browser: Playwright 1.63.0 remote Chrome server over Tailscale' | Out-Null
Write-Host "Scheduled task 'PlaywrightServer' registered (runs at logon of $User)."

& (Join-Path $Base 'browser\restart-server.ps1')
