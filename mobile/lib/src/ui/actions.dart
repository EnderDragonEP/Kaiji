/// The entry actions every screen shares - add, edit, skip and delete, with undo - like the
/// desktop's main_window.py.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../dates.dart';
import '../ledger.dart';
import '../models.dart';
import '../money.dart' as money;
import 'entry_page.dart';
import 'widgets.dart';

Future<EntryResult?> _open(BuildContext context, EntryMode mode, EntryValues initial) =>
    Navigator.of(context).push<EntryResult>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => EntryPage(state: KaijiScope.read(context), mode: mode, initial: initial),
    ));

Future<void> addEntry(BuildContext context, {DateTime? day, String kind = 'expense', String? repeat, EntryValues? from}) async {
  final state = KaijiScope.read(context);
  final initial = from ??
      EntryValues(kind: kind, amount: 0, categoryId: null, day: day ?? today(), freq: repeat);
  final result = await _open(context, EntryMode.add, initial);
  if (result?.values != null) await state.saveEntry(result!.values!);
}

/// Tapping an entry edits it; a repeating date edits the whole repeating entry.
Future<void> editItem(BuildContext context, Item item) =>
    item.repeating ? editRule(context, item.ruleId!) : editEntry(context, item.entryId!);

Future<void> editEntry(BuildContext context, int entryId) async {
  final state = KaijiScope.read(context);
  final entry = state.data.entries.where((e) => e.id == entryId).firstOrNull;
  if (entry == null) return;
  final item = Item(entry.day, entry.kind, entry.amount, entry.categoryId, entry.note, entryId: entry.id);
  final result = await _open(context, EntryMode.entry, EntryValues.of(item));
  if (result == null || !context.mounted) return;
  if (result.deleted) {
    await deleteEntry(context, entryId);
  } else if (result.values != null) {
    await state.saveEntry(result.values!, entryId: entryId);
  }
}

/// mode: series (every date), later (from [day] on) or date (only [day]).
Future<void> editRule(BuildContext context, int ruleId, {EntryMode mode = EntryMode.series, DateTime? day}) async {
  final state = KaijiScope.read(context);
  final rule = state.rule(ruleId);
  if (rule == null) return;
  final from = mode == EntryMode.series ? rule.start : day!;
  // from the 5th of 12 times on, 8 are left
  final times = mode == EntryMode.later && rule.times != null ? (rule.times! - dateNumber(rule, from) + 1) : null;
  final result = await _open(context, mode, EntryValues.ofRule(rule, from, times: times));
  if (result == null || !context.mounted) return;
  if (result.deleted) {
    await deleteRule(context, ruleId, ask: true);
  } else if (result.values != null) {
    final v = result.values!;
    switch (mode) {
      case EntryMode.later:
        await state.changeFrom(ruleId, v);
      case EntryMode.date:
        await state.editDate(ruleId, from, v);
      default:
        await state.saveRule(ruleId, v);
    }
  }
}

Future<void> deleteEntry(BuildContext context, int entryId) async {
  final state = KaijiScope.read(context);
  final entry = state.data.entries.firstWhere((e) => e.id == entryId);
  final undo = await state.deleteEntry(entryId);
  final name = entry.note.isNotEmpty ? entry.note : state.category(entry.categoryId).name;
  showUndo('Deleted $name · ${money.fmt(entry.amount)}', undo);
}

Future<void> deleteRule(BuildContext context, int ruleId, {bool ask = false}) async {
  final state = KaijiScope.read(context);
  final rule = state.rule(ruleId);
  if (rule == null) return;
  if (ask &&
      !await confirm(context, 'Delete this repeating entry?',
          'Every date it falls on goes, past ones too. To keep the past, use "Stop after this date" on a date '
              'in the calendar instead.')) {
    return;
  }
  final undo = await state.deleteRule(ruleId);
  showUndo('Deleted ${rule.note.isNotEmpty ? rule.note : state.category(rule.categoryId).name}', undo);
}

/// Everything dated [start] to [end], repeating dates included, as CSV with the desktop's
/// columns.
String entriesCsv(KaijiState state, DateTime start, DateTime end) {
  final now = today();
  String cell(String s) => s.contains(RegExp('[",\r\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
  final rows = [
    ['Date', 'Type', 'Category', 'Amount', 'Note', 'Repeats', 'Planned'],
    for (final item in state.ledger.items(start, end))
      [
        iso(item.day),
        item.kind == 'income' ? 'Income' : 'Expense',
        state.category(item.categoryId).name,
        money.plain(item.signed),
        item.note,
        switch (state.rule(item.ruleId)) { final r? => describeRule(r), null => '' },
        item.day.isAfter(now) ? 'yes' : '',
      ],
  ];
  return [for (final r in rows) '${r.map(cell).join(',')}\r\n'].join();
}

/// [entriesCsv] as a file to share, UTF-8 with a BOM so Excel reads 花錢 right.
Future<void> shareCsv(KaijiState state, DateTime start, DateTime end, String name) async {
  try {
    final file = File(p.join((await getTemporaryDirectory()).path, name));
    await file.writeAsString('﻿${entriesCsv(state, start, end)}');
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'text/csv')], subject: name));
  } catch (e) {
    showMessage("Couldn't export: $e");
  }
}

/// The long-press menu of an entry, or of one date of a repeating entry.
Future<void> itemMenu(BuildContext context, Item item) async {
  final state = KaijiScope.read(context);
  final (title, _) = describeItem(state, item);
  Widget option(IconData icon, String text, Future<void> Function() run) => ListTile(
        leading: Icon(icon),
        title: Text(text),
        onTap: () async {
          Navigator.pop(context);
          await run();
        },
      );
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(title, style: Theme.of(sheet).textTheme.titleMedium), subtitle: Text(fmtLong(item.day))),
        const Divider(height: 1),
        if (item.repeating) ...[
          option(Icons.edit_outlined, 'Edit this date only', () => editRule(context, item.ruleId!, mode: EntryMode.date, day: item.day)),
          option(Icons.edit_calendar_outlined, 'Edit this and later dates',
              () => editRule(context, item.ruleId!, mode: EntryMode.later, day: item.day)),
          option(Icons.sync, 'Edit all dates', () => editRule(context, item.ruleId!)),
          option(Icons.remove_circle_outline, 'Skip this date', () async {
            showUndo('Skipped ${fmtDate(item.day)}', await state.skip(item.ruleId!, item.day));
          }),
          option(Icons.pause_circle_outline, 'Stop after this date', () async {
            showUndo('The last date is now ${fmtDate(item.day)}', await state.stopAfter(item.ruleId!, item.day));
          }),
          option(Icons.delete_outline, 'Delete all dates', () => deleteRule(context, item.ruleId!, ask: true)),
        ] else ...[
          option(Icons.edit_outlined, 'Edit', () => editEntry(context, item.entryId!)),
          option(Icons.content_copy, 'Duplicate', () => addEntry(context, from: EntryValues.of(item))),
          option(Icons.delete_outline, 'Delete', () => deleteEntry(context, item.entryId!)),
        ],
      ]),
    ),
  );
}
