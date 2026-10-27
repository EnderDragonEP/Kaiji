/// Charts for Today and Statistics, painted to the same specs as the desktop's charts.py: thin
/// marks with 4px rounded data ends, hairline grids, 2px lines, a legend for two series, a few
/// direct labels. On a phone you tap or drag instead of hovering, and the values read out above
/// the chart.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../dates.dart';
import '../models.dart';
import '../money.dart' as money;
import 'look.dart';

const _maxBar = 24.0;
const _radius = 4.0;

/// Round tick values (in cents) covering [lo, hi]: steps of 1, 2 or 5 x 10^n units.
List<int> niceTicks(int lo, int hi, [int count = 4]) {
  if (hi <= lo) hi = lo + 100;
  final raw = math.max((hi - lo) / count, money.decimals == 0 ? 100.0 : 1.0);
  final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final step = [1, 2, 5, 10].map((m) => m * magnitude).firstWhere((s) => s >= raw - 1e-9);
  final ticks = <double>[(lo / step).floor() * step];
  while (ticks.last < hi - step * 1e-9) {
    ticks.add(ticks.last + step);
  }
  return [for (final t in ticks) t.round()];
}

Path _dashed(Path source, double dash, double gap) {
  final out = Path();
  for (final metric in source.computeMetrics()) {
    for (var d = 0.0; d < metric.length; d += dash + gap) {
      out.addPath(metric.extractPath(d, math.min(d + dash, metric.length)), Offset.zero);
    }
  }
  return out;
}

TextPainter _layout(String text, TextStyle style, [TextScaler scaler = TextScaler.noScaling]) =>
    TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
      ..layout();

/// Colors and text styles the painters need, taken from the theme once per build.
class _Ink {
  _Ink(BuildContext context)
      : axis = Theme.of(context).textTheme.labelSmall!.copyWith(color: tertiaryText(context)),
        label = Theme.of(context).textTheme.labelSmall!.copyWith(
            color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600),
        grid = Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
        baseline = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.22),
        hover = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
        surface = Theme.of(context).colorScheme.surfaceContainerLow,
        secondary = secondaryText(context),
        critical = Theme.of(context).colorScheme.error,
        income = series(context, 'income'),
        expense = series(context, 'expense'),
        balance = series(context, 'balance');
  final TextStyle axis, label;
  final Color grid, baseline, hover, surface, secondary, critical, income, expense, balance;

  Color of(String key) => switch (key) { 'income' => income, 'expense' => expense, _ => balance };
}

double _axisWidth(List<int> ticks, TextStyle style) =>
    ticks.map((t) => _layout(money.compact(t), style).width).reduce(math.max) + 8;

void _valueAxis(Canvas canvas, Rect plot, List<int> ticks, double Function(int) yOf, _Ink ink) {
  final grid = Paint()
    ..color = ink.grid
    ..strokeWidth = 1;
  for (final t in ticks) {
    final y = yOf(t).roundToDouble() + 0.5;
    canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    final tp = _layout(money.compact(t), ink.axis);
    tp.paint(canvas, Offset(plot.left - tp.width - 6, y - tp.height / 2));
  }
}

/// Swatch + name per series, above a chart with two of them.
class _Legend extends StatelessWidget {
  const _Legend(this.items);
  final List<(String, Color)> items;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 16, children: [
        for (final (name, c) in items)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            Text(name, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: secondaryText(context))),
          ]),
      ]);
}

/// The line above a chart: what's selected, or how to select.
class _Readout extends StatelessWidget {
  const _Readout(this.spans);
  final List<InlineSpan> spans;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 20,
        child: Text.rich(TextSpan(children: spans),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: secondaryText(context))),
      );
}

InlineSpan _value(String text, Color key) => TextSpan(children: [
      WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(width: 12, height: 3, margin: const EdgeInsets.only(right: 4), color: key)),
      TextSpan(text: text, style: const TextStyle(fontWeight: FontWeight.w600)),
    ]);

class _Empty extends StatelessWidget {
  const _Empty(this.text, this.height);
  final String text;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height,
      child: Center(child: Text(text, style: TextStyle(color: tertiaryText(context)))));
}

// ---------------------------------------------------------------- columns

