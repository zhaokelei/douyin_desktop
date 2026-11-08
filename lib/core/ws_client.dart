// 极简 WebSocket 客户端：只用 dart:io 的 Socket，自己拼握手请求、自己解析帧。
//
// 为什么不直接用 dart:io 的 `WebSocket.connect`：
// 2026-11-07 用户实测日志里，连本机 CDP 的 ws 一直在握手阶段失败，错误是
// `not upgraded to websocket, HTTP status code: 200`。用原始 socket 实测同端口：
//   - 不发 Upgrade 头的普通 GET  → `HTTP/1.1 200 OK`
//   - 发 Upgrade 头            → `HTTP/1.1 101`
//   - 未知 target id           → `HTTP/1.1 404`
// 也就是说 200 意味着**服务端把请求当成了普通 GET**，升级头在到达浏览器前丢了。
// 自己写请求行/头，能保证 `Upgrade: websocket` 一定在线上；握手失败时还能把
// **原始响应**（状态行 + 头 + 体）带回上层写进诊断，不再只剩一句
// `HTTP status code: 200`。
//
// 只实现 CDP 用到的子集：文本帧、分片续帧、ping/pong、close。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 握手失败。带上原始响应，便于定位"是谁回答的、回答了什麼"。
class WsHandshakeException implements Exception {
  WsHandshakeException(
    this.url, {
    required this.statusLine,
    required this.headers,
    required this.body,
  });

  final String url;
  final String statusLine;
  final List<String> headers;

  /// 响应体（截断后的可读文本），用来判断是"普通 GET 的应答"还是错误页。
  final String body;

  @override
  String toString() {
    final head = headers.take(6).join(' | ');
    final tail = body.isEmpty ? '' : ' body=$body';
    return 'WebSocket 握手未升级（$statusLine；$head$tail）';
  }

  /// 一行短摘要（写进日志/界面用）。
  String brief({int max = 220}) {
    final s = '${statusLine.isEmpty ? "无状态行" : statusLine}'
        '${body.isEmpty ? "" : "；$body"}'
        .replaceAll(RegExp(r'\s+'), ' ');
    return s.length <= max ? s : '${s.substring(0, max)}…';
  }
}

class RawWebSocket {
  RawWebSocket._(this._socket, this._url);

  final Socket _socket;
  final String _url;
  final List<int> _pending = [];
  final StreamController<String> _messages = StreamController<String>();
  final StringBuffer _fragment = StringBuffer();

  final Completer<void> _handshake = Completer<void>();
  final bool _debug = Platform.environment['WS_DEBUG'] == '1';
  WsHandshakeException? _handshakeError;
  bool _headerDone = false;
  bool _closed = false;

  Stream<String> get messages => _messages.stream;

