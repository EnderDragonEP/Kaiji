"""Tests for sync: two devices and a server. They run against an in-memory server, and against
PostgreSQL too when KAIJI_TEST_PG has a connection string for a database made for testing -
everything in its kaiji schema is deleted, e.g.
KAIJI_TEST_PG="host=127.0.0.1 port=55432 dbname=kaiji user=kaiji password=..." """
import datetime as dt
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from kaiji_app import credentials, sync  # noqa: E402
from kaiji_app.store import Plan, Store  # noqa: E402

D = dt.date


class MemoryServer:
    """The server's tables in memory, with Remote's methods."""

    def __init__(self):
        self.tables = {table: {} for table in sync.COLUMNS}
        self.version = 0

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        pass

    def _next(self):
        self.version += 1
        return self.version

    def _write(self, table, rows):
        key = sync.COLUMNS[table][0]
        for r in rows:
            row = {c: (list(r[c]) if c == "skips" else r[c]) for c in sync.COLUMNS[table]}
            self.tables[table][r[key]] = dict(row, deleted=False, version=self._next())

    def _drop(self, table, keys):
        for key in keys:
            row = self.tables[table].get(key)
            if row and not row["deleted"]:
                row.update(deleted=True, version=self._next())

    def prepare(self):
        return not any(not r["deleted"] for rows in self.tables.values() for r in rows.values())

    def push(self, changes):
        for table in sync.COLUMNS:
            rows, gone = changes.get(table, ((), ()))
            self._write(table, rows)
            self._drop(table, gone)

    def pull(self, cursor=0):
        found = {t: sorted((dict(r) for r in rows.values() if r["version"] > cursor),
                           key=lambda r: r["version"]) for t, rows in self.tables.items()}
        return found, max((r["version"] for rows in found.values() for r in rows), default=cursor)

    def everything(self):
        found, top = self.pull(0)
        return {t: [r for r in rows if not r["deleted"]] for t, rows in found.items()}, top

    def replace(self, rows):
        for table, cols in sync.COLUMNS.items():
            mine = {r[cols[0]] for r in rows.get(table, [])}
            self._drop(table, [k for k in self.tables[table] if k not in mine])
            self._write(table, rows.get(table, []))
        return self.version


