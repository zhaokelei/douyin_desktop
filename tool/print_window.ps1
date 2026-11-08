# 用 Win32 PrintWindow 抓取指定进程窗口的位图（用于离屏自测，
# 不依赖前台截屏，也不会抢焦点）。
#
# 用法示例：
#   powershell -ExecutionPolicy Bypass -File tool\print_window.ps1 `
#     -ProcessName douyin_desktop -Title '抖音桌面版' `
#     -OutPath C:\...\screenshots\printwindow.png -GrabDelay 18
#
# PW_RENDERFULLCONTENT(0x2) 对 D3D/DirectComposition 窗口比普通 PrintWindow 更可靠。

param(
  [string]$ProcessName = 'douyin_desktop',
  [string]$Title = '抖音桌面版',
  [int]$ProcessId = 0,
  [Parameter(Mandatory = $true)][string]$OutPath,
  [int]$WaitSeconds = 60,
  [int]$GrabDelay = 18
)

Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinGrab
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static IntPtr Find(uint pid, string title)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            uint wpid = 0;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid != pid) return true;
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowTextW(h, sb, 512);
            string t = sb.ToString();
            if (title.Length == 0 || t.Contains(title))
            {
                found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Grab(IntPtr hWnd, string path, out string rect)
    {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) { rect = "GetWindowRect 失败"; return false; }
        rect = string.Format("({0},{1})-({2},{3}) {4}x{5}", r.Left, r.Top, r.Right, r.Bottom,
                             r.Right - r.Left, r.Bottom - r.Top);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        using (var bmp = new System.Drawing.Bitmap(w, h))
        {
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                IntPtr hdc = g.GetHdc();
                bool ok = PrintWindow(hWnd, hdc, 2); // PW_RENDERFULLCONTENT
                g.ReleaseHdc(hdc);
                if (!ok) { bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png); return false; }
            }
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        return true;
    }
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing

Write-Output "[grab] 等待进程 $ProcessName (PID=$ProcessId) 的窗口（最多 $WaitSeconds 秒）"
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$hwnd = [IntPtr]::Zero
$procId = 0
while ((Get-Date) -lt $deadline) {
  if ($ProcessId -gt 0) {
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  } else {
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if ($proc) {
    $procId = $proc.Id
    $hwnd = [WinGrab]::Find([uint32]$proc.Id, $Title)
    if ($hwnd -ne [IntPtr]::Zero) { break }
  } elseif ($ProcessId -gt 0) {
    Write-Output "[grab] 目标进程 $ProcessId 已退出"
    exit 1
  }
  Start-Sleep -Milliseconds 500
}

if ($hwnd -eq [IntPtr]::Zero) {
  Write-Output "[grab] 没找到窗口（进程可能已退出）"
  exit 1
}

Write-Output "[grab] 已找到窗口 hwnd=$hwnd pid=$procId，等待 $GrabDelay 秒让画面稳定"
Start-Sleep -Seconds $GrabDelay

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$rect = ''
$ok = [WinGrab]::Grab($hwnd, $OutPath, [ref]$rect)
Write-Output "[grab] 窗口矩形=$rect PrintWindow=$ok 输出=$OutPath"
if (Test-Path $OutPath) {
  $size = (Get-Item $OutPath).Length
  Write-Output "[grab] 文件大小=$size 字节"
}
if (-not $ok) { exit 2 }
