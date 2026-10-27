"""Cashew compatibility. Cashew (github.com/jameskokoska/Cashew) is an open-source budgeting app.
This reads its backup - "Export data file", the app's SQLite database saved as
cashew-<date>.sql - into Kaiji, and writes Kaiji's entries as a CSV in the layout of Cashew's
own export, which Cashew's "Import CSV" maps by itself.

How Cashew's data fits Kaiji's: Cashew keeps a row per transaction with a signed amount
(expenses negative) and its date as Unix seconds. A repeating payment is its next, unpaid date
plus how often it repeats; every paid date becomes a row of its own. So paid rows become
entries, the unpaid next date of a subscription becomes a repeating entry from that date, and
unpaid one-off ("upcoming") rows become planned entries. Kaiji has one balance for all
accounts, so a transfer between two imported accounts cancels out and is left out. What an
import brings in is tagged, and importing again replaces it rather than adding it twice."""
import csv
import dataclasses
import datetime as dt
import decimal
import pathlib
import re
import sqlite3
from collections import Counter, defaultdict

from . import money
from .ledger import DAY, next_date, occurrences
from .store import Rule

SOURCE = "cashew"                 # imported rows carry source "cashew:<transaction_pk>"
UPCOMING, SUBSCRIPTION, REPETITIVE, CREDIT, DEBT = range(5)   # Cashew's TransactionSpecialType
FREQS = {1: "day", 2: "week", 3: "month", 4: "year"}          # its BudgetReoccurence (0: custom)
CORRECTION = "0"                  # its reserved category for balance corrections and transfers
MAX_SKIPS = 60                    # past unpaid dates of a subscription kept out as skips
NOT_CASHEW = "This file isn't a Cashew backup. In Cashew, use Export data file to make one."
CSV_HEADERS = ["account", "amount", "currency", "title", "note", "date", "income", "type",
               "category name", "subcategory name", "color", "icon", "emoji", "budget", "objective"]
COLUMNS = {
    "transactions": ["transaction_pk", "paired_transaction_fk", "name", "amount", "note",
                     "category_fk", "wallet_fk", "date_created", "period_length", "reoccurrence",
                     "end_date", "type", "paid", "skip_paid"],
    "categories": ["category_pk", "name", "icon_name"],
    "wallets": ["wallet_pk", "name", "currency", "decimals", "order"],
}
# words in Cashew's icon file names (cutlery.png, tram.png...) and the Kaiji icon for them
ICON_WORDS = [
    ({"cutlery", "food", "restaurant", "dining", "coffee", "cafe", "pizza", "burger", "noodle",
      "drink", "tea", "bread", "cake", "lunch", "dinner", "breakfast"}, "CAFE"),
    ({"grocer", "cart", "basket", "supermarket", "shop", "shopping", "bag", "cloth", "shirt",
      "shoe", "dress"}, "SHOPPING_CART"),
    ({"tram", "bus", "metro", "subway", "transit"}, "BUS"),
    ({"car", "taxi", "fuel", "gas", "parking"}, "CAR"),
    ({"train", "rail"}, "TRAIN"),
    ({"plane", "flight", "travel", "luggage", "airplane"}, "AIRPLANE"),
    ({"house", "home", "rent", "building"}, "HOME"),
    ({"bill", "receipt", "invoice", "tax", "fee"}, "DOCUMENT"),
    ({"phone", "mobile"}, "PHONE"),
    ({"wifi", "internet"}, "WIFI"),
    ({"electric", "bulb", "power", "light"}, "BRIGHTNESS"),
    ({"popcorn", "movie", "film", "cinema", "ticket"}, "MOVIE"),
    ({"game", "controller"}, "GAME"),
    ({"music", "headphone"}, "MUSIC"),
    ({"health", "medic", "pill", "hospital", "doctor", "heart", "tooth"}, "HEART"),
    ({"education", "graduation", "book", "school", "study"}, "EDUCATION"),
    ({"gift", "present"}, "PEOPLE"),
    ({"flower", "beauty", "makeup", "salon", "barber", "hair", "nail"}, "CUT"),
    ({"sport", "gym", "ball", "fitness"}, "BASKETBALL"),
    ({"pet", "dog", "cat", "paw", "plant", "leaf"}, "LEAF"),
    ({"camera", "photo"}, "CAMERA"),
    ({"briefcase", "work", "office", "laptop", "computer"}, "DEVELOPER_TOOLS"),
    ({"invest", "stock", "chart", "graph"}, "MARKET"),
    ({"insurance", "shield"}, "VPN"),
    ({"coin", "money", "cash", "salary", "wallet", "bank", "dollar", "income"}, "CERTIFICATE"),
]


def kaiji_icon(icon_name):
    """The Kaiji icon closest to a Cashew icon file name; TAG when nothing fits."""
    spaced = re.sub(r"([a-z])([A-Z])", r"\1 \2", icon_name or "")
    words = re.findall(r"[a-z]+", spaced.lower())
    for keys, icon in ICON_WORDS:
        for word in words:
            if any(word in (k, k + "s", k + "es") or (len(k) >= 5 and word.startswith(k))
                   for k in keys):
                return icon
    return "TAG"


