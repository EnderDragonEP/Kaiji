"""Kaiji 花錢: the controller every page talks to (it owns the data and tells the pages when it
changes), and main()."""
import datetime as dt
import os
import sqlite3
import sys

from PySide6.QtCore import QLockFile, QObject, QTimer, Signal
from PySide6.QtWidgets import QApplication, QMessageBox

from . import cashew, fluent, money
from .config import APP_DIR, APP_NAME, APP_TITLE, BACKUP_DIR, DB_PATH, LOCK_PATH, Settings
from .icons import make_icon
from .ledger import DAY, Ledger, times_before
from .store import Category, Store

UNCATEGORIZED = Category(0, "expense", "Uncategorized", "TAG")


class Kaiji(QObject):
    data_changed = Signal()            # entries, repeating entries, categories or the plan changed
    settings_applied = Signal(object)  # set of changed setting names

    def __init__(self, qapp, settings, store):
        super().__init__()
        self.qapp, self.settings, self.store = qapp, settings, store
        self.ledger = Ledger(store)
        self._categories = self._notes = None
        money.configure(*store.currency())
        self.day = dt.date.today()
        # past midnight, "today" moves: planned entries become real and the views follow
        self.timer = QTimer(self, interval=30_000, timeout=self._tick)
        self.timer.start()
        from .main_window import MainWindow
        self.window = MainWindow(self)

    def _tick(self):
        if dt.date.today() != self.day:
            self.day = dt.date.today()
            self.data_changed.emit()

    # ---- reading
    def categories(self):
        if self._categories is None:
            self._categories = {c.id: c for c in self.store.categories()}
        return self._categories

    def category(self, category_id):
        return self.categories().get(category_id, UNCATEGORIZED)

    def kind_categories(self, kind):
        return [c for c in self.categories().values() if c.kind == kind]

    def rule(self, rule_id):
        return next((r for r in self.ledger.rules if r.id == rule_id), None)

    def notes(self):
        """{note: (kind, category_id)} from recent entries, for completing notes."""
        if self._notes is None:
            self._notes = self.store.recent_notes()
        return self._notes

    # ---- changing
    def changed(self):
        self.ledger.invalidate()
        self._categories = self._notes = None
        self.data_changed.emit()

    def save_entry(self, v, entry_id=None):
        """Add an entry, or a repeating entry when v["freq"] is set; replaces entry_id if given."""
        s = self.store
        if v["freq"]:
            if entry_id:
                s.delete_entry(entry_id)
            s.add_rule(v["kind"], v["amount"], v["category_id"], v["note"], v["freq"], v["every"],
                       v["day"], v["until"], v.get("times"))
        elif entry_id:
            s.update_entry(entry_id, v["day"], v["kind"], v["amount"], v["category_id"], v["note"])
        else:
            s.add_entry(v["day"], v["kind"], v["amount"], v["category_id"], v["note"])
        self.changed()

    def save_rule(self, rule_id, v):
        """Every date of a repeating entry changes."""
        self.store.update_rule(rule_id, v["kind"], v["amount"], v["category_id"], v["note"],
                               v["freq"], v["every"], v["day"], v["until"], v.get("times"))
        self.changed()

    def change_from(self, rule_id, v):
        """A repeating entry changes from v["day"] on: the old one ends the day before and a new
        one carries on (with the dates the old one skipped from then on, and v["times"] being
        the times left)."""
        rule = self.store.rule(rule_id)
        if v["day"] <= rule.start:
            return self.save_rule(rule_id, v)
        self._end_before(rule, v["day"])
        self.store.add_rule(v["kind"], v["amount"], v["category_id"], v["note"], v["freq"],
                            v["every"], v["day"], v["until"], v.get("times"),
                            skips=[d for d in rule.skips if d >= v["day"]])
        self.changed()

    def edit_date(self, rule_id, day, v):
        """Only one date of a repeating entry changes: it's skipped and an entry takes its place."""
        self.store.skip(rule_id, day)
        self.store.add_entry(v["day"], v["kind"], v["amount"], v["category_id"], v["note"])
        self.changed()

    def skip(self, rule_id, day):
        self.store.skip(rule_id, day)
        self.changed()

        def undo():
            self.store.unskip(rule_id, day)
            self.changed()
        return undo

    def _end_before(self, rule, day):
        """End a repeating entry before day: one that ends after a number of times keeps fewer
        times ("After 4 times" stays truthful), any other ends the day before."""
        until = rule.until if rule.until and rule.until < day else None
        if rule.times:
            self.store.set_rule_end(rule.id, until, times_before(rule, day))
        else:
            self.store.set_rule_end(rule.id, until or day - DAY)

    def stop_after(self, rule_id, day):
        rule = self.store.rule(rule_id)
        self._end_before(rule, day + DAY)
        self.changed()

        def undo():
            self.store.set_rule_end(rule_id, rule.until, rule.times)
            self.changed()
        return undo

    def delete_entry(self, entry_id):
        e = self.store.entry(entry_id)
        self.store.delete_entry(entry_id)
        self.changed()

        def undo():
            self.store.add_entry(e.day, e.kind, e.amount, e.category_id, e.note)
            self.changed()
        return undo

    def delete_rule(self, rule_id):
        r = self.store.rule(rule_id)
        self.store.delete_rule(rule_id)
        self.changed()

        def undo():
            self.store.add_rule(r.kind, r.amount, r.category_id, r.note, r.freq, r.every, r.start,
                                r.until, r.times, skips=r.skips)
            self.changed()
        return undo

    def set_plan(self, plan):
        self.store.set_plan(plan)
        self.changed()

    def set_currency(self, symbol, decimals):
        self.store.set_currency(symbol, decimals)
        money.configure(symbol, decimals)
        self.changed()

    def add_category(self, kind, name, icon):
        self.store.add_category(kind, name, icon)
        self.changed()

    def update_category(self, category_id, name, icon):
        self.store.update_category(category_id, name, icon)
        self.changed()

    def move_category(self, category_id, step):
        self.store.move_category(category_id, step)
        self.changed()

    def delete_category(self, category_id, move_to=None):
        self.store.delete_category(category_id, move_to)
        self.changed()

    def restore(self, path):
        """Replace everything with a backup, after keeping a copy of what's there now."""
        os.makedirs(BACKUP_DIR, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y-%m-%d %H%M%S")
        self.store.backup_to(os.path.join(BACKUP_DIR, f"before restore {stamp}.db"))
        self.store.restore_from(path)
        money.configure(*self.store.currency())
        self.changed()

    def import_cashew(self, plan, currency=None):
        """Bring in a planned Cashew import (see cashew.py), after keeping a copy of what's here
        now; currency: (symbol, decimals) to switch to, or None."""
        os.makedirs(BACKUP_DIR, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y-%m-%d %H%M%S")
        self.store.backup_to(os.path.join(BACKUP_DIR, f"before Cashew import {stamp}.db"))
        if currency:
            self.store.set_currency(*currency)
            money.configure(*currency)
        cashew.apply(self.store, plan)
        self.changed()

    def apply_settings(self, keys):
        """React to settings the Settings page just changed."""
        keys = set(keys)
        if "theme" in keys:
            fluent.apply_theme(self.settings.theme)
        if "accent_color" in keys:
            fluent.apply_accent(self.settings.accent_color)
        self.settings_applied.emit(keys)


def main():
    try:
        # its own taskbar button and icon, not python's, when run with pythonw
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(APP_NAME)
    except (AttributeError, OSError):
        pass
    QApplication.setApplicationName(APP_NAME)
    QApplication.setApplicationDisplayName(APP_TITLE)
    qapp = QApplication(sys.argv)
    settings = Settings.load()
    fluent.setup(qapp, settings)
    qapp.setWindowIcon(make_icon())

    os.makedirs(APP_DIR, exist_ok=True)
    lock = QLockFile(LOCK_PATH)
    if not lock.tryLock(100):
        QMessageBox.information(None, APP_TITLE, "Kaiji is already open.")
        return 0
    store = Store(DB_PATH, money.locale_defaults())
    try:
        store.auto_backup(BACKUP_DIR)
    except (OSError, sqlite3.Error):
        pass                      # a missed daily copy shouldn't keep the app from starting

    app = Kaiji(qapp, settings, store)
    app.window.show()
    if not settings.welcomed:
        QTimer.singleShot(500, app.window.welcome)
    return qapp.exec()
