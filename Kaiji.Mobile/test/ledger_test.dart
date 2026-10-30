// The desktop app's tests/test_ledger.py, case for case: the phone must work out the same.
import 'package:flutter_test/flutter_test.dart';
import 'package:kaiji/src/dates.dart';
import 'package:kaiji/src/ledger.dart';
import 'package:kaiji/src/models.dart';

DateTime d(int y, int m, int day) => ymd(y, m, day);

Rule rule(String freq, DateTime start,
        {int every = 1, DateTime? until, Set<DateTime> skips = const {}, int amount = 100,
        String kind = 'expense', int? times}) =>
    Rule(1, kind, amount, null, '', freq, every, start, until: until, times: times, skips: skips);

void main() {
  group('occurrences', () {
    test('monthly on the 31st', () {
      expect(occurrences(rule('month', d(2026, 1, 31)), d(2026, 1, 1), d(2026, 5, 31)),
          [d(2026, 1, 31), d(2026, 2, 28), d(2026, 3, 31), d(2026, 4, 30), d(2026, 5, 31)]);
    });

    test('yearly on Feb 29', () {
      expect(occurrences(rule('year', d(2024, 2, 29)), d(2024, 1, 1), d(2028, 12, 31)),
          [d(2024, 2, 29), d(2025, 2, 28), d(2026, 2, 28), d(2027, 2, 28), d(2028, 2, 29)]);
    });

    test('every two weeks inside a window', () {
      expect(occurrences(rule('week', d(2026, 1, 2), every: 2), d(2026, 1, 10), d(2026, 2, 13)),
          [d(2026, 1, 16), d(2026, 1, 30), d(2026, 2, 13)]);
    });

    test('quarterly, the window starting between dates', () {
      expect(occurrences(rule('month', d(2026, 1, 31), every: 3), d(2026, 3, 15), d(2026, 12, 31)),
          [d(2026, 4, 30), d(2026, 7, 31), d(2026, 10, 31)]);
    });

    test('until and skips', () {
      final r = rule('day', d(2026, 3, 1), every: 3, until: d(2026, 3, 13), skips: {d(2026, 3, 7)});
      expect(occurrences(r, d(2026, 1, 1), d(2026, 12, 31)),
          [d(2026, 3, 1), d(2026, 3, 4), d(2026, 3, 10), d(2026, 3, 13)]);
    });

    test('before the start', () {
      expect(occurrences(rule('month', d(2026, 6, 1)), d(2026, 1, 1), d(2026, 5, 31)), isEmpty);
    });

    test('next date', () {
      expect(nextDate(rule('year', d(2020, 10, 1)), d(2026, 10, 2)), d(2027, 10, 1));
      expect(nextDate(rule('month', d(2026, 1, 5), skips: {d(2026, 11, 5), d(2026, 12, 5)}),
          d(2026, 10, 12)), d(2027, 1, 5));
      expect(nextDate(rule('month', d(2026, 1, 5), until: d(2026, 6, 30)), d(2026, 7, 1)), isNull);
      expect(nextDate(rule('month', d(2029, 1, 5)), d(2026, 7, 1)), d(2029, 1, 5));
    });

    test('a number of times', () {
      final r = rule('month', d(2026, 1, 31), times: 3);
      expect(occurrences(r, d(2025, 1, 1), d(2027, 12, 31)), [d(2026, 1, 31), d(2026, 2, 28), d(2026, 3, 31)]);
      expect(lastDate(r), d(2026, 3, 31));
      expect(occurrences(r, d(2026, 3, 1), d(2026, 12, 31)), [d(2026, 3, 31)]);
    });

    test('skipped dates still count towards the times', () {
      final r = rule('week', d(2026, 1, 2), times: 4, skips: {d(2026, 1, 9)});
      expect(occurrences(r, d(2026, 1, 1), d(2026, 12, 31)), [d(2026, 1, 2), d(2026, 1, 16), d(2026, 1, 23)]);
    });

    test('the earlier end wins', () {
      final r = rule('day', d(2026, 3, 1), times: 10, until: d(2026, 3, 4));
      expect(occurrences(r, d(2026, 1, 1), d(2026, 12, 31)).length, 4);
      expect(describeEnd(r), '2026/03/04');
      expect(lastDate(rule('day', d(2026, 3, 1), times: 2, until: d(2026, 3, 4))), d(2026, 3, 2));
    });

    test('times before a day', () {
      final r = rule('month', d(2026, 1, 10));
      expect([d(2026, 1, 10), d(2026, 3, 5), d(2026, 3, 10), d(2026, 3, 11)].map((x) => timesBefore(r, x)),
          [0, 2, 2, 3]);
      expect(timesBefore(rule('week', d(2026, 1, 2)), d(2026, 1, 17)), 3);
    });

    test('date numbers and the end text', () {
      final r = rule('month', d(2026, 1, 31), every: 2, times: 6);
      expect(dateNumber(r, d(2026, 3, 31)), 2);
      expect(dateNumber(r, d(2026, 11, 30)), 6);
      expect(describeEnd(r), 'After 6 times · 2026/11/30');
      expect(nextDate(r, d(2026, 12, 1)), isNull);
      expect(nextDate(r, d(2026, 10, 1)), d(2026, 11, 30));
      expect(describeEnd(rule('week', d(2026, 1, 2), times: 1)), 'After 1 time · 2026/01/02');
      expect(describeEnd(rule('month', d(2026, 1, 1))), 'No end date');
      expect(dateNumber(rule('week', d(2026, 1, 2), every: 2), d(2026, 1, 30)), 3);
    });

    test('descriptions and per month', () {
      expect(describeRule(rule('month', d(2026, 1, 5))), 'Every month on the 5th');
      expect(describeRule(rule('week', d(2026, 1, 2), every: 2)), 'Every 2 weeks on Friday');
      expect(describeRule(rule('year', d(2026, 10, 12))), 'Every year on Oct 12');
      expect(describeRule(rule('day', d(2026, 1, 1))), 'Every day');
      expect(perMonth(rule('week', d(2026, 1, 1), amount: 10000)), 43482);
      expect(perMonth(rule('year', d(2026, 1, 1), amount: 120000)), 10000);
    });
  });

  group('balances', () {
    const food = 1, rent = 4, salary = 12;
    var nextId = 1;
    Entry entry(DateTime day, String kind, int amount, [int category = food, String note = '']) =>
        Entry(nextId++, day, kind, amount, category, note);

    test('without a starting balance', () {
      final ledger = Ledger(
          [entry(d(2026, 10, 3), 'expense', 5000), entry(d(2026, 10, 5), 'income', 100000, salary)],
          const [], const Plan());
      expect(ledger.days(d(2026, 10, 1), d(2026, 10, 6)).map((x) => x.balance),
          [0, 0, -5000, -5000, 95000, 95000]);
    });

    test('a starting balance, before and after its date', () {
      final ledger = Ledger([
        entry(d(2026, 10, 5), 'expense', 20000),
        entry(d(2026, 10, 10), 'expense', 30000),
        entry(d(2026, 10, 12), 'income', 50000, salary),
      ], const [], Plan(startBalance: 1000000, startDate: d(2026, 10, 10)));
      expect(ledger.balanceBefore(d(2026, 10, 10)), 1000000);
      expect(ledger.balanceBefore(d(2026, 10, 11)), 970000);
      expect(ledger.balanceBefore(d(2026, 10, 13)), 1020000);
      // before the starting date it's worked out backwards
      expect(ledger.balanceBefore(d(2026, 10, 5)), 1020000);
      expect(ledger.balanceBefore(d(2026, 10, 6)), 1000000);
    });

    test('repeating entries count in balances', () {
      final ledger = Ledger(const [], [
        Rule(1, 'income', 100000, salary, 'Salary', 'month', 1, d(2025, 6, 5)),
        Rule(2, 'expense', 1000, food, '', 'day', 1, d(2026, 1, 1)),
      ], Plan(startDate: d(2026, 1, 1)));
      expect(ledger.balanceBefore(d(2026, 2, 1)), 100000 - 31 * 1000);
    });

    // Oct 2026: 30,000 at the start, rent 15,000 on the 1st, salary 50,000 on the 5th, phone 500
    // on the 15th, today (the 12th) 8,000 spent so far.
    Ledger scenario(Plan plan, {int todaySpent = 800000, Set<DateTime> rentSkips = const {}}) => Ledger([
          entry(d(2026, 10, 15), 'expense', 50000, food, 'Phone'),
          entry(d(2026, 10, 12), 'expense', todaySpent),
        ], [
          Rule(1, 'expense', 1500000, rent, 'Rent', 'month', 1, d(2026, 1, 1), skips: rentSkips),
          Rule(2, 'income', 5000000, salary, 'Salary', 'month', 1, d(2026, 1, 5)),
        ], plan);
    final start = Plan(startBalance: 3000000, startDate: d(2026, 10, 1));
    final today = d(2026, 10, 12);

    test('month plan by income', () {
      final p = scenario(start.copyWith(savingsGoal: 1000000)).monthPlan(2026, 10, today);
      expect([p.status, p.income, p.expense], ['current', 5000000, 2350000]);
      expect([p.plannedIncome, p.plannedExpense, p.spent], [0, 50000, 2300000]);
      expect([p.opening, p.closing], [3000000, 5650000]);
      expect([p.lowest, p.lowestDay], [5650000, d(2026, 10, 15)]);
      expect(p.left, 1650000); // 50,000 - 23,500 - 10,000
      expect(p.limitedByBalance, isFalse);
      expect([p.daysLeft, p.perDay], [20, 82500]);
    });

    test('month plan capped by the balance', () {
      final p = scenario(start.copyWith(minBalance: 5000000)).monthPlan(2026, 10, today);
      expect(p.left, 650000); // lowest 56,500 - minimum 50,000
      expect(p.limitedByBalance, isTrue);
    });

    test('month plan by balance', () {
      final p = scenario(start.copyWith(basis: 'balance', savingsGoal: 1000000)).monthPlan(2026, 10, today);
      expect(p.left, 5650000);
    });

    test('overspent', () {
      final p = scenario(start, todaySpent: 4000000).monthPlan(2026, 10, today);
      expect(p.left, -550000);
      expect(p.perDay, 0);
    });

    test('past and future months', () {
      final ledger = scenario(start);
      final past = ledger.monthPlan(2026, 9, today), future = ledger.monthPlan(2026, 11, today);
      expect([past.status, past.daysLeft], ['past', 0]);
      expect([future.status, future.daysLeft, future.left], ['future', 30, 3500000]);
    });

    test('upcoming and the lowest point', () {
      final ledger = scenario(start);
      expect([for (final (i, b) in ledger.upcoming(today)) (i.day, i.signed, b)], [
        (d(2026, 10, 15), -50000, 5650000),
        (d(2026, 11, 1), -1500000, 4150000),
        (d(2026, 11, 5), 5000000, 9150000),
      ]);
      expect(ledger.lowest(d(2026, 10, 13), d(2026, 11, 30)), (d(2026, 11, 1), 4150000));
    });

    test('totals', () {
      final items = scenario(start).items(d(2026, 9, 1), d(2026, 10, 31));
      expect(totalsByCategory(items, 'expense'), [(rent, 3000000, 2), (food, 850000, 2)]);
      expect(totalsByMonth(items, d(2026, 9, 15), d(2026, 10, 31)),
          [(d(2026, 9, 1), 5000000, 1500000), (d(2026, 10, 1), 5000000, 2350000)]);
    });

    test('a skipped date', () {
      final p = scenario(start, rentSkips: {d(2026, 11, 1)}).monthPlan(2026, 11, today);
      expect(p.expense, 0);
    });
  });
}
