# DeepSeek Harness desktop launcher
# Opens the DSH web GUI (http://127.0.0.1:3080) in the default browser.
# If the server is not running, starts it first (hidden, with logs) and waits
# until it responds before opening the browser.

$ErrorActionPreference = 'Stop'

$Url   = 'http://127.0.0.1:3080'
$OutLog = Join-Path $PSScriptRoot 'dsh-web.out.log'
$ErrLog = Join-Path $PSScriptRoot 'dsh-web.err.log'

$NodeExe = 'C:\Program Files\nodejs\node.exe'
$DshBin  = Join-Path $env:USERPROFILE 'AppData\Local\npm-cache\_npx\1e7f6d9597241db0\node_modules\@deepseek-ai\dsh\lib\bin.js'
# 开源适配: 默认路径不存在时探测本机安装
if (-not (Test-Path -LiteralPath $DshBin)) {
    $cmd = (Get-Command dsh -ErrorAction SilentlyContinue).Source
    if ($cmd) {
        if ($cmd -match '\.cmd$') {
            $cand = Join-Path (Split-Path -Parent $cmd) 'node_modules\@deepseek-ai\dsh\lib\bin.js'
            if (Test-Path -LiteralPath $cand) { $DshBin = $cand } else { $DshBin = $cmd }
        } else { $DshBin = $cmd }
    }
}

function Test-Server {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return ($null -ne $r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch {
        return $false
    }
}

function Show-Message([string]$Text, [string]$Title = 'DeepSeek Harness') {
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Information') | Out-Null
    } catch { }
}

function Write-Log([string]$Message) {
    try { Add-Content -Path $ErrLog -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) } catch { }
}

$up = Test-Server

if (-not $up) {
    if (-not (Test-Path -LiteralPath $NodeExe)) { $NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not (Test-Path -LiteralPath $DshBin))  { $DshBin  = (Get-Command dsh  -ErrorAction SilentlyContinue).Source }

    if (Test-Path -LiteralPath $DshBin) {
        $started = $false
        try {
            $proc = Start-Process -FilePath $NodeExe `
                                   -ArgumentList @($DshBin, 'web') `
                                   -WorkingDirectory $PSScriptRoot `
                                   -WindowStyle Hidden `
                                   -RedirectStandardOutput $OutLog `
                                   -RedirectStandardError $ErrLog `
                                   -PassThru
            $started = $true
            Write-Log "server starting (pid $($proc.Id)): $NodeExe $DshBin web"
        } catch {
            Write-Log "start failed: $($_.Exception.Message)"
        }

        for ($i = 0; $i -lt 60 -and -not $up; $i++) {
            Start-Sleep -Milliseconds 1000
            $up = Test-Server
            if ($started -and $proc.HasExited) {
                Write-Log "server exited early (code $($proc.ExitCode)); see $OutLog"
                # Firewall: retry once in safe mode (user patch layers disabled),
                # so a broken cordis.patch.yml can never lock the harness out.
                if (-not $env:DSH_SAFE_MODE) {
                    Write-Log 'retrying once in safe mode (user patch layers disabled)'
                    $env:DSH_SAFE_MODE = '1'
                    $proc = Start-Process -FilePath $NodeExe `
                                           -ArgumentList @($DshBin, 'web') `
                                           -WorkingDirectory $PSScriptRoot `
                                           -WindowStyle Hidden `
                                           -RedirectStandardOutput $OutLog `
                                           -RedirectStandardError $ErrLog `
                                           -PassThru
                    $started = $true
                    Remove-Item Env:DSH_SAFE_MODE -ErrorAction SilentlyContinue
                    Write-Log "safe-mode retry started (pid $($proc.Id)); the broken user layer was snapshotted under `$env:USERPROFILE\.dsh\backups"
                    continue
                }
                break
            }
        }
    } else {
        Write-Log 'dsh binary not found'
    }
}

if ($up) {
    Start-Process $Url
} else {
    Show-Message "DeepSeek Harness 启动失败，请查看日志：$ErrLog" 'DeepSeek Harness 启动失败'
}
