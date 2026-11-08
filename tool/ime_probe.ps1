# IME 实测脚本（Windows / 微软拼音）
# 验证两件事：
#   1) 播放页（焦点不在输入框）时，窗口的输入法上下文已被摘除：
#      按 X 不会进入组字，X 会打开评论面板；
#   2) 打开评论框后输入法上下文恢复：发 ji 能组字（候选框出现），Esc 可取消。
#
# 用法：pwsh -NoProfile -File tool\ime_probe.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ImeNative {
    [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr hWnd);
    [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr hWnd, IntPtr hImc);
    [DllImport("imm32.dll", CharSet = CharSet.Unicode)]
    public static extern int ImmGetCompositionStringW(IntPtr hImc, int index, byte[] buf, int len);
    [DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public delegate bool EnumProc(IntPtr hWnd, IntPtr param);

    // SetForegroundWindow alone is often rejected by the foreground lock;
    // attaching to the target thread input queue makes it reliable.
    public static bool ForceForeground(IntPtr hwnd) {
        uint pid;
        uint tid = GetWindowThreadProcessId(hwnd, out pid);
        uint cur = GetCurrentThreadId();
        // 先敲一下 ALT：绕过 Windows 的前台锁，否则 SetForegroundWindow 常被静默拒绝。
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        AttachThreadInput(cur, tid, true);
        ShowWindow(hwnd, 9 /* SW_RESTORE */);
        BringWindowToTop(hwnd);
        SetWindowPos(hwnd, IntPtr.Zero /* HWND_TOP */, 0, 0, 0, 0, 0x0002 | 0x0001);
        SwitchToThisWindow(hwnd, true);
        bool ok = SetForegroundWindow(hwnd);
        SetFocus(hwnd);
        AttachThreadInput(cur, tid, false);
        return ok;
    }

    public static void ClickAt(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); // left down
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); // left up
    }

    public static IntPtr FindMainWindow(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr hWnd, IntPtr param) {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            if ((int)pid != processId) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.Length == 0) return true;
            found = hWnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static void TapKey(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);      // key down
        keybd_event(vk, 0, 2, UIntPtr.Zero);      // key up
    }

    public static int CompositionLength(IntPtr hwnd) {
        IntPtr himc = ImmGetContext(hwnd);
        if (himc == IntPtr.Zero) return -1;
        int n = ImmGetCompositionStringW(himc, 8 /* GCS_COMPSTR */, null, 0);
        ImmReleaseContext(hwnd, himc);
        return n;
    }
}
'@

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Exe = Join-Path $Root 'build\windows\x64\runner\Release\douyin_desktop.exe'
$Shot = Join-Path $Root '_shots\ime_x.png'
New-Item -ItemType Directory -Force -Path (Split-Path $Shot) | Out-Null

$env:DOUYIN_MUTE = '1'
$env:DOUYIN_NO_VERIFY_UI = '1'
$env:DOUYIN_AUTOPLAY = '1'
$env:DOUYIN_SHOT = ''
$env:DOUYIN_LOG = Join-Path $Root '_shots\ime_probe.log'

Write-Host '启动应用（可见窗口，播放页自动打开）…'
$proc = Start-Process -FilePath $Exe -PassThru

# 等活动窗口出现（最多 20 秒）。
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $hwnd = [ImeNative]::FindMainWindow($proc.Id)
    if ($hwnd -ne [IntPtr]::Zero) { break }
}
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host 'FAIL：找不到主窗口'
    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host ("主窗口 HWND=0x{0:X}" -f [int64]$hwnd)

Start-Sleep -Seconds 6  # 等首页 → 播放页

# ---------- 1. 播放页：输入法上下文应已摘除 ----------
$himc = [ImeNative]::ImmGetContext($hwnd)
if ($himc -eq [IntPtr]::Zero) {
    Write-Host 'PASS 播放页：ImmGetContext = NULL（输入法上下文已摘除，按键不会组字）'
} else {
    Write-Host 'FAIL 播放页：ImmGetContext 仍然有效，输入法没有被摘除'
    [ImeNative]::ImmReleaseContext($hwnd, $himc) | Out-Null
}

# 让窗口前台，然后按 X：应当打开评论面板，而不是弹候选框。
# 让窗口前台 + 在窗口内点一下空白处，确保 Flutter 内部有键盘焦点。
[ImeNative]::ForceForeground($hwnd) | Out-Null
Start-Sleep -Milliseconds 600
$fg = [ImeNative]::GetForegroundWindow()
Write-Host ("前台窗口 = 0x{0:X}（目标 0x{1:X}）" -f [int64]$fg, [int64]$hwnd)
Start-Sleep -Milliseconds 200

$rect = New-Object ImeNative+RECT
[ImeNative]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
Write-Host ("窗口矩形 = {0},{1} - {2},{3}" -f $rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
# 点视频画面中部（避开顶部标签栏与错误框按钮），让 Flutter 页面拿到键盘焦点。
[ImeNative]::ClickAt($rect.Left + 300, $rect.Top + 260) | Out-Null
Start-Sleep -Milliseconds 700
[ImeNative]::TapKey(0x58)  # X

Start-Sleep -Milliseconds 1200
# 全屏截图：既能看到评论面板是否打开，也能看到有没有 IME 候选窗。
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
$bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "截图已保存：$Shot"

# ---------- 2. 评论框聚焦：输入法上下文应恢复 ----------
# 评论面板打开时输入框不会自动聚焦（用户点了才聚焦），所以这里点一下输入框。
# 两种形态都试：抽屉打开 → 输入框在右侧面板底部；抽屉未开 → 播放页底部控制条。
$hits = @(
    @{ X = $rect.Right - 220; Y = $rect.Bottom - 64 },
    @{ X = $rect.Right - 180; Y = $rect.Bottom - 40 },
    @{ X = $rect.Left + 680; Y = $rect.Bottom - 64 },
    @{ X = $rect.Left + 560; Y = $rect.Bottom - 40 }
)
$restored = $false
foreach ($p in $hits) {
    [ImeNative]::ClickAt($p.X, $p.Y) | Out-Null
    Start-Sleep -Milliseconds 900
    $h = [ImeNative]::ImmGetContext($hwnd)
    if ($h -ne [IntPtr]::Zero) {
        Write-Host ("命中评论输入框：({0},{1})" -f $p.X, $p.Y)
        [ImeNative]::ImmReleaseContext($hwnd, $h) | Out-Null
        $restored = $true
        break
    }
}
if ($restored) {
    Write-Host 'PASS 评论框：ImmGetContext 已恢复（输入框能打中文）'
} else {
    Write-Host 'FAIL 评论框：输入法上下文没有恢复，评论框打不了中文'
}

# 发 j i：中文输入法下应出现组字（GCS_COMPSTR 长度 > 0）。
[ImeNative]::TapKey(0x4A)  # J
Start-Sleep -Milliseconds 150
[ImeNative]::TapKey(0x49)  # I
Start-Sleep -Milliseconds 500
$len = [ImeNative]::CompositionLength($hwnd)
Write-Host ("评论框组字长度 = $len（>0 表示微软拼音正在组字；-1 表示没有 IME 上下文）")

# 收尾：Esc 取消组字/关面板，关闭应用。
[ImeNative]::TapKey(0x1B)
Start-Sleep -Milliseconds 500
$proc.CloseMainWindow() | Out-Null
if (-not $proc.HasExited) {
    Start-Sleep -Seconds 3
    if (-not $proc.HasExited) { $proc | Stop-Process -Force }
}
Write-Host '=== IME 实测结束 ==='
