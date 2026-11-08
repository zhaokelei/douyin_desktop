# 内存剖面：隔离场景分别启动 Release，按时间点采样工作集/私有字节/峰值。
# 场景：
#   1) 冷启动空闲（首页不播放）           t=8s
#   2) 播放稳定（1080P，自动播放）        t=35s
#   3) 连续切换 50 条（每秒切一条）        t=60s / t=95s（看是否持续增长）
#   4) 打开评论抽屉 + 详情                 t=35s
# 用法：pwsh -NoProfile -ExecutionPolicy Bypass -File tool\mem_probe.ps1

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Exe = Join-Path $Root 'build\windows\x64\runner\Release\douyin_desktop.exe'
$LogDir = Join-Path $Root '_shots'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$env:DOUYIN_MUTE = '1'
$env:DOUYIN_NO_VERIFY_UI = '1'

function Sample([System.Diagnostics.Process]$p, [string]$label) {
    $p.Refresh()
    $ws = [math]::Round($p.WorkingSet64 / 1MB, 1)
    $pv = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
    $pk = [math]::Round($p.PeakWorkingSet64 / 1MB, 1)
    Write-Host ("{0,-24} 工作集={1,7}MB  私有={2,7}MB  工作集峰值={3,7}MB" -f $label, $ws, $pv, $pk)
    return [pscustomobject]@{ Phase = $label; WorkingSetMB = $ws; PrivateMB = $pv; PeakMB = $pk }
}

function Launch([string]$logName) {
    $env:DOUYIN_LOG = Join-Path $LogDir $logName
    # 离屏模式：窗口移到屏幕外、不进任务栏、不抢焦点；截图延时设成远大于采样
    # 窗口，进程由脚本自己结束，不会弹窗打扰。
    $env:DOUYIN_SHOT = Join-Path $LogDir ($logName -replace '\.log$', '.png')
    $env:DOUYIN_SHOT_DELAY = '600'
    return Start-Process -FilePath $Exe -PassThru
}

function Stop-App([System.Diagnostics.Process]$p) {
    if (-not $p.HasExited) {
        $p.CloseMainWindow() | Out-Null
        Start-Sleep -Seconds 2
        if (-not $p.HasExited) { $p | Stop-Process -Force }
    }
}

$rows = @()

# ---------- 1) 冷启动空闲 ----------
$env:DOUYIN_AUTOPLAY = ''
$env:DOUYIN_SWITCH_EVERY = ''
$env:DOUYIN_OPEN_COMMENTS = ''
$p = Launch 'mem_idle.log'
Start-Sleep -Seconds 8
$rows += Sample $p '冷启动空闲(首页)'
Stop-App $p

# ---------- 2) 播放稳定 30 秒 ----------
$env:DOUYIN_AUTOPLAY = '1'
$p = Launch 'mem_play.log'
Start-Sleep -Seconds 14
$rows += Sample $p '播放首帧后(14s)'
Start-Sleep -Seconds 22
$rows += Sample $p '播放稳定(36s)'
Stop-App $p

# ---------- 3) 连续切换 50 条 ----------
$env:DOUYIN_SWITCH_EVERY = '1'
$p = Launch 'mem_switch.log'
Start-Sleep -Seconds 15
$rows += Sample $p '进播放页(15s)'
Start-Sleep -Seconds 50
$rows += Sample $p '切换~50条(65s)'
Start-Sleep -Seconds 32
$rows += Sample $p '再等32s(97s)'
Stop-App $p

# ---------- 4) 打开评论抽屉 ----------
$env:DOUYIN_SWITCH_EVERY = ''
$env:DOUYIN_OPEN_COMMENTS = '1'
$p = Launch 'mem_comments.log'
Start-Sleep -Seconds 30
$rows += Sample $p '评论抽屉打开(30s)'
Stop-App $p

$env:DOUYIN_AUTOPLAY = ''
$env:DOUYIN_OPEN_COMMENTS = ''
$env:DOUYIN_SHOT = ''
Write-Host ''
Write-Host '=== 汇总 ==='
$rows | Format-Table -AutoSize
$out = Join-Path $LogDir 'mem_summary.csv'
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 $out
Write-Host "CSV: $out"
