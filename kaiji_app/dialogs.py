"""Dialogs over the window (QFluentWidgets MessageBoxBase): add or edit an entry or a repeating
entry, the first-run setup, and adding, editing or deleting a category."""
import dataclasses
import datetime as dt

from PySide6.QtCore import QDate, Qt
from PySide6.QtWidgets import QButtonGroup, QCompleter, QGridLayout, QHBoxLayout, QWidget
from qfluentwidgets import (
    BodyLabel, CalendarPicker, CaptionLabel, ComboBox, CompactSpinBox, EditableComboBox, FlowLayout,
    FluentIcon as FIF, LineEdit, MessageBox, MessageBoxBase, PillPushButton, PushButton,
    SegmentedWidget, SubtitleLabel, ToggleToolButton, getFont,
)

from . import money
from .fluent import AmountEdit, category_icon, literal, secondary, tertiary, tone
from .ledger import FREQ_UNITS, add_months, describe_rule, fmt_date, last_date, month_bounds
from .store import Rule

REPEATS = [(None, "Doesn't repeat"), ("day", "Daily"), ("week", "Weekly"), ("month", "Monthly"),
           ("year", "Yearly")]
ENDS = [(None, "Never"), ("date", "On a date"), ("times", "After")]
DECIMALS = [(0, "No decimals (1,234)"), (2, "Two decimals (1,234.56)")]
ICONS = ["CAFE", "CALORIES", "SHOPPING_CART", "BUS", "CAR", "TRAIN", "AIRPLANE", "HOME", "DOCUMENT",
         "WIFI", "PHONE", "BRIGHTNESS", "GAME", "MOVIE", "MUSIC", "HEADPHONE", "HEART", "VPN",
         "EDUCATION", "LIBRARY", "PEOPLE", "BASKETBALL", "CAMERA", "PALETTE", "CUT", "BROOM", "LEAF",
         "GLOBE", "MAIL", "PRINT", "CERTIFICATE", "ASTERISK", "MARKET", "DEVELOPER_TOOLS",
         "PENCIL_INK", "CANCEL", "SYNC", "CALENDAR", "FLAG", "TAG"]


def label(text):
    return secondary(BodyLabel(text))


def quiet(*buttons):
    """Enter in a dialog should press its primary button, not whichever button has focus."""
    for b in buttons:
        b.setAutoDefault(False)
        b.setDefault(False)


def hint(caption, text, critical=False):
    if critical:
        tone(caption, "critical")
    else:
        tertiary(caption)
    caption.setText(text)


def picker(day=None):
    p = CalendarPicker()
    p.setDateFormat("yyyy/MM/dd")
    if day:
        p.setDate(QDate(day))
    return p


def confirm(window, title, content, yes="Delete"):
    box = MessageBox(title, content, window)
    box.yesButton.setText(yes)
    box.cancelButton.setText("Cancel")
    return bool(box.exec())


