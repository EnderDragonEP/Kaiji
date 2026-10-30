"""Sync through PostgreSQL, when it's turned on in Settings. Every device keeps its own kaiji.db
and works without the server; their changes meet in the server's copy.

Here, triggers (store.SYNC_SCHEMA) note every change in sync_changes. A round pushes those rows to
the server, then pulls what other devices pushed since the last round. On the server each row
keeps the version it was last written at and a deleted flag, so "since the last round" is
"version > cursor". When two devices change the same row, the last push wins.

The phone's sync.dart does the same against the same tables."""
import contextlib
import datetime as dt
import threading

from PySide6.QtCore import QObject, QTimer, Signal

from . import credentials

SCHEMA_VERSION = 1
LOCK = 0x6B61696A69                    # "kaiji": writers take turns, so versions commit in order
# what a device sends of each table, its key first; categories go before what refers to them
COLUMNS = {
    "categories": ("uid", "kind", "name", "icon", "position"),
    "rules": ("uid", "kind", "amount", "category_uid", "note", "freq", "every", "start", "until",
              "times", "skips"),
    "entries": ("uid", "day", "kind", "amount", "category_uid", "note", "created"),
    "meta": ("key", "value"),
}
SERVER_SCHEMA = [
    "CREATE SEQUENCE IF NOT EXISTS kaiji.version",
    "CREATE TABLE IF NOT EXISTS kaiji.info (key text PRIMARY KEY, value text NOT NULL)",
    "CREATE TABLE IF NOT EXISTS kaiji.categories (uid text PRIMARY KEY, kind text NOT NULL, "
    "name text NOT NULL, icon text NOT NULL, position integer NOT NULL DEFAULT 0, "
    "version bigint NOT NULL, deleted boolean NOT NULL DEFAULT false)",
    "CREATE TABLE IF NOT EXISTS kaiji.rules (uid text PRIMARY KEY, kind text NOT NULL, "
    "amount bigint NOT NULL, category_uid text, note text NOT NULL DEFAULT '', "
    "freq text NOT NULL, every integer NOT NULL DEFAULT 1, start text NOT NULL, until text, "
    "times integer, skips text[] NOT NULL DEFAULT '{}', version bigint NOT NULL, "
    "deleted boolean NOT NULL DEFAULT false)",
    "CREATE TABLE IF NOT EXISTS kaiji.entries (uid text PRIMARY KEY, day text NOT NULL, "
    "kind text NOT NULL, amount bigint NOT NULL, category_uid text, "
    "note text NOT NULL DEFAULT '', created text NOT NULL, version bigint NOT NULL, "
    "deleted boolean NOT NULL DEFAULT false)",
    "CREATE TABLE IF NOT EXISTS kaiji.meta (key text PRIMARY KEY, value text, "
    "version bigint NOT NULL, deleted boolean NOT NULL DEFAULT false)",
    *[f"CREATE INDEX IF NOT EXISTS {table}_version ON kaiji.{table} (version)" for table in COLUMNS],
    f"INSERT INTO kaiji.info VALUES ('schema_version', '{SCHEMA_VERSION}') "
    "ON CONFLICT (key) DO NOTHING",
]


def _upsert(table):
    cols = COLUMNS[table]
    values = ", ".join("%s::text[]" if c == "skips" else "%s" for c in cols)
    return (f"INSERT INTO kaiji.{table} ({', '.join(cols)}, version) "
            f"VALUES ({values}, nextval('kaiji.version')) ON CONFLICT ({cols[0]}) DO UPDATE SET "
            + ", ".join(f"{c} = EXCLUDED.{c}" for c in cols[1:])
            + ", version = EXCLUDED.version, deleted = false")


UPSERT = {table: _upsert(table) for table in COLUMNS}


class SyncError(Exception):
    """Why a round didn't happen. kind: "offline" (the server can't be reached: try again
    later), "denied" (the sign-in, the database or its rights need fixing), "newer" (a newer
    Kaiji set up the server) or "failed"."""

    def __init__(self, kind, message, detail=""):
        super().__init__(message)
        self.kind, self.detail = kind, detail


