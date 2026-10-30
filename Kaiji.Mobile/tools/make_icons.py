"""Write the Android launcher icons and the in-app logo from the desktop icon
(Kaiji.Windows/kaiji_app/icons.py): python Kaiji.Mobile/tools/make_icons.py"""
import os
import sys

MOBILE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(MOBILE), "Kaiji.Windows"))

from PySide6.QtCore import QRectF, Qt  # noqa: E402
from PySide6.QtGui import QColor, QFontDatabase, QGuiApplication, QPainter, QPixmap  # noqa: E402

from kaiji_app.icons import FONT, _glyph, make_pixmap  # noqa: E402

RES = os.path.join(MOBILE, "android", "app", "src", "main", "res")
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def foreground(size):
    """花 alone on a 108dp adaptive-icon layer, of which launchers show the middle 72dp. White on
    clear, so it doubles as the monochrome layer that themed icons tint."""
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    shown = size * 72 / 108
    _glyph(p, QRectF((size - shown) / 2, (size - shown) / 2, shown, shown), QColor("white"))
    p.end()
    return pm


def save(pm, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pm.save(path, "PNG")
    print("wrote", os.path.relpath(path, MOBILE))


def main():
    QGuiApplication(sys.argv[:1])   # fonts need a GUI application
    # Without the exe's font Qt quietly draws 花 in another one, and the phone's icon stops
    # matching; QT_QPA_PLATFORM=offscreen, for one, doesn't see the Windows fonts it needs.
    if FONT not in QFontDatabase.families():
        sys.exit(f"{FONT} isn't available to Qt here: run this on Windows, without QT_QPA_PLATFORM")
    for name, scale in DENSITIES.items():
        folder = os.path.join(RES, f"mipmap-{name}")
        save(make_pixmap(round(48 * scale)), os.path.join(folder, "ic_launcher.png"))
        save(foreground(round(108 * scale)), os.path.join(folder, "ic_launcher_foreground.png"))
    save(make_pixmap(192), os.path.join(MOBILE, "assets", "kaiji.png"))


if __name__ == "__main__":
    main()
