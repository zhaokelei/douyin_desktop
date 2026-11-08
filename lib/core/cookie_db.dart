// 不依赖 CDP 的兜底读取：直接从浏览器 profile 的 Cookie 数据库（SQLite）读。
//
// 背景：2026-11-07 实测日志显示 CDP 的 WebSocket 握手被中间层改写成了普通
// GET（返回 200 而不是 101），于是三轮轮询一条 Cookie 都没读到。为了不再把
// "能不能登录"押在一条网络上，这里加一条完全离线的读取路径：
//
//   1. 定位 `<profile>/Default/Network/Cookies`（兼容旧版 `<profile>/Default/Cookies`）
//   2. 先连 `-wal`/`-shm` 一起复制到临时目录再打开（浏览器运行时数据库被独占）
//   3. 用系统自带的 SQLite（Windows 是 winsqlite3.dll，macOS/Linux 是 libsqlite3）
//      走 FFI，不引入第三方原生依赖
//   4. `encrypted_value`：
//        - Windows：`v10` = AES-256-GCM，key 在 `Local State` 的
//          `os_crypt.encrypted_key`（DPAPI 保护），先 CryptUnprotectData 再解开；
//          `v20` = app-bound 加密，离线解不开，明确报出来而不是假装成功
//        - 无前缀：直接就是明文
//        - macOS/Linux：需要系统钥匙串里的 Safe Storage 口令，本实现未覆盖，
//          只返回可读原因（不会静默给空值）
//
// 最终把结果整理成和 CDP 完全一致的字段（domain/name/value/expires/httpOnly/secure），
// 上层可以两条路径混用、合并。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';

import 'error_text.dart';
import 'platform_adapter.dart';

/// 一次兜底读取的结果。无论成败都不抛异常，失败原因放在 [error] 里。
class CookieDbRead {
  CookieDbRead({
    required this.profileDir,
    this.dbPath,
    this.cookies = const [],
    this.error,
    this.rows = 0,
    this.encryptedRows = 0,
    this.v20Rows = 0,
    this.decryptFailed = 0,
    this.expiredRows = 0,
    this.keyNote = '',
    this.locked = false,
  });

  final String profileDir;
  final String? dbPath;
  final List<Map<String, dynamic>> cookies;

  /// 失败原因（成功时为 null）。给界面/日志直接展示。
  final String? error;

  /// cookies 表里命中 douyin.com 的行数。
  final int rows;
  final int encryptedRows;

  /// v20（app-bound）的行数：离线解不开。
  final int v20Rows;
  final int decryptFailed;
  final int expiredRows;

  /// 解密密钥来源/状态说明。
  final String keyNote;

  /// 是否因为"浏览器正在运行、独占打开 Cookie 库"而读不到。
  /// Windows 下 Chromium 是独占打开的，其它进程连只读都打不开——
  /// 这种情况不是配置错误，关掉浏览器再读就行，界面要给出这个明确提示。
  final bool locked;

  bool get ok => error == null;

  /// 一行摘要：条数 + 关键 key + 各失败计数。
  String summary() {
    if (locked) {
      return '本地 Cookie 库被运行中的浏览器独占（Chromium 以独占方式打开，'
          '任何进程只读都打不开），关掉浏览器后即可离线读取';
    }
    if (error != null) return '本地 Cookie 库读取失败：$error';
    final keys = cookieKeySummary(cookies);
    return '本地 Cookie 库 $rows 行 → 可用 ${cookies.length} 项（$keys）'
        '${encryptedRows > 0 ? "；加密 $encryptedRows 行" : ""}'
        '${v20Rows > 0 ? "，其中 v20 $v20Rows 行无法离线解密" : ""}'
        '${decryptFailed > 0 ? "，解密失败 $decryptFailed 行" : ""}'
        '${keyNote.isEmpty ? "" : "；$keyNote"}';
  }
}

/// 关键 Cookie 是否存在（只报有无，不报值）。
String cookieKeySummary(List<Map<String, dynamic>> cookies) {
  final names = {for (final c in cookies) (c['name'] ?? '').toString()};
  return ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt', 'ttwid']
      .map((k) => '$k=${names.contains(k) ? "有" : "无"}')
      .join(' ');
}

