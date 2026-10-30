/// Today: how much you can spend, at a glance, and what's coming up.
library;

import 'package:flutter/material.dart';

import '../dates.dart';
import '../money.dart' as money;
import 'actions.dart';
import 'charts.dart';
import 'look.dart';
import 'settings_page.dart';
import 'widgets.dart';

const _upcomingDays = 30, _upcomingRows = 8, _lookahead = 60;

class TodayPage extends StatelessWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final ledger = state.ledger;
    final now = today();
    final floor = state.plan.minBalance;
    final plan = ledger.monthPlan(now.year, now.month, now);
    final month = months[now.month - 1];
    final day = ledger.days(now, now).first;
    final (lowDay, low) = ledger.lowest(addDays(now, 1), addDays(now, _lookahead));
    final below = floor != 0 ? 'your minimum of ${money.fmt(floor)}' : 'zero';
    final text = Theme.of(context).textTheme;

    Widget? notice;
    if (state.plan.startDate == null) {
      notice = NoticeCard(
        icon: Icons.account_balance_wallet_outlined,
        title: 'Add your current balance',
        text: "Kaiji works out every day's balance from it, so the calendar can show what you'll have on any day.",
        action: 'Set up',
        onAction: () => openWelcome(context),
      );
    } else if ((low < day.balance ? low : day.balance) < floor) {
      final (d, v) = low < day.balance ? (lowDay, low) : (now, day.balance);
      notice = NoticeCard(
        icon: Icons.warning_amber_rounded,
        warning: true,
        title: 'Your balance drops to ${money.fmt(v)} on ${fmtShort(d)}',
        text: "That's below $below.",
      );
    } else if (plan.basis == 'income' && plan.income == 0) {
      notice = NoticeCard(
        icon: Icons.info_outline,
        title: 'No income in $month yet',
        text: "Left to spend comes from this month's income. Add your pay as a repeating entry, or plan by "
            'your balance in Settings.',
        action: 'Add income',
        onAction: () => addEntry(context, kind: 'income', repeat: 'month'),
      );
    }

    // the hero
    final left = plan.left;
    final pool = plan.expense + (left > 0 ? left : 0);
    final used = pool > 0 ? plan.expense / pool : 0.0;
    final ringColor = left < 0
        ? critical(context)
        : (used >= 0.9 ? series(context, 'caution') : Theme.of(context).colorScheme.primary);
    String eyebrow, big, sub;
    Color? bigColor;
    if (plan.income == 0 && plan.expense == 0 && left == 0) {
      (eyebrow, big, sub) = ('Left to spend in $month', money.fmt(0),
          'Add what comes in and goes out this month, and Kaiji works out what you can spend');
    } else if (left > 0) {
      eyebrow = 'Left to spend in $month';
      big = money.fmt(left);
      sub = plan.daysLeft > 1
          ? 'About ${money.fmt(plan.perDay)} a day for the ${plan.daysLeft} days left'
          : 'Today is the last day of the month';
    } else if (plan.basis == 'income' && plan.budgetRoom <= plan.cashRoom) {
      eyebrow = left < 0 ? 'Over budget in $month' : 'Nothing left to spend in $month';
      big = money.fmt(left);
      bigColor = left < 0 ? critical(context) : null;
      final goal = plan.goal != 0 ? ' and your savings goal' : '';
      sub = left < 0
          ? "Expenses are ${money.fmt(-left)} more than $month's income$goal allow"
          : "Expenses use up $month's income$goal";
    } else {
      eyebrow = 'Nothing left to spend in $month';
      big = money.fmt(0);
      sub = 'Your balance is heading for ${money.fmt(plan.lowest)} on ${fmtShort(plan.lowestDay)}, below $below';
    }
    final counted = [
      if (plan.plannedExpense != 0) '${money.fmt(plan.plannedExpense)} still to pay',
      if (plan.goal != 0 && plan.basis == 'income') '${money.fmt(plan.goal)} for savings',
    ];
    var detail = counted.isEmpty ? '' : 'Already counts ${counted.join(' and ')}.';
    final limited = left > 0 && plan.limitedByBalance;
    if (limited) detail = 'Kept down so your balance stays above $below on ${fmtShort(plan.lowestDay)}. $detail';

    final upcoming = ledger.upcoming(now, _upcomingDays);
    final shown = upcoming.take(_upcomingRows).toList();
    final spentCount = day.items.where((i) => i.kind == 'expense').length;
    final start = state.plan.startDate;

    return CustomScrollView(slivers: [
      SliverAppBar.large(
        title: const Text('Today'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('${weekdaysShort[now.weekday - 1]} · ${fmtDate(now)}',
                style: text.bodyMedium?.copyWith(color: secondaryText(context))),
          ),
        ],
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        sliver: SliverList.list(children: [
          if (notice != null) ...[notice, const SizedBox(height: 12)],
          Card.filled(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                SizedBox(
                  width: 104,
                  height: 104,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: left < 0 ? 1 : used.clamp(0, 1).toDouble(),
                        strokeWidth: 9,
                        strokeCap: StrokeCap.round,
                        color: ringColor,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(left < 0 ? 'Over' : '${(used.clamp(0, 1) * 100).round()}%',
                          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                      Text(left < 0 ? 'budget' : 'used', style: text.labelSmall?.copyWith(color: secondaryText(context))),
                    ]),
                  ]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(eyebrow, style: text.bodyMedium?.copyWith(color: secondaryText(context))),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(big,
                          style: text.displaySmall?.copyWith(fontWeight: FontWeight.w600, color: bigColor)),
                    ),
                    Text(sub, style: text.bodyMedium?.copyWith(color: secondaryText(context))),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(detail,
                          style: text.bodySmall
                              ?.copyWith(color: limited ? series(context, 'caution') : tertiaryText(context))),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          TileGrid([
            StatTile(
              caption: 'Balance now',
              value: money.fmt(day.balance),
              note: start != null
                  ? 'Counting from ${money.fmt(state.plan.startBalance)} on ${fmtDate(start)}'
                  : 'No starting balance yet',
              color: day.balance < floor ? critical(context) : null,
            ),
            StatTile(
              caption: 'End of $month',
              value: '≈ ${money.fmt(plan.closing)}',
              note: '${money.fmt(plan.closing - day.balance, sign: true)} from today',
            ),
            StatTile(
              caption: 'Lowest in the next $_lookahead days',
              value: money.fmt(low),
              note: '${weekdaysShort[lowDay.weekday - 1]}, ${fmtShort(lowDay)}${low < floor ? ' · below $below' : ''}',
              color: low < floor ? critical(context) : null,
            ),
            StatTile(
              caption: 'Spent today',
              value: money.fmt(day.expense),
              note: spentCount > 0 ? plural(spentCount, 'expense', 'expenses') : 'Nothing spent yet',
            ),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Coming up · next $_upcomingDays days',
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 12, bottom: 8),
                    child: Text(
                        'Nothing planned. Add your pay, rent and bills as repeating entries and they show up here '
                        'before they happen.',
                        style: TextStyle(color: secondaryText(context))),
                  )
                : Column(children: [
                    for (final (item, balance) in shown)
                      EntryTile(
                        item: item,
                        dated: true,
                        balance: balance,
                        onTap: () => editItem(context, item),
                        onMenu: () => itemMenu(context, item),
                      ),
                    if (upcoming.length > shown.length)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Text('…and ${upcoming.length - shown.length} more in the calendar',
                            style: text.bodySmall?.copyWith(color: tertiaryText(context))),
                      ),
                  ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Balance · last 30 days and next 90',
            child: BalanceChart(days: ledger.days(addDays(now, -30), addDays(now, 90)), today: now, floor: floor),
          ),
        ]),
      ),
    ]);
  }
}
