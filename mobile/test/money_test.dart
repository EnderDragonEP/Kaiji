// The desktop app's money tests (tests/test_ledger.py, class Money), case for case.
import 'package:flutter_test/flutter_test.dart';
import 'package:kaiji/src/money.dart' as money;

void main() {
  tearDown(() => money.configure('\$', 2));

  test('parse', () {
    money.configure('NT\$', 0);
    const cases = {
      '1,234.5': 123450, '120+35': 15500, '3萬': 3000000, '1.5k': 150000, 'NT\$ 1,200': 120000,
      '１２３': 12300, '(100+50)*2': 30000, '10/4': 250, '3 x 45': 13500, '0.1+0.2': 30,
    };
    cases.forEach((text, cents) => expect(money.parse(text), cents, reason: text));
    for (final bad in ['2千5', '', 'abc', '0', '-5', '1/0', '2**10', '1e5', '5-', '9' * 20]) {
      expect(() => money.parse(bad), throwsFormatException, reason: bad);
    }
    expect(money.parse('-500', allowNegative: true), -50000);
    expect(money.isExpression('120 + 35'), isTrue);
    expect(money.isExpression('-120'), isFalse);
    expect(money.tryParse('nope'), isNull);
  });

  test('format', () {
    money.configure('NT\$', 0);
    expect(money.fmt(123450), 'NT\$1,235');
    expect(money.fmt(-123450), '−NT\$1,235');
    expect(money.fmt(50, sign: true), '+NT\$1');
    expect(money.fmt(-40), 'NT\$0');
    expect(money.editText(123450), '1,234.50');
    expect(money.editText(123400), '1,234');
    expect(money.plain(-123450), '-1235');
    money.configure('\$', 2);
    expect(money.fmt(123456, symbol: false), '1,234.56');
    expect(money.plain(5), '0.05');
  });

  test('compact', () {
    expect(money.compact(1234500), '12.3K');
    expect(money.compact(99995000), '1M');
    expect(money.compact(123456789), '1.23M');
    expect(money.compact(50000), '500');
    expect(money.compact(-250000, symbol: true), '−\$2.5K');
    expect(money.compact(1234), '12.34');
    const cases = {
      1000000: '10K', 10000000: '100K', 20000000: '200K', 150000000: '1.5M', 2000000000: '20M',
      10000: '100', 0: '0',
    };
    cases.forEach((cents, text) => expect(money.compact(cents), text, reason: '$cents'));
  });
}