/// Columns per slot (a day or a month) for one or two series from a zero baseline. Planned
/// values (after today) are lighter; a dashed line can mark a reference such as the average.
class ColumnChart extends StatefulWidget {
  const ColumnChart({
    super.key,
    required this.labels,
    required this.titles,
    required this.series,
    this.planned,
    this.reference,
    this.height = 200,
    this.empty = 'Nothing to show yet.',
  });
  final List<String> labels; // x-axis text per slot, "" to skip
  final List<String> titles; // readout heading per slot
  final List<(String, String, List<int>)> series; // (name, color key, cents per slot)
  final List<bool>? planned;
  final (int, String)? reference;
  final double height;
  final String empty;

  @override
  State<ColumnChart> createState() => _ColumnChartState();
}

class _ColumnChartState extends State<ColumnChart> {
  int? selected;

  bool get _isEmpty => widget.labels.isEmpty || !widget.series.any((s) => s.$3.any((v) => v > 0));

  void _select(Offset at, double width, Rect Function(Size) plotOf) {
    final plot = plotOf(Size(width, widget.height));
    final i = ((at.dx - plot.left) / (plot.width / widget.labels.length)).floor();
    setState(() => selected = i >= 0 && i < widget.labels.length ? i : null);
  }

  @override
  Widget build(BuildContext context) {
    if (_isEmpty) return _Empty(widget.empty, widget.height);
    final ink = _Ink(context);
    final painter = _ColumnPainter(widget, ink, selected);
    final i = selected;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.series.length > 1) ...[
        _Legend([for (final (name, key, _) in widget.series) (name, ink.of(key))]),
        const SizedBox(height: 6),
      ],
      _Readout(i == null
          ? [const TextSpan(text: 'Tap a column for its amount')]
          : [
              TextSpan(text: '${widget.titles[i]}   '),
              for (final (name, key, values) in widget.series) ...[
                _value(money.fmt(values[i]), ink.of(key)),
                TextSpan(text: ' $name   '),
              ],
              if (widget.planned?[i] ?? false) const TextSpan(text: 'planned'),
            ]),
      const SizedBox(height: 4),
      LayoutBuilder(builder: (context, box) {
        void pick(Offset at) => _select(at, box.maxWidth, painter.plotOf);
        return GestureDetector(
          onTapDown: (e) => pick(e.localPosition),
          onHorizontalDragUpdate: (e) => pick(e.localPosition),
          child: CustomPaint(size: Size(box.maxWidth, widget.height), painter: painter),
        );
      }),
    ]);
  }
}

class _ColumnPainter extends CustomPainter {
  _ColumnPainter(this.chart, this.ink, this.selected)
      : peak = [
          for (final s in chart.series) ...s.$3,
          if (chart.reference != null) chart.reference!.$1,
        ].reduce(math.max);
  final ColumnChart chart;
  final _Ink ink;
  final int? selected;
  final int peak;

  List<int> get ticks => niceTicks(0, peak);

  Rect plotOf(Size size) => Rect.fromLTRB(_axisWidth(ticks, ink.axis), 4, size.width - 2, size.height - 20);

