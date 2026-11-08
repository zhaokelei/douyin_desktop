// 自测：直接读固定 profile 的 Cookie 库（走 SQLite + DPAPI，不碰 CDP）。
// 只打印条数/关键 key/失败原因，绝不打印 Cookie 值。
// 用法：dart run tool/cookie_db_probe.dart [profileDir]
import 'dart:io';

import 'package:douyin_desktop/core/cookie_db.dart';

Future<void> main(List<String> args) async {
  final dir = args.isEmpty ? '' : args.first;
  final read = await readCookiesFromProfile(
      dir.isEmpty ? Platform.environment['APPDATA']! + r'\douyin_desktop\browser_profile' : dir);
  stdout.writeln('profile = ${read.profileDir}');
  stdout.writeln('db      = ${read.dbPath}');
  stdout.writeln('rows    = ${read.rows}  encrypted=${read.encryptedRows}  '
      'v20=${read.v20Rows}  failed=${read.decryptFailed}  expired=${read.expiredRows}');
  stdout.writeln('keyNote = ${read.keyNote}');
  stdout.writeln('error   = ${read.error}');
  stdout.writeln('summary = ${read.summary()}');
  stdout.writeln('names   = ${read.cookies.map((c) => c['name']).take(40).join(',')}');
  final session = read.cookies.where((c) =>
      const {'sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt'}
          .contains((c['name'] ?? '').toString()));
  stdout.writeln('hash session cookies = ${session.length}');
}
