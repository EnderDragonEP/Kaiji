"""Calendar: a month of income, expenses and the balance per day - projected for the days ahead -
with the selected day's entries and the month's plan."""
import datetime as dt

from PySide6.QtCore import QRectF, Qt, Signal
from PySide6.QtGui import QFont, QFontMetrics, QPainter, QPen
from PySide6.QtWidgets import QGridLayout, QHBoxLayout, QSizePolicy, QVBoxLayout, QWidget
from qfluentwidgets import (
    BodyLabel, CaptionLabel, FluentIcon as FIF, PrimaryPushButton, PushButton, ScrollArea,
    SimpleCardWidget,
    StrongBodyLabel, SubtitleLabel, ToolTipFilter, TransparentToolButton, getFont,
)

from . import fluent, money
from .entry_list import EntryList
from .fluent import Page, badge, color, secondary, tone
from .ledger import MONTHS, WEEKDAY_SHORT, add_months, fmt_long, month_bounds


class MonthGrid(QWidget):
    """Month view with a tile per day: income, expenses and the end-of-day balance (≈ for days
    ahead, red when it drops below the minimum). QFluentWidgets has no month view with content
    in the days, so this one is painted with the library's fonts and theme color."""

    selected = Signal(object)          # date
    activated = Signal(object)         # date (double-click / Enter)
    month_changed = Signal(int, int)
    HEADER, GAP = 28, 4

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setMinimumSize(560, 420)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        today = dt.date.today()
        self.year, self.month, self.current, self.today = today.year, today.month, today, today
        self.days, self.floor, self.week_start, self._hover = {}, 0, 0, None
        fluent.on_theme_change(self.update)

    def set_data(self, days, floor, today, week_start):
        self.days, self.floor, self.today, self.week_start = days, floor, today, week_start
        self.update()

    def set_current(self, day, emit=True):
        self.current = day
        if (day.year, day.month) != (self.year, self.month):
            self.year, self.month = day.year, day.month
            self.month_changed.emit(self.year, self.month)
        self.update()
        if emit:
            self.selected.emit(day)

    def first_day(self):
        first = dt.date(self.year, self.month, 1)
        return first - dt.timedelta(days=(first.weekday() - self.week_start) % 7)

    def rows(self):
        first = dt.date(self.year, self.month, 1)
        lead = (first.weekday() - self.week_start) % 7
        return (lead + month_bounds(self.year, self.month)[1].day + 6) // 7

    def visible_range(self):
        start = self.first_day()
        return start, start + dt.timedelta(days=self.rows() * 7 - 1)

    def _cell(self, i):
        rows = self.rows()
        w = (self.width() - 6 * self.GAP) / 7
        h = (self.height() - self.HEADER - (rows - 1) * self.GAP) / rows
        r, c = divmod(i, 7)
        return QRectF(c * (w + self.GAP), self.HEADER + r * (h + self.GAP), w, h)

    def _index_at(self, pos):
        for i in range(self.rows() * 7):
            if self._cell(i).contains(pos):
                return i
        return None

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        w = (self.width() - 6 * self.GAP) / 7
        p.setFont(getFont(12))
        p.setPen(color("secondary"))
        for c in range(7):
            name = WEEKDAY_SHORT[(c + self.week_start) % 7]
            p.drawText(QRectF(c * (w + self.GAP) + 8, 0, w - 8, self.HEADER),
                       Qt.AlignLeft | Qt.AlignVCenter, name)
        for i in range(self.rows() * 7):
            self._paint_day(p, i)

    def _amount(self, fm, cents, width, sign):
        """The amount as wide as it fits: 40,000, else 40K."""
        text = sign + money.fmt(cents, symbol=False)
        if fm.horizontalAdvance(text) > width:
            text = sign + money.compact(cents)
        return fm.elidedText(text, Qt.ElideRight, int(width))

    def _paint_day(self, p, i):
        day = self.first_day() + dt.timedelta(days=i)
        r = self._cell(i)
        in_month = day.month == self.month
        info = self.days.get(day)
        low = in_month and info is not None and info.balance < self.floor

        p.setPen(Qt.NoPen)
        if low:
            p.setBrush(color("critical_bg"))
            p.drawRoundedRect(r, 5, 5)
        elif in_month:
            p.setBrush(color("fill"))
            p.setPen(QPen(color("stroke"), 1))
            p.drawRoundedRect(r.adjusted(0.5, 0.5, -0.5, -0.5), 5, 5)
            p.setPen(Qt.NoPen)
        if i == self._hover:
            p.setBrush(color("hover"))
            p.drawRoundedRect(r, 5, 5)
        if day == self.current:
            p.setBrush(Qt.NoBrush)
            p.setPen(QPen(color("accent"), 2))
            p.drawRoundedRect(r.adjusted(1, 1, -1, -1), 5, 5)

        number = QRectF(r.left() + 6, r.top() + 6, 26, 26)
        p.setFont(getFont(14, QFont.DemiBold))
        if day == self.today:
            p.setPen(Qt.NoPen)
            p.setBrush(color("accent"))
            p.drawEllipse(number)
            p.setPen(color("on_accent"))
        else:
            p.setPen(color("text" if in_month else "disabled"))
        p.drawText(number, Qt.AlignCenter, str(day.day))
        if not in_month or info is None:
            return

        if any(item.repeating for item in info.items):
            p.setOpacity(0.5)
            FIF.SYNC.render(p, QRectF(r.right() - 20, r.top() + 13, 12, 12))
            p.setOpacity(1)

        future = day > self.today
        ink = color("secondary" if future else "text")
        lines = []
        if info.income:
            lines.append(("income", info.income, "+"))
        if info.expense:
            lines.append(("expense", info.expense, money.MINUS))
        p.setFont(getFont(12))
        fm = QFontMetrics(p.font())
        step = 18
        show_balance = bool(info.items) or day == self.today or day == month_bounds(day.year, day.month)[1]
        bottom = r.bottom() - (22 if show_balance else 4)
        y = r.top() + 36
        for key, cents, sign in lines:
            if y + step > bottom + 2:
                break
            p.setPen(Qt.NoPen)
            p.setBrush(color(key))
            p.drawEllipse(QRectF(r.left() + 9, y + step / 2 - 3.5, 7, 7))
            p.setPen(ink)
            width = r.width() - 30
            p.drawText(QRectF(r.left() + 21, y, width, step), Qt.AlignLeft | Qt.AlignVCenter,
                       self._amount(fm, cents, width, sign))
            y += step
        if show_balance and r.height() >= 62:
            text = ("≈ " if future else "") + money.fmt(info.balance, symbol=False)
            if fm.horizontalAdvance(text) > r.width() - 14:
                text = ("≈ " if future else "") + money.compact(info.balance)
            p.setPen(color("critical") if low else color("tertiary"))
            p.drawText(QRectF(r.left() + 7, r.bottom() - 22, r.width() - 14, 18),
                       Qt.AlignRight | Qt.AlignVCenter, text)

    def mouseMoveEvent(self, event):
        index = self._index_at(event.position())
        if index != self._hover:
            self._hover = index
            self.update()

    def leaveEvent(self, event):
        self._hover = None
        self.update()

    def mousePressEvent(self, event):
        index = self._index_at(event.position())
        if index is not None:
            self.set_current(self.first_day() + dt.timedelta(days=index))

    def mouseDoubleClickEvent(self, event):
        index = self._index_at(event.position())
        if index is not None:
            self.activated.emit(self.first_day() + dt.timedelta(days=index))

    def keyPressEvent(self, event):
        key = event.key()
        step = {Qt.Key_Left: -1, Qt.Key_Right: 1, Qt.Key_Up: -7, Qt.Key_Down: 7}.get(key)
        if step:
            self.set_current(self.current + dt.timedelta(days=step))
        elif key in (Qt.Key_PageUp, Qt.Key_PageDown):
            self.set_current(add_months(self.current, -1 if key == Qt.Key_PageUp else 1))
        elif key == Qt.Key_Home:
            self.set_current(dt.date.today())
        elif key in (Qt.Key_Return, Qt.Key_Enter):
            self.activated.emit(self.current)
        else:
            super().keyPressEvent(event)


