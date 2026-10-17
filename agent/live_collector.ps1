# Live Task-Manager-style collector: samples every ~1s and POSTs to the container (/api/live).
param([string]$Url = "http://localhost:8765/api/live")

$os = Get-CimInstance Win32_OperatingSystem
$cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
$totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB)
$maxMHz = $cpuInfo.MaxClockSpeed
$nvidia = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)

# Power model (ESTIMATE): linear between idle and full-load package power for the CPU,
# plus a flat allowance for board/RAM/SSD/fans. GPU power is measured (nvidia-smi).
$settingsFile = Join-Path $PSScriptRoot "..\general_computer_settings.json"
$cpuIdleW = 25; $cpuMaxW = 120; $otherW = 40   # fallbacks; overridden by general_computer_settings.json
$loop = 0

$counters = @(
  '\Processor Information(*)\% Processor Utility',
  '\Processor Information(_Total)\% Processor Performance',
  '\Memory\Available Bytes', '\Memory\Committed Bytes', '\Memory\Cache Bytes',
  '\PhysicalDisk(_Total)\% Disk Time',
  '\PhysicalDisk(_Total)\Disk Read Bytes/sec', '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
  '\Network Interface(*)\Bytes Received/sec', '\Network Interface(*)\Bytes Sent/sec',
  '\System\Processes', '\System\Threads'
)

function Get-Gpu {
  if (-not $nvidia) { return $null }
  $q = "name,utilization.gpu,utilization.memory,temperature.gpu,power.draw,memory.used,memory.total,clocks.gr,fan.speed"
  $l = (nvidia-smi --query-gpu=$q --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
  if (-not $l) { return $null }
  $p = $l -split ',\s*'
  $n = { param($s) $d = 0.0; if ([double]::TryParse($s, [ref]$d)) { $d } else { $null } }
  @{ name = $p[0]; util_percent = (& $n $p[1]); mem_util_percent = (& $n $p[2]); temp_c = (& $n $p[3])
     power_w = (& $n $p[4]); vram_used_mb = (& $n $p[5]); vram_total_mb = (& $n $p[6])
     clock_mhz = (& $n $p[7]); fan_percent = (& $n $p[8]) }
}

function Get-CpuTemp {
  # Needs LibreHardwareMonitor (or OpenHardwareMonitor) running with "Remote Web Server" on :8085.
  try {
    $j = Invoke-RestMethod "http://localhost:8085/data.json" -TimeoutSec 1
    $found = @()
    $walk = { param($n) if ($n.Value -match '^([\d.,]+) °C' -and $n.Text -match 'Core \(Tctl|Package|CPU|Tdie|Tctl') { $found += [double]($Matches[1] -replace ',', '.') }
              foreach ($c in $n.Children) { & $walk $c } }
    & $walk $j
    if ($found.Count) { return ($found | Measure-Object -Maximum).Maximum }
  } catch {}
  return $null
}

while ($true) {
  try {
    if ($loop++ % 10 -eq 0) {  # re-read settings every ~10s so edits from the web UI apply
      try { $pm = (Get-Content $settingsFile -Raw | ConvertFrom-Json).power_model
            $cpuIdleW = $pm.cpu_idle_w; $cpuMaxW = $pm.cpu_max_w; $otherW = $pm.other_w } catch {}
    }
    $s = (Get-Counter -Counter $counters -ErrorAction SilentlyContinue).CounterSamples
    $val = { param($pat) ($s | Where-Object { $_.Path -like $pat } | Select-Object -First 1).CookedValue }
    $sum = { param($pat) ($s | Where-Object { $_.Path -like $pat -and $_.Path -notlike '*_total*' -and $_.Path -notlike '*isatap*' -and $_.Path -notlike '*loopback*' } | Measure-Object CookedValue -Sum).Sum }

    $cpuTotal = [math]::Min(100, (& $val '*processor information(_total)*% processor utility'))
    $perf = & $val '*processor information(_total)*% processor performance'
    $cores = @($s | Where-Object { $_.Path -like '*processor information(*% processor utility' -and $_.InstanceName -notlike '*_total*' } |
               Sort-Object InstanceName | ForEach-Object { [math]::Round([math]::Min(100, $_.CookedValue), 1) })
    $avail = (& $val '*memory\available bytes') / 1MB
    $used = $totalMemMB - $avail
    $gpu = Get-Gpu
    $cpuW = $cpuIdleW + ($cpuMaxW - $cpuIdleW) * ($cpuTotal / 100)
    $gpuW = if ($gpu -and $gpu.power_w) { $gpu.power_w } else { 0 }

    $body = @{
      source = "windows_live"; hostname = $env:COMPUTERNAME
      cpu = @{ name = $cpuInfo.Name; util_percent = [math]::Round($cpuTotal, 1)
               speed_ghz = [math]::Round($maxMHz * $perf / 100 / 1000, 2)
               temp_c = (Get-CpuTemp); per_core_percent = $cores
               processes = [int](& $val '*system\processes'); threads = [int](& $val '*system\threads') }
      memory = @{ total_mb = $totalMemMB; used_mb = [math]::Round($used); percent = [math]::Round(100 * $used / $totalMemMB, 1)
                  committed_mb = [math]::Round((& $val '*memory\committed bytes') / 1MB)
                  cached_mb = [math]::Round((& $val '*memory\cache bytes') / 1MB) }
      gpu = $gpu
      disk = @{ active_percent = [math]::Round([math]::Min(100, (& $val '*physicaldisk(_total)*% disk time')), 1)
                read_mbps = [math]::Round((& $val '*physicaldisk(_total)*disk read bytes/sec') / 1MB, 2)
                write_mbps = [math]::Round((& $val '*physicaldisk(_total)*disk write bytes/sec') / 1MB, 2) }
      network = @{ recv_mbps = [math]::Round((& $sum '*network interface(*bytes received/sec') * 8 / 1e6, 2)
                   sent_mbps = [math]::Round((& $sum '*network interface(*bytes sent/sec') * 8 / 1e6, 2) }
      power = @{ cpu_w_est = [math]::Round($cpuW, 1); gpu_w = [math]::Round($gpuW, 1); other_w_est = $otherW
                 total_w_est = [math]::Round($cpuW + $gpuW + $otherW, 1)
                 note = "CPU and other are modelled estimates; GPU is measured by nvidia-smi" }
    } | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3 | Out-Null
  } catch { Start-Sleep -Seconds 2 }
}
