import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaiji/src/app_state.dart';
import 'package:kaiji/src/dates.dart';
import 'package:kaiji/src/ledger.dart';
import 'package:kaiji/src/store.dart';
import 'package:kaiji/src/ui/actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late KaijiState state;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('kaiji_state_');
    SharedPreferences.setMockInitialValues({});
    state = await KaijiState.open(await Store.open(databaseFactoryFfiNoIsolate, '${dir.path}/kaiji.db'));
  });
  tearDown(() async {
    await state.store.db.close();
    dir.deleteSync(recursive: true);
  });

  EntryValues loan(DateTime day, {int amount = 100000, int? times}) => EntryValues(
      kind: 'expense', amount: amount, categoryId: null, day: day, note: 'Loan', freq: 'month', times: times);
  List<int> amounts() => [for (final i in state.ledger.items(ymd(2026, 1, 1), ymd(2028, 12, 31))) i.amount];

  test('changing a counted series from a date on keeps the number of payments', () async {
    await state.saveEntry(loan(ymd(2026, 1, 10), times: 12));
    final id = state.data.rules.single.id;
    // the 5th of 12 payments on: 8 left, at a new amount
    await state.changeFrom(id, loan(ymd(2026, 5, 10), amount: 120000, times: 8));
    expect([for (final r in state.data.rules) r.times], [4, 8]);
    expect(amounts(), [...List.filled(4, 100000), ...List.filled(8, 120000)]);
    expect(lastDate(state.data.rules.last), ymd(2026, 12, 10));
  });

  test('a skipped date stays skipped when the series changes from before it', () async {
    await state.saveEntry(loan(ymd(2026, 1, 10)));
    final id = state.data.rules.single.id;
    await state.skip(id, ymd(2026, 7, 10));
    await state.changeFrom(id, loan(ymd(2026, 3, 10), amount: 90000));
    expect(state.data.rules.last.skips, {ymd(2026, 7, 10)});
    expect(state.data.rules.first.until, ymd(2026, 3, 9));
  });

  test('stop after a date, and undo', () async {
    await state.saveEntry(loan(ymd(2026, 1, 10), times: 12));
    final id = state.data.rules.single.id;
    final undo = await state.stopAfter(id, ymd(2026, 3, 10));
    expect(amounts().length, 3);
    await undo();
    expect(amounts().length, 12);
  });

  test('one date edited on its own becomes an entry, the series skips it', () async {
    await state.saveEntry(loan(ymd(2026, 1, 10)));
    final id = state.data.rules.single.id;
    await state.editDate(id, ymd(2026, 2, 10),
        EntryValues(kind: 'expense', amount: 150000, categoryId: null, day: ymd(2026, 2, 12), note: 'Loan'));
    expect(state.data.rules.single.skips, {ymd(2026, 2, 10)});
    final feb = state.ledger.items(ymd(2026, 2, 1), ymd(2026, 2, 28)).single;
    expect((feb.day, feb.amount, feb.repeating), (ymd(2026, 2, 12), 150000, false));
  });

  test('deleting a repeating entry and undoing brings its skipped dates back', () async {
    await state.saveEntry(loan(ymd(2026, 1, 10), times: 6));
    final id = state.data.rules.single.id;
    await state.skip(id, ymd(2026, 2, 10));
    final undo = await state.deleteRule(id);
    expect(state.data.rules, isEmpty);
    await undo();
    final back = state.data.rules.single;
    expect(back.times, 6);
    expect(back.skips, {ymd(2026, 2, 10)});
  });

  test('an entry turned into a repeating one replaces it', () async {
    await state.saveEntry(
        EntryValues(kind: 'expense', amount: 39000, categoryId: null, day: ymd(2026, 3, 12), note: 'Netflix'));
    final entry = state.data.entries.single.id;
    await state.saveEntry(
        EntryValues(kind: 'expense', amount: 39000, categoryId: null, day: ymd(2026, 3, 12), note: 'Netflix', freq: 'month'),
        entryId: entry);
    expect(state.data.entries, isEmpty);
    expect(state.data.rules.single.note, 'Netflix');
  });

  test('CSV export has the desktop columns, quoting where needed', () async {
    final food = state.kindCategories('expense').first;
    await state.saveEntry(EntryValues(
        kind: 'expense', amount: 12050, categoryId: food.id, day: ymd(2026, 3, 2), note: 'Lunch, "the good one"'));
    await state.saveEntry(loan(ymd(2026, 3, 10), times: 2));
    expect(entriesCsv(state, ymd(2026, 3, 1), ymd(2026, 4, 30)).split('\r\n'), [
      'Date,Type,Category,Amount,Note,Repeats,Planned',
      '2026-03-02,Expense,${food.name},-120.50,"Lunch, ""the good one""",,',
      '2026-03-10,Expense,Uncategorized,-1000.00,Loan,Every month on the 10th,',
      '2026-04-10,Expense,Uncategorized,-1000.00,Loan,Every month on the 10th,',
      '',
    ]);
  });

  test('the category used most lately is the one offered first', () async {
    final cats = state.kindCategories('expense');
    for (final (i, c) in [(0, cats[2]), (1, cats[2]), (2, cats[1])]) {
      await state.saveEntry(
          EntryValues(kind: 'expense', amount: 100, categoryId: c.id, day: addDays(today(), -i), note: 'x$i'));
    }
    expect(state.usualCategory('expense'), cats[2].id);
    expect(state.notes()['x2'], ('expense', cats[1].id));
  });
}
