import 'package:flutter/material.dart';

import '../../core/platform_adapter.dart';

/// 播放调试信息层：直接显示 mpv 实际使用的解码器，而不是"应该是硬解"。
class DebugOverlay extends StatelessWidget {
  const DebugOverlay({
    super.key,
    required this.hwdecCurrent,
    required this.codec,
    required this.resolution,
    required this.frameRate,
    required this.hardwareEnabled,
    required this.logs,
    required this.onToggleHardware,
    this.softwareFallback = false,
    this.cacheLine = '',
    this.renderBackend = '',
  });

  final String hwdecCurrent;
  final String codec;
  final String resolution;
  final String frameRate;
  final bool hardwareEnabled;
  final List<String> logs;
  final VoidCallback onToggleHardware;

  /// 开了硬件解码开关，但 mpv 实际回落到软解（硬件/驱动不支持）。
  final bool softwareFallback;

  /// 视频缓存状态（内存占用 / 磁盘 / 未启用），空字符串表示不显示。
  final String cacheLine;

  /// 视频帧交给 Flutter 的渲染后端。硬件纹理（OpenGL）在 macOS 上会与
  /// 字形图集抢 GL 状态，显示出来便于确认当前是否走在稳定路径上。
  final String renderBackend;

  bool get _hardwareActive {
    final v = hwdecCurrent.toLowerCase();
    return v.isNotEmpty && v != '—' && v != 'no' && v != 'failed' && v != 'auto-safe';
  }

  /// mpv 的 `video-codec` 有时带 `((null))`（容器没写 codec 标签时就长这样），
  /// 直接显示很丑，这里去掉括号里的 null 占位。
  String get _codecPretty {
    final cleaned = codec
        .replaceAll(RegExp(r'\s*\(\(?null\)?\)'), '')
        .replaceAll(RegExp(r'\s*\(null\)'), '')
        .trim();
    return cleaned.isEmpty ? '—' : cleaned;
  }

  /// 状态文案区分三种情况，避免"开着硬解但实际软解"时显示误导性的绿标。
  ///
  /// 注意顺序：自动降级后 [hardwareEnabled] 也会变成 false，
  /// 但用户并没有手动关硬解，所以"硬件不可用"要优先于"手动关闭"。
  String get _statusLabel {
    if (softwareFallback) return '软件解码（硬件不可用）';
    if (!hardwareEnabled) return '软件解码（手动关闭）';
    if (_hardwareActive) return '硬件加速中';
    return '等待解码信息';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 310,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xF0141414),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF333333)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '解码信息',
                style: TextStyle(
                  color: Color(0xFFEDEDED),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _statusPill(),
            ],
          ),
          const SizedBox(height: 10),
          _row('实际解码器', PlatformAdapter.describeDecoder(hwdecCurrent)),
          _row('视频编码', _codecPretty),
          _row('分辨率', resolution),
          _row('帧率', frameRate),
          if (cacheLine.isNotEmpty) _row('视频缓存', cacheLine),
          if (renderBackend.isNotEmpty) _row('视频纹理', renderBackend),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                '硬件解码',
                style: TextStyle(color: Color(0xFFBDBDBD), fontSize: 12),
              ),
              const Spacer(),
              Switch(
                value: hardwareEnabled,
                onChanged: (_) => onToggleHardware(),
                activeTrackColor: const Color(0xFFFF2C55),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            '切换后会重新打开当前视频，便于对比硬解与软解的 CPU 占用。',
            style: TextStyle(color: Color(0xFF7C7C7C), fontSize: 10.5, height: 1.4),
          ),
          if (logs.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in logs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color(0xFF8E8E8E),
                            fontSize: 10,
                            fontFamily: PlatformAdapter.monospaceFontFamily,
                            fontFamilyFallback:
                                PlatformAdapter.monospaceFallback,
                            height: 1.35,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _hardwareActive ? const Color(0x2633C46A) : const Color(0x26E0A03A),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: _hardwareActive ? const Color(0x6633C46A) : const Color(0x66E0A03A),
        ),
      ),
      child: Text(
        _statusLabel,
        style: TextStyle(
          color: _hardwareActive ? const Color(0xFF66D98A) : const Color(0xFFE8B55D),
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: const Color(0xFFEDEDED),
                fontSize: 11,
                fontFamily: PlatformAdapter.monospaceFontFamily,
                fontFamilyFallback: PlatformAdapter.monospaceFallback,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
