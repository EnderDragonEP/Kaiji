"""SQLite storage: entries, repeating rules (with the dates they skip), categories, and the plan
and currency settings in `meta`. Days are YYYY-MM-DD text, amounts integer cents (always > 0;
the kind says whether money came in or went out)."""
import dataclasses
import datetime as dt
import glob
import os
import pathlib
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, icon TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY, day TEXT NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL,
    category_id INTEGER, note TEXT NOT NULL DEFAULT '', created TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS entries_day ON entries (day);
CREATE TABLE IF NOT EXISTS rules (
    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER NOT NULL, category_id INTEGER,
    note TEXT NOT NULL DEFAULT '', freq TEXT NOT NULL, every INTEGER NOT NULL DEFAULT 1,
    start TEXT NOT NULL, until TEXT, times INTEGER);
CREATE TABLE IF NOT EXISTS skips (rule_id INTEGER NOT NULL, day TEXT NOT NULL,
    PRIMARY KEY (rule_id, day));
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""
TABLES = {"categories", "entries", "rules", "skips", "meta"}

DEFAULT_CATEGORIES = [
    ("expense", "Food", "CAFE"), ("expense", "Transport", "BUS"),
    ("expense", "Shopping", "SHOPPING_CART"), ("expense", "Housing", "HOME"),
    ("expense", "Bills", "DOCUMENT"), ("expense", "Entertainment", "GAME"),
    ("expense", "Health", "HEART"), ("expense", "Education", "EDUCATION"),
    ("expense", "Travel", "AIRPLANE"), ("expense", "Social & gifts", "PEOPLE"),
    ("expense", "Other", "TAG"),
    ("income", "Salary", "CERTIFICATE"), ("income", "Bonus", "ASTERISK"),
    ("income", "Investments", "MARKET"), ("income", "Side income", "DEVELOPER_TOOLS"),
    ("income", "Gifts", "HEART"), ("income", "Refunds", "CANCEL"), ("income", "Other", "TAG"),
]


def _day(text):
    return dt.date.fromisoformat(text) if text else None


def _text(day):
    return day.isoformat() if day else None


@dataclasses.dataclass
class Category:
    id: int
    kind: str                  # "expense" or "income"
    name: str
    icon: str                  # FluentIcon member name, e.g. "CAFE"
    position: int = 0


@dataclasses.dataclass
class Entry:
    id: int
    day: dt.date
    kind: str
    amount: int
    category_id: int
    note: str = ""


@dataclasses.dataclass
class Rule:
    """A repeating entry: every `every` days/weeks/months/years from `start`, until `until` or
    for `times` dates (skipped ones included), whichever ends first; neither: no end."""
    id: int
    kind: str
    amount: int
    category_id: int
    note: str
    freq: str                  # "day", "week", "month" or "year"
    every: int
    start: dt.date
    until: dt.date = None
    times: int = None
    skips: set = dataclasses.field(default_factory=set)


@dataclasses.dataclass
class Plan:
    """What "left to spend" is worked out from."""
    start_balance: int = 0     # money you had at the start of start_date
    start_date: dt.date = None  # None: balances simply add up from the first entry
    savings_goal: int = 0      # set aside from each month's income
    min_balance: int = 0       # the balance shouldn't drop below this
    basis: str = "income"      # "income": this month's income; "balance": everything you have


