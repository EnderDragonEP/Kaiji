"""Tests for the Cashew import and export: python -m unittest discover tests"""
import csv
import datetime as dt
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from kaiji_app import cashew, money  # noqa: E402
from kaiji_app.ledger import Ledger  # noqa: E402
from kaiji_app.store import Store  # noqa: E402

D = dt.date
TODAY = D(2026, 10, 27)

# the three tables Kaiji reads, with the columns of Cashew's schema 46 (drift_schemas/)
CASHEW_SCHEMA = """
CREATE TABLE wallets (wallet_pk TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, colour TEXT,
    icon_name TEXT, date_created INTEGER NOT NULL, date_time_modified INTEGER,
    "order" INTEGER NOT NULL, currency TEXT, currency_format TEXT,
    decimals INTEGER NOT NULL DEFAULT 2, home_page_widget_display TEXT);
CREATE TABLE categories (category_pk TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, colour TEXT,
    icon_name TEXT, emoji_icon_name TEXT, date_created INTEGER NOT NULL,
    date_time_modified INTEGER, "order" INTEGER NOT NULL, income INTEGER NOT NULL DEFAULT 0,
    method_added INTEGER, main_category_pk TEXT);
CREATE TABLE transactions (transaction_pk TEXT NOT NULL PRIMARY KEY, paired_transaction_fk TEXT,
    name TEXT NOT NULL, amount REAL NOT NULL, note TEXT NOT NULL, category_fk TEXT NOT NULL,
    sub_category_fk TEXT, wallet_fk TEXT NOT NULL DEFAULT '0', date_created INTEGER NOT NULL,
    date_time_modified INTEGER, original_date_due INTEGER, income INTEGER NOT NULL DEFAULT 0,
    period_length INTEGER, reoccurrence INTEGER, end_date INTEGER,
    upcoming_transaction_notification INTEGER, type INTEGER, paid INTEGER NOT NULL DEFAULT 0,
    created_another_future_transaction INTEGER, skip_paid INTEGER NOT NULL DEFAULT 0,
    method_added INTEGER, transaction_owner_email TEXT, transaction_original_owner_email TEXT,
    shared_key TEXT, shared_old_key TEXT, shared_status INTEGER, shared_date_updated INTEGER,
    shared_reference_budget_pk TEXT, objective_fk TEXT, objective_loan_fk TEXT,
    budget_fks_exclude TEXT);
"""


def stamp(*args):
    """Unix seconds for a local date and time, as drift stores it."""
    return int(dt.datetime(*args).timestamp())


def tx(pk, wallet, amount, category, when, name="", note="", sub=None, type=None, paid=1, skip=0,
       reoccurrence=None, period=None, end=None, paired=None):
    return (pk, wallet, amount, category, sub, name, note, stamp(*when), type, paid, skip,
            reoccurrence, period, stamp(*end) if end else None, paired)


TRANSACTIONS = [
    tx("t1", "0", -120.5, "1", (2026, 10, 1, 12), "Latte", "with Amy", sub="s1"),
    tx("t2", "0", 52000.0, "11", (2026, 10, 5, 9), "Salary"),
    # a transfer from Main to Savings, paired; then an older one, unpaired, in the same minute
    tx("t3", "0", -1000.0, "0", (2026, 10, 6, 10, 0, 30), paired="t4"),
    tx("t4", "w2", 1000.0, "0", (2026, 10, 6, 10, 0, 31), paired="t3"),
    tx("t5", "0", -500.0, "0", (2026, 10, 7, 8, 15, 30)),
    tx("t6", "w2", 500.0, "0", (2026, 10, 7, 8, 15, 31)),
    tx("t7", "0", 30000.0, "0", (2026, 9, 1, 0, 0, 31)),                   # the starting balance
    tx("t8", "0", -390.0, "1", (2026, 11, 9, 8), "Netflix", type=1, paid=0, reoccurrence=3, period=1),
    tx("t9", "0", -16500.0, "2", (2026, 9, 1, 8), "Rent", type=2, paid=0, reoccurrence=3, period=1,
       end=(2027, 8, 31)),
    tx("t10", "0", -5000.0, "1", (2026, 12, 1, 8), "Flight", type=0, paid=0),
    tx("t11", "0", -300.0, "1", (2026, 10, 2, 8), "Overdue", type=0, paid=0),
    tx("t12", "0", -2000.0, "1", (2026, 10, 10, 8), "Lent to Bob", type=3),
    tx("t13", "0", -800.0, "1", (2026, 9, 10, 8), "Paid back", type=3, paid=0),
    tx("t14", "0", -99.0, "1", (2026, 11, 2, 8), "Skipped", type=1, paid=0, skip=1, reoccurrence=3,
       period=1),
    tx("t15", "w3", -10.25, "1", (2026, 10, 3, 8), "Burger"),
    tx("t16", "0", 0.0, "1", (2026, 10, 4, 8), "Nothing"),
]