  @override
  void paint(Canvas canvas, Size size) {
    final ticks = this.ticks, plot = plotOf(size), top = ticks.last;
    double yOf(int v) => plot.bottom - v / top * plot.height;
    _valueAxis(canvas, plot, ticks, yOf, ink);

    final n = chart.labels.length, count = chart.series.length;
    final slot = plot.width / n;
    const gap = 2.0;
    final width = ((slot * 0.72 - gap * (count - 1)) / count).clamp(1.5, _maxBar);
    final group = width * count + gap * (count - 1);
    for (var i = 0; i < n; i++) {
      final x = plot.left + slot * i + (slot - group) / 2;
      if (i == selected) {
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(plot.left + slot * i, plot.top, slot, plot.height),
                const Radius.circular(4)),
            Paint()..color = ink.hover);
      }
      for (var s = 0; s < count; s++) {
        final (_, key, values) = chart.series[s];
        final v = values[i];
        if (v <= 0) continue;
        final h = math.max(1.5, v / top * plot.height);
        var c = ink.of(key);
        if (chart.planned?[i] ?? false) c = c.withValues(alpha: 0.42);
        final r = math.min(_radius, math.min(width / 2, h));
        canvas.drawRRect(
            RRect.fromRectAndCorners(Rect.fromLTWH(x + s * (width + gap), plot.bottom - h, width, h),
                topLeft: Radius.circular(r), topRight: Radius.circular(r)),
            Paint()..color = c);
      }
    }
    canvas.drawLine(Offset(plot.left, plot.bottom + 0.5), Offset(plot.right, plot.bottom + 0.5),
        Paint()..color = ink.baseline);

    final ref = chart.reference;
    if (ref != null && ref.$1 > 0) {
      final y = yOf(ref.$1);
      canvas.drawPath(_dashed(Path()..moveTo(plot.left, y)..lineTo(plot.right, y), 4, 3),
          Paint()
            ..color = ink.secondary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      final tp = _layout(ref.$2, ink.axis.copyWith(color: ink.secondary));
      final box = Rect.fromLTWH(plot.right - tp.width - 8, y - tp.height - 4, tp.width + 8, tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)),
          Paint()..color = ink.surface.withValues(alpha: 0.85));
      tp.paint(canvas, Offset(box.left + 4, box.top + 1));
    }

    var last = -1e9;
    for (var i = 0; i < n; i++) {
      final text = chart.labels[i];
      if (text.isEmpty) continue;
      final tp = _layout(text, ink.axis);
      final left = plot.left + slot * (i + 0.5) - tp.width / 2;
      if (left < last + 6) continue;
      last = left + tp.width;
      tp.paint(canvas, Offset(left, plot.bottom + 4));
    }
  }

  @override
  bool shouldRepaint(_ColumnPainter old) => true;
}

// ---------------------------------------------------------------- ranked bars

