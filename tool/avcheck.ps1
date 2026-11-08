# AV sync frame-by-frame check: launch real window, click into player,
# capture screenshots every 40ms while mpv avtrace is written to avcheck.log.
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\douyin_desktop'
$exe = Join-Path $root 'build\windows\x64\runner\Release\douyin_desktop.exe'
$log = 'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\avcheck.log'
$frames = 'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\avframes'
Remove-Item $log -ErrorAction SilentlyContinue
if (Test-Path $frames) { Remove-Item "$frames\*" -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $frames | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

Get-Process douyin_desktop -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

$env:DOUYIN_LOG = $log
$env:DOUYIN_AVTRACE = '1'
$p = Start-Process -FilePath $exe -PassThru
Write-Output "pid=$($p.Id)"

$script:found = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 250
  $cb = [Win32+EnumProc] {
    param($h, $l)
    $sb = New-Object System.Text.StringBuilder 256
    [Win32]::GetWindowText($h, $sb, 256) | Out-Null
    if ($sb.ToString() -eq 'douyin_desktop') { $script:found = $h; return $false }
    return $true
  }
  [Win32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  if ($script:found -ne [IntPtr]::Zero) { break }
}
$hwnd = $script:found
if ($hwnd -eq [IntPtr]::Zero) { Write-Output 'WINDOW_NOT_FOUND'; exit 2 }

$x = 320; $y = 120; $w = 1280; $h = 800
[Win32]::ShowWindow($hwnd, 9) | Out-Null
[Win32]::SetWindowPos($hwnd, [IntPtr](-1), $x, $y, $w, $h, 0x0040 -bor 0x0001) | Out-Null
[Win32]::SetForegroundWindow($hwnd) | Out-Null

# Cold start needs ~9s before feed cards are visible.
Start-Sleep -Seconds 12
[Win32]::SetCursorPos(($x + 420), ($y + 300)) | Out-Null
Start-Sleep -Milliseconds 150
[Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
$clickAt = Get-Date

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rows = @()
for ($i = 0; $i -lt 120; $i++) {
  $t = $sw.ElapsedMilliseconds
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $g.Dispose()
  $file = Join-Path $frames ("f_{0:D3}_{1:D4}.png" -f $i, $t)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $sum = 0; $cnt = 0
  for ($px = 40; $px -lt 960; $px += 16) {
    for ($py = 90; $py -lt 700; $py += 16) {
      $c = $bmp.GetPixel($px, $py)
      $sum += ($c.R + $c.G + $c.B) / 3
      $cnt++
    }
  }
  $rows += [pscustomobject]@{ t = $t; mean = [math]::Round($sum / $cnt, 1) }
  $bmp.Dispose()
  Start-Sleep -Milliseconds 40
}
$sw.Stop()

$rows | ForEach-Object { Write-Output ("t={0}ms mean={1}" -f $_.t, $_.mean) }
Write-Output "clickAt=$($clickAt.ToString('HH:mm:ss.fff'))"
Write-Output "--- avtrace / avsync / player ---"
if (Test-Path $log) {
  Get-Content $log -Raw | Select-String -Pattern 'avtrace|avsync|player' -AllMatches | Out-Null
  Get-Content $log | Where-Object { $_ -match 'avtrace|avsync|player' } | Select-Object -Last 60
}
Get-Process douyin_desktop -ErrorAction SilentlyContinue | Stop-Process -Force
