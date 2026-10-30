/// Sync through PostgreSQL, when it's turned on in Settings: the desktop app's sync.py, against
/// the same tables. Every device keeps its own kaiji.db and works without the server; their
/// changes meet in the server's copy.
///
/// Here, triggers (store.dart's syncSchema) note every change in sync_changes. A round pushes those
/// rows to the server, then pulls what other devices pushed since the last round. On the server
/// each row keeps the version it was last written at and a deleted flag, so "since the last round"
/// is "version > cursor". When two devices change the same row, the last push wins.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleListener, ChangeNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'store.dart';

const schemaVersion = 1;
const _lock = 0x6B61696A69; // "kaiji": writers take turns, so versions commit in order

/// What a device sends of each table, its key first; categories go before what refers to them.
const columns = {
  'categories': ['uid', 'kind', 'name', 'icon', 'position'],
  'rules': ['uid', 'kind', 'amount', 'category_uid', 'note', 'freq', 'every', 'start', 'until', 'times', 'skips'],
  'entries': ['uid', 'day', 'kind', 'amount', 'category_uid', 'note', 'created'],
  'meta': ['key', 'value'],
};

final serverSchema = [
  'CREATE SEQUENCE IF NOT EXISTS kaiji.version',
  'CREATE TABLE IF NOT EXISTS kaiji.info (key text PRIMARY KEY, value text NOT NULL)',
  'CREATE TABLE IF NOT EXISTS kaiji.categories (uid text PRIMARY KEY, kind text NOT NULL, '
      'name text NOT NULL, icon text NOT NULL, position integer NOT NULL DEFAULT 0, '
      'version bigint NOT NULL, deleted boolean NOT NULL DEFAULT false)',
  'CREATE TABLE IF NOT EXISTS kaiji.rules (uid text PRIMARY KEY, kind text NOT NULL, '
      "amount bigint NOT NULL, category_uid text, note text NOT NULL DEFAULT '', "
      'freq text NOT NULL, every integer NOT NULL DEFAULT 1, start text NOT NULL, until text, '
      "times integer, skips text[] NOT NULL DEFAULT '{}', version bigint NOT NULL, "
      'deleted boolean NOT NULL DEFAULT false)',
  'CREATE TABLE IF NOT EXISTS kaiji.entries (uid text PRIMARY KEY, day text NOT NULL, '
      'kind text NOT NULL, amount bigint NOT NULL, category_uid text, '
      "note text NOT NULL DEFAULT '', created text NOT NULL, version bigint NOT NULL, "
      'deleted boolean NOT NULL DEFAULT false)',
  'CREATE TABLE IF NOT EXISTS kaiji.meta (key text PRIMARY KEY, value text, '
      'version bigint NOT NULL, deleted boolean NOT NULL DEFAULT false)',
  for (final table in columns.keys) 'CREATE INDEX IF NOT EXISTS ${table}_version ON kaiji.$table (version)',
  "INSERT INTO kaiji.info VALUES ('schema_version', '$schemaVersion') ON CONFLICT (key) DO NOTHING",
];

// the server's type of each column a device sends (every other one is text)
const _types = {'position': Type.integer, 'every': Type.integer, 'times': Type.integer,
    'amount': Type.bigInteger, 'skips': Type.textArray};

/// Writes [count] rows of [table] in one statement: added, or changed if they're there.
String _upsert(String table, int count) {
  final cols = columns[table]!;
  final values = [
    for (var r = 0; r < count; r++)
      "(${[for (var c = 0; c < cols.length; c++) '\$${r * cols.length + c + 1}'].join(', ')}, nextval('kaiji.version'))",
  ];
  return 'INSERT INTO kaiji.$table (${cols.join(', ')}, version) VALUES ${values.join(', ')} '
      'ON CONFLICT (${cols.first}) DO UPDATE SET '
      '${[for (final c in cols.skip(1)) '$c = EXCLUDED.$c'].join(', ')}, version = EXCLUDED.version, deleted = false';
}

