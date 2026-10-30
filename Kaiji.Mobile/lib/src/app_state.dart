/// The state every screen reads: the data, the ledger over it, the look settings, and the
/// changes. Each change is written to the database and the data loaded again, like the desktop
/// app's controller (app.py), and screens rebuild through [ChangeNotifier].
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dates.dart';
import 'ledger.dart';
import 'models.dart';
import 'money.dart' as money;
import 'store.dart';
import 'sync.dart' as sync;

const uncategorized = Category(0, 'expense', 'Uncategorized', 'TAG');

/// What the entry editor hands back. [freq] set: a repeating entry.
class EntryValues {
  const EntryValues({
    required this.kind,
    required this.amount,
    required this.categoryId,
    required this.day,
    this.note = '',
    this.freq,
    this.every = 1,
    this.until,
    this.times,
  });
  final String kind;
  final int amount;
  final int? categoryId;
  final DateTime day;
  final String note;
  final String? freq;
  final int every;
  final DateTime? until;
  final int? times;

  factory EntryValues.of(Item item) =>
      EntryValues(kind: item.kind, amount: item.amount, categoryId: item.categoryId, day: item.day, note: item.note);

  factory EntryValues.ofRule(Rule r, DateTime day, {int? times}) => EntryValues(
        kind: r.kind, amount: r.amount, categoryId: r.categoryId, day: day, note: r.note, freq: r.freq,
        every: r.every, until: r.until, times: times ?? r.times,
      );
}

class KaijiState extends ChangeNotifier {
  KaijiState(this.store, this.data, this.prefs, {this.wallpaper}) {
    _rebuild();
    syncer = sync.Syncer(store: store, prefs: prefs, onChanged: () => changed(local: false));
  }

  static Future<KaijiState> open(Store store, {Color? wallpaper}) async =>
      KaijiState(store, await store.load(), await SharedPreferences.getInstance(), wallpaper: wallpaper);

  final Store store;
  final SharedPreferences prefs;
  final Color? wallpaper; // the phone's own color (Android 12+), if it has one
  KaijiData data;
  late final sync.Syncer syncer; // sync through PostgreSQL, when it's on
  late Ledger ledger;
  late Map<int, Category> _categories;
  late Map<int, Rule> _rules;

  // ---- look settings (kept on the phone, like the desktop's config.json)
  ThemeMode get themeMode => ThemeMode.values.byName(prefs.getString('theme') ?? 'system');
  int get weekStart => prefs.getInt('week_start') ?? 0; // 0 Monday ... 6 Sunday
  bool get welcomed => prefs.getBool('welcomed') ?? false;
  bool get wallpaperColors => prefs.getBool('wallpaper_colors') ?? true;

  Future<void> setThemeMode(ThemeMode mode) async {
    await prefs.setString('theme', mode.name);
    notifyListeners();
  }

  Future<void> setWallpaperColors(bool on) async {
    await prefs.setBool('wallpaper_colors', on);
    notifyListeners();
  }

  Future<void> setWeekStart(int day) async {
    await prefs.setInt('week_start', day);
    notifyListeners();
  }

  Future<void> setWelcomed() async {
    await prefs.setBool('welcomed', true);
    notifyListeners();
  }

  // ---- reading
  void _rebuild() {
    money.configure(data.currency, data.decimals);
    ledger = Ledger(data.entries, data.rules, data.plan);
    _categories = {for (final c in data.categories) c.id: c};
    _rules = {for (final r in data.rules) r.id: r};
  }

  Plan get plan => data.plan;
  Category category(int? id) => _categories[id] ?? uncategorized;
  List<Category> kindCategories(String kind) => [for (final c in data.categories) if (c.kind == kind) c];
  Rule? rule(int? id) => _rules[id];

  /// note -> (kind, category id) from the most recent entries, to complete notes with.
  Map<String, (String, int?)> notes() {
    final out = <String, (String, int?)>{};
    for (final e in data.entries.reversed) {
      if (e.note.isNotEmpty) out.putIfAbsent(e.note, () => (e.kind, e.categoryId));
    }
    for (final r in data.rules) {
      if (r.note.isNotEmpty) out.putIfAbsent(r.note, () => (r.kind, r.categoryId));
    }
    return out;
  }

