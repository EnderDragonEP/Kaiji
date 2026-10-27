/// The money logic behind every screen: the dates repeating entries fall on, the balance day by
/// day, the month plan ("left to spend") and the totals for Statistics. A port of the desktop's
/// ledger.py, on data kept in memory, so it's plain Dart and the same tests apply.
///
/// Balances: the balance at the end of a day is the starting balance plus everything dated from
/// the starting date up to that day (minus everything between the day and the starting date for
/// days before it). Days after today are projected from what's planned.
///
/// Left to spend (planning by income): this month's income - its expenses (recorded and planned)
/// - the savings goal, but never more than would push the balance below the minimum on any day
/// from today to the month's end. Planning by balance: only the second part counts.
library;

import 'dates.dart';
import 'models.dart';

const freqUnits = {
  'day': ('day', 'days'),
  'week': ('week', 'weeks'),
  'month': ('month', 'months'),
  'year': ('year', 'years'),
};
const perMonthFactor = {'day': 365.25 / 12, 'week': 365.25 / 12 / 7, 'month': 1.0, 'year': 1 / 12};

/// (true, days) between the dates of daily and weekly rules, (false, months) for the rest.
(bool, int) _step(Rule rule) {
  final every = rule.every < 1 ? 1 : rule.every;
  if (rule.freq == 'day' || rule.freq == 'week') return (true, every * (rule.freq == 'week' ? 7 : 1));
  return (false, every * (rule.freq == 'year' ? 12 : 1));
}

/// The rule's date number [n], from 0 at its start; skipped dates count too.
DateTime nthDate(Rule rule, int n) {
  final (inDays, step) = _step(rule);
  return inDays ? addDays(rule.start, n * step) : addMonths(rule.start, n * step);
}

int _monthsBetween(DateTime a, DateTime b) => (b.year - a.year) * 12 + b.month - a.month;

/// Which of the rule's dates [day] is, from 1 at its start; skipped dates count too.
int dateNumber(Rule rule, DateTime day) {
  final (inDays, step) = _step(rule);
  return (inDays ? daysBetween(rule.start, day) : _monthsBetween(rule.start, day)) ~/ step + 1;
}

/// How many of the rule's dates come before [day]; skipped dates count too.
int timesBefore(Rule rule, DateTime day) {
  if (!day.isAfter(rule.start)) return 0;
  final n = dateNumber(rule, day);
  return nthDate(rule, n - 1).isBefore(day) ? n : n - 1;
}

/// The last date the rule can fall on - its end date or its last time, whichever comes first -
/// or null when it doesn't end. Skipping a date doesn't add one at the end.
DateTime? lastDate(Rule rule) {
  final byTimes = rule.times != null ? nthDate(rule, rule.times! - 1) : null;
  if (rule.until == null) return byTimes;
  if (byTimes == null) return rule.until;
  return byTimes.isBefore(rule.until!) ? byTimes : rule.until;
}

/// Dates in [start, end] the rule falls on, skipped dates left out. Monthly rules from the
/// 29th-31st fall on the last day of shorter months, yearly ones from Feb 29 on Feb 28.
List<DateTime> occurrences(Rule rule, DateTime start, DateTime end) {
  final lo = start.isAfter(rule.start) ? start : rule.start;
  final last = lastDate(rule);
  final hi = last != null && last.isBefore(end) ? last : end;
  if (lo.isAfter(hi)) return const [];
  final (inDays, step) = _step(rule);
  final out = <DateTime>[];
  if (inDays) {
    final offset = daysBetween(rule.start, lo);
    var d = addDays(rule.start, ((offset + step - 1) ~/ step) * step);
    while (!d.isAfter(hi)) {
      out.add(d);
      d = addDays(d, step);
    }
  } else {
    var n = _monthsBetween(rule.start, lo) ~/ step;
    while (true) {
      // always from the start date, so Jan 31 -> Feb 28 -> Mar 31 doesn't drift
      final d = addMonths(rule.start, n * step);
      if (d.isAfter(hi)) break;
      if (!d.isBefore(lo)) out.add(d);
      n++;
    }
  }
  return rule.skips.isEmpty ? out : out.where((d) => !rule.skips.contains(d)).toList();
}