typedef SyncRow = Map<String, Object?>;
typedef SyncRows = Map<String, List<SyncRow>>;

/// Why a round didn't happen. [kind]: "offline" (the server can't be reached: try again later),
/// "denied" (the sign-in, the database or its rights need fixing), "newer" (a newer Kaiji set up
/// the server) or "failed".
class SyncError implements Exception {
  const SyncError(this.kind, this.message, [this.detail = '']);
  final String kind, message, detail;

  @override
  String toString() => message;
}

SyncError _error(Object e, String host) {
  if (e is SyncError) return e;
  if (e is ServerException) {
    final code = e.code ?? '', text = e.message;
    if (text.contains('pg_hba.conf')) {
      return SyncError('denied',
          "The server doesn't let this phone in: it needs a line for it in pg_hba.conf (see the README).", text);
    }
    if (code.startsWith('28')) return SyncError('denied', "The server didn't accept the user name and password.", text);
    if (code == '3D000') return SyncError('denied', "That database isn't on the server.", text);
    if (code == '42501') return SyncError('denied', "This user can't make Kaiji's tables in that database.", text);
    if (code.startsWith('57') || code.startsWith('08')) return SyncError('offline', "Can't reach $host.", text);
    return SyncError('failed', text);
  }
  if (e is PgException && e.message.contains('does not support SSL')) {
    return SyncError('denied',
        "The server doesn't take encrypted connections: turn off “Encrypted connection”, or set up TLS on the server.",
        e.message);
  }
  if (e is SocketException || e is TimeoutException || e is PgException) {
    return SyncError('offline', "Can't reach $host.", '$e');
  }
  return SyncError('failed', '$e');
}

/// Kaiji's tables on the server. [open] it, use it, [close] it: one connection.
class Remote {
  Remote(this.host, this.port, this.database, this.user, this.password,
      {this.tls = true, this.timeout = const Duration(seconds: 5)});
  final String host, database, user, password;
  final int port;
  final bool tls;
  final Duration timeout;
  late Connection _c;

  Future<void> open() async {
    try {
      _c = await Connection.open(
        Endpoint(host: host, port: port, database: database, username: user, password: password),
        // require: encrypted, without checking the certificate (a LAN server's is usually
        // self-signed); the password goes as SCRAM either way
        settings: ConnectionSettings(
          sslMode: tls ? SslMode.require : SslMode.disable,
          connectTimeout: timeout,
          queryTimeout: const Duration(seconds: 30),
          applicationName: 'Kaiji',
        ),
      );
    } catch (e) {
      throw _error(e, host);
    }
  }

  Future<void> close() => _c.close();

  Future<T> _tx<T>(Future<T> Function(TxSession s) work, {bool readOnly = false}) async {
    try {
      return await _c.runTx((s) async {
        if (!readOnly) await s.execute('SELECT pg_advisory_xact_lock($_lock)');
        return work(s);
      },
          // every table from one snapshot, so the cursor can't skip a row it didn't see
          settings: readOnly
              ? TransactionSettings(isolationLevel: IsolationLevel.repeatableRead, accessMode: AccessMode.readOnly)
              : null);
    } catch (e) {
      throw _error(e, host);
    }
  }

  /// Make Kaiji's tables if they aren't there. True if the server has no Kaiji data yet.
  Future<bool> prepare() => _tx((s) async {
        if ((await s.execute("SELECT to_regclass('kaiji.info')::text")).first.first == null) {
          if ((await s.execute("SELECT to_regnamespace('kaiji')::text")).first.first == null) {
            await s.execute('CREATE SCHEMA kaiji');
          }
          for (final statement in serverSchema) {
            await s.execute(statement);
          }
        }
        final version = await s.execute("SELECT value FROM kaiji.info WHERE key = 'schema_version'");
        if (int.parse(version.first.first as String) > schemaVersion) {
          throw const SyncError('newer', 'A newer Kaiji set up the server: update this one to sync.');
        }
        final found = await s.execute(
            'SELECT ${[for (final t in columns.keys) 'EXISTS (SELECT 1 FROM kaiji.$t WHERE NOT deleted)'].join(' OR ')}');
        return !(found.first.first as bool);
      });

