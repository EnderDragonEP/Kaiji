/// Statistics: totals, where the money went and came from, spending per day and month, and the
/// balance over a date range.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../dates.dart';
import '../ledger.dart';
import '../models.dart';
import '../money.dart' as money;
import 'actions.dart';
import 'charts.dart';
import 'look.dart';
import 'widgets.dart';

const _ranges = ['This month', 'Last month', '3 months', '6 months', 'This year', '12 months'];
const _dailyLimit = 93; // longer ranges show months only

(DateTime, DateTime) _preset(int index, DateTime now) {
  final first = ymd(now.year, now.month, 1);
  final monthEnd = monthBounds(now.year, now.month).$2;
  return switch (index) {
    0 => (first, monthEnd),
    1 => monthBounds(addMonths(first, -1).year, addMonths(first, -1).month),
    2 => (addMonths(first, -2), monthEnd),
    3 => (addMonths(first, -5), monthEnd),
    4 => (ymd(now.year, 1, 1), ymd(now.year, 12, 31)),
    _ => (addMonths(first, -11), monthEnd),
  };
}

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int range = 0; // an index into _ranges, or -1 for a picked range
  late (DateTime, DateTime) dates = _preset(0, today());

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(2000),
      lastDate: DateTime.utc(2100),
      initialDateRange: DateTimeRange(start: dates.$1, end: dates.$2),
    );
    if (picked != null) {
      setState(() {
        range = -1;
        dates = (dateOf(picked.start), dateOf(picked.end));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final now = today();
    final (start, end) = dates;
    final days = state.ledger.days(start, end);
    final items = [for (final d in days) ...d.items];
    final expenses = [for (final i in items) if (i.kind == 'expense') i];
    final incomes = [for (final i in items) if (i.kind == 'income') i];

    List<(String, String, int, int)> byCategory(String kind) => [
          for (final (id, total, count) in totalsByCategory(items, kind))
            (state.category(id).icon, state.category(id).name, total, count),
        ];

    final span = daysBetween(start, end) + 1;
    final monthsInRange = totalsByMonth(items, start, end);
    return CustomScrollView(slivers: [
      SliverAppBar.large(title: const Text('Statistics'), actions: [
        IconButton(
          icon: const Icon(Icons.ios_share),
          tooltip: 'Export these dates as CSV',
          onPressed: () => shareCsv(state, start, end, 'kaiji ${iso(start)} to ${iso(end)}.csv'),
        ),
      ]),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        sliver: SliverList.list(children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < _ranges.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_ranges[i]),
                    selected: range == i,
                    onSelected: (_) => setState(() {
                      range = i;
                      dates = _preset(i, now);
                    }),
                  ),
                ),
              ChoiceChip(
                avatar: const Icon(Icons.date_range_outlined, size: 18),
                label: const Text('Custom'),
                selected: range == -1,
                onSelected: (_) => _pickRange(),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Text('${fmtDate(start)} – ${fmtDate(end)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: secondaryText(context))),
          const SizedBox(height: 12),
          TileGrid(_tiles(context, state, start, end, now, expenses, incomes)),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Spending by category',
            child: BarList(rows: byCategory('expense'), colorKey: 'expense', empty: 'No expenses in this period.'),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Income by category',
            child: BarList(rows: byCategory('income'), colorKey: 'income', empty: 'No income in this period.'),
          ),
          if (span <= _dailyLimit) ...[
            const SizedBox(height: 12),
            SectionCard(title: 'Spending per day', child: _daily(days, now, span)),
          ],
          if (monthsInRange.length >= 2) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Income and expenses per month',
              child: ColumnChart(
                labels: [
                  for (final (m, _, _) in monthsInRange)
                    monthShort(m.month) + (monthsInRange.first.$1.year != monthsInRange.last.$1.year
                        ? " '${(m.year % 100).toString().padLeft(2, '0')}"
                        : ''),
                ],
                titles: [for (final (m, _, _) in monthsInRange) '${months[m.month - 1]} ${m.year}'],
                series: [
                  ('Income', 'income', [for (final (_, i, _) in monthsInRange) i]),
                  ('Expenses', 'expense', [for (final (_, _, e) in monthsInRange) e]),
                ],
                planned: [for (final (m, _, _) in monthsInRange) m.isAfter(now)],
                empty: 'Nothing in this period.',
              ),
            ),
          ],
          const SizedBox(height: 12),
          SectionCard(title: 'Balance', child: BalanceChart(days: days, today: now, floor: state.plan.minBalance)),
        ]),
      ),
    ]);
  }

  Widget _daily(List<DayInfo> days, DateTime now, int span) {
    String label(DateTime d) {
      // a month: every day number that fits; longer: the 1st (as the month), 8th, 15th, 22nd
      if (d.day == 1) return monthShort(d.month) + (span <= 31 ? ' 1' : '');
      return span <= 31 || const {8, 15, 22}.contains(d.day) ? '${d.day}' : '';
    }

    final past = [for (final d in days) if (!d.day.isAfter(now)) d];
    final average = past.isEmpty ? 0 : past.fold(0, (s, d) => s + d.expense) ~/ past.length;
    return ColumnChart(
      labels: [for (final d in days) label(d.day)],
      titles: [for (final d in days) '${weekdaysShort[d.day.weekday - 1]} ${fmtDate(d.day)}'],
      series: [('Expenses', 'expense', [for (final d in days) d.expense])],
      planned: [for (final d in days) d.day.isAfter(now)],
      reference: average > 0 ? (average, 'Average ${money.fmt(average)}') : null,
      empty: 'No expenses in this period.',
    );
  }

  List<Widget> _tiles(BuildContext context, KaijiState state, DateTime start, DateTime end, DateTime now,
      List<Item> expenses, List<Item> incomes) {
    final income = incomes.fold(0, (s, i) => s + i.amount), expense = expenses.fold(0, (s, i) => s + i.amount);
    final plannedIn = incomes.where((i) => i.day.isAfter(now)).fold(0, (s, i) => s + i.amount);
    final plannedOut = expenses.where((i) => i.day.isAfter(now)).fold(0, (s, i) => s + i.amount);
    final net = income - expense;
    final last = end.isBefore(now) ? end : now;
    final elapsed = last.isBefore(start) ? 0 : daysBetween(start, last) + 1;
    final String average, averageNote;
    if (elapsed > 0) {
      final spent = expenses.where((i) => !i.day.isAfter(now)).fold(0, (s, i) => s + i.amount);
      average = money.fmt(spent ~/ elapsed);
      averageNote = 'over ${plural(elapsed, 'day', 'days')}${end.isAfter(now) ? ' so far' : ''}';
    } else {
      final span = daysBetween(start, end) + 1;
      average = money.fmt(expense ~/ span);
      averageNote = 'planned, over $span days';
    }
    final top = totalsByCategory(expenses, 'expense');
    final largest = expenses.isEmpty
        ? null
        : expenses.reduce((a, b) => b.amount > a.amount || (b.amount == a.amount && b.day.isAfter(a.day)) ? b : a);
    return [
      StatTile(
          caption: 'Income',
          value: money.fmt(income),
          note: plannedIn > 0 ? 'incl. ${money.fmt(plannedIn)} planned' : plural(incomes.length, 'entry', 'entries')),
      StatTile(
          caption: 'Expenses',
          value: money.fmt(expense),
          note: plannedOut > 0 ? 'incl. ${money.fmt(plannedOut)} planned' : plural(expenses.length, 'entry', 'entries')),
      StatTile(
        caption: 'Net',
        value: money.fmt(net, sign: true),
        note: income == 0
            ? ''
            : (net >= 0
                ? 'Saved ${(net / income * 100).round()}% of income'
                : 'Spent ${(-net / income * 100).round()}% more than came in'),
        color: net < 0 ? critical(context) : null,
      ),
      StatTile(caption: 'Spending per day', value: average, note: averageNote),
      StatTile(
        caption: 'Biggest category',
        value: top.isEmpty ? '–' : state.category(top.first.$1).name,
        note: top.isEmpty ? 'No expenses' : '${money.fmt(top.first.$2)} · ${(top.first.$2 / expense * 100).round()}% of spending',
      ),
      StatTile(
        caption: 'Largest expense',
        value: largest == null ? '–' : money.fmt(largest.amount),
        note: largest == null ? 'No expenses' : '${describeItem(state, largest).$1} · ${fmtShort(largest.day)}',
      ),
    ];
  }
}
