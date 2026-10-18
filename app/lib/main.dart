import 'package:flutter/material.dart';

import 'src/home_page.dart';
import 'src/theme.dart';

void main() {
  runApp(const SalahCompanionApp());
}

class SalahCompanionApp extends StatelessWidget {
  const SalahCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Salah Companion',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomePage(),
    );
  }
}