  static TypedValue _value(String column, Object? v) => column == 'skips'
      ? TypedValue(Type.textArray, [...(v as List? ?? const []).cast<String>()])
      : TypedValue(_types[column] ?? Type.text, v);

  static Future<void> _write(TxSession s, String table, List<SyncRow> rows) async {
    final cols = columns[table]!;
    for (var i = 0; i < rows.length; i += 100) {
      final batch = rows.sublist(i, i + 100 < rows.length ? i + 100 : rows.length);
      await s.execute(_upsert(table, batch.length), parameters: [
        for (final r in batch)
          for (final c in cols) _value(c, r[c]),
      ]);
    }
  }

  /// Write {table: (rows, keys of deleted rows)}.
  Future<void> push(Map<String, (List<SyncRow>, List<String>)> changes) async {
    if (changes.isEmpty) return;
    await _tx((s) async {
      for (final table in columns.keys) {
        final (rows, gone) = changes[table] ?? (const <SyncRow>[], const <String>[]);
        await _write(s, table, rows);
        if (gone.isNotEmpty) {
          await s.execute(
              "UPDATE kaiji.$table SET deleted = true, version = nextval('kaiji.version') "
              'WHERE ${columns[table]!.first} = ANY(\$1::text[]) AND NOT deleted',
              parameters: [TypedValue(Type.textArray, gone)]);
        }
      }
    });
  }

  /// ({table: rows written after version [cursor], deleted ones too}, the next cursor).
  Future<(SyncRows, int)> pull([int cursor = 0]) async {
    final found = await _tx((s) async {
      final out = <String, List<SyncRow>>{};
      for (final MapEntry(key: table, value: cols) in columns.entries) {
        final names = [...cols, 'deleted', 'version'];
        final result = await s.execute('SELECT ${names.join(', ')} FROM kaiji.$table WHERE version > \$1 ORDER BY version',
            parameters: [TypedValue(Type.bigInteger, cursor)]);
        out[table] = [
          for (final r in result) {for (var i = 0; i < names.length; i++) names[i]: r[i]},
        ];
      }
      return out;
    }, readOnly: true);
    var top = cursor;
    for (final rows in found.values) {
      for (final r in rows) {
        if ((r['version'] as int) > top) top = r['version'] as int;
      }
    }
    return (found, top);
  }

  /// Everything that isn't deleted, and the cursor after it.
  Future<(SyncRows, int)> everything() async {
    final (found, top) = await pull();
    return ({for (final e in found.entries) e.key: [for (final r in e.value) if (r['deleted'] != true) r]}, top);
  }

  /// Make the server's data [rows], this device's; returns the cursor after it.
  Future<int> replace(SyncRows rows) => _tx((s) async {
        for (final MapEntry(key: table, value: cols) in columns.entries) {
          final mine = rows[table] ?? const [];
          await s.execute(
              "UPDATE kaiji.$table SET deleted = true, version = nextval('kaiji.version') "
              'WHERE NOT deleted AND NOT (${cols.first} = ANY(\$1::text[]))',
              parameters: [TypedValue(Type.textArray, [for (final r in mine) r[cols.first] as String])]);
          await _write(s, table, mine);
        }
        final top = await s.execute(
            'SELECT GREATEST(${[for (final t in columns.keys) '(SELECT MAX(version) FROM kaiji.$t)'].join(', ')})');
        return top.first.first as int? ?? 0;
      });
}

// ---- this device's side: kaiji.db

