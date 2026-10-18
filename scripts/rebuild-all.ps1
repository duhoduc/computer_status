# Rebuild/restart EVERY service of this project so all of them run the current code.
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\scripts\rebuild-all.ps1 [-SkipBrowser]
# -SkipBrowser leaves the remote browser service running (use it when browser/ did not change).
#
# RULE: when you add a new service, add its (re)build/restart command to $steps below.
param([switch]$SkipBrowser)

$Base = Split-Path $PSScriptRoot   # repo root
Set-Location $Base

$steps = @(
    @{ name = 'app (Docker dashboard :8765)';   skip = $false;         run = { docker compose up -d --build } },
    @{ name = 'browser service (server.js)';    skip = $SkipBrowser;   run = { & (Join-Path $Base 'scripts\register-browser.ps1') } },  # (re)registers the task + restarts
    @{ name = 'local jobs (agent/local.js: collector, cleaner, keep_bottom, rebuild agent)'; skip = $false; run = { & (Join-Path $Base 'scripts\register-local.ps1') } },
    @{ name = 'push agent (agent/push_status.ps1)'; skip = $false;     run = { & (Join-Path $Base 'scripts\register-push.ps1') } }
    # @{ name = '<new service>'; skip = $false; run = { & (Join-Path $Base 'scripts\register-<new>.ps1') } }
)

$failed = @()
foreach ($s in $steps) {
    if ($s.skip) { Write-Host "-- skipped: $($s.name)" -ForegroundColor DarkGray; continue }
    Write-Host "== $($s.name)" -ForegroundColor Cyan
    try { & $s.run; if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "exit code $LASTEXITCODE" } }
    catch { Write-Host "   FAILED: $_" -ForegroundColor Red; $failed += $s.name }
    $global:LASTEXITCODE = 0
}
if ($failed.Count) { Write-Host "Failed: $($failed -join '; ')" -ForegroundColor Red; exit 1 }
Write-Host 'All services rebuilt.' -ForegroundColor Green
