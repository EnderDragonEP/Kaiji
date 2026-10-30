"""Charts for Today and Statistics, painted with the library's fonts and theme colors. QtCharts
can't round bar ends or draw a snapping crosshair; these follow the data-viz specs instead:
thin marks with 4px rounded data-ends, hairline grids, 2px lines, a legend for two series,
selective direct labels, and every value in a tooltip (and in the Entries table)."""
import html
import math

from PySide6.QtCore import QPoint, QPointF, QRectF, Qt
from PySide6.QtGui import (
    QFont, QFontMetrics, QGuiApplication, QLinearGradient, QPainter, QPainterPath, QPen,
)
from PySide6.QtWidgets import QSizePolicy, QWidget
from qfluentwidgets import ToolTip, getFont

from . import fluent, money
from .fluent import color
from .ledger import MONTHS_SHORT, WEEKDAY_SHORT, fmt_date

MAX_BAR = 24                  # bar thickness cap
RADIUS = 4                    # rounded data-end


def nice_ticks(lo, hi, count=4):
    """Round tick values (in cents) covering [lo, hi]: steps of 1, 2 or 5 x 10^n units."""
    if hi <= lo:
        hi = lo + 100
    raw = max((hi - lo) / count, 100 if money.decimals() == 0 else 1)
    magnitude = 10 ** math.floor(math.log10(raw))
    step = next(m * magnitude for m in (1, 2, 5, 10) if m * magnitude >= raw)
    first = math.floor(lo / step) * step
    ticks = [first]
    while ticks[-1] < hi - step * 1e-9:
        ticks.append(ticks[-1] + step)
    return ticks


def column_path(rect, radius):
    """A column rounded at the top (its data end), square at the baseline."""
    r = min(radius, rect.width() / 2, rect.height())
    path = QPainterPath()
    path.moveTo(rect.left(), rect.bottom())
    path.lineTo(rect.left(), rect.top() + r)
    path.arcTo(QRectF(rect.left(), rect.top(), 2 * r, 2 * r), 180, -90)
    path.lineTo(rect.right() - r, rect.top())
    path.arcTo(QRectF(rect.right() - 2 * r, rect.top(), 2 * r, 2 * r), 90, -90)
    path.lineTo(rect.right(), rect.bottom())
    path.closeSubpath()
    return path


def bar_path(rect, radius):
    """A horizontal bar rounded at the right (its data end), square at the baseline."""
    r = min(radius, rect.height() / 2, rect.width())
    path = QPainterPath()
    path.moveTo(rect.left(), rect.top())
    path.lineTo(rect.right() - r, rect.top())
    path.arcTo(QRectF(rect.right() - 2 * r, rect.top(), 2 * r, 2 * r), 90, -90)
    path.lineTo(rect.right(), rect.bottom() - r)
    path.arcTo(QRectF(rect.right() - 2 * r, rect.bottom() - 2 * r, 2 * r, 2 * r), 0, -90)
    path.lineTo(rect.left(), rect.bottom())
    path.closeSubpath()
    return path


def tip_row(key, value, label):
    """A tooltip line: a short stroke in the series color, the value in bold, then its label."""
    return (f"<div><span style='color:{fluent.hex_color(key)}'>━━</span>&nbsp; "
            f"<b>{html.escape(value)}</b>&nbsp; {html.escape(label)}</div>")


def tip_head(text):
    return f"<div style='margin-bottom:3px'>{html.escape(text)}</div>"


