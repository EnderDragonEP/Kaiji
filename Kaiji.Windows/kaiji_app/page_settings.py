"""Settings with QFluentWidgets setting cards; changes apply as soon as they're made."""
import csv
import datetime as dt
import os

from PySide6.QtCore import QDate, Qt, QTimer
from PySide6.QtGui import QColor
from PySide6.QtWidgets import QFileDialog, QHBoxLayout, QWidget
from qfluentwidgets import (
    BodyLabel, CalendarPicker, ColorDialog, ComboBox, EditableComboBox, ExpandGroupSettingCard,
    ExpandLayout, FluentIcon as FIF, IconWidget, InfoBar, InfoBarPosition, PushButton, SettingCard,
    SettingCardGroup, ToolTipFilter, TransparentToolButton, themeColor,
)

from . import credentials, money, sync
from .config import APP_DIR, APP_TITLE, APP_VERSION, BACKUP_DIR
from .dialogs import (
    DECIMALS, CategoryDialog, DeleteCategoryDialog, FirstSyncDialog, SyncDialog, confirm,
)
from .fluent import AmountEdit, Page, category_icon
from .icons import make_icon
from .ledger import DAY, describe_rule
from .store import Plan

THEMES = [("system", "Use system setting"), ("light", "Light"), ("dark", "Dark")]
ACCENTS = [("", "Windows accent color"), ("custom", "Custom color")]
BASES = [("income", "This month's income"), ("balance", "Everything I have")]
WEEK_STARTS = [(0, "Monday"), (6, "Sunday")]


def choice_box(choices, current):
    """ComboBox over (value, text)."""
    box = ComboBox()
    for value, text in choices:
        box.addItem(text, userData=value)
    values = [v for v, _ in choices]
    box.setCurrentIndex(values.index(current) if current in values else 0)
    return box


def card(icon, title, content, *controls):
    """A SettingCard with the controls on its right."""
    c = SettingCard(icon, title, content)
    # the text takes the free width and wraps only when the controls need the room
    c.contentLabel.setWordWrap(True)
    c.vBoxLayout.setAlignment(c.contentLabel, Qt.AlignmentFlag(0))
    for i in reversed(range(c.hBoxLayout.count())):
        spacer = c.hBoxLayout.itemAt(i).spacerItem()
        if spacer and spacer.expandingDirections() & Qt.Horizontal:
            c.hBoxLayout.takeAt(i)               # the card's own stretch: the text gets that room
    c.hBoxLayout.setStretchFactor(c.vBoxLayout, 1)
    for control in controls:
        c.hBoxLayout.addWidget(control, 0, Qt.AlignRight)
        c.hBoxLayout.addSpacing(8)
    c.hBoxLayout.addSpacing(8)
    return c


def tool(icon, tip, slot, enabled=True):
    b = TransparentToolButton(icon)
    b.setToolTip(tip)
    b.installEventFilter(ToolTipFilter(b))
    b.setEnabled(enabled)
    b.clicked.connect(slot)
    return b


