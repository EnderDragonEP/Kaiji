"""The money logic behind every page: the dates repeating entries fall on, the balance day by
day, the month plan ("left to spend") and the totals for Statistics. Plain Python over Store.

Balances: the balance at the end of a day is the starting balance plus everything dated from
the starting date up to that day (minus everything between the day and the starting date for
days before it). Days after today are projected from what's planned.

Left to spend (planning by income): this month's income - its expenses (recorded and planned)
- the savings goal, but never more than would push the balance below the minimum on any day
from today to the month's end. Planning by balance: only the second part counts."""
import dataclasses
import datetime as dt
from collections import defaultdict

DAY = dt.timedelta(days=1)
WEEKDAY = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
WEEKDAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December"]
MONTHS_SHORT = [m[:3] for m in MONTHS]
FREQ_UNITS = {"day": ("day", "days"), "week": ("week", "weeks"), "month": ("month", "months"),
              "year": ("year", "years")}
PER_MONTH = {"day": 365.25 / 12, "week": 365.25 / 12 / 7, "month": 1, "year": 1 / 12}


def month_bounds(year, month):
    start = dt.date(year, month, 1)
    end = (start + dt.timedelta(days=32)).replace(day=1) - DAY
    return start, end


def add_months(day, months):
    """Same day `months` later; the 29th-31st become the last day of shorter months."""
    index = day.year * 12 + day.month - 1 + months
    year, month = divmod(index, 12)
    return dt.date(year, month + 1, min(day.day, month_bounds(year, month + 1)[1].day))


def day_range(start, end):
    d = start
    while d <= end:
        yield d
        d += DAY


def fmt_date(day):
    return f"{day:%Y/%m/%d}"


def fmt_short(day):
    return f"{MONTHS_SHORT[day.month - 1]} {day.day}"


def fmt_long(day):
    return f"{WEEKDAY[day.weekday()]}, {day:%Y/%m/%d}"


def ordinal(n):
    suffix = "th" if 11 <= n % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def _step(rule):
    """(True, days) between the dates of daily and weekly rules, (False, months) for the rest."""
    every = max(1, rule.every)
    if rule.freq in ("day", "week"):
        return True, every * (7 if rule.freq == "week" else 1)
    return False, every * (12 if rule.freq == "year" else 1)


def nth_date(rule, n):
    """The rule's date number n, from 0 at its start; skipped dates count too."""
    in_days, step = _step(rule)
    if in_days:
        return rule.start + dt.timedelta(days=n * step)
    return add_months(rule.start, n * step)


def date_number(rule, day):
    """Which of the rule's dates day is, from 1 at its start; skipped dates count too."""
    in_days, step = _step(rule)
    if in_days:
        return (day - rule.start).days // step + 1
    return ((day.year - rule.start.year) * 12 + day.month - rule.start.month) // step + 1


def times_before(rule, day):
    """How many of the rule's dates come before day; skipped dates count too."""
    if day <= rule.start:
        return 0
    n = date_number(rule, day)
    return n if nth_date(rule, n - 1) < day else n - 1


def last_date(rule):
    """The last date the rule can fall on - its end date or its last time, whichever comes
    first - or None when it doesn't end. Skipping a date doesn't add one at the end."""
    ends = [d for d in (rule.until, nth_date(rule, rule.times - 1) if rule.times else None) if d]
    return min(ends) if ends else None


