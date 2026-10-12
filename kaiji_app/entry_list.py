"""Entry rows for the calendar's day panel and Today's coming-up list."""
from PySide6.QtCore import QPoint, QRectF, Qt, Signal
from PySide6.QtGui import QPainter
from PySide6.QtWidgets import QHBoxLayout, QVBoxLayout, QWidget
from qfluentwidgets import (
    BodyLabel, CaptionLabel, FluentIcon as FIF, StrongBodyLabel, TransparentToolButton,
)

from . import money
from .fluent import IconBubble, category_icon, color, secondary, tertiary
from .ledger import WEEKDAY_SHORT, date_number, describe_rule, fmt_short


def describe_item(app, item):
    """(title, subtitle) for an item: the note (or the category) and what's around it."""
    category = app.category(item.category_id)
    title = item.note or category.name
    parts = [category.name] if item.note else []
    if item.repeating:
        rule = app.rule(item.rule_id)
        parts.append(describe_rule(rule) if rule else "Repeating")
        if rule and rule.times:
            parts.append(f"{date_number(rule, item.day)} of {rule.times}")
    return title, " · ".join(parts)


class EntryRow(QWidget):
    """One entry: icon, what it was, the amount. Click to edit; right-click for more."""

    clicked = Signal(object)                    # ledger Item
    menu_requested = Signal(object, object)     # ledger Item, global QPoint

    def __init__(self, item, icon, title, subtitle, amount, side="", lead="", dim=False, parent=None):
        super().__init__(parent)
        self.item = item
        self._hover = False
        self.setCursor(Qt.PointingHandCursor)
        row = QHBoxLayout(self)
        row.setContentsMargins(8, 6, 10, 6)
        row.setSpacing(10)
        if lead:
            when = secondary(CaptionLabel(lead))
            when.setFixedWidth(70)
            row.addWidget(when)
        row.addWidget(IconBubble(icon, item.kind, 32))
        text = QVBoxLayout()
        text.setSpacing(0)
        self.title = BodyLabel(title)
        text.addWidget(self.title)
        if subtitle:
            sub = tertiary(CaptionLabel(subtitle))
            text.addWidget(sub)
        row.addLayout(text, 1)
        right = QVBoxLayout()
        right.setSpacing(0)
        value = StrongBodyLabel(amount)
        if dim:
            secondary(value)
        right.addWidget(value, 0, Qt.AlignRight)
        if side:
            right.addWidget(tertiary(CaptionLabel(side)), 0, Qt.AlignRight)
        row.addLayout(right)
        more = TransparentToolButton(FIF.MORE)
        more.setFixedSize(28, 28)
        more.clicked.connect(
            lambda: self.menu_requested.emit(self.item, more.mapToGlobal(QPoint(0, more.height()))))
        row.addWidget(more)

    def enterEvent(self, e):
        self._hover = True
        self.update()

    def leaveEvent(self, e):
        self._hover = False
        self.update()

    def paintEvent(self, e):
        if self._hover:
            p = QPainter(self)
            p.setRenderHint(QPainter.Antialiasing)
            p.setPen(Qt.NoPen)
            p.setBrush(color("hover"))
            p.drawRoundedRect(QRectF(self.rect()), 5, 5)

    def mouseReleaseEvent(self, e):
        if e.button() == Qt.LeftButton and self.rect().contains(e.position().toPoint()):
            self.clicked.emit(self.item)

    def contextMenuEvent(self, e):
        self.menu_requested.emit(self.item, e.globalPos())


class EntryList(QWidget):
    """Entry rows, or a placeholder when there are none."""

    clicked = Signal(object)
    menu_requested = Signal(object, object)

    def __init__(self, empty="", parent=None):
        super().__init__(parent)
        self.box = QVBoxLayout(self)
        self.box.setContentsMargins(0, 0, 0, 0)
        self.box.setSpacing(2)
        self.empty = secondary(BodyLabel(empty))
        self.empty.setWordWrap(True)
        self.box.addWidget(self.empty)

    def set_empty_text(self, text):
        self.empty.setText(text)

    def set_items(self, app, items, today, dated=False, balances=None):
        """items: ledger Items; dated: lead each row with its date; balances: the balance after
        each item, shown under its amount."""
        while self.box.count() > 1:
            w = self.box.takeAt(1).widget()
            w.hide()            # deleteLater alone leaves it painted until the event loop runs
            w.deleteLater()
        self.empty.setVisible(not items)
        for i, item in enumerate(items):
            title, subtitle = describe_item(app, item)
            lead = f"{WEEKDAY_SHORT[item.day.weekday()]}, {fmt_short(item.day)}" if dated else ""
            side = ""
            if balances is not None:
                side = ("≈ " if item.day > today else "") + money.fmt(balances[i])
            row = EntryRow(item, category_icon(app.category(item.category_id).icon), title, subtitle,
                           money.fmt(item.signed, sign=True), side, lead, dim=item.day > today)
            row.clicked.connect(self.clicked)
            row.menu_requested.connect(self.menu_requested)
            self.box.addWidget(row)
