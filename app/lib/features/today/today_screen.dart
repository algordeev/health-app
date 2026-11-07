import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Daily summary. Week 2 wires these cards to `daily_metrics`. Values are placeholders until then.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _CharacterCard(),
          SizedBox(height: 12),
          _MetricCard(icon: Icons.bedtime, color: AppColors.sleep, title: 'Sleep', value: '—', hint: 'Connect Google Health to see last night'),
          _MetricCard(icon: Icons.favorite, color: AppColors.heart, title: 'Heart', value: '—', hint: 'Resting heart rate · HRV'),
          _MetricCard(icon: Icons.directions_walk, color: AppColors.activity, title: 'Activity', value: '—', hint: 'Steps · active zone minutes'),
        ],
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          CircleAvatar(radius: 32, backgroundColor: t.colorScheme.primaryContainer, child: const Text('🙂', style: TextStyle(fontSize: 32))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Pip · Level 1', style: t.textTheme.titleMedium),
              Text('Feeling content', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          Column(children: [
            Text('0', style: t.textTheme.headlineSmall?.copyWith(color: AppColors.points, fontWeight: FontWeight.bold)),
            Text('pts today', style: t.textTheme.labelSmall),
          ]),
        ]),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.icon, required this.color, required this.title, required this.value, required this.hint});
  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: color, size: 32),
        title: Text(title, style: t.textTheme.titleMedium),
        subtitle: Text(hint),
        trailing: Text(value, style: t.textTheme.headlineSmall),
      ),
    );
  }
}
