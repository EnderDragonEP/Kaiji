"""Kaiji on QFluentWidgets: theme and accent setup, colors for the custom-painted calendar and
charts, plus the few pieces the library doesn't have - a page with a fixed title, stat cards,
an amount box that does arithmetic and a category icon in a tinted circle."""
import winreg

from PySide6.QtCore import QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import QVBoxLayout, QWidget
from qfluentwidgets import (
    CaptionLabel, FluentIcon as FIF, HeaderCardWidget, InfoBadge, LineEdit, ScrollArea,
    SimpleCardWidget, SubtitleLabel, SystemThemeListener, Theme, ThemeColor, TitleLabel,
    isDarkTheme, qconfig, setTheme, setThemeColor,
)
from qframelesswindow.utils import getSystemAccentColor

from . import money

THEMES = {"system": Theme.AUTO, "light": Theme.LIGHT, "dark": Theme.DARK}
# Microsoft JhengHei for Traditional Chinese text (the library defaults to YaHei)
FONTS = ["Segoe UI", "Microsoft JhengHei UI", "Microsoft JhengHei", "Microsoft YaHei"]

# WinUI 3 colors for what QFluentWidgets doesn't paint itself (calendar tiles, charts). Income,
# expense and balance are data-viz categorical slots 1-3 (blue, orange, aqua), stepped per mode;
# the set passes the color-vision-deficiency checks in both modes.
LIGHT = {
    "text": "#E4000000", "secondary": "#9E000000", "tertiary": "#72000000", "disabled": "#5C000000",
    "on_accent": "#FFFFFFFF", "fill": "#B3FFFFFF", "hover": "#09000000", "stroke": "#0F000000",
    "divider": "#14000000", "caution": "#FF9D5D00", "critical": "#FFC42B1C", "success": "#FF0F7B0F",
    "caution_bg": "#FFFFF4CE", "critical_bg": "#FFFDE7E9", "surface": "#FFFBFBFB",
    "income": "#FF2A78D6", "expense": "#FFEB6834", "balance": "#FF1BAF7A",
}
DARK = {
    "text": "#FFFFFFFF", "secondary": "#C5FFFFFF", "tertiary": "#87FFFFFF", "disabled": "#5DFFFFFF",
    "on_accent": "#FF000000", "fill": "#0FFFFFFF", "hover": "#0FFFFFFF", "stroke": "#12FFFFFF",
    "divider": "#15FFFFFF", "caution": "#FFFCE100", "critical": "#FFFF99A4", "success": "#FF6CCB5F",
    "caution_bg": "#FF433519", "critical_bg": "#FF442726", "surface": "#FF2B2B2B",
    "income": "#FF3987E5", "expense": "#FFD95926", "balance": "#FF199E70",
}


def color(name, alpha=None):
    """Current color for name; "accent" is the theme color as the library's controls use it."""
    c = ThemeColor.PRIMARY.color() if name == "accent" else QColor((DARK if isDarkTheme() else LIGHT)[name])
    if alpha is not None:
        c.setAlphaF(alpha)
    return c


def hex_color(name):
    return color(name).name()