class SettingsPage(Page):
    def __init__(self, app, window):
        super().__init__("settings", "Settings", layout=False)
        self.app, self.window, self.s = app, window, app.settings
        self._save_timer = QTimer(self, singleShot=True, interval=400)
        self._save_timer.timeout.connect(self.s.save)
        self._currency_timer = QTimer(self, singleShot=True, interval=600)
        self._currency_timer.timeout.connect(self._currency_changed)
        app.qapp.aboutToQuit.connect(self._flush)

        self.groups = ExpandLayout(self.view)
        self.groups.setSpacing(28)
        self.groups.setContentsMargins(36, 0, 36, 36)
        for group in (self._plan(), self._currency(), self._categories(), self._calendar(),
                      self._data(), self._sync(), self._personalization(), self._about()):
            self.groups.addWidget(group)
        app.data_changed.connect(self._data_changed)

    # ---- plumbing
    def _set(self, **fields):
        changed = {k for k, v in fields.items() if getattr(self.s, k) != v}
        for k in changed:
            setattr(self.s, k, fields[k])
        if changed:
            self._save_timer.start()
            self.app.apply_settings(changed)
        return changed

    def _flush(self):
        if self._save_timer.isActive():
            self._save_timer.stop()
            self.s.save()

    def _tell(self, kind, title, content=""):
        getattr(InfoBar, kind)(title, content, duration=4000 if kind != "error" else 7000,
                               position=InfoBarPosition.TOP_RIGHT, parent=self.window)

    def _data_changed(self):
        """Something else changed the plan, the currency or the categories (the first-run
        setup, a restored backup): show what's saved now."""
        self._load_plan()
        symbol, decimals = self.app.store.currency()
        if self.symbol.text() != symbol and not self._currency_timer.isActive():
            self.symbol.setText(symbol)
        self.decimals.blockSignals(True)
        self.decimals.setCurrentIndex(0 if decimals == 0 else 1)
        self.decimals.blockSignals(False)
        for kind in self.category_cards:
            self._fill_categories(kind)

    # ---- plan
    def _plan(self):
        group = SettingCardGroup("Your plan", self.view)
        self.start_amount = AmountEdit(allow_negative=True)
        self.start_amount.setPlaceholderText("Not set")
        self.start_date = CalendarPicker()
        self.start_date.setDateFormat("yyyy/MM/dd")
        self.goal = AmountEdit()
        self.floor = AmountEdit()
        for edit in (self.start_amount, self.goal, self.floor):
            edit.setFixedWidth(170)
            edit.editingFinished.connect(self._plan_changed)
        self.start_date.dateChanged.connect(self._plan_changed)
        self.basis = choice_box(BASES, "income")
        self.basis.currentIndexChanged.connect(self._plan_changed)
        self._load_plan()
        group.addSettingCard(card(FIF.FLAG, "Starting balance",
                                  "What you had at the start of this day, all accounts together. "
                                  "Every other day's balance is worked out from it.",
                                  self.start_date, self.start_amount))
        group.addSettingCard(card(FIF.PIE_SINGLE, "Left to spend comes from",
                                  "This month's income minus its expenses and your savings goal, or "
                                  "everything you have above the minimum below",
                                  self.basis))
        group.addSettingCard(card(FIF.LEAF, "Monthly savings goal",
                                  "Set aside from each month's income and not counted as money to "
                                  "spend", self.goal))
        group.addSettingCard(card(FIF.VPN, "Keep at least",
                                  "Kaiji warns you when your balance is heading below this, and never "
                                  "counts it as money to spend", self.floor))
        return group

    def _load_plan(self):
        p = self.app.ledger.plan
        for w in (self.start_amount, self.start_date, self.goal, self.floor, self.basis):
            w.blockSignals(True)
        self.start_amount.set_value(p.start_balance if p.start_date else None)
        self.start_date.setDate(QDate(p.start_date or dt.date.today()))
        self.goal.set_value(p.savings_goal or None)
        self.floor.set_value(p.min_balance or None)
        self.basis.setCurrentIndex(0 if p.basis == "income" else 1)
        for w in (self.start_amount, self.start_date, self.goal, self.floor, self.basis):
            w.blockSignals(False)

    def _plan_changed(self, *_):
        edits = (self.start_amount, self.goal, self.floor)
        if not all(e.is_valid() for e in edits):
            return
        has_start = not self.start_amount.is_empty()
        plan = Plan(start_balance=self.start_amount.value() or 0,
                    start_date=self.start_date.getDate().toPython() if has_start else None,
                    savings_goal=self.goal.value() or 0, min_balance=self.floor.value() or 0,
                    basis=self.basis.currentData())
        if plan != self.app.ledger.plan:
            self.app.set_plan(plan)

    # ---- currency
    def _currency(self):
        group = SettingCardGroup("Currency", self.view)
        symbol, decimals = self.app.store.currency()
        self.symbol = EditableComboBox()
        self.symbol.addItems(money.CURRENCIES if symbol in money.CURRENCIES
                             else [symbol] + money.CURRENCIES)
        self.symbol.setText(symbol)
        self.symbol.setFixedWidth(120)
        self.symbol.currentTextChanged.connect(lambda _: self._currency_timer.start())
        self.decimals = choice_box(DECIMALS, 0 if decimals == 0 else 2)
        self.decimals.currentIndexChanged.connect(lambda _: self._currency_changed())
        group.addSettingCard(card(FIF.TAG, "Currency symbol", "Shown in front of every amount",
                                  self.symbol))
        group.addSettingCard(card(FIF.UNIT, "Decimals",
                                  "How amounts are shown; cents you enter are always kept",
                                  self.decimals))
        return group

    def _currency_changed(self):
        self._currency_timer.stop()
        symbol = self.symbol.text().strip()
        if symbol and (symbol, self.decimals.currentData()) != self.app.store.currency():
            self.app.set_currency(symbol, self.decimals.currentData())

    # ---- categories
    def _categories(self):
        group = SettingCardGroup("Categories", self.view)
        self.category_cards = {}
        for kind, icon, title, content in (
                ("expense", FIF.SHOPPING_CART, "Expense categories", "Where your money goes"),
                ("income", FIF.MARKET, "Income categories", "Where your money comes from")):
            c = ExpandGroupSettingCard(icon, title, content, group)
            self.category_cards[kind] = c
            self._fill_categories(kind)
            group.addSettingCard(c)
        return group

    def _fill_categories(self, kind):
        c = self.category_cards[kind]
        cats = self.app.kind_categories(kind)
        shown = [(cat.id, cat.name, cat.icon) for cat in cats]
        if getattr(c, "shown", None) == shown:
            return                                   # entries changed, the categories didn't
        c.shown = shown
        for w in list(c.widgets):
            c.removeGroupWidget(w)
            w.hide()
            w.deleteLater()
        for i, cat in enumerate(cats):
            c.addGroupWidget(self._category_row(cat, i, len(cats)))
        add = PushButton(FIF.ADD, "Add category")
        add.clicked.connect(lambda: self._add_category(kind))
        w = QWidget()
        box = QHBoxLayout(w)
        box.setContentsMargins(48, 10, 48, 10)
        box.addWidget(add)
        box.addStretch(1)
        c.addGroupWidget(w)

    def _category_row(self, cat, index, count):
        w = QWidget()
        box = QHBoxLayout(w)
        box.setContentsMargins(48, 6, 44, 6)
        box.setSpacing(4)
        icon = IconWidget(category_icon(cat.icon))
        icon.setFixedSize(16, 16)
        box.addWidget(icon)
        box.addSpacing(12)
        box.addWidget(BodyLabel(cat.name))
        box.addStretch(1)
        app = self.app
        box.addWidget(tool(FIF.UP, "Move up", lambda: app.move_category(cat.id, -1), index > 0))
        box.addWidget(tool(FIF.DOWN, "Move down", lambda: app.move_category(cat.id, 1), index < count - 1))
        box.addWidget(tool(FIF.EDIT, "Rename or change the icon", lambda: self._edit_category(cat)))
        box.addWidget(tool(FIF.DELETE, "Delete", lambda: self._delete_category(cat)))
        return w

    def _add_category(self, kind):
        dialog = CategoryDialog(self.window, "New expense category" if kind == "expense"
                                else "New income category")
        if dialog.exec():
            self.app.add_category(kind, *dialog.values())

    def _edit_category(self, cat):
        dialog = CategoryDialog(self.window, "Edit category", cat.name, cat.icon)
        if dialog.exec():
            self.app.update_category(cat.id, *dialog.values())

    def _delete_category(self, cat):
        uses = self.app.store.category_uses(cat.id)
        others = [c for c in self.app.kind_categories(cat.kind) if c.id != cat.id]
        if not uses:
            if confirm(self.window, f"Delete “{cat.name}”?", "No entries use it."):
                self.app.delete_category(cat.id)
            return
        if not others:
            self._tell("warning", "Can't delete the last category",
                       "Add another one first, so its entries have somewhere to go.")
            return
        dialog = DeleteCategoryDialog(self.window, cat, uses, others)
        if dialog.exec():
            self.app.delete_category(cat.id, dialog.move_to())

    # ---- calendar
    def _calendar(self):
        group = SettingCardGroup("Calendar", self.view)
        week = choice_box(WEEK_STARTS, self.s.week_start)
        week.currentIndexChanged.connect(lambda _: self._set(week_start=week.currentData()))
        group.addSettingCard(card(FIF.CALENDAR, "First day of the week",
                                  "The calendar's first column", week))
        return group

    # ---- data
    def _data(self):
        group = SettingCardGroup("Your data", self.view)
        export = PushButton(FIF.DOWNLOAD, "Export…")
        export.clicked.connect(self._export_all)
        group.addSettingCard(card(FIF.DOCUMENT, "Export to CSV",
                                  "Every entry, and the dates of repeating entries up to a year "
                                  "ahead, for Excel or another app", export))
        backup = PushButton(FIF.SAVE, "Back up…")
        backup.clicked.connect(self._backup)
        restore = PushButton(FIF.HISTORY, "Restore…")
        restore.clicked.connect(self._restore)
        group.addSettingCard(card(FIF.SAVE_COPY, "Backup",
                                  "Save a copy of all your data, or bring one back. Kaiji also "
                                  "keeps a copy of each of the last 10 days you used it.",
                                  restore, backup))
        folder = PushButton(FIF.FOLDER, "Open folder")
        folder.clicked.connect(lambda: os.startfile(APP_DIR))
        group.addSettingCard(card(FIF.FOLDER, "Data folder", APP_DIR, folder))
        return group

    def _export_all(self):
        today = dt.date.today()
        path, _ = QFileDialog.getSaveFileName(self, "Export CSV", f"kaiji {today.isoformat()}.csv",
                                              "CSV (*.csv)")
        if not path:
            return
        first = self.app.store.first_day() or today
        items = self.app.ledger.items(first, today + 366 * DAY)
        try:
            with open(path, "w", newline="", encoding="utf-8-sig") as f:
                w = csv.writer(f)
                w.writerow(["Date", "Type", "Category", "Amount", "Note", "Repeats", "Planned"])
                for item in items:
                    rule = self.app.rule(item.rule_id) if item.repeating else None
                    w.writerow([item.day.isoformat(), item.kind.capitalize(),
                                self.app.category(item.category_id).name, money.plain(item.signed),
                                item.note, describe_rule(rule) if rule else "",
                                "yes" if item.day > today else ""])
        except OSError as e:
            self._tell("error", "Couldn't save the file", str(e))
        else:
            self._tell("success", "Exported", f"{len(items)} entries · {path}")

    def _backup(self):
        name = f"Kaiji backup {dt.date.today().isoformat()}.db"
        path, _ = QFileDialog.getSaveFileName(self, "Back up", name, "Kaiji backup (*.db)")
        if not path:
            return
        try:
            self.app.store.backup_to(path)
        except Exception as e:      # sqlite3 and OS errors alike
            self._tell("error", "Couldn't save the backup", str(e))
        else:
            self._tell("success", "Backed up", path)

    def _restore(self):
        path, _ = QFileDialog.getOpenFileName(self, "Restore a backup", BACKUP_DIR,
                                              "Kaiji backup (*.db)")
        also = (" Sync is on, so the server and your other devices get the backup's data too."
                if self.s.sync else "")
        if not path or not confirm(self.window, "Restore this backup?",
                                   "Everything in Kaiji now is replaced by the backup. A copy of what's "
                                   "there now goes to the backups folder first." + also, "Restore"):
            return
        try:
            self.app.restore(path)
        except Exception as e:      # not a Kaiji backup, or unreadable
            self._tell("error", "Couldn't restore", str(e))
        else:
            self._tell("success", "Restored", os.path.basename(path))

    # ---- sync
    def _sync(self):
        group = SettingCardGroup("Sync", self.view)
        self.sync_setup = PushButton(FIF.EDIT, "Set up…")
        self.sync_setup.clicked.connect(self._setup_sync)
        self.sync_now = PushButton(FIF.SYNC, "Sync now")
        self.sync_now.clicked.connect(lambda: self.app.syncer.sync(manual=True))
        self.sync_off = PushButton("Turn off")
        self.sync_off.clicked.connect(self._stop_sync)
        self.sync_card = card(FIF.CLOUD, "Sync with PostgreSQL", "", self.sync_off, self.sync_now,
                              self.sync_setup)
        group.addSettingCard(self.sync_card)
        self.app.syncer.changed.connect(self._sync_changed)
        self._sync_changed()
        return group

    def _sync_changed(self):
        syncer = self.app.syncer
        on = syncer.state != "off"
        self.sync_card.setContent(syncer.describe())
        self.sync_setup.setText("Change…" if on else "Set up…")
        self.sync_now.setVisible(on)
        self.sync_now.setEnabled(not syncer.busy)
        self.sync_off.setVisible(on)
        if syncer.report:
            self._tell(*syncer.report)
            syncer.report = None

    def _setup_sync(self):
        s = self.s
        dialog = SyncDialog(self.window, s, (credentials.load() or "") if s.sync else "")
        if not dialog.exec():
            return
        v = dialog.values()
        same = s.sync and all(getattr(s, k) == v[k] for k in ("sync_host", "sync_port",
                                                              "sync_database"))
        if same:
            first = None                   # carry on with the same server
        elif dialog.server_empty:
            first = "replace"
        elif not sync.has_own_data(self.app.store.db):
            first = "take"
        else:
            choice = FirstSyncDialog(self.window, v["sync_host"])
            if not choice.exec():
                return
            first = choice.choice()
        self.app.start_sync(v, dialog.password.text(), first)

    def _stop_sync(self):
        if confirm(self.window, "Turn off sync?",
                   "Kaiji on this PC keeps its data, and so does the server, but they no longer "
                   "share changes. The saved password is removed.", "Turn off"):
            self.app.stop_sync()

    # ---- personalization
    def _personalization(self):
        group = SettingCardGroup("Personalization", self.view)
        mode = choice_box(THEMES, self.s.theme)
        mode.currentIndexChanged.connect(lambda _: self._set(theme=mode.currentData()))
        group.addSettingCard(card(FIF.BRUSH, "App theme", "Light or dark, or follow Windows", mode))
        self.accent = choice_box(ACCENTS, "custom" if self.s.accent_color else "")
        self.pick_color = PushButton("Choose color")
        self.pick_color.setEnabled(bool(self.s.accent_color))
        self.pick_color.clicked.connect(self._choose_color)
        self.accent.currentIndexChanged.connect(self._accent_changed)
        group.addSettingCard(card(FIF.PALETTE, "Accent color",
                                  "Used for buttons, today in the calendar and the progress ring",
                                  self.pick_color, self.accent))
        return group

    def _accent_changed(self, _):
        custom = self.accent.currentData() == "custom"
        self.pick_color.setEnabled(custom)
        if not custom:
            self._set(accent_color="")
        elif not self.s.accent_color:
            self._choose_color()

    def _choose_color(self):
        dialog = ColorDialog(QColor(self.s.accent_color) if self.s.accent_color else themeColor(),
                             "Accent color", self.window)
        dialog.colorChanged.connect(lambda c: self._set(accent_color=c.name()))
        dialog.exec()
        if not self.s.accent_color:             # cancelled without picking: stay on Windows'
            self.accent.blockSignals(True)
            self.accent.setCurrentIndex(0)
            self.accent.blockSignals(False)
            self.pick_color.setEnabled(False)

    # ---- about
    def _about(self):
        group = SettingCardGroup("About", self.view)
        welcome = PushButton("Run setup again")
        welcome.clicked.connect(self.window.welcome)
        group.addSettingCard(card(make_icon(), APP_TITLE,
                                  f"Version {APP_VERSION} · A monthly spending tracker with a calendar "
                                  "that looks ahead.",
                                  welcome))
        return group