class EntryDialog(MessageBoxBase):
    """Add or edit an entry. "Repeats" makes it a repeating entry (salary, rent, subscriptions)
    that the calendar shows on every date it falls on.

    mode: "new"; "entry" (a one-off entry); "series" (every date of a repeating entry);
    "later" (a repeating entry from one date on); "date" (one date of a repeating entry)."""

    SCOPES = {
        "series": "Changes apply to every date, past ones too. To change only from some date on "
                  "(a raise, new rent), right-click that date in the calendar.",
        "later": "Dates before this one stay as they were.",
        "date": "Only this date changes; the other dates stay as they are.",
    }

    def __init__(self, window, app, mode="new", day=None, kind="expense", values=None):
        super().__init__(window)
        self.app, self.mode = app, mode
        self.deleted = False
        v = values or {}
        self.kind = v.get("kind", kind)
        self.picked = v.get("category_id")
        self.chosen = mode != "new"                # a category picked by hand isn't overridden
        start = v.get("day") or day or dt.date.today()

        self.title = SubtitleLabel("")
        self.kinds = SegmentedWidget()
        self.kinds.addItem("expense", "Expense", lambda: self._set_kind("expense"))
        self.kinds.addItem("income", "Income", lambda: self._set_kind("income"))
        head = QHBoxLayout()
        head.addWidget(self.title)
        head.addStretch(1)
        head.addWidget(self.kinds)
        self.viewLayout.addLayout(head)
        if mode in self.SCOPES:
            scope = tertiary(CaptionLabel(self.SCOPES[mode]))
            scope.setWordWrap(True)
            self.viewLayout.addWidget(scope)

        self.amount = AmountEdit()
        self.amount.setFont(getFont(18))
        self.amount.setFixedHeight(40)
        self.amount.set_value(v.get("amount"))
        self.amount.valueChanged.connect(self._amount_changed)
        self.amount_hint = tertiary(CaptionLabel("Arithmetic works too: 120+35, 3*45, 1.5k"))
        amount_row = QHBoxLayout()
        amount_row.setSpacing(8)
        amount_row.addWidget(BodyLabel(money.symbol()))
        amount_row.addWidget(self.amount, 1)

        self.pills = QWidget()
        self.flow = FlowLayout(self.pills, needAni=False)
        self.flow.setContentsMargins(0, 0, 0, 0)
        self.flow.setHorizontalSpacing(6)
        self.flow.setVerticalSpacing(6)
        self.group = QButtonGroup(self)
        self.group.setExclusive(True)
        self.group.idClicked.connect(self._category_clicked)

        self.date = picker(start)
        self.date.dateChanged.connect(self._update_repeat)
        self.note = LineEdit()
        self.note.setPlaceholderText("What was it? (optional)")
        self.note.setText(v.get("note", ""))
        self.notes = app.notes()
        completer = QCompleter(sorted(self.notes), self.note)
        completer.setCaseSensitivity(Qt.CaseInsensitive)
        completer.setFilterMode(Qt.MatchContains)
        completer.setMaxVisibleItems(8)
        self.note.setCompleter(completer)
        self.note.textChanged.connect(self._note_changed)

        self.repeat = ComboBox()
        for value, text in (REPEATS if mode in ("new", "entry") else REPEATS[1:]):
            self.repeat.addItem(text, userData=value)
        freq = v.get("freq")
        self.repeat.setCurrentIndex(max(0, self.repeat.findData(freq)))
        self.repeat.currentIndexChanged.connect(self._update_repeat)
        self.every = CompactSpinBox()
        self.every.setRange(1, 99)
        self.every.setValue(v.get("every") or 1)
        self.every.valueChanged.connect(self._update_repeat)
        self.every_text, self.unit = BodyLabel("every"), BodyLabel("")
        repeat_row = QHBoxLayout()
        repeat_row.setSpacing(8)
        for w in (self.repeat, self.every_text, self.every, self.unit):
            repeat_row.addWidget(w)
        repeat_row.addStretch(1)
        # ends: never, on a date, or after a number of times
        until, times = v.get("until"), v.get("times")
        if until and times:            # both set: show the one that ends it first
            probe = Rule(0, self.kind, 0, None, "", v.get("freq") or "month", v.get("every") or 1,
                         start, until, times)
            until, times = (until, None) if last_date(probe) == until else (None, times)
        self.ends = ComboBox()
        for value, text in ENDS:
            self.ends.addItem(text, userData=value)
        self.ends.setCurrentIndex(2 if times else 1 if until else 0)
        self.ends.currentIndexChanged.connect(self._ends_changed)
        self.until = picker(until or add_months(start, 12))
        self.until.dateChanged.connect(self._update_repeat)
        self.times = CompactSpinBox()
        self.times.setRange(1, 999)
        self.times.setValue(times or 12)
        self.times.valueChanged.connect(self._update_repeat)
        self.times_unit = BodyLabel("times")
        ends_row = QHBoxLayout()
        ends_row.setSpacing(8)
        for w in (self.ends, self.until, self.times, self.times_unit):
            ends_row.addWidget(w)
        ends_row.addStretch(1)
        self.repeat_hint = tertiary(CaptionLabel(""))
        self.repeat_hint.setWordWrap(True)

        grid = QGridLayout()
        grid.setHorizontalSpacing(16)
        grid.setVerticalSpacing(10)
        grid.setColumnStretch(1, 1)
        date_text = {"series": "Starts", "later": "From"}.get(mode, "Date")
        self.repeat_label, self.ends_label = label("Repeats"), label("Ends")
        rows = [("Amount", amount_row), ("", self.amount_hint), ("Category", self.pills),
                (date_text, self.date), ("Note", self.note), (self.repeat_label, repeat_row),
                (self.ends_label, ends_row), ("", self.repeat_hint)]
        for r, (name, field) in enumerate(rows):
            if name:
                grid.addWidget(name if isinstance(name, QWidget) else label(name), r, 0,
                               Qt.AlignLeft | (Qt.AlignTop if field is self.pills else Qt.AlignVCenter))
            if isinstance(field, QWidget):
                align = Qt.AlignLeft if field is self.date else Qt.AlignmentFlag(0)
                grid.addWidget(field, r, 1, align)
            else:
                grid.addLayout(field, r, 1)
        self.viewLayout.addSpacing(4)
        self.viewLayout.addLayout(grid)

        self.yesButton.setText("Add" if mode == "new" else "Save")
        self.cancelButton.setText("Cancel")
        self.yesButton.setDefault(True)
        quiet(self.cancelButton, self.date, self.until, self.repeat, self.ends,
              *self.kinds.items.values())
        if mode in ("entry", "series"):
            delete = PushButton(FIF.DELETE, "Delete")
            delete.clicked.connect(self._delete)
            quiet(delete)
            self.buttonLayout.insertWidget(0, delete, 1)
        self.widget.setMinimumWidth(560)

        self.kinds.setCurrentItem(self.kind)
        self._set_kind(self.kind)
        self._update_repeat()

    # ---- behaviour
    def showEvent(self, e):
        super().showEvent(e)
        self.amount.setFocus()
        self.amount.selectAll()

    def _set_kind(self, kind):
        self.kind = kind
        noun = "expense" if kind == "expense" else "income"
        self.title.setText({"new": f"Add {noun}", "entry": f"Edit {noun}",
                            "series": f"Edit repeating {noun}",
                            "later": f"Change repeating {noun}",
                            "date": f"Edit one {noun} date"}[self.mode])
        for b in self.group.buttons():
            self.group.removeButton(b)
        while self.flow.count():
            w = self.flow.takeAt(0)
            w.hide()            # deleteLater alone leaves it painted until the event loop runs
            w.deleteLater()
        cats = self.app.kind_categories(kind)
        for c in cats:
            pill = PillPushButton(category_icon(c.icon), literal(c.name), self.pills)
            quiet(pill)
            self.group.addButton(pill, c.id)
            self.flow.addWidget(pill)
            pill.show()
        ids = [c.id for c in cats]
        if self.picked not in ids:
            usual = self.app.store.usual_category(kind, dt.date.today() - dt.timedelta(days=90))
            self.picked = usual if usual in ids else (ids[0] if ids else None)
            self.chosen = False
        if self.picked is not None:
            self.group.button(self.picked).setChecked(True)
        self._note_changed(self.note.text())

    def _category_clicked(self, category_id):
        self.picked = category_id
        self.chosen = True

    def _note_changed(self, text):
        """A note typed before brings its category along (until one is picked by hand)."""
        known = self.notes.get(text.strip())
        if self.chosen or not known or known[0] != self.kind:
            return
        button = self.group.button(known[1]) if known[1] is not None else None
        if button:
            button.setChecked(True)
            self.picked = known[1]

    def _amount_changed(self, cents):
        if self.amount.is_empty():
            hint(self.amount_hint, "Arithmetic works too: 120+35, 3*45, 1.5k")
        elif cents is None:
            hint(self.amount_hint, "That isn't an amount. Use numbers and + − × ÷.", critical=True)
        else:
            hint(self.amount_hint,
                 f"= {money.fmt(cents)}" if money.is_expression(self.amount.text()) else " ")

    def _freq(self):
        return self.repeat.currentData() if self.mode != "date" else None

    def _until(self):
        return self.until.getDate().toPython() if self.ends.currentData() == "date" else None

    def _times(self):
        return self.times.value() if self.ends.currentData() == "times" else None

    def _ends_changed(self, _):
        start = self.date.getDate().toPython()
        if self.ends.currentData() == "date" and self.until.getDate().toPython() <= start:
            self.until.setDate(QDate(add_months(start, 12)))     # a year on, not before the start
        self._update_repeat()

    def _update_repeat(self, *_):
        for w in (self.repeat_label, self.repeat):
            w.setVisible(self.mode != "date")       # one date of a repeating entry can't repeat
        freq = self._freq()
        on = freq is not None
        ends = self.ends.currentData()
        for w in (self.every_text, self.every, self.unit, self.ends_label, self.ends, self.repeat_hint):
            w.setVisible(on)
        self.until.setVisible(on and ends == "date")
        self.times.setVisible(on and ends == "times")
        self.times_unit.setVisible(on and ends == "times")
        if not on:
            return
        every = self.every.value()
        self.unit.setText(FREQ_UNITS[freq][0 if every == 1 else 1])
        self.times_unit.setText("time" if self.times.value() == 1 else "times")
        start, until, times = self.date.getDate().toPython(), self._until(), self._times()
        if until and until < start:
            hint(self.repeat_hint, "The end date is before the first date.", critical=True)
            return
        rule = Rule(0, self.kind, 0, None, "", freq, every, start, until, times)
        text = describe_rule(rule)
        if freq == "month" and start.day > 28:
            text += " (the last day of shorter months)"
        text += f", from {fmt_date(start)}"
        if times == 1:
            text += ", just once"
        elif times:
            text += f", {times} times: the last is on {fmt_date(last_date(rule))}"
        else:
            text += f" until {fmt_date(until)}" if until else ", with no end date"
        hint(self.repeat_hint, text + ".")

    def _delete(self):
        self.deleted = True
        self.accept()

    def validate(self):
        if self.amount.value() is None:
            self.amount.setError(True)
            if self.amount.is_empty():
                hint(self.amount_hint, "Enter an amount.", critical=True)
            self.amount.setFocus()
            return False
        until = self._until()
        if self._freq() and until and until < self.date.getDate().toPython():
            return False
        return True

    def values(self):
        freq = self._freq()
        return {"kind": self.kind, "amount": self.amount.value(),
                "category_id": self.picked, "day": self.date.getDate().toPython(),
                "note": self.note.text().strip(), "freq": freq,
                "every": self.every.value() if freq else 1,
                "until": self._until() if freq else None,
                "times": self._times() if freq else None}


