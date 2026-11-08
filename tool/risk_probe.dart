// 验证「风控 / 需要验证」的统一判定（直接调用生产函数 classifyRiskResponse）。
//
// 用法：dart run tool/risk_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';

int failed = 0;

void check(String name, RiskSignal signal, {bool needVerify = true, String? url}) {
  final ok = signal.needsVerify == needVerify &&
      (url == null || signal.verifyUrl == url);
  if (!ok) failed++;
  print('${ok ? "PASS" : "FAIL"}  $name -> needsVerify=${signal.needsVerify} '
      'reason="${signal.reason}" url=${signal.verifyUrl ?? "无"}');
}

void main() {
  // 1. 403 空 body：网关直接拦截
  check(
    'HTTP 403 空响应',
    classifyRiskResponse(httpStatus: 403, body: '', headers: const {}),
  );

  // 2. 412 风控码
  check(
    'HTTP 412',
    classifyRiskResponse(httpStatus: 412, body: '', headers: const {}),
  );

  // 3. status_code=8：会话未登录/失效
  check(
    'status_code=8',
    classifyRiskResponse(
        httpStatus: 200, body: '{"status_code":8}', headers: const {}),
  );

  // 4. 业务失败 + 中文验证提示
  check(
    'status_msg 含"安全验证"',
    classifyRiskResponse(
        httpStatus: 200,
        body: '{"status_code":2154,"status_msg":"请完成安全验证"}',
        headers: const {}),
  );

  // 5. 响应里带验证地址
  check(
    'data.verify_url',
    classifyRiskResponse(
        httpStatus: 200,
        body:
            '{"status_code":2154,"data":{"verify_url":"https://verify.douyin.com/x"}}',
        headers: const {}),
    url: 'https://verify.douyin.com/x',
  );

  // 6. bdturing 响应头（base64 JSON 里带地址）
  final bdturing = base64Encode(
      utf8.encode('{"verify_type":"slide","url":"https://verify.douyin.com/b"}'));
  check(
    'x-vc-bdturing-parameters(base64)',
    classifyRiskResponse(
        httpStatus: 403,
        body: '',
        headers: {'x-vc-bdturing-parameters': bdturing}),
    url: 'https://verify.douyin.com/b',
  );

  // 7. 正常响应不能被误判
  check(
    '正常推荐流',
    classifyRiskResponse(
        httpStatus: 200,
        body: '{"status_code":0,"aweme_list":[{"aweme_id":"1"}]}',
        headers: const {}),
    needVerify: false,
  );

  // 8. 正常响应里出现 verifyFp / verify 字样也不应误判
  check(
    '正常响应含 verifyFp 字段',
    classifyRiskResponse(
        httpStatus: 200,
        body: '{"status_code":0,"verifyFp":"verify_abc","verify_event":""}',
        headers: const {}),
    needVerify: false,
  );

  // 9. 429 限流不算"需要用户验证"
  check(
    'HTTP 429 限流',
    classifyRiskResponse(httpStatus: 429, body: '', headers: const {}),
    needVerify: false,
  );

  // 10. 200 空 body 只算普通异常，不弹验证
  check(
    'HTTP 200 空 body',
    classifyRiskResponse(httpStatus: 200, body: '', headers: const {}),
    needVerify: false,
  );

  // 11. HTML 验证页（非 JSON）
  check(
    'HTML captcha 页面',
    classifyRiskResponse(
        httpStatus: 200,
        body: '<html><body>captcha 滑块验证</body></html>',
        headers: const {}),
  );

  print(failed == 0 ? '\n全部通过' : '\n$failed 项失败');
  exitCode = failed == 0 ? 0 : 1;
}
