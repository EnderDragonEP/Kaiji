// Sync: two devices and a server, as in the PC's tests/test_sync.py. They run against an
// in-memory server, and against PostgreSQL too when KAIJI_TEST_PG has a connection string for a
// database made for testing - everything in its kaiji schema is deleted, e.g.
// KAIJI_TEST_PG="host=127.0.0.1 port=55432 dbname=kaiji user=kaiji password=..."
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaiji/src/dates.dart';
import 'package:kaiji/src/models.dart';
import 'package:kaiji/src/store.dart';
import 'package:kaiji/src/sync.dart' as sync;
import 'package:postgres/postgres.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The server's tables in memory, with [sync.Remote]'s methods.
class MemoryServer implements sync.Remote {
  final tables = {for (final t in sync.columns.keys) t: <String, sync.SyncRow>{}};
  var version = 0;

  @override
  String get host => 'memory';
  @override
  int get port => 0;
  @override
  String get database => '';
  @override
  String get user => '';
  @override
  String get password => '';
  @override
  bool get tls => false;
  @override
  Duration get timeout => Duration.zero;

  @override
  Future<void> open() async {}
  @override
  Future<void> close() async {}

  void _write(String table, List<sync.SyncRow> rows) {
    final cols = sync.columns[table]!;
    for (final r in rows) {
      tables[table]![r[cols.first] as String] = {
        for (final c in cols) c: c == 'skips' ? [...r[c] as List] : r[c],
        'deleted': false,
        'version': ++version,
      };
    }
  }

  void _drop(String table, Iterable<String> keys) {
    for (final k in keys) {
      final row = tables[table]![k];
      if (row != null && row['deleted'] != true) {
        row['deleted'] = true;
        row['version'] = ++version;
      }
    }
  }

  @override
  Future<bool> prepare() async => !tables.values.any((rows) => rows.values.any((r) => r['deleted'] != true));

  @override
  Future<void> push(Map<String, (List<sync.SyncRow>, List<String>)> changes) async {
    for (final table in sync.columns.keys) {
      final (rows, gone) = changes[table] ?? (const <sync.SyncRow>[], const <String>[]);
      _write(table, rows);
      _drop(table, gone);
    }
  }

  @override
  Future<(sync.SyncRows, int)> pull([int cursor = 0]) async {
    final found = {
      for (final e in tables.entries)
        e.key: [for (final r in e.value.values) if ((r['version'] as int) > cursor) {...r}]
          ..sort((a, b) => (a['version'] as int).compareTo(b['version'] as int)),
    };
    var top = cursor;
    for (final rows in found.values) {
      for (final r in rows) {
        if ((r['version'] as int) > top) top = r['version'] as int;
      }
    }
    return (found, top);
  }

  @override
  Future<(sync.SyncRows, int)> everything() async {
    final (found, top) = await pull();
    return ({for (final e in found.entries) e.key: [for (final r in e.value) if (r['deleted'] != true) r]}, top);
  }

  @override
  Future<int> replace(sync.SyncRows rows) async {
    for (final MapEntry(key: table, value: cols) in sync.columns.entries) {
      final mine = {for (final r in rows[table] ?? const <sync.SyncRow>[]) r[cols.first]};
      _drop(table, [for (final k in tables[table]!.keys) if (!mine.contains(k)) k]);
      _write(table, rows[table] ?? const []);
    }
    return version;
  }
}

Map<String, String> _conninfo(String s) => {
      for (final part in s.trim().split(RegExp(r'\s+')))
        if (part.contains('=')) part.substring(0, part.indexOf('=')): part.substring(part.indexOf('=') + 1),
    };

