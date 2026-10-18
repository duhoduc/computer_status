# Needs admin (right-click > Run as administrator). Lets machines on your Tailscale network (100.64.0.0/10)
# reach the dashboard (8765) and the rebuild agent (8766). Nothing else is opened, and not the whole LAN.
#   powershell -ExecutionPolicy Bypass -File C:\computer_status\scripts\allow-tailscale-admin.ps1
$tailnet = '100.64.0.0/10'
foreach ($r in @(@{ n = 'computer_status dashboard (Tailscale)'; p = 8765 }, @{ n = 'computer_status rebuild agent (Tailscale)'; p = 8766 })) {
    Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Action Allow -Protocol TCP -LocalPort $r.p -RemoteAddress $tailnet -Profile Any | Out-Null
    Write-Host "allowed TCP $($r.p) from $tailnet"
}
$ip = & 'C:\Program Files\Tailscale\tailscale.exe' ip -4 | Select-Object -First 1
Write-Host "Remote URL: http://${ip}:8765  (or http://$($env:COMPUTERNAME.ToLower()):8765 with MagicDNS)"