/// Ranked horizontal bars: icon, name, the bar and its amount with the share at the tip.
class BarList extends StatelessWidget {
  const BarList({super.key, required this.rows, required this.colorKey, this.empty = 'Nothing to show yet.'});
  final List<(String, String, int, int)> rows; // (icon, name, cents, count), largest first
  final String colorKey;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return _Empty(empty, 84);
    final total = rows.fold(0, (s, r) => s + r.$3);
    final peak = rows.first.$3;
    final style = Theme.of(context).textTheme.bodySmall!;
    // room after the longest bar for the widest amount and a share, at the phone's text size
    final scaler = MediaQuery.textScalerOf(context);
    double width(String text) => _layout(text, style, scaler).width;
    final labelWidth = rows.map((r) => width(money.fmt(r.$3))).reduce(math.max) + width('100%') + 14;
    final color = series(context, colorKey);
    return Column(children: [
      for (final (icon, name, cents, count) in rows)
        Tooltip(
          message: '$count ${count == 1 ? 'entry' : 'entries'} · average ${money.fmt(cents ~/ count)}',
          child: SizedBox(
            height: 32,
            child: Row(children: [
              Icon(categoryIcon(icon), size: 18, color: Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: 8),
              SizedBox(width: 104, child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
              Expanded(
                child: LayoutBuilder(builder: (context, box) {
                  final span = math.max(4.0, box.maxWidth - labelWidth);
                  return Row(children: [
                    Container(
                      width: math.max(2.0, cents / peak * span),
                      height: 12,
                      decoration: BoxDecoration(
                          color: color, borderRadius: const BorderRadius.horizontal(right: Radius.circular(_radius))),
                    ),
                    const SizedBox(width: 6),
                    Text(money.fmt(cents), style: style),
                    const SizedBox(width: 6),
                    Text('${(cents / total * 100).round()}%',
                        style: style.copyWith(color: secondaryText(context))),
                  ]);
                }),
              ),
            ]),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------- balance

/// End-of-day balance: solid up to today, dashed after it (projected), a hairline at today and
/// a dashed line at the minimum balance. Drag across it to read any day.
class BalanceChart extends StatefulWidget {
  const BalanceChart({super.key, required this.days, required this.today, this.floor = 0, this.height = 200});
  final List<DayInfo> days;
  final DateTime today;
  final int floor;
  final double height;

  @override
  State<BalanceChart> createState() => _BalanceChartState();
}

class _BalanceChartState extends State<BalanceChart> {
  int? selected;

  bool get _isEmpty => widget.days.length < 2 || !widget.days.any((d) => d.items.isNotEmpty || d.balance != 0);

  @override
  Widget build(BuildContext context) {
    if (_isEmpty) return _Empty('Nothing to show yet.', widget.height);
    final ink = _Ink(context);
    final painter = _BalancePainter(widget, ink, selected);
    final i = selected;
    final d = i != null ? widget.days[i] : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Readout(d == null
          ? [const TextSpan(text: 'Drag across the line to read a day')]
          : [
              TextSpan(text: '${weekdaysShort[d.day.weekday - 1]} ${fmtDate(d.day)}   '),
              _value((d.day.isAfter(widget.today) ? '≈ ' : '') + money.fmt(d.balance), ink.balance),
              if (d.income > 0) TextSpan(text: '   ${money.fmt(d.income, sign: true)}'),
              if (d.expense > 0) TextSpan(text: '   ${money.fmt(-d.expense)}'),
            ]),
      const SizedBox(height: 4),
      LayoutBuilder(builder: (context, box) {
        void pick(Offset at) {
          final plot = painter.plotOf(Size(box.maxWidth, widget.height));
          final x = at.dx.clamp(plot.left, plot.right);
          setState(() => selected = ((x - plot.left) / plot.width * (widget.days.length - 1)).round());
        }

        return GestureDetector(
          onTapDown: (e) => pick(e.localPosition),
          onHorizontalDragUpdate: (e) => pick(e.localPosition),
          child: CustomPaint(size: Size(box.maxWidth, widget.height), painter: painter),
        );
      }),
    ]);
  }
}

class _BalancePainter extends CustomPainter {
  _BalancePainter(this.chart, this.ink, this.selected);
  final BalanceChart chart;
  final _Ink ink;
  final int? selected;

  List<DayInfo> get days => chart.days;

  bool get showsFloor {
    final values = days.map((d) => d.balance);
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    // unless it's so far below the balance it would flatten the line
    return chart.floor != 0 && chart.floor >= lo - (hi - lo) * 0.5;
  }

  List<int> get ticks {
    final values = days.map((d) => d.balance);
    var lo = values.reduce(math.min), hi = values.reduce(math.max);
    if (showsFloor) {
      lo = math.min(lo, chart.floor);
      hi = math.max(hi, chart.floor);
    }
    // some room around the line; a flat one still gets distinct tick labels
    final pad = [(hi - lo) * 0.08, math.max(lo.abs(), hi.abs()) * 0.05, 100.0].reduce(math.max).round();
    // and no axis below zero for a balance that never goes there
    return niceTicks(lo >= 0 ? math.max(0, lo - pad) : lo - pad, hi + pad);
  }

  Rect plotOf(Size size) => Rect.fromLTRB(_axisWidth(ticks, ink.axis), 18, size.width - 8, size.height - 20);

  int get todayIndex {
    for (var i = 0; i < days.length; i++) {
      if (!days[i].day.isBefore(chart.today)) return days[i].day == chart.today ? i : math.max(0, i - 1);
    }
    return days.length - 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ticks = this.ticks, plot = plotOf(size);
    final lo = ticks.first, hi = ticks.last, n = days.length;
    double xOf(int i) => plot.left + i / (n - 1) * plot.width;
    double yOf(int v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    _valueAxis(canvas, plot, ticks, yOf, ink);
    if (lo < 0 && hi > 0) {
      final y = yOf(0).roundToDouble() + 0.5;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), Paint()..color = ink.secondary);
    }

    final points = [for (var i = 0; i < n; i++) Offset(xOf(i), yOf(days[i].balance))];
    final ti = todayIndex;
    final future = days.last.day.isAfter(chart.today);

    // a soft wash under the line, fading out towards the bottom
    final area = Path()..moveTo(points.first.dx, plot.bottom);
    for (final p in points) {
      area.lineTo(p.dx, p.dy);
    }
    area
      ..lineTo(points.last.dx, plot.bottom)
      ..close();
    canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [ink.balance.withValues(alpha: 0.18), ink.balance.withValues(alpha: 0)],
          ).createShader(plot));

    Rect? floorLabel;
    if (showsFloor) {
      final y = yOf(chart.floor);
      canvas.drawPath(_dashed(Path()..moveTo(plot.left, y)..lineTo(plot.right, y), 4, 3),
          Paint()
            ..color = ink.critical
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      final tp = _layout('Minimum ${money.fmt(chart.floor)}', ink.axis.copyWith(color: ink.critical));
      floorLabel = Offset(plot.left + 4, y - 15) & tp.size;
      tp.paint(canvas, floorLabel.topLeft);
    }

    if (!chart.today.isBefore(days.first.day) && !chart.today.isAfter(days.last.day)) {
      final x = xOf(ti).roundToDouble() + 0.5;
      canvas.drawLine(Offset(x, plot.top - 2), Offset(x, plot.bottom), Paint()..color = ink.axis.color!);
      final tp = _layout('Today', ink.axis);
      tp.paint(canvas, Offset(x - tp.width / 2, 0));
    }

    final line = Paint()
      ..color = ink.balance
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final split = future ? ti : n - 1;
    Path pathOf(List<Offset> part) {
      final p = Path()..moveTo(part.first.dx, part.first.dy);
      for (final o in part.skip(1)) {
        p.lineTo(o.dx, o.dy);
      }
      return p;
    }

    if (split > 0) canvas.drawPath(pathOf(points.sublist(0, split + 1)), line);
    if (split < n - 1) canvas.drawPath(_dashed(pathOf(points.sublist(split)), 5, 5), line);

    // direct labels: today, the lowest point ahead and the last day, each above its dot or below
    // it (the low one below first: the line rises on both sides of it), or left out when neither
    // clears the dots and the other labels
    final marks = <(int, String, bool)>[(ti, '', false)];
    if (future) {
      var low = ti + 1;
      for (var i = ti + 1; i < n; i++) {
        if (days[i].balance < days[low].balance) low = i;
      }
      if (days[low].balance < days[ti].balance && low != n - 1) marks.add((low, 'Low ', true));
      marks.add((n - 1, '', false));
    }
    final taken = [for (final (i, _, _) in marks) Rect.fromCircle(center: points[i], radius: 6), ?floorLabel];
    for (final (i, prefix, under) in marks) {
      final p = points[i];
      final approx = days[i].day.isAfter(chart.today) ? '≈ ' : '';
      final tp = _layout(prefix + approx + money.fmt(days[i].balance), ink.label);
      final left = (p.dx - tp.width / 2).clamp(plot.left, plot.right - tp.width);
      final above = Rect.fromLTWH(left, p.dy - tp.height - 8, tp.width, tp.height);
      final below = Rect.fromLTWH(left, p.dy + 8, tp.width, tp.height);
      final box = (under ? [below, above] : [above, below])
          .where((b) => b.top >= plot.top && b.bottom <= plot.bottom && !taken.any((t) => t.overlaps(b)))
          .firstOrNull;
      _dot(canvas, p);
      if (box == null) continue;
      taken.add(box);
      tp.paint(canvas, box.topLeft);
    }

    final sel = selected;
    if (sel != null && sel < n) {
      final x = points[sel].dx.roundToDouble() + 0.5;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), Paint()..color = ink.secondary);
      _dot(canvas, points[sel]);
    }

    // x labels: month starts for long spans, a few dates otherwise
    final picks = <(int, String)>[];
    if (n > 75) {
      for (var i = 0; i < n; i++) {
        if (days[i].day.day == 1) picks.add((i, monthShort(days[i].day.month)));
      }
    } else {
      final step = math.max(1, (n / 5).round());
      for (var i = 0; i < n; i += step) {
        picks.add((i, fmtShort(days[i].day)));
      }
    }
    var last = -1e9;
    for (final (i, text) in picks) {
      final tp = _layout(text, ink.axis);
      final left = (xOf(i) - tp.width / 2).clamp(0.0, size.width - tp.width);
      if (left < last + 10) continue;
      last = left + tp.width;
      tp.paint(canvas, Offset(left, plot.bottom + 4));
    }
  }

  void _dot(Canvas canvas, Offset p) {
    canvas.drawCircle(p, 5, Paint()..color = ink.surface);
    canvas.drawCircle(p, 3.5, Paint()..color = ink.balance);
  }

  @override
  bool shouldRepaint(_BalancePainter old) => true;
}
