/// SQLite storage with the desktop app's tables (store.py): entries, repeating rules with the
/// dates they skip, categories, and the plan and currency in `meta`. Days are YYYY-MM-DD text,
/// amounts integer cents. Because the tables match, a kaiji.db from the PC opens here and the
/// other way round.
library;

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';

import 'dates.dart';
import 'models.dart';

const _schema = [
  '''CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, icon TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY, day TEXT NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL,
    category_id INTEGER, note TEXT NOT NULL DEFAULT '', created TEXT NOT NULL, source TEXT)''',
  'CREATE INDEX IF NOT EXISTS entries_day ON entries (day)',
  '''CREATE TABLE IF NOT EXISTS rules (
    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER NOT NULL, category_id INTEGER,
    note TEXT NOT NULL DEFAULT '', freq TEXT NOT NULL, every INTEGER NOT NULL DEFAULT 1,
    start TEXT NOT NULL, until TEXT, times INTEGER, source TEXT)''',
  '''CREATE TABLE IF NOT EXISTS skips (rule_id INTEGER NOT NULL, day TEXT NOT NULL,
    PRIMARY KEY (rule_id, day))''',
  'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)',
];
const tables = {'categories', 'entries', 'rules', 'skips', 'meta'};
// columns added since the desktop app's first version
const _added = [('rules', 'times', 'INTEGER'), ('entries', 'source', 'TEXT'), ('rules', 'source', 'TEXT')];

const defaultCategories = [
  ('expense', 'Food', 'CAFE'), ('expense', 'Transport', 'BUS'),
  ('expense', 'Shopping', 'SHOPPING_CART'), ('expense', 'Housing', 'HOME'),
  ('expense', 'Bills', 'DOCUMENT'), ('expense', 'Entertainment', 'GAME'),
  ('expense', 'Health', 'HEART'), ('expense', 'Education', 'EDUCATION'),
  ('expense', 'Travel', 'AIRPLANE'), ('expense', 'Social & gifts', 'PEOPLE'),
  ('expense', 'Other', 'TAG'),
  ('income', 'Salary', 'CERTIFICATE'), ('income', 'Bonus', 'ASTERISK'),
  ('income', 'Investments', 'MARKET'), ('income', 'Side income', 'DEVELOPER_TOOLS'),
  ('income', 'Gifts', 'HEART'), ('income', 'Refunds', 'CANCEL'), ('income', 'Other', 'TAG'),
];

/// Everything in the database, loaded at once: a household's entries fit in memory easily, and
/// the screens then compute synchronously.
class KaijiData {
  const KaijiData(this.categories, this.entries, this.rules, this.plan, this.currency, this.decimals);
  final List<Category> categories;
  final List<Entry> entries;
  final List<Rule> rules;
  final Plan plan;
  final String currency;
  final int decimals;
}

String _now() => DateTime.now().toIso8601String().substring(0, 19);

class Store {
  Store._(this.factory, this.path, this.db);

  final DatabaseFactory factory;
  final String path;
  Database db;

  static Future<Store> open(DatabaseFactory factory, String path, {(String, int) currency = ('\$', 2)}) async {
    final store = Store._(factory, path, await factory.openDatabase(path));
    await store._prepare(currency);
    return store;
  }

  Future<void> _prepare((String, int) currency) async {
    await db.transaction((t) async {
      for (final statement in _schema) {
        await t.execute(statement);
      }
      for (final (table, column, kind) in _added) {
        final columns = await t.rawQuery('PRAGMA table_info($table)');
        if (!columns.any((c) => c['name'] == column)) {
          await t.execute('ALTER TABLE $table ADD COLUMN $column $kind');
        }
      }
      if ((await t.rawQuery('SELECT 1 FROM categories LIMIT 1')).isEmpty) {
        var position = 0;
        for (final (kind, name, icon) in defaultCategories) {
          await t.insert('categories', {'kind': kind, 'name': name, 'icon': icon, 'position': position++});
        }
      }
      if ((await t.query('meta', where: 'key = ?', whereArgs: ['currency'])).isEmpty) {
        await t.insert('meta', {'key': 'currency', 'value': currency.$1});
        await t.insert('meta', {'key': 'decimals', 'value': '${currency.$2}'});
      }
    });
  }