const _read = {
  'categories': 'SELECT uid, kind, name, icon, position FROM categories',
  'rules': 'SELECT r.uid AS uid, r.kind AS kind, r.amount AS amount, c.uid AS category_uid, r.note AS note, '
      'r.freq AS freq, r.every AS every, r.start AS start, r.until AS until, r.times AS times, r.id AS id '
      'FROM rules r LEFT JOIN categories c ON c.id = r.category_id',
  'entries': 'SELECT e.uid AS uid, e.day AS day, e.kind AS kind, e.amount AS amount, c.uid AS category_uid, '
      'e.note AS note, e.created AS created FROM entries e LEFT JOIN categories c ON c.id = e.category_id',
  'meta': 'SELECT key, value FROM meta',
};
const _key = {'categories': 'uid', 'rules': 'r.uid', 'entries': 'e.uid', 'meta': 'key'};

/// This device's rows of [table] in [columns]' terms; only those with the given keys if any.
Future<List<SyncRow>> _rows(DatabaseExecutor db, String table, [List<String>? keys]) async {
  final found = <SyncRow>[];
  if (keys == null) {
    found.addAll(await db.rawQuery(_read[table]!));
  } else {
    for (var i = 0; i < keys.length; i += 500) {
      final chunk = keys.sublist(i, i + 500 > keys.length ? keys.length : i + 500);
      found.addAll(await db.rawQuery(
          '${_read[table]} WHERE ${_key[table]} IN (${List.filled(chunk.length, '?').join(', ')})', chunk));
    }
  }
  Map<int, List<String>> skips = {};
  if (table == 'rules') {
    for (final r in await db.rawQuery('SELECT rule_id, day FROM skips ORDER BY day')) {
      skips.putIfAbsent(r['rule_id'] as int, () => []).add(r['day'] as String);
    }
  }
  return [
    for (final r in found)
      {
        for (final c in columns[table]!) c: c == 'skips' ? skips[r['id']] ?? <String>[] : r[c],
      },
  ];
}

Future<String?> syncState(DatabaseExecutor db, String key) async =>
    (await db.query('sync_state', where: 'key = ?', whereArgs: [key])).firstOrNull?['value'] as String?;