/// The first date on or after [day] the rule falls on; null once it has ended.
DateTime? nextDate(Rule rule, DateTime day) {
  const gaps = {'day': 1, 'week': 7, 'month': 31, 'year': 366};
  final gap = gaps[rule.freq]! * (rule.every < 1 ? 1 : rule.every);
  final begin = day.isAfter(rule.start) ? day : rule.start;
  // skipped dates can hide at most that many occurrences
  final found = occurrences(rule, begin, addDays(begin, gap * (rule.skips.length + 2)));
  return found.isEmpty ? null : found.first;
}

/// "Every month on the 5th", "Every 2 weeks on Friday", "Every year on Oct 12".
String describeRule(Rule rule) {
  final unit = freqUnits[rule.freq]!;
  final head = rule.every <= 1 ? 'Every ${unit.$1}' : 'Every ${rule.every} ${unit.$2}';
  final s = rule.start;
  switch (rule.freq) {
    case 'week':
      return '$head on ${weekdays[s.weekday - 1]}';
    case 'month':
      return '$head on the ${ordinal(s.day)}';
    case 'year':
      return '$head on ${fmtShort(s)}';
  }
  return head;
}

/// "No end date", "2027/09/05", or "After 12 times · 2027/09/05".
String describeEnd(Rule rule) {
  final last = lastDate(rule);
  if (last == null) return 'No end date';
  if (rule.times != null && last == nthDate(rule, rule.times! - 1)) {
    return 'After ${rule.times} ${rule.times == 1 ? 'time' : 'times'} · ${fmtDate(last)}';
  }
  return fmtDate(last);
}

/// The rule's amount averaged per month (a weekly NT$100 is about NT$435 a month).
int perMonth(Rule rule) => (rule.amount * perMonthFactor[rule.freq]! / (rule.every < 1 ? 1 : rule.every)).round();

