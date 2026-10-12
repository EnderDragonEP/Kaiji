"""Tests for the money logic: python -m unittest discover tests"""
import datetime as dt
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from kaiji_app import money, store as store_module  # noqa: E402
from kaiji_app.ledger import (  # noqa: E402
    Ledger, date_number, describe_end, describe_rule, last_date, next_date, occurrences, per_month,
    times_before, totals_by_category, totals_by_month,
)
from kaiji_app.store import Plan, Rule, Store  # noqa: E402

D = dt.date


def rule(freq, start, every=1, until=None, skips=(), amount=100, kind="expense", times=None):
    return Rule(1, kind, amount, None, "", freq, every, start, until, times, set(skips))


class Occurrences(unittest.TestCase):
    def test_monthly_on_the_31st(self):
        r = rule("month", D(2026, 1, 31))
        self.assertEqual(occurrences(r, D(2026, 1, 1), D(2026, 5, 31)),
                         [D(2026, 1, 31), D(2026, 2, 28), D(2026, 3, 31), D(2026, 4, 30),
                          D(2026, 5, 31)])

    def test_yearly_on_feb_29(self):
        r = rule("year", D(2024, 2, 29))
        self.assertEqual(occurrences(r, D(2024, 1, 1), D(2028, 12, 31)),
                         [D(2024, 2, 29), D(2025, 2, 28), D(2026, 2, 28), D(2027, 2, 28),
                          D(2028, 2, 29)])

    def test_every_two_weeks_inside_a_window(self):
        r = rule("week", D(2026, 1, 2), every=2)          # a Friday
        self.assertEqual(occurrences(r, D(2026, 1, 10), D(2026, 2, 13)),
                         [D(2026, 1, 16), D(2026, 1, 30), D(2026, 2, 13)])

    def test_quarterly_window_starting_between_dates(self):
        r = rule("month", D(2026, 1, 31), every=3)
        self.assertEqual(occurrences(r, D(2026, 3, 15), D(2026, 12, 31)),
                         [D(2026, 4, 30), D(2026, 7, 31), D(2026, 10, 31)])

    def test_until_and_skips(self):
        r = rule("day", D(2026, 3, 1), every=3, until=D(2026, 3, 13), skips={D(2026, 3, 7)})
        self.assertEqual(occurrences(r, D(2026, 1, 1), D(2026, 12, 31)),
                         [D(2026, 3, 1), D(2026, 3, 4), D(2026, 3, 10), D(2026, 3, 13)])

    def test_before_start(self):
        self.assertEqual(occurrences(rule("month", D(2026, 6, 1)), D(2026, 1, 1), D(2026, 5, 31)), [])

    def test_next_date(self):
        r = rule("year", D(2020, 10, 1))
        self.assertEqual(next_date(r, D(2026, 10, 2)), D(2027, 10, 1))
        r = rule("month", D(2026, 1, 5), skips={D(2026, 11, 5), D(2026, 12, 5)})
        self.assertEqual(next_date(r, D(2026, 10, 12)), D(2027, 1, 5))
        self.assertIsNone(next_date(rule("month", D(2026, 1, 5), until=D(2026, 6, 30)), D(2026, 7, 1)))
        self.assertEqual(next_date(rule("month", D(2029, 1, 5)), D(2026, 7, 1)), D(2029, 1, 5))

    def test_times(self):
        r = rule("month", D(2026, 1, 31), times=3)
        self.assertEqual(occurrences(r, D(2025, 1, 1), D(2027, 12, 31)),
                         [D(2026, 1, 31), D(2026, 2, 28), D(2026, 3, 31)])
        self.assertEqual(last_date(r), D(2026, 3, 31))
        self.assertEqual(occurrences(r, D(2026, 3, 1), D(2026, 12, 31)), [D(2026, 3, 31)])

    def test_skipped_dates_still_count(self):
        r = rule("week", D(2026, 1, 2), times=4, skips={D(2026, 1, 9)})
        self.assertEqual(occurrences(r, D(2026, 1, 1), D(2026, 12, 31)),
                         [D(2026, 1, 2), D(2026, 1, 16), D(2026, 1, 23)])

    def test_earlier_end_wins(self):
        r = rule("day", D(2026, 3, 1), times=10, until=D(2026, 3, 4))
        self.assertEqual(len(occurrences(r, D(2026, 1, 1), D(2026, 12, 31))), 4)
        self.assertEqual(describe_end(r), "2026/03/04")
        r = rule("day", D(2026, 3, 1), times=2, until=D(2026, 3, 4))
        self.assertEqual(last_date(r), D(2026, 3, 2))

    def test_times_before(self):
        r = rule("month", D(2026, 1, 10))
        cases = {D(2026, 1, 10): 0, D(2026, 3, 5): 2, D(2026, 3, 10): 2, D(2026, 3, 11): 3}
        for day, count in cases.items():
            self.assertEqual(times_before(r, day), count, day)
        self.assertEqual(times_before(rule("week", D(2026, 1, 2)), D(2026, 1, 17)), 3)

    def test_date_number_and_end_text(self):
        r = rule("month", D(2026, 1, 31), every=2, times=6)
        self.assertEqual(date_number(r, D(2026, 3, 31)), 2)
        self.assertEqual(date_number(r, D(2026, 11, 30)), 6)
        self.assertEqual(describe_end(r), "After 6 times · 2026/11/30")
        self.assertIsNone(next_date(r, D(2026, 12, 1)))
        self.assertEqual(next_date(r, D(2026, 10, 1)), D(2026, 11, 30))
        self.assertEqual(describe_end(rule("week", D(2026, 1, 2), times=1)), "After 1 time · 2026/01/02")
        self.assertEqual(describe_end(rule("month", D(2026, 1, 1))), "No end date")
        self.assertEqual(date_number(rule("week", D(2026, 1, 2), every=2), D(2026, 1, 30)), 3)

    def test_describe_and_per_month(self):
        self.assertEqual(describe_rule(rule("month", D(2026, 1, 5))), "Every month on the 5th")
        self.assertEqual(describe_rule(rule("week", D(2026, 1, 2), every=2)), "Every 2 weeks on Friday")
        self.assertEqual(describe_rule(rule("year", D(2026, 10, 12))), "Every year on Oct 12")
        self.assertEqual(describe_rule(rule("day", D(2026, 1, 1))), "Every day")
        self.assertEqual(per_month(rule("week", D(2026, 1, 1), amount=10000)), 43482)
        self.assertEqual(per_month(rule("year", D(2026, 1, 1), amount=120000)), 10000)