Future<void> setSyncState(DatabaseExecutor db, String key, Object? value) async {
  if (value == null) {
    await db.delete('sync_state', where: 'key = ?', whereArgs: [key]);
  } else {
    await db.insert('sync_state', {'key': key, 'value': '$value'}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

/// Forget what was synced: the next round starts as a device's first.
Future<void> reset(Database db) => db.transaction((t) async {
      await t.delete('sync_state');
      await t.delete('sync_changes');
    });

/// Whether there's anything here to lose: entries or repeating entries.
Future<bool> hasOwnData(DatabaseExecutor db) async =>
    (await db.rawQuery('SELECT EXISTS (SELECT 1 FROM entries) OR EXISTS (SELECT 1 FROM rules) AS has'))
        .first['has'] ==
    1;

Future<int> waiting(DatabaseExecutor db) async =>
    (await db.rawQuery('SELECT COUNT(*) AS n FROM sync_changes')).first['n'] as int;

Future<DateTime?> lastSync(DatabaseExecutor db) async {
  final stamp = await syncState(db, 'last_sync');
  return stamp != null ? DateTime.parse(stamp) : null;
}

Future<int> _lastSeq(DatabaseExecutor db) async =>
    (await db.rawQuery('SELECT COALESCE(MAX(seq), 0) AS s FROM sync_changes')).first['s'] as int;

Future<SyncRows> snapshot(DatabaseExecutor db) async => {for (final table in columns.keys) table: await _rows(db, table)};

/// (the last change's seq, {table: (rows, keys of deleted rows)}) of what isn't pushed yet.
Future<(int, Map<String, (List<SyncRow>, List<String>)>)> pending(DatabaseExecutor db) async {
  final noted = await db.rawQuery('SELECT seq, tbl, uid FROM sync_changes ORDER BY seq');
  final changes = <String, (List<SyncRow>, List<String>)>{};
  for (final table in columns.keys) {
    final keys = {for (final n in noted) if (n['tbl'] == table) n['uid'] as String};
    if (keys.isNotEmpty) {
      final rows = await _rows(db, table, keys.toList());
      final present = {for (final r in rows) r[columns[table]!.first]};
      changes[table] = (rows, ([for (final k in keys) if (!present.contains(k)) k]..sort()));
    }
  }
  return (noted.isEmpty ? 0 : noted.last['seq'] as int, changes);
}

Future<int?> _categoryId(DatabaseExecutor db, Object? uid) async => uid == null
    ? null
    : (await db.query('categories', columns: ['id'], where: 'uid = ?', whereArgs: [uid])).firstOrNull?['id'] as int?;

/// Give the row with this uid these values, adding it if it isn't here. True if anything changed.
Future<bool> _put(DatabaseExecutor db, String table, Object? uid, Map<String, Object?> values) async {
  final sets = [for (final c in values.keys) '$c = ?'].join(', ');
  final differs = [for (final c in values.keys) '$c IS NOT ?'].join(' OR ');
  final v = values.values.toList();
  if (await db.rawUpdate('UPDATE $table SET $sets WHERE uid = ? AND ($differs)', [...v, uid, ...v]) > 0) {
    return true;
  }
  if ((await db.query(table, columns: ['1'], where: 'uid = ?', whereArgs: [uid])).isNotEmpty) return false;
  await db.insert(table, {...values, 'uid': uid});
  return true;
}

Future<bool> _applyCategory(DatabaseExecutor db, SyncRow row) async {
  if (row['deleted'] == true) {
    final id = await _categoryId(db, row['uid']);
    if (id == null) return false;
    for (final table in ['entries', 'rules']) {
      // so a new category can't take over the id
      await db.update(table, {'category_id': null}, where: 'category_id = ?', whereArgs: [id]);
    }
    await db.delete('categories', where: 'id = ?', whereArgs: [id]);
    return true;
  }
  return _put(db, 'categories', row['uid'], {for (final c in ['kind', 'name', 'icon', 'position']) c: row[c]});
}

Future<bool> _applyRule(DatabaseExecutor db, SyncRow row) async {
  final found = (await db.query('rules', columns: ['id'], where: 'uid = ?', whereArgs: [row['uid']])).firstOrNull;
  if (row['deleted'] == true) {
    if (found == null) return false;
    await db.delete('skips', where: 'rule_id = ?', whereArgs: [found['id']]);
    await db.delete('rules', where: 'id = ?', whereArgs: [found['id']]);
    return true;
  }
  var changed = await _put(db, 'rules', row['uid'], {
    for (final c in ['kind', 'amount', 'note', 'freq', 'every', 'start', 'until', 'times']) c: row[c],
    'category_id': await _categoryId(db, row['category_uid']),
  });
  final ruleId = (await db.query('rules', columns: ['id'], where: 'uid = ?', whereArgs: [row['uid']])).first['id'];
  final have = {
    for (final s in await db.query('skips', columns: ['day'], where: 'rule_id = ?', whereArgs: [ruleId]))
      s['day'] as String,
  };
  final want = {...(row['skips'] as List? ?? const []).cast<String>()};
  if (have.length != want.length || !have.containsAll(want)) {
    await db.delete('skips', where: 'rule_id = ?', whereArgs: [ruleId]);
    for (final day in want.toList()..sort()) {
      await db.insert('skips', {'rule_id': ruleId, 'day': day});
    }
    changed = true;
  }
  return changed;
}

Future<bool> _applyEntry(DatabaseExecutor db, SyncRow row) async {
  if (row['deleted'] == true) return await db.delete('entries', where: 'uid = ?', whereArgs: [row['uid']]) > 0;
  return _put(db, 'entries', row['uid'], {
    for (final c in ['day', 'kind', 'amount', 'note', 'created']) c: row[c],
    'category_id': await _categoryId(db, row['category_uid']),
  });
}

Future<bool> _applyMeta(DatabaseExecutor db, SyncRow row) async {
  if (row['deleted'] == true) return await db.delete('meta', where: 'key = ?', whereArgs: [row['key']]) > 0;
  if (await db.rawUpdate('UPDATE meta SET value = ? WHERE key = ? AND value IS NOT ?',
          [row['value'], row['key'], row['value']]) >
      0) {
    return true;
  }
  if ((await db.query('meta', where: 'key = ?', whereArgs: [row['key']])).isNotEmpty) return false;
  await db.insert('meta', {'key': row['key'], 'value': row['value']});
  return true;
}

const _apply = {'categories': _applyCategory, 'rules': _applyRule, 'entries': _applyEntry, 'meta': _applyMeta};

Future<void> _synced(DatabaseExecutor db, int cursor) async {
  await setSyncState(db, 'cursor', cursor);
  await setSyncState(db, 'first', null);
  await setSyncState(db, 'last_sync', DateTime.now().toIso8601String().substring(0, 19));
}

/// Write what the server sent, after the changes up to seq [pushed] went up. SyncRows changed here
/// meanwhile are left alone: they go up next round and win. True if anything changed.
Future<bool> apply(Database db, SyncRows rows, int pushed, int cursor) => db.transaction((t) async {
      var changed = false;
      await t.delete('sync_changes', where: 'seq <= ?', whereArgs: [pushed]);
      final mine = {for (final n in await t.query('sync_changes')) '${n['tbl']}\n${n['uid']}'};
      final before = await _lastSeq(t);
      for (final MapEntry(key: table, value: cols) in columns.entries) {
        for (final row in rows[table] ?? const <SyncRow>[]) {
          if (!mine.contains('$table\n${row[cols.first]}')) changed = await _apply[table]!(t, row) || changed;
        }
      }
      await t.delete('sync_changes', where: 'seq > ?', whereArgs: [before]); // the triggers' notes
      await _synced(t, cursor);
      return changed;
    });

/// Replace everything here with the server's rows (a device's first sync). In batches: years of
/// entries row by row would take a while on a phone.
Future<void> take(Database db, SyncRows rows, int cursor) => db.transaction((t) async {
      for (final table in ['skips', 'entries', 'rules', 'categories', 'meta']) {
        await t.delete(table);
      }
      Map<String, Object?> pick(SyncRow r, List<String> names) => {for (final c in names) c: r[c]};
      final first = t.batch();
      for (final r in rows['categories'] ?? const <SyncRow>[]) {
        first.insert('categories', pick(r, ['uid', 'kind', 'name', 'icon', 'position']));
      }
      for (final r in rows['meta'] ?? const <SyncRow>[]) {
        first.insert('meta', pick(r, ['key', 'value']));
      }
      await first.commit(noResult: true);
      final categoryIds = {for (final c in await t.query('categories', columns: ['id', 'uid'])) c['uid']: c['id']};
      final second = t.batch();
      for (final r in rows['rules'] ?? const <SyncRow>[]) {
        second.insert('rules', {
          ...pick(r, ['uid', 'kind', 'amount', 'note', 'freq', 'every', 'start', 'until', 'times']),
          'category_id': categoryIds[r['category_uid']],
        });
      }
      for (final r in rows['entries'] ?? const <SyncRow>[]) {
        second.insert('entries', {
          ...pick(r, ['uid', 'day', 'kind', 'amount', 'note', 'created']),
          'category_id': categoryIds[r['category_uid']],
        });
      }
      await second.commit(noResult: true);
      final ruleIds = {for (final x in await t.query('rules', columns: ['id', 'uid'])) x['uid']: x['id']};
      final third = t.batch();
      for (final r in rows['rules'] ?? const <SyncRow>[]) {
        for (final day in (r['skips'] as List? ?? const []).toSet()) {
          third.insert('skips', {'rule_id': ruleIds[r['uid']], 'day': day});
        }
      }
      await third.commit(noResult: true);
      await t.delete('sync_changes');
      await _synced(t, cursor);
    });

// ---- a round: the local part, the network part, the local part

/// What the next round does, with what it sends.
class Job {
  Job(this.kind, {this.seq = 0, this.rows = const {}, this.changes = const {}, this.cursor = 0});
  final String kind; // "take", "replace" or "sync"
  final int seq, cursor;
  final SyncRows rows;
  final Map<String, (List<SyncRow>, List<String>)> changes;
}

Future<Job> job(Database db) async {
  final first = await syncState(db, 'first');
  if (first == 'take') return Job('take');
  if (first == 'replace') return Job('replace', seq: await _lastSeq(db), rows: await snapshot(db));
  final (seq, changes) = await pending(db);
  return Job('sync', seq: seq, changes: changes, cursor: int.parse(await syncState(db, 'cursor') ?? '0'));
}

/// The network part, on an open [Remote]: (rows to apply, the next cursor).
Future<(SyncRows, int)> exchange(Remote server, Job todo) async {
  if (todo.kind == 'take') return server.everything();
  if (todo.kind == 'replace') return (<String, List<SyncRow>>{}, await server.replace(todo.rows));
  await server.push(todo.changes);
  return server.pull(todo.cursor);
}

/// True if this device's data changed.
Future<bool> finish(Database db, Job todo, SyncRows rows, int cursor) async {
  if (todo.kind == 'take') {
    await take(db, rows, cursor);
    return true;
  }
  return apply(db, rows, todo.seq, cursor);
}

/// A whole round on an open [Remote], here and now.
Future<bool> run(Database db, Remote server) async {
  final todo = await job(db);
  final (rows, cursor) = await exchange(server, todo);
  return finish(db, todo, rows, cursor);
}

/// Where to sync, kept on the phone (the password in the Android Keystore, through
/// flutter_secure_storage; never in kaiji.db, so not in backups).
class SyncSettings {
  const SyncSettings({
    required this.host,
    this.port = 5432,
    this.database = 'kaiji',
    this.user = 'kaiji',
    this.tls = true,
  });
  final String host, database, user;
  final int port;
  final bool tls;

  static SyncSettings of(SharedPreferences prefs) => SyncSettings(
        host: prefs.getString('sync_host') ?? '',
        port: prefs.getInt('sync_port') ?? 5432,
        database: prefs.getString('sync_database') ?? 'kaiji',
        user: prefs.getString('sync_user') ?? 'kaiji',
        tls: prefs.getBool('sync_tls') ?? true,
      );

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString('sync_host', host);
    await prefs.setInt('sync_port', port);
    await prefs.setString('sync_database', database);
    await prefs.setString('sync_user', user);
    await prefs.setBool('sync_tls', tls);
  }

  bool sameServer(SyncSettings o) => host == o.host && port == o.port && database == o.database;

  Remote remote(String password, {Duration timeout = const Duration(seconds: 5)}) =>
      Remote(host, port, database, user, password, tls: tls, timeout: timeout);
}

const _password = 'sync_password';

/// Runs rounds while sync is on: when Kaiji starts or comes back to the front, a couple of seconds
/// after each change, every minute while it's open, and once more as it goes to the background.
class Syncer extends ChangeNotifier {
  Syncer({required this.store, required this.prefs, required this.onChanged, FlutterSecureStorage? secrets})
      : secrets = secrets ?? const FlutterSecureStorage();

  final Store store;
  final SharedPreferences prefs;
  final Future<void> Function() onChanged; // reload after another device's changes came in
  final FlutterSecureStorage secrets;
  void Function(String message)? onReport; // shows a message once

  String state = 'off'; // "off", "on", "offline" or "stopped"
  SyncError? error;
  bool busy = false;
  DateTime? last;
  int waitingChanges = 0;
  bool _manual = false, _again = false, _prepared = false;
  int _round = 0; // what a round finds changed is dropped after a stop
  Future<void>? _running;
  Timer? _timer, _later;
  AppLifecycleListener? _lifecycle;

  bool get enabled => prefs.getBool('sync') ?? false;
  SyncSettings get settings => SyncSettings.of(prefs);

  Future<String> password() async => await secrets.read(key: _password) ?? '';

  Future<void> start() async {
    _round++;
    state = 'on';
    error = null;
    busy = _prepared = false;
    last = await lastSync(store.db);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => sync());
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(minutes: 1), (_) => sync());
        sync();
      },
      onPause: () {
        _timer?.cancel();
        sync(); // what was just entered goes up before Android may close the app
      },
    );
    unawaited(sync());
  }

  /// Stop, after any round under way (its result is dropped).
  Future<void> stop() async {
    _round++;
    state = 'off';
    _timer?.cancel();
    _later?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
    await _running;
    error = null;
    busy = false;
    notifyListeners();
  }

  /// Something changed here: a round in a moment (changes in a row go up together).
  void soon() {
    if (state != 'on' && state != 'offline') return;
    _later?.cancel();
    _later = Timer(const Duration(seconds: 2), sync);
  }

  Future<void> sync({bool manual = false}) async {
    if (state == 'off' || (state == 'stopped' && !manual)) return;
    _manual = _manual || manual;
    if (busy) {
      _again = true;
      return;
    }
    _later?.cancel();
    busy = true;
    _again = false;
    notifyListeners();
    final run = _roundTrip(_round);
    _running = run;
    await run;
  }

  Future<void> _roundTrip(int round) async {
    Object result;
    Job? todo;
    var prepared = false;
    try {
      todo = await job(store.db);
      final server = settings.remote(await password());
      await server.open();
      try {
        if (!_prepared) {
          await server.prepare();
          prepared = true;
        }
        result = await exchange(server, todo);
      } finally {
        await server.close();
      }
    } on SyncError catch (e) {
      result = e;
    } catch (e) {
      result = SyncError('failed', '$e');
    }
    if (round != _round) return;
    busy = false;
    final manual = _manual;
    _manual = false;
    if (result is SyncError) {
      final before = state;
      error = result;
      if (result.kind == 'offline') {
        state = 'offline';
        if (manual) onReport?.call("Couldn't sync: ${result.message}");
      } else {
        // no point trying every minute until the settings or the server change
        state = 'stopped';
        _timer?.cancel();
        if (before != 'stopped' || manual) onReport?.call('Sync stopped: ${result.message}');
      }
    } else {
      _prepared = _prepared || prepared;
      if (state == 'stopped') _timer = Timer.periodic(const Duration(minutes: 1), (_) => sync());
      state = 'on';
      error = null;
      final (rows, cursor) = result as (SyncRows, int);
      if (await finish(store.db, todo!, rows, cursor)) await onChanged();
      last = await lastSync(store.db);
      if (manual) onReport?.call('Synced with ${settings.host}');
    }
    waitingChanges = await waiting(store.db);
    notifyListeners();
    if (_again) unawaited(sync());
  }

  /// The status line in Settings.
  String describe() {
    final host = settings.host;
    switch (state) {
      case 'off':
        return 'Off: your data is only on this phone';
      case 'stopped':
        return 'Stopped: ${error?.message} Fix it in Sync, or try Sync now.';
      case 'offline':
        final n = waitingChanges;
        return "Can't reach $host right now, trying again every minute."
            '${n > 0 ? ' $n ${n == 1 ? 'change waits' : 'changes wait'} to go up.' : ''}';
    }
    final at = last;
    if (at == null) return 'Connecting to $host…';
    final now = DateTime.now();
    final time = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    return 'Synced with $host ${sameDay ? 'at $time' : 'on ${at.year}/${at.month.toString().padLeft(2, '0')}/'
        '${at.day.toString().padLeft(2, '0')} at $time'}';
  }

  /// Turn sync on with these settings. [first]: "take" (this phone gets the server's data),
  /// "replace" (the server gets this phone's), or null to carry on where it was (the same
  /// server, a new password say).
  Future<void> turnOn(SyncSettings s, String password, String? first) async {
    await stop();
    await secrets.write(key: _password, value: password);
    await s.save(prefs);
    await prefs.setBool('sync', true);
    if (first != null) {
      await reset(store.db);
      await setSyncState(store.db, 'first', first);
    }
    await start();
  }

  /// Back to this phone only; its data stays as it is.
  Future<void> turnOff() async {
    await stop();
    await prefs.setBool('sync', false);
    await secrets.delete(key: _password);
    await reset(store.db);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _later?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