class ChartTip:
    """One Fluent tooltip that follows the pointer over a chart."""

    def __init__(self, widget):
        self.widget = widget
        self.tip = None
        self.text = None

    def show(self, text, global_pos):
        if self.tip is None:
            self.tip = ToolTip("", self.widget.window())
            self.tip.setDuration(-1)
        if text != self.text:
            self.text = text
            self.tip.setText(text)
        screen = QGuiApplication.screenAt(global_pos)
        area = screen.availableGeometry() if screen else self.widget.window().geometry()
        x, y = global_pos.x() + 8, global_pos.y() + 4
        if x + self.tip.width() > area.right():
            x = global_pos.x() - self.tip.width() - 4
        y = min(y, area.bottom() - self.tip.height())
        self.tip.move(QPoint(x, y))
        if not self.tip.isVisible():
            self.tip.show()

    def hide(self):
        if self.tip is not None:
            self.tip.hide()
        self.text = None


class Chart(QWidget):
    """Hover tracking, the tooltip, an empty state and the value axis shared by the charts."""

    def __init__(self, empty="Nothing to show yet.", parent=None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.empty_text = empty
        self.hover = None
        self.tip = ChartTip(self)
        fluent.on_theme_change(self.update)

    def set_hover(self, index, text=None, pos=None):
        if index != self.hover:
            self.hover = index
            self.update()
        if index is None or not text:
            self.tip.hide()
        else:
            self.tip.show(text, pos)

    def leaveEvent(self, e):
        self.set_hover(None)

    def hideEvent(self, e):
        self.tip.hide()
        super().hideEvent(e)

    def painter(self):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.TextAntialiasing)
        return p

    def paint_empty(self, p):
        p.setFont(getFont(13))
        p.setPen(color("tertiary"))
        p.drawText(QRectF(self.rect()), Qt.AlignCenter, self.empty_text)

    @staticmethod
    def axis_width(ticks):
        fm = QFontMetrics(getFont(12))
        return max(fm.horizontalAdvance(money.compact(t)) for t in ticks) + 10

    @staticmethod
    def paint_value_axis(p, plot, ticks, y_of):
        """Hairline gridlines with compact labels on the left."""
        p.setFont(getFont(12))
        for t in ticks:
            y = round(y_of(t)) + 0.5
            p.setPen(QPen(color("divider"), 1))
            p.drawLine(QPointF(plot.left(), y), QPointF(plot.right(), y))
            p.setPen(color("tertiary"))
            p.drawText(QRectF(0, y - 9, plot.left() - 8, 18), Qt.AlignRight | Qt.AlignVCenter,
                       money.compact(t))

    @staticmethod
    def paint_legend(p, x, y, series):
        """Rect swatches (the marks are bars) with the series names, from (x, y)."""
        p.setFont(getFont(12))
        fm = QFontMetrics(p.font())
        for name, key in series:
            p.setPen(Qt.NoPen)
            p.setBrush(color(key))
            p.drawRoundedRect(QRectF(x, y + 3, 10, 10), 2, 2)
            p.setPen(color("secondary"))
            p.drawText(QRectF(x + 15, y, 200, 16), Qt.AlignLeft | Qt.AlignVCenter, name)
            x += 15 + fm.horizontalAdvance(name) + 18


