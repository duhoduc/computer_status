# Launcher run by the scheduled task "PlaywrightServer".
# Runs server.js and restarts it whenever it exits. Output goes to server.log.

$Base = Split-Path $PSScriptRoot   # repo root
New-Item -ItemType Directory -Force (Join-Path $Base 'logs') | Out-Null
$Log  = Join-Path $Base 'logs\server.log'
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'   # also applies to >> redirection

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File -FilePath $Log -Append
}

# Keep the log from growing without bound
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 10MB) {
    Move-Item $Log "$Log.old" -Force
}

# A stray Ctrl+C on this hidden console must not kill the restart loop
try { [Console]::TreatControlCAsInput = $true } catch {}

Set-Location $Base
while ($true) {
    Write-Log 'Starting server.js'
    $Node = Join-Path $Base 'node\node.exe'   # portable Node if present, else the system one
    if (-not (Test-Path $Node)) { $Node = (Get-Command node -ErrorAction SilentlyContinue).Source }
    & $Node (Join-Path $Base 'browser\server.js') *>> $Log
    Write-Log "server.js exited with code $LASTEXITCODE; restarting in 5s"
    Start-Sleep -Seconds 5
}