  Future<KaijiData> load() async {
    final meta = {
      for (final r in await db.query('meta')) r['key'] as String: r['value'] as String?,
    };
    int num(String key) => int.tryParse(meta[key] ?? '') ?? 0;
    final skips = <int, Set<DateTime>>{};
    for (final r in await db.query('skips')) {
      skips.putIfAbsent(r['rule_id'] as int, () => {}).add(parseIso(r['day'] as String)!);
    }
    return KaijiData(
      [
        for (final r in await db.query('categories', orderBy: 'kind, position, id'))
          Category(r['id'] as int, r['kind'] as String, r['name'] as String, r['icon'] as String,
              r['position'] as int),
      ],
      [
        for (final r in await db.query('entries', orderBy: 'day, id'))
          Entry(r['id'] as int, parseIso(r['day'] as String)!, r['kind'] as String, r['amount'] as int,
              r['category_id'] as int?, r['note'] as String? ?? ''),
      ],
      [
        for (final r in await db.query('rules', orderBy: 'id'))
          Rule(r['id'] as int, r['kind'] as String, r['amount'] as int, r['category_id'] as int?,
              r['note'] as String? ?? '', r['freq'] as String, r['every'] as int,
              parseIso(r['start'] as String)!,
              until: parseIso(r['until'] as String?), times: r['times'] as int?,
              skips: skips[r['id']] ?? const {}),
      ],
      Plan(
        startBalance: num('start_balance'),
        startDate: parseIso(meta['start_date']),
        savingsGoal: num('savings_goal'),
        minBalance: num('min_balance'),
        basis: meta['basis'] ?? 'income',
      ),
      meta['currency'] ?? '\$',
      meta['decimals'] == '0' ? 0 : 2,
    );
  }

