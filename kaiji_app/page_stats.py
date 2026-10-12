"""Statistics: totals, where the money went and came from, spending per day and month, and the
balance over a date range - with every entry in a table (and CSV)."""
import csv
import datetime as dt

from PySide6.QtCore import QDate, Qt, QTimer
from PySide6.QtWidgets import (
    QAbstractItemView, QFileDialog, QGridLayout, QHBoxLayout, QHeaderView, QTableWidgetItem,
)
from qfluentwidgets import (
    BodyLabel, CalendarPicker, ComboBox, FluentIcon as FIF, InfoBar, InfoBarPosition, PushButton,
    TableWidget,
)

from . import fluent, money
from .charts import BalanceChart, BarList, ColumnChart
from .entry_list import describe_item
from .fluent import Page, StatCard, category_icon, header_card
from .ledger import (
    MONTHS, MONTHS_SHORT, WEEKDAY_SHORT, add_months, describe_rule, fmt_date, fmt_short,
    month_bounds, totals_by_category, totals_by_month,
)

RANGES = ["This month", "Last month", "Last 3 months", "Last 6 months", "This year",
          "Last 12 months", "Custom"]
HEADERS = ["Date", "Day", "Category", "Note", "Amount", "Repeats"]
DAILY_LIMIT = 93                   # longer ranges show months only
ROW_HEIGHT = 38


class _SortItem(QTableWidgetItem):
    """Sorts by the key in UserRole, so amounts sort as numbers and days in week order."""

    def __lt__(self, other):
        a, b = self.data(Qt.UserRole), other.data(Qt.UserRole)
        if a is None or b is None:
            return super().__lt__(other)
        return a < b


