"""Repeating entries: pay, rent, bills and subscriptions that come back on their own, with what
they add up to per month."""
import datetime as dt

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QAbstractItemView, QHBoxLayout, QHeaderView, QTableWidgetItem
from qfluentwidgets import (
    Action, BodyLabel, FluentIcon as FIF, PrimaryPushButton, PushButton, RoundMenu, TableWidget,
)

from . import fluent, money
from .fluent import Page, StatCard, category_icon, header_card, secondary
from .ledger import (
    date_number, describe_end, describe_rule, fmt_date, last_date, next_date, per_month,
)

HEADERS = ["Name", "Category", "Amount", "Repeats", "Next", "Ends"]
ROW_HEIGHT = 40


class RepeatingPage(Page):
    def __init__(self, app, window):
        super().__init__("repeating", "Repeating")
        self.app, self.window = app, window
        intro = secondary(BodyLabel("Add pay, rent, bills and subscriptions once: they appear on "
                                    "every date they fall on, so the calendar can look ahead."))
        intro.setWordWrap(True)
        self.vbox.addWidget(intro)

        add = PrimaryPushButton(FIF.ADD, "Add repeating entry")
        add.clicked.connect(self._add)
        self.edit = PushButton(FIF.EDIT, "Edit")
        self.edit.clicked.connect(self._edit_selected)
        self.delete = PushButton(FIF.DELETE, "Delete")
        self.delete.clicked.connect(self._delete_selected)
        bar = QHBoxLayout()
        bar.setSpacing(8)
        for w in (add, self.edit, self.delete):
            bar.addWidget(w)
        bar.addStretch(1)
        self.vbox.addLayout(bar)

        self.income = StatCard("Repeating income per month")
        self.expense = StatCard("Repeating expenses per month")
        self.net = StatCard("Left over per month")
        cards = QHBoxLayout()
        cards.setSpacing(12)
        for card in (self.income, self.expense, self.net):
            cards.addWidget(card)
        self.vbox.addLayout(cards)

        self.table = TableWidget()
        self.table.setColumnCount(len(HEADERS))
        self.table.setHorizontalHeaderLabels(HEADERS)
        self.table.setBorderVisible(True)
        self.table.setBorderRadius(8)
        self.table.setWordWrap(False)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.table.verticalHeader().hide()
        self.table.verticalHeader().setDefaultSectionSize(ROW_HEIGHT)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(QHeaderView.Stretch)
        for column in (2, 4, 5):
            header.setSectionResizeMode(column, QHeaderView.ResizeToContents)
        self.table.setContextMenuPolicy(Qt.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._menu)
        self.table.cellDoubleClicked.connect(lambda row, _: window.edit_rule(self._rule_at(row)))
        self.table.itemSelectionChanged.connect(self._selection_changed)
        self.empty = secondary(BodyLabel("No repeating entries yet. Your pay and rent are good ones "
                                         "to start with."))
        self.vbox.addWidget(header_card("Repeating entries", self.table, self.empty)[0])
        self.vbox.addStretch(1)

        app.data_changed.connect(self._data_changed)
        fluent.on_theme_change(self._data_changed)       # the category icons in the table
        self._selection_changed()

    def activate(self):
        self.refresh()

    def _data_changed(self):
        if self.isVisible():
            self.refresh()

    def _add(self):
        self.window.add_entry(dt.date.today(), "expense", repeat="month")

    def _rule_at(self, row):
        item = self.table.item(row, 0)
        return item.data(Qt.UserRole) if item else None

    def _selected(self):
        rows = self.table.selectionModel().selectedRows()
        return self._rule_at(rows[0].row()) if rows else None

    def _selection_changed(self):
        on = self._selected() is not None
        self.edit.setEnabled(on)
        self.delete.setEnabled(on)

    def _edit_selected(self):
        if self._selected() is not None:
            self.window.edit_rule(self._selected())

    def _delete_selected(self):
        if self._selected() is not None:
            self.window.delete_rule(self._selected(), ask=True)

    def _menu(self, pos):
        row = self.table.rowAt(pos.y())
        rule_id = self._rule_at(row) if row >= 0 else None
        if rule_id is None:
            return
        menu = RoundMenu(parent=self)
        menu.addAction(Action(FIF.EDIT, "Edit…", triggered=lambda: self.window.edit_rule(rule_id)))
        menu.addAction(Action(FIF.DELETE, "Delete…",
                              triggered=lambda: self.window.delete_rule(rule_id, ask=True)))
        menu.exec(self.table.viewport().mapToGlobal(pos))

    def refresh(self):
        today = dt.date.today()
        rules = self.app.ledger.rules
        active = [r for r in rules if (last_date(r) or today) >= today]
        income = sum(per_month(r) for r in active if r.kind == "income")
        expense = sum(per_month(r) for r in active if r.kind == "expense")
        count_in = sum(1 for r in active if r.kind == "income")
        count_out = len(active) - count_in
        self.income.set(money.fmt(income), f"{count_in} {'entry' if count_in == 1 else 'entries'}")
        self.expense.set(money.fmt(expense), f"{count_out} {'entry' if count_out == 1 else 'entries'}")
        self.net.set(money.fmt(income - expense, sign=True),
                     "Before day-to-day spending; weekly and yearly ones are averaged",
                     "critical" if income < expense else None)

        def order(r):
            nxt = next_date(r, today)
            return (nxt is None, nxt or last_date(r) or r.start, r.id)

        rows = sorted(rules, key=order)
        self.table.setRowCount(len(rows))
        for i, r in enumerate(rows):
            category = self.app.category(r.category_id)
            nxt = next_date(r, today)
            if nxt is None:
                upcoming = "Ended"
            else:
                upcoming = fmt_date(nxt) + (f" · {date_number(r, nxt)} of {r.times}" if r.times else "")
            cells = [r.note or category.name, category.name,
                     money.fmt(r.amount if r.kind == "income" else -r.amount, sign=True),
                     describe_rule(r), upcoming, describe_end(r)]
            for c, text in enumerate(cells):
                cell = QTableWidgetItem(text)
                if c == 0:
                    cell.setData(Qt.UserRole, r.id)
                if c == 1:
                    cell.setIcon(category_icon(category.icon).icon())
                if c == 2:
                    cell.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
                self.table.setItem(i, c, cell)
        visible = min(max(len(rows), 1), 12)
        self.table.setFixedHeight(self.table.horizontalHeader().height() + visible * ROW_HEIGHT + 4)
        self.table.setVisible(bool(rows))
        self.empty.setVisible(not rows)
        self._selection_changed()