  static Future<RawWebSocket> connect(String url,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final uri = Uri.parse(url);
    final secure = uri.scheme == 'wss';
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
    final path = uri.path.isEmpty ? '/' : uri.path;
    final target = uri.hasQuery ? '$path?${uri.query}' : path;

    final Socket socket = secure
        ? await SecureSocket.connect(host, port, timeout: timeout)
        : await Socket.connect(host, port, timeout: timeout);

    final ws = RawWebSocket._(socket, url);
    socket.listen(ws._onData, onError: (Object e) {
      ws._failBeforeHandshake('连接出错：$e');
      ws._finish(e);
    }, onDone: () {
      ws._failBeforeHandshake('连接在握手完成前被关闭');
      ws._finish(null);
    });

    final key = base64Encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)));
    socket.add(utf8.encode('GET $target HTTP/1.1\r\n'
        'Host: $host:$port\r\n'
        'Connection: Upgrade\r\n'
        'Upgrade: websocket\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: $key\r\n'
        '\r\n'));

    await ws._handshake.future.timeout(timeout, onTimeout: () {
      ws._failBeforeHandshake('握手响应超时（${timeout.inMilliseconds}ms）');
    });
    final error = ws._handshakeError;
    if (error != null) {
      ws._finish(null);
      throw error;
    }
    return ws;
  }

  void _failBeforeHandshake(String reason) {
    if (_handshake.isCompleted) return;
    _handshakeError = WsHandshakeException(_url,
        statusLine: reason, headers: const [], body: '');
    _handshake.complete();
  }

  void _onData(List<int> chunk) {
    if (_debug) stderr.writeln('[ws] recv ${chunk.length} 字节 (pending=${_pending.length} headerDone=$_headerDone)');
    _pending.addAll(chunk);
    if (!_headerDone) {
      final end = _headerEnd(_pending);
      if (end < 0) {
        if (_pending.length > 64 * 1024) {
          _failBeforeHandshake('响应头超过 64KB 仍未结束');
        }
        return;
      }
      final headerText =
          utf8.decode(_pending.sublist(0, end), allowMalformed: true);
      _pending.removeRange(0, end + 4);
      _headerDone = true;
      final lines = headerText.split('\r\n');
      final statusLine = lines.isEmpty ? '' : lines.first;
      final headers = lines.length > 1 ? lines.sublist(1) : const <String>[];
      if (!statusLine.startsWith('HTTP/1.1 101')) {
        // 非 101：再等一小会儿把响应体收回来，写进诊断。
        Timer(const Duration(milliseconds: 250), () {
          if (_handshake.isCompleted) return;
          final body = utf8.decode(_pending.take(600).toList(),
              allowMalformed: true);
          _pending.clear();
          _handshakeError = WsHandshakeException(_url,
              statusLine: statusLine, headers: headers, body: _flatten(body));
          _handshake.complete();
        });
        return;
      }
      if (!_handshake.isCompleted) _handshake.complete();
    }
    _parse();
  }

  static String _flatten(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 400 ? flat : '${flat.substring(0, 400)}…';
  }

  static int _headerEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _parse() {
    while (true) {
      if (_pending.length < 2) return;
      final b0 = _pending[0];
      final b1 = _pending[1];
      final fin = (b0 & 0x80) != 0;
      final opcode = b0 & 0x0f;
      final masked = (b1 & 0x80) != 0;
      var len = b1 & 0x7f;
      var offset = 2;
      if (len == 126) {
        if (_pending.length < offset + 2) return;
        len = (_pending[offset] << 8) | _pending[offset + 1];
        offset += 2;
      } else if (len == 127) {
        if (_pending.length < offset + 8) return;
        len = 0;
        for (var i = 0; i < 8; i++) {
          len = (len << 8) | _pending[offset + i];
        }
        offset += 8;
      }
      List<int>? mask;
      if (masked) {
        if (_pending.length < offset + 4) return;
        mask = _pending.sublist(offset, offset + 4);
        offset += 4;
      }
      if (_pending.length < offset + len) return; // 数据没到齐，等下一片
      var payload = _pending.sublist(offset, offset + len);
      if (mask != null) {
        payload = [
          for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4]
        ];
      }
      _pending.removeRange(0, offset + len);

      switch (opcode) {
        case 0x1: // text
        case 0x2: // binary（CDP 只用文本，二进制按文本尽力解）
        case 0x0: // continuation
          _fragment.write(utf8.decode(payload, allowMalformed: true));
          if (fin) {
            if (!_messages.isClosed) _messages.add(_fragment.toString());
            _fragment.clear();
          }
          break;
        case 0x8: // close
          _finish(null);
          return;
        case 0x9: // ping → pong
          _sendFrame(0xA, payload);
          break;
        case 0xA: // pong
          break;
      }
    }
  }

  void sendText(String text) => _sendFrame(0x1, utf8.encode(text));

  void _sendFrame(int opcode, List<int> payload) {
    if (_closed) return;
    // RFC 6455：**客户端发出的帧必须掩码**，否则服务端直接断开连接
    // （Chromium 就是这么做的：101 之后收到未掩码帧立即 close）。
    final mask = List<int>.generate(4, (_) => Random.secure().nextInt(256));
    final masked = [
      for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4]
    ];
    final frame = BytesBuilder();
    if (payload.length < 126) {
      frame.add([0x80 | opcode, 0x80 | payload.length]);
    } else if (payload.length < 65536) {
      frame.add([
        0x80 | opcode,
        0x80 | 126,
        (payload.length >> 8) & 0xff,
        payload.length & 0xff,
      ]);
    } else {
      frame.add([0x80 | opcode, 0x80 | 127, 0, 0, 0, 0]);
      for (var i = 3; i >= 0; i--) {
        frame.add([(payload.length >> (8 * i)) & 0xff]);
      }
    }
    frame.add(mask);
    frame.add(masked);
    try {
      _socket.add(frame.toBytes());
    } catch (_) {}
  }

  void _finish(Object? error) {
    if (_closed) return;
    _closed = true;
    try {
      _socket.destroy();
    } catch (_) {}
    if (error != null && !_messages.isClosed) _messages.addError(error);
    if (!_messages.isClosed) _messages.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _sendFrame(0x8, const [0x03, 0xe8]);
    _finish(null);
  }
}