class ColumnChart(Chart):
    """Columns per slot (a day or a month) for one or two series from a zero baseline. Planned
    values (after today) are lighter; a dashed line can mark a reference such as the average."""

    def __init__(self, empty="Nothing to show yet.", height=260, parent=None):
        super().__init__(empty, parent)
        self.setFixedHeight(height)
        self.labels, self.titles, self.series, self.planned, self.ref = [], [], [], [], None

    def set_data(self, labels, titles, series, planned=None, ref=None):
        """labels: x-axis text per slot ("" to skip); titles: tooltip heading per slot;
        series: [(name, color key, [cents per slot])]; planned: [bool] per slot;
        ref: (cents, label) for a dashed reference line."""
        self.labels, self.titles, self.series = labels, titles, series
        self.planned = planned or [False] * len(labels)
        self.ref = ref
        self.set_hover(None)
        self.update()

    def _geometry(self):
        top = 30 if len(self.series) > 1 else 10
        peak = max([max(v) for _, _, v in self.series if v] + [self.ref[0] if self.ref else 0])
        ticks = nice_ticks(0, peak)
        plot = QRectF(self.axis_width(ticks), top, 0, 0)
        plot.setRight(self.width() - 4)
        plot.setBottom(self.height() - 26)
        return plot, ticks

    def _empty(self):
        return not self.labels or not any(any(v) for _, _, v in self.series)

    def paintEvent(self, e):
        p = self.painter()
        if self._empty():
            self.paint_empty(p)
            return
        plot, ticks = self._geometry()
        top = ticks[-1]

        def y_of(v):
            return plot.bottom() - v / top * plot.height()

        self.paint_value_axis(p, plot, ticks, y_of)
        if len(self.series) > 1:
            self.paint_legend(p, plot.left(), 0, [(n, k) for n, k, _ in self.series])

        n, count = len(self.labels), len(self.series)
        slot = plot.width() / n
        gap = 2
        width = max(2.0, min(MAX_BAR, (slot * 0.72 - gap * (count - 1)) / count))
        group = width * count + gap * (count - 1)
        for i in range(n):
            x = plot.left() + slot * i + (slot - group) / 2
            if i == self.hover:
                p.setPen(Qt.NoPen)
                p.setBrush(color("hover"))
                p.drawRoundedRect(QRectF(plot.left() + slot * i, plot.top(), slot, plot.height()),
                                  4, 4)
            for s, (_, key, values) in enumerate(self.series):
                v = values[i]
                if v <= 0:
                    continue
                h = max(1.5, v / top * plot.height())
                c = color(key, 0.42 if self.planned[i] else None)
                p.fillPath(column_path(QRectF(x + s * (width + gap), plot.bottom() - h, width, h),
                                       RADIUS), c)
        p.setPen(QPen(color("text", 0.18), 1))           # the baseline, a step above the grid
        base = plot.bottom() + 0.5
        p.drawLine(QPointF(plot.left(), base), QPointF(plot.right(), base))

        if self.ref and self.ref[0] > 0:
            y = y_of(self.ref[0])
            pen = QPen(color("secondary"), 1.2, Qt.CustomDashLine)
            pen.setDashPattern([4, 3])
            p.setPen(pen)
            p.drawLine(QPointF(plot.left(), y), QPointF(plot.right(), y))
            p.setFont(getFont(12))
            fm = QFontMetrics(p.font())
            w = fm.horizontalAdvance(self.ref[1]) + 12
            box = QRectF(plot.right() - w, y - 19, w, 17)
            p.setPen(Qt.NoPen)
            p.setBrush(color("surface", 0.85))
            p.drawRoundedRect(box, 4, 4)
            p.setPen(color("secondary"))
            p.drawText(box, Qt.AlignCenter, self.ref[1])

        # x labels, left to right, each one that doesn't touch the one before
        p.setFont(getFont(12))
        fm = QFontMetrics(p.font())
        p.setPen(color("tertiary"))
        last = -1e9
        for i, text in enumerate(self.labels):
            if not text:
                continue
            w = fm.horizontalAdvance(text)
            left = plot.left() + slot * (i + 0.5) - w / 2
            if left < last + 8:
                continue
            last = left + w
            p.drawText(QRectF(left, plot.bottom() + 4, w + 2, 20), Qt.AlignLeft | Qt.AlignTop, text)

    def mouseMoveEvent(self, e):
        if self._empty():
            return
        plot, _ = self._geometry()
        x = e.position().x()
        if not plot.left() <= x <= plot.right():
            self.set_hover(None)
            return
        i = min(len(self.labels) - 1, int((x - plot.left()) / (plot.width() / len(self.labels))))
        text = tip_head(self.titles[i])
        text += "".join(tip_row(key, money.fmt(values[i]), name) for name, key, values in self.series)
        if self.planned[i]:
            text += "<div>Planned</div>"
        self.set_hover(i, text, e.globalPosition().toPoint())


