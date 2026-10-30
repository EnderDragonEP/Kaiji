/// Kaiji 花錢 on Android: the desktop app's monthly spending tracker, keeping the same kaiji.db so
/// a backup opens on either.
library;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'src/app_state.dart';
import 'src/money.dart' as money;
import 'src/store.dart';
import 'src/ui/home.dart';
import 'src/ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final country = WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  final store = await Store.open(databaseFactory, p.join(await getDatabasesPath(), 'kaiji.db'),
      currency: money.defaultsFor(money.currencyOf(country)));
  final state = await KaijiState.open(store, wallpaper: await _wallpaper());
  state.syncer.onReport = showMessage;
  if (state.syncer.enabled) await state.syncer.start();
  runApp(KaijiApp(state: state));
}

/// The color Android 12 and later take from the wallpaper, or null on older phones.
Future<Color?> _wallpaper() async {
  try {
    final palette = await DynamicColorPlugin.getCorePalette();
    return palette == null ? null : Color(palette.primary.get(40));
  } catch (_) {
    return null;
  }
}
