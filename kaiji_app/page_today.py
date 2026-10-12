"""Today: how much you can spend, at a glance, and what's coming up."""
import datetime as dt

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QGridLayout, QHBoxLayout, QVBoxLayout, QWidget
from qfluentwidgets import (
    BodyLabel, CaptionLabel, FluentIcon as FIF, InfoBar, InfoBarIcon, InfoBarPosition,
    LargeTitleLabel, PrimaryPushButton, ProgressRing, PushButton, SimpleCardWidget, TitleLabel,
)

from . import fluent, money
from .charts import BalanceChart
from .entry_list import EntryList
from .fluent import Page, StatCard, header_card, secondary, tertiary, tone
from .ledger import DAY, MONTHS, WEEKDAY, WEEKDAY_SHORT, fmt_date, fmt_short

BAR_ICONS = {"info": InfoBarIcon.INFORMATION, "warning": InfoBarIcon.WARNING, "error": InfoBarIcon.ERROR}
UPCOMING_DAYS, UPCOMING_ROWS = 30, 8
LOOKAHEAD = 60                     # days the low-balance warning looks ahead
FORECAST_BACK, FORECAST_AHEAD = 30, 90


class BudgetRing(QWidget):
    """The library's ProgressRing with the share of this month's money used in the middle."""

    def __init__(self, size=168, parent=None):
        super().__init__(parent)
        self.ring = ProgressRing(self)
        self.ring.setFixedSize(size, size)
        self.ring.setStrokeWidth(10)
        self.ring.setRange(0, 1000)
        self.ring.setTextVisible(False)
        self.text = TitleLabel("")
        self.caption = secondary(CaptionLabel(""))
        middle = QVBoxLayout()
        middle.setSpacing(0)
        middle.addStretch(1)
        middle.addWidget(self.text, 0, Qt.AlignHCenter)
        middle.addWidget(self.caption, 0, Qt.AlignHCenter)
        middle.addStretch(1)
        grid = QGridLayout(self)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.addWidget(self.ring, 0, 0)
        grid.addLayout(middle, 0, 0)        # same cell: the labels sit over the ring

    def set_state(self, fraction, severity=None, text="", caption=""):
        if severity:
            self.ring.setCustomBarColor(fluent.LIGHT[severity], fluent.DARK[severity])
        else:
            self.ring.setCustomBarColor("", "")          # invalid colors: back to the theme color
        self.ring.setValue(round(1000 * min(1.0, max(0.0, fraction))))
        self.text.setText(text)
        self.caption.setText(caption)