def make_backup(path):
    db = sqlite3.connect(path)
    db.executescript(CASHEW_SCHEMA)
    db.executemany('INSERT INTO wallets (wallet_pk, name, date_created, "order", currency, decimals) '
                   "VALUES (?, ?, 0, ?, ?, ?)",
                   [("0", "Main", 0, "twd", 0), ("w2", "Savings", 1, "twd", 0),
                    ("w3", "US card", 2, "usd", 2)])
    db.executemany('INSERT INTO categories (category_pk, name, icon_name, date_created, "order", '
                   "income, main_category_pk) VALUES (?, ?, ?, 0, 0, ?, ?)",
                   [("0", "Balance Correction", "charts.png", 0, None),
                    ("1", "Dining", "cutlery.png", 0, None),
                    ("2", "Bills & Fees", "bills.png", 0, None),
                    ("11", "Income", "coin.png", 1, None), ("s1", "Coffee", "coffee.png", 0, "1")])
    db.executemany(
        "INSERT INTO transactions (transaction_pk, wallet_fk, amount, category_fk, sub_category_fk, "
        "name, note, date_created, type, paid, skip_paid, reoccurrence, period_length, end_date, "
        "paired_transaction_fk) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", TRANSACTIONS)
    db.commit()
    db.close()


class Import(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.folder.name, "cashew-2026-10-27.sql")
        make_backup(self.path)
        self.backup = cashew.read_backup(self.path)

    def tearDown(self):
        self.folder.cleanup()

    def test_reads_accounts(self):
        self.assertEqual([(w.pk, w.name, w.currency, w.decimals, w.count) for w in self.backup.wallets],
                         [("0", "Main", "TWD", 0, 13), ("w2", "Savings", "TWD", 0, 2),
                          ("w3", "US card", "USD", 2, 1)])

    def test_plan_for_two_accounts(self):
        plan = cashew.plan_import(self.backup, ["0", "w2"], TODAY)
        self.assertEqual(
            [(d, k, c, cat, note) for d, k, c, cat, note, _ in plan.entries],
            [(D(2026, 9, 1), "income", 3_000_000, ("Balance Correction", "income", "EDIT"), ""),
             (D(2026, 10, 1), "expense", 12050, ("Dining", "expense", "CAFE"), "Latte · with Amy"),
             (D(2026, 10, 5), "income", 5_200_000, ("Income", "income", "CERTIFICATE"), "Salary"),
             (D(2026, 10, 10), "expense", 200_000, ("Dining", "expense", "CAFE"), "Lent to Bob"),
             (D(2026, 12, 1), "expense", 500_000, ("Dining", "expense", "CAFE"), "Flight")])
        self.assertEqual(
            [(k, c, cat[0], note, f, e, start, until, skips)
             for k, c, cat, note, f, e, start, until, skips, _ in plan.rules],
            [("expense", 1_650_000, "Bills & Fees", "Rent", "month", 1, D(2026, 9, 1), D(2027, 8, 31),
              [D(2026, 9, 1), D(2026, 10, 1)]),
             ("expense", 39000, "Dining", "Netflix", "month", 1, D(2026, 11, 9), None, [])])
        self.assertEqual(dict(plan.left_out), {"transfer": 4, "unpaid": 1, "settled loan": 1,
                                               "skipped": 1, "zero": 1})
        self.assertTrue(all(src.startswith("cashew:t") for *_, src in plan.entries))

    def test_transfer_to_an_account_left_out_counts(self):
        plan = cashew.plan_import(self.backup, ["0"], TODAY)
        corrections = [c for _, k, c, cat, *_ in plan.entries if cat[0] == "Balance Correction"]
        self.assertEqual(sorted(corrections), [50000, 100000, 3_000_000])
        self.assertNotIn("transfer", plan.left_out)

    def test_apply_and_import_again(self):
        store = Store(":memory:", ("NT$", 0))
        self.addCleanup(store.db.close)
        ledger = Ledger(store)
        food = next(c.id for c in store.categories() if c.name == "Food")
        store.add_entry(D(2026, 10, 20), "expense", 10000, food, "mine")
        plan = cashew.plan_import(self.backup, ["0", "w2"], TODAY)
        # Dining, Bills & Fees, Income and Balance Correction aren't Kaiji categories yet
        self.assertEqual(cashew.new_categories(store, plan), 4)
        cashew.apply(store, plan)
        self.assertEqual(store.imported_count("cashew"), (5, 2))
        names = [c.name for c in store.categories()]
        cashew.apply(store, cashew.plan_import(self.backup, ["0", "w2"], TODAY))
        self.assertEqual(store.imported_count("cashew"), (5, 2))      # replaced, not added twice
        self.assertEqual([c.name for c in store.categories()], names)
        self.assertEqual(len(store.entries()), 6)                     # Kaiji's own entry stays
        income = next(c for c in store.categories() if c.kind == "income" and c.name == "Income")
        self.assertEqual(income.icon, "CERTIFICATE")
        # Sept 1 + Oct 1 rent were unpaid in Cashew: skipped; Nov 1 counts
        ledger.invalidate()
        rent = next(r for r in store.rules() if r.note == "Rent")
        self.assertEqual(rent.skips, {D(2026, 9, 1), D(2026, 10, 1)})
        balance = ledger.balance_before(D(2026, 11, 2))
        self.assertEqual(balance, 3_000_000 - 12050 + 5_200_000 - 200_000 - 10000 - 1_650_000)

    def test_older_backup_without_new_columns(self):
        old = os.path.join(self.folder.name, "old.sql")
        schema = CASHEW_SCHEMA.split("CREATE TABLE transactions")[0] + (
            "CREATE TABLE transactions (transaction_pk TEXT PRIMARY KEY, name TEXT, amount REAL, "
            "note TEXT, category_fk TEXT, wallet_fk TEXT, date_created INTEGER, paid INTEGER, "
            "income INTEGER);")
        db = sqlite3.connect(old)
        db.executescript(schema)
        db.execute("INSERT INTO transactions VALUES ('x', 'Tea', -45, '', '1', '0', ?, 1, 0)",
                   (stamp(2026, 10, 1, 9),))
        db.commit()
        db.close()
        plan = cashew.plan_import(cashew.read_backup(old), ["0"], TODAY)
        self.assertEqual([(d, c, note) for d, _, c, _, note, _ in plan.entries],
                         [(D(2026, 10, 1), 4500, "Tea")])

    def test_not_a_cashew_file(self):
        kaiji = os.path.join(self.folder.name, "kaiji.db")
        Store(kaiji).db.close()      # Kaiji's own database isn't a Cashew backup
        junk = os.path.join(self.folder.name, "junk.sql")
        with open(junk, "w") as f:
            f.write("hello")
        for path in (kaiji, junk):
            with self.assertRaises(ValueError):
                cashew.read_backup(path)

    def test_icons(self):
        cases = {"cutlery.png": "CAFE", "groceries.png": "SHOPPING_CART", "tram.png": "BUS",
                 "credit-card.png": "TAG", "plane.png": "AIRPLANE", "bills.png": "DOCUMENT",
                 "image.png": "TAG", None: "TAG", "flowerPot.png": "CUT"}
        for name, icon in cases.items():
            self.assertEqual(cashew.kaiji_icon(name), icon, name)


