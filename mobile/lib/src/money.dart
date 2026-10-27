/// Amounts are integer cents, so totals are exact. Formatting follows the currency settings
/// (symbol and decimals, kept with the data); parsing takes simple arithmetic, so "120+35",
/// "1.5k" or "3萬" can be typed straight into an amount field. A port of money.py.
library;

const minus = '−'; // typographic minus for the UI
const limit = 1000000000000; // largest amount in cents (SQLite's 64-bit integers)

const currencies = ['NT\$', '\$', 'HK\$', '¥', '€', '£', '₩', 'S\$', 'A\$', 'C\$', 'RM', '฿', '₹'];
const symbols = {
  'TWD': 'NT\$', 'HKD': 'HK\$', 'USD': '\$', 'CNY': '¥', 'JPY': '¥', 'EUR': '€', 'GBP': '£',
  'KRW': '₩', 'SGD': 'S\$', 'AUD': 'A\$', 'CAD': 'C\$', 'MYR': 'RM', 'THB': '฿', 'INR': '₹',
};
const noDecimals = {'TWD', 'JPY', 'KRW', 'VND', 'IDR', 'CLP', 'HUF', 'ISK', 'PYG', 'UGX'};

String _symbol = '\$';
int _decimals = 2;

void configure(String symbol, int decimals) {
  _symbol = symbol;
  _decimals = decimals == 0 ? 0 : 2;
}

String get symbol => _symbol;
int get decimals => _decimals;

/// (symbol, decimals) for a currency code such as "TWD", used when the database is created.
(String, int) defaultsFor(String code) =>
    (symbols[code.toUpperCase()] ?? '\$', noDecimals.contains(code.toUpperCase()) ? 0 : 2);

const _countries = {
  'TW': 'TWD', 'HK': 'HKD', 'US': 'USD', 'CN': 'CNY', 'JP': 'JPY', 'GB': 'GBP', 'KR': 'KRW',
  'SG': 'SGD', 'AU': 'AUD', 'CA': 'CAD', 'MY': 'MYR', 'TH': 'THB', 'IN': 'INR',
};
const _euro = {
  'AT', 'BE', 'CY', 'DE', 'EE', 'ES', 'FI', 'FR', 'GR', 'HR', 'IE', 'IT', 'LT', 'LU', 'LV', 'MT',
  'NL', 'PT', 'SI', 'SK',
};

/// The currency code of a country such as "TW" (the phone's region), "USD" when unknown.
String currencyOf(String? country) {
  final c = country?.toUpperCase() ?? '';
  return _euro.contains(c) ? 'EUR' : _countries[c] ?? 'USD';
}