class Balances(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:", ("NT$", 0))
        self.ledger = Ledger(self.store)
        cats = {(c.kind, c.name): c.id for c in self.store.categories()}
        self.food, self.rent = cats["expense", "Food"], cats["expense", "Housing"]
        self.salary = cats["income", "Salary"]

    def plan(self, **kw):
        self.store.set_plan(Plan(**kw))
        self.ledger.invalidate()

    def test_without_starting_balance(self):
        self.store.add_entry(D(2026, 10, 3), "expense", 5000, self.food)
        self.store.add_entry(D(2026, 10, 5), "income", 100000, self.salary)
        days = self.ledger.days(D(2026, 10, 1), D(2026, 10, 6))
        self.assertEqual([d.balance for d in days.values()], [0, 0, -5000, -5000, 95000, 95000])

    def test_starting_balance_before_and_after(self):
        self.plan(start_balance=1_000_000, start_date=D(2026, 10, 10))
        self.store.add_entry(D(2026, 10, 5), "expense", 20000, self.food)
        self.store.add_entry(D(2026, 10, 10), "expense", 30000, self.food)
        self.store.add_entry(D(2026, 10, 12), "income", 50000, self.salary)
        self.assertEqual(self.ledger.balance_before(D(2026, 10, 10)), 1_000_000)
        self.assertEqual(self.ledger.balance_before(D(2026, 10, 11)), 970_000)
        self.assertEqual(self.ledger.balance_before(D(2026, 10, 13)), 1_020_000)
        # before the starting date it's worked out backwards
        self.assertEqual(self.ledger.balance_before(D(2026, 10, 5)), 1_020_000)
        self.assertEqual(self.ledger.balance_before(D(2026, 10, 6)), 1_000_000)

    def test_repeating_entries_count_in_balances(self):
        self.plan(start_balance=0, start_date=D(2026, 1, 1))
        self.store.add_rule("income", 100000, self.salary, "Salary", "month", 1, D(2025, 6, 5))
        self.store.add_rule("expense", 1000, self.food, "", "day", 1, D(2026, 1, 1))
        self.ledger.invalidate()
        # Jan 1-31: one salary (Jan 5) and 31 days of food
        self.assertEqual(self.ledger.balance_before(D(2026, 2, 1)), 100000 - 31 * 1000)

    def scenario(self, today_spent=800_000, **plan):
        """Oct 2026: 30,000 at the start, rent 15,000 on the 1st, salary 50,000 on the 5th,
        phone 500 on the 15th, today (the 12th) 8,000 spent so far."""
        self.plan(start_balance=3_000_000, start_date=D(2026, 10, 1), **plan)
        self.store.add_rule("expense", 1_500_000, self.rent, "Rent", "month", 1, D(2026, 1, 1))
        self.store.add_rule("income", 5_000_000, self.salary, "Salary", "month", 1, D(2026, 1, 5))
        self.store.add_entry(D(2026, 10, 15), "expense", 50000, self.food, "Phone")
        self.store.add_entry(D(2026, 10, 12), "expense", today_spent, self.food)
        self.ledger.invalidate()
        return self.ledger.month_plan(2026, 10, D(2026, 10, 12))

    def test_month_plan_by_income(self):
        p = self.scenario(savings_goal=1_000_000)
        self.assertEqual((p.status, p.income, p.expense), ("current", 5_000_000, 2_350_000))
        self.assertEqual((p.planned_income, p.planned_expense, p.spent), (0, 50000, 2_300_000))
        self.assertEqual((p.opening, p.closing), (3_000_000, 5_650_000))
        self.assertEqual((p.lowest, p.lowest_day), (5_650_000, D(2026, 10, 15)))
        self.assertEqual(p.left, 1_650_000)              # 50,000 - 23,500 - 10,000
        self.assertFalse(p.limited_by_balance)
        self.assertEqual((p.days_left, p.per_day), (20, 82500))

    def test_month_plan_capped_by_balance(self):
        p = self.scenario(min_balance=5_000_000)
        self.assertEqual(p.left, 650_000)                # lowest 56,500 - minimum 50,000
        self.assertTrue(p.limited_by_balance)

    def test_month_plan_by_balance(self):
        p = self.scenario(basis="balance", savings_goal=1_000_000)
        self.assertEqual(p.left, 5_650_000)

    def test_overspent(self):
        p = self.scenario(today_spent=4_000_000)
        self.assertEqual(p.left, -550_000)
        self.assertEqual(p.per_day, 0)

    def test_past_and_future_months(self):
        self.scenario()
        past = self.ledger.month_plan(2026, 9, D(2026, 10, 12))
        future = self.ledger.month_plan(2026, 11, D(2026, 10, 12))
        self.assertEqual((past.status, past.days_left), ("past", 0))
        self.assertEqual((future.status, future.days_left, future.left), ("future", 30, 3_500_000))

    def test_upcoming_and_lowest(self):
        self.scenario()
        up = self.ledger.upcoming(D(2026, 10, 12), days=30)
        self.assertEqual([(i.day, i.signed, b) for i, b in up],
                         [(D(2026, 10, 15), -50000, 5_650_000),
                          (D(2026, 11, 1), -1_500_000, 4_150_000),
                          (D(2026, 11, 5), 5_000_000, 9_150_000)])
        self.assertEqual(self.ledger.lowest(D(2026, 10, 13), D(2026, 11, 30)),
                         (D(2026, 11, 1), 4_150_000))

    def test_totals(self):
        self.scenario()
        items = self.ledger.items(D(2026, 9, 1), D(2026, 10, 31))
        self.assertEqual(totals_by_category(items, "expense"),
                         [(self.rent, 3_000_000, 2), (self.food, 850_000, 2)])
        self.assertEqual(totals_by_month(items, D(2026, 9, 15), D(2026, 10, 31)),
                         [(D(2026, 9, 1), 5_000_000, 1_500_000),
                          (D(2026, 10, 1), 5_000_000, 2_350_000)])

    def test_skip_and_categories(self):
        self.scenario()
        rent = next(r for r in self.store.rules() if r.note == "Rent")
        self.store.skip(rent.id, D(2026, 11, 1))
        self.ledger.invalidate()
        self.assertEqual(self.ledger.month_plan(2026, 11, D(2026, 10, 12)).expense, 0)
        self.store.delete_category(self.rent, move_to=self.food)
        self.assertEqual(self.store.rule(rent.id).category_id, self.food)

    def test_repeat_times_in_balances(self):
        rid = self.store.add_rule("expense", 300_000, self.food, "Phone in 12 payments", "month", 1,
                                  D(2026, 1, 10), times=12)
        self.ledger.invalidate()
        self.assertEqual(self.store.rule(rid).times, 12)
        spent = self.ledger.balance_before(D(2027, 6, 1)) - self.ledger.balance_before(D(2026, 1, 1))
        self.assertEqual(spent, -12 * 300_000)
        self.store.update_rule(rid, "expense", 300_000, self.food, "", "month", 1, D(2026, 1, 10),
                               times=None)
        self.assertIsNone(self.store.rule(rid).times)

    def test_backup_and_restore(self):
        self.scenario()
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "copy.db")
            self.store.backup_to(path)
            self.store.add_entry(D(2026, 10, 20), "expense", 1, self.food)
            self.store.restore_from(path)
            self.assertEqual(len(self.store.entries()), 2)
            bad = os.path.join(folder, "bad.db")
            with open(bad, "w") as f:
                f.write("not a database")
            with self.assertRaises(ValueError):
                self.store.restore_from(bad)