def _seconds(value):
    """Unix seconds of a Cashew date: drift stores seconds (or ISO text with another option)."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value / 1000 if value > 10 ** 11 else float(value)     # milliseconds, just in case
    try:
        moment = dt.datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment.timestamp()


def _date(value):
    seconds = _seconds(value)
    if seconds is None:
        return None
    try:
        return dt.datetime.fromtimestamp(seconds).date()        # the day it was where you are
    except (OverflowError, OSError, ValueError):
        return None


def _cents(amount):
    try:
        value = decimal.Decimal(str(amount or 0)).copy_abs() * 100
    except decimal.InvalidOperation:
        return 0
    return int(value.quantize(decimal.Decimal(1), decimal.ROUND_HALF_UP))


@dataclasses.dataclass
class Wallet:
    pk: str
    name: str
    currency: str                 # ISO code in capitals, "" when Cashew doesn't say
    decimals: int
    count: int                    # transactions in it


@dataclasses.dataclass
class Backup:
    wallets: list
    categories: dict              # pk -> (name, icon file name)
    rows: list                    # transactions as dicts of COLUMNS["transactions"]


@dataclasses.dataclass
class Plan:
    """What an import would bring in. entries: (day, kind, cents, category, note, source);
    rules: (kind, cents, category, note, freq, every, start, until, skips, source); left_out:
    rows by the reason they stay out. Categories are (name, kind, Kaiji icon) until they're
    matched to Kaiji's or added."""
    entries: list = dataclasses.field(default_factory=list)
    rules: list = dataclasses.field(default_factory=list)
    left_out: Counter = dataclasses.field(default_factory=Counter)

    def categories(self):
        return {e[3] for e in self.entries} | {r[2] for r in self.rules}


def _columns(db, table):
    return {row[1] for row in db.execute(f'PRAGMA table_info("{table}")')}


def _select(db, table, have):
    """All COLUMNS of table as dicts; a column an older Cashew didn't have reads as None."""
    wanted = COLUMNS[table]
    fields = ", ".join(f'"{c}"' if c in have else f'NULL AS "{c}"' for c in wanted)
    return [dict(zip(wanted, row)) for row in db.execute(f'SELECT {fields} FROM "{table}"')]


def read_backup(path):
    """The accounts, categories and transactions in a Cashew backup; ValueError otherwise."""
    try:
        db = sqlite3.connect(pathlib.Path(path).resolve().as_uri() + "?mode=ro", uri=True)
    except sqlite3.Error as e:
        raise ValueError(NOT_CASHEW) from e
    try:
        try:
            have = {table: _columns(db, table) for table in COLUMNS}
            if not ({"transaction_pk", "amount", "date_created", "category_fk"} <= have["transactions"]
                    and "category_pk" in have["categories"]):
                raise ValueError(NOT_CASHEW)
            rows = _select(db, "transactions", have["transactions"])
            categories = {r["category_pk"]: ((r["name"] or "").strip(), r["icon_name"])
                          for r in _select(db, "categories", have["categories"])}
            wallets = _select(db, "wallets", have["wallets"]) if have["wallets"] else []
        except sqlite3.DatabaseError as e:
            raise ValueError(NOT_CASHEW) from e
    finally:
        db.close()
    for r in rows:
        r["wallet_fk"] = str(r["wallet_fk"] if r["wallet_fk"] is not None else "0")
    counts = Counter(r["wallet_fk"] for r in rows)
    known = {str(w["wallet_pk"]) for w in wallets}
    wallets = [Wallet(str(w["wallet_pk"]), (w["name"] or "Account").strip(),
                      (w["currency"] or "").upper(), 0 if w["decimals"] == 0 else 2,
                      counts[str(w["wallet_pk"])])
               for w in sorted(wallets, key=lambda w: (w["order"] or 0))]
    # transactions in an account the backup has no row for still get one
    wallets += [Wallet(pk, "Account" if pk != "0" else "Main", "", 2, n)
                for pk, n in sorted(counts.items()) if pk not in known]
    return Backup(wallets, categories, rows)


