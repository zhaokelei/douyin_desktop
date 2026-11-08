// 全局「需要验证」横幅：叠在应用最上层，任何页面都能看到当前验证进度，
// 并能一键取消。验证期间不阻塞其它区域，用户可以继续浏览只读内容。

import 'dart:async';

import 'package:flutter/material.dart';

import 'verify_gate.dart';

class VerifyBanner extends StatefulWidget {
  const VerifyBanner({super.key});

  @override
  State<VerifyBanner> createState() => _VerifyBannerState();
}

class _VerifyBannerState extends State<VerifyBanner> {
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    VerifyGate.instance.addListener(_onGateChanged);
    _onGateChanged();
  }

  void _onGateChanged() {
    if (!mounted) return;
    setState(() {});
    final gate = VerifyGate.instance;
    _hideTimer?.cancel();
    if (gate.phase == VerifyPhase.passed) {
      // 成功提示只留 4 秒，避免挡住页面内容。
      _hideTimer = Timer(const Duration(seconds: 4), gate.reset);
    } else if (gate.phase != VerifyPhase.running &&
        gate.phase != VerifyPhase.idle) {
      // 失败 / 超时 / 取消：给用户足够时间看清原因。
      _hideTimer = Timer(const Duration(seconds: 10), gate.reset);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    VerifyGate.instance.removeListener(_onGateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gate = VerifyGate.instance;
    if (gate.phase == VerifyPhase.idle) return const SizedBox.shrink();
    final passed = gate.phase == VerifyPhase.passed;
    final accent = passed ? const Color(0xFF4CAF50) : const Color(0xFFFFB74D);
    final background = passed ? const Color(0xFF12301C) : const Color(0xFF3A2A0C);
    final title = gate.actionLabel == null
        ? (passed ? '验证已通过' : '需要验证')
        : (passed ? '${gate.actionLabel}：验证已通过' : '${gate.actionLabel}：需要验证');

    return Align(
      alignment: Alignment.topCenter,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 9, 8, 9),
          decoration: BoxDecoration(
            color: background,
            border: Border(bottom: BorderSide(color: accent, width: 1)),
          ),
          child: Row(
            children: [
              Icon(passed ? Icons.verified_outlined : Icons.shield_outlined,
                  color: accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(gate.message,
                        style: const TextStyle(
                            color: Color(0xFFE0E0E0), fontSize: 12, height: 1.45)),
                  ],
                ),
              ),
              if (gate.phase == VerifyPhase.running) ...[
                const SizedBox(width: 8),
                Text('${gate.waitedSeconds}s',
                    style: const TextStyle(
                        color: Color(0xFFBFBFBF), fontSize: 12)),
                TextButton(
                  onPressed: gate.cancel,
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('取消'),
                ),
              ] else
                IconButton(
                  onPressed: gate.reset,
                  icon: const Icon(Icons.close, size: 18),
                  color: const Color(0xFFBFBFBF),
                  tooltip: '收起',
                ),
            ],
          ),
        ),
      ),
    );
  }
}