class BarList(Chart):
    """Ranked horizontal bars: icon, name, the bar and its amount with the share at the tip."""

    ROW = 34

    def __init__(self, empty="Nothing to show yet.", parent=None):
        super().__init__(empty, parent)
        self.rows, self.key, self.noun = [], "expense", "spending"
        self.setFixedHeight(self.ROW * 3)

    def set_data(self, rows, key, noun):
        """rows: [(FluentIcon, name, cents, count)], largest first; key: series color."""
        self.rows, self.key, self.noun = rows, key, noun
        self.setFixedHeight(max(3, len(rows)) * self.ROW + 4)
        self.set_hover(None)
        self.update()

    def _columns(self):
        fm = QFontMetrics(getFont(13))
        name_w = min(170, max(fm.horizontalAdvance(r[1]) for r in self.rows) + 12)
        label_w = max(fm.horizontalAdvance(self._label(r)) for r in self.rows) + 12
        return 26 + name_w, label_w

    def _label(self, row):
        total = sum(r[2] for r in self.rows)
        return f"{money.fmt(row[2])}   {row[2] / total:.0%}" if total else money.fmt(row[2])

    def paintEvent(self, e):
        p = self.painter()
        if not self.rows:
            self.paint_empty(p)
            return
        bar_x, label_w = self._columns()
        span = max(10, self.width() - bar_x - label_w)
        peak = max(r[2] for r in self.rows)
        total = sum(r[2] for r in self.rows)
        fm13 = QFontMetrics(getFont(13))
        for i, (icon, name, cents, _) in enumerate(self.rows):
            y = 2 + i * self.ROW
            row = QRectF(0, y, self.width(), self.ROW)
            if i == self.hover:
                p.setPen(Qt.NoPen)
                p.setBrush(color("hover"))
                p.drawRoundedRect(row, 4, 4)
            icon.render(p, QRectF(4, row.center().y() - 8, 16, 16))
            p.setFont(getFont(13))
            p.setPen(color("text"))
            p.drawText(QRectF(26, y, bar_x - 32, self.ROW), Qt.AlignLeft | Qt.AlignVCenter,
                       fm13.elidedText(name, Qt.ElideRight, int(bar_x - 34)))
            length = max(2.0, cents / peak * span)
            bar = QRectF(bar_x, row.center().y() - 6, length, 12)
            p.fillPath(bar_path(bar, RADIUS), color(self.key))
            p.drawText(QRectF(bar.right() + 8, y, label_w, self.ROW), Qt.AlignLeft | Qt.AlignVCenter,
                       money.fmt(cents))
            amount_w = fm13.horizontalAdvance(money.fmt(cents))
            p.setFont(getFont(12))
            p.setPen(color("secondary"))
            p.drawText(QRectF(bar.right() + 8 + amount_w + 8, y, label_w, self.ROW),
                       Qt.AlignLeft | Qt.AlignVCenter, f"{cents / total:.0%}" if total else "")

    def mouseMoveEvent(self, e):
        i = int((e.position().y() - 2) // self.ROW)
        if not self.rows or not 0 <= i < len(self.rows):
            self.set_hover(None)
            return
        _, name, cents, count = self.rows[i]
        total = sum(r[2] for r in self.rows)
        text = tip_head(name) + tip_row(self.key, money.fmt(cents),
                                        f"{cents / total:.0%} of {self.noun}")
        text += (f"<div>{count} {'entry' if count == 1 else 'entries'} · "
                 f"average {money.fmt(cents // count)}</div>")
        self.set_hover(i, text, e.globalPosition().toPoint())


class BalanceChart(Chart):
    """End-of-day balance: solid up to today, dashed after it (projected), a hairline at today
    and a dashed line at the minimum balance. A crosshair snaps to the nearest day."""

    def __init__(self, empty="Nothing to show yet.", height=260, parent=None):
        super().__init__(empty, parent)
        self.setFixedHeight(height)
        self.days, self.today, self.floor = [], None, 0

    def set_data(self, days, today, floor=0):
        """days: [ledger.Day] in date order; floor: the minimum balance (0 = none shown)."""
        self.days, self.today, self.floor = days, today, floor
        self.set_hover(None)
        self.update()

    def _shows_floor(self):
        """The minimum line, unless it's so far below the balance it would flatten the line."""
        values = [d.balance for d in self.days]
        lo, hi = min(values), max(values)
        return bool(self.floor) and self.floor >= lo - (hi - lo) * 0.5

    def _geometry(self):
        values = [d.balance for d in self.days]
        lo, hi = min(values), max(values)
        if self._shows_floor():
            lo, hi = min(lo, self.floor), max(hi, self.floor)
        # some room around the line; a flat one still gets distinct tick labels
        pad = max((hi - lo) * 0.08, max(abs(lo), abs(hi)) * 0.05, 100)
        ticks = nice_ticks(lo - pad, hi + pad)
        plot = QRectF(self.axis_width(ticks), 22, 0, 0)
        plot.setRight(self.width() - 12)
        plot.setBottom(self.height() - 26)
        return plot, ticks

    def _today_index(self):
        for i, d in enumerate(self.days):
            if d.day >= self.today:
                return i if d.day == self.today else max(0, i - 1)
        return len(self.days) - 1

    def _empty(self):
        return len(self.days) < 2 or not any(d.items or d.balance for d in self.days)

    def paintEvent(self, e):
        p = self.painter()
        if self._empty():
            self.paint_empty(p)
            return
        plot, ticks = self._geometry()
        lo, hi = ticks[0], ticks[-1]
        n = len(self.days)

        def x_of(i):
            return plot.left() + i / (n - 1) * plot.width()

        def y_of(v):
            return plot.bottom() - (v - lo) / (hi - lo) * plot.height()

        self.paint_value_axis(p, plot, ticks, y_of)
        if lo < 0 < hi:
            p.setPen(QPen(color("secondary"), 1))
            y = round(y_of(0)) + 0.5
            p.drawLine(QPointF(plot.left(), y), QPointF(plot.right(), y))

        points = [QPointF(x_of(i), y_of(d.balance)) for i, d in enumerate(self.days)]
        ti = self._today_index()
        future = self.today is not None and self.days[-1].day > self.today

        # a soft wash under the line, fading out towards the bottom
        area = QPainterPath(QPointF(points[0].x(), plot.bottom()))
        for pt in points:
            area.lineTo(pt)
        area.lineTo(QPointF(points[-1].x(), plot.bottom()))
        area.closeSubpath()
        wash = QLinearGradient(QPointF(0, plot.top()), QPointF(0, plot.bottom()))
        wash.setColorAt(0, color("balance", 0.16))
        wash.setColorAt(1, color("balance", 0.0))
        p.fillPath(area, wash)

        if self._shows_floor():
            y = y_of(self.floor)
            pen = QPen(color("critical"), 1.2, Qt.CustomDashLine)
            pen.setDashPattern([4, 3])
            p.setPen(pen)
            p.drawLine(QPointF(plot.left(), y), QPointF(plot.right(), y))
            p.setFont(getFont(12))
            p.setPen(color("critical"))
            p.drawText(QRectF(plot.left() + 6, y - 18, 300, 16), Qt.AlignLeft | Qt.AlignVCenter,
                       f"Minimum {money.fmt(self.floor)}")

        if self.today is not None and self.days[0].day <= self.today <= self.days[-1].day:
            x = round(x_of(ti)) + 0.5
            p.setPen(QPen(color("tertiary"), 1))
            p.drawLine(QPointF(x, plot.top() - 4), QPointF(x, plot.bottom()))
            p.setFont(getFont(12))
            p.drawText(QRectF(x - 40, 0, 80, 16), Qt.AlignCenter, "Today")

        solid = QPen(color("balance"), 2, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        dashed = QPen(color("balance"), 2, Qt.CustomDashLine, Qt.RoundCap, Qt.RoundJoin)
        dashed.setDashPattern([2.5, 2.5])
        p.setBrush(Qt.NoBrush)
        split = ti if future else n - 1
        for pen, part in ((solid, points[:split + 1]), (dashed, points[split:])):
            if len(part) > 1:
                path = QPainterPath(part[0])
                for pt in part[1:]:
                    path.lineTo(pt)
                p.setPen(pen)
                p.drawPath(path)

        # direct labels: today, the lowest point ahead, the last day
        marks = [(ti, "")]
        if future:
            low = min(range(ti + 1, n), key=lambda i: (self.days[i].balance, i))
            if self.days[low].balance < self.days[ti].balance and low != n - 1:
                marks.append((low, "Low "))
            marks.append((n - 1, ""))
        taken = []
        p.setFont(getFont(12, QFont.DemiBold))
        fm = QFontMetrics(p.font())
        for i, prefix in marks:
            pt = points[i]
            approx = "≈ " if self.today is not None and self.days[i].day > self.today else ""
            text = prefix + approx + money.fmt(self.days[i].balance)
            w = fm.horizontalAdvance(text) + 8
            box = QRectF(min(max(pt.x() - w / 2, plot.left()), plot.right() - w), pt.y() - 26, w, 18)
            if box.top() < plot.top():                   # keep clear of the "Today" label
                box.moveTop(pt.y() + 8)
            self._dot(p, pt)
            if any(box.intersects(t) for t in taken):
                continue
            taken.append(box)
            p.setPen(color("text"))
            p.drawText(box, Qt.AlignCenter, text)

        if self.hover is not None:
            x = round(points[self.hover].x()) + 0.5
            p.setPen(QPen(color("secondary"), 1))
            p.drawLine(QPointF(x, plot.top()), QPointF(x, plot.bottom()))
            self._dot(p, points[self.hover])

        self._x_labels(p, plot, x_of)

    @staticmethod
    def _dot(p, pt):
        p.setPen(QPen(color("surface"), 2))
        p.setBrush(color("balance"))
        p.drawEllipse(pt, 5, 5)

    def _x_labels(self, p, plot, x_of):
        n = len(self.days)
        p.setFont(getFont(12))
        p.setPen(color("tertiary"))
        if n > 75:            # month starts
            picks = [(i, MONTHS_SHORT[d.day.month - 1]) for i, d in enumerate(self.days)
                     if d.day.day == 1]
        else:
            step = max(1, round(n / 6))
            picks = [(i, f"{MONTHS_SHORT[self.days[i].day.month - 1]} {self.days[i].day.day}")
                     for i in range(0, n, step)]
        fm = QFontMetrics(p.font())
        last = -1e9
        for i, text in picks:
            x = x_of(i)
            w = fm.horizontalAdvance(text)
            left = min(max(x - w / 2, plot.left() - 8), self.width() - w)
            if left < last + 12:
                continue
            last = left + w
            p.drawText(QRectF(left, plot.bottom() + 4, w + 2, 20), Qt.AlignLeft | Qt.AlignTop, text)

    def mouseMoveEvent(self, e):
        if self._empty():
            return
        plot, _ = self._geometry()
        x = min(max(e.position().x(), plot.left()), plot.right())
        i = round((x - plot.left()) / plot.width() * (len(self.days) - 1))
        d = self.days[i]
        projected = self.today is not None and d.day > self.today
        text = tip_head(f"{WEEKDAY_SHORT[d.day.weekday()]} {fmt_date(d.day)}"
                        + (" · projected" if projected else ""))
        text += tip_row("balance", money.fmt(d.balance), "balance at day end")
        if d.income:
            text += tip_row("income", money.fmt(d.income, sign=True), "income")
        if d.expense:
            text += tip_row("expense", money.MINUS + money.fmt(d.expense), "expenses")
        self.set_hover(i, text, e.globalPosition().toPoint())
