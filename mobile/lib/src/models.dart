/// What Kaiji stores: categories, entries, repeating entries (rules) and the plan. The same
/// tables and meaning as the desktop app's store.py, so a kaiji.db moves between the two.
library;

class Category {
  const Category(this.id, this.kind, this.name, this.icon, [this.position = 0]);
  final int id;
  final String kind; // "expense" or "income"
  final String name;
  final String icon; // a desktop FluentIcon name such as "CAFE"; the phone maps it
  final int position;
}

class Entry {
  const Entry(this.id, this.day, this.kind, this.amount, this.categoryId, [this.note = '']);
  final int id;
  final DateTime day;
  final String kind;
  final int amount; // cents, always > 0; the kind says in or out
  final int? categoryId;
  final String note;

  int get signed => kind == 'income' ? amount : -amount;
}

/// A repeating entry: every [every] days/weeks/months/years from [start], until [until] or for
/// [times] dates (skipped ones included), whichever ends first; neither: no end.
class Rule {
  const Rule(this.id, this.kind, this.amount, this.categoryId, this.note, this.freq, this.every,
      this.start,
      {this.until, this.times, this.skips = const {}});
  final int id;
  final String kind;
  final int amount;
  final int? categoryId;
  final String note;
  final String freq; // "day", "week", "month" or "year"
  final int every;
  final DateTime start;
  final DateTime? until;
  final int? times;
  final Set<DateTime> skips;

  int get signed => kind == 'income' ? amount : -amount;
}

/// What "left to spend" is worked out from.
class Plan {
  const Plan({
    this.startBalance = 0,
    this.startDate,
    this.savingsGoal = 0,
    this.minBalance = 0,
    this.basis = 'income',
  });
  final int startBalance; // money you had at the start of startDate
  final DateTime? startDate; // null: balances simply add up from the first entry
  final int savingsGoal; // set aside from each month's income
  final int minBalance; // the balance shouldn't drop below this
  final String basis; // "income": this month's income; "balance": everything you have

  Plan copyWith({int? startBalance, DateTime? startDate, bool clearStart = false, int? savingsGoal,
          int? minBalance, String? basis}) =>
      Plan(
        startBalance: startBalance ?? this.startBalance,
        startDate: clearStart ? null : (startDate ?? this.startDate),
        savingsGoal: savingsGoal ?? this.savingsGoal,
        minBalance: minBalance ?? this.minBalance,
        basis: basis ?? this.basis,
      );

  @override
  bool operator ==(Object other) =>
      other is Plan &&
      other.startBalance == startBalance &&
      other.startDate == startDate &&
      other.savingsGoal == savingsGoal &&
      other.minBalance == minBalance &&
      other.basis == basis;

  @override
  int get hashCode => Object.hash(startBalance, startDate, savingsGoal, minBalance, basis);
}

/// One amount on the calendar: an entry, or a date a repeating entry falls on.
class Item {
  const Item(this.day, this.kind, this.amount, this.categoryId, this.note,
      {this.entryId, this.ruleId});
  final DateTime day;
  final String kind;
  final int amount;
  final int? categoryId;
  final String note;
  final int? entryId;
  final int? ruleId;

  int get signed => kind == 'income' ? amount : -amount;
  bool get repeating => ruleId != null;
}

class DayInfo {
  DayInfo(this.day, this.items, this.income, this.expense, this.balance);
  final DateTime day;
  final List<Item> items;
  final int income, expense;
  final int balance; // at the end of the day
}

class MonthPlan {
  const MonthPlan({
    required this.start,
    required this.end,
    required this.status,
    required this.income,
    required this.expense,
    required this.plannedIncome,
    required this.plannedExpense,
    required this.opening,
    required this.closing,
    required this.lowest,
    required this.lowestDay,
    required this.goal,
    required this.floor,
    required this.basis,
    required this.budgetRoom,
    required this.cashRoom,
    required this.daysLeft,
  });
  final DateTime start, end;
  final String status; // "past", "current" or "future"
  final int income, expense; // everything dated in the month, recorded and planned
  final int plannedIncome, plannedExpense; // the part dated after today
  final int opening, closing; // balances at the start and the end of the month
  final int lowest; // lowest end-of-day balance from today (or the 1st) on
  final DateTime lowestDay;
  final int goal, floor;
  final String basis;
  final int budgetRoom; // income - expenses - savings goal
  final int cashRoom; // lowest balance - minimum balance
  final int daysLeft; // today included; 0 for past months

  /// Left to spend in the rest of the month; negative when the plan is overspent.
  int get left => basis == 'balance' ? cashRoom : (budgetRoom < cashRoom ? budgetRoom : cashRoom);
  bool get limitedByBalance => basis == 'income' && cashRoom < budgetRoom;
  int get perDay => left > 0 && daysLeft > 0 ? left ~/ daysLeft : 0;
  int get spent => expense - plannedExpense;
  int get net => income - expense;
}