def _error(e, host):
    """The SyncError for a psycopg error."""
    import psycopg
    text = str(e).strip()
    first = text.splitlines()[0] if text else type(e).__name__
    state = getattr(e, "sqlstate", None) or ""
    low = text.lower()
    if "pg_hba.conf" in low:
        return SyncError("denied", "The server doesn't let this device in: it needs a line for "
                         "it in pg_hba.conf (see the README).", first)
    if state.startswith("28") or "authentication failed" in low:
        return SyncError("denied", "The server didn't accept the user name and password.", first)
    if state == "3D000" or ("database" in low and "does not exist" in low):
        return SyncError("denied", "That database isn't on the server.", first)
    if state == "42501" or "permission denied" in low:
        return SyncError("denied", "This user can't make Kaiji's tables in that database.", first)
    if "ssl" in low and "not support" in low:
        return SyncError("denied", "The server doesn't take encrypted connections: turn off "
                         "“Encrypted connection”, or set up TLS on the server.", first)
    if isinstance(e, psycopg.OperationalError):
        return SyncError("offline", f"Can't reach {host}.", first)
    return SyncError("failed", first, text)


class Remote:
    """Kaiji's tables on the server. `with Remote(...) as server:` is one connection."""

    def __init__(self, host, port, database, user, password, tls=True, timeout=5):
        self.host = host
        # sslmode require: encrypted, without checking the certificate (a LAN server's is usually
        # self-signed); the password goes as SCRAM either way
        self.params = dict(host=host, port=port, dbname=database, user=user, password=password,
                           sslmode="require" if tls else "disable", connect_timeout=timeout,
                           application_name="Kaiji", options="-c statement_timeout=30000")
        self.conn = None

    def __enter__(self):
        import psycopg                 # only once sync is on: local-only use never loads it
        try:
            self.conn = psycopg.connect(autocommit=True, **self.params)
        except psycopg.Error as e:
            raise _error(e, self.host) from e
        return self

    def __exit__(self, *exc):
        self.conn.close()

    @contextlib.contextmanager
    def _transaction(self, read_only=False):
        import psycopg
        try:
            with self.conn.transaction():
                if read_only:
                    # every table from one snapshot, so the cursor can't skip a row it didn't see
                    self.conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
                else:
                    self.conn.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK,))
                yield self.conn
        except psycopg.Error as e:
            raise _error(e, self.host) from e

    def prepare(self):
        """Make Kaiji's tables if they aren't there. True if the server has no Kaiji data yet."""
        with self._transaction() as c:
            if c.execute("SELECT to_regclass('kaiji.info')").fetchone()[0] is None:
                if c.execute("SELECT to_regnamespace('kaiji')").fetchone()[0] is None:
                    c.execute("CREATE SCHEMA kaiji")
                for statement in SERVER_SCHEMA:
                    c.execute(statement)
            version = c.execute("SELECT value FROM kaiji.info WHERE key = 'schema_version'")
            if int(version.fetchone()[0]) > SCHEMA_VERSION:
                raise SyncError("newer", "A newer Kaiji set up the server: update this one to sync.")
            found = c.execute("SELECT " + " OR ".join(
                f"EXISTS (SELECT 1 FROM kaiji.{t} WHERE NOT deleted)" for t in COLUMNS))
            return not found.fetchone()[0]

    @staticmethod
    def _write(c, table, rows):
        if rows:
            cols = COLUMNS[table]
            with c.cursor() as cur:
                cur.executemany(UPSERT[table], [tuple(r[col] for col in cols) for r in rows])

    def push(self, changes):
        """Write {table: (rows, keys of deleted rows)}."""
        if not changes:
            return
        with self._transaction() as c:
            for table in COLUMNS:
                rows, gone = changes.get(table, ((), ()))
                self._write(c, table, rows)
                if gone:
                    c.execute(f"UPDATE kaiji.{table} SET deleted = true, "
                              f"version = nextval('kaiji.version') "
                              f"WHERE {COLUMNS[table][0]} = ANY(%s::text[]) AND NOT deleted",
                              (list(gone),))

    def pull(self, cursor=0):
        """({table: rows written after version cursor, deleted ones too}, the next cursor)."""
        found = {}
        with self._transaction(read_only=True) as c:
            for table, cols in COLUMNS.items():
                names = cols + ("deleted", "version")
                rows = c.execute(f"SELECT {', '.join(names)} FROM kaiji.{table} "
                                 f"WHERE version > %s ORDER BY version", (cursor,))
                found[table] = [dict(zip(names, r)) for r in rows]
        top = max((r["version"] for rows in found.values() for r in rows), default=cursor)
        return found, top

    def everything(self):
        """Everything that isn't deleted, and the cursor after it."""
        found, top = self.pull(0)
        return {t: [r for r in rows if not r["deleted"]] for t, rows in found.items()}, top

    def replace(self, rows):
        """Make the server's data {table: rows}, this device's; returns the cursor after it."""
        with self._transaction() as c:
            for table, cols in COLUMNS.items():
                mine = rows.get(table, [])
                c.execute(f"UPDATE kaiji.{table} SET deleted = true, "
                          f"version = nextval('kaiji.version') "
                          f"WHERE NOT deleted AND NOT ({cols[0]} = ANY(%s::text[]))",
                          ([r[cols[0]] for r in mine],))
                self._write(c, table, mine)
            top = c.execute("SELECT GREATEST(" + ", ".join(
                f"(SELECT MAX(version) FROM kaiji.{t})" for t in COLUMNS) + ")")
            return top.fetchone()[0] or 0


