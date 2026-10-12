"""The app window: a QFluentWidgets FluentWindow (frameless, Mica, navigation pane), and the
entry actions every page shares - add, edit, skip and delete, with undo."""
import datetime as dt

from PySide6.QtGui import QGuiApplication, QKeySequence, QShortcut
from qfluentwidgets import (
    Action, FluentIcon as FIF, FluentWindow, InfoBar, InfoBarPosition, NavigationItemPosition,
    PushButton, RoundMenu,
)

from . import money
from .config import APP_TITLE
from .dialogs import EntryDialog, WelcomeDialog, confirm
from .icons import make_icon
from .ledger import date_number, fmt_date
from .page_calendar import CalendarPage
from .page_repeating import RepeatingPage
from .page_settings import SettingsPage
from .page_stats import StatisticsPage
from .page_today import TodayPage


def entry_values(source, day=None):
    """Dialog values from an entry, a rule or a ledger item."""
    return {"kind": source.kind, "amount": source.amount, "category_id": source.category_id,
            "note": source.note, "day": day or getattr(source, "day", None),
            "freq": getattr(source, "freq", None), "every": getattr(source, "every", 1),
            "until": getattr(source, "until", None), "times": getattr(source, "times", None)}


class MainWindow(FluentWindow):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.setWindowTitle(APP_TITLE)
        self.setWindowIcon(make_icon())
        self.setMicaEffectEnabled(True)            # Windows 11; a plain background elsewhere
        self.navigationInterface.setReturnButtonVisible(False)
        self.navigationInterface.setExpandWidth(220)

        self.pages = {"today": TodayPage(app, self), "calendar": CalendarPage(app, self),
                      "stats": StatisticsPage(app, self), "repeating": RepeatingPage(app, self),
                      "settings": SettingsPage(app, self)}
        self.addSubInterface(self.pages["today"], FIF.HOME, "Today")
        self.addSubInterface(self.pages["calendar"], FIF.CALENDAR, "Calendar")
        self.addSubInterface(self.pages["stats"], FIF.PIE_SINGLE, "Statistics")
        self.addSubInterface(self.pages["repeating"], FIF.SYNC, "Repeating")
        self.addSubInterface(self.pages["settings"], FIF.SETTING, "Settings",
                             NavigationItemPosition.BOTTOM)
        self.stackedWidget.currentChanged.connect(lambda _: self.current_page().activate())
        QShortcut(QKeySequence.New, self, activated=lambda: self.add_entry())

        self.resize(1320, 880)
        self.setMinimumSize(1100, 700)
        screen = QGuiApplication.primaryScreen().availableGeometry()
        self.move(screen.center() - self.rect().center())
        self.navigationInterface.expand(useAni=False)      # labels shown, like Windows Settings

    def show_page(self, key):
        page = self.pages[key]
        if self.current_page() is page:
            page.activate()
        else:
            self.switchTo(page)                    # activates it through currentChanged

    def current_page(self):
        return self.stackedWidget.currentWidget()

    def show_day(self, day):
        self.show_page("calendar")
        self.pages["calendar"].show_day(day)

    def showEvent(self, event):
        super().showEvent(event)
        self.current_page().activate()

    def tell(self, kind, title, content="", undo=None):
        bar = getattr(InfoBar, kind)(title, content, duration=6000 if undo else 4000,
                                     position=InfoBarPosition.TOP_RIGHT, parent=self)
        if undo:
            button = PushButton("Undo")
            button.clicked.connect(lambda: (undo(), bar.close()))
            bar.addWidget(button)
        return bar

    def default_day(self):
        """New entries go on the day selected in the calendar while it's showing, else today."""
        if self.current_page() is self.pages["calendar"]:
            return self.pages["calendar"].grid.current
        return dt.date.today()

    def welcome(self):
        dialog = WelcomeDialog(self, self.app)
        if dialog.exec():
            dialog.apply()
        self.app.settings.welcomed = True
        self.app.settings.save()

    # ---- entries
    def add_entry(self, day=None, kind="expense", repeat=None, values=None):
        values = dict(values or {}, freq=repeat or (values or {}).get("freq"))
        dialog = EntryDialog(self, self.app, "new", day or self.default_day(), kind, values)
        if dialog.exec():
            self.app.save_entry(dialog.values())

    def edit_item(self, item):
        """Clicking an entry edits it; a repeating date edits the whole repeating entry."""
        if item.repeating:
            self.edit_rule(item.rule_id)
        else:
            self.edit_entry(item.entry_id)

    def edit_entry(self, entry_id):
        entry = self.app.store.entry(entry_id)
        if entry is None:
            return
        dialog = EntryDialog(self, self.app, "entry", values=entry_values(entry))
        if not dialog.exec():
            return
        if dialog.deleted:
            self.delete_entry(entry_id)
        else:
            self.app.save_entry(dialog.values(), entry_id)

    def edit_rule(self, rule_id, mode="series", day=None):
        """mode: "series" (every date), "later" (from day on) or "date" (only day)."""
        rule = self.app.store.rule(rule_id)
        if rule is None:
            return
        values = entry_values(rule, day or rule.start)
        if mode == "later" and rule.times:
            # from the 5th of 12 times on, 8 are left
            values["times"] = max(1, rule.times - date_number(rule, day) + 1)
        dialog = EntryDialog(self, self.app, mode, values=values)
        if not dialog.exec():
            return
        if dialog.deleted:
            self.delete_rule(rule_id, ask=True)
        elif mode == "series":
            self.app.save_rule(rule_id, dialog.values())
        elif mode == "later":
            self.app.change_from(rule_id, dialog.values())
        else:
            self.app.edit_date(rule_id, day, dialog.values())

    def item_menu(self, item, pos):
        menu = RoundMenu(parent=self)
        if item.repeating:
            r, d = item.rule_id, item.day
            menu.addActions([
                Action(FIF.EDIT, "Edit this date only…", triggered=lambda: self.edit_rule(r, "date", d)),
                Action(FIF.DATE_TIME, "Edit this and later dates…",
                       triggered=lambda: self.edit_rule(r, "later", d)),
                Action(FIF.SYNC, "Edit all dates…", triggered=lambda: self.edit_rule(r)),
            ])
            menu.addSeparator()
            menu.addActions([
                Action(FIF.REMOVE, "Skip this date", triggered=lambda: self.skip(r, d)),
                Action(FIF.PAUSE, "Stop after this date", triggered=lambda: self.stop_after(r, d)),
                Action(FIF.DELETE, "Delete all dates…", triggered=lambda: self.delete_rule(r, ask=True)),
            ])
        else:
            e = item.entry_id
            menu.addActions([
                Action(FIF.EDIT, "Edit…", triggered=lambda: self.edit_entry(e)),
                Action(FIF.COPY, "Duplicate…",
                       triggered=lambda: self.add_entry(item.day, item.kind, values=entry_values(item))),
            ])
            menu.addSeparator()
            menu.addAction(Action(FIF.DELETE, "Delete", triggered=lambda: self.delete_entry(e)))
        menu.exec(pos)

    def delete_entry(self, entry_id):
        entry = self.app.store.entry(entry_id)
        undo = self.app.delete_entry(entry_id)
        self.tell("success", "Entry deleted",
                  f"{entry.note or self.app.category(entry.category_id).name} · "
                  f"{money.fmt(entry.amount)} · {fmt_date(entry.day)}", undo)

    def delete_rule(self, rule_id, ask=False):
        rule = self.app.store.rule(rule_id)
        if rule is None:
            return
        if ask and not confirm(self, "Delete this repeating entry?",
                               "Every date it falls on goes, past ones too. To keep the past, use "
                               "“Stop after this date” on a date in the calendar instead."):
            return
        undo = self.app.delete_rule(rule_id)
        self.tell("success", "Repeating entry deleted",
                  rule.note or self.app.category(rule.category_id).name, undo)

    def skip(self, rule_id, day):
        undo = self.app.skip(rule_id, day)
        self.tell("success", "Date skipped", f"Nothing on {fmt_date(day)} for this one.", undo)

    def stop_after(self, rule_id, day):
        undo = self.app.stop_after(rule_id, day)
        self.tell("success", "Stopped", f"The last date is {fmt_date(day)}.", undo)
