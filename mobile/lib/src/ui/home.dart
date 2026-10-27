/// The app: its theme, the first-run setup, and the five pages behind the navigation bar.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../dates.dart';
import 'actions.dart';
import 'calendar_page.dart';
import 'look.dart';
import 'repeating_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'today_page.dart';
import 'widgets.dart';

class KaijiApp extends StatelessWidget {
  const KaijiApp({super.key, required this.state});
  final KaijiState state;

  @override
  Widget build(BuildContext context) => KaijiScope(
        state: state,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final seed = state.wallpaperColors ? state.wallpaper ?? kaijiGreen : kaijiGreen;
            return MaterialApp(
              title: 'Kaiji 花錢',
              debugShowCheckedModeBanner: false,
              scaffoldMessengerKey: messengerKey,
              themeMode: state.themeMode,
              theme: kaijiTheme(ColorScheme.fromSeed(seedColor: seed)),
              darkTheme: kaijiTheme(ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)),
              home: const _Start(),
            );
          },
        ),
      );
}

/// The setup the first time, the pages after.
class _Start extends StatelessWidget {
  const _Start();

  @override
  Widget build(BuildContext context) => KaijiScope.of(context).welcomed ? const HomeShell() : const WelcomePage();
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int page = 0;
  DateTime day = today(); // the calendar's selected day; + adds there

  @override
  Widget build(BuildContext context) {
    final Widget? add = switch (page) {
      0 || 1 => FloatingActionButton(
          tooltip: 'Add an entry',
          onPressed: () => addEntry(context, day: page == 1 ? day : today()),
          child: const Icon(Icons.add),
        ),
      3 => FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('Repeating'),
          onPressed: () => addEntry(context, repeat: 'month'),
        ),
      _ => null,
    };
    // back goes to Today before it leaves the app
    return PopScope(
      canPop: page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => page = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: page, children: [
          const TodayPage(),
          CalendarPage(day: day, onDay: (d) => setState(() => day = d)),
          const StatsPage(),
          const RepeatingPage(),
          const SettingsPage(),
        ]),
        floatingActionButton: add,
        bottomNavigationBar: NavigationBar(
          selectedIndex: page,
          onDestinationSelected: (i) => setState(() => page = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
            NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'Calendar'),
            NavigationDestination(
                icon: Icon(Icons.insert_chart_outlined), selectedIcon: Icon(Icons.insert_chart), label: 'Statistics'),
            NavigationDestination(icon: Icon(Icons.event_repeat_outlined), selectedIcon: Icon(Icons.event_repeat), label: 'Repeating'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
