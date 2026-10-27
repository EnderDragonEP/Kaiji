/// Add or edit an entry. "Repeats" makes it a repeating entry (salary, rent, subscriptions) that
/// the calendar shows on every date it falls on. The desktop's EntryDialog, for a phone.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../dates.dart';
import '../ledger.dart';
import '../models.dart';
import '../money.dart' as money;
import 'look.dart';

/// add; entry: a one-off entry; series: every date of a repeating entry; later: a repeating
/// entry from one date on; date: one date of a repeating entry.
enum EntryMode { add, entry, series, later, date }

/// What the editor hands back: the values, or that the entry is to be deleted.
class EntryResult {
  const EntryResult(this.values, {this.deleted = false});
  final EntryValues? values;
  final bool deleted;
}

const _repeats = {null: "Doesn't repeat", 'day': 'Daily', 'week': 'Weekly', 'month': 'Monthly', 'year': 'Yearly'};
const _scopes = {
  EntryMode.series: 'Changes apply to every date, past ones too. To change only from some date on '
      '(a raise, new rent), long-press that date in the calendar.',
  EntryMode.later: 'Dates before this one stay as they were.',
  EntryMode.date: 'Only this date changes; the other dates stay as they are.',
};

class EntryPage extends StatefulWidget {
  const EntryPage({super.key, required this.state, required this.mode, required this.initial});
  final KaijiState state;
  final EntryMode mode;
  final EntryValues initial; // amount 0 when adding

  @override
  State<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<EntryPage> {
  late String kind = widget.initial.kind;
  late final amount = TextEditingController(
      text: widget.initial.amount > 0 ? money.editText(widget.initial.amount) : '');
  late final note = TextEditingController(text: widget.initial.note);
  final noteFocus = FocusNode();
  late int? categoryId = widget.initial.categoryId;
  late bool chosen = widget.mode != EntryMode.add; // a category picked by hand isn't overridden
  late DateTime day = widget.initial.day;
  late String? freq = widget.initial.freq;
  late int every = widget.initial.every;
  late String ends = widget.initial.times != null ? 'times' : (widget.initial.until != null ? 'date' : 'never');
  late DateTime until = widget.initial.until ?? addMonths(widget.initial.day, 12);
  late final times = TextEditingController(text: '${widget.initial.times ?? 12}');
  late final Map<String, (String, int?)> notes = widget.state.notes();
  bool tried = false; // Save was pressed: show what's missing

  @override
  void initState() {
    super.initState();
    _pickCategory();
    note.addListener(_noteChanged);
    amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    noteFocus.dispose();
    times.dispose();
    super.dispose();
  }

  List<Category> get _categories => widget.state.kindCategories(kind);

  void _pickCategory() {
    final ids = [for (final c in _categories) c.id];
    if (!ids.contains(categoryId)) {
      final usual = widget.state.usualCategory(kind);
      categoryId = ids.contains(usual) ? usual : (ids.isEmpty ? null : ids.first);
      chosen = false;
    }
  }

  /// A note typed before brings its category along (until one is picked by hand).
  void _noteChanged() {
    final known = notes[note.text.trim()];
    if (chosen || known == null || known.$1 != kind || known.$2 == null) return;
    if (_categories.any((c) => c.id == known.$2)) setState(() => categoryId = known.$2);
  }

  int? get _amount => money.tryParse(amount.text);
  int? get _times => ends == 'times' ? int.tryParse(times.text) : null;
  DateTime? get _until => ends == 'date' ? until : null;

  // short enough to fit beside Delete and Save; the menu that opened it said which dates
  String get _title {
    final noun = kind == 'expense' ? 'expense' : 'income';
    return switch (widget.mode) {
      EntryMode.add => 'Add $noun',
      EntryMode.entry => 'Edit $noun',
      EntryMode.series => 'Edit all dates',
      EntryMode.later => 'Edit from ${fmtShort(widget.initial.day)}',
      EntryMode.date => 'Edit ${fmtShort(widget.initial.day)} only',
    };
  }

  String? get _repeatHint {
    if (freq == null) return null;
    if (_until != null && _until!.isBefore(day)) return 'The end date is before the first date.';
    if (ends == 'times' && (_times == null || _times! < 1)) return 'Enter how many times.';
    final rule = Rule(0, kind, 0, null, '', freq!, every, day, until: _until, times: _times);
    var text = describeRule(rule);
    if (freq == 'month' && day.day > 28) text += ' (the last day of shorter months)';
    text += ', from ${fmtDate(day)}';
    if (_times == 1) {
      text += ', just once';
    } else if (_times != null) {
      text += ', $_times times: the last is on ${fmtDate(lastDate(rule)!)}';
    } else {
      text += _until != null ? ' until ${fmtDate(_until!)}' : ', with no end date';
    }
    return '$text.';
  }

  bool get _repeatOk =>
      freq == null || ((_until == null || !_until!.isBefore(day)) && (ends != 'times' || (_times ?? 0) >= 1));

  void _save() {
    setState(() => tried = true);
    final cents = _amount;
    if (cents == null || !_repeatOk) return;
    Navigator.pop(
        context,
        EntryResult(EntryValues(
          kind: kind, amount: cents, categoryId: categoryId, day: day, note: note.text.trim(),
          freq: freq, every: freq != null ? every : 1, until: freq != null ? _until : null,
          times: freq != null ? _times : null,
        )));
  }

  void _insert(String op) {
    final sel = amount.selection;
    final text = amount.text;
    final start = sel.isValid ? sel.start : text.length, end = sel.isValid ? sel.end : text.length;
    amount.value = TextEditingValue(
        text: text.replaceRange(start, end, op), selection: TextSelection.collapsed(offset: start + op.length));
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
        context: context, initialDate: day, firstDate: DateTime.utc(2000), lastDate: DateTime.utc(2100));
    if (picked != null) setState(() => day = dateOf(picked));
  }

