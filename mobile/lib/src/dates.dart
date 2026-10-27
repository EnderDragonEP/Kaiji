/// Days are UTC-midnight DateTimes, so adding days never trips over daylight saving.
library;

DateTime ymd(int y, int m, int d) => DateTime.utc(y, m, d);

DateTime dateOf(DateTime t) => DateTime.utc(t.year, t.month, t.day);

DateTime today() => dateOf(DateTime.now());

DateTime addDays(DateTime d, int n) => DateTime.utc(d.year, d.month, d.day + n);

int daysBetween(DateTime a, DateTime b) => b.difference(a).inDays;

/// (first, last) day of a month.
(DateTime, DateTime) monthBounds(int year, int month) => (ymd(year, month, 1), ymd(year, month + 1, 0));

/// Same day [months] later; the 29th-31st become the last day of shorter months.
DateTime addMonths(DateTime day, int months) {
  final index = day.year * 12 + day.month - 1 + months;
  final year = index ~/ 12, month = index % 12 + 1;
  final last = monthBounds(year, month).$2.day;
  return ymd(year, month, day.day < last ? day.day : last);
}

Iterable<DateTime> dayRange(DateTime start, DateTime end) sync* {
  for (var d = start; !d.isAfter(end); d = addDays(d, 1)) {
    yield d;
  }
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime? parseIso(String? text) {
  if (text == null || text.length < 10) return null;
  return ymd(int.parse(text.substring(0, 4)), int.parse(text.substring(5, 7)),
      int.parse(text.substring(8, 10)));
}

const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December',
];

String monthShort(int month) => months[month - 1].substring(0, 3);

/// 2026/10/12
String fmtDate(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

/// Oct 12
String fmtShort(DateTime d) => '${monthShort(d.month)} ${d.day}';

/// Monday, 2026/10/12
String fmtLong(DateTime d) => '${weekdays[d.weekday - 1]}, ${fmtDate(d)}';

String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th';
  return '$n$suffix';
}