class SyncTests:
    """The scenarios; a subclass says which server."""

    def setUp(self):
        self.pc, self.phone = Store(":memory:", ("$", 2)), Store(":memory:", ("$", 2))

    def tearDown(self):
        self.pc.db.close()
        self.phone.db.close()

    def server(self):
        raise NotImplementedError

    def sync(self, store):
        with self.server() as server:
            server.prepare()
            return sync.run(store.db, server)

    def join(self, store, first):
        sync.reset(store.db)
        sync.set_state(store.db, "first", first)
        return self.sync(store)

    def connect_both(self):
        """The PC goes first and puts its data on the server; the phone takes it."""
        self.join(self.pc, "replace")
        self.join(self.phone, "take")

    def food(self, store):
        return next(c.id for c in store.categories() if c.name == "Food" and c.kind == "expense")

    def entries(self, store):
        cats = {c.id: c.name for c in store.categories()}
        return sorted((e.day, e.kind, e.amount, cats.get(e.category_id), e.note)
                      for e in store.entries())

    def rules(self, store):
        cats = {c.id: c.name for c in store.categories()}
        return sorted((r.kind, r.amount, cats.get(r.category_id), r.note, r.freq, r.every, r.start,
                       r.until, r.times, sorted(r.skips)) for r in store.rules())

    def categories(self, store):
        return [(c.kind, c.name, c.icon) for c in store.categories()]

    def same(self):
        self.assertEqual(self.entries(self.pc), self.entries(self.phone))
        self.assertEqual(self.rules(self.pc), self.rules(self.phone))
        self.assertEqual(self.categories(self.pc), self.categories(self.phone))
        self.assertEqual(self.pc.plan(), self.phone.plan())
        self.assertEqual(self.pc.currency(), self.phone.currency())

    # ---- first connect
    def test_the_first_device_fills_the_server_and_the_next_takes_it(self):
        with self.server() as server:
            self.assertTrue(server.prepare())
        self.pc.add_entry(D(2026, 10, 3), "expense", 12050, self.food(self.pc), "Lunch")
        self.phone.add_entry(D(2026, 10, 4), "expense", 999, self.food(self.phone), "Phone's own")
        self.assertTrue(sync.has_own_data(self.phone.db))
        self.connect_both()
        with self.server() as server:
            self.assertFalse(server.prepare())
        self.same()
        self.assertEqual([e[-1] for e in self.entries(self.phone)], ["Lunch"])
        self.assertEqual(sync.waiting(self.pc.db), 0)
        self.assertEqual(sync.waiting(self.phone.db), 0)

    def test_replacing_the_server_reaches_the_other_devices(self):
        self.pc.add_entry(D(2026, 10, 3), "expense", 12050, self.food(self.pc), "Lunch")
        self.connect_both()
        self.phone.add_entry(D(2026, 10, 5), "income", 500000, None, "Pay")
        self.pc.add_entry(D(2026, 10, 6), "expense", 100, None, "Only on the PC, not pushed")
        self.join(self.phone, "replace")
        self.sync(self.pc)
        self.assertEqual([e[-1] for e in self.entries(self.pc)],
                         ["Lunch", "Pay", "Only on the PC, not pushed"])
        self.sync(self.phone)      # the PC's unpushed entry still went up after the replace
        self.same()

    def test_a_restored_backup_replaces_everyone_s_data(self):
        self.pc.add_entry(D(2026, 10, 3), "expense", 12050, self.food(self.pc), "Lunch")
        self.connect_both()
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "backup.db")
            self.pc.backup_to(path)
            self.pc.add_entry(D(2026, 10, 4), "expense", 300, None, "After the backup")
            self.sync(self.pc)
            self.sync(self.phone)
            self.assertEqual(len(self.entries(self.phone)), 2)
            self.pc.restore_from(path)                 # what Kaiji.restore() does
            self.join(self.pc, "replace")
        self.sync(self.phone)
        self.assertEqual([e[-1] for e in self.entries(self.phone)], ["Lunch"])
        self.same()

    # ---- changes going across
    def test_entries_added_edited_and_deleted_on_either_side(self):
        self.connect_both()
        lunch = self.pc.add_entry(D(2026, 10, 3), "expense", 12050, self.food(self.pc), "Lunch")
        self.assertEqual(self.pc.entry(lunch).note, "Lunch")    # the id comes back as before
        self.sync(self.pc)
        self.assertFalse(self.sync(self.pc))                    # nothing new: nothing changes
        self.assertTrue(self.sync(self.phone))
        self.same()
        mine = self.phone.entries()[0]
        self.phone.update_entry(mine.id, D(2026, 10, 4), "expense", 13000, mine.category_id, "Dinner")
        self.sync(self.phone)
        self.sync(self.pc)
        self.assertEqual(self.entries(self.pc), [(D(2026, 10, 4), "expense", 13000, "Food", "Dinner")])
        self.pc.delete_entry(lunch)
        self.sync(self.pc)
        self.sync(self.phone)
        self.assertEqual(self.phone.entries(), [])
        self.assertEqual(sync.waiting(self.phone.db), 0)        # what came in isn't sent back

    def test_repeating_entries_and_their_skips(self):
        self.connect_both()
        rent = self.pc.add_rule("expense", 1800000, None, "Rent", "month", 1, D(2026, 1, 31),
                                times=12, skips=[D(2026, 2, 28)])
        self.sync(self.pc)
        self.sync(self.phone)
        self.same()
        mine = self.phone.rules()[0]
        self.phone.skip(mine.id, D(2026, 3, 31))
        self.phone.unskip(mine.id, D(2026, 2, 28))
        self.sync(self.phone)
        self.sync(self.pc)
        self.assertEqual(self.pc.rule(rent).skips, {D(2026, 3, 31)})
        self.pc.set_rule_end(rent, until=D(2026, 6, 30))
        self.sync(self.pc)
        self.sync(self.phone)
        self.same()
        self.pc.delete_rule(rent)
        self.sync(self.pc)
        self.sync(self.phone)
        self.assertEqual(self.phone.rules(), [])
        self.assertEqual(self.phone.db.execute("SELECT COUNT(*) FROM skips").fetchone()[0], 0)

    def test_the_plan_and_the_currency(self):
        self.connect_both()
        self.pc.set_plan(Plan(start_balance=5000000, start_date=D(2026, 10, 1), savings_goal=300000,
                              basis="balance"))
        self.pc.set_currency("NT$", 0)
        self.sync(self.pc)
        self.sync(self.phone)
        self.same()
        self.assertEqual(self.phone.currency(), ("NT$", 0))

    def test_categories_and_deleting_one_in_use(self):
        self.connect_both()
        snacks = self.pc.add_category("expense", "Snacks", "CAFE")
        self.pc.add_entry(D(2026, 10, 3), "expense", 500, snacks, "Chips")
        self.pc.move_category(snacks, -1)
        self.sync(self.pc)
        self.sync(self.phone)
        self.same()
        mine = next(c for c in self.phone.categories() if c.name == "Snacks")
        self.phone.update_category(mine.id, "Treats", "GAME")
        self.sync(self.phone)
        self.sync(self.pc)
        self.same()
        self.pc.delete_category(snacks, move_to=self.food(self.pc))
        self.sync(self.pc)
        self.sync(self.phone)
        self.same()
        self.assertEqual(self.entries(self.phone), [(D(2026, 10, 3), "expense", 500, "Food", "Chips")])

    # ---- both at once
    def test_a_change_made_during_a_round_survives_it(self):
        lunch = self.pc.add_entry(D(2026, 10, 3), "expense", 12050, None, "Lunch")
        self.connect_both()
        mine = self.phone.entries()[0]
        self.pc.update_entry(lunch, D(2026, 10, 3), "expense", 12050, None, "PC's")
        self.sync(self.pc)
        todo = sync.job(self.phone.db)               # the phone's round starts...
        self.phone.update_entry(mine.id, D(2026, 10, 3), "expense", 12050, None, "Phone's")
        with self.server() as server:                # ...the server sends the PC's edit...
            rows, cursor = sync.exchange(server, todo)
        sync.finish(self.phone.db, todo, rows, cursor)
        self.assertEqual(self.phone.entry(mine.id).note, "Phone's")    # ...which doesn't win
        self.sync(self.phone)
        self.sync(self.pc)
        self.assertEqual(self.pc.entry(lunch).note, "Phone's")

    def test_the_last_push_wins(self):
        lunch = self.pc.add_entry(D(2026, 10, 3), "expense", 12050, None, "Lunch")
        self.connect_both()
        mine = self.phone.entries()[0]
        self.pc.update_entry(lunch, D(2026, 10, 3), "expense", 100, None, "PC's")
        self.phone.update_entry(mine.id, D(2026, 10, 3), "expense", 200, None, "Phone's")
        self.sync(self.pc)
        self.sync(self.phone)
        self.sync(self.pc)
        self.same()
        self.assertEqual(self.pc.entry(lunch).note, "Phone's")

    def test_an_offline_round_keeps_the_changes_for_the_next(self):
        self.connect_both()
        self.pc.add_entry(D(2026, 10, 3), "expense", 12050, None, "Lunch")
        todo = sync.job(self.pc.db)
        self.assertEqual(len(todo["changes"]["entries"][0]), 1)
        # the network part failed: nothing is finished, the change still waits
        self.assertEqual(sync.waiting(self.pc.db), 1)
        self.sync(self.pc)
        self.sync(self.phone)
        self.same()


