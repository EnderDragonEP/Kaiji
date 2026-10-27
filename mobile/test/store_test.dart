import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaiji/src/dates.dart';
import 'package:kaiji/src/ledger.dart';
import 'package:kaiji/src/models.dart';
import 'package:kaiji/src/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfiNoIsolate;
  late Directory dir;
  String file(String name) => '${dir.path}${Platform.pathSeparator}$name';

  setUp(() => dir = Directory.systemTemp.createTempSync('kaiji_store_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a new database has the default categories and the currency it was made with', () async {
    final store = await Store.open(factory, file('kaiji.db'), currency: ('NT\$', 0));
    final data = await store.load();
    expect(data.categories.map((c) => c.name), containsAll(['Food', 'Salary', 'Other']));
    expect(data.categories.length, defaultCategories.length);
    expect((data.currency, data.decimals), ('NT\$', 0));
    expect(data.plan, const Plan());
    await store.db.close();
  });

  test('entries, repeating entries and the plan come back as saved', () async {
    final store = await Store.open(factory, file('kaiji.db'));
    final food = (await store.load()).categories.firstWhere((c) => c.name == 'Food').id;
    await store.addEntry(ymd(2026, 10, 3), 'expense', 12050, food, 'Lunch');
    final rent = await store.addRule('expense', 1800000, null, 'Rent', 'month', 1, ymd(2026, 1, 31), times: 12);
    await store.skip(rent, ymd(2026, 2, 28));
    await store.setPlan(Plan(startBalance: 5000000, startDate: ymd(2026, 10, 1), savingsGoal: 300000, basis: 'balance'));

    final data = await store.load();
    final lunch = data.entries.single;
    expect((lunch.day, lunch.kind, lunch.amount, lunch.categoryId, lunch.note), (ymd(2026, 10, 3), 'expense', 12050, food, 'Lunch'));
    final rule = data.rules.single;
    expect((rule.freq, rule.every, rule.start, rule.times, rule.until), ('month', 1, ymd(2026, 1, 31), 12, null));
    expect(rule.skips, {ymd(2026, 2, 28)});
    expect(lastDate(rule), ymd(2026, 12, 31)); // a skipped date still counts toward the 12
    expect(data.plan, Plan(startBalance: 5000000, startDate: ymd(2026, 10, 1), savingsGoal: 300000, basis: 'balance'));

    await store.setRuleEnd(rent, until: ymd(2026, 6, 30));
    expect(((await store.load()).rules.single.until, (await store.load()).rules.single.times), (ymd(2026, 6, 30), null));
    await store.deleteRule(rent);
    expect(await store.db.query('skips'), isEmpty);
    await store.db.close();
  });

  test('categories reorder, and deleting one moves its entries', () async {
    final store = await Store.open(factory, file('kaiji.db'));
    List<Category> expenses(KaijiData d) => [for (final c in d.categories) if (c.kind == 'expense') c];
    final before = expenses(await store.load());
    final ids = [for (final c in before) c.id];
    await store.reorderCategories([ids.last, ...ids.take(ids.length - 1)]);
    expect(expenses(await store.load()).first.id, ids.last);

    final (food, transport) = (before[0].id, before[1].id);
    await store.addEntry(ymd(2026, 10, 1), 'expense', 100, food, '');
    await store.addRule('expense', 100, food, '', 'week', 1, ymd(2026, 10, 1));
    expect(await store.categoryUses(food), 2);
    await store.deleteCategory(food, transport);
    final data = await store.load();
    expect(data.entries.single.categoryId, transport);
    expect(data.rules.single.categoryId, transport);
    expect(data.categories.any((c) => c.id == food), isFalse);
    await store.db.close();
  });

  test("opens a database from the desktop app's first version and adds the newer columns", () async {
    final old = await factory.openDatabase(file('old.db'));
    for (final statement in [
      'CREATE TABLE categories (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, '
          'icon TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0)',
      'CREATE TABLE entries (id INTEGER PRIMARY KEY, day TEXT NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL, '
          "category_id INTEGER, note TEXT NOT NULL DEFAULT '', created TEXT NOT NULL)",
      'CREATE TABLE rules (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER NOT NULL, category_id INTEGER, '
          "note TEXT NOT NULL DEFAULT '', freq TEXT NOT NULL, every INTEGER NOT NULL DEFAULT 1, start TEXT NOT NULL, until TEXT)",
      'CREATE TABLE skips (rule_id INTEGER NOT NULL, day TEXT NOT NULL, PRIMARY KEY (rule_id, day))',
      'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)',
      "INSERT INTO categories VALUES (1, 'income', 'Salary', 'CERTIFICATE', 0)",
      "INSERT INTO rules VALUES (1, 'income', 4200000, 1, 'Pay', 'month', 1, '2026-01-05', NULL)",
      "INSERT INTO meta VALUES ('currency', 'NT\$'), ('decimals', '0'), ('start_balance', '1000000'), "
          "('start_date', '2026-01-01'), ('basis', 'income')",
    ]) {
      await old.execute(statement);
    }
    await old.close();

    final store = await Store.open(factory, file('old.db'));
    final data = await store.load();
    expect(data.categories.single.name, 'Salary'); // no default categories added on top
    expect((data.rules.single.note, data.rules.single.times), ('Pay', null));
    expect((data.currency, data.decimals, data.plan.startBalance), ('NT\$', 0, 1000000));
    await store.addRule('expense', 100, null, '', 'day', 1, ymd(2026, 1, 1), times: 3);
    expect((await store.load()).rules.last.times, 3);
    await store.db.close();
  });

  test('a backup restores everything as it was', () async {
    final store = await Store.open(factory, file('kaiji.db'), currency: ('€', 2));
    await store.addEntry(ymd(2026, 10, 1), 'expense', 1200, null, 'Lunch');
    await store.backupTo(file('backup.db'));
    await store.addEntry(ymd(2026, 10, 2), 'expense', 500, null, 'Coffee');
    await store.setCurrency('\$', 2);

    await store.restoreFrom(file('backup.db'));
    final data = await store.load();
    expect(data.entries.map((e) => e.note), ['Lunch']);
    expect(data.currency, '€');

    File(file('notes.txt')).writeAsStringSync('not a database');
    await expectLater(store.restoreFrom(file('notes.txt')), throwsFormatException);
    final other = await factory.openDatabase(file('other.db'));
    await other.execute('CREATE TABLE things (id INTEGER)');
    await other.close();
    await expectLater(store.restoreFrom(file('other.db')), throwsFormatException);
    expect((await store.load()).entries.map((e) => e.note), ['Lunch']); // still there
    await store.db.close();
  });
}
