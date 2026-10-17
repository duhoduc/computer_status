# Launcher run by the scheduled task "PlaywrightServer".
# Runs server.js and restarts it whenever it exits. Output goes to server.log.

$Base = $PSScriptRoot
$Log  = Join-Path $Base 'server.log'
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
    & (Join-Path $Base 'node\node.exe') (Join-Path $Base 'server.js') *>> $Log
    Write-Log "server.js exited with code $LASTEXITCODE; restarting in 5s"
    Start-Sleep -Seconds 5
}
