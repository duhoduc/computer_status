# (Re)create the scheduled task "ComputerStatusLocal": runs agent\start-local.ps1 (keeps local.js running) at logon,
# with a 5-minute watchdog. No admin rights needed. Usage:
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\scripts\register-local.ps1

$Base = Split-Path $PSScriptRoot   # repo root
$User = "$env:USERDOMAIN\$env:USERNAME"

New-Item -ItemType Directory -Force (Join-Path $Base 'logs') | Out-Null
function Pick($f) {  # machine-specific variant: name_<COMPUTERNAME>.ext wins over name.ext
  $i = Get-Item $f; $c = Join-Path $i.DirectoryName ($i.BaseName + '_' + $env:COMPUTERNAME.ToUpper() + $i.Extension)
  if (Test-Path $c) { $c } else { $f } }
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Pick "$Base\agent\start-local.ps1")`"" `
    -WorkingDirectory $Base
$watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$trigger = @((New-ScheduledTaskTrigger -AtLogOn -User $User), $watchdog)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 4

Register-ScheduledTask -TaskName 'ComputerStatusLocal' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'computer_status: local jobs (live metrics collector + chromium cleaner)' | Out-Null
Write-Host "Scheduled task 'ComputerStatusLocal' registered (runs at logon of $User)."
# Stop the previous instance (and its collector) so the new code actually runs
Stop-ScheduledTask -TaskName 'ComputerStatusLocal' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process |
    Where-Object { ($_.CommandLine -like '*agent\local.js*' -or $_.CommandLine -like '*live_collector.ps1*') -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName 'ComputerStatusLocal'
