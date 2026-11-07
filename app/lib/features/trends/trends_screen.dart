import 'package:flutter/material.dart';

import '../../core/placeholder_view.dart';

class TrendsScreen extends StatelessWidget {
  const TrendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trends')),
      body: const PlaceholderView(icon: Icons.show_chart, title: 'Trends', subtitle: 'Weekly and monthly charts arrive in week 3.'),
    );
  }
}