# ---- this device's side: kaiji.db

_READ = {
    "categories": "SELECT uid, kind, name, icon, position FROM categories",
    "rules": "SELECT r.uid, r.kind, r.amount, c.uid, r.note, r.freq, r.every, r.start, r.until, "
             "r.times, r.id FROM rules r LEFT JOIN categories c ON c.id = r.category_id",
    "entries": "SELECT e.uid, e.day, e.kind, e.amount, c.uid, e.note, e.created "
               "FROM entries e LEFT JOIN categories c ON c.id = e.category_id",
    "meta": "SELECT key, value FROM meta",
}
_KEY = {"categories": "uid", "rules": "r.uid", "entries": "e.uid", "meta": "key"}


def _rows(db, table, keys=None):
    """This device's rows of table in COLUMNS' terms; only those with the given keys if any."""
    if keys is None:
        found = db.execute(_READ[table]).fetchall()
    else:
        keys, found = list(keys), []
        for i in range(0, len(keys), 500):
            chunk = keys[i:i + 500]
            found += db.execute(f"{_READ[table]} WHERE {_KEY[table]} IN "
                                f"({', '.join('?' * len(chunk))})", chunk).fetchall()
    if table == "rules":
        skips = {}
        for rule_id, day in db.execute("SELECT rule_id, day FROM skips ORDER BY day"):
            skips.setdefault(rule_id, []).append(day)
        found = [row[:-1] + (skips.get(row[-1], []),) for row in found]
    return [dict(zip(COLUMNS[table], row)) for row in found]


def state(db, key, default=None):
    row = db.execute("SELECT value FROM sync_state WHERE key = ?", (key,)).fetchone()
    return row[0] if row else default


def _put_state(db, key, value):
    if value is None:
        db.execute("DELETE FROM sync_state WHERE key = ?", (key,))
    else:
        db.execute("INSERT OR REPLACE INTO sync_state VALUES (?, ?)", (key, str(value)))


def set_state(db, key, value):
    with db:
        _put_state(db, key, value)


def reset(db):
    """Forget what was synced: the next round starts as a device's first."""
    with db:
        db.execute("DELETE FROM sync_state")
        db.execute("DELETE FROM sync_changes")


def has_own_data(db):
    """Whether there's anything here to lose: entries or repeating entries."""
    return bool(db.execute("SELECT EXISTS (SELECT 1 FROM entries) "
                           "OR EXISTS (SELECT 1 FROM rules)").fetchone()[0])


