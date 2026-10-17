# (Re)create the scheduled task "ComputerStatusPush": runs agent\push_status.ps1 at logon and every minute.
# No admin rights needed. Usage:
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\register-push.ps1

$Base = $PSScriptRoot
$User = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Base\agent\push_status.ps1`"" `
    -WorkingDirectory $Base
$every = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
$trigger = @((New-ScheduledTaskTrigger -AtLogOn -User $User), $every)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'ComputerStatusPush' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'computer_status: posts Windows status to http://localhost:8765/api/status' | Out-Null
Write-Host "Scheduled task 'ComputerStatusPush' registered (runs at logon of $User and every minute)."
Start-ScheduledTask -TaskName 'ComputerStatusPush'