def _transfers(rows, chosen):
    """Transaction pks of transfers with both halves in chosen accounts: together they cancel
    out. Newer Cashew pairs the halves; older ones are two balance corrections in the same
    minute with opposite amounts."""
    by_pk = {r["transaction_pk"]: r for r in rows}
    out = set()
    for r in rows:
        other = by_pk.get(r["paired_transaction_fk"])
        if other and r["wallet_fk"] != other["wallet_fk"] and \
                {r["wallet_fk"], other["wallet_fk"]} <= chosen:
            out |= {r["transaction_pk"], other["transaction_pk"]}
    loose = defaultdict(list)
    for r in rows:
        seconds = _seconds(r["date_created"])
        if r["category_fk"] == CORRECTION and r["transaction_pk"] not in out and seconds \
                and r["wallet_fk"] in chosen and r["amount"]:
            loose[(_cents(r["amount"]), int(seconds // 60))].append(r)
    for group in loose.values():
        negatives = [r for r in group if r["amount"] < 0]
        positives = [r for r in group if r["amount"] > 0]
        for neg in negatives:
            match = next((p for p in positives if p["wallet_fk"] != neg["wallet_fk"]), None)
            if match:
                positives.remove(match)
                out |= {neg["transaction_pk"], match["transaction_pk"]}
    return out


def plan_import(backup, wallet_pks, today):
    """What importing the chosen accounts would bring in, as of today."""
    chosen = set(wallet_pks)
    transfers = _transfers(backup.rows, chosen)
    plan, series = Plan(), set()
    rows = [r for r in backup.rows if r["wallet_fk"] in chosen]
    for r in sorted(rows, key=lambda r: (_seconds(r["date_created"]) or 0, str(r["transaction_pk"]))):
        day, cents = _date(r["date_created"]), _cents(r["amount"])
        if day is None:
            plan.left_out["unreadable"] += 1
            continue
        if not cents:
            plan.left_out["zero"] += 1
            continue
        if r["transaction_pk"] in transfers:
            plan.left_out["transfer"] += 1
            continue
        kind = "income" if r["amount"] > 0 else "expense"
        name, icon = backup.categories.get(r["category_fk"], ("", None))
        if r["category_fk"] == CORRECTION:
            name, icon = name or "Balance correction", "EDIT"
        else:
            icon = kaiji_icon(icon)
        category = (name or "Other", kind, icon)
        note = " · ".join(p for p in ((r["name"] or "").strip(), (r["note"] or "").strip()) if p)
        source = f"{SOURCE}:{r['transaction_pk']}"
        paid, special = bool(r["paid"]), r["type"]
        if special in (CREDIT, DEBT):
            # a loan counts while it's open; once it's paid back Cashew stops counting it
            if paid:
                plan.entries.append((day, kind, cents, category, note, source))
            else:
                plan.left_out["settled loan"] += 1
            continue
        if paid:
            plan.entries.append((day, kind, cents, category, note, source))
            continue
        if r["skip_paid"]:
            plan.left_out["skipped"] += 1
            continue
        freq = FREQS.get(r["reoccurrence"]) if special in (SUBSCRIPTION, REPETITIVE) else None
        if not freq:
            if day >= today:
                plan.entries.append((day, kind, cents, category, note, source))   # planned
            else:
                plan.left_out["unpaid"] += 1
            continue
        every = max(1, r["period_length"] or 1)
        key = (note, cents, category, freq, every, r["wallet_fk"])
        if key in series:
            plan.left_out["duplicate"] += 1
            continue
        series.add(key)
        until = _date(r["end_date"])
        rule = Rule(0, kind, cents, None, note, freq, every, day, until)
        # dates before today that weren't paid in Cashew didn't happen
        skips = occurrences(rule, day, today - DAY) if day < today else []
        start = day
        if len(skips) > MAX_SKIPS:
            start, skips = next_date(rule, today), []
        if start is None or (until and until < start):
            plan.left_out["ended"] += 1
            continue
        plan.rules.append((kind, cents, category, note, freq, every, start, until, skips, source))
    return plan


def apply(store, plan):
    """Put a planned import into Kaiji, replacing what the last Cashew import brought in.
    Categories are matched by name and kind, or added."""
    existing = {(c.kind, c.name.casefold()): c.id for c in store.categories()}
    ids = {}
    for name, kind, icon in sorted(plan.categories()):
        key = (kind, name.casefold())
        if key not in existing:
            existing[key] = store.add_category(kind, name, icon)
        ids[(name, kind, icon)] = existing[key]
    entries = [(d, k, c, ids[cat], note, src) for d, k, c, cat, note, src in plan.entries]
    rules = [(k, c, ids[cat], note, f, every, start, until, None, skips, src)
             for k, c, cat, note, f, every, start, until, skips, src in plan.rules]
    store.replace_imported(SOURCE, entries, rules)


def new_categories(store, plan):
    """How many of the plan's categories Kaiji doesn't have yet."""
    existing = {(c.kind, c.name.casefold()) for c in store.categories()}
    return len({(kind, name.casefold()) for name, kind, _ in plan.categories()} - existing)


def export_csv(path, ledger, category_name, start, end):
    """Kaiji's entries and repeating dates from start to end as a CSV in the layout of Cashew's
    own export. Entries that came from Cashew stay out, so nothing goes back twice. Returns the
    number of rows."""
    entry_ids, rule_ids = ledger.store.imported_ids(SOURCE)
    items = [i for i in ledger.items(start, end)
             if not (i.entry_id in entry_ids or i.rule_id in rule_ids)]
    code = next((c for c, s in money.SYMBOLS.items() if s == money.symbol()), "")
    # utf-8 without a BOM and "\n" line ends: Cashew splits its CSV on "\n"
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(CSV_HEADERS)
        for i in items:
            amount = decimal.Decimal(i.signed) / 100
            w.writerow(["", f"{amount:.2f}", code, i.note, "", f"{i.day.isoformat()} 00:00:00.000",
                        "true" if i.kind == "income" else "false", "null",
                        category_name(i.category_id), "", "", "", "", "", ""])
    return len(items)