def windows_accent():
    """The accent color picked in Windows Settings > Personalization > Colors."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Explorer\Accent") as key:
            data, _ = winreg.QueryValueEx(key, "AccentPalette")
        return QColor(data[12], data[13], data[14])      # the palette's base color
    except (OSError, IndexError, TypeError):
        accent = getSystemAccentColor()
        return accent if accent.isValid() else QColor("#0078D4")


_listener = None


def setup(qapp, settings):
    """Theme, accent and fonts before the first window; then follow Windows light/dark mode."""
    global _listener
    qconfig.set(qconfig.fontFamilies, FONTS, save=False)
    apply_theme(settings.theme)
    apply_accent(settings.accent_color)
    _listener = SystemThemeListener(qapp)
    # the listener only reports the change; setTheme restyles the widgets
    _listener.systemThemeChanged.connect(lambda: setTheme(Theme.AUTO, lazy=True))
    _listener.start()
    qapp.aboutToQuit.connect(_stop_listener)


def _stop_listener():
    _listener.terminate()
    _listener.wait(1000)


def apply_theme(mode):
    setTheme(THEMES.get(mode, Theme.AUTO), lazy=True)


def apply_accent(hex_value):
    """hex_value "" means the Windows accent color."""
    setThemeColor(QColor(hex_value) if hex_value else windows_accent(), lazy=True)


def on_theme_change(callback, accent=True):
    """callback() after every light/dark change, and accent color change unless accent=False.
    Widgets that come and go (list rows) pass accent=False: the lambda for the accent signal
    would outlive them."""
    qconfig.themeChangedFinished.connect(callback)
    if accent:
        qconfig.themeColorChanged.connect(lambda *_: callback())


def secondary(label):
    label.setTextColor(QColor(0, 0, 0, 158), QColor(255, 255, 255, 197))
    return label


def tertiary(label):
    label.setTextColor(QColor(0, 0, 0, 114), QColor(255, 255, 255, 135))
    return label


def tone(label, name=None):
    """Text in a status color ("critical", "caution", "success") or back to normal (None)."""
    if name:
        label.setTextColor(QColor(LIGHT[name]), QColor(DARK[name]))
    else:
        label.setTextColor(QColor(0, 0, 0), QColor(255, 255, 255))
    return label


BADGES = {"caution": InfoBadge.warning, "critical": InfoBadge.error, "success": InfoBadge.success,
          "info": InfoBadge.info}


def badge(text, severity):
    return BADGES[severity](text)


def category_icon(name):
    return FIF.__members__.get(name, FIF.TAG)


def literal(text):
    """Text for buttons, menus and combo boxes, where & would mark a keyboard shortcut."""
    return text.replace("&", "&&")


def header_card(title, *widgets):
    """A HeaderCardWidget with its content stacked (the card's own viewLayout is a row)."""
    card = HeaderCardWidget()
    card.setTitle(title)
    box = QVBoxLayout()
    box.setContentsMargins(0, 0, 0, 0)
    box.setSpacing(8)
    for w in widgets:
        box.addWidget(w)
    card.viewLayout.addLayout(box)
    return card, box


def paint_bubble(p, rect, icon, kind):
    """A category icon in a circle tinted with its kind's series color."""
    p.save()
    p.setPen(Qt.NoPen)
    p.setBrush(color(kind, 0.30 if isDarkTheme() else 0.16))
    p.drawEllipse(rect)
    side = rect.width() * 0.5
    icon.render(p, QRectF(rect.center().x() - side / 2, rect.center().y() - side / 2, side, side))
    p.restore()


class IconBubble(QWidget):
    def __init__(self, icon=FIF.TAG, kind="expense", size=32, parent=None):
        super().__init__(parent)
        self.icon, self.kind = icon, kind
        self.setFixedSize(size, size)
        on_theme_change(self.update, accent=False)       # series colors, not the accent

    def set(self, icon, kind):
        self.icon, self.kind = icon, kind
        self.update()

    def paintEvent(self, e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        paint_bubble(p, QRectF(self.rect()), self.icon, self.kind)


class StatCard(SimpleCardWidget):
    """Caption, value and a note."""

    def __init__(self, caption, parent=None):
        super().__init__(parent)
        col = QVBoxLayout(self)
        col.setContentsMargins(16, 12, 16, 14)
        col.setSpacing(2)
        self.caption = secondary(CaptionLabel(caption))
        col.addWidget(self.caption)
        self.value = SubtitleLabel("–")
        self.note = tertiary(CaptionLabel(""))
        self.note.setWordWrap(True)
        col.addWidget(self.value)
        col.addWidget(self.note)

    def set(self, value, note="", severity=None):
        self.value.setText(value)
        self.note.setText(note)
        tone(self.value, severity)


class Page(ScrollArea):
    """A navigation page: a fixed title with the content scrolling below it."""

    def __init__(self, key, title, parent=None, layout=True):
        super().__init__(parent)
        self.setObjectName(key)                 # FluentWindow routes by object name
        self.view = QWidget(self)
        self.view.setObjectName("view")
        self.view.setStyleSheet("QWidget#view { background: transparent; }")
        self.title = TitleLabel(title, self)
        self.title.move(36, 24)
        self.title.adjustSize()
        self.setViewportMargins(0, 76, 0, 0)
        self.setWidget(self.view)
        self.setWidgetResizable(True)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.enableTransparentBackground()
        if layout:
            self.vbox = QVBoxLayout(self.view)
            self.vbox.setContentsMargins(36, 0, 36, 36)
            self.vbox.setSpacing(12)

    def activate(self):
        """Called when the page is navigated to."""


class AmountEdit(LineEdit):
    """An amount box that takes arithmetic ("120+35", "1.5k", "3萬"). Red border while the text
    isn't an amount; a calculation turns into its result when you leave the box."""

    valueChanged = Signal(object)         # cents, or None while empty or invalid

    def __init__(self, allow_negative=False, parent=None):
        super().__init__(parent)
        self.allow_negative = allow_negative
        self._value = None
        self.setPlaceholderText("0")
        self.textChanged.connect(self._changed)
        self.editingFinished.connect(self._finish)

    def value(self):
        return self._value

    def set_value(self, cents):
        # set directly too: with signals blocked, textChanged wouldn't reach _changed
        self._value = cents
        self.setError(False)
        self.setText("" if cents is None else money.edit_text(cents))

    def is_empty(self):
        return not self.text().strip()

    def is_valid(self):
        return self.is_empty() or self._value is not None

    def _changed(self, text):
        try:
            self._value = money.parse(text, self.allow_negative) if text.strip() else None
        except ValueError:
            self._value = None
        self.setError(not self.is_valid())
        self.valueChanged.emit(self._value)

    def _finish(self):
        if self._value is not None and money.is_expression(self.text()):
            self.set_value(self._value)
