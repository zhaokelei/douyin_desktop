// 自解压引导器（Flutter 版单文件形态）。
//
// Flutter Windows 产物是 exe + data/ + 一堆 DLL，无法做成真正的单 exe，
// 所以这里把整个 Release 目录压进本 exe 的资源里：
//   1. 运行时按「负载内容 SHA-256 前 8 字节」决定解压目录
//      %LOCALAPPDATA%\DouyinDesktopFlutter\<hash>\，
//      目录里已有 .ready 就跳过解压直接启动（等价于"已是最新"）；
//   2. 拉起解压目录里的 douyin_desktop.exe，工作目录设为该目录；
//   3. 等待应用退出并把退出码透传出去；本身编译为 WinExe，没有控制台黑窗。
//
// 只依赖 .NET Framework（Windows 10/11 系统自带），不使用任何第三方库。
// 用户数据（Cookie、浏览器 profile）仍由应用自己写 %APPDATA%\douyin_desktop\，
// 与解压目录无关，所以换版本重装不会丢登录态。
//
// 负载格式（与 pack_launcher.ps1 对称）：
//   8 字节魔数 "DYLPKG01" + Deflate 压缩流；
//   流内依次是 BinaryWriter 的 (相对路径 string, 长度 int32, 内容 bytes)，
//   以空字符串结尾。

using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

internal static class Program
{
    private const string PayloadResource = "payload.pkg";
    private const string AppExeName = "douyin_desktop.exe";
    private const string ReadyMarker = ".ready";
    private const string Magic = "DYLPKG01";

    [STAThread]
    private static int Main(string[] args)
    {
        var total = Stopwatch.StartNew();
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DouyinDesktopFlutter");
        try { Directory.CreateDirectory(root); }
        catch { }

        Stream payload = null;
        try
        {
            payload = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(PayloadResource);
            if (payload == null)
            {
                Log(root, "找不到内嵌负载 payload.pkg（打包错误）");
                return 11;
            }

            // Deflate 流不能回卷，而"算哈希"和"解压"都要从头上读一次，
            // 所以先把压缩负载整个读进内存（压缩后几十 MB，一次性开销）。
            var buffer = new MemoryStream();
            var chunk = new byte[8192];
            int n;
            while ((n = payload.Read(chunk, 0, chunk.Length)) > 0)
            {
                buffer.Write(chunk, 0, n);
            }
            payload.Dispose();
            payload = null;
            buffer.Position = 0;

            var hash = SHA256.Create().ComputeHash(buffer.ToArray());
            var tag = BitConverter.ToString(hash, 0, 8)
                .Replace("-", string.Empty).ToLowerInvariant();
            Log(root, string.Format("负载 {0:N1} MB，内容哈希 {1}",
                buffer.Length / 1048576.0, tag));

            var dir = Path.Combine(root, tag);
            if (File.Exists(Path.Combine(dir, ReadyMarker)))
            {
                Log(root, string.Format(
                    "内容哈希一致、已解压过，跳过解压直接启动（{0} ms）",
                    total.ElapsedMilliseconds));
            }
            else
            {
                var extractWatch = Stopwatch.StartNew();
                dir = Extract(buffer, root, tag);
                Log(root, string.Format("解压完成：{0} ms，目录 {1}，文件 {2}",
                    extractWatch.ElapsedMilliseconds, dir, _lastEntryCount));
            }

            var exe = Path.Combine(dir, AppExeName);
            if (!File.Exists(exe))
            {
                Log(root, "解压后找不到 " + exe);
                return 13;
            }

            var psi = new ProcessStartInfo(exe);
            psi.WorkingDirectory = dir; // Flutter 会按工作目录找 data\ 与 DLL
            psi.UseShellExecute = false; // 不经过 shell，避免闪一个控制台窗口
            var proc = Process.Start(psi);
            if (proc == null)
            {
                Log(root, "Process.Start 返回空，无法拉起应用");
                return 12;
            }
            Log(root, string.Format("已拉起应用（引导器累计 {0} ms）", total.ElapsedMilliseconds));

            proc.WaitForExit(); // 双击启动时引导器随应用一起存在，关闭应用即退出
            Log(root, string.Format("应用已退出，退出码 {0}（引导器存活 {1} ms）",
                proc.ExitCode, total.ElapsedMilliseconds));
            return proc.ExitCode;
        }
        catch (Exception e)
        {
            Log(root, "引导器失败：" + e);
            return 14;
        }
        finally
        {
            if (payload != null) payload.Dispose();
        }
    }

    private static int _lastEntryCount;

    /// <summary>
    /// 把负载解到 root\&lt;tag&gt; 并返回实际使用的目录。
    /// 解压先写 .tmp-&lt;pid&gt;，全部成功后才改名，避免中途失败留下半个目录。
    /// </summary>
    private static string Extract(Stream payload, string root, string tag)
    {
        var target = Path.Combine(root, tag);
        var tmp = Path.Combine(root, ".tmp-" + Process.GetCurrentProcess().Id);
        if (Directory.Exists(tmp))
        {
            try { Directory.Delete(tmp, true); }
            catch { }
        }
        Directory.CreateDirectory(tmp);

        payload.Position = 0;
        var magic = new byte[8];
        var got = 0;
        while (got < 8)
        {
            var n = payload.Read(magic, got, 8 - got);
            if (n <= 0) throw new IOException("负载太小，缺少魔数");
            got += n;
        }
        if (Encoding.ASCII.GetString(magic) != Magic)
            throw new IOException("负载魔数不匹配（不是本引导器打出的包）");

        var count = 0;
        using (var deflate = new DeflateStream(payload, CompressionMode.Decompress, true))
        using (var reader = new BinaryReader(deflate, Encoding.UTF8))
        {
            while (true)
            {
                string rel;
                try { rel = reader.ReadString(); }
                catch (EndOfStreamException) { break; }
                if (rel.Length == 0) break; // 空字符串是清单结束标记

                var len = reader.ReadInt32();
                var data = reader.ReadBytes(len);
                if (data.Length != len)
                    throw new IOException("负载被截断：" + rel);

                var safe = rel.Replace('/', Path.DirectorySeparatorChar).TrimStart('\\');
                if (safe.Contains("..") || Path.IsPathRooted(safe))
                    throw new IOException("非法相对路径: " + rel);

                var full = Path.Combine(tmp, safe);
                var parent = Path.GetDirectoryName(full);
                if (parent != null) Directory.CreateDirectory(parent);
                File.WriteAllBytes(full, data);
                count++;
            }
        }

        File.WriteAllText(Path.Combine(tmp, ReadyMarker), tag, Encoding.ASCII);
        _lastEntryCount = count;

        // 同名目录已存在（上次解压被中断）：先删；删不掉说明旧版本还在跑，
        // 那就这次直接用临时目录里的完整副本启动，不阻塞用户。
        if (Directory.Exists(target))
        {
            try { Directory.Delete(target, true); }
            catch { }
        }
        if (!Directory.Exists(target))
        {
            Directory.Move(tmp, target);
            return target;
        }
        return tmp;
    }

    private static void Log(string root, string message)
    {
        try
        {
            var path = Path.Combine(root, "launcher.log");
            var fi = new FileInfo(path);
            if (fi.Exists && fi.Length > 1048576) File.WriteAllText(path, string.Empty);
            File.AppendAllText(path,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }
}
