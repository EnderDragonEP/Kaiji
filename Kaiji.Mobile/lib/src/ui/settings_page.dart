/// Settings, the categories, and the first-run setup. Changes apply as soon as they're made.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../dates.dart';
import '../models.dart';
import '../money.dart' as money;
import 'actions.dart';
import 'look.dart';
import 'sync_page.dart';
import 'widgets.dart';

const _bases = {'income': "This month's income", 'balance': 'Everything I have'};

Future<void> openWelcome(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const WelcomePage()));

/// An amount from a dialog: null if cancelled, (true, null) if cleared.
Future<(bool, int?)?> askAmount(BuildContext context, String title,
    {int? initial, bool allowNegative = false, String? note}) {
  final field = TextEditingController(text: initial != null && initial != 0 ? money.editText(initial) : '');
  return showDialog<(bool, int?)>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final textValue = field.text.trim();
      final cents = money.tryParse(textValue, allowNegative: allowNegative);
      final valid = textValue.isEmpty || cents != null;
      return AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (note != null) ...[Text(note), const SizedBox(height: 12)],
          TextField(
            controller: field,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: true, signed: allowNegative),
            decoration: InputDecoration(
              prefixText: '${money.symbol} ',
              border: const OutlineInputBorder(),
              errorText: valid ? null : "That isn't an amount.",
            ),
            onChanged: (_) => setState(() {}),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: valid ? () => Navigator.pop(context, (true, textValue.isEmpty ? null : cents)) : null,
            child: const Text('Save'),
          ),
        ],
      );
    }),
  );
}