  // ---- meta
  Future<void> _setMeta(DatabaseExecutor t, String key, Object value) =>
      t.insert('meta', {'key': key, 'value': '$value'}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setPlan(Plan p) => db.transaction((t) async {
        await _setMeta(t, 'start_balance', p.startBalance);
        await _setMeta(t, 'start_date', p.startDate != null ? iso(p.startDate!) : '');
        await _setMeta(t, 'savings_goal', p.savingsGoal);
        await _setMeta(t, 'min_balance', p.minBalance);
        await _setMeta(t, 'basis', p.basis);
      });

  Future<void> setCurrency(String symbol, int decimals) => db.transaction((t) async {
        await _setMeta(t, 'currency', symbol);
        await _setMeta(t, 'decimals', decimals);
      });

  // ---- categories
  Future<int> addCategory(String kind, String name, String icon) => db.transaction((t) async {
        final top = (await t.rawQuery(
                'SELECT COALESCE(MAX(position), -1) + 1 AS p FROM categories WHERE kind = ?', [kind]))
            .first['p'] as int;
        return t.insert('categories', {'kind': kind, 'name': name, 'icon': icon, 'position': top});
      });

  Future<void> updateCategory(int id, String name, String icon) =>
      db.update('categories', {'name': name, 'icon': icon}, where: 'id = ?', whereArgs: [id]);

  /// Swap with the neighbour above (step -1) or below (step 1) in its list.
  Future<void> moveCategory(List<Category> sameKind, int id, int step) async {
    final list = [...sameKind];
    final i = list.indexWhere((c) => c.id == id), j = i + step;
    if (i < 0 || j < 0 || j >= list.length) return;
    final c = list[i];
    list[i] = list[j];
    list[j] = c;
    await db.transaction((t) async {
      for (var p = 0; p < list.length; p++) {
        await t.update('categories', {'position': p}, where: 'id = ?', whereArgs: [list[p].id]);
      }
    });
  }

  /// A kind's categories in this order (after dragging them around).
  Future<void> reorderCategories(List<int> ids) => db.transaction((t) async {
        for (var p = 0; p < ids.length; p++) {
          await t.update('categories', {'position': p}, where: 'id = ?', whereArgs: [ids[p]]);
        }
      });

  Future<int> categoryUses(int id) async {
    final r = await db.rawQuery(
        'SELECT (SELECT COUNT(*) FROM entries WHERE category_id = ?) + '
        '(SELECT COUNT(*) FROM rules WHERE category_id = ?) AS n',
        [id, id]);
    return r.first['n'] as int;
  }

  /// Delete a category; its entries and repeating entries move to [moveTo].
  Future<void> deleteCategory(int id, int? moveTo) => db.transaction((t) async {
        for (final table in ['entries', 'rules']) {
          await t.update(table, {'category_id': moveTo}, where: 'category_id = ?', whereArgs: [id]);
        }
        await t.delete('categories', where: 'id = ?', whereArgs: [id]);
      });

  // ---- entries
  Future<int> addEntry(DateTime day, String kind, int amount, int? categoryId, String note) =>
      db.insert('entries', {
        'day': iso(day), 'kind': kind, 'amount': amount, 'category_id': categoryId, 'note': note,
        'created': _now(),
      });

  Future<void> updateEntry(int id, DateTime day, String kind, int amount, int? categoryId, String note) =>
      db.update('entries',
          {'day': iso(day), 'kind': kind, 'amount': amount, 'category_id': categoryId, 'note': note},
          where: 'id = ?', whereArgs: [id]);

  Future<void> deleteEntry(int id) => db.delete('entries', where: 'id = ?', whereArgs: [id]);

  // ---- repeating rules
  Map<String, Object?> _ruleRow(String kind, int amount, int? categoryId, String note, String freq,
          int every, DateTime start, DateTime? until, int? times) =>
      {
        'kind': kind, 'amount': amount, 'category_id': categoryId, 'note': note, 'freq': freq,
        'every': every, 'start': iso(start), 'until': until != null ? iso(until) : null,
        'times': times,
      };

  Future<int> addRule(String kind, int amount, int? categoryId, String note, String freq, int every,
          DateTime start, {DateTime? until, int? times, Iterable<DateTime> skips = const []}) =>
      db.transaction((t) async {
        final id = await t.insert('rules', _ruleRow(kind, amount, categoryId, note, freq, every, start, until, times));
        for (final d in skips) {
          await t.insert('skips', {'rule_id': id, 'day': iso(d)}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        return id;
      });

  Future<void> updateRule(int id, String kind, int amount, int? categoryId, String note, String freq,
          int every, DateTime start, {DateTime? until, int? times}) =>
      db.update('rules', _ruleRow(kind, amount, categoryId, note, freq, every, start, until, times),
          where: 'id = ?', whereArgs: [id]);

  Future<void> setRuleEnd(int id, {DateTime? until, int? times}) => db.update(
      'rules', {'until': until != null ? iso(until) : null, 'times': times},
      where: 'id = ?', whereArgs: [id]);

  Future<void> deleteRule(int id) => db.transaction((t) async {
        await t.delete('rules', where: 'id = ?', whereArgs: [id]);
        await t.delete('skips', where: 'rule_id = ?', whereArgs: [id]);
      });

  Future<void> skip(int ruleId, DateTime day) => db.insert('skips', {'rule_id': ruleId, 'day': iso(day)},
      conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> unskip(int ruleId, DateTime day) =>
      db.delete('skips', where: 'rule_id = ? AND day = ?', whereArgs: [ruleId, iso(day)]);

  // ---- files
  /// A consistent copy of the whole database at [target] (the PC's Kaiji restores it too).
  Future<void> backupTo(String target) async {
    final file = File(target);
    if (await file.exists()) await file.delete();
    try {
      await db.execute('VACUUM INTO ?', [target]);
    } on DatabaseException {
      // SQLite before 3.27 (Android 10 and older): fold any write-ahead log in, then copy the file
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await File(path).copy(target);
    }
  }

  /// Replace everything with the Kaiji database at [source]; FormatException if it isn't one.
  Future<void> restoreFrom(String source) async {
    final other = await factory.openDatabase(source, options: OpenDatabaseOptions(readOnly: true));
    try {
      final names = {
        for (final r in await other.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'"))
          r['name'] as String,
      };
      if (!names.containsAll(tables)) throw const FormatException("This file isn't a Kaiji backup.");
    } on DatabaseException {
      throw const FormatException("This file isn't a Kaiji backup.");
    } finally {
      await other.close();
    }
    await db.close();
    for (final leftover in ['-wal', '-shm', '-journal']) {
      final file = File(path + leftover); // would be replayed into the restored file
      if (await file.exists()) await file.delete();
    }
    await File(source).copy(path);
    db = await factory.openDatabase(path);
    await _prepare(('\$', 2));
  }
}