def waiting(db):
    return db.execute("SELECT COUNT(*) FROM sync_changes").fetchone()[0]


def last_sync(db):
    stamp = state(db, "last_sync")
    return dt.datetime.fromisoformat(stamp) if stamp else None


def _last_seq(db):
    return db.execute("SELECT COALESCE(MAX(seq), 0) FROM sync_changes").fetchone()[0]


def snapshot(db):
    return {table: _rows(db, table) for table in COLUMNS}


def pending(db):
    """(the last change's seq, {table: (rows, keys of deleted rows)}) of what isn't pushed yet."""
    noted = db.execute("SELECT seq, tbl, uid FROM sync_changes ORDER BY seq").fetchall()
    changes = {}
    for table in COLUMNS:
        keys = {uid for _, t, uid in noted if t == table}
        if keys:
            rows = _rows(db, table, keys)
            changes[table] = (rows, sorted(keys - {r[COLUMNS[table][0]] for r in rows}))
    return (noted[-1][0] if noted else 0), changes


def _category_id(db, uid):
    row = db.execute("SELECT id FROM categories WHERE uid = ?", (uid,)).fetchone() if uid else None
    return row[0] if row else None


def _put(db, table, uid, values):
    """Give the row with this uid these {column: value}s, adding it if it isn't here. True if
    anything changed."""
    sets = ", ".join(f"{c} = ?" for c in values)
    differs = " OR ".join(f"{c} IS NOT ?" for c in values)
    v = list(values.values())
    if db.execute(f"UPDATE {table} SET {sets} WHERE uid = ? AND ({differs})",
                  v + [uid] + v).rowcount:
        return True
    if db.execute(f"SELECT 1 FROM {table} WHERE uid = ?", (uid,)).fetchone():
        return False
    db.execute(f"INSERT INTO {table} ({', '.join(values)}, uid) "
               f"VALUES ({', '.join('?' * len(values))}, ?)", v + [uid])
    return True


def _apply_category(db, row):
    if row["deleted"]:
        category_id = _category_id(db, row["uid"])
        if category_id is None:
            return False
        for table in ("entries", "rules"):        # so a new category can't take over the id
            db.execute(f"UPDATE {table} SET category_id = NULL WHERE category_id = ?",
                       (category_id,))
        db.execute("DELETE FROM categories WHERE id = ?", (category_id,))
        return True
    return _put(db, "categories", row["uid"],
                {c: row[c] for c in ("kind", "name", "icon", "position")})


def _apply_rule(db, row):
    found = db.execute("SELECT id FROM rules WHERE uid = ?", (row["uid"],)).fetchone()
    if row["deleted"]:
        if not found:
            return False
        db.execute("DELETE FROM skips WHERE rule_id = ?", found)
        db.execute("DELETE FROM rules WHERE id = ?", found)
        return True
    values = {c: row[c] for c in ("kind", "amount", "note", "freq", "every", "start", "until",
                                  "times")}
    values["category_id"] = _category_id(db, row["category_uid"])
    changed = _put(db, "rules", row["uid"], values)
    rule_id = db.execute("SELECT id FROM rules WHERE uid = ?", (row["uid"],)).fetchone()[0]
    have = {day for (day,) in db.execute("SELECT day FROM skips WHERE rule_id = ?", (rule_id,))}
    if have != set(row["skips"] or ()):
        db.execute("DELETE FROM skips WHERE rule_id = ?", (rule_id,))
        db.executemany("INSERT INTO skips VALUES (?, ?)",
                       [(rule_id, day) for day in sorted(set(row["skips"]))])
        changed = True
    return changed


def _apply_entry(db, row):
    if row["deleted"]:
        return db.execute("DELETE FROM entries WHERE uid = ?", (row["uid"],)).rowcount > 0
    values = {c: row[c] for c in ("day", "kind", "amount", "note", "created")}
    values["category_id"] = _category_id(db, row["category_uid"])
    return _put(db, "entries", row["uid"], values)


