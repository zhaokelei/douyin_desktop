import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_settings.dart';
import '../../core/diag.dart';
import '../../core/diag_ui.dart';
import '../../core/memory_trim.dart';
import '../../data/video_cache.dart';

/// 设置页：首页右上角齿轮进入。
///
/// 所有选项都直接写 `AppSettings`（持久化），播放页监听同一份设置，
/// 返回后立刻按新配置工作，不需要重启应用。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppSettings _settings = AppSettings.instance;
  final VideoCache _cache = VideoCache.shared;

  Timer? _ticker;

  /// 「运行状态」卡片的局部刷新信号。
  ///
  /// 内存/缓存占用每秒变一次，但整页只有那一张卡片依赖它。用独立
  /// Listenable 驱动该卡片，避免设置页整体（含所有选项与说明文字）
  /// 每秒重建一次——页面上那几个开关的布局完全没变，纯属白付。
  final _UsageTick _usageTick = _UsageTick();

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    // 缓存索引常驻内存，占用/条数可直接同步读；这里 init 一次确保目录与索引就绪。
    unawaited(_cache.init());
    // 预取在播放页后台进行，占用会随时变化，1 秒刷一次足够。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _usageTick.ping();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _usageTick.dispose();
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _clearCache() async {
    final before = _cache.usedBytes;
    await _cache.clear();
    if (!mounted) return;
    setState(() {});
    _snack('已删除 ${((before - _cache.usedBytes) / (1024 * 1024)).toStringAsFixed(1)} MB 缓存');
  }

  /// 一键复制诊断信息：环境 + 设置 + 播放器状态 + 最近日志。
  Future<void> _copyDiagnostics() async {
    try {
      final length = await DiagUi.copyReport(note: '设置页');
      _snack('诊断信息已复制（$length 字符），直接粘贴发送即可');
    } catch (e) {
      _snack('复制失败：$e');
    }
  }

  Future<void> _exportDiagnostics() async {
    try {
      final path = await DiagUi.exportReport(note: '设置页');
      _snack('已导出诊断文件：$path');
    } catch (e) {
      _snack('导出失败：$e');
    }
  }

  Future<void> _revealLogDir() async {
    final ok = await DiagUi.openLogDir();
    if (!ok) _snack('打不开文件管理器，请手动前往：${DiagUi.logDir}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141414),
        title: const Text('设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
        children: [
          _SectionCard(
            title: '视频解码',
            icon: Icons.memory,
            children: [
              _ChoiceTile(
                title: '自动（优先硬件解码）',
                subtitle: '能用显卡硬解就用硬解；硬件不可用时自动切到 CPU 软件解码，'
                    '并给出中文提示。推荐保持这一项。',
                selected: _settings.decodeMode == DecodeMode.auto,
                onTap: () => _settings.setDecodeMode(DecodeMode.auto),
              ),
              _ChoiceTile(
                title: '仅软件解码（CPU）',
                subtitle: '始终用 CPU 解码。兼容性最好、不会出现驱动相关的黑屏，'
                    '但高分辨率视频的 CPU 占用明显更高。',
                selected: _settings.decodeMode == DecodeMode.software,
                onTap: () => _settings.setDecodeMode(DecodeMode.software),
              ),
              const _Hint(
                '说明：个别显卡驱动会让硬解初始化失败。选「自动」时应用会检测到失败、'
                '自动改用软件解码并继续播放，不会弹出错误挡住画面；'
                '如果这台机器反复失败，可以直接固定为「仅软件解码」。',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '视频缓存',
            icon: Icons.sd_storage_outlined,
            children: [
              _ChoiceTile(
                title: '缓存在磁盘（推荐）',
                subtitle: '自动把后面几条作品提前下好，切过去就能立刻播、进度条随便拖；'
                    '到达上限时自动删除最早缓存的视频，循环往复，不会无限占空间。',
                selected: _settings.cacheMode == CacheMode.disk,
                onTap: () => _settings.setCacheMode(CacheMode.disk),
              ),
              _ChoiceTile(
                title: '不使用缓存（直连播放）',
                subtitle: '不占磁盘，但每条都要现拉流，且在线流不支持拖动进度，网络抖动时更容易卡。',
                selected: _settings.cacheMode == CacheMode.off,
                onTap: () => _settings.setCacheMode(CacheMode.off),
              ),
              if (_settings.cacheMode == CacheMode.disk) ...[
                const SizedBox(height: 6),
                _SubLabel('缓存大小上限'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mb in AppSettings.cacheLimitOptions)
                      _PillButton(
                        label: mb >= 1024
                            ? '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB'
                            : '$mb MB',
                        selected: _settings.cacheLimitMB == mb,
                        onTap: () => _settings.setCacheLimitMB(mb),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _UsageBar(
                  used: _cache.usedBytes,
                  limit: _settings.cacheLimitBytes,
                  label: '当前占用 '
                      '${(_cache.usedBytes / (1024 * 1024)).toStringAsFixed(1)} MB · '
                      '${_cache.itemCount} 条'
                      '${_cache.ready ? '' : '（正在读取缓存目录…）'}',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _ActionButton(
                      label: '清空缓存',
                      icon: Icons.cleaning_services_outlined,
                      onTap: _clearCache,
                    ),
                  ],
                ),
                _Hint('超过上限时按「最早缓存」的顺序删除，正在播放的那条不会被删。'
                    '缓存目录：${_cache.dirPath}'),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '播放',
            icon: Icons.play_circle_outline,
            children: [
              const _SubLabel('默认清晰度'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // 键必须和 `heightOfQualityLabel` 能识别的写法一致：
                  // 1440P / 2160P 是接口 gear 里的真实高度，
                  // 直接写 '2K' / '4K' 换算不出高度，会退化到自动档。
                  for (final entry in const {
                    'auto': '自动',
                    '2160P': '4K',
                    '1440P': '2K',
                    '1080P': '1080P',
                    '720P': '720P',
                    '540P': '540P',
                  }.entries)
                    _PillButton(
                      label: entry.value,
                      selected: _settings.qualityPref == entry.key,
                      onTap: () => _settings.setQualityPref(entry.key),
                    ),
                ],
              ),
              const _Hint('切换清晰度只影响之后打开的作品；当前正在播放的不会中断。'
                  '作品没有对应档位时按「不超过所选上限的最高档」播放。'
                  '2K/4K 会显著增加显存与内存占用，集显机器（如 Intel UHD）'
                  '建议保持 1080P 及以下。'),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '运行状态',
            icon: Icons.monitor_heart_outlined,
            children: [
              ListenableBuilder(
                listenable: _usageTick,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoRow(
                      label: '进程内存',
                      value:
                          '${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0)} MB',
                    ),
                    _InfoRow(
                      label: '磁盘缓存',
                      value: _cache.ready
                          ? '${(_cache.usedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
                              '${(_cache.maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB'
                              ' · ${_cache.itemCount} 条'
                          : '正在读取…',
                    ),
                    _InfoRow(
                      label: '缓存命中',
                      value: '${_cache.hitCount} / ${_cache.missCount} 次'
                          '（失败 ${_cache.failureCount}）',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              _ActionButton(
                label: '把内存还给系统',
                icon: Icons.arrow_downward,
                onTap: () {
                  MemoryTrim.trim(force: true);
                  _snack('已请求系统回收内存，占用会在数秒内下降');
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '诊断与日志',
            icon: Icons.bug_report_outlined,
            children: [
              const _Hint(
                '遇到播放异常、闪屏、卡顿、解码失败时，点「复制诊断信息」，'
                '把复制到的内容直接发给开发者即可定位，不需要截图描述现象。'
                '内容包含运行环境、当前设置、播放器实时状态与最近运行日志，'
                '不含账号凭证和视频地址。',
              ),
              const SizedBox(height: 10),
              _ActionButton(
                label: '复制诊断信息',
                icon: Icons.copy_all,
                onTap: () => unawaited(_copyDiagnostics()),
              ),
              const SizedBox(height: 8),
              _ActionButton(
                label: '导出诊断文件',
                icon: Icons.save_alt,
                onTap: () => unawaited(_exportDiagnostics()),
              ),
              const SizedBox(height: 8),
              _ActionButton(
                label: '打开日志目录',
                icon: Icons.folder_open,
                onTap: () => unawaited(_revealLogDir()),
              ),
              const SizedBox(height: 12),
              const _SubLabel('日志位置'),
              const SizedBox(height: 6),
              SelectableText(
                Diag.logPath,
                style: const TextStyle(
                    color: Color(0xFF9A9A9A), fontSize: 11, height: 1.5),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Center(
            child: Text(
              '抖音桌面版 · Flutter $kAppVersion',
              style: const TextStyle(color: Color(0xFF5A5A5A), fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message, style: const TextStyle(fontSize: 12.5)),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      width: 300,
      backgroundColor: const Color(0xEE2A2A2A),
    ));
  }
}

class _UsageTick extends ChangeNotifier {
  /// 暴露 protected 的 [notifyListeners]，供「运行状态」卡片局部刷新。
  void ping() => notifyListeners();
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF272727)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: const Color(0xFFB0B0B0)),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFFF0F0F0),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 2),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? const Color(0xFFFF2C55)
                      : const Color(0xFF555555),
                  width: 1.6,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFFFF2C55),
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFFFFFFFF)
                          : const Color(0xFFDDDDDD),
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF8A8A8A),
                      fontSize: 11.5,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFFA8A8A8),
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0x33FF2C55) : const Color(0xFF1F1F1F),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? const Color(0xAAFF2C55) : const Color(0xFF333333),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFFFF6A85) : const Color(0xFFBFBFBF),
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15, color: const Color(0xFFD0D0D0)),
      label: Text(
        label,
        style: const TextStyle(color: Color(0xFFD0D0D0), fontSize: 12),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF353535)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.used,
    required this.limit,
    required this.label,
  });

  final int used;
  final int limit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ratio = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    // 接近上限时变黄，超过 85% 变红：一眼能看出该清理了。
    final barColor = ratio >= 0.85
        ? const Color(0xFFFF5A5A)
        : (ratio >= 0.6 ? const Color(0xFFFFB74D) : const Color(0xFF4CC2FF));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: const Color(0xFF262626),
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 11.5),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFFDCDCDC), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF6F6F6F),
          fontSize: 11.5,
          height: 1.6,
        ),
      ),
    );
  }
}
