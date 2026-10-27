# Kaiji 花錢

A monthly spending tracker for Windows 10 and 11. Put your income and spending on a calendar -
including what's still to come, like pay day and rent - and Kaiji shows what your balance will
be on any day and how much you can still spend this month.

## Run

```powershell
pip install -r requirements.txt
pythonw Kaiji.pyw            # or double-click Kaiji.pyw
```

On first run Kaiji asks for your currency, what you have today, and (optionally) your monthly
pay and savings goal. Everything can be changed later in Settings.

Standalone exe: `pip install pyinstaller`, then `build.bat` → `dist\Kaiji\Kaiji.exe`.
The exe icon is generated from `kaiji_app/icons.py` by `tools/make_ico.py`; extra arguments go
to PyInstaller (e.g. `build.bat --clean`).

Tests for the money logic: `python -m unittest discover tests`.

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
  first day of the week, CSV export, backup and restore, Cashew import and export, theme and
  accent color.
- **Amounts** take arithmetic: `120+35`, `3*45`, `1.5k`, `3萬`.

## Cashew

Settings → Your data → Cashew moves data between Kaiji and the
[Cashew](https://github.com/jameskokoska/Cashew) budgeting app:

- **Import** reads a Cashew backup: in Cashew, *Export data file* in its settings makes
  `cashew-<date>.sql`. You pick the accounts to bring in (those in Cashew's main currency are
  picked). Paid transactions become entries, a subscription's next unpaid date becomes a
  repeating entry from that date (its unpaid past dates are skipped), and an upcoming one-off
  becomes a planned entry. Categories are matched by name or added with a similar icon;
  subcategories go to their main category, and a transaction's title and note become the note.
  Kaiji has one balance, so transfers between the imported accounts cancel out and stay out;
  open loans count, ones paid back don't. Importing again replaces what the last Cashew import
  brought in (so change those entries in Cashew), and Kaiji keeps a copy of your data from
  before each import in the backups folder.
- **Export** writes a CSV in the layout of Cashew's own export, so Cashew's *Import CSV* maps
  the columns itself. Cashew adds every row as a paid transaction to the account selected in
  Cashew, so planned entries are left out by default, repeating entries go as their dates, and
  entries that came from Cashew stay out. Importing the same file twice in Cashew adds it twice.

There's no live sync: Cashew syncs through its own Google Drive backups, so moving data is a
file each way.

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

- `kaiji_app/` – the app:
  - `app.py` the controller that owns the data, and `main()`; `main_window.py` the window,
    navigation and the entry actions (edit, skip, delete with undo); `page_today.py`,
    `page_calendar.py`, `page_stats.py`, `page_repeating.py`, `page_settings.py` the pages.
  - `ledger.py` the money logic: repeating dates, daily balances, the month plan and totals.
    `store.py` the SQLite database, `money.py` amounts (parsing and formatting), `cashew.py`
    reading Cashew backups and writing CSVs for Cashew.
  - `fluent.py` theme and accent setup, colors, and what QFluentWidgets doesn't have (page,
    stat card, amount box); `charts.py` the charts; `entry_list.py` entry rows;
    `dialogs.py` the dialogs; `config.py` paths and settings; `icons.py` the app icon.
- `tests/test_ledger.py` – tests for repeating dates, balances, left to spend and amounts;
  `tests/test_cashew.py` – the Cashew import and export, on a made-up Cashew backup.
- `%APPDATA%\Kaiji\kaiji.db` – your entries, repeating entries, categories, plan and currency.
- `%APPDATA%\Kaiji\backups\` – a copy of the database for each of the last 10 days Kaiji ran,
  and one taken before every restore or Cashew import.
- `%APPDATA%\Kaiji\config.json` – theme, accent color, first day of the week.