  Future<void> _pickUntil() async {
    final picked = await showDatePicker(
        context: context, initialDate: until, firstDate: DateTime.utc(2000), lastDate: DateTime.utc(2100));
    if (picked != null) setState(() => until = dateOf(picked));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mode = widget.mode;
    final cents = _amount;
    final String? amountError = amount.text.trim().isEmpty
        ? (tried ? 'Enter an amount.' : null)
        : (cents == null ? "That isn't an amount. Use numbers and + − × ÷." : null);
    final repeats = mode == EntryMode.add || mode == EntryMode.entry
        ? _repeats
        : {for (final e in _repeats.entries) if (e.key != null) e.key: e.value};
    final hint = _repeatHint;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cancel', onPressed: () => Navigator.pop(context)),
        title: Text(_title),
        actions: [
          if (mode == EntryMode.entry || mode == EntryMode.series)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () => Navigator.pop(context, const EntryResult(null, deleted: true)),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: Text(mode == EntryMode.add ? 'Add' : 'Save')),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'expense', label: Text('Expense'), icon: Icon(Icons.remove)),
            ButtonSegment(value: 'income', label: Text('Income'), icon: Icon(Icons.add)),
          ],
          selected: {kind},
          onSelectionChanged: (s) => setState(() {
            kind = s.first;
            _pickCategory();
            _noteChanged();
          }),
        ),
        if (_scopes[mode] != null) ...[
          const SizedBox(height: 12),
          Text(_scopes[mode]!, style: text.bodySmall?.copyWith(color: tertiaryText(context))),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: amount,
          autofocus: mode == EntryMode.add,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          style: text.headlineMedium,
          decoration: InputDecoration(
            labelText: 'Amount',
            prefixText: '${money.symbol} ',
            border: const OutlineInputBorder(),
            errorText: amountError,
            helperText: cents != null && money.isExpression(amount.text)
                ? '= ${money.fmt(cents)}'
                : 'Arithmetic works too: 120+35, 3×45, 1.5k',
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final op in ['+', '−', '×', '÷', '(', ')'])
            ActionChip(label: Text(op, style: text.titleMedium), onPressed: () => _insert(op)),
        ]),
        const SizedBox(height: 20),
        Text('Category', style: text.labelLarge?.copyWith(color: secondaryText(context))),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final c in _categories)
            ChoiceChip(
              avatar: Icon(categoryIcon(c.icon), size: 18),
              label: Text(c.name),
              selected: c.id == categoryId,
              showCheckmark: false,
              onSelected: (_) => setState(() {
                categoryId = c.id;
                chosen = true;
              }),
            ),
        ]),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_outlined),
          title: Text(switch (mode) { EntryMode.series => 'Starts', EntryMode.later => 'From', _ => 'Date' }),
          trailing: Text(fmtLong(day), style: text.bodyLarge),
          onTap: _pickDay,
        ),
        RawAutocomplete<String>(
          textEditingController: note,
          focusNode: noteFocus,
          optionsBuilder: (value) {
            final q = value.text.trim().toLowerCase();
            if (q.isEmpty) return const [];
            return notes.keys.where((n) => n.toLowerCase().contains(q) && n != value.text).take(8);
          },
          fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
            controller: controller,
            focusNode: focus,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Note', hintText: 'What was it? (optional)', border: OutlineInputBorder()),
          ),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240, maxWidth: 360),
                child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                  for (final o in options) ListTile(dense: true, title: Text(o), onTap: () => onSelected(o)),
                ]),
              ),
            ),
          ),
        ),
        if (mode != EntryMode.date) ...[
          const SizedBox(height: 20),
          DropdownButtonFormField<String?>(
            initialValue: freq,
            decoration: const InputDecoration(labelText: 'Repeats', border: OutlineInputBorder()),
            items: [for (final e in repeats.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => freq = v),
          ),
          if (freq != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Text('Every'),
              IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: 'Less often',
                  onPressed: every > 1 ? () => setState(() => every--) : null),
              Text('$every', style: text.titleMedium),
              IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'More apart',
                  onPressed: every < 99 ? () => setState(() => every++) : null),
              Text(every == 1 ? freqUnits[freq]!.$1 : freqUnits[freq]!.$2),
            ]),
            const SizedBox(height: 4),
            Text('Ends', style: text.labelLarge?.copyWith(color: secondaryText(context))),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'never', label: Text('Never')),
                ButtonSegment(value: 'date', label: Text('On a date')),
                ButtonSegment(value: 'times', label: Text('After')),
              ],
              selected: {ends},
              onSelectionChanged: (s) => setState(() {
                ends = s.first;
                if (ends == 'date' && !until.isAfter(day)) until = addMonths(day, 12);
              }),
            ),
            if (ends == 'date')
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_busy_outlined),
                title: const Text('Last date'),
                trailing: Text(fmtLong(until), style: text.bodyLarge),
                onTap: _pickUntil,
              ),
            if (ends == 'times')
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(children: [
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: times,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(_times == 1 ? 'time' : 'times'),
                ]),
              ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(hint,
                  style: text.bodySmall?.copyWith(color: _repeatOk ? tertiaryText(context) : critical(context))),
            ],
          ],
        ],
      ]),
    );
  }
}
