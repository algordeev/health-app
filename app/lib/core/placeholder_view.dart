import 'package:flutter/material.dart';

/// Temporary body for tabs that are scheduled for later weeks.
class PlaceholderView extends StatelessWidget {
  const PlaceholderView({super.key, required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: t.colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(subtitle, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