class Export(unittest.TestCase):
    def test_csv_for_cashew(self):
        money.configure("NT$", 0)
        self.addCleanup(money.configure, "$", 2)
        store = Store(":memory:", ("NT$", 0))
        self.addCleanup(store.db.close)
        ledger = Ledger(store)
        cats = {c.name: c.id for c in store.categories()}
        store.add_entry(D(2026, 10, 12), "expense", 12050, cats["Food"], "Lunch, with Amy")
        store.add_entry(D(2026, 10, 5), "income", 5_200_000, cats["Salary"], "")
        store.add_rule("expense", 39000, cats["Entertainment"], "Netflix", "month", 1, D(2026, 9, 9))
        store.replace_imported("cashew", [(D(2026, 10, 1), "expense", 100, cats["Food"], "from Cashew",
                                           "cashew:t1")], [])
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "for cashew.csv")
            count = cashew.export_csv(path, ledger, lambda i: next(
                c.name for c in store.categories() if c.id == i), D(2026, 9, 1), D(2026, 10, 27))
            with open(path, "rb") as f:
                raw = f.read()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf") or b"\r" in raw)
            rows = list(csv.reader(raw.decode("utf-8").split("\n")[:-1]))
        self.assertEqual(count, 4)
        self.assertEqual(rows[0], cashew.CSV_HEADERS)
        body = [(r[1], r[2], r[3], r[5], r[6], r[8]) for r in rows[1:]]
        self.assertEqual(body, [
            ("-390.00", "TWD", "Netflix", "2026-09-09 00:00:00.000", "false", "Entertainment"),
            ("52000.00", "TWD", "", "2026-10-05 00:00:00.000", "true", "Salary"),
            ("-390.00", "TWD", "Netflix", "2026-10-09 00:00:00.000", "false", "Entertainment"),
            ("-120.50", "TWD", "Lunch, with Amy", "2026-10-12 00:00:00.000", "false", "Food")])


if __name__ == "__main__":
    unittest.main()
