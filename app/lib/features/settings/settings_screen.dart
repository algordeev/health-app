import 'package:flutter/material.dart';

import '../../core/placeholder_view.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const PlaceholderView(icon: Icons.settings_outlined, title: 'Settings', subtitle: 'Export, delete and sharing controls arrive in week 5.'),
    );
  }
}
