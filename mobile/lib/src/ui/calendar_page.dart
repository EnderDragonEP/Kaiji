/// Calendar: a month of income, expenses and the balance per day - projected (≈) for the days
/// ahead, red when it would drop below the minimum - with the selected day's entries and the
/// month's plan below. Swipe sideways for another month.
library;

import 'package:flutter/material.dart';

import '../dates.dart';
import '../models.dart';
import '../money.dart' as money;
import 'actions.dart';
import 'look.dart';
import 'widgets.dart';

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key, required this.day, required this.onDay});
  final DateTime day; // the selected day
  final ValueChanged<DateTime> onDay;

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final now = today();
    final first = ymd(day.year, day.month, 1);
    final lead = (first.weekday - 1 - state.weekStart) % 7;
    final gridStart = addDays(first, -lead);
    final rows = (lead + monthBounds(day.year, day.month).$2.day + 6) ~/ 7;
    final days = {for (final d in state.ledger.days(gridStart, addDays(gridStart, rows * 7 - 1))) d.day: d};
    final plan = state.ledger.monthPlan(day.year, day.month, now);
    final text = Theme.of(context).textTheme;

    void step(int months) => onDay(addMonths(day, months));

    Widget cell(DateTime d) => Expanded(
          child: _DayCell(
            info: days[d]!,
            inMonth: d.month == day.month,
            selected: d == day,
            today: d == now,
            future: d.isAfter(now),
            floor: state.plan.minBalance,
            onTap: () => onDay(d),
          ),
        );

    return SafeArea(
      bottom: false,
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
          child: Row(children: [
            Expanded(
              child: Text('${months[day.month - 1]} ${day.year}',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
                icon: const Icon(Icons.today_outlined),
                tooltip: 'Go to today',
                onPressed: day == now ? null : () => onDay(now)),
            IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Previous month', onPressed: () => step(-1)),
            IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Next month', onPressed: () => step(1)),
          ]),
        ),
        Row(children: [
          for (var c = 0; c < 7; c++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 4),
                child: Text(weekdaysShort[(c + state.weekStart) % 7],
                    style: text.labelSmall?.copyWith(color: secondaryText(context))),
              ),
            ),
        ]),
        GestureDetector(
          onHorizontalDragEnd: (e) {
            final v = e.primaryVelocity ?? 0;
            if (v < -200) step(1);
            if (v > 200) step(-1);
          },
          child: Column(children: [
            for (var r = 0; r < rows; r++)
              Row(children: [for (var c = 0; c < 7; c++) cell(addDays(gridStart, r * 7 + c))]),
          ]),
        ),
        const SizedBox(height: 12),
        _DayPanel(info: days[day] ?? state.ledger.days(day, day).first),
        const SizedBox(height: 12),
        _MonthCard(plan: plan),
      ]),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.info,
    required this.inMonth,
    required this.selected,
    required this.today,
    required this.future,
    required this.floor,
    required this.onTap,
  });
  final DayInfo info;
  final bool inMonth, selected, today, future;
  final int floor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final low = inMonth && info.balance < floor;
    final monthEnd = info.day == monthBounds(info.day.year, info.day.month).$2;
    final showBalance = inMonth && (info.items.isNotEmpty || today || monthEnd);
    final ink = future ? secondaryText(context) : scheme.onSurface;
    Widget amount(int cents, String key) => Row(children: [
          Container(
              width: 6, height: 6, margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(color: series(context, key), shape: BoxShape.circle)),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(money.compact(cents, sign: true), style: text.labelSmall?.copyWith(color: ink, height: 1.2)),
            ),
          ),
        ]);
    return AspectRatio(
      aspectRatio: 0.72,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: Material(
          color: low ? scheme.errorContainer : (inMonth ? scheme.surfaceContainerHigh : Colors.transparent),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: selected ? BorderSide(color: scheme.primary, width: 2) : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(3, 3, 3, 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: today ? BoxDecoration(color: scheme.primary, shape: BoxShape.circle) : null,
                  child: Text('${info.day.day}',
                      style: text.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: today ? scheme.onPrimary : (inMonth ? scheme.onSurface : tertiaryText(context)),
                      )),
                ),
                if (inMonth) ...[
                  if (info.income > 0) amount(info.income, 'income'),
                  if (info.expense > 0) amount(-info.expense, 'expense'),
                  const Spacer(),
                  if (showBalance)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text((future ? '≈' : '') + money.compact(info.balance),
                            style: text.labelSmall?.copyWith(
                                fontSize: 10, color: low ? critical(context) : tertiaryText(context))),
                      ),
                    ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _DayPanel extends StatelessWidget {
  const _DayPanel({required this.info});
  final DayInfo info;

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final now = today();
    final day = info.day;
    final floor = state.plan.minBalance;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget chip(String label, {bool bad = false}) => Padding(
          padding: const EdgeInsets.only(right: 6, top: 6),
          child: Chip(
            label: Text(label),
            visualDensity: VisualDensity.compact,
            labelStyle: text.labelSmall?.copyWith(color: bad ? scheme.onErrorContainer : scheme.onSecondaryContainer),
            backgroundColor: bad ? scheme.errorContainer : scheme.secondaryContainer,
            side: BorderSide.none,
          ),
        );
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(fmtLong(day), style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          Wrap(children: [
            if (day == now) chip('Today') else if (day.isAfter(now) && info.items.isNotEmpty) chip('Planned'),
            if (info.balance < 0)
              chip('Overdrawn', bad: true)
            else if (info.balance < floor)
              chip('Below your minimum', bad: true),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(children: [
              if (info.income > 0) Expanded(child: _Figure('Income', money.fmt(info.income, sign: true))),
              if (info.expense > 0) Expanded(child: _Figure('Expenses', money.fmt(-info.expense))),
              Expanded(
                child: _Figure(day.isAfter(now) ? 'Projected balance' : 'Balance at day end',
                    (day.isAfter(now) ? '≈ ' : '') + money.fmt(info.balance),
                    color: info.balance < floor ? critical(context) : null),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          if (info.items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
              child: Text('Nothing on this day. Tap + to add an entry.', style: TextStyle(color: secondaryText(context))),
            )
          else
            for (final item in info.items)
              EntryTile(item: item, onTap: () => editItem(context, item), onMenu: () => itemMenu(context, item)),
        ]),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.caption, this.value, {this.color});
  final String caption, value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(caption, style: text.labelSmall?.copyWith(color: secondaryText(context))),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: color)),
        ),
      ]),
    );
  }
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.plan});
  final MonthPlan plan;

  @override
  Widget build(BuildContext context) {
    final approx = plan.status == 'past' ? '' : '≈ ';
    final (String, String, Color?) fourth;
    if (plan.status == 'past') {
      if (plan.goal != 0) {
        final short = plan.goal - plan.net;
        fourth = ('Savings goal', short <= 0 ? 'Met' : 'Short by ${money.fmt(short)}',
            short <= 0 ? null : series(context, 'caution'));
      } else {
        fourth = ('Spent per day', money.fmt(plan.expense ~/ (daysBetween(plan.start, plan.end) + 1)), null);
      }
    } else {
      fourth = (
        'Left to spend',
        money.fmt(plan.left) + (plan.left > 0 && plan.daysLeft > 1 ? ' · ${money.fmt(plan.perDay)}/day' : ''),
        plan.left < 0 ? critical(context) : null,
      );
    }
    final cells = [
      ('Income', money.fmt(plan.income), null),
      ('Expenses', money.fmt(plan.expense), null),
      ('Net', money.fmt(plan.net, sign: true), null),
      fourth,
      ('Balance at start', money.fmt(plan.opening), null),
      ('Balance at end', approx + money.fmt(plan.closing), null),
    ];
    return SectionCard(
      title: '${months[plan.start.month - 1]} ${plan.start.year}',
      child: Column(children: [
        for (var i = 0; i < cells.length; i += 2)
          Row(children: [
            for (final (caption, value, color) in cells.sublist(i, i + 2))
              Expanded(child: _Figure(caption, value, color: color)),
          ]),
      ]),
    );
  }
}
