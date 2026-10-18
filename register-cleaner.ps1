# (Re)create the scheduled task "ChromeCleaner": runs agent\start-cleaner.ps1 at logon,
# with a 5-minute watchdog. No admin rights needed. Usage:
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\register-cleaner.ps1

$Base = $PSScriptRoot
$User = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Base\agent\start-cleaner.ps1`"" `
    -WorkingDirectory $Base
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$trigger = @((New-ScheduledTaskTrigger -AtLogOn -User $User), $watchdog)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 4

Register-ScheduledTask -TaskName 'ChromeCleaner' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'computer_status: local chromium cleaner (separate from the remote browser server)' | Out-Null
Write-Host "Scheduled task 'ChromeCleaner' registered (runs at logon of $User)."
Start-ScheduledTask -TaskName 'ChromeCleaner'
