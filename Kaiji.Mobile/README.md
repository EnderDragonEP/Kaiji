# Kaiji 花錢 for Android

Kaiji on your phone: the same Today, Calendar, Statistics, Repeating and Settings pages as on
the PC, the same money logic (ported from `Kaiji.Windows/kaiji_app/ledger.py` and checked against
it), and the same database file, so a backup made on either one opens on the other - and the
same optional sync through PostgreSQL.

## Build and install

From the repository root, `.\build.ps1 android` builds it and copies it to
`dist\Kaiji-release.apk` (`.\build.ps1 all` also builds the PC's exe). Or by hand:

```powershell
cd Kaiji.Mobile
flutter pub get
flutter build apk --release   # → build\app\outputs\flutter-apk\app-release.apk
flutter install               # phone plugged in, with USB debugging on
```

`flutter run` gives a debug build with hot reload instead. It needs Flutter 3.47 or later and
the Android SDK (Android Studio's works). Android 7.0 and later are supported. The APK holds the
code for every kind of phone (about 53 MB); `--split-per-abi` makes one per kind instead, about
20 MB each (most phones take the `arm64-v8a` one).

The release APK is signed with Flutter's debug key, which is fine for your own phone. For the
Play Store, set up an upload key first (Flutter docs: *Build and release an Android app*).

Tests: `flutter test`. They cover amounts and repeating dates (ports of
`Kaiji.Windows/tests/test_ledger.py`), the database on a real SQLite (including a database from
the desktop app's first version), the edits behind the menus (change from a date, skip, stop
after, undo), sync between two devices (a port of `test_sync.py`; with `KAIJI_TEST_PG` set,
against PostgreSQL too, as in the main README), and widget tests that go through every page on
a phone-sized screen in light and dark.

The launcher icons and `assets/kaiji.png` come from the desktop icon:
`python tools/make_icons.py` (needs PySide6).

## Moving your data between PC and phone

- **Phone → PC**: Settings › *Back up* shares a `.db` file (Drive, email, Nearby Share…). On the
  PC, Settings › *Restore* and pick it.
- **PC → phone**: on the PC, Settings › *Back up* (or copy `%APPDATA%\Kaiji\kaiji.db`). Get the
  file onto the phone, then Settings › *Restore*.

A restore replaces everything on that device; on the phone, *Undo* on the notice that follows
puts back what was there. Theme, first day of the week and wallpaper colors belong to each
device and aren't part of a backup.

Or let them sync: Settings › *Sync with PostgreSQL*, with the server set up as in the main
README's "Sync between your PC and phone". The phone syncs while Kaiji is open and once more as
you leave it, wherever the server can be reached (your home Wi-Fi, say); changes made elsewhere
wait and go up later. The password stays in the Android Keystore, and Android's own backup
leaves it out.

## Differences from the PC

- Long-press an entry (or tap ⋯) for what the PC has on right-click: edit this date only, this
  and later dates, all dates, skip, stop after this date, delete. Swipe the calendar sideways
  for another month.
- Colors follow the wallpaper on Android 12 and later (Material You); Settings can switch that
  off for Kaiji green. Income, expenses and the balance keep the PC's blue, orange and green.
- CSV export (Settings for everything, the share button in Statistics for its dates) goes to
  the share sheet, with the PC's columns.
- Not on the phone yet: the entries table in Statistics, and the PC's automatic daily backups
  (Android's own device backup includes Kaiji's data).

## Files

- `lib/main.dart` opens `kaiji.db` and starts the app.
- `lib/src/` the logic, each a port of the desktop file it names: `money.dart` (money.py),
  `ledger.dart` (ledger.py), `store.dart` (store.py, the same tables), `sync.dart` (sync.py,
  the same server tables), `app_state.dart` (the controller in app.py), plus `dates.dart` and
  `models.dart`.
- `lib/src/ui/` the screens: `home.dart` (theme and navigation), `today_page.dart`,
  `calendar_page.dart`, `stats_page.dart`, `repeating_page.dart`, `settings_page.dart` (with the
  categories and the first-run setup), `sync_page.dart` (sync's settings and status),
  `entry_page.dart` (add and edit), `actions.dart` (edit, skip and delete with undo),
  `charts.dart`, `widgets.dart`, `look.dart` (colors and icons).
- `test/` the tests; `test/sample.dart` is the made-up data the widget tests use.