def _apply_meta(db, row):
    if row["deleted"]:
        return db.execute("DELETE FROM meta WHERE key = ?", (row["key"],)).rowcount > 0
    if db.execute("UPDATE meta SET value = ? WHERE key = ? AND value IS NOT ?",
                  (row["value"], row["key"], row["value"])).rowcount:
        return True
    if db.execute("SELECT 1 FROM meta WHERE key = ?", (row["key"],)).fetchone():
        return False
    db.execute("INSERT INTO meta VALUES (?, ?)", (row["key"], row["value"]))
    return True


APPLY = {"categories": _apply_category, "rules": _apply_rule, "entries": _apply_entry,
         "meta": _apply_meta}


def _synced(db, cursor):
    _put_state(db, "cursor", cursor)
    _put_state(db, "first", None)
    _put_state(db, "last_sync", dt.datetime.now().isoformat(timespec="seconds"))


def apply(db, rows, pushed, cursor):
    """Write what the server sent, after the changes up to seq `pushed` went up. Rows changed
    here meanwhile are left alone: they go up next round and win. True if anything changed."""
    changed = False
    with db:
        db.execute("DELETE FROM sync_changes WHERE seq <= ?", (pushed,))
        mine = set(db.execute("SELECT tbl, uid FROM sync_changes"))
        before = _last_seq(db)
        for table, cols in COLUMNS.items():
            for row in rows.get(table, ()):
                if (table, row[cols[0]]) not in mine:
                    changed = APPLY[table](db, row) or changed
        db.execute("DELETE FROM sync_changes WHERE seq > ?", (before,))   # the triggers' notes
        _synced(db, cursor)
    return changed


def take(db, rows, cursor):
    """Replace everything here with the server's rows (a device's first sync)."""
    with db:
        for table in ("skips", "entries", "rules", "categories", "meta"):
            db.execute(f"DELETE FROM {table}")
        for table in COLUMNS:
            for row in rows.get(table, ()):
                APPLY[table](db, row)
        db.execute("DELETE FROM sync_changes")
        _synced(db, cursor)


# ---- a round: the local part, the network part (any thread), the local part

def job(db):
    """What the next round does, with what it sends."""
    first = state(db, "first")
    if first == "take":
        return {"do": "take"}
    if first == "replace":
        return {"do": "replace", "seq": _last_seq(db), "rows": snapshot(db)}
    seq, changes = pending(db)
    return {"do": "sync", "seq": seq, "changes": changes, "cursor": int(state(db, "cursor", 0))}


def exchange(server, todo):
    """The network part, on an open Remote: (rows to apply, the next cursor)."""
    if todo["do"] == "take":
        return server.everything()
    if todo["do"] == "replace":
        return {}, server.replace(todo["rows"])
    server.push(todo["changes"])
    return server.pull(todo["cursor"])


def finish(db, todo, rows, cursor):
    """True if this device's data changed."""
    if todo["do"] == "take":
        take(db, rows, cursor)
        return True
    return apply(db, rows, todo["seq"], cursor)


def run(db, server):
    """A whole round on an open Remote, here and now."""
    todo = job(db)
    return finish(db, todo, *exchange(server, todo))