class MemorySyncTests(SyncTests, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.memory = MemoryServer()

    def server(self):
        return self.memory


@unittest.skipUnless(os.environ.get("KAIJI_TEST_PG"), "set KAIJI_TEST_PG to test with PostgreSQL")
class PostgresSyncTests(SyncTests, unittest.TestCase):
    def setUp(self):
        super().setUp()
        import psycopg
        from psycopg.conninfo import conninfo_to_dict
        self.params = conninfo_to_dict(os.environ["KAIJI_TEST_PG"])
        with psycopg.connect(**self.params, autocommit=True) as c:
            c.execute("DROP SCHEMA IF EXISTS kaiji CASCADE")

    def server(self):
        p = self.params
        return sync.Remote(p["host"], int(p.get("port", 5432)), p["dbname"], p["user"],
                           p.get("password", ""), tls=p.get("sslmode") == "require")

    def test_a_newer_kaiji_s_server_is_left_alone(self):
        with self.server() as server:
            server.prepare()
            server.conn.execute("UPDATE kaiji.info SET value = '99' WHERE key = 'schema_version'")
            with self.assertRaises(sync.SyncError) as e:
                server.prepare()
        self.assertEqual(e.exception.kind, "newer")

    def test_a_wrong_password_is_said_so(self):
        p = self.params
        with self.assertRaises(sync.SyncError) as e:
            with sync.Remote(p["host"], int(p.get("port", 5432)), p["dbname"], p["user"], "wrong",
                             tls=False):
                pass
        self.assertEqual(e.exception.kind, "denied")

    def test_an_unreachable_server_is_offline(self):
        with self.assertRaises(sync.SyncError) as e:
            with sync.Remote("127.0.0.1", 1, "kaiji", "kaiji", "", tls=False, timeout=2):
                pass
        self.assertEqual(e.exception.kind, "offline")


class StoreSyncSchemaTests(unittest.TestCase):
    def test_every_row_has_a_uid_and_changes_are_noted(self):
        store = Store(":memory:")
        self.assertEqual(store.db.execute("SELECT COUNT(*) FROM categories WHERE uid IS NULL")
                         .fetchone()[0], 0)
        sync.reset(store.db)
        entry = store.add_entry(D(2026, 10, 3), "expense", 100, None, "Tea")
        rule = store.add_rule("expense", 100, None, "Tea", "week", 1, D(2026, 10, 1))
        store.skip(rule, D(2026, 10, 8))
        store.skip(rule, D(2026, 10, 8))       # already skipped: nothing new to note
        store.set_meta("basis", "balance")
        noted = store.db.execute("SELECT tbl FROM sync_changes ORDER BY seq").fetchall()
        self.assertEqual([t for (t,) in noted], ["entries", "rules", "meta"])
        self.assertEqual(store.entry(entry).note, "Tea")

    def test_a_change_moves_a_noted_row_to_the_end(self):
        store = Store(":memory:")
        rule = store.add_rule("expense", 100, None, "Tea", "week", 1, D(2026, 10, 1))
        store.add_entry(D(2026, 10, 3), "expense", 100, None, "Tea")
        before = store.db.execute("SELECT seq FROM sync_changes WHERE tbl = 'rules'").fetchone()[0]
        store.skip(rule, D(2026, 10, 8))       # fired by INSERT OR IGNORE, still a newer seq
        after = store.db.execute("SELECT seq FROM sync_changes WHERE tbl = 'rules'").fetchone()[0]
        self.assertGreater(after, before)

    def test_a_database_from_before_sync_gets_uids(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "old.db")
            db = sqlite3.connect(path)
            db.executescript("""
                CREATE TABLE categories (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
                    icon TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE entries (id INTEGER PRIMARY KEY, day TEXT NOT NULL, kind TEXT NOT NULL,
                    amount INTEGER NOT NULL, category_id INTEGER, note TEXT NOT NULL DEFAULT '',
                    created TEXT NOT NULL);
                CREATE TABLE rules (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER NOT NULL,
                    category_id INTEGER, note TEXT NOT NULL DEFAULT '', freq TEXT NOT NULL,
                    every INTEGER NOT NULL DEFAULT 1, start TEXT NOT NULL, until TEXT);
                CREATE TABLE skips (rule_id INTEGER NOT NULL, day TEXT NOT NULL, PRIMARY KEY (rule_id, day));
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO categories (kind, name, icon) VALUES ('expense', 'Food', 'CAFE');
                INSERT INTO entries (day, kind, amount, category_id, note, created)
                    VALUES ('2026-01-02', 'expense', 100, 1, 'a', '2026-01-02T10:00:00'),
                           ('2026-01-03', 'expense', 200, 1, 'b', '2026-01-03T10:00:00');
                INSERT INTO rules (kind, amount, note, freq, start) VALUES ('expense', 5, 'r', 'day', '2026-01-01');
            """)
            db.close()
            store = Store(path)
            for table in ("categories", "entries", "rules"):
                uids = [u for (u,) in store.db.execute(f"SELECT uid FROM {table}")]
                self.assertTrue(all(u and len(u) == 32 for u in uids))
                self.assertEqual(len(set(uids)), len(uids))
            self.assertEqual(len(store.entries()), 2)
            store.db.close()


class CredentialTests(unittest.TestCase):
    TARGET = "Kaiji/test"

    def test_save_load_forget(self):
        try:
            self.assertIsNone(credentials.load(self.TARGET))
            credentials.save("kaiji", "pässwörd 花錢", self.TARGET)
            self.assertEqual(credentials.load(self.TARGET), "pässwörd 花錢")
            credentials.save("kaiji", "", self.TARGET)
            self.assertEqual(credentials.load(self.TARGET), "")
        finally:
            credentials.forget(self.TARGET)
        self.assertIsNone(credentials.load(self.TARGET))
        credentials.forget(self.TARGET)           # forgetting twice is fine


if __name__ == "__main__":
    unittest.main()