Future<T?> askChoice<T>(BuildContext context, String title, Map<T, String> choices, T current) =>
    showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(title: Text(title), children: [
        RadioGroup<T>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(context, v),
          child: Column(children: [
            for (final e in choices.entries) RadioListTile<T>(value: e.key, title: Text(e.value)),
          ]),
        ),
      ]),
    );

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final plan = state.plan;
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(text,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );
    return CustomScrollView(slivers: [
      const SliverAppBar.large(title: Text('Settings')),
      SliverList.list(children: [
        header('Your plan'),
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('Starting balance'),
          subtitle: Text(plan.startDate != null
              ? '${money.fmt(plan.startBalance)} at the start of ${fmtDate(plan.startDate!)}'
              : 'Not set: balances add up from your first entry'),
          onTap: () => _startBalance(context, state),
        ),
        ListTile(
          leading: const Icon(Icons.pie_chart_outline),
          title: const Text('Left to spend comes from'),
          subtitle: Text(_bases[plan.basis]!),
          onTap: () async {
            final basis = await askChoice(context, 'Left to spend comes from', _bases, plan.basis);
            if (basis != null) await state.setPlan(state.plan.copyWith(basis: basis));
          },
        ),
        ListTile(
          leading: const Icon(Icons.eco_outlined),
          title: const Text('Monthly savings goal'),
          subtitle: Text(plan.savingsGoal != 0
              ? '${money.fmt(plan.savingsGoal)} set aside from each month\'s income'
              : 'None'),
          onTap: () async {
            final r = await askAmount(context, 'Monthly savings goal', initial: plan.savingsGoal,
                note: "Set aside from each month's income and not counted as money to spend.");
            if (r != null) await state.setPlan(state.plan.copyWith(savingsGoal: r.$2 ?? 0));
          },
        ),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Keep at least'),
          subtitle: Text(plan.minBalance != 0 ? money.fmt(plan.minBalance) : 'None'),
          onTap: () async {
            final r = await askAmount(context, 'Keep at least', initial: plan.minBalance,
                note: 'Kaiji warns you when your balance is heading below this, and never counts it as money to spend.');
            if (r != null) await state.setPlan(state.plan.copyWith(minBalance: r.$2 ?? 0));
          },
        ),
        header('Currency'),
        ListTile(
          leading: const Icon(Icons.sell_outlined),
          title: const Text('Currency symbol'),
          subtitle: Text(state.data.currency),
          onTap: () async {
            final symbol = await _askSymbol(context, state.data.currency);
            if (symbol != null) await state.setCurrency(symbol, state.data.decimals);
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.straighten),
          title: const Text('Show cents'),
          subtitle: const Text('How amounts are shown; cents you enter are always kept'),
          value: state.data.decimals == 2,
          onChanged: (on) => state.setCurrency(state.data.currency, on ? 2 : 0),
        ),
        header('Categories'),
        for (final (kind, icon, title) in [
          ('expense', Icons.shopping_cart_outlined, 'Expense categories'),
          ('income', Icons.trending_up, 'Income categories'),
        ])
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(plural(state.kindCategories(kind).length, 'category', 'categories')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => CategoriesPage(kind: kind))),
          ),
        header('Calendar and look'),
        ListTile(
          leading: const Icon(Icons.calendar_month_outlined),
          title: const Text('First day of the week'),
          subtitle: Text(state.weekStart == 6 ? 'Sunday' : 'Monday'),
          onTap: () async {
            final day = await askChoice(context, 'First day of the week', {0: 'Monday', 6: 'Sunday'}, state.weekStart);
            if (day != null) await state.setWeekStart(day);
          },
        ),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('Theme'),
          subtitle: Text(const {ThemeMode.system: 'Use system setting', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'}[
              state.themeMode]!),
          onTap: () async {
            final mode = await askChoice(context, 'Theme',
                {ThemeMode.system: 'Use system setting', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'}, state.themeMode);
            if (mode != null) await state.setThemeMode(mode);
          },
        ),
        if (state.wallpaper != null)
          SwitchListTile(
            secondary: const Icon(Icons.palette_outlined),
            title: const Text('Wallpaper colors'),
            subtitle: const Text("Use your phone's colors instead of Kaiji green"),
            value: state.wallpaperColors,
            onChanged: state.setWallpaperColors,
          ),
        header('Your data'),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('Back up'),
          subtitle: const Text('Send a copy of all your data somewhere safe. It opens in Kaiji on your PC too.'),
          onTap: () => _backup(context, state),
        ),
        ListTile(
          leading: const Icon(Icons.table_view_outlined),
          title: const Text('Export CSV'),
          subtitle: const Text('Every entry, with repeating dates up to a year ahead, for a spreadsheet'),
          onTap: () {
            final now = today();
            final first = [for (final e in state.data.entries) e.day, for (final r in state.data.rules) r.start]
                .fold(now, (a, b) => b.isBefore(a) ? b : a);
            shareCsv(state, first, addDays(now, 366), 'kaiji ${iso(now)}.csv');
          },
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('Restore'),
          subtitle: const Text('Replace everything with a backup from this phone or from Kaiji on your PC'),
          onTap: () => _restore(context, state),
        ),
        ListenableBuilder(
          listenable: state.syncer,
          builder: (context, _) => ListTile(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Sync with PostgreSQL'),
            subtitle: Text(state.syncer.describe()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncPage())),
          ),
        ),
        header('About'),
        ListTile(
          leading: Image.asset('assets/kaiji.png', width: 24, height: 24),
          title: const Text('Kaiji 花錢'),
          subtitle: const Text('Version 1.0 · A monthly spending tracker with a calendar that looks ahead'),
        ),
        ListTile(
          leading: const Icon(Icons.replay),
          title: const Text('Run setup again'),
          onTap: () => openWelcome(context),
        ),
        const SizedBox(height: 32),
      ]),
    ]);
  }

  Future<void> _startBalance(BuildContext context, KaijiState state) async {
    var day = state.plan.startDate ?? today();
    final field = TextEditingController(
        text: state.plan.startDate != null ? money.editText(state.plan.startBalance) : '');
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        final value = money.tryParse(field.text, allowNegative: true);
        final valid = field.text.trim().isEmpty || value != null;
        return AlertDialog(
          title: const Text('Starting balance'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("What you had at the start of a day, all accounts together. Every other day's balance is "
                'worked out from it.'),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(
                  prefixText: '${money.symbol} ',
                  border: const OutlineInputBorder(),
                  errorText: valid ? null : "That isn't an amount."),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined),
              label: Text('At the start of ${fmtDate(day)}'),
              onPressed: () async {
                final picked = await showDatePicker(
                    context: context, initialDate: day, firstDate: DateTime.utc(2000), lastDate: DateTime.utc(2100));
                if (picked != null) setState(() => day = dateOf(picked));
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'clear'), child: const Text('Clear')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: valid ? () => Navigator.pop(context, 'save') : null, child: const Text('Save')),
          ],
        );
      }),
    );
    if (saved == 'clear') {
      await state.setPlan(state.plan.copyWith(startBalance: 0, clearStart: true));
    } else if (saved == 'save') {
      final value = money.tryParse(field.text, allowNegative: true);
      await state.setPlan(value == null
          ? state.plan.copyWith(startBalance: 0, clearStart: true)
          : state.plan.copyWith(startBalance: value, startDate: day));
    }
  }

  Future<String?> _askSymbol(BuildContext context, String current) {
    final custom = TextEditingController(text: money.currencies.contains(current) ? '' : current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Currency symbol'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final s in money.currencies)
                ChoiceChip(label: Text(s), selected: s == current, onSelected: (_) => Navigator.pop(context, s)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: custom,
              decoration: const InputDecoration(labelText: 'Another symbol', border: OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, custom.text.trim().isEmpty ? null : custom.text.trim()),
            child: const Text('Use'),
          ),
        ],
      ),
    );
  }

  Future<void> _backup(BuildContext context, KaijiState state) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, 'Kaiji backup ${iso(today())}.db');
      await state.store.backupTo(path);
      await SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: 'Kaiji backup'));
    } catch (e) {
      showMessage("Couldn't make the backup: $e");
    }
  }

  Future<void> _restore(BuildContext context, KaijiState state) async {
    final picked = await FilePicker.pickFile(dialogTitle: 'Choose a Kaiji backup');
    if (picked == null || !context.mounted) return;
    final also = state.syncer.enabled
        ? ' Sync is on, so the server and your other devices get the backup\'s data too.'
        : '';
    if (!await confirm(context, 'Restore this backup?', 'Everything in Kaiji now is replaced by the backup.$also',
        yes: 'Restore')) {
      return;
    }
    try {
      final temp = (await getTemporaryDirectory()).path;
      // a copy of our own: the picker may hand over a file that isn't on disk
      final copy = File(p.join(temp, 'restore.db'));
      await copy.writeAsBytes(await picked.readAsBytes(), flush: true);
      final before = p.join(temp, 'before restore.db'); // what Undo puts back
      await state.store.backupTo(before);
      await state.restore(copy.path);
      await copy.delete();
      showUndo('Restored ${picked.name}', () => state.restore(before));
    } on FormatException catch (e) {
      showMessage(e.message);
    } catch (e) {
      showMessage("Couldn't restore: $e");
    }
  }
}

