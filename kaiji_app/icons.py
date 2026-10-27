"""The app icon, drawn at runtime: 花 on a rounded square in the green of the balance line."""
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QIcon, QLinearGradient, QPainter, QPainterPath, QPixmap

TOP, BOTTOM = QColor("#27c08e"), QColor("#118259")
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def _glyph(p, rect, color):
    # Filled as an outline rather than drawn as text: Windows text rendering adds ClearType
    # color fringes at icon sizes, and the outline lets us center the glyph's real shape.
    font = QFont("Microsoft JhengHei")
    font.setBold(True)
    font.setPixelSize(100)
    path = QPainterPath()
    path.setFillRule(Qt.WindingFill)   # strokes overlap; even-odd would cut holes where they cross
    path.addText(0, 0, font, "花")
    box = path.boundingRect()
    scale = rect.height() * 0.6 / max(box.width(), box.height())
    p.save()
    p.translate(rect.center())
    p.scale(scale, scale)
    p.translate(-box.center())
    p.fillPath(path, color)
    p.restore()


def make_pixmap(size=64):
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    rect = QRectF(0, 0, size, size).adjusted(size * 0.04, size * 0.04, -size * 0.04, -size * 0.04)
    gradient = QLinearGradient(QPointF(0, rect.top()), QPointF(0, rect.bottom()))
    gradient.setColorAt(0, TOP)
    gradient.setColorAt(1, BOTTOM)
    p.setPen(Qt.NoPen)
    p.setBrush(gradient)
    radius = size * 0.22
    p.drawRoundedRect(rect, radius, radius)
    _glyph(p, rect, QColor("white"))
    p.end()
    return pm


def make_icon():
    icon = QIcon()
    for size in SIZES:
        icon.addPixmap(make_pixmap(size))
    return icon
