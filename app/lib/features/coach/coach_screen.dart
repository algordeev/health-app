import 'package:flutter/material.dart';

import '../../core/placeholder_view.dart';

class CoachScreen extends StatelessWidget {
  const CoachScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Coach')),
      body: const PlaceholderView(icon: Icons.chat_bubble_outline, title: 'Coach', subtitle: 'Ask why you slept badly this week. Coming in week 4.'),
    );
  }
}