  /// The category used most for [kind] in the last 90 days.
  int? usualCategory(String kind) {
    final since = addDays(today(), -90);
    final counts = <int, int>{};
    for (final e in data.entries) {
      if (e.kind == kind && e.categoryId != null && !e.day.isBefore(since)) {
        counts[e.categoryId!] = (counts[e.categoryId!] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return null;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// Load the data again after a change: made here ([local]), or brought by sync.
  Future<void> changed({bool local = true}) async {
    data = await store.load();
    _rebuild();
    notifyListeners();
    if (local) syncer.soon();
  }

  // ---- changing (each returns once it's saved and the screens have the new data)
  /// Add an entry, or a repeating entry when [v] repeats; replaces [entryId] if given.
  Future<void> saveEntry(EntryValues v, {int? entryId}) async {
    if (v.freq != null) {
      if (entryId != null) await store.deleteEntry(entryId);
      await store.addRule(v.kind, v.amount, v.categoryId, v.note, v.freq!, v.every, v.day,
          until: v.until, times: v.times);
    } else if (entryId != null) {
      await store.updateEntry(entryId, v.day, v.kind, v.amount, v.categoryId, v.note);
    } else {
      await store.addEntry(v.day, v.kind, v.amount, v.categoryId, v.note);
    }
    await changed();
  }

  /// Every date of a repeating entry changes.
  Future<void> saveRule(int ruleId, EntryValues v) async {
    await store.updateRule(ruleId, v.kind, v.amount, v.categoryId, v.note, v.freq!, v.every, v.day,
        until: v.until, times: v.times);
    await changed();
  }

  /// End a repeating entry before [day]: one that ends after a number of times keeps fewer times
  /// ("After 4 times" stays truthful), any other ends the day before.
  Future<void> _endBefore(Rule rule, DateTime day) async {
    final until = rule.until != null && rule.until!.isBefore(day) ? rule.until : null;
    if (rule.times != null) {
      await store.setRuleEnd(rule.id, until: until, times: timesBefore(rule, day));
    } else {
      await store.setRuleEnd(rule.id, until: until ?? addDays(day, -1));
    }
  }

  /// A repeating entry changes from v.day on: the old one ends before it and a new one carries
  /// on, with the dates the old one skipped from then on.
  Future<void> changeFrom(int ruleId, EntryValues v) async {
    final r = rule(ruleId)!;
    if (!v.day.isAfter(r.start)) return saveRule(ruleId, v);
    await _endBefore(r, v.day);
    await store.addRule(v.kind, v.amount, v.categoryId, v.note, v.freq!, v.every, v.day,
        until: v.until, times: v.times, skips: r.skips.where((d) => !d.isBefore(v.day)));
    await changed();
  }

  /// Only one date of a repeating entry changes: it's skipped and an entry takes its place.
  Future<void> editDate(int ruleId, DateTime day, EntryValues v) async {
    await store.skip(ruleId, day);
    await store.addEntry(v.day, v.kind, v.amount, v.categoryId, v.note);
    await changed();
  }

  Future<Future<void> Function()> skip(int ruleId, DateTime day) async {
    await store.skip(ruleId, day);
    await changed();
    return () async {
      await store.unskip(ruleId, day);
      await changed();
    };
  }

  Future<Future<void> Function()> stopAfter(int ruleId, DateTime day) async {
    final r = rule(ruleId)!;
    await _endBefore(r, addDays(day, 1));
    await changed();
    return () async {
      await store.setRuleEnd(ruleId, until: r.until, times: r.times);
      await changed();
    };
  }

  Future<Future<void> Function()> deleteEntry(int entryId) async {
    final e = data.entries.firstWhere((x) => x.id == entryId);
    await store.deleteEntry(entryId);
    await changed();
    return () async {
      await store.addEntry(e.day, e.kind, e.amount, e.categoryId, e.note);
      await changed();
    };
  }

  Future<Future<void> Function()> deleteRule(int ruleId) async {
    final r = rule(ruleId)!;
    await store.deleteRule(ruleId);
    await changed();
    return () async {
      await store.addRule(r.kind, r.amount, r.categoryId, r.note, r.freq, r.every, r.start,
          until: r.until, times: r.times, skips: r.skips);
      await changed();
    };
  }

  Future<void> setPlan(Plan p) async {
    await store.setPlan(p);
    await changed();
  }

  Future<void> setCurrency(String symbol, int decimals) async {
    await store.setCurrency(symbol, decimals);
    await changed();
  }

  Future<void> addCategory(String kind, String name, String icon) async {
    await store.addCategory(kind, name, icon);
    await changed();
  }

  Future<void> updateCategory(int id, String name, String icon) async {
    await store.updateCategory(id, name, icon);
    await changed();
  }

  Future<void> moveCategory(Category c, int step) async {
    await store.moveCategory(kindCategories(c.kind), c.id, step);
    await changed();
  }

  Future<void> reorderCategories(List<int> ids) async {
    await store.reorderCategories(ids);
    await changed();
  }

  Future<void> deleteCategory(int id, int? moveTo) async {
    await store.deleteCategory(id, moveTo);
    await changed();
  }

  /// Replace everything with a backup. While syncing, the backup replaces the server's data too.
  Future<void> restore(String path) async {
    await syncer.stop(); // a round under way mustn't write over the restore
    await store.restoreFrom(path);
    await sync.reset(store.db); // the backup's sync state isn't this phone's now
    if (syncer.enabled) {
      await sync.setSyncState(store.db, 'first', 'replace');
      await syncer.start();
    }
    await changed();
  }
}
