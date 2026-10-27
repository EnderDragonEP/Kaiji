/// Kaiji's look on Android: Material 3 in the wallpaper's colors (Material You), or Kaiji green.
/// Income, expenses and the balance are the same blue, orange and green as on the desktop - a
/// data-viz set checked to stay apart for color-vision deficiency in light and dark - and the
/// categories keep the desktop's icon names, shown with the Material icon that matches.
library;

import 'package:flutter/material.dart';

const kaijiGreen = Color(0xFF1BAF7A);

const _series = {
  'income': (Color(0xFF2A78D6), Color(0xFF3987E5)),
  'expense': (Color(0xFFEB6834), Color(0xFFD95926)),
  'balance': (Color(0xFF1BAF7A), Color(0xFF199E70)),
  'caution': (Color(0xFF9D5D00), Color(0xFFFCE100)),
};

bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// "income", "expense", "balance" or "caution" for the current brightness.
Color series(BuildContext context, String key) {
  final pair = _series[key]!;
  return isDark(context) ? pair.$2 : pair.$1;
}

Color critical(BuildContext context) => Theme.of(context).colorScheme.error;

/// Secondary and tertiary text, like the desktop's.
Color secondaryText(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;
Color tertiaryText(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.72);

const _icons = {
  'CAFE': Icons.local_cafe_outlined, 'CALORIES': Icons.local_fire_department_outlined,
  'SHOPPING_CART': Icons.shopping_cart_outlined, 'BUS': Icons.directions_bus_outlined,
  'CAR': Icons.directions_car_outlined, 'TRAIN': Icons.train_outlined, 'AIRPLANE': Icons.flight_outlined,
  'HOME': Icons.home_outlined, 'DOCUMENT': Icons.description_outlined, 'WIFI': Icons.wifi,
  'PHONE': Icons.phone_outlined, 'BRIGHTNESS': Icons.lightbulb_outline, 'GAME': Icons.sports_esports_outlined,
  'MOVIE': Icons.movie_outlined, 'MUSIC': Icons.music_note_outlined, 'HEADPHONE': Icons.headphones_outlined,
  'HEART': Icons.favorite_border, 'VPN': Icons.shield_outlined, 'EDUCATION': Icons.school_outlined,
  'LIBRARY': Icons.menu_book_outlined, 'PEOPLE': Icons.people_outline, 'BASKETBALL': Icons.sports_basketball_outlined,
  'CAMERA': Icons.photo_camera_outlined, 'PALETTE': Icons.palette_outlined, 'CUT': Icons.content_cut,
  'BROOM': Icons.cleaning_services_outlined, 'LEAF': Icons.eco_outlined, 'GLOBE': Icons.public,
  'MAIL': Icons.mail_outline, 'PRINT': Icons.print_outlined, 'CERTIFICATE': Icons.payments_outlined,
  'ASTERISK': Icons.auto_awesome_outlined, 'MARKET': Icons.trending_up, 'DEVELOPER_TOOLS': Icons.handyman_outlined,
  'PENCIL_INK': Icons.draw_outlined, 'CANCEL': Icons.undo, 'SYNC': Icons.sync, 'CALENDAR': Icons.calendar_month_outlined,
  'FLAG': Icons.flag_outlined, 'TAG': Icons.sell_outlined, 'EDIT': Icons.edit_outlined,
};

/// The icon choices for a category, in the desktop app's order.
const iconChoices = [
  'CAFE', 'CALORIES', 'SHOPPING_CART', 'BUS', 'CAR', 'TRAIN', 'AIRPLANE', 'HOME', 'DOCUMENT', 'WIFI',
  'PHONE', 'BRIGHTNESS', 'GAME', 'MOVIE', 'MUSIC', 'HEADPHONE', 'HEART', 'VPN', 'EDUCATION', 'LIBRARY',
  'PEOPLE', 'BASKETBALL', 'CAMERA', 'PALETTE', 'CUT', 'BROOM', 'LEAF', 'GLOBE', 'MAIL', 'PRINT',
  'CERTIFICATE', 'ASTERISK', 'MARKET', 'DEVELOPER_TOOLS', 'PENCIL_INK', 'CANCEL', 'SYNC', 'CALENDAR',
  'FLAG', 'TAG',
];

IconData categoryIcon(String name) => _icons[name] ?? Icons.sell_outlined;

/// A category icon in a circle tinted with its kind's series color.
class IconBubble extends StatelessWidget {
  const IconBubble(this.icon, this.kind, {super.key, this.size = 40});
  final String icon;
  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: series(context, kind).withValues(alpha: isDark(context) ? 0.30 : 0.16),
        ),
        child: Icon(categoryIcon(icon), size: size * 0.5, color: Theme.of(context).colorScheme.onSurface),
      );
}

ThemeData kaijiTheme(ColorScheme scheme) => ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
    );
