/// A few months of believable data around today, for the widget tests.
library;

import 'package:kaiji/src/dates.dart';
import 'package:kaiji/src/models.dart';
import 'package:kaiji/src/store.dart';

Future<void> fillSample(Store store) async {
  final now = today();
  final first = addMonths(ymd(now.year, now.month, 1), -1);
  final c = {for (final x in (await store.load()).categories) '${x.kind}:${x.name}': x.id};
  await store.setCurrency('NT\$', 0);
  await store.setPlan(Plan(startBalance: 3850000, startDate: first, savingsGoal: 500000, minBalance: 1000000));

  await store.addRule('income', 4800000, c['income:Salary'], 'Salary', 'month', 1, ymd(2026, 1, 5));
  await store.addRule('expense', 1600000, c['expense:Housing'], 'Rent', 'month', 1, ymd(2026, 1, 1));
  await store.addRule('expense', 59900, c['expense:Bills'], 'Phone bill', 'month', 1, ymd(2026, 1, 20));
  await store.addRule('expense', 39000, c['expense:Entertainment'], 'Netflix', 'month', 1, ymd(2026, 2, 12));
  await store.addRule('expense', 1250000, c['expense:Bills'], 'Insurance', 'year', 1, addMonths(addDays(now, 19), -12));
  await store.addRule('expense', 250000, c['expense:Shopping'], 'Laptop', 'month', 1, addMonths(addDays(now, -2), -4),
      times: 12);

  // day-to-day spending since the start, the same every run
  var seed = 7;
  int next(int n) => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n;
  for (var d = first; !d.isAfter(now); d = addDays(d, 1)) {
    await store.addEntry(d, 'expense', (90 + next(80)) * 100, c['expense:Food'], 'Lunch');
    if (next(3) == 0) await store.addEntry(d, 'expense', 6500, c['expense:Food'], 'Coffee');
    if (d.weekday <= 5) await store.addEntry(d, 'expense', (30 + next(30)) * 100, c['expense:Transport'], 'MRT');
    if (d.weekday == 6) await store.addEntry(d, 'expense', (900 + next(800)) * 100, c['expense:Food'], 'Groceries');
    if (next(13) == 0) await store.addEntry(d, 'expense', (300 + next(1500)) * 100, c['expense:Shopping'], 'Uniqlo');
    if (next(17) == 0) await store.addEntry(d, 'expense', (300 + next(900)) * 100, c['expense:Social & gifts'], 'Dinner with friends');
  }
  await store.addEntry(addDays(now, -9), 'income', 128000, c['income:Refunds'], 'Shoe refund');
  await store.addEntry(addDays(now, -15), 'expense', 168000, c['expense:Travel'], 'Train to Tainan');
}