void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfiNoIsolate;
  final pg = Platform.environment['KAIJI_TEST_PG'];

  void scenarios(String name, sync.Remote Function() makeServer, {Future<void> Function()? fresh}) {
    group(name, () {
      late Directory dir;
      late Store pc, phone;
      late sync.Remote memory; // the server, whichever it is

      setUp(() async {
        dir = Directory.systemTemp.createTempSync('kaiji_sync_');
        pc = await Store.open(factory, '${dir.path}/pc.db');
        phone = await Store.open(factory, '${dir.path}/phone.db');
        memory = makeServer();
        await fresh?.call();
      });
      tearDown(() async {
        await pc.db.close();
        await phone.db.close();
        dir.deleteSync(recursive: true);
      });

      /// [work] on one connection to the server.
      Future<T> onServer<T>(Future<T> Function(sync.Remote server) work) async {
        await memory.open();
        try {
          return await work(memory);
        } finally {
          await memory.close();
        }
      }

      Future<bool> syncNow(Store store) => onServer((server) async {
            await server.prepare();
            return sync.run(store.db, server);
          });

      Future<bool> join(Store store, String first) async {
        await sync.reset(store.db);
        await sync.setSyncState(store.db, 'first', first);
        return syncNow(store);
      }

      Future<void> connectBoth() async {
        await join(pc, 'replace');
        await join(phone, 'take');
      }

      Future<int> food(Store store) async =>
          (await store.load()).categories.firstWhere((c) => c.kind == 'expense' && c.name == 'Food').id;

      Future<List<String>> entries(Store store) async {
        final d = await store.load();
        final cats = {for (final c in d.categories) c.id: c.name};
        return [for (final e in d.entries) '${iso(e.day)} ${e.kind} ${e.amount} ${cats[e.categoryId]} ${e.note}']
          ..sort();
      }

      Future<List<String>> notes(Store store) async {
        final d = await store.load();
        return [for (final e in [...d.entries]..sort((a, b) => a.day.compareTo(b.day))) e.note];
      }

      Future<List<String>> rules(Store store) async {
        final d = await store.load();
        final cats = {for (final c in d.categories) c.id: c.name};
        return [
          for (final r in d.rules)
            '${r.kind} ${r.amount} ${cats[r.categoryId]} ${r.note} ${r.freq} ${r.every} ${iso(r.start)} '
                '${r.until != null ? iso(r.until!) : '-'} ${r.times} ${[for (final s in r.skips) iso(s)]..sort()}',
        ]..sort();
      }

      Future<List<String>> categories(Store store) async =>
          [for (final c in (await store.load()).categories) '${c.kind} ${c.name} ${c.icon}'];

      Future<void> same() async {
        expect(await entries(pc), await entries(phone));
        expect(await rules(pc), await rules(phone));
        expect(await categories(pc), await categories(phone));
        final (a, b) = (await pc.load(), await phone.load());
        expect(a.plan, b.plan);
        expect((a.currency, a.decimals), (b.currency, b.decimals));
      }

      test('the first device fills the server and the next takes it', () async {
        expect(await onServer((s) => s.prepare()), isTrue);
        await pc.addEntry(ymd(2026, 10, 3), 'expense', 12050, await food(pc), 'Lunch');
        await phone.addEntry(ymd(2026, 10, 4), 'expense', 999, await food(phone), "Phone's own");
        expect(await sync.hasOwnData(phone.db), isTrue);
        await connectBoth();
        expect(await onServer((s) => s.prepare()), isFalse);
        await same();
        expect(await notes(phone), ['Lunch']);
        expect(await sync.waiting(pc.db), 0);
        expect(await sync.waiting(phone.db), 0);
      });

      test('replacing the server reaches the other devices', () async {
        await pc.addEntry(ymd(2026, 10, 3), 'expense', 12050, await food(pc), 'Lunch');
        await connectBoth();
        await phone.addEntry(ymd(2026, 10, 5), 'income', 500000, null, 'Pay');
        await pc.addEntry(ymd(2026, 10, 6), 'expense', 100, null, 'Only on the PC, not pushed');
        await join(phone, 'replace');
        await syncNow(pc);
        expect(await notes(pc), ['Lunch', 'Pay', 'Only on the PC, not pushed']);
        await syncNow(phone);
        await same();
      });

      test("a restored backup replaces everyone's data", () async {
        await pc.addEntry(ymd(2026, 10, 3), 'expense', 12050, await food(pc), 'Lunch');
        await connectBoth();
        final backup = '${dir.path}/backup.db';
        await pc.backupTo(backup);
        await pc.addEntry(ymd(2026, 10, 4), 'expense', 300, null, 'After the backup');
        await syncNow(pc);
        await syncNow(phone);
        expect((await notes(phone)).length, 2);
        await pc.restoreFrom(backup); // what KaijiState.restore() does
        await join(pc, 'replace');
        await syncNow(phone);
        expect(await notes(phone), ['Lunch']);
        await same();
      });

      test('entries added, edited and deleted on either side', () async {
        await connectBoth();
        final lunch = await pc.addEntry(ymd(2026, 10, 3), 'expense', 12050, await food(pc), 'Lunch');
        expect((await pc.load()).entries.single.id, lunch); // the id comes back as before
        await syncNow(pc);
        expect(await syncNow(pc), isFalse); // nothing new: nothing changes
        expect(await syncNow(phone), isTrue);
        await same();
        final mine = (await phone.load()).entries.single;
        await phone.updateEntry(mine.id, ymd(2026, 10, 4), 'expense', 13000, mine.categoryId, 'Dinner');
        await syncNow(phone);
        await syncNow(pc);
        expect(await entries(pc), ['2026-10-04 expense 13000 Food Dinner']);
        await pc.deleteEntry(lunch);
        await syncNow(pc);
        await syncNow(phone);
        expect((await phone.load()).entries, isEmpty);
        expect(await sync.waiting(phone.db), 0); // what came in isn't sent back
      });

      test('repeating entries and their skips', () async {
        await connectBoth();
        final rent = await pc.addRule('expense', 1800000, null, 'Rent', 'month', 1, ymd(2026, 1, 31),
            times: 12, skips: [ymd(2026, 2, 28)]);
        await syncNow(pc);
        await syncNow(phone);
        await same();
        final mine = (await phone.load()).rules.single;
        await phone.skip(mine.id, ymd(2026, 3, 31));
        await phone.unskip(mine.id, ymd(2026, 2, 28));
        await syncNow(phone);
        await syncNow(pc);
        expect((await pc.load()).rules.single.skips, {ymd(2026, 3, 31)});
        await pc.setRuleEnd(rent, until: ymd(2026, 6, 30));
        await syncNow(pc);
        await syncNow(phone);
        await same();
        await pc.deleteRule(rent);
        await syncNow(pc);
        await syncNow(phone);
        expect((await phone.load()).rules, isEmpty);
        expect(await phone.db.query('skips'), isEmpty);
      });

      test('the plan and the currency', () async {
        await connectBoth();
        await pc.setPlan(Plan(startBalance: 5000000, startDate: ymd(2026, 10, 1), savingsGoal: 300000, basis: 'balance'));
        await pc.setCurrency('NT\$', 0);
        await syncNow(pc);
        await syncNow(phone);
        await same();
        expect((await phone.load()).currency, 'NT\$');
      });

      test('categories, and deleting one in use', () async {
        await connectBoth();
        final snacks = await pc.addCategory('expense', 'Snacks', 'CAFE');
        await pc.addEntry(ymd(2026, 10, 3), 'expense', 500, snacks, 'Chips');
        final expenses = [for (final c in (await pc.load()).categories) if (c.kind == 'expense') c];
        await pc.moveCategory(expenses, snacks, -1);
        await syncNow(pc);
        await syncNow(phone);
        await same();
        final mine = (await phone.load()).categories.firstWhere((c) => c.name == 'Snacks');
        await phone.updateCategory(mine.id, 'Treats', 'GAME');
        await syncNow(phone);
        await syncNow(pc);
        await same();
        await pc.deleteCategory(snacks, await food(pc));
        await syncNow(pc);
        await syncNow(phone);
        await same();
        expect(await entries(phone), ['2026-10-03 expense 500 Food Chips']);
      });

      test('a change made during a round survives it', () async {
        final lunch = await pc.addEntry(ymd(2026, 10, 3), 'expense', 12050, null, 'Lunch');
        await connectBoth();
        final mine = (await phone.load()).entries.single;
        await pc.updateEntry(lunch, ymd(2026, 10, 3), 'expense', 12050, null, "PC's");
        await syncNow(pc);
        final todo = await sync.job(phone.db); // the phone's round starts...
        await phone.updateEntry(mine.id, ymd(2026, 10, 3), 'expense', 12050, null, "Phone's");
        final (rows, cursor) = await onServer((s) => sync.exchange(s, todo)); // ...the server sends the PC's edit...
        await sync.finish(phone.db, todo, rows, cursor);
        expect((await phone.load()).entries.single.note, "Phone's"); // ...which doesn't win
        await syncNow(phone);
        await syncNow(pc);
        expect((await pc.load()).entries.single.note, "Phone's");
      });

      test('the last push wins', () async {
        final lunch = await pc.addEntry(ymd(2026, 10, 3), 'expense', 12050, null, 'Lunch');
        await connectBoth();
        final mine = (await phone.load()).entries.single;
        await pc.updateEntry(lunch, ymd(2026, 10, 3), 'expense', 100, null, "PC's");
        await phone.updateEntry(mine.id, ymd(2026, 10, 3), 'expense', 200, null, "Phone's");
        await syncNow(pc);
        await syncNow(phone);
        await syncNow(pc);
        await same();
        expect((await pc.load()).entries.single.note, "Phone's");
      });
    });
  }

  scenarios('memory server', MemoryServer.new);

  if (pg != null) {
    final c = _conninfo(pg);
    sync.Remote server() => sync.Remote(
        c['host']!, int.parse(c['port'] ?? '5432'), c['dbname']!, c['user']!, c['password'] ?? '',
        tls: c['sslmode'] == 'require');
    scenarios('PostgreSQL', server, fresh: () async {
      final conn = await Connection.open(
          Endpoint(host: c['host']!, port: int.parse(c['port'] ?? '5432'), database: c['dbname']!,
              username: c['user'], password: c['password']),
          settings: ConnectionSettings(sslMode: c['sslmode'] == 'require' ? SslMode.require : SslMode.disable));
      await conn.execute('DROP SCHEMA IF EXISTS kaiji CASCADE');
      await conn.close();
    });

    test('PostgreSQL: a wrong password and an unreachable server are told apart', () async {
      final wrong = sync.Remote(c['host']!, int.parse(c['port'] ?? '5432'), c['dbname']!, c['user']!, 'wrong',
          tls: c['sslmode'] == 'require');
      await expectLater(wrong.open(), throwsA(isA<sync.SyncError>().having((e) => e.kind, 'kind', 'denied')));
      final away = sync.Remote('127.0.0.1', 1, 'kaiji', 'kaiji', '', tls: false, timeout: const Duration(seconds: 2));
      await expectLater(away.open(), throwsA(isA<sync.SyncError>().having((e) => e.kind, 'kind', 'offline')));
    });
  }

  group('the sync schema', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('kaiji_sync_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('every row has a uid, and changes are noted once each, newest last', () async {
      final store = await Store.open(factory, '${dir.path}/kaiji.db');
      expect(await store.db.rawQuery('SELECT 1 FROM categories WHERE uid IS NULL'), isEmpty);
      await sync.reset(store.db);
      final entry = await store.addEntry(ymd(2026, 10, 3), 'expense', 100, null, 'Tea');
      final rule = await store.addRule('expense', 100, null, 'Tea', 'week', 1, ymd(2026, 10, 1));
      Future<int> seq() async =>
          (await store.db.rawQuery("SELECT seq FROM sync_changes WHERE tbl = 'rules'")).single['seq'] as int;
      final before = await seq();
      await store.skip(rule, ymd(2026, 10, 8)); // fired by INSERT OR IGNORE: still a newer seq
      expect(await seq(), greaterThan(before));
      await store.skip(rule, ymd(2026, 10, 8)); // already skipped: nothing new to note
      await store.setPlan(const Plan(basis: 'balance')); // five meta rows
      final noted = await store.db.rawQuery('SELECT tbl FROM sync_changes ORDER BY seq');
      expect([for (final n in noted) n['tbl']], ['entries', 'rules', 'meta', 'meta', 'meta', 'meta', 'meta']);
      expect((await store.load()).entries.single.id, entry);
      await store.db.close();
    });

    test('a database from before sync gets uids', () async {
      final path = '${dir.path}/old.db';
      final old = await factory.openDatabase(path);
      for (final statement in [
        'CREATE TABLE categories (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, icon TEXT NOT NULL, '
            'position INTEGER NOT NULL DEFAULT 0)',
        'CREATE TABLE entries (id INTEGER PRIMARY KEY, day TEXT NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL, '
            "category_id INTEGER, note TEXT NOT NULL DEFAULT '', created TEXT NOT NULL)",
        'CREATE TABLE rules (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER NOT NULL, category_id INTEGER, '
            "note TEXT NOT NULL DEFAULT '', freq TEXT NOT NULL, every INTEGER NOT NULL DEFAULT 1, start TEXT NOT NULL, until TEXT)",
        'CREATE TABLE skips (rule_id INTEGER NOT NULL, day TEXT NOT NULL, PRIMARY KEY (rule_id, day))',
        'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)',
        "INSERT INTO categories (kind, name, icon) VALUES ('expense', 'Food', 'CAFE')",
        'INSERT INTO entries (day, kind, amount, category_id, note, created) VALUES '
            "('2026-01-02', 'expense', 100, 1, 'a', '2026-01-02T10:00:00'), ('2026-01-03', 'expense', 200, 1, 'b', '2026-01-03T10:00:00')",
      ]) {
        await old.execute(statement);
      }
      await old.close();
      final store = await Store.open(factory, path);
      for (final table in ['categories', 'entries']) {
        final uids = [for (final r in await store.db.query(table, columns: ['uid'])) r['uid'] as String?];
        expect(uids.every((u) => u != null && u.length == 32), isTrue);
        expect(uids.toSet().length, uids.length);
      }
      await store.db.close();
    });
  });
}