/// 从指定 profile 目录读 douyin.com Cookie。永不抛异常。
Future<CookieDbRead> readCookiesFromProfile(String profileDir) async {
  final sep = Platform.pathSeparator;
  final candidates = [
    '$profileDir${sep}Default${sep}Network${sep}Cookies',
    '$profileDir${sep}Default${sep}Cookies',
    '$profileDir${sep}Network${sep}Cookies',
  ];
  final dbFile = candidates.map(File.new).where((f) => f.existsSync()).firstOrNull;
  if (dbFile == null) {
    return CookieDbRead(
      profileDir: profileDir,
      error: 'profile 里没有 Cookie 数据库（找过 ${candidates.length} 个位置）',
    );
  }

  Directory? tempDir;
  try {
    final problems = <String>[];
    // 1) 优先复制一份（含 wal/shm）再读：浏览器没在跑时最干净。
    tempDir = await Directory.systemTemp.createTemp('douyin_cookie_db_');
    final base = '${tempDir.path}${sep}Cookies';
    var copyOk = false;
    for (final suffix in const ['', '-wal', '-shm']) {
      final src = File('${dbFile.path}$suffix');
      if (!src.existsSync()) continue;
      try {
        await src.copy('$base$suffix');
        if (suffix.isEmpty) copyOk = true;
      } catch (e) {
        // 浏览器在跑时文件被独占，复制会失败——记下来，后面走 immutable。
        problems.add('复制$suffix失败：${ErrorText.from(e)}');
      }
    }

    // 2) 依次尝试：复制出来的库 → 原库（immutable=1，绕过 WAL/锁，只读已提交页）。
    final targets = <String>[
      if (copyOk) base,
      '${Uri.file(dbFile.path)}?immutable=1',
    ];
    List<_Row>? rows;
    for (final target in targets) {
      try {
        rows = await _queryDouyinRows(target);
        break;
      } catch (e) {
        problems.add('打开 ${target.startsWith('file:') ? "原库(immutable)" : "副本"} 失败：${ErrorText.from(e)}');
      }
    }
    if (rows == null) {
      return CookieDbRead(
        profileDir: profileDir,
        dbPath: dbFile.path,
        error: problems.join('；'),
        locked: _looksLocked(problems),
      );
    }
    final result = await _materialize(profileDir, dbFile.path, rows);
    return result;
  } catch (e) {
    return CookieDbRead(
        profileDir: profileDir, dbPath: dbFile.path, error: ErrorText.from(e));
  } finally {
    if (tempDir != null) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 从错误文本里判断是不是"被运行中的浏览器独占"。
bool _looksLocked(List<String> problems) {
  const hints = ['errno = 32', 'being used by another process', '正在使用此文件', 'rc=14'];
  return problems.any((p) => hints.any(p.contains));
}

class _Row {
  _Row(this.hostKey, this.name, this.value, this.encrypted, this.path,
      this.expiresUtc, this.secure, this.httpOnly);
  final String hostKey;
  final String name;
  final String value;
  final Uint8List encrypted;
  final String path;
  final int expiresUtc;
  final bool secure;
  final bool httpOnly;
}

Future<List<_Row>> _queryDouyinRows(String dbPath) async {
  final db = _sqlite.open(dbPath);
  try {
    final rows = <_Row>[];
    _sqlite.eachRow(
      db,
      'SELECT host_key, name, value, encrypted_value, path, expires_utc,'
      " is_secure, is_httponly FROM cookies WHERE host_key LIKE '%douyin.com'",
      (stmt) {
        rows.add(_Row(
          _sqlite.text(stmt, 0),
          _sqlite.text(stmt, 1),
          _sqlite.text(stmt, 2),
          _sqlite.blob(stmt, 3),
          _sqlite.text(stmt, 4),
          _sqlite.int64(stmt, 5),
          _sqlite.int64(stmt, 6) != 0,
          _sqlite.int64(stmt, 7) != 0,
        ));
      },
    );
    return rows;
  } finally {
    _sqlite.close(db);
  }
}

Future<CookieDbRead> _materialize(
    String profileDir, String dbPath, List<_Row> rows) async {
  final key = await _platformKey(profileDir);
  final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final cookies = <Map<String, dynamic>>[];
  var encryptedRows = 0;
  var v20 = 0;
  var decryptFailed = 0;
  var expired = 0;

  for (final row in rows) {
    if (row.name.isEmpty) continue;
    String value;
    if (row.value.isNotEmpty) {
      value = row.value;
    } else if (row.encrypted.isNotEmpty) {
      encryptedRows++;
      final head = row.encrypted.length >= 3
          ? utf8.decode(row.encrypted.sublist(0, 3), allowMalformed: true)
          : '';
      if (head == 'v20') {
        v20++;
        continue;
      }
      final decrypted = await key.decrypt(row.encrypted, row.hostKey);
      if (decrypted == null) {
        decryptFailed++;
        continue;
      }
      value = decrypted;
    } else {
      continue;
    }
    if (value.isEmpty) continue;

    // expires_utc：自 1601-01-01 起的微秒；0 表示会话 Cookie。
    final expires = row.expiresUtc > 0
        ? (row.expiresUtc / 1000000.0 - 11644473600.0)
        : -1.0;
    if (expires > 0 && expires < nowSeconds.toDouble()) {
      expired++;
      continue;
    }
    cookies.add({
      'domain': row.hostKey,
      'name': row.name,
      'value': value,
      'path': row.path.isEmpty ? '/' : row.path,
      'expires': expires,
      'httpOnly': row.httpOnly,
      'secure': row.secure,
    });
  }

  String? error;
  if (rows.isEmpty) {
    error = 'Cookie 库里没有 douyin.com 的 Cookie（浏览器里可能还没登录）';
  } else if (cookies.isEmpty) {
    error = encryptedRows > 0
        ? '有 $encryptedRows 行加密 Cookie 但一条也没解开（v20=$v20，失败=$decryptFailed）'
        : '有 ${rows.length} 行但不是过期就是空值';
  }

  return CookieDbRead(
    profileDir: profileDir,
    dbPath: dbPath,
    cookies: cookies,
    error: error,
    rows: rows.length,
    encryptedRows: encryptedRows,
    v20Rows: v20,
    decryptFailed: decryptFailed,
    expiredRows: expired,
    keyNote: key.note,
  );
}

// ---------------------------------------------------------------- 解密密钥

abstract class _CookieKey {
  const _CookieKey(this.note);

  /// 密钥来源说明（写进诊断）。
  final String note;

  /// [hostKey] 是这一行 Cookie 的 host_key：Chromium 的 v10 密文正文
  /// 前 32 字节是它的 SHA-256，必须用它来剥离，否则值前面会带乱码。
  Future<String?> decrypt(Uint8List encrypted, String hostKey);

  /// 没有可用密钥时的占位实现：只保留明文行，并把原因写清楚。
  static Future<_CookieKey> unavailable(String note) async =>
      _UnavailableKey(note);
}

class _UnavailableKey extends _CookieKey {
  _UnavailableKey(super.note);

  @override
  Future<String?> decrypt(Uint8List encrypted, String hostKey) async => null;
}

class _WindowsAesGcmKey extends _CookieKey {
  _WindowsAesGcmKey(super.note, this._key) : _gcm = AesGcm.with256bits();

  final List<int> _key;
  final AesGcm _gcm;

  @override
  Future<String?> decrypt(Uint8List encrypted, String hostKey) async {
    // v10 布局：3 字节前缀 + 12 字节 nonce + 密文 + 16 字节 tag
    if (encrypted.length < 3 + 12 + 16) return null;
    final nonce = encrypted.sublist(3, 15);
    final cipher = encrypted.sublist(15, encrypted.length - 16);
    final tag = encrypted.sublist(encrypted.length - 16);
    try {
      final clear = await _gcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(_key),
      );
      final bytes = await _stripHostHash(Uint8List.fromList(clear), hostKey);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 剥离 Chromium（v24 起的 Cookie 加密版本）写在密文正文最前面的
  /// 32 字节 host_key SHA-256。
  ///
  /// 2026-11-07 实测：不剥这 32 字节时值会带一段乱码（看起来"解密成功"），
  /// 拼进 HTTP 头直接触发 `FormatException: Invalid HTTP header field value`，
  /// 于是"读到了 Cookie 却永远用不了"。
  ///
  /// 判断顺序：
  ///   1. 前 32 字节与当前 host_key 的 SHA-256 相同 → 确定是前缀，剥离；
  ///   2. 不相同但前 32 字节含不可打印字节 → 仍是前缀（host_key 大小写/
  ///      尾点差异导致哈希对不上），按位置剥离；
  ///   3. 其余情况（老版本明文没有前缀）原样返回。
  Future<Uint8List> _stripHostHash(Uint8List clear, String hostKey) async {
    if (clear.length < 32) return clear;
    final head = clear.sublist(0, 32);
    final expected = (await Sha256().hash(utf8.encode(hostKey))).bytes;
    var same = true;
    for (var i = 0; i < 32; i++) {
      if (head[i] != expected[i]) {
        same = false;
        break;
      }
    }
    if (same) return clear.sublist(32);
    final printable = head.every((b) => b >= 0x20 && b < 0x7f);
    return printable ? clear : clear.sublist(32);
  }
}

/// 取当前平台可用的解密密钥。Windows 走 DPAPI；macOS/Linux 返回"不可用+原因"。
Future<_CookieKey> _platformKey(String profileDir) async {
  final sep = Platform.pathSeparator;
  if (!Platform.isWindows) {
    return _CookieKey.unavailable(Platform.isMacOS
        ? 'macOS 的 v10 需要钥匙串里的 Safe Storage 口令，本实现未覆盖'
        : 'Linux 的 v11 需要 keyring，本实现未覆盖（明文项仍可用）');
  }

  final stateFile = File('$profileDir${sep}Local State');
  if (!stateFile.existsSync()) {
    return _CookieKey.unavailable('profile 里没有 Local State，拿不到解密密钥');
  }
  Map<String, dynamic> state;
  try {
    final decoded = jsonDecode(await stateFile.readAsString());
    if (decoded is! Map<String, dynamic>) throw const FormatException('结构不是对象');
    state = decoded;
  } catch (e) {
    return _CookieKey.unavailable('Local State 解析失败：${ErrorText.from(e)}');
  }
  final osCrypt = state['os_crypt'];
  if (osCrypt is! Map) {
    return _CookieKey.unavailable('Local State 里没有 os_crypt');
  }
  if (osCrypt['app_bound_encrypted_key'] != null) {
    // 存在 app-bound key 说明这个浏览器可能写 v20；v10 仍可按老办法解。
  }
  final b64 = (osCrypt['encrypted_key'] ?? '').toString();
  if (b64.isEmpty) {
    return _CookieKey.unavailable(
        'Local State 里没有 os_crypt.encrypted_key，无法解密 v10');
  }
  try {
    final blob = base64Decode(b64);
    // 前 5 字节是 ASCII "DPAPI"，后面才是 DPAPI 保护的数据。
    if (blob.length <= 5) {
      return _CookieKey.unavailable('os_crypt.encrypted_key 长度异常');
    }
    final key = _dpapiUnprotect(blob.sublist(5));
    if (key == null) {
      return _CookieKey.unavailable('DPAPI 解密密钥失败（CryptUnprotectData 返回 0）');
    }
    if (key.length != 32) {
      return _CookieKey.unavailable('解出的密钥长度是 ${key.length}，不是预期的 32');
    }
    return _WindowsAesGcmKey('DPAPI 密钥已取到（32 字节）', key);
  } catch (e) {
    return _CookieKey.unavailable('DPAPI 解密异常：${ErrorText.from(e)}');
  }
}

// --------------------------------------------------------------- DPAPI (FFI)

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptUnprotectDataNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _CryptUnprotectData = int Function(
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

Uint8List? _dpapiUnprotect(Uint8List data) {
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final unprotect = crypt32
      .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectData>(
          'CryptUnprotectData');
  final localFree = kernel32.lookupFunction<IntPtr Function(Pointer<Void>),
      int Function(Pointer<Void>)>('LocalFree');

  final inPtr = calloc<Uint8>(data.length);
  final blobIn = calloc<_DataBlob>();
  final blobOut = calloc<_DataBlob>();
  try {
    inPtr.asTypedList(data.length).setAll(0, data);
    blobIn.ref.cbData = data.length;
    blobIn.ref.pbData = inPtr;
    final ok = unprotect(blobIn, nullptr, nullptr, nullptr, nullptr, 0, blobOut);
    if (ok == 0 || blobOut.ref.pbData == nullptr) return null;
    final size = blobOut.ref.cbData;
    final out = Uint8List.fromList(blobOut.ref.pbData.asTypedList(size));
    localFree(blobOut.ref.pbData.cast());
    return out;
  } finally {
    calloc.free(inPtr);
    calloc.free(blobIn);
    calloc.free(blobOut);
  }
}

// -------------------------------------------------------------- SQLite (FFI)

class _Sqlite {
  DynamicLibrary? _lib;

  DynamicLibrary get lib {
    final cached = _lib;
    if (cached != null) return cached;
    final loaded = _open();
    _lib = loaded;
    return loaded;
  }

  static DynamicLibrary _open() {
    final names = <String>[
      if (Platform.isWindows) 'winsqlite3.dll',
      if (Platform.isMacOS) '/usr/lib/libsqlite3.dylib',
      if (Platform.isLinux) ...['libsqlite3.so.0', 'libsqlite3.so'],
    ];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    throw UnsupportedError('系统里找不到 SQLite 动态库（试过 ${names.join(' / ')}）');
  }

  Pointer<Void> open(String path) {
    final openV2 = lib.lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>, Int32, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Void>>, int, Pointer<Utf8>)>(
        'sqlite3_open_v2');
    final dbPtr = calloc<Pointer<Void>>();
    final pathPtr = path.toNativeUtf8();
    try {
      // SQLITE_OPEN_READONLY |（路径是 URI 时）SQLITE_OPEN_URI
      final flags = 1 | (path.startsWith('file:') ? 0x40 : 0);
      final rc = openV2(pathPtr, dbPtr, flags, nullptr);
      if (rc != 0) {
        final msg = errmsg(dbPtr.value);
        throw StateError('打开 Cookie 库失败（rc=$rc）：$msg');
      }
      return dbPtr.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(dbPtr);
    }
  }

  String errmsg(Pointer<Void> db) {
    try {
      final f = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)>('sqlite3_errmsg');
      return f(db).toDartString();
    } catch (_) {
      return '未知错误';
    }
  }

  void close(Pointer<Void> db) {
    try {
      lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
          'sqlite3_close')(db);
    } catch (_) {}
  }

  /// 跑一条只读查询，逐行回调。
  void eachRow(Pointer<Void> db, String sql, void Function(Pointer<Void>) onRow) {
    final prepare = lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>)>('sqlite3_prepare_v2');
    final step = lib.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('sqlite3_step');
    final finalize = lib.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('sqlite3_finalize');

    final sqlPtr = sql.toNativeUtf8();
    final stmtPtr = calloc<Pointer<Void>>();
    try {
      final rc = prepare(db, sqlPtr, -1, stmtPtr, nullptr);
      if (rc != 0) throw StateError('SQL 预处理失败（rc=$rc）：${errmsg(db)}');
      final stmt = stmtPtr.value;
      try {
        while (true) {
          final rc2 = step(stmt);
          if (rc2 == 100) {
            onRow(stmt);
            continue;
          }
          if (rc2 == 101) break;
          throw StateError('读行失败（rc=$rc2）：${errmsg(db)}');
        }
      } finally {
        finalize(stmt);
      }
    } finally {
      calloc.free(sqlPtr);
      calloc.free(stmtPtr);
    }
  }

  String text(Pointer<Void> stmt, int column) {
    final f = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, int)>('sqlite3_column_text');
    final ptr = f(stmt, column);
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }

  Uint8List blob(Pointer<Void> stmt, int column) {
    final blobFn = lib.lookupFunction<Pointer<Uint8> Function(Pointer<Void>, Int32),
        Pointer<Uint8> Function(Pointer<Void>, int)>('sqlite3_column_blob');
    final bytesFn = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('sqlite3_column_bytes');
    final ptr = blobFn(stmt, column);
    final n = bytesFn(stmt, column);
    if (ptr == nullptr || n <= 0) return Uint8List(0);
    return Uint8List.fromList(ptr.asTypedList(n));
  }

  int int64(Pointer<Void> stmt, int column) {
    final f = lib.lookupFunction<Int64 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('sqlite3_column_int64');
    return f(stmt, column);
  }
}

final _Sqlite _sqlite = _Sqlite();

/// 供自测脚本直接调用：返回摘要字符串（不含 Cookie 值）。
Future<String> debugProfileSummary(String profileDir) async {
  final read = await readCookiesFromProfile(
      profileDir.isEmpty ? PlatformAdapter.browserProfileDir : profileDir);
  return '${read.summary()}；profile=${read.profileDir}；db=${read.dbPath}';
}