class Store:
    def __init__(self, path, currency=("$", 2)):
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.path = path
        self.db = sqlite3.connect(path)
        self._prepare(currency)

    def _prepare(self, currency):
        with self.db:
            self.db.executescript(SCHEMA)
            # databases (and backups) from before "repeat N times"
            if "times" not in {row[1] for row in self.db.execute("PRAGMA table_info(rules)")}:
                self.db.execute("ALTER TABLE rules ADD COLUMN times INTEGER")
            if not self.db.execute("SELECT 1 FROM categories LIMIT 1").fetchone():
                self.db.executemany(
                    "INSERT INTO categories (kind, name, icon, position) VALUES (?, ?, ?, ?)",
                    [(k, n, i, pos) for pos, (k, n, i) in enumerate(DEFAULT_CATEGORIES)])
            if self.meta("currency") is None:
                self.set_meta("currency", currency[0])
                self.set_meta("decimals", currency[1])

    # ---- meta
    def meta(self, key, default=None):
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else default

    def set_meta(self, key, value):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, str(value)))

    def plan(self):
        return Plan(start_balance=int(self.meta("start_balance", 0)),
                    start_date=_day(self.meta("start_date", "")),
                    savings_goal=int(self.meta("savings_goal", 0)),
                    min_balance=int(self.meta("min_balance", 0)),
                    basis=self.meta("basis", "income"))

    def set_plan(self, plan):
        for key, value in (("start_balance", plan.start_balance),
                           ("start_date", _text(plan.start_date) or ""),
                           ("savings_goal", plan.savings_goal),
                           ("min_balance", plan.min_balance), ("basis", plan.basis)):
            self.set_meta(key, value)

    def currency(self):
        return self.meta("currency", "$"), int(self.meta("decimals", 2))

    def set_currency(self, symbol, decimals):
        self.set_meta("currency", symbol)
        self.set_meta("decimals", decimals)

    # ---- categories
    def categories(self):
        rows = self.db.execute("SELECT id, kind, name, icon, position FROM categories "
                               "ORDER BY kind, position, id")
        return [Category(*r) for r in rows]

    def add_category(self, kind, name, icon):
        with self.db:
            top = self.db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM categories "
                                  "WHERE kind = ?", (kind,)).fetchone()[0]
            return self.db.execute("INSERT INTO categories (kind, name, icon, position) "
                                   "VALUES (?, ?, ?, ?)", (kind, name, icon, top)).lastrowid

    def update_category(self, category_id, name, icon):
        with self.db:
            self.db.execute("UPDATE categories SET name = ?, icon = ? WHERE id = ?",
                            (name, icon, category_id))

    def move_category(self, category_id, step):
        """Swap with the neighbour above (step -1) or below (step 1) in its list."""
        cats = self.categories()
        mine = next(c for c in cats if c.id == category_id)
        same = [c for c in cats if c.kind == mine.kind]
        i = same.index(mine)
        j = i + step
        if not 0 <= j < len(same):
            return
        same[i], same[j] = same[j], same[i]
        with self.db:
            self.db.executemany("UPDATE categories SET position = ? WHERE id = ?",
                                [(pos, c.id) for pos, c in enumerate(same)])

    def category_uses(self, category_id):
        q = "SELECT (SELECT COUNT(*) FROM entries WHERE category_id = ?) " \
            "+ (SELECT COUNT(*) FROM rules WHERE category_id = ?)"
        return self.db.execute(q, (category_id, category_id)).fetchone()[0]

    def delete_category(self, category_id, move_to=None):
        """Delete a category; its entries and repeating entries move to move_to."""
        with self.db:
            for table in ("entries", "rules"):
                self.db.execute(f"UPDATE {table} SET category_id = ? WHERE category_id = ?",
                                (move_to, category_id))
            self.db.execute("DELETE FROM categories WHERE id = ?", (category_id,))

    # ---- entries
    def entries(self, start=None, end=None):
        q = "SELECT id, day, kind, amount, category_id, note FROM entries WHERE day BETWEEN ? AND ? " \
            "ORDER BY day, id"
        rows = self.db.execute(q, (_text(start) or "0000", _text(end) or "9999"))
        return [Entry(i, _day(d), k, a, c, n) for i, d, k, a, c, n in rows]

    def entry(self, entry_id):
        row = self.db.execute("SELECT id, day, kind, amount, category_id, note FROM entries "
                              "WHERE id = ?", (entry_id,)).fetchone()
        return Entry(row[0], _day(row[1]), *row[2:]) if row else None

    def add_entry(self, day, kind, amount, category_id, note=""):
        with self.db:
            return self.db.execute(
                "INSERT INTO entries (day, kind, amount, category_id, note, created) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (_text(day), kind, amount, category_id, note,
                 dt.datetime.now().isoformat(timespec="seconds"))).lastrowid

    def update_entry(self, entry_id, day, kind, amount, category_id, note=""):
        with self.db:
            self.db.execute("UPDATE entries SET day = ?, kind = ?, amount = ?, category_id = ?, "
                            "note = ? WHERE id = ?",
                            (_text(day), kind, amount, category_id, note, entry_id))

    def delete_entry(self, entry_id):
        with self.db:
            self.db.execute("DELETE FROM entries WHERE id = ?", (entry_id,))

    def entry_net(self, end):
        """Income minus expenses of the entries dated on or before `end`."""
        q = "SELECT COALESCE(SUM(CASE kind WHEN 'income' THEN amount ELSE -amount END), 0) " \
            "FROM entries WHERE day <= ?"
        return self.db.execute(q, (_text(end),)).fetchone()[0]

    def first_day(self):
        q = "SELECT MIN(d) FROM (SELECT MIN(day) AS d FROM entries UNION ALL " \
            "SELECT MIN(start) FROM rules)"
        return _day(self.db.execute(q).fetchone()[0])

    def usual_category(self, kind, since):
        """The category used most for kind since the given day, or None."""
        row = self.db.execute("SELECT category_id FROM entries WHERE kind = ? AND day >= ? "
                              "AND category_id IS NOT NULL GROUP BY category_id "
                              "ORDER BY COUNT(*) DESC, MAX(id) DESC LIMIT 1",
                              (kind, _text(since))).fetchone()
        return row[0] if row else None

    def recent_notes(self, limit=400):
        """{note: (kind, category_id)} of the most recent entries, for completion."""
        q = "SELECT note, kind, category_id FROM (SELECT note, kind, category_id, id FROM entries " \
            "UNION ALL SELECT note, kind, category_id, 0 FROM rules) WHERE note != '' " \
            "ORDER BY id DESC LIMIT ?"
        out = {}
        for note, kind, category_id in self.db.execute(q, (limit,)):
            out.setdefault(note, (kind, category_id))
        return out

    # ---- repeating rules
    def rules(self):
        skips = {}
        for rule_id, day in self.db.execute("SELECT rule_id, day FROM skips"):
            skips.setdefault(rule_id, set()).add(_day(day))
        rows = self.db.execute("SELECT id, kind, amount, category_id, note, freq, every, start, "
                               "until, times FROM rules ORDER BY id")
        return [Rule(i, k, a, c, n, f, e, _day(s), _day(u), t, skips.get(i, set()))
                for i, k, a, c, n, f, e, s, u, t in rows]

    def rule(self, rule_id):
        return next((r for r in self.rules() if r.id == rule_id), None)

    def add_rule(self, kind, amount, category_id, note, freq, every, start, until=None, times=None,
                 skips=()):
        with self.db:
            rule_id = self.db.execute(
                "INSERT INTO rules (kind, amount, category_id, note, freq, every, start, until, "
                "times) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (kind, amount, category_id, note, freq, every, _text(start), _text(until),
                 times)).lastrowid
            self.db.executemany("INSERT OR IGNORE INTO skips VALUES (?, ?)",
                                [(rule_id, _text(d)) for d in skips])
        return rule_id

    def update_rule(self, rule_id, kind, amount, category_id, note, freq, every, start, until=None,
                    times=None):
        with self.db:
            self.db.execute("UPDATE rules SET kind = ?, amount = ?, category_id = ?, note = ?, "
                            "freq = ?, every = ?, start = ?, until = ?, times = ? WHERE id = ?",
                            (kind, amount, category_id, note, freq, every, _text(start),
                             _text(until), times, rule_id))

    def set_rule_end(self, rule_id, until=None, times=None):
        with self.db:
            self.db.execute("UPDATE rules SET until = ?, times = ? WHERE id = ?",
                            (_text(until), times, rule_id))

    def delete_rule(self, rule_id):
        with self.db:
            self.db.execute("DELETE FROM rules WHERE id = ?", (rule_id,))
            self.db.execute("DELETE FROM skips WHERE rule_id = ?", (rule_id,))

    def skip(self, rule_id, day):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO skips VALUES (?, ?)", (rule_id, _text(day)))

    def unskip(self, rule_id, day):
        with self.db:
            self.db.execute("DELETE FROM skips WHERE rule_id = ? AND day = ?",
                            (rule_id, _text(day)))

    # ---- files
    def backup_to(self, path):
        """Copy the whole database to path (safe while it's open)."""
        target = sqlite3.connect(path)
        try:
            with target:
                self.db.backup(target)
        finally:
            target.close()

    def restore_from(self, path):
        """Replace everything with the backup at path. ValueError if it isn't a Kaiji backup."""
        source = sqlite3.connect(pathlib.Path(path).resolve().as_uri() + "?mode=ro", uri=True)
        try:
            try:
                names = {r[0] for r in source.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'")}
            except sqlite3.DatabaseError as e:
                raise ValueError("This file isn't a Kaiji backup.") from e
            if not TABLES <= names:
                raise ValueError("This file isn't a Kaiji backup.")
            source.backup(self.db)
        finally:
            source.close()
        self._prepare(self.currency())

    def auto_backup(self, folder, keep=10):
        """Once a day, keep a copy of the database in folder; only the newest `keep` stay."""
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"kaiji-{dt.date.today().isoformat()}.db")
        if not os.path.exists(path):
            self.backup_to(path)
        for old in sorted(glob.glob(os.path.join(folder, "kaiji-*.db")))[:-keep]:
            try:
                os.remove(old)
            except OSError:
                pass