class WelcomeDialog(MessageBoxBase):
    """First run: the currency, what you have today, and optionally your pay and savings goal.
    Run again from Settings, it starts from what's set now."""

    def __init__(self, window, app):
        super().__init__(window)
        self.app = app
        today = dt.date.today()
        symbol, decimals = app.store.currency()
        plan = app.ledger.plan
        self.salary = next((r for r in app.ledger.rules if r.kind == "income" and r.freq == "month"
                            and r.note == "Salary" and (last_date(r) or today) >= today), None)
        self.now = app.ledger.days(today, today)[today]
        title = SubtitleLabel("Welcome to Kaiji 花錢")
        text = BodyLabel("A few numbers so Kaiji can tell you how much you can spend. All of "
                         "them can be changed later in Settings.")
        text.setWordWrap(True)
        self.viewLayout.addWidget(title)
        self.viewLayout.addWidget(text)

        self.currency = EditableComboBox()
        self.currency.addItems(money.CURRENCIES if symbol in money.CURRENCIES
                               else [symbol] + money.CURRENCIES)
        self.currency.setText(symbol)
        self.currency.setFixedWidth(110)
        self.decimals = ComboBox()
        for value, name in DECIMALS:
            self.decimals.addItem(name, userData=value)
        self.decimals.setCurrentIndex(0 if decimals == 0 else 1)
        self.currency.currentTextChanged.connect(self._currency_changed)

        self.balance = AmountEdit(allow_negative=True)
        self.balance.setPlaceholderText("e.g. 52,000")
        self.pay = AmountEdit()
        self.pay.setPlaceholderText("optional")
        self.pay_day = CompactSpinBox()
        self.pay_day.setRange(1, 31)
        self.pay_day.setValue(5)
        self.goal = AmountEdit()
        self.goal.setPlaceholderText("optional")
        for edit in (self.balance, self.pay, self.goal):
            edit.setFixedWidth(200)
        if plan.start_date:
            self.balance.set_value(self.now.balance)
        if self.salary:
            self.pay.set_value(self.salary.amount)
            self.pay_day.setValue(self.salary.start.day)
        if plan.savings_goal:
            self.goal.set_value(plan.savings_goal)
        self.prefilled = (self.balance.value(), self.pay.value(), self.pay_day.value())

        grid = QGridLayout()
        grid.setHorizontalSpacing(12)
        grid.setVerticalSpacing(12)
        currency_row = QHBoxLayout()
        currency_row.setSpacing(8)
        currency_row.addWidget(self.currency)
        currency_row.addWidget(self.decimals)
        currency_row.addStretch(1)
        pay_row = QHBoxLayout()
        pay_row.setSpacing(8)
        pay_row.addWidget(self.pay)
        pay_row.addWidget(BodyLabel("on day"))
        pay_row.addWidget(self.pay_day)
        pay_row.addWidget(BodyLabel("of each month"))
        pay_row.addStretch(1)
        rows = [("Currency", currency_row),
                ("Money you have today", self.balance),
                ("", tertiary(CaptionLabel("All your accounts together; Kaiji works out the balance "
                                           "of every day from here."))),
                ("Monthly pay", pay_row),
                ("Savings goal per month", self.goal)]
        for r, (name, field) in enumerate(rows):
            if name:
                grid.addWidget(label(name), r, 0)
            if isinstance(field, QWidget):
                grid.addWidget(field, r, 1, Qt.AlignLeft)
            else:
                grid.addLayout(field, r, 1)
        self.viewLayout.addSpacing(4)
        self.viewLayout.addLayout(grid)
        self.yesButton.setText("Get started")
        self.cancelButton.setText("Skip")
        self.yesButton.setDefault(True)
        quiet(self.cancelButton, self.decimals)
        self.widget.setMinimumWidth(580)

    def _currency_changed(self, text):
        code = next((c for c, s in money.SYMBOLS.items() if s == text.strip()), "")
        self.decimals.setCurrentIndex(0 if code in money.NO_DECIMALS else 1)

    def validate(self):
        bad = [e for e in (self.balance, self.pay, self.goal) if not e.is_valid()]
        for e in bad:
            e.setError(True)
        return not bad and bool(self.currency.text().strip())

    def apply(self):
        """Save what was entered."""
        app, today = self.app, dt.date.today()
        app.set_currency(self.currency.text().strip(), self.decimals.currentData())
        plan = dataclasses.replace(app.ledger.plan)
        balance, pay, pay_day = self.balance.value(), self.pay.value(), self.pay_day.value()
        if balance is not None and balance != self.prefilled[0]:
            # what you have now, today's entries included
            plan.start_balance = balance - (self.now.income - self.now.expense)
            plan.start_date = today
        plan.savings_goal = self.goal.value() or 0
        app.set_plan(plan)
        if pay and (pay, pay_day) != self.prefilled[1:]:
            category = next((c.id for c in app.kind_categories("income") if c.name == "Salary"), None)
            last = month_bounds(today.year, today.month)[1].day
            v = {"kind": "income", "amount": pay, "day": today.replace(day=min(pay_day, last)),
                 "category_id": self.salary.category_id if self.salary else category,
                 "note": "Salary", "freq": "month", "every": 1, "until": None, "times": None}
            if self.salary:
                app.change_from(self.salary.id, v)      # the new pay from this month on
            else:
                app.save_entry(v)


