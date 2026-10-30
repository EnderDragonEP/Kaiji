# Kaiji 花錢

A monthly spending tracker for Windows 10 and 11. Put your income and spending on a calendar -
including what's still to come, like pay day and rent - and Kaiji shows what your balance will
be on any day and how much you can still spend this month.

## Run

```powershell
pip install -r Kaiji.Windows\requirements.txt
pythonw Kaiji.Windows\Kaiji.pyw   # or double-click Kaiji.pyw
```

On first run Kaiji asks for your currency, what you have today, and (optionally) your monthly
pay and savings goal. Everything can be changed later in Settings.

Standalone exe: `pip install pyinstaller`, then `.\build.ps1` → `dist\Kaiji\Kaiji.exe`.
The exe icon is generated from `Kaiji.Windows/kaiji_app/icons.py` by
`Kaiji.Windows/tools/make_ico.py`; extra arguments go to PyInstaller (e.g. `.\build.ps1 --clean`).

The Android app: `.\build.ps1 android` → `dist\Kaiji-release.apk` (needs Flutter and the Android
SDK, see [Kaiji.Mobile/README.md](Kaiji.Mobile/README.md)); extra arguments go to
`flutter build apk` (e.g. `.\build.ps1 android --split-per-abi`). `.\build.ps1 all` builds both.

Tests for the money logic and sync: `python -m unittest discover Kaiji.Windows\tests`. The sync
tests also run against a real PostgreSQL when `KAIJI_TEST_PG` names a database made for testing
(everything in its `kaiji` schema is deleted), e.g. a throwaway one in Docker:

```powershell
docker run -d --rm --name kaiji-pg -e POSTGRES_PASSWORD=test -p 127.0.0.1:55432:5432 postgres:17
$env:KAIJI_TEST_PG = "host=127.0.0.1 port=55432 dbname=postgres user=postgres password=test"
```

## On your phone

`Kaiji.Mobile/` is Kaiji for Android, written in Flutter: the same pages and the same database,
so you can back up on one and restore on the other, or sync them. See
[Kaiji.Mobile/README.md](Kaiji.Mobile/README.md).

## Sync between your PC and phone (optional)

Kaiji works on its own on each device, as before. If you have a PostgreSQL server on your
network (12 or later; tested with 17), the PC and the phone can also share their data through
it. Each keeps its own `kaiji.db` and keeps working when the server can't be reached; changes
go across when it can - a couple of seconds after you make them, and every minute while Kaiji
is open.

### The server, once

Kaiji gets a login and a database of its own, so it can't see or change anything else on the
server. As the server's admin (e.g. in `psql -U postgres`):

```sql
CREATE ROLE kaiji LOGIN;
\password kaiji
CREATE DATABASE kaiji OWNER kaiji;
REVOKE ALL ON DATABASE kaiji FROM PUBLIC;
```

`\password` asks for the password, so it doesn't end up in psql's history or the server's log.
Then let the devices on your network in with a line in `pg_hba.conf`, above any line that would
match them first, and reload the server (`SELECT pg_reload_conf();`):

```text
# TYPE   DATABASE  USER   ADDRESS          METHOD
hostssl  kaiji     kaiji  192.168.1.0/24   scram-sha-256
```

If the server has no TLS set up, use `host` instead of `hostssl` and turn off "Encrypted
connection" in Kaiji. Kaiji makes its tables itself, in a `kaiji` schema, the first time it
connects.

### Connecting

Settings › Sync with PostgreSQL, on the PC and on the phone: the server's address, the port
(5432), the database and user (`kaiji`) and the password.

- The first device to connect puts its data on the server, so connect the one with your
  up-to-date data first.
- A device with no entries takes the server's data. One with entries of its own asks which to
  keep: the server's (the PC keeps a copy of its own in the backups folder, the phone offers
  Undo) or its own (the server's data is replaced, and the other devices get it when they next
  sync). Kaiji doesn't merge the two: they're usually copies of each other from earlier backups,
  and would double up.
- Restoring a backup while syncing replaces the server's data too: the backup becomes
  everyone's data.
- When the same entry is changed on two devices before they sync, the change that reaches the
  server last wins.
- The phone syncs while Kaiji is open and once more as you leave it; nothing runs in the
  background. Where the server can't be reached (away from home, unless you have a VPN),
  changes wait and go up when it can.
- Turning sync off leaves the data on the device and on the server as it is.

The password is kept in Windows Credential Manager on the PC and in the Android Keystore on the
phone - never in `kaiji.db`, `config.json` or a backup. Android's own backup leaves it out too,
so a restored phone asks for it again.

## What it does

