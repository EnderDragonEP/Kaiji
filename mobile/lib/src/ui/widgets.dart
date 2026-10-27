/// Pieces the screens share: access to the state, stat tiles, titled cards and entry rows.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../dates.dart';
import '../ledger.dart';
import '../models.dart';
import '../money.dart' as money;
import 'look.dart';

/// Hands the [KaijiState] down; screens that read it with [of] rebuild when it changes.
class KaijiScope extends InheritedNotifier<KaijiState> {
  const KaijiScope({super.key, required KaijiState state, required super.child}) : super(notifier: state);

  static KaijiState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KaijiScope>()!.notifier!;

  /// The state without rebuilding on changes, for callbacks.
  static KaijiState read(BuildContext context) => context.getInheritedWidgetOfExactType<KaijiScope>()!.notifier!;
}

String plural(int n, String one, String many) {
  final digits = n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$digits ${n == 1 ? one : many}';
}

/// Caption, value and a note.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.caption, required this.value, this.note = '', this.color});
  final String caption, value, note;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(caption, style: text.labelMedium?.copyWith(color: secondaryText(context))),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: text.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(note, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: tertiaryText(context))),
          ],
        ]),
      ),
    );
  }
}

/// Two tiles per row; a last one on its own takes the whole row.
class TileGrid extends StatelessWidget {
  const TileGrid(this.tiles, {super.key});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < tiles.length; i += 2)
          Padding(
            padding: EdgeInsets.only(bottom: i + 2 < tiles.length ? 8 : 0),
            child: i + 1 < tiles.length
                ? IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: tiles[i]),
                      const SizedBox(width: 8),
                      Expanded(child: tiles[i + 1]),
                    ]),
                  )
                : SizedBox(width: double.infinity, child: tiles[i]), // an odd one out gets the row
          ),
      ]);
}

/// A card with a title, like the desktop's header cards.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16)});
  final String title;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card.outlined(
        child: Padding(
          padding: padding,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

/// (title, subtitle) for an item: the note (or the category) and what's around it; [brief]
/// leaves out how a repeating entry repeats.
(String, String) describeItem(KaijiState state, Item item, {bool brief = false}) {
  final category = state.category(item.categoryId);
  final title = item.note.isNotEmpty ? item.note : category.name;
  final parts = [if (item.note.isNotEmpty) category.name];
  if (item.repeating) {
    final rule = state.rule(item.ruleId);
    if (!brief) parts.add(rule != null ? describeRule(rule) : 'Repeating');
    if (rule?.times != null) parts.add('${dateNumber(rule!, item.day)} of ${rule.times}');
  }
  return (title, parts.join(' · '));
}

/// One entry: icon, what it was, the amount; tap to edit, long-press (or ⋯) for more.
class EntryTile extends StatelessWidget {
  const EntryTile({super.key, required this.item, this.dated = false, this.balance, this.onTap, this.onMenu});
  final Item item;
  final bool dated;
  final int? balance; // shown under the amount
  final VoidCallback? onTap;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final (title, subtitle) = describeItem(state, item, brief: dated);
    final future = item.day.isAfter(today());
    final text = Theme.of(context).textTheme;
    final sub = [
      if (dated) '${weekdaysShort[item.day.weekday - 1]}, ${fmtShort(item.day)}',
      if (subtitle.isNotEmpty) subtitle,
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 4, right: 0),
      leading: IconBubble(state.category(item.categoryId).icon, item.kind),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(money.fmt(item.signed, sign: true),
              style: text.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600, color: future ? secondaryText(context) : null)),
          if (balance != null)
            Text((future ? '≈ ' : '') + money.fmt(balance!),
                style: text.bodySmall?.copyWith(color: tertiaryText(context))),
        ]),
        if (onMenu != null)
          IconButton(icon: const Icon(Icons.more_vert), tooltip: 'More', onPressed: onMenu)
        else
          const SizedBox(width: 12),
      ]),
      onTap: onTap,
      onLongPress: onMenu,
    );
  }
}

/// A notice inside a page: setup to do, or a warning about the balance ahead.
class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.icon, required this.title, required this.text, this.action, this.onAction, this.warning = false});
  final IconData icon;
  final String title, text;
  final String? action;
  final VoidCallback? onAction;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      color: warning ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: warning ? scheme.onErrorContainer : scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(text, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ]),
          if (action != null)
            Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onAction, child: Text(action!))),
        ]),
      ),
    );
  }
}

/// The app's messenger, so a message can follow a screen that has closed.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// A snack bar with Undo.
void showUndo(String message, Future<void> Function() undo) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: 'Undo', onPressed: () => undo()),
    ));
}

void showMessage(String message) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
}

/// A yes/no question; true for yes.
Future<bool> confirm(BuildContext context, String title, String text, {String yes = 'Delete'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;