class CategoryDialog(MessageBoxBase):
    """Add or edit a category: its name and icon."""

    def __init__(self, window, title, name="", icon="TAG"):
        super().__init__(window)
        self.viewLayout.addWidget(SubtitleLabel(title))
        self.name = LineEdit()
        self.name.setPlaceholderText("Name")
        self.name.setText(name)
        self.viewLayout.addWidget(self.name)
        self.viewLayout.addWidget(label("Icon"))
        icons = QWidget()
        flow = FlowLayout(icons, needAni=False)
        flow.setContentsMargins(0, 0, 0, 0)
        flow.setHorizontalSpacing(6)
        flow.setVerticalSpacing(6)
        self.group = QButtonGroup(self)
        self.group.setExclusive(True)
        self.names = list(ICONS) if icon in ICONS else [icon] + ICONS
        for i, key in enumerate(self.names):
            b = ToggleToolButton(category_icon(key), icons)
            b.setFixedSize(38, 34)
            self.group.addButton(b, i)
            flow.addWidget(b)
            if key == icon:
                b.setChecked(True)
        self.viewLayout.addWidget(icons)
        self.yesButton.setText("Save")
        self.cancelButton.setText("Cancel")
        self.yesButton.setDefault(True)
        quiet(self.cancelButton)
        self.widget.setMinimumWidth(460)
        self.widget.setMaximumWidth(460)

    def showEvent(self, e):
        super().showEvent(e)
        self.name.setFocus()

    def validate(self):
        ok = bool(self.name.text().strip())
        self.name.setError(not ok)
        return ok

    def values(self):
        index = self.group.checkedId()
        return self.name.text().strip(), self.names[index] if index >= 0 else "TAG"


class DeleteCategoryDialog(MessageBoxBase):
    """Delete a category that's in use: its entries move to another one."""

    def __init__(self, window, category, uses, others):
        super().__init__(window)
        self.viewLayout.addWidget(SubtitleLabel(f"Delete “{category.name}”?"))
        text = BodyLabel(f"{uses} {'entry uses' if uses == 1 else 'entries use'} this category. "
                         "Move them to:")
        text.setWordWrap(True)
        self.viewLayout.addWidget(text)
        self.target = ComboBox()
        for c in others:
            self.target.addItem(literal(c.name), category_icon(c.icon), c.id)
        self.viewLayout.addWidget(self.target, 0, Qt.AlignLeft)
        self.yesButton.setText("Delete")
        self.cancelButton.setText("Cancel")
        quiet(self.cancelButton, self.target)
        self.widget.setMinimumWidth(420)

    def move_to(self):
        return self.target.currentData()