// ---------------------------------------------------------------- categories

class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key, required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final state = KaijiScope.of(context);
    final cats = state.kindCategories(kind);
    return Scaffold(
      appBar: AppBar(title: Text(kind == 'expense' ? 'Expense categories' : 'Income categories')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Category'),
        onPressed: () async {
          final r = await _editCategory(context, kind == 'expense' ? 'New expense category' : 'New income category');
          if (r != null) await state.addCategory(kind, r.$1, r.$2);
        },
      ),
      body: ReorderableListView(
        padding: const EdgeInsets.only(bottom: 96),
        onReorderItem: (from, to) {
          final ids = [for (final c in cats) c.id];
          ids.insert(to, ids.removeAt(from));
          state.reorderCategories(ids);
        },
        children: [
          for (final (i, c) in cats.indexed)
            ListTile(
              key: ValueKey(c.id),
              leading: IconBubble(c.icon, kind),
              title: Text(c.name),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _delete(context, state, c),
                ),
                // drags right away; a long press anywhere on the row does too
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle)),
                ),
              ]),
              onTap: () async {
                final r = await _editCategory(context, 'Edit category', name: c.name, icon: c.icon);
                if (r != null) await state.updateCategory(c.id, r.$1, r.$2);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, KaijiState state, Category c) async {
    final uses = await state.store.categoryUses(c.id);
    if (!context.mounted) return;
    final others = [for (final o in state.kindCategories(c.kind)) if (o.id != c.id) o];
    if (uses == 0) {
      if (await confirm(context, 'Delete "${c.name}"?', 'No entries use it.')) await state.deleteCategory(c.id, null);
      return;
    }
    if (others.isEmpty) {
      showMessage("Can't delete the last category: add another one first, so its entries have somewhere to go.");
      return;
    }
    var target = others.first.id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Delete "${c.name}"?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${plural(uses, 'entry uses', 'entries use')} this category. Move them to:'),
            const SizedBox(height: 8),
            DropdownButton<int>(
              value: target,
              isExpanded: true,
              items: [for (final o in others) DropdownMenuItem(value: o.id, child: Text(o.name))],
              onChanged: (v) => setState(() => target = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        ),
      ),
    );
    if (ok == true) await state.deleteCategory(c.id, target);
  }

  /// (name, icon) from a dialog, or null.
  Future<(String, String)?> _editCategory(BuildContext context, String title, {String name = '', String icon = 'TAG'}) {
    final field = TextEditingController(text: name);
    var picked = icon;
    return showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: field,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 4, runSpacing: 4, children: [
                for (final key in iconChoices.contains(icon) ? iconChoices : [icon, ...iconChoices])
                  IconButton(
                    isSelected: key == picked,
                    icon: Icon(categoryIcon(key)),
                    style: IconButton.styleFrom(
                      backgroundColor: key == picked ? Theme.of(context).colorScheme.primaryContainer : null,
                    ),
                    onPressed: () => setState(() => picked = key),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: field.text.trim().isEmpty ? null : () => Navigator.pop(context, (field.text.trim(), picked)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- first run

/// First run: the currency, what you have today, and optionally your pay and savings goal.
/// Run again from Settings, it starts from what's set now.
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  late final KaijiState state;
  late String symbol;
  late bool cents;
  late final Rule? salary; // the monthly pay set up here before
  late final DayInfo now;
  late final TextEditingController balance, pay, goal;
  late int payDay;
  late final (int?, int?, int) initial; // what the fields start with: only what changes is saved

  @override
  void initState() {
    super.initState();
    state = KaijiScope.read(context);
    symbol = state.data.currency;
    cents = state.data.decimals == 2;
    salary = state.data.rules
        .where((r) => r.kind == 'income' && r.freq == 'month' && r.note == 'Salary' && r.until == null && r.times == null)
        .firstOrNull;
    now = state.ledger.days(today(), today()).first;
    balance = TextEditingController(text: state.plan.startDate != null ? money.editText(now.balance) : '');
    pay = TextEditingController(text: salary != null ? money.editText(salary!.amount) : '');
    payDay = salary?.start.day ?? 5;
    goal = TextEditingController(text: state.plan.savingsGoal != 0 ? money.editText(state.plan.savingsGoal) : '');
    initial = (money.tryParse(balance.text, allowNegative: true), money.tryParse(pay.text), payDay);
  }

  @override
  void dispose() {
    balance.dispose();
    pay.dispose();
    goal.dispose();
    super.dispose();
  }

  bool _valid(TextEditingController c, {bool negative = false}) =>
      c.text.trim().isEmpty || money.tryParse(c.text, allowNegative: negative) != null;

  Future<void> _finish(bool apply) async {
    if (apply) {
      final day = today();
      await state.setCurrency(symbol, cents ? 2 : 0);
      var plan = state.plan;
      final value = money.tryParse(balance.text, allowNegative: true);
      if (value != null && value != initial.$1) {
        // what you have now, today's entries included
        plan = plan.copyWith(startBalance: value - (now.income - now.expense), startDate: day);
      }
      plan = plan.copyWith(savingsGoal: money.tryParse(goal.text) ?? 0);
      await state.setPlan(plan);
      final amount = money.tryParse(pay.text);
      if (amount != null && (amount, payDay) != (initial.$2, initial.$3)) {
        // from this month, or the last month that has the day (pay on the 31st starts in a long month)
        var month = ymd(day.year, day.month, 1);
        while (monthBounds(month.year, month.month).$2.day < payDay) {
          month = addMonths(month, -1);
        }
        final category = salary?.categoryId ??
            state.kindCategories('income').where((c) => c.name == 'Salary').firstOrNull?.id;
        final v = EntryValues(
            kind: 'income', amount: amount, categoryId: category, day: ymd(month.year, month.month, payDay),
            note: 'Salary', freq: 'month');
        if (salary != null) {
          await state.changeFrom(salary!.id, v); // the new pay from this month on
        } else {
          await state.saveEntry(v);
        }
      }
    }
    await state.setWelcomed();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ok = _valid(balance, negative: true) && _valid(pay) && _valid(goal);
    InputDecoration field(String label, {String? hint, bool error = false}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixText: '$symbol ',
        border: const OutlineInputBorder(),
        errorText: error ? "That isn't an amount." : null);
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to Kaiji 花錢'), automaticallyImplyLeading: false),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text('A few numbers so Kaiji can tell you how much you can spend. All of them can be changed later in '
            'Settings.', style: text.bodyLarge),
        const SizedBox(height: 20),
        Text('Currency', style: text.labelLarge?.copyWith(color: secondaryText(context))),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final s in {...money.currencies, symbol})
            ChoiceChip(
              label: Text(s),
              selected: s == symbol,
              onSelected: (_) => setState(() {
                symbol = s;
                final code = money.symbols.entries.where((e) => e.value == s).firstOrNull?.key ?? '';
                cents = !money.noDecimals.contains(code);
              }),
            ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show cents'),
          value: cents,
          onChanged: (v) => setState(() => cents = v),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: balance,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: field('Money you have today', hint: 'e.g. 52,000', error: !_valid(balance, negative: true)),
          onChanged: (_) => setState(() {}),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Text('All your accounts together; Kaiji works out the balance of every day from here.',
              style: text.bodySmall?.copyWith(color: tertiaryText(context))),
        ),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: pay,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: field('Monthly pay', hint: 'optional', error: !_valid(pay)),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<int>(
              initialValue: payDay,
              decoration: const InputDecoration(labelText: 'On day', border: OutlineInputBorder()),
              items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
              onChanged: (v) => setState(() => payDay = v!),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: goal,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: field('Savings goal per month', hint: 'optional', error: !_valid(goal)),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: ok ? () => _finish(true) : null, child: const Text('Get started')),
        const SizedBox(height: 8),
        TextButton(onPressed: () => _finish(false), child: const Text('Skip')),
      ]),
    );
  }
}
