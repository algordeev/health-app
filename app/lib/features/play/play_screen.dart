import 'package:flutter/material.dart';

import '../../core/placeholder_view.dart';

class PlayScreen extends StatelessWidget {
  const PlayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Play')),
      body: const PlaceholderView(icon: Icons.emoji_events_outlined, title: 'Play', subtitle: 'Tasks, streaks, friends and challenges arrive in weeks 5–6.'),
    );
  }
}