def occurrences(rule, start, end):
    """Dates in [start, end] the rule falls on, skipped dates left out. Monthly rules from the
    29th-31st fall on the last day of shorter months, yearly ones from Feb 29 on Feb 28."""
    lo = max(start, rule.start)
    last = last_date(rule)
    hi = min(end, last) if last else end
    if lo > hi:
        return []
    in_days, step = _step(rule)
    out = []
    if in_days:
        offset = (lo - rule.start).days
        d = rule.start + dt.timedelta(days=-(-offset // step) * step)
        while d <= hi:
            out.append(d)
            d += dt.timedelta(days=step)
    else:
        n = ((lo.year - rule.start.year) * 12 + lo.month - rule.start.month) // step
        while True:
            # always from the start date, so Jan 31 -> Feb 28 -> Mar 31 doesn't drift
            d = add_months(rule.start, n * step)
            if d > hi:
                break
            if d >= lo:
                out.append(d)
            n += 1
    return [d for d in out if d not in rule.skips] if rule.skips else out


def next_date(rule, today):
    """The first date on or after today the rule falls on; None once it has ended."""
    gap = {"day": 1, "week": 7, "month": 31, "year": 366}[rule.freq] * max(1, rule.every)
    begin = max(today, rule.start)
    # skipped dates can hide at most that many occurrences
    found = occurrences(rule, begin, begin + dt.timedelta(days=gap * (len(rule.skips) + 2)))
    return found[0] if found else None


def describe_rule(rule):
    """'Every month on the 5th', 'Every 2 weeks on Friday', 'Every year on Oct 12'."""
    unit = FREQ_UNITS[rule.freq]
    head = f"Every {unit[0]}" if rule.every <= 1 else f"Every {rule.every} {unit[1]}"
    s = rule.start
    if rule.freq == "week":
        return f"{head} on {WEEKDAY[s.weekday()]}"
    if rule.freq == "month":
        return f"{head} on the {ordinal(s.day)}"
    if rule.freq == "year":
        return f"{head} on {fmt_short(s)}"
    return head


def describe_end(rule):
    """'No end date', '2027/09/05', or 'After 12 times · 2027/09/05'."""
    last = last_date(rule)
    if last is None:
        return "No end date"
    if rule.times and last == nth_date(rule, rule.times - 1):
        return f"After {rule.times} {'time' if rule.times == 1 else 'times'} · {fmt_date(last)}"
    return fmt_date(last)


def per_month(rule):
    """The rule's amount averaged per month (a weekly NT$100 is about NT$435 a month)."""
    return round(rule.amount * PER_MONTH[rule.freq] / max(1, rule.every))


@dataclasses.dataclass
class Item:
    """One amount on the calendar: an entry, or a date a repeating entry falls on."""
    day: dt.date
    kind: str
    amount: int
    category_id: int
    note: str
    entry_id: int = None
    rule_id: int = None

    @property
    def signed(self):
        return self.amount if self.kind == "income" else -self.amount

    @property
    def repeating(self):
        return self.rule_id is not None


@dataclasses.dataclass
class Day:
    day: dt.date
    items: list
    income: int = 0
    expense: int = 0
    balance: int = 0              # at the end of the day


@dataclasses.dataclass
class MonthPlan:
    start: dt.date
    end: dt.date
    status: str                   # "past", "current" or "future"
    income: int                   # everything dated in the month, recorded and planned
    expense: int
    planned_income: int           # the part dated after today
    planned_expense: int
    opening: int                  # balance at the start of the month
    closing: int                  # balance at its end (projected unless it's over)
    lowest: int                   # lowest end-of-day balance from today (or the 1st) on
    lowest_day: dt.date
    goal: int                     # savings goal
    floor: int                    # minimum balance
    basis: str                    # "income" or "balance"
    budget_room: int              # income - expenses - savings goal
    cash_room: int                # lowest balance - minimum balance
    days_left: int                # today included; 0 for past months

    @property
    def left(self):
        """Left to spend in the rest of the month; negative when the plan is overspent."""
        if self.basis == "balance":
            return self.cash_room
        return min(self.budget_room, self.cash_room)

    @property
    def limited_by_balance(self):
        return self.basis == "income" and self.cash_room < self.budget_room

    @property
    def per_day(self):
        return self.left // self.days_left if self.left > 0 and self.days_left else 0

    @property
    def spent(self):
        """Expenses recorded up to today."""
        return self.expense - self.planned_expense

    @property
    def net(self):
        return self.income - self.expense


class Ledger:
    def __init__(self, store):
        self.store = store
        self._rules = self._plan = None

    def invalidate(self):
        """Forget cached rules and plan after the data changed."""
        self._rules = self._plan = None

    @property
    def rules(self):
        if self._rules is None:
            self._rules = self.store.rules()
        return self._rules

    @property
    def plan(self):
        if self._plan is None:
            self._plan = self.store.plan()
        return self._plan

    def items(self, start, end):
        """Entries and repeating dates in [start, end]: by day, income first, larger first."""
        out = [Item(e.day, e.kind, e.amount, e.category_id, e.note, entry_id=e.id)
               for e in self.store.entries(start, end)]
        for r in self.rules:
            out += [Item(d, r.kind, r.amount, r.category_id, r.note, rule_id=r.id)
                    for d in occurrences(r, start, end)]
        out.sort(key=lambda i: (i.day, i.kind != "income", -i.amount))
        return out

    def _net_until(self, day):
        """Income minus expenses of everything dated on or before day."""
        total = self.store.entry_net(day)
        for r in self.rules:
            if r.start <= day:
                count = len(occurrences(r, r.start, day))
                total += count * (r.amount if r.kind == "income" else -r.amount)
        return total

    def balance_before(self, day):
        """The balance at the start of day."""
        plan = self.plan
        balance = plan.start_balance + self._net_until(day - DAY)
        if plan.start_date:
            balance -= self._net_until(plan.start_date - DAY)
        return balance

    def days(self, start, end):
        """{date: Day} for every day in [start, end], with end-of-day balances."""
        balance = self.balance_before(start)
        by_day = defaultdict(list)
        for item in self.items(start, end):
            by_day[item.day].append(item)
        out = {}
        for d in day_range(start, end):
            items = by_day.get(d, [])
            income = sum(i.amount for i in items if i.kind == "income")
            expense = sum(i.amount for i in items if i.kind != "income")
            balance += income - expense
            out[d] = Day(d, items, income, expense, balance)
        return out

    def month_plan(self, year, month, today):
        start, end = month_bounds(year, month)
        days = list(self.days(start, end).values())
        plan = self.plan
        status = "past" if end < today else "future" if start > today else "current"
        first = today if status == "current" else start
        later = [d for d in days if d.day > today]
        low = min((d for d in days if d.day >= first), key=lambda d: (d.balance, d.day))
        income = sum(d.income for d in days)
        expense = sum(d.expense for d in days)
        return MonthPlan(
            start=start, end=end, status=status, income=income, expense=expense,
            planned_income=sum(d.income for d in later),
            planned_expense=sum(d.expense for d in later),
            opening=days[0].balance - days[0].income + days[0].expense,
            closing=days[-1].balance, lowest=low.balance, lowest_day=low.day,
            goal=plan.savings_goal, floor=plan.min_balance, basis=plan.basis,
            budget_room=income - expense - plan.savings_goal,
            cash_room=low.balance - plan.min_balance,
            days_left=0 if status == "past" else (end - first).days + 1)

    def upcoming(self, today, days=30):
        """[(item, balance after it)] for everything planned in the next `days` days."""
        start = today + DAY
        balance = self.balance_before(start)
        out = []
        for item in self.items(start, today + dt.timedelta(days=days)):
            balance += item.signed
            out.append((item, balance))
        return out

    def lowest(self, start, end):
        """(day, balance): the lowest end-of-day balance in [start, end], the earliest if tied."""
        low = min(self.days(start, end).values(), key=lambda d: (d.balance, d.day))
        return low.day, low.balance


def totals_by_category(items, kind):
    """[(category_id, total, count)] of the items of one kind, largest first."""
    totals = defaultdict(lambda: [0, 0])
    for i in items:
        if i.kind == kind:
            t = totals[i.category_id]
            t[0] += i.amount
            t[1] += 1
    return sorted(((c, t, n) for c, (t, n) in totals.items()), key=lambda r: -r[1])


def totals_by_month(items, start, end):
    """[(first day of the month, income, expense)] for every month touching [start, end]."""
    months = []
    d = start.replace(day=1)
    while d <= end:
        months.append(d)
        d = add_months(d, 1)
    sums = {m: [0, 0] for m in months}
    for i in items:
        sums[i.day.replace(day=1)][0 if i.kind == "income" else 1] += i.amount
    return [(m, *sums[m]) for m in months]