int _lowerBound(List<DateTime> days, DateTime day) {
  var lo = 0, hi = days.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (days[mid].isBefore(day)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

class Ledger {
  Ledger(List<Entry> entries, this.rules, this.plan)
      : entries = [...entries]..sort((a, b) {
          final byDay = a.day.compareTo(b.day);
          return byDay != 0 ? byDay : a.id.compareTo(b.id);
        }) {
    _days = [for (final e in this.entries) e.day];
    var total = 0;
    _prefix = [for (final e in this.entries) total += e.signed];
  }

  final List<Entry> entries; // by day
  final List<Rule> rules;
  final Plan plan;
  late final List<DateTime> _days;
  late final List<int> _prefix; // running signed total of the entries

  /// Income minus expenses of the entries dated on or before [end].
  int entryNet(DateTime end) {
    final i = _lowerBound(_days, addDays(end, 1));
    return i == 0 ? 0 : _prefix[i - 1];
  }

  List<Entry> entriesIn(DateTime start, DateTime end) =>
      entries.sublist(_lowerBound(_days, start), _lowerBound(_days, addDays(end, 1)));

  /// Entries and repeating dates in [start, end]: by day, income first, larger first.
  List<Item> items(DateTime start, DateTime end) {
    final out = [
      for (final e in entriesIn(start, end))
        Item(e.day, e.kind, e.amount, e.categoryId, e.note, entryId: e.id),
      for (final r in rules)
        for (final d in occurrences(r, start, end))
          Item(d, r.kind, r.amount, r.categoryId, r.note, ruleId: r.id),
    ];
    out.sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      if (byDay != 0) return byDay;
      final byKind = (a.kind == 'income' ? 0 : 1) - (b.kind == 'income' ? 0 : 1);
      return byKind != 0 ? byKind : b.amount - a.amount;
    });
    return out;
  }

  /// Income minus expenses of everything dated on or before [day].
  int _netUntil(DateTime day) {
    var total = entryNet(day);
    for (final r in rules) {
      if (!r.start.isAfter(day)) total += occurrences(r, r.start, day).length * r.signed;
    }
    return total;
  }

  /// The balance at the start of [day].
  int balanceBefore(DateTime day) {
    var balance = plan.startBalance + _netUntil(addDays(day, -1));
    if (plan.startDate != null) balance -= _netUntil(addDays(plan.startDate!, -1));
    return balance;
  }

  /// Every day in [start, end] with its items and end-of-day balance, in order.
  List<DayInfo> days(DateTime start, DateTime end) {
    var balance = balanceBefore(start);
    final byDay = <DateTime, List<Item>>{};
    for (final item in items(start, end)) {
      byDay.putIfAbsent(item.day, () => []).add(item);
    }
    final out = <DayInfo>[];
    for (final d in dayRange(start, end)) {
      final its = byDay[d] ?? const <Item>[];
      var income = 0, expense = 0;
      for (final i in its) {
        if (i.kind == 'income') {
          income += i.amount;
        } else {
          expense += i.amount;
        }
      }
      balance += income - expense;
      out.add(DayInfo(d, its, income, expense, balance));
    }
    return out;
  }

  MonthPlan monthPlan(int year, int month, DateTime today) {
    final (start, end) = monthBounds(year, month);
    final all = days(start, end);
    final status = end.isBefore(today) ? 'past' : (start.isAfter(today) ? 'future' : 'current');
    final first = status == 'current' ? today : start;
    final later = all.where((d) => d.day.isAfter(today));
    DayInfo low = all.last;
    for (final d in all.where((d) => !d.day.isBefore(first))) {
      if (d.balance < low.balance || (d.balance == low.balance && d.day.isBefore(low.day))) low = d;
    }
    final income = all.fold(0, (s, d) => s + d.income);
    final expense = all.fold(0, (s, d) => s + d.expense);
    return MonthPlan(
      start: start,
      end: end,
      status: status,
      income: income,
      expense: expense,
      plannedIncome: later.fold(0, (s, d) => s + d.income),
      plannedExpense: later.fold(0, (s, d) => s + d.expense),
      opening: all.first.balance - all.first.income + all.first.expense,
      closing: all.last.balance,
      lowest: low.balance,
      lowestDay: low.day,
      goal: plan.savingsGoal,
      floor: plan.minBalance,
      basis: plan.basis,
      budgetRoom: income - expense - plan.savingsGoal,
      cashRoom: low.balance - plan.minBalance,
      daysLeft: status == 'past' ? 0 : daysBetween(first, end) + 1,
    );
  }

  /// (item, balance after it) for everything planned in the next [count] days.
  List<(Item, int)> upcoming(DateTime today, [int count = 30]) {
    final start = addDays(today, 1);
    var balance = balanceBefore(start);
    return [
      for (final item in items(start, addDays(today, count))) (item, balance += item.signed),
    ];
  }

  /// (day, balance): the lowest end-of-day balance in [start, end], the earliest if tied.
  (DateTime, int) lowest(DateTime start, DateTime end) {
    DayInfo? low;
    for (final d in days(start, end)) {
      if (low == null || d.balance < low.balance) low = d;
    }
    return (low!.day, low.balance);
  }
}

/// (category id, total, count) of the items of one kind, largest first.
List<(int?, int, int)> totalsByCategory(Iterable<Item> items, String kind) {
  final totals = <int?, (int, int)>{};
  for (final i in items) {
    if (i.kind != kind) continue;
    final t = totals[i.categoryId] ?? (0, 0);
    totals[i.categoryId] = (t.$1 + i.amount, t.$2 + 1);
  }
  final out = [for (final e in totals.entries) (e.key, e.value.$1, e.value.$2)];
  out.sort((a, b) => b.$2 - a.$2);
  return out;
}

/// (first day of the month, income, expense) for every month touching [start, end].
List<(DateTime, int, int)> totalsByMonth(Iterable<Item> items, DateTime start, DateTime end) {
  final sums = <DateTime, List<int>>{};
  for (var m = ymd(start.year, start.month, 1); !m.isAfter(end); m = addMonths(m, 1)) {
    sums[m] = [0, 0];
  }
  for (final i in items) {
    sums[ymd(i.day.year, i.day.month, 1)]?[i.kind == 'income' ? 0 : 1] += i.amount;
  }
  return [for (final e in sums.entries) (e.key, e.value[0], e.value[1])];
}
