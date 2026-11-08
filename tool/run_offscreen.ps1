# 离屏自测启动器：复制 release 到独立目录、带入登录态 Cookie、
# 屏幕外启动（-3000,-3000，不激活、不进任务栏）、按需自截图后自动退出。
#
# 示例：
#   powershell -ExecutionPolicy Bypass -File tool\run_offscreen.ps1 `
#     -Name feed1 -Delay 12 -Shot screenshots\20_feed.png -LogFile build\logs\feed1.log
#
# 所有窗口都在屏幕外，不会弹出来打扰使用电脑的人。

param(
  [Parameter(Mandatory = $true)][string]$Name,
  [int]$Delay = 12,
  [string]$Shot = '',
  [string]$LogFile = '',
  [switch]$Autoplay,
  [switch]$OpenComments,
  [int]$SwitchEvery = 0,
  [switch]$Memlog,
  [switch]$Autoscroll,
  [switch]$ForceControls,
  [int]$KillAfter = 0,
  [string]$ApiBase = '',
  [int]$ToggleDrawer = 0,
  [int]$ScrollMs = 0,
  [switch]$NoAutoNext
)

$root = 'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03'
$proj = "$root\douyin_desktop"
$release = "$proj\build\windows\x64\runner\Release"
$runDir = "$proj\build\runs\$Name"

if (Test-Path $runDir) { Remove-Item $runDir -Recurse -Force }
Copy-Item $release $runDir -Recurse

# Cookie 不放进 Release 目录（避免被打包分发），只复制到本次运行目录。
$cookie = "$proj\douyin_cookies.json"
if (Test-Path $cookie) { Copy-Item $cookie "$runDir\douyin_cookies.json" }

New-Item -ItemType Directory -Force -Path "$proj\build\logs" | Out-Null
if ($LogFile -eq '') { $LogFile = "$proj\build\logs\$Name.log" }
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
$env:DOUYIN_LOG = $LogFile
if ($Shot -ne '') {
  $env:DOUYIN_SHOT = if ($Shot -match '^[A-Za-z]:') { $Shot } else { "$root\$Shot" }
  $env:DOUYIN_SHOT_DELAY = "$Delay"
} else {
  Remove-Item Env:DOUYIN_SHOT -ErrorAction SilentlyContinue
}
if ($Autoplay) { $env:DOUYIN_AUTOPLAY = '1' } else { Remove-Item Env:DOUYIN_AUTOPLAY -ErrorAction SilentlyContinue }
if ($OpenComments) { $env:DOUYIN_OPEN_COMMENTS = '1' } else { Remove-Item Env:DOUYIN_OPEN_COMMENTS -ErrorAction SilentlyContinue }
if ($SwitchEvery -gt 0) { $env:DOUYIN_SWITCH_EVERY = "$SwitchEvery" } else { Remove-Item Env:DOUYIN_SWITCH_EVERY -ErrorAction SilentlyContinue }
if ($Memlog) { $env:DOUYIN_MEMLOG = '1' } else { Remove-Item Env:DOUYIN_MEMLOG -ErrorAction SilentlyContinue }
if ($Autoscroll) { $env:DOUYIN_AUTOSCROLL = '1' } else { Remove-Item Env:DOUYIN_AUTOSCROLL -ErrorAction SilentlyContinue }
if ($ForceControls) { $env:DOUYIN_FORCE_CONTROLS = '1' } else { Remove-Item Env:DOUYIN_FORCE_CONTROLS -ErrorAction SilentlyContinue }
if ($ApiBase -ne '') { $env:DOUYIN_API_BASE = $ApiBase } else { Remove-Item Env:DOUYIN_API_BASE -ErrorAction SilentlyContinue }
if ($ToggleDrawer -gt 0) { $env:DOUYIN_TOGGLE_DRAWER = "$ToggleDrawer" } else { Remove-Item Env:DOUYIN_TOGGLE_DRAWER -ErrorAction SilentlyContinue }
if ($ScrollMs -gt 0) { $env:DOUYIN_SCROLL_MS = "$ScrollMs" } else { Remove-Item Env:DOUYIN_SCROLL_MS -ErrorAction SilentlyContinue }
if ($NoAutoNext) { $env:DOUYIN_NO_AUTONEXT = '1' } else { Remove-Item Env:DOUYIN_NO_AUTONEXT -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath "$runDir\douyin_desktop.exe" -PassThru
Write-Output "[run] $Name pid=$($p.Id) delay=$Delay shot=$Shot"

if ($Shot -ne '' -or $Delay -gt 0) {
  $p | Wait-Process -Timeout ($Delay + 25) -ErrorAction SilentlyContinue
}
if ($KillAfter -gt 0) {
  $deadline = (Get-Date).AddSeconds($KillAfter)
  while ((Get-Date) -lt $deadline -and -not $p.HasExited) {
    Start-Sleep -Seconds 2
  }
  if (-not $p.HasExited) {
    Write-Output "[run] 到达 KillAfter，结束进程 $($p.Id)"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}
$code = if ($p.HasExited) { $p.ExitCode } else { -1 }
Write-Output "[run] 退出码=$code 日志=$LogFile"
if (Test-Path $LogFile) {
  Write-Output "[run] 日志大小=$((Get-Item $LogFile).Length) 字节"
}
if ($Shot -ne '' -and (Test-Path $env:DOUYIN_SHOT)) {
  Write-Output "[run] 截图=$($env:DOUYIN_SHOT) 大小=$((Get-Item $env:DOUYIN_SHOT).Length) 字节"
} elseif ($Shot -ne '') {
  Write-Output "[run] 截图未生成"
}