- **Today**: how much is *left to spend* this month and about how much a day, a ring for how
  much of the month's money is used, today's balance, the month-end balance, the lowest balance
  in the next 60 days, what's coming up in the next 30 days with the balance after each, and a
  chart of the balance over the last 30 and next 90 days. A bar warns when your balance is
  heading below your minimum.
- **Calendar**: each day shows its income, its spending and the balance at the end of the day -
  projected (≈) for days ahead, red when it would drop below your minimum. The selected day's
  entries and the month's totals are on the right. Arrow keys and Page Up/Down move around,
  Home goes to today, double-click (or Enter) adds an entry.
- **Statistics**: for a range (this month, last 3 / 6 / 12 months, this year or any dates):
  totals, spending and income by category, spending per day, income and expenses per month,
  the balance, and every entry in a table (double-click to edit) with CSV export. Hover the
  charts for the numbers.
- **Repeating**: pay, rent, bills and subscriptions, added once. They appear on every date they
  fall on - daily, weekly, monthly or yearly, every N of those - which is what lets the calendar
  look ahead. They end never, on a date, or after a number of times (12 monthly payments; a
  skipped date still counts, so the plan doesn't grow), and then show "4 of 12" on each date.
  On a date in the calendar (right-click, or the ⋯ button) you can edit just that date, change
  it from that date on (a raise, new rent), skip it, or stop after it. Deletes and skips can be
  undone from the notice that appears.
- **Settings**: your plan (starting balance, savings goal, minimum balance, what "left to spend"
  comes from), currency and decimals, categories (add, rename, change icon, reorder, delete),
  first day of the week, CSV export, backup and restore, sync, theme and accent color.
- **Amounts** take arithmetic: `120+35`, `3*45`, `1.5k`, `3萬`.

## Left to spend

- *This month's income* (default): the month's income − its expenses (recorded and still to
  come) − your savings goal. It's never more than would take your balance below your minimum
  on any day until the month ends; when that's what limits it, Today says so.
- *Everything I have*: the lowest balance between today and the month's end − your minimum.

Spend about the daily amount and the daily amount stays the same; spend more and it drops for
the rest of the month.

## Look and feel

The UI is built with [PySide6-Fluent-Widgets](https://github.com/zhiyiYo/PyQt-Fluent-Widgets)
(QFluentWidgets): a frameless Fluent window with Mica on Windows 11, the navigation pane,
setting cards, date pickers, dialogs, menus and info bars all come from the library, like in
HaBanLa. The calendar and the charts are painted with the library's fonts and theme colors.
Kaiji uses your Windows accent color unless you pick another one, and follows Windows
light/dark mode unless you choose one.

Income, expenses and the balance are blue, orange and green everywhere (calendar dots, icons,
charts); that set is checked to stay distinguishable with color-vision deficiency in both
light and dark mode. Amounts always carry their + or − as well.

The app uses PySide6 only. PyQt6 and PySide6 are two separate bindings of the same Qt, and one
process can't mix them; PySide6-Fluent-Widgets is built on PySide6.

PySide6-Fluent-Widgets is GPLv3, so Kaiji is GPLv3 as well when you distribute it.

## Files

- `Kaiji.Windows/` – Kaiji for Windows: `Kaiji.pyw` starts it; `requirements.txt`;
  `tools/make_ico.py` the exe icon.
- `Kaiji.Windows/kaiji_app/` – the app:
  - `app.py` the controller that owns the data, and `main()`; `main_window.py` the window,
    navigation and the entry actions (edit, skip, delete with undo); `page_today.py`,
    `page_calendar.py`, `page_stats.py`, `page_repeating.py`, `page_settings.py` the pages.
  - `ledger.py` the money logic: repeating dates, daily balances, the month plan and totals.
    `store.py` the SQLite database, `money.py` amounts (parsing and formatting).
  - `sync.py` sync through PostgreSQL: the server's tables, a round's push and pull, and the
    `Syncer` that runs them; `credentials.py` the password in Credential Manager.
  - `fluent.py` theme and accent setup, colors, and what QFluentWidgets doesn't have (page,
    stat card, amount box); `charts.py` the charts; `entry_list.py` entry rows;
    `dialogs.py` the dialogs; `config.py` paths and settings; `icons.py` the app icon.
- `Kaiji.Windows/tests/` – `test_ledger.py` for repeating dates, balances, left to spend and
  amounts; `test_sync.py` for sync between two devices.
- `Kaiji.Mobile/` – Kaiji for Android (Flutter), with its own README.
- `build.ps1` – builds the exe and the APK.
- `%APPDATA%\Kaiji\kaiji.db` – your entries, repeating entries, categories, plan and currency.
- `%APPDATA%\Kaiji\backups\` – a copy of the database for each of the last 10 days Kaiji ran,
  and one taken before every restore or before taking the server's data.
- `%APPDATA%\Kaiji\config.json` – theme, accent color, first day of the week, where to sync.
