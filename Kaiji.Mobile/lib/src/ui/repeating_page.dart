/// Repeating entries: pay, rent, bills and subscriptions that come back on their own, with what
/// they add up to per month.
library;

import 'package:flutter/material.dart';

import '../dates.dart';
import '../ledger.dart';
import '../models.dart';
import '../money.dart' as money;
import 'actions.dart';
import 'look.dart';
import 'widgets.dart';

class RepeatingPage extends StatelessWidget {
  const RepeatingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final now = today();
    final text = Theme.of(context).textTheme;
    final rules = [...state.data.rules];
    bool active(Rule r) => (lastDate(r) ?? now).compareTo(now) >= 0;
    final live = rules.where(active).toList();
    final income = live.where((r) => r.kind == 'income').fold(0, (s, r) => s + perMonth(r));
    final expense = live.where((r) => r.kind == 'expense').fold(0, (s, r) => s + perMonth(r));
    final countIn = live.where((r) => r.kind == 'income').length;
    final next = {for (final r in rules) r.id: nextDate(r, now)};
    rules.sort((a, b) {
      final na = next[a.id], nb = next[b.id];
      if ((na == null) != (nb == null)) return na == null ? 1 : -1;
      return (na ?? lastDate(a) ?? a.start).compareTo(nb ?? lastDate(b) ?? b.start);
    });

    Widget tile(Rule r) {
      final category = state.category(r.categoryId);
      final name = r.note.isNotEmpty ? r.note : category.name;
      final n = next[r.id], last = lastDate(r);
      final when = n == null
          ? 'Ended ${fmtDate(last!)}'
          : [
              'Next ${fmtShort(n)}',
              if (r.times != null) '${dateNumber(r, n)} of ${r.times}',
              if (last != null) 'last ${fmtDate(last)}',
            ].join(' · ');
      return ListTile(
        leading: IconBubble(category.icon, r.kind),
        // the amount beside the name, so the two lines under it have the whole width
        title: Row(children: [
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(money.fmt(r.signed, sign: true), style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ]),
        subtitle: Text('${describeRule(r)}\n$when'),
        isThreeLine: true,
        onTap: () => editRule(context, r.id),
        onLongPress: () async {
          if (await confirm(context, 'Delete $name?', 'Every date it falls on goes, past ones too.') &&
              context.mounted) {
            await deleteRule(context, r.id);
          }
        },
      );
    }

    return CustomScrollView(slivers: [
      const SliverAppBar.large(title: Text('Repeating')),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        sliver: SliverList.list(children: [
          Text('Add pay, rent, bills and subscriptions once: they appear on every date they fall on, so the '
              'calendar can look ahead.', style: text.bodyMedium?.copyWith(color: secondaryText(context))),
          const SizedBox(height: 12),
          TileGrid([
            StatTile(caption: 'Income per month', value: money.fmt(income), note: plural(countIn, 'entry', 'entries')),
            StatTile(
                caption: 'Expenses per month',
                value: money.fmt(expense),
                note: plural(live.length - countIn, 'entry', 'entries')),
            StatTile(
              caption: 'Left over per month',
              value: money.fmt(income - expense, sign: true),
              note: 'Before day-to-day spending; weekly and yearly ones are averaged',
              color: income < expense ? critical(context) : null,
            ),
          ]),
          const SizedBox(height: 12),
          if (rules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('No repeating entries yet. Your pay and rent are good ones to start with.',
                  style: TextStyle(color: secondaryText(context))),
            )
          else
            Card.outlined(child: Column(children: [for (final r in rules) tile(r)])),
        ]),
      ),
    ]);
  }
}