class TodayPage(Page):
    def __init__(self, app, window):
        super().__init__("today", "Today")
        self.app, self.window = app, window
        self.date = secondary(BodyLabel(""))
        self.vbox.addWidget(self.date)
        self.bar_box = QVBoxLayout()
        self.vbox.addLayout(self.bar_box)
        self.bar, self._bar_key = None, None

        hero = SimpleCardWidget()
        row = QHBoxLayout(hero)
        row.setContentsMargins(28, 24, 28, 24)
        row.setSpacing(36)
        self.ring = BudgetRing(168)
        row.addWidget(self.ring)
        info = QVBoxLayout()
        info.setSpacing(2)
        self.eyebrow = secondary(BodyLabel(""))
        self.big = LargeTitleLabel("")
        font = self.big.font()
        font.setPixelSize(48)
        self.big.setFont(font)
        self.sub = secondary(BodyLabel(""))
        self.detail = tertiary(CaptionLabel(""))
        self.detail.setWordWrap(True)
        add_expense = PrimaryPushButton(FIF.ADD, "Add expense")
        add_expense.clicked.connect(lambda: window.add_entry(dt.date.today(), "expense"))
        add_income = PushButton(FIF.ADD, "Add income")
        add_income.clicked.connect(lambda: window.add_entry(dt.date.today(), "income"))
        buttons = QHBoxLayout()
        buttons.setSpacing(8)
        buttons.addWidget(add_expense)
        buttons.addWidget(add_income)
        buttons.addStretch(1)
        info.addStretch(1)
        for w in (self.eyebrow, self.big, self.sub):
            info.addWidget(w)
        info.addSpacing(6)
        info.addWidget(self.detail)
        info.addSpacing(16)
        info.addLayout(buttons)
        info.addStretch(1)
        row.addLayout(info, 1)
        self.vbox.addWidget(hero)

        self.balance = StatCard("Balance now")
        self.month_end = StatCard("End of the month")
        self.lowest = StatCard(f"Lowest in the next {LOOKAHEAD} days")
        self.spent = StatCard("Spent today")
        cards = QHBoxLayout()
        cards.setSpacing(12)
        for card in (self.balance, self.month_end, self.lowest, self.spent):
            cards.addWidget(card)
        self.vbox.addLayout(cards)

        self.upcoming = EntryList("Nothing planned. Add your pay, rent and bills as repeating entries "
                                  "and they show up here before they happen.")
        self.upcoming.clicked.connect(window.edit_item)
        self.upcoming.menu_requested.connect(window.item_menu)
        self.more = tertiary(CaptionLabel(""))
        upcoming, box = header_card(f"Coming up · next {UPCOMING_DAYS} days", self.upcoming, self.more)
        box.addStretch(1)
        self.forecast = BalanceChart(height=300)
        forecast, box = header_card(f"Balance · last {FORECAST_BACK} days and next {FORECAST_AHEAD}",
                                    self.forecast)
        box.addStretch(1)
        bottom = QHBoxLayout()
        bottom.setSpacing(12)
        bottom.addWidget(upcoming, 5)
        bottom.addWidget(forecast, 6)
        self.vbox.addLayout(bottom)
        self.vbox.addStretch(1)

        app.data_changed.connect(self.refresh)

    def activate(self):
        self.refresh()

    def _show_bar(self, severity=None, title="", content="", action=None, on_action=None):
        """Inline InfoBar; rebuilt only when what it says changes."""
        key = (severity, title, content, action)
        if key == self._bar_key:
            return
        self._bar_key = key
        if self.bar is not None:
            self.bar.hide()
            self.bar.deleteLater()
            self.bar = None
        if severity is None:
            return
        self.bar = InfoBar(BAR_ICONS[severity], title, content, Qt.Horizontal, isClosable=False,
                           duration=-1, position=InfoBarPosition.NONE, parent=self.view)
        if action:
            button = PushButton(action)
            button.clicked.connect(on_action)
            self.bar.addWidget(button)
        self.bar_box.addWidget(self.bar)

    def refresh(self):
        if not self.isVisible():
            return
        app, today = self.app, dt.date.today()
        ledger = app.ledger
        settings_plan = ledger.plan
        floor = settings_plan.min_balance
        plan = ledger.month_plan(today.year, today.month, today)
        month = MONTHS[today.month - 1]
        self.date.setText(f"{WEEKDAY[today.weekday()]} · {fmt_date(today)}")
        now = ledger.days(today, today)[today]
        low_day, low = ledger.lowest(today + DAY, today + dt.timedelta(days=LOOKAHEAD))

        # the bar: setup first, then a warning about the balance ahead, then missing income
        below = "your minimum of " + money.fmt(floor) if floor else "zero"
        if settings_plan.start_date is None:
            self._show_bar("info", "Add your current balance",
                           "Kaiji works out every day's balance from it, so the calendar can show "
                           "what you'll have on any day.", "Set up", self.window.welcome)
        elif min(low, now.balance) < floor:
            day, value = (low_day, low) if low < now.balance else (today, now.balance)
            self._show_bar("warning", f"Your balance drops to {money.fmt(value)} on {fmt_short(day)}",
                           f"That's below {below}.", "Show in calendar",
                           lambda: self.window.show_day(day))
        elif plan.basis == "income" and plan.income == 0:
            self._show_bar("info", f"No income in {month} yet",
                           "Left to spend comes from this month's income. Add your pay as a "
                           "repeating entry, or plan by your balance in Settings.", "Add income",
                           lambda: self.window.add_entry(today, "income"))
        else:
            self._show_bar()

        # hero
        left = plan.left
        used = plan.expense / (plan.expense + max(left, 0)) if plan.expense + max(left, 0) else 0
        severity = "critical" if left < 0 else "caution" if used >= 0.9 else None
        self.ring.set_state(1.0 if left < 0 else used, severity,
                            f"{min(used, 1):.0%}" if left >= 0 else "Over",
                            "used" if left >= 0 else "budget")
        tone(self.big)
        if not plan.income and not plan.expense and left == 0:
            self.eyebrow.setText(f"Left to spend in {month}")
            self.big.setText(money.fmt(0))
            self.sub.setText("Add what comes in and goes out this month, and Kaiji works out what "
                             "you can spend")
        elif left > 0:
            self.eyebrow.setText(f"Left to spend in {month}")
            self.big.setText(money.fmt(left))
            self.sub.setText(f"About {money.fmt(plan.per_day)} a day for the {plan.days_left} "
                             "days left" if plan.days_left > 1 else "Today is the last day of the month")
        elif plan.basis == "income" and plan.budget_room <= plan.cash_room:
            self.eyebrow.setText(f"Over budget in {month}" if left < 0
                                 else f"Nothing left to spend in {month}")
            self.big.setText(money.fmt(left))
            tone(self.big, "critical" if left < 0 else None)
            goal = " and your savings goal" if plan.goal else ""
            self.sub.setText(f"Expenses are {money.fmt(-left)} more than {month}'s income{goal} "
                             "allow" if left < 0 else f"Expenses use up {month}'s income{goal}")
        else:
            self.eyebrow.setText(f"Nothing left to spend in {month}")
            self.big.setText(money.fmt(0))
            self.sub.setText(f"Your balance is heading for {money.fmt(plan.lowest)} on "
                             f"{fmt_short(plan.lowest_day)}, below {below}")

        counted = []
        if plan.planned_expense:
            counted.append(f"{money.fmt(plan.planned_expense)} still to pay")
        if plan.goal and plan.basis == "income":
            counted.append(f"{money.fmt(plan.goal)} for savings")
        detail = f"Already counts {' and '.join(counted)}." if counted else ""
        if left > 0 and plan.limited_by_balance:
            detail = (f"Kept down so your balance stays above {below} on "
                      f"{fmt_short(plan.lowest_day)}. " + detail)
        if left > 0 and plan.limited_by_balance:
            tone(self.detail, "caution")
        else:
            tertiary(self.detail)
        self.detail.setText(detail)
        self.detail.setVisible(bool(detail))

        # cards
        start = settings_plan.start_date
        self.balance.set(money.fmt(now.balance),
                         f"Counting from {money.fmt(settings_plan.start_balance)} on {fmt_date(start)}"
                         if start else "No starting balance yet",
                         "critical" if now.balance < floor else None)
        self.month_end.caption.setText(f"End of {month}")
        self.month_end.set("≈ " + money.fmt(plan.closing),
                           f"{money.fmt(plan.closing - now.balance, sign=True)} from today")
        self.lowest.set(money.fmt(low), f"{WEEKDAY_SHORT[low_day.weekday()]}, {fmt_short(low_day)}"
                        + (f" · below {below}" if low < floor else ""),
                        "critical" if low < floor else None)
        count = sum(1 for i in now.items if i.kind == "expense")
        self.spent.set(money.fmt(now.expense), f"{count} {'expense' if count == 1 else 'expenses'}"
                       if count else "Nothing spent yet")

        # coming up and the forecast
        rows = ledger.upcoming(today, UPCOMING_DAYS)
        shown = rows[:UPCOMING_ROWS]
        self.upcoming.set_items(app, [i for i, _ in shown], today, dated=True,
                                balances=[b for _, b in shown])
        more = len(rows) - len(shown)
        self.more.setText(f"…and {more} more in the calendar" if more > 0 else "")
        self.more.setVisible(more > 0)
        days = ledger.days(today - dt.timedelta(days=FORECAST_BACK),
                           today + dt.timedelta(days=FORECAST_AHEAD))
        self.forecast.set_data(list(days.values()), today, floor)