String _group(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// "abs(cents)" rounded half up to [places] (0 or 2), with thousands separators.
String _digits(int cents, int places) {
  final abs = cents.abs();
  if (places == 0) return _group((abs + 50) ~/ 100);
  return '${_group(abs ~/ 100)}.${(abs % 100).toString().padLeft(2, '0')}';
}

bool _roundsToZero(int cents, int places) => places == 0 ? cents.abs() < 50 : cents == 0;

/// NT$1,234 or −NT$1,234; with sign also +NT$1,234.
String fmt(int cents, {bool sign = false, bool symbol = true}) {
  final text = (symbol ? _symbol : '') + _digits(cents, _decimals);
  if (_roundsToZero(cents, _decimals)) return text;
  if (cents < 0) return '$minus$text';
  return sign ? '+$text' : text;
}

String _fixed(double v, int places) {
  var s = v.toStringAsFixed(places);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s;
}

/// Three significant digits from 1,000 up (12.3K, 1.25M) for chart axes and tight spots.
String compact(int cents, {bool sign = false, bool symbol = false}) {
  final value = cents.abs() / 100;
  String? body;
  for (final (lim, suffix) in [(1e9, 'B'), (1e6, 'M'), (1e3, 'K')]) {
    if (value >= lim * 0.9995) {
      // 999,950 reads 1M, not 1000K
      final v = value / lim;
      final places = v >= 99.95 ? 0 : (v >= 9.995 ? 1 : 2);
      body = _fixed(v, places) + suffix;
      break;
    }
  }
  if (body == null) {
    final whole = _decimals == 0 || value >= 100 || value == value.truncateToDouble();
    body = value.toStringAsFixed(whole ? 0 : 2);
  }
  final nonzero = body != '0' && body != '0.00';
  final text = (symbol ? _symbol : '') + body;
  if (cents < 0 && nonzero) return '$minus$text';
  return sign && cents > 0 && nonzero ? '+$text' : text;
}

/// Text for an amount field: separators but no symbol, and no rounding away of cents.
String editText(int cents) {
  final places = (_decimals == 2 || cents % 100 != 0) ? 2 : 0;
  return (cents < 0 ? '-' : '') + _digits(cents, places);
}

/// The number for CSV files: "1234.50" (or "1235" without decimals), ASCII minus.
String plain(int cents) {
  final neg = cents < 0 && !_roundsToZero(cents, _decimals);
  final abs = cents.abs();
  final body = _decimals == 0
      ? '${(abs + 50) ~/ 100}'
      : '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  return (neg ? '-' : '') + body;
}

// ---- parsing

final _noise = RegExp(r'(?:NT|HK|MOP|S|A|C)?\$|NTD|TWD|RM|[¥€£₩฿₹元圓塊,\s]', caseSensitive: false);
final _units = {'k': '*1000', '千': '*1000', '萬': '*10000', '万': '*10000'};

/// Full-width characters (an IME's ＋１２０) to ASCII, as NFKC does for these.
String _halfWidth(String s) => String.fromCharCodes(s.runes.map((c) {
      if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;
      if (c == 0x3000) return 0x20;
      return c;
    }));

/// The typed text without full-width characters, currency symbols and separators, with
/// k / 千 / 萬 spelled out as multiplications.
String normalize(String text) {
  var s = _halfWidth(text).trim();
  if (_symbol.isNotEmpty) s = s.replaceAll(_symbol, '');
  s = s.replaceAll(_noise, '');
  s = s
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll(minus, '-')
      .replaceAll('x', '*')
      .replaceAll('X', '*');
  // only a trailing unit: "2千5" (2,500 in speech) stays invalid rather than becoming 20,005
  return s.replaceAllMapped(RegExp(r'(?<=[\d.)])([kK千萬万])(?![\d.])'),
      (m) => _units[m.group(1)!.toLowerCase()]!);
}

/// True when the text is a calculation rather than a plain number.
bool isExpression(String text) => RegExp(r'[\d.)][-+*/]').hasMatch(normalize(text));

/// An exact fraction, so 0.1 + 0.2 is 0.3 and rounding matches the desktop app.
class _Q {
  _Q(this.n, this.d);
  final BigInt n, d;
  _Q operator +(_Q o) => _Q(n * o.d + o.n * d, d * o.d);
  _Q operator -(_Q o) => _Q(n * o.d - o.n * d, d * o.d);
  _Q operator *(_Q o) => _Q(n * o.n, d * o.d);
  _Q operator /(_Q o) {
    if (o.n == BigInt.zero) throw const FormatException('division by zero');
    return o.n.isNegative ? _Q(-n * o.d, d * -o.n) : _Q(n * o.d, d * o.n);
  }

  _Q operator -() => _Q(-n, d);
}

class _Parser {
  _Parser(this.s);
  final String s;
  var i = 0;

  _Q parse() {
    final v = _expr();
    if (i != s.length) throw const FormatException('not an amount');
    return v;
  }

  _Q _expr() {
    var v = _term();
    while (i < s.length && (s[i] == '+' || s[i] == '-')) {
      final op = s[i++];
      final r = _term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  _Q _term() {
    var v = _factor();
    while (i < s.length && (s[i] == '*' || s[i] == '/')) {
      final op = s[i++];
      final r = _factor();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  _Q _factor() {
    if (i >= s.length) throw const FormatException('not an amount');
    final c = s[i];
    if (c == '+' || c == '-') {
      i++;
      final v = _factor();
      return c == '-' ? -v : v;
    }
    if (c == '(') {
      i++;
      final v = _expr();
      if (i >= s.length || s[i] != ')') throw const FormatException('not an amount');
      i++;
      return v;
    }
    final m = RegExp(r'\d+(?:\.\d*)?|\.\d+').matchAsPrefix(s, i);
    if (m == null) throw const FormatException('not an amount');
    i = m.end;
    final text = m.group(0)!;
    final dot = text.indexOf('.');
    if (dot < 0) return _Q(BigInt.parse(text), BigInt.one);
    final whole = text.substring(0, dot), frac = text.substring(dot + 1);
    return _Q(BigInt.parse('${whole.isEmpty ? '0' : whole}$frac'), BigInt.from(10).pow(frac.length));
  }
}

/// Cents from what was typed: "1,234.5", "120+35", "3*45", "1.5k", "3萬". Throws
/// FormatException if it isn't an amount, is absurdly large, or is zero or less (unless
/// [allowNegative]).
int parse(String text, {bool allowNegative = false}) {
  final s = normalize(text);
  if (s.isEmpty || s.length > 80 || !RegExp(r'^[\d.+\-*/()]+$').hasMatch(s)) {
    throw const FormatException('not an amount');
  }
  final q = _Parser(s).parse();
  // round half away from zero, like the desktop's ROUND_HALF_UP
  final scaled = q.n * BigInt.from(100);
  final num = scaled.abs() * BigInt.two + q.d;
  var cents = num ~/ (q.d * BigInt.two);
  if (scaled.isNegative) cents = -cents;
  if (cents.abs() >= BigInt.from(limit)) throw const FormatException('too large');
  final value = cents.toInt();
  if (value <= 0 && !allowNegative) throw const FormatException('must be more than zero');
  return value;
}

/// [parse] that returns null instead of throwing.
int? tryParse(String text, {bool allowNegative = false}) {
  try {
    return parse(text, allowNegative: allowNegative);
  } on FormatException {
    return null;
  }
}
