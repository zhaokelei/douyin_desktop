# 将 Flutter Release 产物同步到桌面的「抖音客户端\Flutter版」目录，方便实机测试。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\deploy_to_desktop.ps1
# 前提：已执行 flutter build windows --release

$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release'
$dst = Join-Path ([Environment]::GetFolderPath('Desktop')) '抖音客户端\Flutter版'

# ---------------------------------------------------------------- 兜底拉回
# 本机 CMakeCache 里的 CMAKE_INSTALL_PREFIX 曾被写成 C:\Program Files\douyin_desktop，
# 导致"构建显示成功、但 build 目录还是旧文件"。这里检测 Program Files 里是否有更新的
# 产物，有就先拷回来，保证后面同步出去的永远是刚编译出来的那一份。
$installed = 'C:\Program Files\douyin_desktop'
$installedSo = Join-Path $installed 'data\app.so'
$builtSo = Join-Path $src 'data\app.so'
if ((Test-Path $installedSo) -and (Test-Path $builtSo)) {
    $installedTime = (Get-Item $installedSo).LastWriteTime
    $builtTime = (Get-Item $builtSo).LastWriteTime
    if ($installedTime -gt $builtTime) {
        Write-Host "[回拉] Program Files 里有更新的产物（$installedTime），先拷回 build" -ForegroundColor Yellow
        Copy-Item (Join-Path $installed 'data\*') (Join-Path $src 'data') -Recurse -Force
        Copy-Item (Join-Path $installed '*.dll') $src -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $installed '*.exe') $src -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path (Join-Path $src 'douyin_desktop.exe'))) {
    Write-Host "[跳过] 未找到构建产物，请先执行: flutter build windows --release" -ForegroundColor Yellow
    Write-Host "       期望路径: $src"
    exit 2
}

# 防御：目标目录必须存在父级「抖音客户端」，避免路径异常时误同步到别处
$parent = Split-Path $dst -Parent
if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
if (-not (Test-Path $dst)) {
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
}

# /MIR 镜像同步：目标多余文件会被清理，保证与构建产物完全一致
robocopy $src $dst /MIR /NFL /NDL /NJH /NP /R:2 /W:2 | Out-Null
$code = $LASTEXITCODE
if ($code -ge 8) {
    Write-Host "[失败] robocopy 返回 $code，同步未完成。" -ForegroundColor Red
    exit $code
}

$exe = Join-Path $dst 'douyin_desktop.exe'
$so = Join-Path $dst 'data\app.so'
$info = Get-Item $exe
$soInfo = Get-Item $so
$files = (Get-ChildItem $dst -Recurse -File | Measure-Object).Count
$sizeMB = [math]::Round(((Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)

Write-Host "[完成] 已同步到: $dst" -ForegroundColor Green
Write-Host ("       douyin_desktop.exe  {0:N0} 字节  {1}" -f $info.Length, $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ("       data\app.so         {0:N0} 字节  {1}" -f $soInfo.Length, $soInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host ("       共 {0} 个文件 / {1} MB" -f $files, $sizeMB)
exit 0
