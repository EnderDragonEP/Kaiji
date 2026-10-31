import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaiji/src/app_state.dart';
import 'package:kaiji/src/dates.dart';
import 'package:kaiji/src/store.dart';
import 'package:kaiji/src/ui/home.dart';
import 'package:kaiji/src/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sample.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('kaiji_app_'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A 411 x 914 phone, and Kaiji on a fresh database (with the sample data if asked).
  Future<KaijiState> start(WidgetTester tester, {bool welcomed = true, bool sample = false, bool dark = false}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'welcomed': welcomed, if (dark) 'theme': 'dark'});
    final state = (await tester.runAsync(() async {
      final store = await Store.open(databaseFactoryFfiNoIsolate, '${dir.path}/kaiji.db', currency: ('NT\$', 0));
      if (sample) await fillSample(store);
      return KaijiState.open(store);
    }))!;
    addTearDown(() => tester.runAsync(state.store.db.close));
    await tester.pumpWidget(KaijiApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  Finder nav(String page) => find.descendant(of: find.byType(NavigationBar), matching: find.text(page));

  testWidgets('the first run asks for the balance and the pay, then shows Today', (tester) async {
    final state = await start(tester, welcomed: false);
    expect(find.text('Welcome to Kaiji 花錢'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Money you have today'), '52,000');
    await tester.enterText(find.widgetWithText(TextField, 'Monthly pay'), '42000');
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.text('Left to spend in ${months[today().month - 1]}'), findsOneWidget);
    expect(state.welcomed, isTrue);
    expect(state.ledger.days(today(), today()).single.balance, 5200000);
    final pay = state.data.rules.single;
    expect((pay.note, pay.amount, pay.freq), ('Salary', 4200000, 'month'));
  });

  for (final dark in [false, true]) {
    testWidgets('every page lays out with a few months of data (${dark ? 'dark' : 'light'})', (tester) async {
      await start(tester, sample: true, dark: dark);
      await tester.tap(nav('Statistics'));
      await tester.pumpAndSettle();
      for (final range in ['Last month', '3 months', '12 months', 'This month']) {
        await tester.ensureVisible(find.text(range));
        await tester.pumpAndSettle();
        await tester.tap(find.text(range));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, range)).selected, isTrue);
      }
      for (final page in ['Today', 'Calendar', 'Statistics', 'Repeating', 'Settings']) {
        await tester.tap(nav(page));
        await tester.pumpAndSettle();
        await tester.fling(find.byType(Scrollable).hitTestable().first, const Offset(0, -2000), 3000);
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('+ adds an expense, arithmetic and all', (tester) async {
    final state = await start(tester);
    await tester.tap(find.byTooltip('Add an entry'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '120+35');
    await tester.pump();
    expect(find.text('= NT\$155'), findsOneWidget);
    await tester.tap(find.text('Transport'));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    final e = state.data.entries.single;
    expect((e.amount, e.day, state.category(e.categoryId).name), (15500, today(), 'Transport'));
    expect(find.text('1 expense'), findsOneWidget); // under Spent today
  });

  testWidgets('a date of a repeating entry can be skipped, and the skip undone', (tester) async {
    final day = addDays(today(), 3);
    final state = await start(tester);
    await tester.runAsync(() => state.saveEntry(
        EntryValues(kind: 'expense', amount: 39000, categoryId: null, day: day, note: 'Netflix', freq: 'month')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Netflix'), 200);
    await tester.longPress(find.text('Netflix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip this date'));
    await tester.pumpAndSettle();
    expect(state.data.rules.single.skips, {day});
    expect(find.text('Netflix'), findsNothing); // the next is more than 30 days away

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(state.data.rules.single.skips, isEmpty);
    expect(find.text('Netflix'), findsOneWidget);
  });

  testWidgets('the calendar adds on the day picked in it', (tester) async {
    final state = await start(tester);
    await tester.tap(nav('Calendar'));
    await tester.pumpAndSettle();
    final day = ymd(today().year, today().month, today().day == 15 ? 16 : 15);
    await tester.tap(find.text('${day.day}').first);
    await tester.pumpAndSettle();
    expect(find.text(fmtLong(day)), findsOneWidget);
    await tester.tap(find.byTooltip('Add an entry'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '80');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(state.data.entries.single.day, day);
  });

  testWidgets('categories can be added in Settings', (tester) async {
    final state = await start(tester);
    await tester.tap(nav('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Expense categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Category'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Pets');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(state.kindCategories('expense').last.name, 'Pets');
    expect(find.text('Pets'), findsOneWidget);
  });

  testWidgets('sync is off until set up, and Connect waits for a server', (tester) async {
    final state = await start(tester);
    await tester.tap(nav('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Sync with PostgreSQL'), 300,
        scrollable: find.descendant(of: find.byType(SettingsPage), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    expect(find.text('Off: your data is only on this phone'), findsOneWidget);
    await tester.tap(find.text('Sync with PostgreSQL'));
    await tester.pumpAndSettle();
    final connect = find.widgetWithText(FilledButton, 'Connect');
    expect(tester.widget<FilledButton>(connect).onPressed, isNull); // no server yet
    await tester.enterText(find.widgetWithText(TextField, 'Server'), '192.168.1.150');
    await tester.pump();
    expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
    expect(state.syncer.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pages can be pulled down to sync only while sync is on', (tester) async {
    final state = await start(tester);
    expect(find.byType(RefreshIndicator), findsNothing);
    state.syncer.state = 'on'; // as after Syncer.start, without a server to reach
    await tester.pumpWidget(KaijiApp(state: state));
    await tester.tap(nav('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsOneWidget); // the page on show
    state.syncer.state = 'off';
  });
}