class Migration(unittest.TestCase):
    def test_database_from_before_repeat_times(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "old.db")
            old = sqlite3.connect(path)
            old.executescript(store_module.SCHEMA.replace(", times INTEGER", ""))
            old.execute("INSERT INTO rules (kind, amount, category_id, note, freq, every, start) "
                        "VALUES ('income', 100, NULL, 'Salary', 'month', 1, '2026-01-05')")
            old.commit()
            old.close()
            store = Store(path)
            try:
                self.assertIsNone(store.rules()[0].times)
                rid = store.add_rule("expense", 5, None, "", "week", 1, D(2026, 1, 1), times=3)
                self.assertEqual(store.rule(rid).times, 3)
            finally:
                store.db.close()


class Money(unittest.TestCase):
    def tearDown(self):
        money.configure("$", 2)

    def test_parse(self):
        money.configure("NT$", 0)
        cases = {"1,234.5": 123450, "120+35": 15500, "3萬": 3000000, "1.5k": 150000,
                 "NT$ 1,200": 120000, "１２３": 12300, "(100+50)*2": 30000, "10/4": 250,
                 "3 x 45": 13500, "2千5": None}
        for text, cents in cases.items():
            if cents is None:
                with self.assertRaises(ValueError):
                    money.parse(text)
            else:
                self.assertEqual(money.parse(text), cents, text)
        for bad in ["", "abc", "0", "-5", "1/0", "2**10", "1e5", "5-", "9" * 20]:
            with self.assertRaises(ValueError, msg=bad):
                money.parse(bad)
        self.assertEqual(money.parse("-500", allow_negative=True), -50000)
        self.assertTrue(money.is_expression("120 + 35"))
        self.assertFalse(money.is_expression("-120"))

    def test_format(self):
        money.configure("NT$", 0)
        self.assertEqual(money.fmt(123450), "NT$1,235")
        self.assertEqual(money.fmt(-123450), "−NT$1,235")
        self.assertEqual(money.fmt(50, sign=True), "+NT$1")
        self.assertEqual(money.fmt(-40), "NT$0")
        self.assertEqual(money.edit_text(123450), "1,234.50")
        self.assertEqual(money.edit_text(123400), "1,234")
        self.assertEqual(money.plain(-123450), "-1235")
        money.configure("$", 2)
        self.assertEqual(money.fmt(123456, symbol=False), "1,234.56")
        self.assertEqual(money.plain(5), "0.05")

    def test_compact(self):
        self.assertEqual(money.compact(1_234_500), "12.3K")
        self.assertEqual(money.compact(99_995_000), "1M")
        self.assertEqual(money.compact(123_456_789), "1.23M")
        self.assertEqual(money.compact(50_000), "500")
        self.assertEqual(money.compact(-250_000, symbol=True), "−$2.5K")
        self.assertEqual(money.compact(1234), "12.34")
        cases = {1_000_000: "10K", 10_000_000: "100K", 20_000_000: "200K", 150_000_000: "1.5M",
                 2_000_000_000: "20M", 10_000: "100", 0: "0"}
        for cents, text in cases.items():
            self.assertEqual(money.compact(cents), text, cents)


if __name__ == "__main__":
    unittest.main()