class StatisticsPage(Page):
    def __init__(self, app, window):
        super().__init__("stats", "Statistics")
        self.app, self.window = app, window
        self.items = []

        self.range = ComboBox()
        self.range.addItems(RANGES)
        self.range.setMinimumWidth(160)
        self.range.currentIndexChanged.connect(self._preset)
        self.date_from, self.date_to = CalendarPicker(), CalendarPicker()
        for picker in (self.date_from, self.date_to):
            picker.setDateFormat("yyyy/MM/dd")
            picker.dateChanged.connect(self._dates_edited)
        export = PushButton(FIF.DOWNLOAD, "Export CSV")
        export.clicked.connect(self._export_csv)
        bar = QHBoxLayout()
        bar.setSpacing(8)
        for w in (self.range, self.date_from, BodyLabel("–"), self.date_to):
            bar.addWidget(w)
        bar.addStretch(1)
        bar.addWidget(export)
        self.vbox.addLayout(bar)

        self.tiles = {k: StatCard(c) for k, c in [
            ("income", "Income"), ("expense", "Expenses"), ("net", "Net"),
            ("average", "Spending per day"), ("top", "Biggest category"),
            ("largest", "Largest expense"), ("repeating", "Repeating expenses"),
            ("count", "Entries")]}
        tiles = QGridLayout()
        tiles.setSpacing(12)
        for i, tile in enumerate(self.tiles.values()):
            tiles.addWidget(tile, i // 4, i % 4)
        self.vbox.addLayout(tiles)

        self.spending = BarList("No expenses in this period.")
        self.earning = BarList("No income in this period.")
        categories = QHBoxLayout()
        categories.setSpacing(12)
        for title, chart, stretch in (("Spending by category", self.spending, 3),
                                      ("Income by category", self.earning, 2)):
            card, box = header_card(title, chart)
            box.addStretch(1)
            categories.addWidget(card, stretch)
        self.vbox.addLayout(categories)
        self.daily = ColumnChart("No expenses in this period.")
        self.daily_card, _ = header_card("Spending per day", self.daily)
        self.monthly = ColumnChart("Nothing in this period.")
        self.monthly_card, _ = header_card("Income and expenses per month", self.monthly)
        self.balance = BalanceChart()
        self.vbox.addWidget(self.daily_card)
        self.vbox.addWidget(self.monthly_card)
        self.vbox.addWidget(header_card("Balance", self.balance)[0])

        self.table = TableWidget()
        self.table.setColumnCount(len(HEADERS))
        self.table.setHorizontalHeaderLabels(HEADERS)
        self.table.setBorderVisible(True)
        self.table.setBorderRadius(8)
        self.table.setWordWrap(False)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.verticalHeader().hide()
        self.table.verticalHeader().setDefaultSectionSize(ROW_HEIGHT)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(QHeaderView.Stretch)
        for column in (0, 1, 4):
            header.setSectionResizeMode(column, QHeaderView.ResizeToContents)
        self.table.cellDoubleClicked.connect(self._open_row)
        self.vbox.addWidget(header_card("Entries · double-click one to edit it", self.table)[0])

        self._reload = QTimer(self, singleShot=True, interval=250)
        self._reload.timeout.connect(self.refresh)
        app.data_changed.connect(self._data_changed)
        fluent.on_theme_change(self._data_changed)       # the category icons in the table
        self._active = False              # nothing is computed until the page is first opened
        self._preset(0)

    def activate(self):
        self._active = True
        self.refresh()

    def _data_changed(self):
        if self.isVisible():
            self.refresh()

    def _range(self):
        start, end = self.date_from.getDate().toPython(), self.date_to.getDate().toPython()
        return (start, end) if start <= end else (end, start)

    def _preset(self, index):
        today = dt.date.today()
        first = today.replace(day=1)
        month_end = month_bounds(today.year, today.month)[1]
        if index == 0:
            start, end = first, month_end
        elif index == 1:
            prev = add_months(first, -1)
            start, end = month_bounds(prev.year, prev.month)
        elif index in (2, 3, 5):
            start, end = add_months(first, -{2: 2, 3: 5, 5: 11}[index]), month_end
        elif index == 4:
            start, end = dt.date(today.year, 1, 1), dt.date(today.year, 12, 31)
        else:
            return
        for picker, value in ((self.date_from, start), (self.date_to, end)):
            picker.blockSignals(True)
            picker.setDate(QDate(value))
            picker.blockSignals(False)
        self._reload.start()

    def _dates_edited(self, *_):
        self.range.blockSignals(True)
        self.range.setCurrentIndex(RANGES.index("Custom"))
        self.range.blockSignals(False)
        self._reload.start()

    def refresh(self):
        if not self._active:
            return
        app, today = self.app, dt.date.today()
        start, end = self._range()
        days = app.ledger.days(start, end)
        self.items = items = [i for d in days.values() for i in d.items]
        expenses = [i for i in items if i.kind == "expense"]
        incomes = [i for i in items if i.kind == "income"]
        self._fill_tiles(start, end, today, expenses, incomes)

        def rows(kind):
            out = []
            for category_id, total, count in totals_by_category(items, kind):
                c = app.category(category_id)
                out.append((category_icon(c.icon), c.name, total, count))
            return out

        self.spending.set_data(rows("expense"), "expense", "spending")
        self.earning.set_data(rows("income"), "income", "income")

        span = (end - start).days + 1
        self.daily_card.setVisible(span <= DAILY_LIMIT)
        if span <= DAILY_LIMIT:
            dlist = list(days.values())

            def day_label(day):
                """A month: every day number that fits; longer: the 1st (as the month's name),
                8th, 15th and 22nd."""
                if day.day == 1:
                    return MONTHS_SHORT[day.month - 1] + (" 1" if span <= 31 else "")
                return str(day.day) if span <= 31 or day.day in (8, 15, 22) else ""

            labels = [day_label(d.day) for d in dlist]
            titles = [f"{WEEKDAY_SHORT[d.day.weekday()]} {fmt_date(d.day)}" for d in dlist]
            past = [d for d in dlist if d.day <= today]
            average = sum(d.expense for d in past) // len(past) if past else 0
            self.daily.set_data(labels, titles, [("Expenses", "expense", [d.expense for d in dlist])],
                                planned=[d.day > today for d in dlist],
                                ref=(average, f"Average {money.fmt(average)}") if average else None)

        months = totals_by_month(items, start, end)
        self.monthly_card.setVisible(len(months) >= 2)
        if len(months) >= 2:
            years = len({m.year for m, _, _ in months}) > 1
            labels = [MONTHS_SHORT[m.month - 1] + (f" ’{m.year % 100:02d}" if years else "")
                      for m, _, _ in months]
            titles = [f"{MONTHS[m.month - 1]} {m.year}" for m, _, _ in months]
            self.monthly.set_data(labels, titles,
                                  [("Income", "income", [i for _, i, _ in months]),
                                   ("Expenses", "expense", [e for _, _, e in months])],
                                  planned=[m > today for m, _, _ in months])

        self.balance.set_data(list(days.values()), today, app.ledger.plan.min_balance)
        self._fill_table(today)

    def _fill_tiles(self, start, end, today, expenses, incomes):
        t, fmt = self.tiles, money.fmt
        income, expense = sum(i.amount for i in incomes), sum(i.amount for i in expenses)
        planned_in = sum(i.amount for i in incomes if i.day > today)
        planned_out = sum(i.amount for i in expenses if i.day > today)
        t["income"].set(fmt(income), f"incl. {fmt(planned_in)} planned" if planned_in
                        else f"{len(incomes)} {'entry' if len(incomes) == 1 else 'entries'}")
        t["expense"].set(fmt(expense), f"incl. {fmt(planned_out)} planned" if planned_out
                         else f"{len(expenses)} {'entry' if len(expenses) == 1 else 'entries'}")
        net = income - expense
        if income and net >= 0:
            note = f"Saved {net / income:.0%} of income"
        elif income:
            note = f"Spent {-net / income:.0%} more than came in"
        else:
            note = ""
        t["net"].set(fmt(net, sign=True), note, "critical" if net < 0 else None)

        last = min(end, today)
        elapsed = (last - start).days + 1 if last >= start else 0
        if elapsed:
            spent = sum(i.amount for i in expenses if i.day <= today)
            t["average"].set(fmt(spent // elapsed), f"over {elapsed} {'day' if elapsed == 1 else 'days'}"
                             + (" so far" if end > today else ""))
        else:
            span = (end - start).days + 1
            t["average"].set(fmt(expense // span), f"planned, over {span} days")

        by_category = totals_by_category(expenses, "expense")
        if by_category:
            category_id, total, _ = by_category[0]
            t["top"].set(self.app.category(category_id).name,
                         f"{fmt(total)} · {total / expense:.0%} of spending")
        else:
            t["top"].set("–", "No expenses")
        if expenses:
            biggest = max(expenses, key=lambda i: (i.amount, i.day))
            t["largest"].set(fmt(biggest.amount),
                             f"{describe_item(self.app, biggest)[0]} · {fmt_short(biggest.day)}")
        else:
            t["largest"].set("–", "No expenses")
        repeating = sum(i.amount for i in expenses if i.repeating)
        t["repeating"].set(fmt(repeating), f"{repeating / expense:.0%} of spending · rent, bills, "
                           "subscriptions" if expense else "Rent, bills, subscriptions")
        days_with = len({i.day for i in expenses + incomes})
        count = len(expenses) + len(incomes)
        t["count"].set(str(count), f"on {days_with} {'day' if days_with == 1 else 'days'}")

    def _rows(self):
        """(cells, sort keys, item) per entry; CSV gets plain numbers."""
        for item in sorted(self.items, key=lambda i: (i.day, i.kind != "income", -i.amount)):
            title, _ = describe_item(self.app, item)
            category = self.app.category(item.category_id).name
            rule = self.app.rule(item.rule_id) if item.repeating else None
            repeats = describe_rule(rule) if rule else ""
            cells = [fmt_date(item.day), WEEKDAY_SHORT[item.day.weekday()], category, item.note,
                     money.fmt(item.signed, sign=True), repeats]
            keys = [item.day.isoformat(), item.day.weekday(), category, item.note, item.signed, repeats]
            yield cells, keys, item

    def _fill_table(self, today):
        self.table.setSortingEnabled(False)
        rows = list(self._rows())
        self.table.setRowCount(len(rows))
        for r, (cells, keys, item) in enumerate(rows):
            for c, (value, key) in enumerate(zip(cells, keys)):
                cell = _SortItem(value)
                cell.setData(Qt.UserRole, key)
                if c == 0:
                    cell.setData(Qt.UserRole + 1, item)
                if c == 2:
                    cell.setIcon(category_icon(self.app.category(item.category_id).icon).icon())
                if c == 4:
                    cell.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
                if item.day > today:
                    cell.setToolTip("Planned")
                self.table.setItem(r, c, cell)
        self.table.setSortingEnabled(True)
        visible = min(max(len(rows), 1), 14)
        self.table.setFixedHeight(self.table.horizontalHeader().height() + visible * ROW_HEIGHT + 4)

    def _open_row(self, row, _column):
        item = self.table.item(row, 0).data(Qt.UserRole + 1)
        if item is not None:
            self.window.edit_item(item)

    def _export_csv(self):
        start, end = self._range()
        name = f"kaiji {start.isoformat()} to {end.isoformat()}.csv"
        path, _ = QFileDialog.getSaveFileName(self, "Export CSV", name, "CSV (*.csv)")
        if not path:
            return
        today = dt.date.today()
        try:
            with open(path, "w", newline="", encoding="utf-8-sig") as f:
                w = csv.writer(f)
                w.writerow(["Date", "Type", "Category", "Amount", "Note", "Repeats", "Planned"])
                for cells, _, item in self._rows():
                    w.writerow([item.day.isoformat(), item.kind.capitalize(), cells[2],
                                money.plain(item.signed), item.note, cells[5],
                                "yes" if item.day > today else ""])
        except OSError as e:
            InfoBar.error("Couldn't save the file", str(e), duration=7000,
                          position=InfoBarPosition.TOP_RIGHT, parent=self.window)
        else:
            InfoBar.success("Exported", path, duration=4000,
                            position=InfoBarPosition.TOP_RIGHT, parent=self.window)
