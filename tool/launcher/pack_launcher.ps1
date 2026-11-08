# 打包 Flutter 版单文件引导器：
#   1) 把 build\windows\x64\runner\Release 压成自定义负载 payload.pkg；
#   2) 用系统自带的 .NET Framework csc 把负载嵌进 WinExe 引导器；
#   3) 产物拷到桌面交付目录。
#
# 用法：powershell -ExecutionPolicy Bypass -File pack_launcher.ps1

$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Release = Join-Path $Root 'build\windows\x64\runner\Release'
$Dest = 'C:\Users\Administrator\Desktop\抖音客户端'
$Work = Join-Path $PSScriptRoot 'work'
$Payload = Join-Path $Work 'payload.pkg'
$LauncherExe = Join-Path $Work 'DouyinDesktop-Flutter.exe'
$Csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path $Release)) { throw "找不到 Release 目录：$Release" }
if (-not (Test-Path $Csc)) { throw "找不到 csc.exe：$Csc" }
New-Item -ItemType Directory -Force -Path $Work, $Dest | Out-Null

# ---------- 0. 补齐 VC++ 运行时 ----------
# flutter build 的产物不携带 MSVC 运行时，而 douyin_desktop.exe 的导入表里有
# MSVCP140 / VCRUNTIME140 / VCRUNTIME140_1。干净机器（没装 VC++ 2015-2022
# 运行库）双击会直接报"丢失 MSVCP140.dll"，单文件交付就不成立了。
# 这里把这几个运行库从系统目录一并打进负载，解压后与应用同目录即可加载。
$vcNames = @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll')
$sys32 = Join-Path $env:WINDIR 'System32'
$extra = @()
foreach ($n in $vcNames) {
    if (Test-Path (Join-Path $Release $n)) { continue }  # 应用自带就不重复
    $src = Join-Path $sys32 $n
    if (-not (Test-Path $src)) { throw "系统缺少 $n，无法补齐运行时" }
    $extra += [pscustomobject]@{
        Rel   = $n
        Bytes = [IO.File]::ReadAllBytes($src)
    }
    Write-Host ("补齐运行时：{0}（{1:N0} 字节）" -f $n, (Get-Item $src).Length)
}

# ---------- 1. 打包负载 ----------
$files = Get-ChildItem -Path $Release -Recurse -File |
    Where-Object { $_.FullName -notlike '*\douyin_desktop.exe.WebView2\*' } |
    Sort-Object FullName
$extraBytes = 0
foreach ($e in $extra) { $extraBytes += $e.Bytes.Length }
Write-Host ("打包文件数：{0}（含运行库 {1}），原始 {2:N1} MB" -f
    ($files.Count + $extra.Count), $extra.Count,
    ((($files | Measure-Object Length -Sum).Sum + $extraBytes) / 1MB))

$fs = [IO.File]::Create($Payload)
$ascii = [Text.Encoding]::ASCII
$fs.Write($ascii.GetBytes('DYLPKG01'), 0, 8)
$deflate = [IO.Compression.DeflateStream]::new(
    $fs, [IO.Compression.CompressionMode]::Compress, $true)
$writer = [IO.BinaryWriter]::new($deflate, [Text.Encoding]::UTF8)
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Release.Length + 1)
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $writer.Write($rel)
        $writer.Write([int]$bytes.Length)
        $writer.Write($bytes)
    }
    foreach ($e in $extra) {
        $writer.Write($e.Rel)
        $writer.Write([int]$e.Bytes.Length)
        $writer.Write($e.Bytes)
    }
    $writer.Write('')
    $writer.Flush()
} finally {
    $writer.Dispose()
    $deflate.Dispose()
    $fs.Dispose()
}
Write-Host ("负载大小：{0:N1} MB" -f ((Get-Item $Payload).Length / 1MB))

# ---------- 2. 编译引导器 ----------
$cscArgs = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    "/out:$LauncherExe"
    # 资源参数必须是单个 token：/resource:<文件>,<资源名>
    "/resource:$Payload,payload.pkg"
    (Join-Path $PSScriptRoot 'Launcher.cs')
)
& $Csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败：$LASTEXITCODE" }

# ---------- 3. 交付 ----------
Copy-Item $LauncherExe (Join-Path $Dest 'DouyinDesktop-Flutter.exe') -Force
$out = Get-Item (Join-Path $Dest 'DouyinDesktop-Flutter.exe')
Write-Host ("交付：{0}（{1:N1} MB）" -f $out.FullName, ($out.Length / 1MB))