class Syncer(QObject):
    """Runs rounds while sync is on: when Kaiji starts, a couple of seconds after each change, and
    every minute. The network part runs in a thread so the window never waits for the server;
    kaiji.db is only read and written on this one."""
    changed = Signal()                   # state, busy, last sync or report
    _done = Signal(object, object)

    def __init__(self, app):
        super().__init__()
        self.app = app
        self.state = "off"               # "off", "on", "offline" or "stopped"
        self.error = None                # the SyncError behind "offline" and "stopped"
        self.busy = False
        self.report = None               # (InfoBar kind, title, text) to show once
        self._manual = self._again = self._prepared = False
        self._thread = None
        self._round = 0                  # what a round finds changed is dropped after a stop
        self.timer = QTimer(self, interval=60_000, timeout=self.sync)
        self.later = QTimer(self, singleShot=True, interval=2_000, timeout=self.sync)
        self._done.connect(self._finish)

    def server(self, timeout=5):
        s = self.app.settings
        return Remote(s.sync_host, s.sync_port, s.sync_database, s.sync_user,
                      credentials.load() or "", s.sync_tls, timeout)

    def start(self):
        self._round += 1
        self.state, self.error, self.busy, self._prepared = "on", None, False, False
        self.timer.start()
        self.sync()

    def stop(self):
        """Stop, after any round under way (what it brings is dropped)."""
        self._round += 1
        self.timer.stop()
        self.later.stop()
        if self._thread and self._thread.is_alive():
            self._thread.join(5)
        self.state, self.error, self.busy = "off", None, False
        self.changed.emit()

    def soon(self):
        """Something changed here: a round in a moment (changes in a row go up together)."""
        if self.state in ("on", "offline"):
            self.later.start()

    def sync(self, manual=False):
        if self.state == "off" or (self.state == "stopped" and not manual):
            return
        self._manual = self._manual or manual
        if self.busy:
            self._again = True
            return
        self.later.stop()
        args = (self._round, self.server(), job(self.app.store.db), not self._prepared)
        self.busy, self._again = True, False
        self._thread = threading.Thread(target=self._work, args=args, daemon=True)
        self._thread.start()
        self.changed.emit()

    def _work(self, round_, server, todo, prepare):
        try:
            with server:
                if prepare:
                    server.prepare()
                result = exchange(server, todo)
        except SyncError as e:
            result = e
        except Exception as e:          # a bug: say so instead of losing the thread quietly
            result = SyncError("failed", f"{type(e).__name__}: {e}")
        self._done.emit((round_, todo, prepare), result)

    def _finish(self, info, result):
        round_, todo, prepared = info
        if round_ != self._round:
            return
        self.busy = False
        manual, self._manual = self._manual, False
        if isinstance(result, SyncError):
            before, self.error = self.state, result
            if result.kind == "offline":
                self.state = "offline"
                if manual:
                    self.report = ("warning", "Couldn't sync", str(result))
            else:
                # no point trying every minute until the settings or the server change
                self.state = "stopped"
                self.timer.stop()
                if before != "stopped" or manual:
                    self.report = ("error", "Sync stopped", str(result))
        else:
            self._prepared = self._prepared or prepared
            if self.state == "stopped":
                self.timer.start()
            self.state, self.error = "on", None
            if finish(self.app.store.db, todo, *result):
                self.app.remote_changed()
            if manual:
                self.report = ("success", "Synced", self.app.settings.sync_host)
        self.changed.emit()
        if self._again:
            self.sync()

    def flush(self):
        """Kaiji is closing: send what's waiting, giving the server a few seconds at most (not
        when the last round couldn't reach it: closing shouldn't wait for nothing)."""
        if self.state != "on":
            return
        if self._thread and self._thread.is_alive():
            self._thread.join(5)
            if self._thread.is_alive():
                return
        db = self.app.store.db
        if not waiting(db) and not state(db, "first"):
            return
        try:
            with self.server(timeout=3) as server:
                if not self._prepared:
                    server.prepare()
                run(db, server)
        except SyncError:
            pass                         # it goes up next time

    def describe(self):
        """The status line in Settings."""
        host = self.app.settings.sync_host
        db = self.app.store.db
        if self.state == "off":
            return "Off: your data is only on this PC"
        if self.state == "stopped":
            return f"Stopped: {self.error} Fix it with Change…, or try Sync now."
        if self.state == "offline":
            n = waiting(db)
            return (f"Can't reach {host} right now, trying again every minute."
                    + (f" {n} {'change waits' if n == 1 else 'changes wait'} to go up." if n else ""))
        last = last_sync(db)
        if last is None:
            return f"Connecting to {host}…"
        when = (f"at {last:%H:%M}" if last.date() == dt.date.today()
                else f"on {last:%Y/%m/%d} at {last:%H:%M}")
        return f"Synced with {host} {when}"
