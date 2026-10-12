"""Write the Kaiji icon as a multi-size .ico for the exe: python tools/make_ico.py OUT.ico"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PySide6.QtCore import QBuffer, QIODevice  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402

from kaiji_app.icons import SIZES, make_pixmap  # noqa: E402


def png_bytes(size):
    buf = QBuffer()
    buf.open(QIODevice.WriteOnly)
    make_pixmap(size).save(buf, "PNG")
    return bytes(buf.data())


def main(out):
    QGuiApplication(sys.argv[:1])   # fonts need a GUI application
    images = [png_bytes(s) for s in SIZES]
    # ICONDIR, then one ICONDIRENTRY per image, then the PNG data (Vista+ PNG-in-ICO)
    offset = 6 + 16 * len(images)
    header = struct.pack("<HHH", 0, 1, len(images))
    entries = b""
    for size, data in zip(SIZES, images):
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "wb") as f:
        f.write(header + entries + b"".join(images))
    print(f"wrote {out} ({', '.join(map(str, SIZES))} px)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Kaiji.ico")
