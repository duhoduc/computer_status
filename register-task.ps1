# (Re)create the scheduled task "PlaywrightServer" so the server starts when you log in.
# No admin rights needed. Usage:
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\register-task.ps1

$Base = $PSScriptRoot
$User = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Base\start-server.ps1`"" `
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

& (Join-Path $Base 'restart-server.ps1')