def summary_cell(caption):
    cell = QVBoxLayout()
    cell.setSpacing(0)
    value = StrongBodyLabel("–")
    cell.addWidget(secondary(CaptionLabel(caption)))
    cell.addWidget(value)
    return cell, value


class CalendarPage(Page):
    def __init__(self, app, window):
        super().__init__("calendar", "Calendar")
        self.app, self.window = app, window
        self.days = {}

        bar = QHBoxLayout()
        bar.setSpacing(8)
        for icon, tip, months in ((FIF.LEFT_ARROW, "Previous month (Page Up)", -1),
                                  (FIF.RIGHT_ARROW, "Next month (Page Down)", 1)):
            b = TransparentToolButton(icon)
            b.setToolTip(tip)
            b.installEventFilter(ToolTipFilter(b))
            b.clicked.connect(lambda _=False, m=months: self._step(m))
            bar.addWidget(b)
        self.month_label = SubtitleLabel("")
        self.month_label.setMinimumWidth(190)
        today = PushButton("Today")
        today.clicked.connect(lambda: self.grid.set_current(dt.date.today()))
        add = PrimaryPushButton(FIF.ADD, "Add entry")
        add.clicked.connect(lambda: window.add_entry(self.grid.current))
        for w in (self.month_label, today):
            bar.addWidget(w)
        bar.addStretch(1)
        bar.addWidget(add)
        self.vbox.addLayout(bar)

        body = QHBoxLayout()
        body.setSpacing(16)
        grid_card = SimpleCardWidget()
        grid_box = QVBoxLayout(grid_card)
        grid_box.setContentsMargins(12, 8, 12, 12)
        self.grid = MonthGrid()
        self.grid.selected.connect(lambda _: self._show_day())
        self.grid.month_changed.connect(lambda *_: self.refresh())
        self.grid.activated.connect(lambda day: window.add_entry(day))
        grid_box.addWidget(self.grid)
        body.addWidget(grid_card, 1)

        side = QVBoxLayout()
        side.setContentsMargins(0, 0, 0, 0)
        side.setSpacing(12)
        day_card = SimpleCardWidget()
        day_box = QVBoxLayout(day_card)
        day_box.setContentsMargins(16, 16, 16, 16)
        day_box.setSpacing(8)
        self.day_title = SubtitleLabel("")
        self.day_badges = QHBoxLayout()
        self.day_badges.setSpacing(6)
        details = QGridLayout()
        details.setHorizontalSpacing(16)
        details.setVerticalSpacing(6)
        self.detail = {}
        for row, key in enumerate(["Income", "Expenses", "Balance"]):
            name, value = secondary(BodyLabel(key)), StrongBodyLabel("")
            details.addWidget(name, row, 0)
            details.addWidget(value, row, 1)
            self.detail[key] = (name, value)
        details.setColumnStretch(1, 1)
        self.entries = EntryList("Nothing on this day. Double-click a day in the calendar to add "
                                 "an entry.")
        self.entries.clicked.connect(window.edit_item)
        self.entries.menu_requested.connect(window.item_menu)
        buttons = QHBoxLayout()
        buttons.setSpacing(8)
        for kind, text in (("expense", "Expense"), ("income", "Income")):
            b = PushButton(FIF.ADD, text)
            b.clicked.connect(lambda _=False, k=kind: window.add_entry(self.grid.current, k))
            buttons.addWidget(b)
        buttons.addStretch(1)
        day_box.addWidget(self.day_title)
        day_box.addLayout(self.day_badges)
        day_box.addLayout(details)
        day_box.addSpacing(4)
        day_box.addWidget(secondary(CaptionLabel("Entries")))
        day_box.addWidget(self.entries)
        day_box.addSpacing(4)
        day_box.addLayout(buttons)
        side.addWidget(day_card)

        month_card = SimpleCardWidget()
        month_box = QVBoxLayout(month_card)
        month_box.setContentsMargins(16, 16, 16, 16)
        month_box.setSpacing(8)
        self.month_title = StrongBodyLabel("")
        month_box.addWidget(self.month_title)
        summary = QGridLayout()
        summary.setHorizontalSpacing(16)
        summary.setVerticalSpacing(10)
        self.summary = {}
        for i, (key, caption) in enumerate([("Income", "Income"), ("Expenses", "Expenses"),
                                            ("Net", "Net"), ("Left", "Left to spend"),
                                            ("Start", "Balance at start"), ("End", "Balance at end")]):
            cell, value = summary_cell(caption)
            summary.addLayout(cell, i // 2, i % 2)
            self.summary[key] = (cell.itemAt(0).widget(), value)
        month_box.addLayout(summary)
        side.addWidget(month_card)
        side.addStretch(1)
        side_widget = QWidget()
        side_widget.setObjectName("side")
        side_widget.setStyleSheet("QWidget#side { background: transparent; }")
        side_widget.setLayout(side)
        # the side scrolls on its own, so a long day doesn't stretch the calendar with it
        side_scroll = ScrollArea()
        side_scroll.setWidget(side_widget)
        side_scroll.setWidgetResizable(True)
        side_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        side_scroll.enableTransparentBackground()
        side_scroll.setFixedWidth(340)
        body.addWidget(side_scroll)
        self.vbox.addLayout(body, 1)

        app.data_changed.connect(self._data_changed)
        app.settings_applied.connect(lambda keys: self.refresh() if "week_start" in keys else None)

    def activate(self):
        self.refresh()

    def show_day(self, day):
        self.grid.set_current(day)
        self.grid.setFocus()

    def _data_changed(self):
        if self.isVisible():
            self.refresh()

    def _step(self, months):
        self.grid.set_current(add_months(self.grid.current, months))

    def refresh(self):
        app, today = self.app, dt.date.today()
        start, end = self.grid.visible_range()
        self.days = app.ledger.days(start, end)
        self.grid.set_data(self.days, app.ledger.plan.min_balance, today, app.settings.week_start)
        year, month = self.grid.year, self.grid.month
        self.month_label.setText(f"{MONTHS[month - 1]} {year}")
        self._show_month(app.ledger.month_plan(year, month, today))
        self._show_day()

    def _show_month(self, plan):
        self.month_title.setText(f"{MONTHS[plan.start.month - 1]} {plan.start.year}")
        s = self.summary
        approx = "" if plan.status == "past" else "≈ "
        s["Income"][1].setText(money.fmt(plan.income))
        s["Expenses"][1].setText(money.fmt(plan.expense))
        s["Net"][1].setText(money.fmt(plan.net, sign=True))
        s["Start"][1].setText(money.fmt(plan.opening))
        s["End"][1].setText(approx + money.fmt(plan.closing))
        caption, value = s["Left"]
        if plan.status == "past":
            caption.setText("Savings goal" if plan.goal else "Spent per day")
            if plan.goal:
                short = plan.goal - plan.net
                value.setText("Met" if short <= 0 else f"Short by {money.fmt(short)}")
                tone(value, "success" if short <= 0 else "caution")
            else:
                value.setText(money.fmt(plan.expense // ((plan.end - plan.start).days + 1)))
                tone(value)
        else:
            caption.setText("Left to spend")
            value.setText(money.fmt(plan.left) + (f" · {money.fmt(plan.per_day)}/day"
                                                  if plan.left > 0 and plan.days_left > 1 else ""))
            tone(value, "critical" if plan.left < 0 else None)

    def _show_day(self):
        day, today = self.grid.current, dt.date.today()
        info = self.days.get(day) or self.app.ledger.days(day, day)[day]
        floor = self.app.ledger.plan.min_balance
        self.day_title.setText(fmt_long(day))
        while self.day_badges.count():
            w = self.day_badges.takeAt(0).widget()
            if w:
                w.hide()
                w.deleteLater()
        if day == today:
            self.day_badges.addWidget(badge("Today", "info"))
        elif day > today and info.items:
            self.day_badges.addWidget(badge("Planned", "info"))
        if info.balance < 0:
            self.day_badges.addWidget(badge("Overdrawn", "critical"))
        elif info.balance < floor:
            self.day_badges.addWidget(badge("Below your minimum", "critical"))
        self.day_badges.addStretch(1)

        values = {"Income": money.fmt(info.income, sign=True) if info.income else "",
                  "Expenses": money.MINUS + money.fmt(info.expense) if info.expense else "",
                  "Balance": ("≈ " if day > today else "") + money.fmt(info.balance)}
        for key, (name, value) in self.detail.items():
            value.setText(values[key])
            name.setVisible(bool(values[key]))
            value.setVisible(bool(values[key]))
        self.detail["Balance"][0].setText("Projected balance" if day > today else "Balance at day end")
        tone(self.detail["Balance"][1], "critical" if info.balance < floor else None)
        self.entries.set_items(self.app, info.items, today)
