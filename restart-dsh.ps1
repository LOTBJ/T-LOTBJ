# Restart DeepSeek Harness (delayed restart, for agent-initiated restarts):
# waits 25s so the current conversation can finish, kills whatever listens on
# 3080 (kills by port, so stale PIDs can never bite again), then delegates the
# start to launch-dsh.ps1 (hidden window, logs, safe-mode auto-retry, browser).
$ErrorActionPreference = 'SilentlyContinue'

Start-Sleep -Seconds 25  # let the current agent turn finish first

$conn = Get-NetTCPConnection -LocalPort 3080 -State Listen | Select-Object -First 1
if ($conn) {
    Stop-Process -Id $conn.OwningProcess -Force
    Start-Sleep -Seconds 3
}

& (Join-Path $PSScriptRoot 'launch-dsh.ps1')
