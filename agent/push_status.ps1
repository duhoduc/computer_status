# Collects Windows host status and pushes it to the computer-status container.
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
$bat  = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  @{ drive=$_.DeviceID; total_gb=[math]::Round($_.Size/1GB,1); free_gb=[math]::Round($_.FreeSpace/1GB,1) } }
$top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
  @{ name=$_.ProcessName; mem_mb=[math]::Round($_.WorkingSet64/1MB) } }
$body = @{
  source          = "windows"
  hostname        = $env:COMPUTERNAME
  os              = $os.Caption
  cpu_percent     = $cpu
  mem_total_mb    = [math]::Round($os.TotalVisibleMemorySize/1KB)
  mem_used_mb     = [math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1KB)
  uptime_s        = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  battery_percent = if ($bat) { $bat.EstimatedChargeRemaining } else { $null }
  disks           = @($disks)
  top_processes   = @($top)
} | ConvertTo-Json -Depth 4
Invoke-RestMethod -Uri "http://localhost:8765/api/status" -Method Post -Body $body -ContentType "application/json" | Out-Null
