"""Amounts are integer cents, so totals are exact. Formatting follows the currency settings
(symbol and decimals, kept with the data); parsing takes simple arithmetic, so "120+35",
"1.5k" or "3萬" can be typed straight into an amount box."""
import ast
import decimal
import operator
import re
import unicodedata

MINUS = "−"                  # typographic minus for the UI; CSV export uses "-"
LIMIT = 10 ** 12                  # largest amount in cents (fits SQLite's 64-bit integers)

CURRENCIES = ["NT$", "$", "HK$", "¥", "€", "£", "₩", "S$", "A$", "C$", "RM", "฿", "₹"]
SYMBOLS = {"TWD": "NT$", "HKD": "HK$", "USD": "$", "CNY": "¥", "JPY": "¥", "EUR": "€", "GBP": "£",
           "KRW": "₩", "SGD": "S$", "AUD": "A$", "CAD": "C$", "MYR": "RM", "THB": "฿", "INR": "₹"}
NO_DECIMALS = {"TWD", "JPY", "KRW", "VND", "IDR", "CLP", "HUF", "ISK", "PYG", "UGX"}

_symbol, _decimals = "$", 2


def configure(symbol, decimals):
    global _symbol, _decimals
    _symbol, _decimals = symbol, 0 if decimals == 0 else 2


def symbol():
    return _symbol


def decimals():
    return _decimals


def locale_defaults():
    """(symbol, decimals) for the Windows region, used when the database is first created."""
    from PySide6.QtCore import QLocale
    loc = QLocale.system()
    code = loc.currencySymbol(QLocale.CurrencyIsoCode)
    sym = SYMBOLS.get(code) or loc.currencySymbol(QLocale.CurrencySymbol) or "$"
    return sym, (0 if code in NO_DECIMALS else 2)


def _rounded(cents, places):
    step = decimal.Decimal(1).scaleb(-places)
    return (decimal.Decimal(cents) / 100).quantize(step, decimal.ROUND_HALF_UP)


def fmt(cents, sign=False, symbol=True):
    """NT$1,234 or −NT$1,234; with sign=True also +NT$1,234."""
    value = _rounded(cents, _decimals)
    text = (_symbol if symbol else "") + f"{abs(value):,.{_decimals}f}"
    if value < 0:
        return MINUS + text
    return "+" + text if sign and value > 0 else text


def compact(cents, sign=False, symbol=False):
    """Three significant digits from 1,000 up (12.3K, 1.25M) for chart axes and tight spots."""
    value = abs(cents) / 100
    body = None
    for limit, suffix in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if value >= limit * 0.9995:            # 999,950 reads 1M, not 1000K
            v = value / limit
            places = 0 if v >= 99.95 else 1 if v >= 9.995 else 2
            body = f"{v:.{places}f}"
            if "." in body:
                body = body.rstrip("0").rstrip(".")
            body += suffix
            break
    if body is None:
        whole = _decimals == 0 or value >= 100 or value == int(value)
        body = f"{value:.0f}" if whole else f"{value:.2f}"
    nonzero = body not in ("0", "0.00")
    text = (_symbol if symbol else "") + body
    if cents < 0 and nonzero:
        return MINUS + text
    return "+" + text if sign and cents > 0 and nonzero else text


def edit_text(cents):
    """Text for an amount box: separators but no symbol, and no rounding away of cents."""
    places = 2 if _decimals == 2 or cents % 100 else 0
    value = _rounded(cents, places)
    return ("-" if value < 0 else "") + f"{abs(value):,.{places}f}"


def plain(cents):
    """Number for CSV files: '1234.50' (or '1235' without decimals), with an ASCII minus."""
    return f"{_rounded(cents, _decimals):.{_decimals}f}"


_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
        ast.Div: operator.truediv}
_UNITS = {"k": "*1000", "千": "*1000", "萬": "*10000", "万": "*10000"}
_NOISE = re.compile(r"(?:NT|HK|MOP|S|A|C)?\$|NTD|TWD|RM|[¥€£₩฿₹元圓塊,\s]", re.IGNORECASE)


def _evaluate(node):
    if isinstance(node, ast.Expression):
        return _evaluate(node.body)
    if isinstance(node, ast.Constant) and type(node.value) in (int, float):
        return decimal.Decimal(str(node.value))
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        left, right = _evaluate(node.left), _evaluate(node.right)
        if isinstance(node.op, ast.Div) and right == 0:
            raise ValueError("division by zero")
        return _OPS[type(node.op)](left, right)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
        value = _evaluate(node.operand)
        return -value if isinstance(node.op, ast.USub) else value
    raise ValueError("not an amount")


def normalize(text):
    """The typed text without full-width characters, currency symbols and separators, with
    k / 千 / 萬 spelled out as multiplications."""
    s = unicodedata.normalize("NFKC", text).strip()
    if _symbol:
        s = s.replace(_symbol, "")
    s = _NOISE.sub("", s)
    s = s.replace("×", "*").replace("÷", "/").replace(MINUS, "-").replace("x", "*").replace("X", "*")
    # only a trailing unit: "2千5" (2,500 in speech) stays invalid rather than becoming 20,005
    return re.sub(r"(?<=[\d.)])([kK千萬万])(?![\d.])", lambda m: _UNITS[m.group(1).lower()], s)


def is_expression(text):
    """True when the text is a calculation rather than a plain number."""
    return bool(re.search(r"[\d.)][-+*/]", normalize(text)))


def parse(text, allow_negative=False):
    """Cents from what was typed: '1,234.5', '120+35', '3*45', '1.5k', '3萬'. ValueError if it
    isn't an amount, is absurdly large, or is zero or less (unless allow_negative)."""
    s = normalize(text)
    if not s or len(s) > 80 or not re.fullmatch(r"[\d.+\-*/()]+", s):
        raise ValueError("not an amount")
    try:
        value = _evaluate(ast.parse(s, mode="eval"))
    except (SyntaxError, decimal.InvalidOperation, RecursionError) as e:
        raise ValueError("not an amount") from e
    if not value.is_finite():
        raise ValueError("not an amount")
    cents = int((value * 100).quantize(decimal.Decimal(1), decimal.ROUND_HALF_UP))
    if abs(cents) >= LIMIT:
        raise ValueError("too large")
    if cents <= 0 and not allow_negative:
        raise ValueError("must be more than zero")
    return cents
